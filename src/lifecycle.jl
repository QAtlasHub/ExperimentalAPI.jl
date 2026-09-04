# The mark's exit.
#
# A mark that can only ever be added is a decoration. What makes it a work item is a stated
# condition under which it stops applying — `until=` on the declaration — and the two questions
# that condition makes answerable: may this mark go, and how long has it been standing.

"""
    ready_to_promote(m::Module, name::Symbol) -> Bool
    ready_to_promote(mk::Mark) -> Bool

Whether the declaration's own exit condition is met.

Not "is this marked" but "may this stop being marked", answered by the thing that knows: the
`until=` predicate the author wrote next to the reason.

```julia
@experimental(
    "no reference value yet",
    since = v"0.1.0",
    tracking = "https://github.com/org/Pkg.jl/issues/12",
    until = () -> isfile(joinpath(@__DIR__, "..", "test", "refs", "energy.toml")),
    energy(β) = 2β,
)
```

`false` for a mark with no `until=`, always — a mark whose exit was never written down cannot be
retired mechanically, and reporting it "ready" because it happens to be covered by a test would be
inventing a criterion the author did not state. Those marks are reported separately by
[`marks_without_exit`](@ref) rather than being quietly lumped in with the ones still standing.

A predicate that throws counts as not ready: an exit condition that cannot be evaluated has not
been met.
"""
function ready_to_promote(mk::Mark)
    mk.until === nothing && return false
    return try
        mk.until() === true
    catch
        false
    end
end

function ready_to_promote(m::Module, name::Symbol)
    mk = mark(m, name)
    return mk === nothing ? false : ready_to_promote(mk)
end

"""
    promotable(m::Module) -> Vector{Mark}

Every mark in `m` whose exit condition is met — the work item list, in the direction of done.
"""
promotable(m::Module) = filter(ready_to_promote, experimental(m))

"""
    age(m::Module, name::Symbol, current::VersionNumber) -> Union{Int,Missing}
    age(mk::Mark, current::VersionNumber) -> Union{Int,Missing}

How many **breaking** releases the mark has been standing for, or `missing` if it records no
`since`.

Counted on the axis a version bump is breaking along, which under Julia's 0.x convention is the
minor component and after 1.0 the major one. `since = v"0.1.0"` seen from `v"0.9.0"` is 8.

`since` exists so a mark cannot quietly become permanent. This is the function that reads it; see
[`stale_since`](@ref) for the list form a CI job asks for.
"""
function age(mk::Mark, current::VersionNumber)
    mk.since === nothing && return missing
    s = mk.since
    (s.major == 0 && current.major == 0) && return Int(current.minor) - Int(s.minor)
    return Int(current.major) - Int(s.major)
end

function age(m::Module, name::Symbol, current::VersionNumber)
    mk = mark(m, name)
    return mk === nothing ? missing : age(mk, current)
end

"""
    stale_since(m::Module, current::VersionNumber; releases::Int = 2) -> Vector{Mark}

The marks that have been standing for `releases` breaking releases or more.

The report a CI job turns into a nag. Marks with no `since` are not listed here — they are a
different finding, and [`marks_without_exit`](@ref) plus a `since`-less mark is what a package
that never intended to retire anything looks like.
"""
function stale_since(m::Module, current::VersionNumber; releases::Int=2)
    out = Mark[]
    for mk in experimental(m)
        a = age(mk, current)
        a === missing && continue
        a >= releases && push!(out, mk)
    end
    return out
end

"""
    exceeds_mark_cap(m::Module, cap::Int) -> Bool

Whether `m` carries more than `cap` marks.

The ratchet, in the shape [`test_surface`](@ref)'s `skip` already has: a number checked into the
repository that can be lowered and not raised. It is a count and not a list because the list is
`experimental(m)`, and a project that wants the finer gate should assert on that instead.
"""
exceeds_mark_cap(m::Module, cap::Int) = length(experimental(m)) > cap
