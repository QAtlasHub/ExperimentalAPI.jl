# Reading a module's marks back out. Everything here is read-only and allocation-cheap: these
# are the functions a release script, a docs build or a test calls, and none of them should be
# able to create a registry as a side effect of asking a question.
#
# Two units live side by side. A NAME is what `names(m)` reports and what a release promises; a
# METHOD is what a call site actually reaches. A mark attached to a definition is both — it names
# something unsettled and knows which signature it attached to — so the queries below differ in
# which of the two they answer, never in which marks they can see.

"""
    experimental(m::Module; extensions = false) -> Vector{Mark}

Every declaration `m` has written with [`@experimental`](@ref), sorted by name.

This is the query the marker exists to make possible — a tool asks the module, rather than a
human reading docstrings. A module with no marks answers with an empty vector; it never errors
for not having opted in.

```julia
for mk in experimental(MyPackage)
    println(mk.name, " — ", mk.reason)
end
```

Includes marks on methods of *other* modules' generics, which `m` wrote and therefore owns: those
carry a `sig` and a name that is not `m`'s. `extensions = true` also walks `m`'s package
extensions, whose public names are part of the surface a user sees and are invisible to
`names(m)`.

The result is a fresh vector; mutating it does not change the module. Note that a mark does not
imply the name is public — see [`audit`](@ref)'s `dangling`.
"""
function experimental(m::Module; extensions::Bool=false)
    out = _has_registry(m) ? copy(_registry_of(m)) : Mark[]
    if extensions
        for ext in package_extensions(m)
            _has_registry(ext) && append!(out, _registry_of(ext))
        end
    end
    return sort!(out; by=_mark_order)
end

_mark_order(mk::Mark) = (string(mk.name), mk.sig === nothing ? "" : string(mk.sig))

"""
    experimental(f) -> Vector{Mark}

Every mark **anyone** has written on a method of the generic `f`, across all loaded modules.

The `fetch_value(::Heisenberg, ::Energy)` case: a generic is defined upstream and extended by
several packages, each of which may declare its own methods unsettled. The marks live in the
modules that wrote the methods, so answering this means asking all of them — see
[`marks_on`](@ref), which is the same search stated as a verb about the callee rather than about
ownership.
"""
experimental(f::Function) = marks_on(f)
experimental(t::Type) = marks_on(t)

"""
    experimental_methods(m::Module) -> Vector{Mark}

The subset of `m`'s marks that carry a signature — the claims about a method rather than about a
whole name.

Every attached form produces one, including `@experimental "…" Base.show(io, ::T) = …`, which is
how a package declares a method it contributed to somebody else's generic unsettled. The mark is
stored in the module that **wrote** the method, never in the module that owns the name: a package
cannot carry claims its dependents invented, and the mark has to survive that package being
reloaded.
"""
function experimental_methods(m::Module; extensions::Bool=false)
    return filter(mk -> mk.sig !== nothing, experimental(m; extensions))
end

"""
    marks_on(f) -> Vector{Mark}
    marks_on(m::Method) -> Vector{Mark}

Every mark written on a method of `f`, or on `m` specifically, wherever it was written.

The cross-module search. [`experimental_methods`](@ref) is the ownership question — "what has
this module declared?" — and this is the call-site question — "has anyone said anything about
what I am about to call?". One name for both would leave a reader unable to tell which they got.
"""
function marks_on(@nospecialize(f))
    ft = _ftype_of(f)
    out = Mark[]
    for mod in marked_modules()
        for mk in _registry_of(mod)
            mk.sig === nothing && continue
            _sig_ftype(mk.sig) === ft && push!(out, mk)
        end
    end
    return sort!(out; by=_mark_order)
end

function marks_on(m::Method)
    out = Mark[]
    for mk in _marks_covering(m)
        push!(out, mk)
    end
    return sort!(out; by=_mark_order)
end

"""
    mark(m::Module, name::Symbol) -> Union{Mark,Nothing}

The [`Mark`](@ref) on `name` in `m`, or `nothing` if it carries none.

This is how the reason gets to whoever needs it — an error message, a docs page, a release
checklist:

```julia
mk = mark(MyPackage, :render_report)
mk === nothing || @warn "not settled" mk.reason mk.tracking
```

A name may carry several marks when separate methods behind it were declared separately. The
whole-name declaration is returned in preference to any of them, because it is the wider claim;
[`marks`](@ref) returns all of them.
"""
function mark(m::Module, name::Symbol)
    ms = marks(m, name)
    isempty(ms) && return nothing
    i = findfirst(isnamewide, ms)
    return i === nothing ? ms[1] : ms[i]
end

"""
    marks(m::Module, name::Symbol) -> Vector{Mark}

Every mark `m` carries under `name` — the whole-name declaration if there is one, and one per
separately declared method.
"""
function marks(m::Module, name::Symbol)
    _has_registry(m) || return Mark[]
    return sort!(filter(x -> x.name === name, copy(_registry_of(m))); by=_mark_order)
end

"""
    mark(m::Method) -> Union{Mark,Nothing}

The [`Mark`](@ref) covering the method `m`, or `nothing`.

A method is covered by a mark on its exact signature, or by a whole-name mark on the generic it
belongs to. The second is why a name list still says something about every method behind the
name, and the first is why marking one dispatch path does not speak for its siblings.
"""
function mark(m::Method)
    for mk in _marks_covering(m)
        return mk
    end
    return nothing
end

"""
    isexperimental(m::Module, name::Symbol) -> Bool
    isexperimental(m::Method) -> Bool

Whether `name` in `m`, or the method `m`, is declared [`@experimental`](@ref).

The one-bit form of [`mark`](@ref), for a caller that only needs the verdict — for instance the
mechanical statement that changing this name is not breaking. Does not consult docstrings and
does not consult visibility: it answers only whether a mark exists.
"""
isexperimental(m::Module, name::Symbol) = !isempty(marks(m, name))
isexperimental(m::Method) = mark(m) !== nothing

# The marks that cover one method, widest first. Written as an iterator over a vector so both
# `mark(::Method)` and `marks_on(::Method)` read the same rule.
function _marks_covering(m::Method)
    out = Mark[]
    ft = _sig_ftype(m.sig)
    id = _ftype_identity(ft)
    for mod in _search_modules(m)
        _has_registry(mod) || continue
        for mk in _registry_of(mod)
            if mk.sig === m.sig
                push!(out, mk)
            elseif mk.sig === nothing &&
                id !== nothing &&
                mk.mod === id.mod &&
                mk.name === id.name &&
                (!id.constructor || mk.includes_constructors)
                push!(out, mk)
            end
        end
    end
    # A whole-name claim is the wider statement, so a caller that wants one mark gets that one.
    return sort!(out; by=mk -> (mk.sig !== nothing, _mark_order(mk)))
end

# Where a mark covering `m` can live, and nowhere else. The macro writes into the module the
# definition is in, and `mark_method!` writes into `m.module` for the same reason — so a
# signature-level mark is always in `m.module`. A whole-name mark is in the module that owns the
# name, which is the only module in which that name means this generic.
#
# Two modules rather than a walk over every marked module in the process: this runs once per
# resolved call site inside `reach`, and a world walk there would dominate the analysis.
function _search_modules(m::Method)
    id = _ftype_identity(_sig_ftype(m.sig))
    (id === nothing || id.mod === m.module) && return (m.module,)
    return (m.module, id.mod)
end

# The function type a signature dispatches on: `Tuple{typeof(f), Int}` -> `typeof(f)`.
function _sig_ftype(@nospecialize(sig))
    s = Base.unwrap_unionall(sig)
    (s isa DataType && s <: Tuple && !isempty(s.parameters)) || return nothing
    return s.parameters[1]
end

# Who a function type belongs to, in the vocabulary a mark is written in.
function _ftype_identity(@nospecialize(ft))
    ft === nothing && return nothing
    if ft isa DataType && ft <: Type && length(ft.parameters) == 1
        t = ft.parameters[1]
        t isa Union && return nothing
        b = Base.unwrap_unionall(t)
        b isa DataType || return nothing
        return (mod=parentmodule(b), name=nameof(b), constructor=true)
    end
    ft isa DataType || return nothing
    if isdefined(ft, :instance)
        f = ft.instance
        return (mod=parentmodule(f), name=nameof(f), constructor=false)
    end
    # A callable object: `(c::C)(x)` dispatches on `C` itself.
    return (mod=parentmodule(ft), name=nameof(ft), constructor=false)
end

"""
    mark_method!(m::Method, reason::AbstractString; since, tracking, until) -> Mark

Declare one method unsettled, from outside its definition.

The imperative route to what `@experimental "…" f(::T) = …` does at the definition site. It is
here for the cases the macro cannot reach: a method produced by another package's macro, a method
generated in a loop, and a package adopting this on code it does not want to touch yet.

The mark is stored in the module that **wrote** the method, `m.module`, exactly where the macro
would have put it — so it is queryable through [`experimental_methods`](@ref) and survives the
same way.

```julia
mark_method!(
    which(fetch_value, Tuple{Heisenberg,Energy}),
    "numerically delicate; no reference value";
    tracking = "https://github.com/org/Pkg.jl/issues/12",
)
```

Prefer the macro. A mark that is not next to the definition is a mark the next person editing that
definition will not see.
"""
function mark_method!(
    m::Method, reason::AbstractString; since=nothing, tracking=nothing, until=nothing
)
    reg = _method_registry!(m.module)
    mk = Mark(
        m.module,
        m.name,
        _reason(reason),
        since === nothing ? nothing : _since(since),
        tracking === nothing ? nothing : _tracking(tracking),
        m.file,
        Int(m.line),
        m.sig,
        false,
        until === nothing ? nothing : _until(until),
    )
    return _mark!(reg, mk)
end

# `mark_method!` may be the first mark a module ever gets, and it arrives at run time rather than
# from the macro, so the registry has to be created here. The value is used through `Core.eval`'s
# return value and never read back in the same world age.
function _method_registry!(m::Module)
    _has_registry(m) && return _registry_of(m)
    return Core.eval(m, Expr(:const, Expr(:(=), MARKS_BINDING, Mark[])))
end

"""
    superseded_marks(m::Module) -> Vector{Mark}

The declarations that were replaced by a later one on the same name and signature.

Re-marking is last-write-wins, which is the right rule — a file included twice must not double
its marks — but it is a rule that can lose a reason silently. Anything it drops is kept here, so
"the mark says something different from what I wrote" is answerable rather than mysterious.

Empty for almost every module: nothing is recorded unless a mark actually replaced a different
one.
"""
function superseded_marks(m::Module)
    isdefined(m, SUPERSEDED_BINDING) || return Mark[]
    v = getglobal(m, SUPERSEDED_BINDING)
    return v isa Vector{Mark} ? copy(v) : Mark[]
end

"""
    package_extensions(m::Module) -> Vector{Module}

Every loaded package extension of `m`.

An extension is a separate module whose public names are part of the surface a user sees and are
invisible to `names(m)`. [`audit`](@ref) reports which of them are loaded rather than folding
them in, because an extension that is not loaded is not missing — it is inapplicable.
"""
function package_extensions(m::Module)
    out = Module[]
    root = Base.moduleroot(m)
    dir = try
        Base.pkgdir(root)
    catch
        nothing
    end
    dir === nothing && return out
    proj = joinpath(dir, "Project.toml")
    isfile(proj) || return out
    # Read from the project rather than found by walking `Base.loaded_modules`: an extension is a
    # top-level module whose parent link says nothing about whose extension it is, and the
    # `[extensions]` table is the only place the relationship is written down.
    d = try
        TOML.parsefile(proj)
    catch
        return out
    end
    for name in sort!(collect(keys(get(d, "extensions", Dict{String,Any}()))))
        ext = Base.get_extension(root, Symbol(name))
        ext === nothing || push!(out, ext)
    end
    return out
end

"""
    marks_without_exit(m::Module) -> Vector{Mark}

The marks that say why a name is unsettled but not what would settle it.

A mark with no `until=` can be added and never mechanically retired — [`ready_to_promote`](@ref)
can only answer `false` for it, forever. That is a decoration rather than a work item, so it is
reported as its own finding rather than being folded into "not ready".
"""
marks_without_exit(m::Module) = filter(mk -> mk.until === nothing, experimental(m))
