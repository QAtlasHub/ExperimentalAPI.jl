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
| `mod::Module` | the module that **wrote** the mark, and where it is stored |
| `name::Symbol` | the marked name; a macro is stored as `Symbol("@foo")` |
| `reason::String` | why it is not settled |
| `since::Union{VersionNumber,Nothing}` | version the name has been experimental since |
| `tracking::Union{String,Nothing}` | where the shape is being decided — an issue, PR, or URL |
| `file::Symbol`, `line::Int` | where the declaration is written |
| `sig::Union{Type,Nothing}` | the signature it attached to, or `nothing` for a whole-name claim |
| `includes_constructors::Bool` | a type's constructors are covered by its mark |
| `until::Union{Function,Nothing}` | the exit condition — see [`ready_to_promote`](@ref) |

`sig` is what makes the claim narrower than the name. A mark attached to `energy(::Numerical)`
says the *name* has something unsettled about it — [`audit`](@ref) reads it that way — while
[`reach`](@ref) resolves calls to a method and only reports the marked one. A mark with
`sig === nothing` (a name list, a `struct`, a `const`) covers every method the name has.

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
    sig::Union{Type,Nothing}
    includes_constructors::Bool
    until::Union{Function,Nothing}

    # The reason is the payload, so the invariant belongs in the type: `Mark` is `public`, and
    # every construction route that is not the macro gets it for free here.
    function Mark(
        mod,
        name,
        reason,
        since,
        tracking,
        file,
        line,
        sig=nothing,
        includes_constructors=false,
        until=nothing,
    )
        r = String(strip(reason))
        isempty(r) &&
            throw(ArgumentError("a Mark's reason may not be empty — it is the payload"))
        return new(
            mod, name, r, since, tracking, file, line, sig, includes_constructors, until
        )
    end
end

"""
    Mark(mod, name, reason; since, tracking, file, line, sig, includes_constructors, until)

Keyword form, for the fields that are usually absent. The positional form takes them in the order
of the table in [`Mark`](@ref).
"""
function Mark(
    mod::Module,
    name::Symbol,
    reason::AbstractString;
    since=nothing,
    tracking=nothing,
    file::Symbol=:none,
    line::Int=0,
    sig=nothing,
    includes_constructors::Bool=false,
    until=nothing,
)
    return Mark(
        mod, name, reason, since, tracking, file, line, sig, includes_constructors, until
    )
end

# `until` holds a closure, and `==` on two closures of the same source is identity, so the
# default field-wise equality would report two identical declarations as different. Equality is
# over what the mark SAYS; the exit predicate is compared by whether it is present.
function Base.:(==)(a::Mark, b::Mark)
    return a.mod === b.mod &&
           a.name === b.name &&
           a.reason == b.reason &&
           a.since == b.since &&
           a.tracking == b.tracking &&
           a.file === b.file &&
           a.line == b.line &&
           a.sig === b.sig &&
           a.includes_constructors == b.includes_constructors &&
           (a.until === nothing) == (b.until === nothing)
end

function Base.hash(m::Mark, h::UInt)
    h = hash(m.mod, h)
    h = hash(m.name, h)
    h = hash(m.reason, h)
    h = hash(m.since, h)
    h = hash(m.tracking, h)
    h = hash(m.sig, h)
    return hash(m.line, h)
end

"""
    isnamewide(mk::Mark) -> Bool

Whether `mk` claims the whole name rather than one signature.

`true` for a name list, a `struct`, a `const`, a module — the forms that carry no signature.
A mark attached to a definition knows which method it created and is therefore narrower; see
[`stable`](@ref) for where the difference is load-bearing.
"""
isnamewide(mk::Mark) = mk.sig === nothing

function Base.show(io::IO, m::Mark)
    print(io, "Mark(", m.mod, ".", m.name, ", ", repr(m.reason))
    m.sig === nothing || print(io, ", sig=", m.sig)
    m.since === nothing || print(io, ", since=v\"", m.since, "\"")
    m.tracking === nothing || print(io, ", tracking=", repr(m.tracking))
    return print(io, ")")
end

function Base.show(io::IO, ::MIME"text/plain", m::Mark)
    println(io, m.mod, ".", m.name, " — experimental")
    println(io, "  reason:   ", m.reason)
    m.sig === nothing || println(io, "  signature: ", m.sig)
    m.since === nothing || println(io, "  since:    v", m.since)
    m.tracking === nothing || println(io, "  tracking: ", m.tracking)
    m.until === nothing || println(io, "  until:    an exit condition is recorded")
    return print(io, "  declared: ", m.file, ":", m.line)
end

# Named rather than gensym'd, so they are greppable when a query result surprises someone.
const MARKS_BINDING = :__EXPERIMENTAL_API_MARKS__
const SUPERSEDED_BINDING = :__EXPERIMENTAL_API_SUPERSEDED__

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

_has_registry(m::Module) = isdefined(m, MARKS_BINDING)

# The superseded log is created on the first replacement rather than emitted by the macro: most
# modules never supersede a mark, and an empty binding in every marked module would be noise in
# `names(m; all=true)`. `Core.eval` is safe here because the value is used through the return
# value, never by reading the binding back in the same world age.
function _superseded_registry!(m::Module)
    isdefined(m, SUPERSEDED_BINDING) && return getglobal(m, SUPERSEDED_BINDING)
    return Core.eval(m, Expr(:const, Expr(:(=), SUPERSEDED_BINDING, Mark[])))
end

# Replaces rather than appends, so re-including a file cannot duplicate a declaration. The key is
# the pair (name, signature): one name may carry several method-level marks, and each of them is
# a separate claim.
function _mark!(reg::Vector{Mark}, mk::Mark)
    i = findfirst(x -> x.name === mk.name && x.sig === mk.sig, reg)
    if i === nothing
        push!(reg, mk)
    else
        old = reg[i]
        old == mk || push!(_superseded_registry!(mk.mod), old)
        reg[i] = mk
    end
    return mk
end

"""
    @experimental "reason" definition
    @experimental "reason" name₁ name₂ …
    @experimental "reason" since=v"0.4.0" tracking="…" until=(() -> …) definition

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

Optional keywords come between the reason and the subject:

| keyword | |
|---|---|
| `since=v"0.4.0"` | the version the name has been unsettled since — read by [`age`](@ref) |
| `tracking="…"` | the issue or PR where the shape is being decided |
| `until=() -> …` | the **exit condition**: what would discharge the reason. See [`ready_to_promote`](@ref) |

`tracking` is what turns a mark into something a reader can act on. `until` is what turns it into
a work item: a mark with no stated exit can be added but never mechanically retired, and
[`marks_without_exit`](@ref) reports those.

Attaches to `function`, short-form `f(x) = …`, a callable object `(c::C)(x) = …`, a method on
another module's generic `Base.show(io, ::T) = …`, `struct`, `mutable struct`, `abstract type`,
`primitive type`, `macro` (recorded as `Symbol("@name")`), `const`, plain assignment, and a
definition wrapped in `@inline`, `@noinline`, `@generated`, `@propagate_inbounds`,
`@assume_effects` or `Base.@kwdef`.

Anything else — a `module` (which Julia requires as a direct top-level statement, so it cannot be
wrapped), a definition produced by some other macro, a bare qualified name with no signature — is
rejected with a message pointing at the name-list form, because guessing which name such an
expression defines is exactly the kind of silence this package exists to remove.

Marking is not visibility: a marked name still has to be `export`ed or declared `public` to be
part of the surface. A mark on a name that is neither is reported by [`audit`](@ref) as
`dangling`.

# What the mark claims

A mark attached to a definition records the **signature** it created, so the claim is about that
method. A mark written as a name list, or attached to a `struct` or a `const`, carries no
signature and covers the whole name.

The difference shows up in three places: [`reach`](@ref) only reports the marked method,
[`stable`](@ref) keeps a name in the covenant until *every* method behind it is marked, and
[`audit`](@ref) reads either as "the author has said something about this name".

# What gets observed

A definition **with a body** — `function` and short-form `f(x) = …`, including parametric,
callable-object and return-type-annotated signatures — also gets a flag in that body, so
[`entered`](@ref) can report whether the run went through it. The flag is one short-circuit read:
`1.03x` on one thread and `0.985x` on eight, measured over 10M calls of a numeric body.

Every other form is a **declaration only** — recorded, queryable and audited, but not observed:

| form | observed? |
|---|---|
| `function f(x) … end`, `f(x) = …`, `f(x::T) where {T} = …`, `f(x)::R = …`, `(c::C)(x) = …` | yes |
| `Base.show(io::IO, ::T) = …` — a method on a foreign generic | yes |
| a name list (`@experimental "…" a b c`) | no — those definitions are elsewhere and already compiled |
| `struct`, `abstract type`, `primitive type`, `const`, assignment | no — nothing is *entered* |
| `macro` | no |
| `@generated function` | no — the body returns an expression, so a probe there would be generated rather than run |
| `Base.@kwdef`, `@inline`, `@noinline` and the other pass-through macros | no |

One flag per marked **name**, not per method: flags are name-keyed, so two methods of a marked
name share one.

!!! note "Top level only"
    The mark is stored in a `const` binding in the enclosing module, so `@experimental` belongs
    at module top level — the same place `export` and `public` go. Written inside a function
    body it is refused by Julia's lowering, at the line you wrote it on.

See also [`experimental`](@ref), [`audit`](@ref), [`stable`](@ref), [`reach`](@ref).
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
    isempty(rest) && throw(
        ArgumentError(
            "@experimental: nothing to mark — the reason comes first, then one definition " *
            "or a list of names: @experimental \"why\" f(x) = x",
        ),
    )

    # The last argument is always the subject, which keeps `@experimental "…" x = 3` unambiguous
    # against `@experimental "…" since=v"1" x = 3`.
    since, tracking, until, i = nothing, nothing, nothing, 1
    while i < length(rest)
        a = rest[i]
        if a isa Expr && a.head === :(=) && a.args[1] isa Symbol && a.args[1] in _KEYWORDS
            a.args[1] === :since && (since = a.args[2])
            a.args[1] === :tracking && (tracking = a.args[2])
            a.args[1] === :until && (until = a.args[2])
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
        subject[1].args[1] in _KEYWORDS
        throw(
            ArgumentError(
                "@experimental: `$(subject[1].args[1])=…` given but no name to mark"
            ),
        )
    end

    names = _subject_names(subject)
    sub = nothing
    if names === nothing
        length(subject) == 1 || throw(
            ArgumentError(
                "@experimental: expected one definition, or a list of bare names — got " *
                "$(length(subject)) arguments of which `$(_short(subject[findfirst(x -> !(x isa Symbol), subject)]))` is not a name",
            ),
        )
        sub = _subject(subject[1])
        names = [sub.name]
    end

    src = __source__
    marks = esc(MARKS_BINDING)
    # The `const` must land in its own top-level statement: the `_mark!` calls below read that
    # binding, and Julia 1.12 forbids reading one created in the same world age.
    #
    # Built with `Expr` so no `LineNumberNode` from this file reaches the expansion. `const` in
    # local scope is a lowering error this macro cannot catch, so the only lever is where the
    # error points, and it must point at the caller. Pinned in `test_spec_forms.jl`.
    init = Expr(
        :if,
        :(!$(isdefined)($__module__, $(QuoteNode(MARKS_BINDING)))),
        Expr(:block, src, Expr(:const, Expr(:(=), marks, :($(Mark)[])))),
    )

    # The default layer's flag, one per marked name, and the probe that sets it. Only a
    # definition with a body can carry one; a name list, a struct, a const, a module or a
    # `@generated` function is a declaration this package cannot observe.
    flags = Expr[]
    emitted = sub === nothing ? nothing : sub.def
    if sub !== nothing && sub.instrumentable
        # The `const` is emitted on its own, so it needs escaping here; the probe rides inside
        # the definition, which is escaped as a whole below — escaping it twice is an error.
        flagsym = _flag_name(sub.name)
        push!(
            flags,
            Expr(
                :if,
                :(!$(isdefined)($__module__, $(QuoteNode(flagsym)))),
                Expr(
                    :block,
                    src,
                    Expr(
                        :const,
                        Expr(
                            :(=),
                            esc(flagsym),
                            :($(Probe)($__module__, $(QuoteNode(sub.name)))),
                        ),
                    ),
                ),
            ),
        )
        probed = _instrument(sub.def, flagsym, src)
        probed === nothing || (emitted = probed)
    end

    # Tells the documentation system which expression a preceding docstring belongs to, as
    # `Base.@kwdef` does. Without it a docstring on a marked definition fails to attach at all.
    body = emitted === nothing ? nothing : Expr(:block, Expr(:meta, :doc), esc(emitted))

    # The signature is read back from the method table AFTER the definition has run: the macro
    # sees argument types as syntax, and `Tuple{typeof(f), Numerical}` cannot be built out of
    # syntax without evaluating names this module may not have yet.
    sigexpr = sub === nothing ? nothing : sub.sigexpr
    records = [
        :($(_mark!)(
            $marks,
            $(Mark)(
                $__module__,
                $(QuoteNode(n)),
                $(_reason)($(esc(reason))),
                $(since === nothing ? nothing : :($(_since)($(esc(since))))),
                $(tracking === nothing ? nothing : :($(_tracking)($(esc(tracking))))),
                $(QuoteNode(src.file)),
                $(src.line),
                $(sigexpr === nothing ? nothing : sigexpr),
                $(sub === nothing ? false : sub.includes_constructors),
                $(until === nothing ? nothing : :($(_until)($(esc(until))))),
            ),
        )) for n in names
    ]
    return Expr(:block, init, flags..., body, records..., nothing)
end

const _KEYWORDS = (:since, :tracking, :until)

# Normalises whitespace so a wrapped triple-quoted reason does not carry its indentation into
# every message. Nothing else about the text is touched.
function _reason(s::AbstractString)
    r = String(strip(s))
    isempty(r) && throw(
        ArgumentError("@experimental: the reason may not be empty — it is the payload")
    )
    return r
end
function _reason(@nospecialize(x))
    return throw(
        ArgumentError(
            "@experimental: the reason must be a string, got a $(typeof(x)) — " *
            "@experimental \"why\" f(x) = x",
        ),
    )
end

_since(v::VersionNumber) = v
function _since(@nospecialize(x))
    return throw(
        ArgumentError(
            "@experimental: `since` must be a VersionNumber, got a $(typeof(x)) — " *
            "write since=v\"$(x)\" rather than since=$(repr(x))",
        ),
    )
end

_tracking(s::AbstractString) = String(s)
function _tracking(@nospecialize(x))
    return throw(
        ArgumentError(
            "@experimental: `tracking` must be a string — an issue, a pull request or a URL, " *
            "got a $(typeof(x))",
        ),
    )
end

_until(f::Function) = f
function _until(@nospecialize(x))
    return throw(
        ArgumentError(
            "@experimental: `until` must be a predicate taking no arguments — the condition " *
            "that would discharge the reason, e.g. until=() -> isfile(reference_path), got " *
            "a $(typeof(x))",
        ),
    )
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

# What the macro learned from one definition: the name to record it under, the expression to emit,
# whether a probe can ride in the body, and how to read the created method's signature back at
# load time.
struct _Subject
    name::Symbol
    def::Any
    instrumentable::Bool
    sigexpr::Any
    includes_constructors::Bool
end

# Macros known to hand their definition through unchanged. An allowlist rather than "unwrap the
# last argument of any macrocall": `@deprecate old new` also ends in something name-shaped, and
# marking the wrong symbol silently is the failure this package exists to remove.
#
# Split by whether the body underneath is still a body. `@inline` and its neighbours annotate a
# definition and leave the body alone, so the probe can ride inside and the definition is
# observed. `@generated`'s body returns an expression — a probe there would be generated rather
# than run — and `Base.@kwdef` wraps a struct, which has no body at all.
const _ANNOTATING_MACROS = (
    Symbol("@inline"),
    Symbol("@noinline"),
    Symbol("@propagate_inbounds"),
    Symbol("@assume_effects"),
    Symbol("@constprop"),
    Symbol("@nospecializeinfer"),
)
const _OPAQUE_MACROS = (Symbol("@generated"), Symbol("@kwdef"))

_macroname(x::Symbol) = x
_macroname(x::Expr) = x.head === :. ? _macroname(x.args[2]) : Symbol("")
_macroname(x::QuoteNode) = x.value isa Symbol ? x.value : Symbol("")
_macroname(@nospecialize(x)) = Symbol("")

function _subject(ex)
    if ex isa Expr && ex.head === :macrocall
        mname = _macroname(ex.args[1])
        if mname in _ANNOTATING_MACROS
            # The annotation is kept, and the probe goes inside the definition it annotates — an
            # `@inline` marked kernel is exactly the kind that has to be observable.
            s = _subject(ex.args[end])
            wrapped = Expr(:macrocall, ex.args[1:(end - 1)]..., s.def)
            return _Subject(
                s.name, wrapped, s.instrumentable, s.sigexpr, s.includes_constructors
            )
        end
        if mname in _OPAQUE_MACROS
            # The wrapping macro stays in charge of the definition, so nothing is spliced into a
            # body it is about to rewrite.
            s = _subject(ex.args[end])
            return _Subject(s.name, ex, false, s.sigexpr, s.includes_constructors)
        end
        throw(
            ArgumentError(
                "@experimental cannot see what `$(ex.args[1])` defines. Name it instead: " *
                "@experimental \"why\" the_name",
            ),
        )
    end
    return _plain_subject(ex)
end

function _plain_subject(ex)
    ex isa Symbol && return _Subject(ex, ex, false, nothing, false)
    ex isa Expr || throw(
        ArgumentError("@experimental: `$(_short(ex))` is neither a name nor a definition"),
    )
    h = ex.head
    if h === :function || h === :(=)
        sig = ex.args[1]
        _is_signature(sig) || return _Subject(_defname(ex), ex, false, nothing, false)
        callee = _callee(sig)
        return _Subject(callee.name, ex, length(ex.args) == 2, _sigexpr(callee), false)
    end
    h === :struct && return _Subject(_typename(ex.args[2]), ex, false, nothing, true)
    h === :abstract && return _Subject(_typename(ex.args[1]), ex, false, nothing, true)
    h === :primitive && return _Subject(_typename(ex.args[1]), ex, false, nothing, true)
    h === :macro &&
        return _Subject(Symbol("@", _signame(ex.args[1])), ex, false, nothing, false)
    h === :const && return _Subject(_defname(ex.args[1]), ex, false, nothing, false)
    return _Subject(_defname(ex), ex, false, nothing, false)
end

# The pieces of a call signature the macro needs: the name to record, and an expression that
# evaluates — in the caller's module, after the definition has run — to the function TYPE whose
# newest method is the one just defined.
struct _Callee
    name::Symbol
    ftype::Any        # an expression, already escaped
end

_sigexpr(c::_Callee) = :($(_newest_sig)($(c.ftype)))

function _callee(sig)
    if sig isa Expr && (sig.head === :where || sig.head === :(::))
        # `f(x)::R` and `f(x) where {T}` both wrap the call; a lone `(c::C)` does not.
        inner = sig.args[1]
        (inner isa Expr && (inner.head in (:call, :where, :(::)))) && return _callee(inner)
    end
    if sig isa Expr && sig.head === :call
        f = sig.args[1]
        if f isa Symbol
            return _Callee(f, :($(_ftype_of)($(esc(f))))) # `f(x)` — a name in this module
        elseif f isa Expr && f.head === :.
            # `Base.show(io, ::T)` — a method on somebody else's generic. The name is theirs, so
            # this records a claim about the signature and not about their surface.
            return _Callee(_qualified_name(f), :($(_ftype_of)($(esc(f)))))
        elseif f isa Expr && f.head === :(::)
            # `(c::C)(x)` and `(::Type{C})(x)` — the callable object IS the function type.
            t = length(f.args) == 2 ? f.args[2] : f.args[1]
            return _Callee(_typename(t), :($(_ftype_self)($(esc(_typebase(t))))))
        elseif f isa Expr && f.head === :curly
            # `T{P}(x) = …` — a parametric constructor.
            return _Callee(_typename(f), :($(_ftype_of)($(esc(_typebase(f))))))
        end
        throw(ArgumentError("@experimental: cannot read a name out of `$(_short(sig))`"))
    end
    return throw(ArgumentError("@experimental: cannot read a name out of `$(_short(sig))`"))
end

# `x isa Type ? Type{x} : typeof(x)` — a name in call position is either a function or a type
# constructor, and the two need different function types to look the method up under.
_ftype_of(@nospecialize(x)) = x isa Type ? Type{x} : typeof(x)
# A callable object's own type IS the function type: `(c::C)(x)` defines `Tuple{C, Any}`.
_ftype_self(@nospecialize(x)) = x isa Type ? x : typeof(x)

"""
    _newest_sig(ftype) -> Union{Type,Nothing}

The signature of the most recently defined method under `ftype`.

Called from the statement the macro emits immediately after the definition, so "most recent" is
the method that definition just created. Reading it back from the method table is the only route:
the macro sees `::Numerical` as syntax, and building `Tuple{typeof(f), Numerical}` out of syntax
would mean evaluating names in a module that may not have them yet.

Returns `nothing` rather than throwing if the lookup fails — a mark that loses its signature is a
wider claim, never a wrong one, and a package must not fail to load over it.
"""
function _newest_sig(@nospecialize(ft))
    try
        ms = Base._methods_by_ftype(Tuple{ft,Vararg{Any}}, -1, Base.get_world_counter())
        (ms === nothing || ms === false) && return nothing
        best = nothing
        for match in ms
            m = match.method
            (best === nothing || m.primary_world > best.primary_world) && (best = m)
        end
        return best === nothing ? nothing : best.sig
    catch
        return nothing
    end
end

function _is_signature(x)
    return x isa Expr && (
        x.head === :call ||
        ((x.head === :where || x.head === :(::)) && _is_signature(x.args[1]))
    )
end

function _qualified_name(ex::Expr)
    n = ex.args[2]
    n isa QuoteNode && n.value isa Symbol && return n.value
    n isa Symbol && return n
    return throw(ArgumentError("@experimental: cannot read a name out of `$(_short(ex))`"))
end

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
    # A bare `Base.show` names every method of that generic in the world, including ones this
    # package never wrote. Guessing is worse than refusing.
    h === :. && throw(
        ArgumentError(
            "@experimental: `$(_short(ex))` names another module's generic without saying " *
            "WHICH method — mark the definition instead: " *
            "@experimental \"why\" $(_short(ex))(::MyType) = …",
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
function _defname(@nospecialize(x))
    return throw(
        ArgumentError("@experimental: `$(_short(x))` is neither a name nor a definition")
    )
end

_signame(s::Symbol) = s
function _signame(ex::Expr)
    h = ex.head
    (h === :call || h === :where || h === :curly) && return _signame(ex.args[1])
    if h === :(::)
        inner = ex.args[1]
        # `f(x)::R` annotates the return type — the name is inside. A lone `(c::C)` or `(::T)`
        # is a callable object, and the name that means anything to a reader is the TYPE.
        (inner isa Expr && inner.head in (:call, :where, :curly)) && return _signame(inner)
        return _typename(length(ex.args) == 2 ? ex.args[2] : ex.args[1])
    end
    h === :. && return _qualified_name(ex)
    return throw(ArgumentError("@experimental: cannot read a name out of `$(_short(ex))`"))
end
function _signame(@nospecialize(x))
    return throw(ArgumentError("@experimental: cannot read a name out of `$(_short(x))`"))
end

_typename(s::Symbol) = s
function _typename(ex::Expr)
    h = ex.head
    # `Type{C}` in `(::Type{C})(x)` — the name a reader recognises is `C`.
    h === :curly &&
        ex.args[1] === :Type &&
        length(ex.args) == 2 &&
        return _typename(ex.args[2])
    (h === :curly || h === :<:) && return _typename(ex.args[1])
    h === :. && return _qualified_name(ex)
    return throw(
        ArgumentError("@experimental: cannot read a type name out of `$(_short(ex))`")
    )
end
function _typename(@nospecialize(x))
    return throw(
        ArgumentError("@experimental: cannot read a type name out of `$(_short(x))`")
    )
end

# The expression naming the type itself, with any parameters dropped: `C{T}` is looked up under
# `C`, because `T` is a type variable bound by the `where` and means nothing at load time.
_typebase(s::Symbol) = s
function _typebase(ex::Expr)
    ex.head === :curly &&
        ex.args[1] === :Type &&
        length(ex.args) == 2 &&
        return :(Type{$(_typebase(ex.args[2]))})
    ex.head === :curly && return _typebase(ex.args[1])
    ex.head === :<: && return _typebase(ex.args[1])
    return ex
end
