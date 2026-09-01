# The check. Everything above this file is material; this is the part that turns a marker into
# something that can fail.
#
# The whole audit is one set difference: public surface, minus the names with a docstring, minus
# the names with a mark. What is left is the set of names a caller can reach and nobody has said
# anything about — and it is exactly the set that a package cannot leave non-empty once this runs
# in CI.

"""
    surface(m::Module) -> Vector{Symbol}

The public surface of `m`: every name it exports or declares `public`, sorted, excluding the
module's own name.

This is `names(m)`, given a name — since Julia 1.11 that list is precisely "exported or
`public`", which is the surface a stability claim has to be made about. Names reachable only as
`M.internal_thing` are not here, and are nobody's promise.
"""
surface(m::Module) = sort!(filter(!=(nameof(m)), names(m)))

"""
    stable(m::Module) -> Vector{Symbol}

The public surface of `m` minus the names declared [`@experimental`](@ref) — the names whose
removal or renaming *is* a breaking change.

The covenant, in other words. [`snapshot`](@ref) writes this down so two releases can be
compared; [`isbreaking`](@ref) is what reads the comparison.
"""
stable(m::Module) = setdiff(surface(m), Symbol[mk.name for mk in experimental(m)])

"""
    isdocumented(m::Module, name::Symbol) -> Bool

Whether `name` has a docstring.

A re-exported name counts: the lookup follows the binding to the module the name actually comes
from, so a package that puts a dependency's name on its own surface is not asked to re-document
it. [`audit`](@ref) still reports those separately as `foreign`, because who owns a name and who
documented it are different questions.

This answers *whether prose exists*, never whether it is any good. A docstring reading `"TODO"`
is documented as far as this package is concerned.
"""
function isdocumented(m::Module, name::Symbol)
    # `Docs.hasdoc` is not part of Base's public API. It is what Documenter's `checkdocs` uses,
    # so it is de-facto stable; `test/test_audit.jl` pins both the documented/undocumented split
    # AND the re-export behaviour relied on here, so this stops being an assumption.
    return Base.Docs.hasdoc(m, name)
end

function _owner(m::Module, name::Symbol)
    return isdefined(m, name) ? Base.binding_module(m, name) : nothing
end

# A submodule's names are still this package's to account for; a dependency's are not.
function _is_own(m::Module, name::Symbol)
    o = _owner(m, name)
    o === nothing && return true              # public but undefined — ours, and a defect
    while true
        o === m && return true
        p = parentmodule(o)
        p === o && return false
        o = p
    end
end

"""
    Audit

What [`audit`](@ref) found. Every field is a sorted `Vector{Symbol}`, and every name in
`surface` appears in exactly one of `foreign`, `documented`, `declared`, `unaccounted` —
except that a name may be both `documented` and `declared`, in which case it is counted as
`documented`.

| field | |
|---|---|
| `mod` | the module audited |
| `surface` | `names(m)` — exported or `public` |
| `foreign` | public here, but bound in another package; not this module's to declare |
| `documented` | has a docstring |
| `declared` | has an [`@experimental`](@ref) mark |
| `unaccounted` | **neither** — the finding |
| `dangling` | marked experimental but not public; a mark that promises nothing |

`unaccounted` is the one a test asserts is empty. `dangling` needs no external oracle to be
wrong: it is the module contradicting itself.
"""
struct Audit
    mod::Module
    surface::Vector{Symbol}
    foreign::Vector{Symbol}
    documented::Vector{Symbol}
    declared::Vector{Symbol}
    unaccounted::Vector{Symbol}
    dangling::Vector{Symbol}
end

"""
    audit(m::Module) -> Audit

List the public names of `m` that are **neither documented nor declared experimental**.

```julia
julia> audit(Pinax).unaccounted
15-element Vector{Symbol}:
 :completeness_overview
 :dump_test_report
 ⋮
```

Two accounts are accepted, and the choice between them is the author's: write the docstring, or
say [`@experimental`](@ref) and why. What is not accepted is saying nothing — which is the state
a public name is in by default, and the state no reader can distinguish from a settled one.

Also reports `dangling`: marks on names that are not public. That check needs no reference
implementation to be right, because the module is disagreeing with itself.

# What this cannot see

  * **Signatures.** A name that stays present while its arguments change is invisible here.
  * **Prose quality.** A docstring exists or it does not; [`isdocumented`](@ref) reads no further.
  * **Methods on other packages' functions.** They are not in `names(m)` and never will be.
  * **Names public only inside an extension**, which is a separate module.

See [`test_surface`](@ref) to run this as a test, and [`snapshot`](@ref) to carry the result into
a release decision.
"""
function audit(m::Module)
    surf = surface(m)
    marked = Set(mk.name for mk in experimental(m))

    foreign = Symbol[]
    documented = Symbol[]
    declared = Symbol[]
    unaccounted = Symbol[]
    for n in surf
        if !_is_own(m, n)
            push!(foreign, n)
        elseif isdocumented(m, n)
            push!(documented, n)
            n in marked && push!(declared, n)
        elseif n in marked
            push!(declared, n)
        else
            push!(unaccounted, n)
        end
    end
    dangling = sort!(collect(setdiff(marked, surf)))
    return Audit(m, surf, foreign, documented, declared, unaccounted, dangling)
end

function Base.show(io::IO, a::Audit)
    return print(
        io,
        "Audit(",
        a.mod,
        ": ",
        length(a.surface),
        " public, ",
        length(a.unaccounted),
        " unaccounted)",
    )
end

function Base.show(io::IO, ::MIME"text/plain", a::Audit)
    println(io, "Public surface of ", a.mod, " — ", length(a.surface), " names")
    println(io, "  documented    ", lpad(length(a.documented), 4))
    println(io, "  experimental  ", lpad(length(a.declared), 4))
    isempty(a.foreign) || println(
        io,
        "  foreign       ",
        lpad(length(a.foreign), 4),
        "   (bound in another module)",
    )
    print(io, "  unaccounted   ", lpad(length(a.unaccounted), 4))
    if isempty(a.unaccounted)
        println(io)
    else
        println(io, "   ← neither documented nor @experimental")
        _print_names(io, a.unaccounted)
    end
    if !isempty(a.dangling)
        println(
            io,
            "  dangling      ",
            lpad(length(a.dangling), 4),
            "   ← marked, but not public",
        )
        _print_names(io, a.dangling)
    end
    return nothing
end

# Never truncated: a coverage list that elides its tail reads as if the tail were empty.
function _print_names(io::IO, ns::Vector{Symbol})
    width = something(get(io, :displaysize, nothing), displaysize(io))[2]
    line = "     "
    for n in ns
        s = string(n)
        if length(line) + length(s) + 2 > width && length(line) > 5
            println(io, rstrip(line))
            line = "     "
        end
        line *= s * ", "
    end
    return println(io, rstrip(rstrip(line), ','))
end
