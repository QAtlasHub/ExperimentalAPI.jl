# The default layer: which marked definitions a run actually entered.
#
# Scope: presence, not counts, and only for definitions with a body. A mark written as a name list,
# or attached to a struct, const, module or macro, is a declaration only — nothing observes it.
#
# The one statement the macro puts in a marked body reads a single field and writes it once:
# measured at 1.03x on one thread and 0.985x on eight, over 10M calls of a numeric body. A flag
# written once and only read afterwards stops dirtying the cache line, which a counter (3.76x at
# eight threads, and losing 40% of its increments to races unless atomic) does not.
#
# `record` reaches the same statement without changing it: opening a recording clears every
# probe's flag, so the short-circuit fails and the write side runs on every call. The cost of
# counting is paid only inside `record`, and the fast path is one field load either way.

# Padding, in Int64 slots, between one thread's counter and the next. A cache line is 64 bytes on
# every platform this runs on; two threads sharing one would serialise on the store.
const _COUNTER_STRIDE = 8

# How many distinct backtraces one probe keeps while recording, and how many times it will look.
# A backtrace costs microseconds, so capturing one per call would dominate any run long enough to
# be worth recording. The paths a marked definition is reached by are few and repeat, so the
# attempt budget is what bounds the cost: without it, a definition reached by three paths would
# keep paying for a backtrace on every one of ten million calls, having found its third path in
# the first microsecond.
const _TRACE_CAP = 64
const _TRACE_ATTEMPTS = 256

"""
    Probe

The one-field flag `@experimental` puts in a marked body, and the counter [`record`](@ref) reads.

Not part of the public surface — it is named rather than gensym'd only so that
`MyModule.__EXPERIMENTAL_API_ENTERED_energy__` is greppable when a query result surprises someone.

`entered` is the whole default layer: read on every call, written on the first. The remaining
fields are untouched unless a recording is open.
"""
mutable struct Probe
    entered::Bool
    const mod::Module
    const name::Symbol
    # Recording state. `hits` is padded per thread; `traces` is bounded and guarded.
    hits::Vector{Int64}
    traces::Vector{Vector{Union{Ptr{Nothing},Base.InterpreterIP}}}
    attempts::Int64
    const lock::ReentrantLock
end

function Probe(mod::Module, name::Symbol)
    return Probe(
        false,
        mod,
        name,
        Int64[],
        Vector{Union{Ptr{Nothing},Base.InterpreterIP}}[],
        0,
        ReentrantLock(),
    )
end

# The fast path, and the only thing a marked body does when nothing is recording.
Base.getindex(p::Probe) = p.entered

# The write side. Reached once per process when nothing is recording, and on every call while a
# recording is open — which is what makes counting cost nothing outside `record`.
#
# `@noinline` for two reasons, and neither is speed on this path. It keeps the marked body small,
# so the fast path is a load and a branch over a call; and it makes the call a real frame, so the
# backtrace taken underneath it resolves to the marked definition rather than to whatever the
# optimiser left at that address.
@noinline function Base.setindex!(p::Probe, v::Bool)
    if _RECORDING[]
        _hit!(p)
    else
        p.entered = v
    end
    return v
end

# Read by the write side only, so the fast path never sees it.
const _RECORDING = Ref(false)

@noinline function _hit!(p::Probe)
    tid = Threads.threadid()
    h = p.hits
    i = tid * _COUNTER_STRIDE
    if i <= length(h)
        @inbounds h[i] += 1
    else
        # A thread that did not exist when the recording opened — the interactive pool grows, and
        # an `nthreads()`-sized vector would throw here rather than count.
        @lock p.lock begin
            _resize_hits!(p, tid)
            @inbounds p.hits[i] += 1
        end
    end
    # Racy on purpose: `attempts` is a budget, not a count, and a lock on the fast path of the
    # recorder would cost more than the backtraces it saves.
    if _CAPTURE_PATHS[] && p.attempts < _TRACE_ATTEMPTS && length(p.traces) < _TRACE_CAP
        p.attempts += 1
        _capture_trace!(p)
    end
    return nothing
end

# Whether the open recording asked for call paths. Read on the recorder's slow path only.
const _CAPTURE_PATHS = Ref(true)

function _resize_hits!(p::Probe, tid::Int)
    need = (max(tid, Threads.maxthreadid()) + 2) * _COUNTER_STRIDE
    length(p.hits) >= need && return nothing
    h = zeros(Int64, need)
    copyto!(h, p.hits)
    p.hits = h
    return nothing
end

# The address list only. Resolving it to names here would mean walking the debug info while the
# sampling profiler may be in its signal handler doing the same thing, and the two take the same
# lock: `record`'s own paths would deadlock against its own timing. `_trace_names` is called
# once, at the end of the block, with the sampler stopped.
@noinline function _capture_trace!(p::Probe)
    bt = backtrace()
    @lock p.lock begin
        length(p.traces) < _TRACE_CAP && !any(==(bt), p.traces) && push!(p.traces, bt)
    end
    return nothing
end

# The caller chain, innermost first, with this package's own frames dropped: the probe, the
# recorder and `record` itself are in every path and in none of the user's code.
function _trace_names(bt)
    out = Symbol[]
    for frame in stacktrace(bt, false)
        frame.from_c && continue
        _frame_module(frame) === ExperimentalAPI && continue
        push!(out, frame.func)
    end
    return out
end

# `StackFrame.linfo` is a `CodeInstance` on 1.12, a `MethodInstance` before it, `nothing` for an
# inlined frame, and a `CodeInfo` for top-level code. Only the first two lead to a module — an
# inlined frame is kept, which is right: an inlined caller is still a caller.
function _frame_module(frame)
    li = frame.linfo
    li isa Core.CodeInstance && (li = li.def)
    li isa Core.MethodInstance || return nothing
    d = li.def
    return d isa Method ? d.module : (d isa Module ? d : nothing)
end

_probe_count(p::Probe) = isempty(p.hits) ? 0 : sum(p.hits)

function _arm!(p::Probe, slots::Int)
    @lock p.lock begin
        h = zeros(Int64, (slots + 2) * _COUNTER_STRIDE)
        length(p.hits) == length(h) ? fill!(p.hits, 0) : (p.hits = h)
        empty!(p.traces)
        p.attempts = 0
    end
    return nothing
end

# One probe per marked NAME, in the marked module, next to its registry.
_flag_name(n::Symbol) = Symbol("__EXPERIMENTAL_API_ENTERED_", n, "__")

function _flag(m::Module, n::Symbol)
    s = _flag_name(n)
    isdefined(m, s) || return nothing
    f = getglobal(m, s)
    return f isa Probe ? f : nothing
end

"""
    probes(m::Module) -> Vector{Probe}
    probes() -> Vector{Probe}

Every [`Probe`](@ref) a module carries — one per marked definition that has a body.

The recording layer arms and reads these; nothing else should need them. Exposed because
`record`'s cost model is only checkable by someone who can see how many probes there are.
"""
function probes(m::Module)
    out = Probe[]
    _has_registry(m) || return out
    for mk in _registry_of(m)
        p = _flag(m, mk.name)
        p === nothing || (p in out || push!(out, p))
    end
    return out
end

probes() = reduce(vcat, (probes(m) for m in marked_modules()); init=Probe[])

# What the macro puts in the body: one statement, a read that writes only on the first call.
_probe(flag) = :($flag[] || ($flag[] = true))

# Returns the definition with the probe spliced in, or `nothing` if this form has no body to
# instrument.
#
# The `LineNumberNode` is the declaration's own, and it is load bearing rather than cosmetic. The
# write side is a cold branch, so the optimiser is free to sink it to the end of the function;
# without a location of its own it inherits whichever statement happens to be next, and a
# backtrace taken inside it then resolves to that statement's inlining context instead of to the
# marked definition. `record`'s call paths are built out of exactly that.
function _instrument(def, flag, src::LineNumberNode)
    def isa Expr || return nothing
    (def.head === :function || def.head === :(=)) || return nothing
    _is_signature(def.args[1]) || return nothing
    length(def.args) == 2 || return nothing
    return Expr(def.head, def.args[1], Expr(:block, src, _probe(flag), def.args[2]))
end

"""
    Entry

One marked definition that the current run entered, as reported by [`entered`](@ref).

`count` is always `nothing`. The default layer knows *whether* a definition was entered, never how
often — a per-call counter costs 3.76x on eight threads and loses 40% of its increments to races
unless it is atomic. Counting is [`record`](@ref)'s job, and it is opt-in for that reason.
"""
struct Entry
    mod::Module
    name::Symbol
    reason::String
    count::Nothing
end

Entry(m::Module, n::Symbol, r::AbstractString) = Entry(m, n, String(r), nothing)

function Base.show(io::IO, e::Entry)
    return print(io, "Entry(", e.mod, ".", e.name, ", ", repr(e.reason), ")")
end

"""
    entered(m::Module) -> Vector{Entry}
    entered() -> Vector{Entry}

The marked definitions this run has entered at least once.

Without an argument, every loaded module that carries marks. This is the question a docstring
cannot answer: not "is this name experimental" but "did the number I am about to publish come out
of code nobody has validated".

A definition that was never called is **absent**, not reported with a count of zero.

```julia
julia> MyPkg.energy(0.5);

julia> entered()
1-element Vector{ExperimentalAPI.Entry}:
 Entry(MyPkg.energy, "convergence not established below β ≈ 0.1")
```

Only definitions with a body are observed; see [`@experimental`](@ref) for which forms those are.
"""
function entered(m::Module)
    out = Entry[]
    _has_registry(m) || return out
    seen = Set{Symbol}()
    for mk in _registry_of(m)
        mk.name in seen && continue
        f = _flag(m, mk.name)
        if f !== nothing && f[]
            push!(seen, mk.name)
            push!(out, Entry(m, mk.name, mk.reason))
        end
    end
    return out
end

entered() = reduce(vcat, (entered(m) for m in marked_modules()); init=Entry[])

# Base and Core are skipped rather than walked: neither can carry a mark, and `names(Base;
# all=true)` is thousands of bindings whose `getglobal` can warn.
const _NOT_WALKED = (Base, Core)

"""
    marked_modules() -> Vector{Module}

Every loaded module that carries at least one [`@experimental`](@ref) mark.

Found by walking the loaded packages rather than by a registry inside this package: a table here
would be written while the *marked* package is precompiled, and so would be absent from its cache
image. Same constraint that puts the marks themselves in the marked module.
"""
function marked_modules()
    w = Base.get_world_counter()
    cached = _MARKED_MODULES[]
    cached[1] == w && return cached[2]
    out = Module[]
    seen = Set{Module}()
    for root in values(Base.loaded_modules)
        _walk_modules!(out, seen, root)
    end
    _MARKED_MODULES[] = (w, out)
    return out
end

# Cached per world age. The walk is over every binding of every loaded module, and `record` asks
# for it twice per block — with a large dependency tree loaded that is the most expensive thing
# in a recording that counts a hundred calls. Keying on the world counter is exact rather than
# approximate: a module gains a registry only by defining a `const`, and defining one advances
# the counter.
const _MARKED_MODULES = Ref{Tuple{UInt64,Vector{Module}}}((typemax(UInt64), Module[]))

function _walk_modules!(out::Vector{Module}, seen::Set{Module}, m::Module)
    (m in seen || m in _NOT_WALKED) && return nothing
    push!(seen, m)
    _has_registry(m) && push!(out, m)
    for n in names(m; all=true)
        isdefined(m, n) || continue
        v = try
            getglobal(m, n)
        catch
            continue
        end
        v isa Module && v !== m && parentmodule(v) === m && _walk_modules!(out, seen, v)
    end
    return nothing
end

"""
    detecting() -> Bool

Whether the summary at process exit is armed.

On by default, because a user who never asks is exactly the one who needs to be told. Set
`ENV["EXPERIMENTALAPI_SUMMARY"] = "0"` **before** `using ExperimentalAPI` to silence it; the
`atexit` hook is registered at load time, so a later assignment has no effect.

Detection itself is not a switch: the flag is in the definition and costs nothing to leave on.
See [`overhead_when_detecting`](@ref) for the figure that justifies that sentence.
"""
detecting() = get(ENV, "EXPERIMENTALAPI_SUMMARY", "1") != "0"

"""
    overhead_when_detecting() -> Float64

The measured cost of the default layer, as a fraction of the unmarked body's run time.

`0.03`. Not computed at call time: it is the figure from the measurement that chose this
mechanism — 10M calls of a realistic numeric body on Julia 1.12.2, minimum of 7–9 trials, giving
`1.03x` on one thread and `0.985x` on eight. The eight-thread figure is below one because a flag
written once and read thereafter stops dirtying its cache line.

It is reported rather than re-measured because a wall-clock measurement on a shared CI runner is a
flake generator, and because a number that moves with the machine cannot be the thing a caller
plans against. [`record`](@ref) reports its own overhead per run, which is the opposite case: that
one depends on how often the marked code was entered.
"""
overhead_when_detecting() = 0.03

"""
    summary_text() -> String
    summary_text(es::AbstractVector{Entry}) -> String

What the exit summary prints, as a string. Empty when nothing marked was entered.

Carries the reason, not just the name: the name tells a reader which line to look at, the reason
tells them whether the result they are holding is affected.
"""
function summary_text(es::AbstractVector{Entry}=entered())
    isempty(es) && return ""
    io = IOBuffer()
    n = length(es)
    println(
        io,
        "┌ ExperimentalAPI: this run entered $n experimental definition$(n == 1 ? "" : "s")",
    )
    for e in es
        println(io, "│   ", e.mod, ".", e.name, " — ", e.reason)
    end
    println(
        io, "└ set ENV[\"EXPERIMENTALAPI_SUMMARY\"] = \"0\" before `using` to silence this"
    )
    return String(take!(io))
end

# Printed to stderr, and only when something was entered: loading a package that HAS marks must be
# silent, or this package is intolerable as a dependency. Never throws — a summary that breaks a
# process on its way out would be worse than no summary.
function _summarise()
    try
        s = summary_text()
        isempty(s) || print(stderr, s)
    catch
    end
    return nothing
end
