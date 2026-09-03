# What one `@experimental` declaration records, where it is stored, and the macro that writes it.
#
# Storage is a `const` vector inside the MARKED module: a registry here would be populated during
# the marked package's precompilation, and nothing written into a third module then survives into
# its cache image. `Docs.META` is per-module for the same reason. Pinned by
# `test/test_precompile.jl`.

"""
    Mark

One `@experimental` declaration.

`reason` is the field the whole design exists for: why a name is not settled is knowledge only
the author has, so it travels with the mark rather than being reconstructed by a reader later.
`file`/`line` point at the declaration, which is the definition site in the attached form.

| field | |
|---|---|
| `mod::Module` | the module the name is public in |
| `name::Symbol` | the marked name; a macro is stored as `Symbol("@foo")` |
| `reason::String` | why it is not settled |
| `since::Union{VersionNumber,Nothing}` | version the name has been experimental since |
| `tracking::Union{String,Nothing}` | where the shape is being decided — an issue, PR, or URL |
| `file::Symbol`, `line::Int` | where the declaration is written |

See [`experimental`](@ref) to read them back, and [`mark`](@ref) to look one up by name.
"""
struct Mark
    mod::Module
    name::Symbol
    reason::String
    since::Union{VersionNumber,Nothing}
    tracking::Union{String,Nothing}
    file::Symbol
    line::Int

    # The reason is the payload, so the invariant belongs in the type: `Mark` is `public`, and
    # every construction route that is not the macro gets it for free here.
    function Mark(mod, name, reason, since, tracking, file, line)
        r = String(strip(reason))
        isempty(r) &&
            throw(ArgumentError("a Mark's reason may not be empty — it is the payload"))
        return new(mod, name, r, since, tracking, file, line)
    end
end

function Base.show(io::IO, m::Mark)
    print(io, "Mark(", m.mod, ".", m.name, ", ", repr(m.reason))
    m.since === nothing || print(io, ", since=v\"", m.since, "\"")
    m.tracking === nothing || print(io, ", tracking=", repr(m.tracking))
    return print(io, ")")
end

function Base.show(io::IO, ::MIME"text/plain", m::Mark)
    println(io, m.mod, ".", m.name, " — experimental")
    println(io, "  reason:   ", m.reason)
    m.since === nothing || println(io, "  since:    v", m.since)
    m.tracking === nothing || println(io, "  tracking: ", m.tracking)
    return print(io, "  declared: ", m.file, ":", m.line)
end

# Named rather than gensym'd, so it is greppable when a query result surprises someone.
const MARKS_BINDING = :__EXPERIMENTAL_API_MARKS__

# Created by code the macro emits into the marked module, not by `Core.eval` from here: Julia
# 1.12 rejects reading a binding created earlier in the same top-level statement, which is what a
# `Core.eval`-then-`getglobal` helper does. The emitted form puts the `const` and the `push!` in
# separate statements, so the world age has advanced in between.
function _registry_of(m::Module)
    v = getglobal(m, MARKS_BINDING)
    v isa Vector{Mark} || throw(
        ArgumentError(
            "$m.$MARKS_BINDING is a $(typeof(v)), not a Vector{Mark} — two copies of " *
            "ExperimentalAPI are probably loaded at once",
        ),
    )
    return v
end

# Replaces rather than appends, so re-including a file cannot duplicate a name.
function _mark!(reg::Vector{Mark}, mk::Mark)
    i = findfirst(x -> x.name === mk.name, reg)
    if i === nothing
        push!(reg, mk)
    else
        reg[i] = mk
    end
    return mk
end

"""
    @experimental "reason" definition
    @experimental "reason" name₁ name₂ …
    @experimental "reason" since=v"0.4.0" tracking="…" definition

Declare that a public name is not settled, and say why.

The reason is required and comes first. Everything after it is either **one definition** or **a
list of names** already defined elsewhere:

```julia
# attached to the definition
@experimental(
    "signature will be wrapped once the write-back refactor settles",
    function ingest(config; doc, kwargs...)
        # ...
    end,
)

# declared for names defined in an included file
@experimental(
    "reads Test's internal result tree; not dogfooded in CI",
    render_test_report,
    dump_test_report,
    load_test_dump,
)
```

Optional `since=` and `tracking=` come between the reason and the subject. `tracking` is what
turns a mark into something a reader can act on: the issue or PR where the shape is being
decided.

Attaches to `function`, short-form `f(x) = …`, `struct`, `mutable struct`, `abstract type`,
`primitive type`, `macro` (recorded as `Symbol("@name")`), `const`, and plain assignment.
Anything else — a `module` (which Julia requires as a direct top-level statement, so it cannot be
wrapped), a definition produced by another macro, a qualified `Base.foo(…)` method — is rejected
with a message pointing at the name-list form, because guessing which name such an expression
defines is exactly the kind of silence this package exists to remove.

Marking is not visibility: a marked name still has to be `export`ed or declared `public` to be
part of the surface. A mark on a name that is neither is reported by [`audit`](@ref) as
`dangling`.

# What gets observed

A definition **with a body** — `function` and short-form `f(x) = …`, including parametric and
return-type-annotated signatures — also gets a flag in that body, so [`entered`](@ref) can report
whether the run went through it. The flag is one short-circuit read: `1.03x` on one thread and
`0.985x` on eight, measured over 10M calls of a numeric body.

Every other form is a **declaration only** — recorded, queryable and audited, but not observed:

| form | observed? |
|---|---|
| `function f(x) … end`, `f(x) = …`, `f(x::T) where {T} = …`, `f(x)::R = …` | yes |
| a name list (`@experimental "…" a b c`) | no — those definitions are elsewhere and already compiled |
| `struct`, `abstract type`, `primitive type`, `const`, assignment | no — nothing is *entered* |
| `macro` | no |
| `@generated function` | refused outright, as any macro-produced definition is; the name-list form takes it, as a declaration |

One flag per marked **name**, not per method: marks are name-keyed, so two methods of a marked
name share it.

!!! note "Top level only"
    The mark is stored in a `const` binding in the enclosing module, so `@experimental` belongs
    at module top level — the same place `export` and `public` go.

See also [`experimental`](@ref), [`audit`](@ref), [`stable`](@ref).
"""
macro experimental(args...)
    isempty(args) && throw(
        ArgumentError(
            "@experimental needs a reason and something to mark: @experimental \"why\" f",
        ),
    )
    reason = args[1]
    if reason isa AbstractString && isempty(strip(reason))
        throw(
            ArgumentError("@experimental: the reason may not be empty — it is the payload")
        )
    end
    if reason isa Symbol || (reason isa Expr && reason.head in (:function, :struct, :macro))
        throw(
            ArgumentError(
                "@experimental: the reason comes first — @experimental \"why\" $(_short(reason))",
            ),
        )
    end

    rest = args[2:end]
    isempty(rest) &&
        throw(ArgumentError("@experimental: nothing to mark — give a definition or a name"))

    # The last argument is always the subject, which keeps `@experimental "…" x = 3` unambiguous
    # against `@experimental "…" since=v"1" x = 3`.
    since, tracking, i = nothing, nothing, 1
    while i < length(rest)
        a = rest[i]
        if a isa Expr &&
            a.head === :(=) &&
            a.args[1] isa Symbol &&
            a.args[1] in (:since, :tracking)
            a.args[1] === :since ? (since = a.args[2]) : (tracking = a.args[2])
            i += 1
        else
            break
        end
    end
    subject = rest[i:end]

    if length(subject) == 1 &&
        subject[1] isa Expr &&
        subject[1].head === :(=) &&
        subject[1].args[1] isa Symbol &&
        subject[1].args[1] in (:since, :tracking)
        throw(
            ArgumentError(
                "@experimental: `$(subject[1].args[1])=…` given but no name to mark"
            ),
        )
    end

    names = _subject_names(subject)
    def = nothing
    if names === nothing
        length(subject) == 1 || throw(
            ArgumentError(
                "@experimental: expected one definition, or a list of bare names — got " *
                "$(length(subject)) arguments of which `$(_short(subject[findfirst(x -> !(x isa Symbol), subject)]))` is not a name",
            ),
        )
        def = subject[1]
        names = [_defname(def)]
    end

    # The `const` must land in its own top-level statement: the `_mark!` calls below read that
    # binding, and Julia 1.12 forbids reading one created in the same world age.
    marks = esc(MARKS_BINDING)
    src = __source__
    # Built with `Expr` so no `LineNumberNode` from this file reaches the expansion. `const` in
    # local scope is a lowering error this macro cannot catch, so the only lever is where the
    # error points, and it must point at the caller. Pinned in `test_spec_forms.jl`.
    init = Expr(
        :if,
        :(!$(isdefined)($__module__, $(QuoteNode(MARKS_BINDING)))),
        Expr(:block, src, Expr(:const, Expr(:(=), marks, :($(Mark)[])))),
    )
    records = [
        :($(_mark!)(
            $marks,
            $(Mark)(
                $__module__,
                $(QuoteNode(n)),
                $(_reason)($(esc(reason))),
                $(since === nothing ? nothing : esc(since)),
                $(tracking === nothing ? nothing : esc(tracking)),
                $(QuoteNode(src.file)),
                $(src.line),
            ),
        )) for n in names
    ]
    # The default layer's flag, one per marked name, and the probe that sets it. Only a
    # definition with a body can carry one; a name list, a struct, a const, a module or a
    # `@generated` function is a declaration this package cannot observe. `_instrument` returns
    # `nothing` for those and the definition goes out untouched.
    flags = Expr[]
    instrumented = def
    if def !== nothing
        # The `const` is emitted on its own, so it needs escaping here; the probe rides inside
        # the definition, which is escaped as a whole below — escaping it twice is an error.
        flagsym = _flag_name(names[1])
        push!(
            flags,
            Expr(
                :if,
                :(!$(isdefined)($__module__, $(QuoteNode(flagsym)))),
                Expr(
                    :block,
                    src,
                    Expr(
                        :const, Expr(:(=), esc(flagsym), :($(Base.RefValue{Bool})(false)))
                    ),
                ),
            ),
        )
        probed = _instrument(def, flagsym)
        probed === nothing || (instrumented = probed)
    end
    # Tells the documentation system which expression a preceding docstring belongs to, as
    # `Base.@kwdef` does. Without it a docstring on a marked definition fails to attach at all.
    body = if instrumented === nothing
        nothing
    else
        Expr(:block, Expr(:meta, :doc), esc(instrumented))
    end
    return Expr(:block, init, flags..., body, records..., nothing)
end

# Normalises whitespace so a wrapped triple-quoted reason does not carry its indentation into
# every message. Nothing else about the text is touched.
function _reason(s)
    r = String(strip(s))
    isempty(r) && throw(
        ArgumentError("@experimental: the reason may not be empty — it is the payload")
    )
    return r
end

# `nothing` means "not a name list" — i.e. the subject is a definition to attach to.
function _subject_names(subject)
    names = Symbol[]
    for a in subject
        if a isa Symbol
            push!(names, a)
        elseif a isa Expr &&
            a.head === :macrocall &&
            a.args[1] isa Symbol &&
            length(a.args) == 2 &&
            a.args[2] isa LineNumberNode
            # A bare `@foo` is a name; a macrocall carrying arguments is a definition this macro
            # cannot read, and must fall through to be refused rather than recorded.
            push!(names, a.args[1])
        elseif a isa QuoteNode && a.value isa Symbol
            push!(names, a.value)              # `:foo`, for a name a reader prefers to quote
        else
            return nothing
        end
    end
    return names
end

_short(ex) = (s=string(ex); length(s) > 40 ? first(s, 37) * "..." : s)

_defname(s::Symbol) = s
function _defname(ex::Expr)
    h = ex.head
    h === :function && return _signame(ex.args[1])
    h === :(=) && return _signame(ex.args[1])
    h === :macro && return Symbol("@", _signame(ex.args[1]))
    h === :struct && return _typename(ex.args[2])
    h === :abstract && return _typename(ex.args[1])
    h === :primitive && return _typename(ex.args[1])
    h === :const && return _defname(ex.args[1])
    # Julia requires `module` as a direct top-level statement, so it cannot be wrapped and takes
    # the name-list form.
    h === :module && throw(
        ArgumentError(
            "@experimental cannot attach to a `module`, which Julia requires at top level. " *
            "Name it instead: @experimental \"why\" $(ex.args[2])",
        ),
    )
    h === :macrocall && throw(
        ArgumentError(
            "@experimental cannot see what `$(ex.args[1])` defines. Name it instead: " *
            "@experimental \"why\" the_name",
        ),
    )
    return throw(
        ArgumentError(
            "@experimental cannot read a `$h` expression as a definition. Name it instead: " *
            "@experimental \"why\" the_name",
        ),
    )
end
function _defname(x)
    return throw(
        ArgumentError("@experimental: `$(_short(x))` is neither a name nor a definition")
    )
end

_signame(s::Symbol) = s
function _signame(ex::Expr)
    h = ex.head
    (h === :call || h === :where || h === :(::) || h === :curly) &&
        return _signame(ex.args[1])
    h === :. && throw(
        ArgumentError(
            "@experimental: `$(_short(ex))` defines a name owned by another module, which is " *
            "not part of this module's public surface",
        ),
    )
    return throw(ArgumentError("@experimental: cannot read a name out of `$(_short(ex))`"))
end
function _signame(x)
    return throw(ArgumentError("@experimental: cannot read a name out of `$(_short(x))`"))
end

_typename(s::Symbol) = s
function _typename(ex::Expr)
    h = ex.head
    (h === :curly || h === :<:) && return _typename(ex.args[1])
    return throw(
        ArgumentError("@experimental: cannot read a type name out of `$(_short(ex))`")
    )
end
function _typename(x)
    return throw(
        ArgumentError("@experimental: cannot read a type name out of `$(_short(x))`")
    )
end
