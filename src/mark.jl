# The mark itself: what one `@experimental` declaration records, where it is stored, and the
# macro that writes it.
#
# Storage is a `const` vector inside the MARKED module, not a table inside this one. That is not
# a style choice — a registry living here would be populated while the marked package is being
# precompiled, and nothing written into a third module at that moment is part of the cache image
# that gets loaded later. Base's own `Docs.META` is a per-module binding for exactly this reason,
# and `test/test_precompile.jl` is the test that would catch it if this stopped being true.

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

# The binding every marked module gets. Named, not gensym'd, so `M.__EXPERIMENTAL_API_MARKS__`
# is greppable and inspectable when a query result surprises someone.
const MARKS_BINDING = :__EXPERIMENTAL_API_MARKS__

# The registry is created by code the macro emits INTO the marked module — not by `Core.eval`
# from here. The difference is not stylistic. Julia 1.12 rejects reading a binding that was
# created earlier in the same top-level statement ("define the const at top-level before running
# the function that uses it"), and a `Core.eval`-then-`getglobal` helper does exactly that. The
# emitted form puts the `const` in one top-level statement and the `push!` in the next, so the
# world age has advanced in between and the read is legal.
#
# `@macroexpand` therefore shows the whole mechanism, which is the second reason to prefer it.
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

# Re-marking a name replaces its entry instead of appending, so re-including a file (Revise, an
# `include` reached twice) cannot make one name appear in `experimental(M)` several times.
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

The reason is required and comes first. Everything after it is either **one definition** — which
is emitted unchanged, so this costs nothing at run time — or **a list of names** already defined
elsewhere:

```julia
# attached to the definition
@experimental "signature will be wrapped once the write-back refactor settles" \
function ingest(config; doc, kwargs...)
    # ...
end

# declared for names defined in an included file
@experimental "reads Test's internal result tree; not dogfooded in CI" \
    render_test_report dump_test_report load_test_dump
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

    # `k = v` pairs bind tighter than the subject only when they are NOT the last argument: the
    # last argument is always the thing being marked, which keeps `@experimental "…" x = 3`
    # unambiguous against `@experimental "…" since=v"1" x = 3`.
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

    # Statement order carries a constraint: the `const` must land in its own top-level statement,
    # because the `_mark!` calls below READ that binding and Julia 1.12 forbids reading a binding
    # created in the same world age.
    marks = esc(MARKS_BINDING)
    init = :(
        if !$(isdefined)($__module__, $(QuoteNode(MARKS_BINDING)))
            const $marks = $(Mark)[]
        end
    )
    src = __source__
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
    # `Expr(:meta, :doc)` is how a macro tells the documentation system which expression inside
    # its expansion a preceding docstring belongs to — the mechanism `Base.@kwdef` uses. Without
    # it, `"""docs""" @experimental "why" f(x) = x` fails with "cannot document the following
    # expression", which would make the two accounts this package asks for mutually exclusive.
    body = def === nothing ? nothing : Expr(:block, Expr(:meta, :doc), esc(def))
    return Expr(:block, init, body, records..., nothing)
end

# Whitespace is normalised so a reason written as a wrapped triple-quoted string does not carry
# its indentation into every message that prints it. Nothing else about the text is touched.
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
            # A BARE `@foo` — the name a macro is public under. A macrocall carrying arguments
            # is a definition this macro cannot read, not a name, and must fall through to be
            # refused rather than silently recorded as `Symbol("@doc")`.
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
    # A `module` cannot be flattened out of the block this macro emits — Julia requires it as a
    # direct top-level statement — so it takes the name-list form rather than being wrapped.
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
