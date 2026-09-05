# The opt-in layer: how often a run entered marked code, by which paths, and how much of the run
# was spent inside it.
#
# The boundary against the default layer was measured rather than chosen (`test/spec/README.md`).
# A counter in the body costs 3.76x on eight threads and loses 40% of its increments to races
# unless it is atomic; a set-once flag is free. So the flag stays, and `record` reaches the same
# statement from the other side: opening a recording clears every probe, the short-circuit fails,
# and the write side — which is a function call, not an inlined store — does the counting. Nothing
# in the body changes, and nothing outside `record` pays for any of it.

"""
    Hit

One marked definition a [`record`](@ref) block entered, and what it cost.

| field | |
|---|---|
| `mod`, `name` | which marked definition |
| `reason` | carried into the record, so a reader a year later needs no source |
| `count` | how many times it was entered, summed over threads |
| `method` | the method the mark attached to, when it attached to one |
| `callers` | the distinct immediate callers seen |
| `paths` | the distinct call paths seen, innermost first, bounded |
| `inclusive`, `exclusive` | seconds, or `missing` when no timing backend was loaded |

`count` is exact. `paths` is a bounded sample: a backtrace costs microseconds, so the recorder
stops looking once it has seen enough, and a path that only occurs after the budget is spent is
absent. `inclusive` counts time in anything this definition called; `exclusive` counts only time
in the definition itself, which is what separates a marked wrapper over settled code from a marked
kernel.
"""
struct Hit
    mod::Module
    name::Symbol
    reason::String
    count::Int
    method::Union{Method,Nothing}
    callers::Vector{Symbol}
    paths::Vector{Vector{Symbol}}
    inclusive::Union{Float64,Missing}
    exclusive::Union{Float64,Missing}
end

function Base.:(==)(a::Hit, b::Hit)
    return a.mod === b.mod &&
           a.name === b.name &&
           a.count == b.count &&
           a.method === b.method &&
           a.callers == b.callers &&
           a.paths == b.paths
end

function Base.show(io::IO, h::Hit)
    return print(io, "Hit(", h.mod, ".", h.name, ", count=", h.count, ")")
end

"""
    Record

What [`record`](@ref) observed: a `Vector`-like of [`Hit`](@ref), plus what the run was.

| property | |
|---|---|
| `enabled` | whether recording was actually on — an empty record means "nothing was entered", and that is a different statement from "nothing was recorded" |
| `slots` | thread slots the counters were sized for, at least `Threads.maxthreadid()` |
| `elapsed` | seconds the recorded call took |
| `overhead` | the recorder's estimated share of `elapsed` |
| `versions` | package versions the marks were read against |
| `sampled` | whether a timing backend produced `inclusive`/`exclusive` |

Indexing, iteration and `==` are the `Hit` vector's, so `record(f) == []` reads the way it looks.
The extra properties are why it is a type and not a plain vector: an empty `Vector{Hit}` cannot
tell "touched nothing" from "recording was off", and those mean opposite things.
"""
struct Record <: AbstractVector{Hit}
    hits::Vector{Hit}
    enabled::Bool
    slots::Int
    elapsed::Float64
    overhead::Float64
    versions::Dict{String,Any}
    sampled::Bool
end

Base.size(r::Record) = size(r.hits)
Base.getindex(r::Record, i::Int) = r.hits[i]
Base.IndexStyle(::Type{Record}) = IndexLinear()

function Base.show(io::IO, ::MIME"text/plain", r::Record)
    println(
        io,
        "Record — ",
        length(r),
        " marked definition",
        length(r) == 1 ? "" : "s",
        " entered in ",
        round(r.elapsed; sigdigits=3),
        "s",
    )
    r.enabled || println(io, "  (recording was OFF — this is not a claim that nothing ran)")
    for h in r.hits
        println(io, "  ", h.mod, ".", h.name, "  ×", h.count, " — ", h.reason)
        h.inclusive === missing || println(
            io,
            "     inclusive ",
            round(h.inclusive; sigdigits=3),
            "s   exclusive ",
            round(h.exclusive; sigdigits=3),
            "s",
        )
        for p in h.paths
            println(io, "     via ", join(reverse(p), " → "))
        end
    end
    return println(io, "  recorder overhead ≈ ", round(100 * r.overhead; sigdigits=2), "%")
end

# ── the timing backend ───────────────────────────────────────────────────────────────────────
#
# Sampling is the only way to say how much of a run was spent inside a definition without wrapping
# the call, and wrapping is exactly what the emitted statement may not do. The sampler is Julia's
# own, reached through an extension so that `using ExperimentalAPI` — which every marked package
# does at run time — never loads `Profile`.

"""
    TimingBackend

How [`record`](@ref) gets `inclusive`/`exclusive` time. The one implementation lives in this
package's `Profile` extension; without it, timing is `missing` rather than zero.
"""
abstract type TimingBackend end

struct NoTiming <: TimingBackend end

const _TIMING = Ref{TimingBackend}(NoTiming())

start_timing!(::NoTiming; kwargs...) = false
stop_timing!(::NoTiming) = nothing
attribute_timing(::NoTiming) = nothing

"""
    timing_backend() -> TimingBackend

The loaded timing backend. `NoTiming()` until `Profile` is loaded, after which
[`record`](@ref) reports seconds instead of `missing`.
"""
timing_backend() = _TIMING[]

"""
    recording() -> Bool

Whether a [`record`](@ref) block is open.

`false` by default and outside `record`, which is the whole cost argument: detection is on always
and free, counting happens only where somebody asked for it.
"""
recording() = _DEPTH[] > 0

const _DEPTH = Ref(0)
const _RECORD_LOCK = ReentrantLock()

"""
    record(f; paths = true, timing = true, with_profile = false, rethrow = true, maxdepth) -> Record

Run `f` and report which marked definitions it entered, how often, and by which paths.

```julia
r = record() do
    simulate(model; steps = 10_000)
end
isempty(r) || @warn "used unvalidated code" [(h.name, h.count) for h in r]
```

A definition that was never entered is **absent**, not reported with a count of zero: the record
says what happened, and enumerating what did not is [`experimental`](@ref)'s job.

| keyword | |
|---|---|
| `paths` | capture call paths. Bounded — see [`Hit`](@ref) — but still the expensive part |
| `timing` | ask the [`TimingBackend`](@ref) for `inclusive`/`exclusive`. Ignored if none is loaded |
| `with_profile` | leave whatever is already in the profile buffer alone instead of clearing it |
| `rethrow` | `false` returns the record for the part of `f` that ran instead of propagating |

Nests: an inner `record` reports its own block, and the outer one still counts each entry once.
Counts are exact under threads — per-thread counters sized by `Threads.maxthreadid()`, not
`nthreads()`, because the interactive pool means a task can have a thread id above the worker
count.

!!! note "This costs something, which is why it is a call"
    Every marked body takes its write path while a recording is open. The record reports the
    recorder's estimated share of the elapsed time in `overhead`; [`overhead_when_detecting`](@ref)
    is the other number, and it is 3%.
"""
function record(
    f; paths::Bool=true, timing::Bool=true, with_profile::Bool=false, rethrow::Bool=true
)
    ps = probes()
    slots = Threads.maxthreadid()
    sampled = false
    saved = Bool[]
    @lock _RECORD_LOCK begin
        if _DEPTH[] == 0
            saved = Bool[p.entered for p in ps]
            for p in ps
                _arm!(p, slots)
                p.entered = false
            end
            _CAPTURE_PATHS[] = paths
            _RECORDING[] = true
        end
        _DEPTH[] += 1
    end
    before = Dict{Probe,Int}(p => _probe_count(p) for p in ps)
    # Only the outermost block touches the sampler. Re-initialising `Profile` while its timer is
    # running is a segmentation fault, not an error, and a nested `record` has no business
    # disturbing the block that contains it.
    outermost = _DEPTH[] == 1
    if timing && outermost
        sampled = start_timing!(timing_backend(); clear=(!with_profile))
    end
    t0 = time()
    err = nothing
    try
        f()
    catch e
        err = e
    end
    elapsed = time() - t0
    sampled && stop_timing!(timing_backend())
    times = sampled ? attribute_timing(timing_backend()) : nothing

    counts = Dict{Probe,Int}(p => _probe_count(p) - get(before, p, 0) for p in ps)
    traces = Dict{Probe,Vector{Vector{Symbol}}}(p => _paths_of(p) for p in ps)
    @lock _RECORD_LOCK begin
        _DEPTH[] -= 1
        if _DEPTH[] == 0
            _RECORDING[] = false
            _CAPTURE_PATHS[] = true
            for (i, p) in enumerate(ps)
                p.entered = (i <= length(saved) && saved[i]) || counts[p] > 0
            end
        end
    end
    err === nothing || rethrow && Base.rethrow(err)

    hits = Hit[]
    for p in ps
        n = counts[p]
        n > 0 || continue
        mk = mark(p.mod, p.name)
        mk === nothing && continue
        pth = traces[p]
        inc, exc = _timing_for(times, p.mod, p.name, elapsed)
        push!(
            hits,
            Hit(
                p.mod,
                p.name,
                mk.reason,
                n,
                mk.sig === nothing ? nothing : _method_of(mk.sig),
                unique(x[2] for x in pth if length(x) >= 2),
                pth,
                inc,
                exc,
            ),
        )
    end
    sort!(hits; by=h -> (string(h.mod), string(h.name)))
    total = sum(h -> h.count, hits; init=0)
    return Record(
        hits,
        true,
        slots,
        elapsed,
        _estimate_overhead(total, elapsed),
        _versions_of(hits),
        sampled,
    )
end

function _timing_for(times, mod::Module, name::Symbol, elapsed::Float64)
    times === nothing && return (missing, missing)
    t = get(times, (mod, name), nothing)
    t === nothing && return (0.0, 0.0)
    return (t[1] * elapsed, t[2] * elapsed)
end

# Called once per probe at the end of the block, with the sampler already stopped and the recorded
# closure still alive — which is what keeps the addresses resolvable.
function _paths_of(p::Probe)
    out = Vector{Symbol}[]
    @lock p.lock begin
        for bt in p.traces
            names = _trace_names(bt)
            isempty(names) || (names in out || push!(out, names))
        end
    end
    return out
end

function _method_of(@nospecialize(sig))
    return try
        which(sig)
    catch
        nothing
    end
end

function _versions_of(hits::Vector{Hit})
    d = Dict{String,Any}()
    for h in hits
        root = Base.moduleroot(h.mod)
        v = try
            pkgversion(root)
        catch
            nothing
        end
        d[string(nameof(root))] = v === nothing ? "unknown" : string(v)
    end
    return d
end

# What one counted entry costs, measured once and cached. Reported rather than re-derived per run,
# because a per-hit timer would be the same mistake as a counter in the body: it would change the
# thing it measures.
const _PER_HIT = Ref(0.0)

function _per_hit_seconds()
    _PER_HIT[] > 0 && return _PER_HIT[]
    p = Probe(@__MODULE__, :_calibration)
    _arm!(p, Threads.maxthreadid())
    n = 100_000
    old_paths = _CAPTURE_PATHS[]
    _CAPTURE_PATHS[] = false
    _hit!(p)                                     # warm
    t0 = time_ns()
    for _ in 1:n
        _hit!(p)
    end
    t = (time_ns() - t0) / 1e9 / n
    _CAPTURE_PATHS[] = old_paths
    _PER_HIT[] = t
    return t
end

function _estimate_overhead(hits::Int, elapsed::Float64)
    (hits == 0 || elapsed <= 0) && return 0.0
    return min(1.0, hits * _per_hit_seconds() / elapsed)
end

"""
    experimental_fraction(r::Record) -> Union{Float64,Missing}

The share of the recorded run spent inside marked code, in `[0, 1]`.

`missing` when no [`TimingBackend`](@ref) was loaded — a run whose time was never attributed has
no fraction, and reporting `0.0` would say the opposite of what is known. Derived from the
`inclusive` times, so it is time and not calls: one entry into a marked kernel that runs for a
minute matters more than a million into a marked accessor.
"""
function experimental_fraction(r::Record)
    r.sampled || return missing
    r.elapsed > 0 || return 0.0
    total = 0.0
    for h in r
        h.inclusive === missing && return missing
        total += h.inclusive
    end
    return min(1.0, total / r.elapsed)
end

"""
    merge_records(rs) -> Record

Combine records — from separate processes, separate workers, or separate blocks — into one.

Counts add, paths and callers union, elapsed times add. Order-independent and associative: workers
finish in whatever order they finish in, and provenance must not depend on that.
"""
function merge_records(rs)
    byname = Dict{Tuple{Module,Symbol},Hit}()
    for r in rs
        for h in r
            k = (h.mod, h.name)
            prev = get(byname, k, nothing)
            byname[k] = prev === nothing ? h : _merge(prev, h)
        end
    end
    hits = sort!(collect(values(byname)); by=h -> (string(h.mod), string(h.name)))
    elapsed = sum(r -> r.elapsed, rs; init=0.0)
    total = sum(h -> h.count, hits; init=0)
    versions = Dict{String,Any}()
    for r in rs
        merge!(versions, r.versions)
    end
    return Record(
        hits,
        all(r -> r.enabled, rs),
        maximum(r -> r.slots, rs; init=0),
        elapsed,
        _estimate_overhead(total, elapsed),
        versions,
        any(r -> r.sampled, rs),
    )
end

function _merge(a::Hit, b::Hit)
    inc = if (a.inclusive === missing || b.inclusive === missing)
        missing
    else
        a.inclusive + b.inclusive
    end
    exc = if (a.exclusive === missing || b.exclusive === missing)
        missing
    else
        a.exclusive + b.exclusive
    end
    return Hit(
        a.mod,
        a.name,
        a.reason,
        a.count + b.count,
        a.method === nothing ? b.method : a.method,
        sort!(unique(vcat(a.callers, b.callers)); by=string),
        sort!(unique(vcat(a.paths, b.paths)); by=x -> join(x, "/")),
        inc,
        exc,
    )
end

"""
    attribute(data) -> Vector{Attribution}

Attribute an **existing** profile buffer to marked definitions, after the fact.

```julia
using Profile
Profile.@profile long_run()
attribute(Profile.fetch())
```

The twelve-hour-run case: a job that was already profiled must not have to be run again to learn
which of its time went through unvalidated code. What comes back is samples, not calls — which is
why it is an [`Attribution`](@ref) and not a [`Hit`](@ref). A sampling profiler cannot count
entries, and a field called `count` holding a sample total would read as a measurement it did not
make.

!!! note "What sampling cannot see, and why counts exist"
    A marked definition small enough to be inlined into its caller may leave **no** separately
    attributable samples at all: after inlining there is no frame to attribute them to, and the
    time is charged to whatever the optimiser left at that address. That is not a defect here, it
    is what a sampling profiler is. It is also the reason [`record`](@ref)'s `count` is exact and
    comes from a counter rather than from samples.
"""
attribute(data) = attribute(timing_backend(), data)

function attribute(::NoTiming, data)
    return throw(
        ArgumentError(
            "attribute: no timing backend is loaded — `using Profile` first, which is what " *
            "supplies the one that can read a profile buffer",
        ),
    )
end

"""
    Attribution

One marked definition's share of a profile buffer, as reported by [`attribute`](@ref).

`samples` is a sample count, never a call count: `inclusive` is the fraction of samples with this
definition anywhere on the stack, `exclusive` the fraction with it on top.
"""
struct Attribution
    mod::Module
    name::Symbol
    reason::String
    samples::Int
    inclusive::Float64
    exclusive::Float64
end

function Base.show(io::IO, a::Attribution)
    return print(
        io,
        "Attribution(",
        a.mod,
        ".",
        a.name,
        ", ",
        a.samples,
        " samples, inclusive ",
        round(100 * a.inclusive; sigdigits=2),
        "%)",
    )
end

"""
    write_record(path::AbstractString, r::Record) -> String

Write a record to TOML. Returns `path`.

Evidence, not a printout: what a run went through belongs next to the result it produced, and it
has to be readable by something that is not this package — a year later the package may not
resolve. See [`stamp`](@ref) for the same idea aimed at a result file rather than at a record.
"""
function write_record(path::AbstractString, r::Record)
    d = Dict{String,Any}(
        "enabled" => r.enabled,
        "slots" => r.slots,
        "elapsed" => r.elapsed,
        "overhead" => r.overhead,
        "sampled" => r.sampled,
        "versions" => r.versions,
        "entered" => [
            Dict{String,Any}(
                "module" => string(h.mod),
                "name" => string(h.name),
                "reason" => h.reason,
                "count" => h.count,
                "callers" => string.(h.callers),
                "paths" => [string.(p) for p in h.paths],
                "inclusive" => h.inclusive === missing ? "unmeasured" : h.inclusive,
                "exclusive" => h.exclusive === missing ? "unmeasured" : h.exclusive,
            ) for h in r
        ],
    )
    open(path, "w") do io
        return TOML.print(io, d)
    end
    return path
end

"""
    read_record(path::AbstractString) -> Record

Read back a record written by [`write_record`](@ref).

The `method` field of every [`Hit`](@ref) comes back `nothing`: a `Method` is not a thing a file
can carry, and reconstructing one would mean claiming the code in this process is the code that
produced the record.
"""
function read_record(path::AbstractString)
    d = TOML.parsefile(path)
    hits = Hit[]
    for e in get(d, "entered", Dict{String,Any}[])
        mod = _module_by_name(e["module"])
        inc = e["inclusive"]
        exc = e["exclusive"]
        push!(
            hits,
            Hit(
                mod,
                Symbol(e["name"]),
                e["reason"],
                Int(e["count"]),
                nothing,
                Symbol.(get(e, "callers", String[])),
                [Symbol.(p) for p in get(e, "paths", Vector{String}[])],
                inc isa Real ? Float64(inc) : missing,
                exc isa Real ? Float64(exc) : missing,
            ),
        )
    end
    return Record(
        hits,
        get(d, "enabled", true),
        Int(get(d, "slots", 0)),
        Float64(get(d, "elapsed", 0.0)),
        Float64(get(d, "overhead", 0.0)),
        Dict{String,Any}(get(d, "versions", Dict{String,Any}())),
        get(d, "sampled", false),
    )
end

# A record read back names its modules as strings. Resolving them is best effort: the point of
# writing one is that it survives the package not being there.
function _module_by_name(s::AbstractString)
    parts = Symbol.(split(s, "."))
    for root in values(Base.loaded_modules)
        nameof(root) === parts[1] || continue
        m = root
        ok = true
        for p in parts[2:end]
            if isdefined(m, p) && getglobal(m, p) isa Module
                m = getglobal(m, p)
            else
                ok = false
                break
            end
        end
        ok && return m
    end
    return Main
end

"""
    assert_clean(f; throw = true) -> Bool

Run `f` and assert it entered nothing marked.

The gate. `true` when the run touched no marked definition; otherwise it throws, naming every mark
it went through and why — or returns `false` if `throw = false`, which is what a caller doing its
own reporting wants.

```julia
assert_clean() do
    publish(compute(model))
end
```
"""
function assert_clean(f; throw::Bool=true)
    r = record(f; paths=false, timing=false)
    isempty(r) && return true
    throw || return false
    io = IOBuffer()
    println(io, "assert_clean: the run entered ", length(r), " experimental definition(s):")
    for h in r
        println(io, "  ", h.mod, ".", h.name, " ×", h.count, " — ", h.reason)
    end
    return Base.throw(ErrorException(String(take!(io))))
end
