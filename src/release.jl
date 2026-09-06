# The release-decision layer: write the covenant down at release time, and read a diff of two of
# them at review time. This is the payoff for marking anything at all — "changing an experimental
# name is not breaking" stops being an argument and becomes a function call.
#
# Two units, one file, one schema. Names are what `names(m)` promises; methods are what a call
# site reaches, and a package whose surface is methods on somebody else's generic has no name-level
# covenant at all. The two live in one snapshot so that a repository has one file to commit.
@experimental """
the snapshot schema is young: nothing has been released against it, and the method half was added \
after the name half, so a file written by one version may not be readable by the next
""" snapshot read_snapshot write_snapshot compare compare_methods isbreaking stamp Diff MethodDiff

"""
    snapshot(m::Module) -> Dict{String,Any}

Write down what `m` currently promises: its [`stable`](@ref) names and its experimental ones with
their reasons, and the same split at method granularity.

The result is plain `Dict`/`String`/`Vector` data, so `TOML.print` accepts it as-is
([`write_snapshot`](@ref) does that). Take one at each release; hand the old one and the new module
to [`compare`](@ref).

```toml
module = "MyPackage"
version = "0.4.2"
stable = ["adapt", "measure"]
stable_methods = ["adapt(::Model, ::Grid)", "measure(::Model)"]

[experimental.render_report]
reason = "reads Test's internal result tree"
tracking = "https://example.invalid/issues/12"

[experimental_methods."fetch_value(::Heisenberg, ::Energy)"]
reason = "numerically delicate; no reference value"
```

`methods = false` writes the name half only, which is what a package with no foreign methods and a
slow method search wants.
"""
function snapshot(m::Module; methods::Bool=true)
    # The two name lists partition the surface, which is what makes `compare`'s buckets add up:
    # a name is experimental here exactly when `stable` left it out, and that is the `wholly`
    # rule — a name with one marked method out of four is still a promise.
    st = stable(m)
    exp = Dict{String,Any}()
    for n in setdiff(surface(m), st)
        mk = mark(m, n)
        mk === nothing && continue
        exp[string(n)] = _mark_entry(mk)
    end
    d = Dict{String,Any}(
        "module" => string(nameof(m)), "stable" => string.(st), "experimental" => exp
    )
    if methods
        expm = Dict{String,Any}()
        for mk in experimental_methods(m)
            expm[_signature_key(mk)] = _mark_entry(mk)
        end
        d["experimental_methods"] = expm
        d["stable_methods"] = [_signature_key(mm) for mm in stable_methods(m)]
    end
    v = pkgversion(m)
    v === nothing || (d["version"] = string(v))
    return d
end

function _mark_entry(mk::Mark)
    e = Dict{String,Any}("reason" => mk.reason)
    mk.since === nothing || (e["since"] = string(mk.since))
    mk.tracking === nothing || (e["tracking"] = mk.tracking)
    return e
end

"""
    write_snapshot(path::AbstractString, m::Module) -> String

[`snapshot`](@ref) `m` and write it to `path` as TOML. Returns `path`.

Committing this file at each release is what gives the next release something to compare
against; a repository with no committed snapshot can be told what is experimental *now*, but not
what changed.
"""
function write_snapshot(path::AbstractString, m::Module; methods::Bool=true)
    open(path, "w") do io
        return TOML.print(io, snapshot(m; methods))
    end
    return path
end

"""
    read_snapshot(path::AbstractString) -> Dict{String,Any}

Read a TOML file written by [`write_snapshot`](@ref).
"""
read_snapshot(path::AbstractString) = TOML.parsefile(path)

"""
    Diff

The result of [`compare`](@ref): how a module's public surface moved between two snapshots.

| field | breaking? | |
|---|---|---|
| `removed_stable` | **yes** | a settled name is gone |
| `demoted` | **yes** | a settled name is now called experimental — a promise withdrawn |
| `removed_experimental` | no | this is what marking a name buys |
| `promoted` | no | experimental → settled; the direction this is all for |
| `added_stable` | no | |
| `added_experimental` | no | |

[`isbreaking`](@ref) is the one-bit reading of the first two rows.
"""
struct Diff
    removed_stable::Vector{Symbol}
    demoted::Vector{Symbol}
    removed_experimental::Vector{Symbol}
    promoted::Vector{Symbol}
    added_stable::Vector{Symbol}
    added_experimental::Vector{Symbol}
end

"""
    MethodDiff

[`Diff`](@ref) at method granularity — the same six buckets, keyed by signature rather than by
name, as produced by [`compare_methods`](@ref).

A signature key carries the argument types and the keyword **names**, so a method whose arguments
or keywords changed reads as one key removed and another added. That is the blind spot `compare`
admits to and this closes; see [`compare_methods_sees_keywords`](@ref) for the part that stays
open.
"""
struct MethodDiff
    removed_stable::Vector{String}
    demoted::Vector{String}
    removed_experimental::Vector{String}
    promoted::Vector{String}
    added_stable::Vector{String}
    added_experimental::Vector{String}
end

"""
    compare(old::AbstractDict, new::Union{Module,AbstractDict}) -> Diff

Say mechanically what moved between two snapshots — and therefore whether the change is breaking.

```julia
d = compare(read_snapshot("api.toml"), MyPackage)
isbreaking(d) && error("breaking: \$(d.removed_stable) removed, \$(d.demoted) demoted")
```

A removed name that was declared [`@experimental`](@ref) in `old` lands in `removed_experimental`
and does not make the change breaking. That is the whole contract: the mark was the notice, and
it was given in the source, at the definition, before the removal.

`demoted` — a name that was stable and is now marked experimental — counts as **breaking**.
Retroactively withdrawing a promise is a change to what callers were told, not a correction of
it.

!!! warning "Names, not signatures"
    This compares name sets. A name present in both snapshots whose method signature, return type
    or keyword arguments changed is a breaking change `compare` cannot see. [`compare_methods`](@ref)
    is the finer instrument; read this one as a floor on breakage, never as a clearance.
"""
compare(old::AbstractDict, new::Module) = compare(old, snapshot(new))

function compare(old::AbstractDict, new::AbstractDict)
    os, oe = _sets(old, "stable", "experimental", Symbol)
    ns, ne = _sets(new, "stable", "experimental", Symbol)
    return Diff(_buckets(os, oe, ns, ne)...)
end

"""
    compare_methods(old::AbstractDict, new::Union{Module,AbstractDict}) -> MethodDiff

[`compare`](@ref) at method granularity: what moved between two snapshots' `stable_methods` and
`experimental_methods`.

The unit a call site actually reaches. `fetch(::Ising, ::Energy)` and `fetch(::Heisenberg, ::Energy)`
are one name and two promises, and removing the second is breaking exactly when it was not marked.

Reads the same snapshot file `compare` does — the two keys mirror the name-level pair — so a
repository commits one file and a release script asks it both questions.
"""
compare_methods(old::AbstractDict, new::Module) = compare_methods(old, snapshot(new))

function compare_methods(old::AbstractDict, new::AbstractDict)
    os, oe = _sets(old, "stable_methods", "experimental_methods", String)
    ns, ne = _sets(new, "stable_methods", "experimental_methods", String)
    return MethodDiff(_buckets(os, oe, ns, ne)...)
end

function _buckets(os, oe, ns, ne)
    return (
        sort!(collect(setdiff(os, ns, ne))),
        sort!(collect(intersect(os, ne))),
        sort!(collect(setdiff(oe, ns, ne))),
        sort!(collect(intersect(oe, ns))),
        sort!(collect(setdiff(ns, os, oe))),
        sort!(collect(setdiff(ne, os, oe))),
    )
end

function _sets(d::AbstractDict, skey::String, ekey::String, T::Type)
    st = Set(T.(get(d, skey, String[])))
    ex = Set(T.(collect(keys(get(d, ekey, Dict{String,Any}())))))
    return st, ex
end

"""
    compare_methods_sees_keywords

`true`. A signature key carries the keyword **names** a method declares, so adding, removing or
renaming one moves the key and [`compare_methods`](@ref) reports it.

Stated as a constant rather than left to be discovered, because the neighbouring limit is real and
has to be stated with it: keyword **defaults** live in the method body and are invisible here, so
changing `tol = 1e-8` to `tol = 1e-6` moves nothing. Names yes, defaults no.
"""
const compare_methods_sees_keywords = true

"""
    isbreaking(d::Union{Diff,MethodDiff}) -> Bool

Whether `d` removes a settled name or method, or demotes one — the two moves that break callers
who were told the truth.

This is the release gate: a `true` here means the version bump is major (or, under Julia's 0.x
convention, a minor bump). Because a diff reads names and signatures and not behaviour, `false`
means *no breakage of this kind was found*, not *nothing broke*.
"""
isbreaking(d::Diff) = !isempty(d.removed_stable) || !isempty(d.demoted)
isbreaking(d::MethodDiff) = !isempty(d.removed_stable) || !isempty(d.demoted)

# The key a method is recorded under. `f(::Int64; tol, maxiter)` — argument types positionally,
# keyword names alphabetically. Readable in a committed file, and stable under anything that does
# not change the signature.
function _signature_key(mm::Method)
    return _signature_key(mm.name, mm.sig, Base.kwarg_decl(mm))
end

function _signature_key(mk::Mark)
    mk.sig === nothing && return string(mk.name)
    mm = try
        which(mk.sig)
    catch
        nothing
    end
    kw = mm === nothing ? Symbol[] : Base.kwarg_decl(mm)
    name = mm === nothing ? mk.name : mm.name
    return _signature_key(name, mk.sig, kw)
end

function _signature_key(name::Symbol, @nospecialize(sig), kwargs::Vector{Symbol})
    s = Base.unwrap_unionall(sig)
    args = if (s isa DataType && s <: Tuple && length(s.parameters) >= 1)
        s.parameters[2:end]
    else
        Any[]
    end
    io = IOBuffer()
    print(io, name, "(")
    print(io, join(("::" * _type_key(a) for a in args), ", "))
    kw = sort(filter(k -> !endswith(String(k), "..."), kwargs); by=String)
    isempty(kw) || print(io, "; ", join(kw, ", "))
    print(io, ")")
    return String(take!(io))
end

# Type names without their defining module: a snapshot committed by one package and read by
# another must not move because a module was renamed around the type.
function _type_key(@nospecialize(t))
    t isa TypeVar && return String(t.name)
    b = Base.unwrap_unionall(t)
    if b isa DataType
        isempty(b.parameters) && return String(nameof(b))
        return String(nameof(b)) *
               "{" *
               join((_type_key(p) for p in b.parameters), ", ") *
               "}"
    end
    return string(t)
end

function Base.show(io::IO, ::MIME"text/plain", d::Diff)
    return _show_diff(io, "Diff", d, isbreaking(d))
end
function Base.show(io::IO, ::MIME"text/plain", d::MethodDiff)
    return _show_diff(io, "MethodDiff", d, isbreaking(d))
end

function _show_diff(io::IO, label::String, d, breaking::Bool)
    println(io, label, " — ", breaking ? "BREAKING" : "not breaking")
    for (name, v, breaks) in (
        ("removed (stable)", d.removed_stable, true),
        ("demoted to experimental", d.demoted, true),
        ("removed (experimental)", d.removed_experimental, false),
        ("promoted to stable", d.promoted, false),
        ("added (stable)", d.added_stable, false),
        ("added (experimental)", d.added_experimental, false),
    )
        isempty(v) && continue
        println(io, "  ", breaks ? "! " : "  ", rpad(name, 24), join(v, ", "))
    end
    return nothing
end

"""
    stamp(path::AbstractString, f) -> String
    stamp(path::AbstractString, r::Record) -> String

Run `f`, and write next to its result a record of which unvalidated code paths produced it.

The end state this package is for: a figure's directory says what the number came out of, in plain
TOML that a reader a year later can open without resolving the package that wrote it.

```julia
stamp("figures/energy_sweep.provenance.toml") do
    sweep(model; βs = 0.05:0.05:2.0)
end
```

Returns `path`. The file carries every mark the run entered, its reason, how often it was entered,
and the versions of the packages the marks came from — see [`stamp_versions`](@ref).
"""
function stamp(path::AbstractString, f)
    return stamp(path, record(f))
end

# `stamp(path) do … end` puts the function first, which is the form the documentation teaches and
# the order `record` already takes. Typed `::Function` so `stamp(path, value)` stays unambiguous.
function stamp(f::Function, path::AbstractString)
    return stamp(path, f)
end

function stamp(path::AbstractString, r::Record)
    d = Dict{String,Any}(
        "generated" => string(Dates_now()),
        "julia" => string(VERSION),
        "elapsed" => r.elapsed,
        "versions" => stamp_versions(),
        "experimental" => [
            Dict{String,Any}(
                "module" => string(h.mod),
                "name" => string(h.name),
                "reason" => h.reason,
                "count" => h.count,
            ) for h in r
        ],
    )
    open(path, "w") do io
        return TOML.print(io, d)
    end
    return path
end

# `Dates` is not a dependency and one timestamp does not justify making it one.
Dates_now() = Base.Libc.strftime("%Y-%m-%dT%H:%M:%S%z", time())

"""
    stamp_versions() -> Dict{String,Any}

The version of every loaded package, for [`stamp`](@ref) to write beside a result.

`energy` being experimental in v0.3 says nothing about v0.9, so a provenance record that names
marks without naming versions describes a state nobody can get back to.
"""
function stamp_versions()
    d = Dict{String,Any}("julia" => string(VERSION))
    for (id, mod) in Base.loaded_modules
        v = try
            pkgversion(mod)
        catch
            nothing
        end
        v === nothing || (d[String(id.name)] = string(v))
    end
    return d
end
