# The release-decision layer: write the covenant down at release time, and read a diff of two of
# them at review time. This is the payoff for marking anything at all — "changing an experimental
# name is not breaking" stops being an argument and becomes a function call.
#
# It is also the least settled part of this package, so it says so in its own vocabulary. The
# name-list form is used here rather than six attached marks because the reason is one reason.
@experimental """
the snapshot schema records names only; making it signature-aware would change the file format, \
and nothing has yet been released against it
""" snapshot read_snapshot write_snapshot compare isbreaking Diff

"""
    snapshot(m::Module) -> Dict{String,Any}

Write down what `m` currently promises: its [`stable`](@ref) names, and its experimental ones
with their reasons.

The result is plain `Dict`/`String`/`Vector` data, so `TOML.print` accepts it as-is
([`write_snapshot`](@ref) does that). Take one at each release; hand the old one and the new
module to [`compare`](@ref).

```toml
module = "MyPackage"
version = "0.4.2"
stable = ["adapt", "measure"]

[experimental.render_report]
reason = "reads Test's internal result tree"
tracking = "https://github.com/org/MyPackage.jl/issues/12"
```
"""
function snapshot(m::Module)
    exp = Dict{String,Any}()
    for mk in experimental(m)
        e = Dict{String,Any}("reason" => mk.reason)
        mk.since === nothing || (e["since"] = string(mk.since))
        mk.tracking === nothing || (e["tracking"] = mk.tracking)
        exp[string(mk.name)] = e
    end
    d = Dict{String,Any}(
        "module" => string(nameof(m)), "stable" => string.(stable(m)), "experimental" => exp
    )
    v = pkgversion(m)
    v === nothing || (d["version"] = string(v))
    return d
end

"""
    write_snapshot(path::AbstractString, m::Module) -> String

[`snapshot`](@ref) `m` and write it to `path` as TOML. Returns `path`.

Committing this file at each release is what gives the next release something to compare
against; a repository with no committed snapshot can be told what is experimental *now*, but not
what changed.
"""
function write_snapshot(path::AbstractString, m::Module)
    open(path, "w") do io
        return TOML.print(io, snapshot(m))
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
    This compares name sets. A name present in both snapshots whose method signature, return
    type or keyword arguments changed is a breaking change that `compare` cannot see, and no
    amount of marking makes it visible. Read the diff as a floor on breakage, never as a
    clearance.
"""
compare(old::AbstractDict, new::Module) = compare(old, snapshot(new))

function compare(old::AbstractDict, new::AbstractDict)
    os, oe = _sets(old)
    ns, ne = _sets(new)
    return Diff(
        sort!(collect(setdiff(os, ns, ne))),
        sort!(collect(intersect(os, ne))),
        sort!(collect(setdiff(oe, ns, ne))),
        sort!(collect(intersect(oe, ns))),
        sort!(collect(setdiff(ns, os, oe))),
        sort!(collect(setdiff(ne, os, oe))),
    )
end

function _sets(d::AbstractDict)
    st = Set(Symbol.(get(d, "stable", String[])))
    ex = Set(Symbol.(keys(get(d, "experimental", Dict{String,Any}()))))
    return st, ex
end

"""
    isbreaking(d::Diff) -> Bool

Whether `d` removes a settled name or demotes one — the two moves that break callers who were
told the truth.

This is the release gate: a `true` here means the version bump is major (or, under Julia's 0.x
convention, a minor bump). Because [`compare`](@ref) reads names and not signatures, `false`
means *no breakage of this kind was found*, not *nothing broke*.
"""
isbreaking(d::Diff) = !isempty(d.removed_stable) || !isempty(d.demoted)

function Base.show(io::IO, ::MIME"text/plain", d::Diff)
    println(io, "Diff — ", isbreaking(d) ? "BREAKING" : "not breaking")
    for (label, v, breaks) in (
        ("removed (stable)", d.removed_stable, true),
        ("demoted to experimental", d.demoted, true),
        ("removed (experimental)", d.removed_experimental, false),
        ("promoted to stable", d.promoted, false),
        ("added (stable)", d.added_stable, false),
        ("added (experimental)", d.added_experimental, false),
    )
        isempty(v) && continue
        println(io, "  ", breaks ? "! " : "  ", rpad(label, 24), join(v, ", "))
    end
    return nothing
end
