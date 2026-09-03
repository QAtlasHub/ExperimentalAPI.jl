# The default layer: which marked definitions a run actually entered.
#
# Scope: presence, not counts, and only for definitions with a body. A mark written as a name list,
# or attached to a struct, const, module or macro, is a declaration only — nothing observes it.

# One flag per marked NAME, in the marked module, next to its registry. Named rather than
# gensym'd for the same reason the registry is.
_flag_name(n::Symbol) = Symbol("__EXPERIMENTAL_API_ENTERED_", n, "__")

function _flag(m::Module, n::Symbol)
    s = _flag_name(n)
    isdefined(m, s) || return nothing
    f = getglobal(m, s)
    return f isa Base.RefValue{Bool} ? f : nothing
end

# What the macro puts in the body. Measured on 10M calls of a numeric body: 1.03x on one thread
# and 0.985x on eight, because after the first call it is a read of a cache line nobody writes.
# An unconditional store, a counter, or anything that logs is not affordable here — see
# `test/spec/README.md`.
_probe(flag) = :($flag[] || ($flag[] = true))

function _is_signature(x)
    return x isa Expr && (
        x.head === :call ||
        ((x.head === :where || x.head === :(::)) && _is_signature(x.args[1]))
    )
end

# Returns the definition with the probe spliced in, or `nothing` if this form has no body to
# instrument. `@generated` and other macro-wrapped forms are refused rather than guessed at: the
# body of a generated function returns an expression, so a probe there would be spliced into the
# generated code instead of running.
function _instrument(def, flag)
    def isa Expr || return nothing
    (def.head === :function || def.head === :(=)) || return nothing
    _is_signature(def.args[1]) || return nothing
    length(def.args) == 2 || return nothing
    return Expr(def.head, def.args[1], Expr(:block, _probe(flag), def.args[2]))
end

"""
    Entry

One marked definition that the current run entered, as reported by [`entered`](@ref).

`count` is always `nothing`. The default layer knows *whether* a definition was entered, never how
often — a per-call counter costs 3.76x on eight threads and loses 40% of its increments to races
unless it is atomic. Counting is the opt-in layer's job.
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
    isdefined(m, MARKS_BINDING) || return out
    for mk in _registry_of(m)
        f = _flag(m, mk.name)
        f !== nothing && f[] && push!(out, Entry(m, mk.name, mk.reason))
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
    out = Module[]
    seen = Set{Module}()
    for root in values(Base.loaded_modules)
        _walk_modules!(out, seen, root)
    end
    return out
end

function _walk_modules!(out::Vector{Module}, seen::Set{Module}, m::Module)
    (m in seen || m in _NOT_WALKED) && return nothing
    push!(seen, m)
    isdefined(m, MARKS_BINDING) && push!(out, m)
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
"""
detecting() = get(ENV, "EXPERIMENTALAPI_SUMMARY", "1") != "0"

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
