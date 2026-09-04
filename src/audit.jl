# The check. Everything above this file is material; this is the part that turns a marker into
# something that can fail.
#
# The name half of the audit is one set difference: public surface, minus the names with a
# docstring, minus the names with a mark. What is left is the set of names a caller can reach and
# nobody has said anything about — and it is exactly the set that a package cannot leave non-empty
# once this runs in CI.
#
# The method half exists because `names(m)` cannot see a method a package contributed to somebody
# else's generic, and for a package whose surface IS such methods — `fetch(model, quantity)` with
# 570 of them — a clean name audit reports nothing while covering nothing.

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

The public surface of `m` minus the names that are *wholly* [`@experimental`](@ref) — the names
whose removal or renaming is a breaking change.

The covenant, in other words. [`snapshot`](@ref) writes this down so two releases can be
compared; [`isbreaking`](@ref) is what reads the comparison.

"Wholly" is the load-bearing word. A name is out of the covenant when a whole-name declaration
covers it, or when every method behind it is marked. A name with four methods of which one is
marked stays **in** — the author declared one dispatch path unsettled, which is not a licence to
remove the name. See [`stable_methods`](@ref) for the finer unit.
"""
function stable(m::Module)
    marked = Set(mk.name for mk in experimental(m))
    return filter(n -> !(n in marked && _wholly_experimental(m, n)), surface(m))
end

"""
    stable_methods(m::Module) -> Vector{Method}

The methods `m` defines that carry no mark — the covenant at the unit a call site actually
reaches.

The name-level [`stable`](@ref) cannot see this: `fetch(::Ising, ::Energy)` and
`fetch(::Heisenberg, ::Energy)` are one name and two promises. Covers both `m`'s own generics and
the methods it contributed to somebody else's; see [`contributed_methods`](@ref).
"""
function stable_methods(m::Module)
    return filter(!isexperimental, own_methods(m))
end

function _wholly_experimental(m::Module, name::Symbol)
    ms = marks(m, name)
    isempty(ms) && return false
    any(isnamewide, ms) && return true
    isdefined(m, name) || return true
    v = try
        getglobal(m, name)
    catch
        return true
    end
    ml = try
        methods(v)
    catch
        return false
    end
    isempty(ml) && return false
    return all(isexperimental, ml)
end

"""
    isdocumented(m::Module, name::Symbol) -> Bool
    isdocumented(m::Method) -> Bool

Whether `name`, or the method `m`, has a docstring.

A re-exported name counts: the lookup follows the binding to the module the name actually comes
from, so a package that puts a dependency's name on its own surface is not asked to re-document
it. [`audit`](@ref) still reports those separately as `foreign`, because who owns a name and who
documented it are different questions.

Docstrings are keyed by signature, so the method form is answerable and is not the same question:
a documented generic with an undocumented method is normal, and for a package whose surface is
methods on somebody else's generic it is the only question there is.

This answers *whether prose exists*, never whether it is any good. A docstring reading `"TODO"` is
documented as far as this package is concerned.
"""
function isdocumented(m::Module, name::Symbol)
    # `Docs.hasdoc` is public API — `public`, and exported from `Base.Docs`. Its set-valued
    # sibling `Docs.undocumented_names` answers the same question for a whole module at once and
    # is what `Aqua.test_undocumented_names` is built on; the per-name form is used here because
    # `audit` has to tell a module's own gap apart from a dependency's, and the set form reports
    # a re-exported name's missing docstring as though it were this module's to fix.
    return Base.Docs.hasdoc(m, name)
end

function isdocumented(m::Method)
    id = _ftype_identity(_sig_ftype(m.sig))
    owner = id === nothing ? m.module : id.mod
    name = id === nothing ? m.name : id.name
    # Only the module that WROTE the method is asked. `Docs` files a docstring under the
    # binding's module but in the *writing* module's table, so this is the right table — and
    # looking in the owner's as well would let the generic's own docstring, whose key is
    # `Tuple{Any, Any}`, account for all 570 methods anybody ever contributed to it.
    d = try
        Base.Docs.meta(m.module; autoinit=false)
    catch
        nothing
    end
    d === nothing && return false
    b = Base.Docs.Binding(owner, name)
    haskey(d, b) || return false
    args = _argument_tuple(m.sig)
    args === nothing && return false
    for sig in keys(d[b].docs)
        # `Union{}` is the key `@doc` uses for a docstring attached to the binding rather than to
        # any one signature. `Docs` keys the rest by ARGUMENT types, without the function type.
        sig === Union{} && continue
        sig isa Type && args <: sig && return true
    end
    return false
end

function _argument_tuple(@nospecialize(sig))
    s = Base.unwrap_unionall(sig)
    (s isa DataType && s <: Tuple && !isempty(s.parameters)) || return nothing
    return try
        Tuple{s.parameters[2:end]...}
    catch
        nothing
    end
end

# Whether a mark says anything about `m`'s own public surface. A mark that attached to a
# signature is asked about the generic it extends, not about whether the name happens to be bound
# here: `using ..Upstream` leaves no binding for `fetch_value`, and reading that absence as "ours"
# would report every contributed method as a dangling promise.
function _is_surface_claim(m::Module, mk::Mark)
    if mk.sig !== nothing
        id = _ftype_identity(_sig_ftype(mk.sig))
        id === nothing || return _is_submodule(id.mod, m)
    end
    return _is_own(m, mk.name)
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
    own_methods(m::Module) -> Vector{Method}

Every method `m` defines, on its own generics and on other modules' alike.

Julia indexes methods by generic, not by module, so this is a search: the generics bound in `m`
(including the ones it imported to extend), the generics `m`'s own marks name, and the
exported-or-`public` names of every loaded module. That last set is what catches
`Base.show(io, ::Widget)`, written with a qualified name that leaves no binding in `m`.

!!! note "The one gap, stated"
    A method contributed to a generic that is neither bound in `m` nor exported-or-`public`
    anywhere — `Base.SomeInternal.f(::Widget) = …` — is not found. It is also not part of any
    surface anyone can be told about, which is why the search stops there rather than walking
    every binding of every loaded module.
"""
function own_methods(m::Module)
    out = Method[]
    seen = Set{Method}()
    for f in _generic_candidates(m)
        ml = try
            methods(f)
        catch
            continue
        end
        for mm in ml
            mm.module === m && !(mm in seen) && (push!(seen, mm); push!(out, mm))
        end
    end
    return sort!(out; by=mm -> (string(mm.name), string(mm.sig)))
end

function _generic_candidates(m::Module)
    seen = Set{UInt}()
    out = Any[]
    add(v) =
        if (v isa Function || v isa Type) && !(objectid(v) in seen)
            push!(seen, objectid(v))
            push!(out, v)
        end
    for n in names(m; all=true, imported=true)
        isdefined(m, n) || continue
        v = try
            getglobal(m, n)
        catch
            continue
        end
        add(v)
    end
    if _has_registry(m)
        for mk in _registry_of(m)
            mk.sig === nothing && continue
            ft = _sig_ftype(mk.sig)
            ft isa DataType && isdefined(ft, :instance) && add(ft.instance)
        end
    end
    for v in _public_generics()
        add(v)
    end
    return out
end

# The exported-or-`public` callables of every loaded module, computed once per world age. The
# result is a few thousand entries and the scan over it costs tens of milliseconds; recomputing it
# per `audit` call would make the audit the slowest thing in a test suite.
const _PUBLIC_GENERICS = Ref{Tuple{UInt64,Vector{Any}}}((typemax(UInt64), Any[]))

function _public_generics()
    w = Base.get_world_counter()
    cached = _PUBLIC_GENERICS[]
    cached[1] == w && return cached[2]
    seen = Set{UInt}()
    out = Any[]
    for mod in values(Base.loaded_modules)
        for n in names(mod)
            isdefined(mod, n) || continue
            v = try
                getglobal(mod, n)
            catch
                continue
            end
            (v isa Function || v isa Type) || continue
            objectid(v) in seen && continue
            push!(seen, objectid(v))
            push!(out, v)
        end
    end
    _PUBLIC_GENERICS[] = (w, out)
    return out
end

"""
    contributed_methods(m::Module) -> Vector{Method}

The methods `m` defines on generics it does not own.

`audit`'s `foreign` bucket says "this name is bound elsewhere, so documenting it is not our
problem". A method we wrote on such a name is the exact opposite: it is entirely our problem, and
it is invisible to `names(m)`.
"""
function contributed_methods(m::Module)
    return filter(own_methods(m)) do mm
        id = _ftype_identity(_sig_ftype(mm.sig))
        return id === nothing ? false : !_is_submodule(id.mod, m)
    end
end

function _is_submodule(o::Module, m::Module)
    while true
        o === m && return true
        p = parentmodule(o)
        p === o && return false
        o = p
    end
end

"""
    extends_base(mm::Method) -> Bool

Whether `mm` extends a generic owned by `Base` or `Core`.

The line [`test_surface`](@ref) draws by default when it asks whether a contributed method is
accounted for. A method on `Base.show` or `Base.==` implements a protocol whose documentation is
Base's, and requiring a docstring on each of them trains a project to turn the whole check off. A
method on another package's generic is a downstream extension only this package can describe —
`fetch_value(::Heisenberg, ::Energy)` is surface in a way `show(io, ::Audit)` is not.

Stated as a rule about **who owns the generic**, not as a list of names: a list of interface
functions is not closed under the ones Julia adds next.
"""
function extends_base(mm::Method)
    id = _ftype_identity(_sig_ftype(mm.sig))
    id === nothing && return false
    r = Base.moduleroot(id.mod)
    return r === Base || r === Core
end

"""
    unaccounted_methods(m::Module) -> Vector{Method}

The methods `m` contributed to other modules' generics that carry **neither** a docstring nor a
mark.

The method-level twin of `audit(m).unaccounted`, and the finding for a package whose surface is
methods rather than names. A name-level audit reports `unaccounted = []` for such a package while
having looked at none of them.
"""
function unaccounted_methods(m::Module)
    return filter(mm -> !isdocumented(mm) && !isexperimental(mm), contributed_methods(m))
end

"""
    Audit

What [`audit`](@ref) found. The name fields are sorted `Vector{Symbol}`, and every name in
`surface` appears in exactly one of `foreign`, `documented`, `unaccounted` or
`declared`-and-not-`documented` — the partition [`partition_holds`](@ref) checks.

| field | |
|---|---|
| `mod` | the module audited |
| `surface` | `names(m)` — exported or `public` |
| `foreign` | public here, but bound in another package; not this module's to declare |
| `documented` | has a docstring |
| `declared` | has an [`@experimental`](@ref) mark |
| `undocumented` | no docstring, mark or not |
| `unaccounted` | **neither** — the finding |
| `dangling` | marked experimental but not public; a mark that promises nothing |
| `tracking` | name → where its shape is being decided, for the marks that say |
| `contributed_methods` | methods this module wrote on other modules' generics |
| `undocumented_methods` | of those, the ones with no docstring |
| `unaccounted_methods` | of those, the ones with neither a docstring nor a mark |
| `extensions` | this module's loaded package extensions, which are audited separately |

`unaccounted` is the one a test asserts is empty. `dangling` needs no external oracle to be
wrong: it is the module contradicting itself.
"""
struct Audit
    mod::Module
    surface::Vector{Symbol}
    foreign::Vector{Symbol}
    documented::Vector{Symbol}
    declared::Vector{Symbol}
    undocumented::Vector{Symbol}
    unaccounted::Vector{Symbol}
    dangling::Vector{Symbol}
    tracking::Dict{Symbol,String}
    contributed_methods::Vector{Method}
    undocumented_methods::Vector{Method}
    unaccounted_methods::Vector{Method}
    extensions::Vector{Module}
end

"""
    audit(m::Module; methods = true) -> Audit

Report the public names of `m` that are missing prose, a mark, or both — and the methods it
contributed to other modules' generics, which no name-level check can see.

```julia
julia> audit(Pinax).undocumented
15-element Vector{Symbol}:
 :completeness_overview
 :dump_test_report
 ⋮
```

**A mark is not a substitute for a docstring.** The two are independent accounts of a name and
both are owed: the docstring says what it does, the mark says whether the shape is settled. A
public name that carries a mark and no prose appears in `undocumented` exactly as one with
neither does, and [`test_surface`](@ref) fails on it.

| field | what it holds |
|---|---|
| `documented` | has a docstring |
| `declared` | has a mark — overlaps `documented`, and is not an alternative to it |
| `undocumented` | no docstring, mark or not. This is the one [`test_surface`](@ref) asserts empty |
| `unaccounted` | neither account — a subset of `undocumented`, and the worst case |

Also reports `dangling`: marks on names that are not public. That check needs no reference
implementation to be right, because the module is disagreeing with itself.

`methods = false` skips the method-level search, which is the expensive half — it scans the
generics of every loaded module. The name-level answer is unchanged by it.

# What this cannot see

  * **Signatures of its own names.** A name that stays present while its arguments change is
    invisible here; `compare_methods` is the release-side answer.
  * **Prose quality.** A docstring exists or it does not; [`isdocumented`](@ref) reads no further.
  * **Names public only inside an extension**, which is a separate module — reported in
    `extensions` and audited by passing it to `audit` in its own right.

See [`test_surface`](@ref) to run this as a test, and [`snapshot`](@ref) to carry the result into
a release decision.
"""
function audit(m::Module; methods::Bool=true)
    surf = surface(m)
    all_marks = experimental(m)
    marked = Set(mk.name for mk in all_marks)

    foreign = Symbol[]
    documented = Symbol[]
    declared = Symbol[]
    undocumented = Symbol[]
    unaccounted = Symbol[]
    for n in surf
        if !_is_own(m, n)
            push!(foreign, n)
            continue
        end
        n in marked && push!(declared, n)
        if isdocumented(m, n)
            push!(documented, n)
        else
            push!(undocumented, n)
            n in marked || push!(unaccounted, n)
        end
    end
    # A mark on a generic another module owns is the foreign-method form — `Base.show(io, ::T)`
    # — and it promises nothing about THIS module's surface, so it cannot dangle here;
    # `contributed_methods` is where it is accounted for. A mark on something of our own that is
    # not public does dangle, whether or not it carries a signature.
    dangling = sort!(
        unique(
            mk.name for mk in all_marks if _is_surface_claim(m, mk) && !(mk.name in surf)
        ),
    )
    tracking = Dict{Symbol,String}(
        mk.name => mk.tracking for mk in all_marks if mk.tracking !== nothing
    )

    contributed = methods ? contributed_methods(m) : Method[]
    undoc_methods = filter(!isdocumented, contributed)
    unacc_methods = filter(mm -> !isexperimental(mm), undoc_methods)
    return Audit(
        m,
        surf,
        foreign,
        documented,
        declared,
        undocumented,
        unaccounted,
        dangling,
        tracking,
        contributed,
        undoc_methods,
        unacc_methods,
        package_extensions(m),
    )
end

"""
    partition_holds(a::Audit) -> Bool

Whether every public name landed in exactly one bucket.

`foreign`, `documented`, `unaccounted`, and the declared-but-undocumented remainder must cover
`surface` exactly once. The invariant is stated in [`Audit`](@ref) and is easy to break from the
outside — every new field is one more thing a reader assumes partitions the surface — so it is
checkable rather than only written down.
"""
function partition_holds(a::Audit)
    parts = vcat(a.foreign, a.documented, a.unaccounted, setdiff(a.declared, a.documented))
    return sort(parts) == a.surface && length(unique(parts)) == length(parts)
end

"""
    aqua_compatible_names(m::Module) -> Vector{Symbol}

The names `Aqua.test_undocumented_names` reports and this package's [`audit`](@ref) accounts for.

The two tools ask different questions, and both are legitimate. Aqua's is two-valued: a public
name has a docstring or it fails. `audit` has a third answer — a mark — so a name that is
declared unsettled is still `undocumented` but is not `unaccounted`.

This is the difference, computed, so a project running both can see exactly which names it would
have to argue about. **Empty means the two agree**, which is the state a package should be aiming
for: a mark records that a shape is unsettled, and that is never a reason to say nothing about
what the name does.
"""
function aqua_compatible_names(m::Module)
    a = audit(m; methods=false)
    return sort!(collect(intersect(Set(a.declared), Set(a.undocumented))))
end

function Base.show(io::IO, a::Audit)
    return print(
        io,
        "Audit(",
        a.mod,
        ": ",
        length(a.surface),
        " public, ",
        length(a.undocumented),
        " undocumented)",
    )
end

function Base.show(io::IO, ::MIME"text/plain", a::Audit)
    println(io, "Public surface of ", a.mod, " — ", length(a.surface), " names")
    println(io, "  documented    ", lpad(length(a.documented), 4))
    println(io, "  experimental  ", lpad(length(a.declared), 4))
    isempty(a.undocumented) ||
        println(io, "  undocumented  ", lpad(length(a.undocumented), 4))
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
    if !isempty(a.contributed_methods)
        println(
            io,
            "  contributed methods ",
            lpad(length(a.contributed_methods), 4),
            "   (on other modules' generics)",
        )
        print(io, "  unaccounted methods ", lpad(length(a.unaccounted_methods), 4))
        if isempty(a.unaccounted_methods)
            println(io)
        else
            println(io, "   ← neither documented nor @experimental")
            for mm in a.unaccounted_methods
                println(io, "     ", mm.name, mm.sig, "  @ ", mm.file, ":", mm.line)
            end
        end
    end
    isempty(a.extensions) || println(
        io, "  extensions    ", lpad(length(a.extensions), 4), "   (audited separately)"
    )
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
