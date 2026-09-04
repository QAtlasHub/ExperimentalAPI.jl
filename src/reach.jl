# A caller that never names a marked thing still depends on it.
#
# Modelled on Lean's `sorry`, but Julia's call graph is not closed, so the answer is three-valued:
#
#     :depends   a marked definition is reachable
#     :clean     the whole call graph was resolved and nothing marked is in it
#     :unknown   some call site could not be resolved — the honest non-answer
#
# Collapsing `:unknown` into `:clean` is the one failure this file exists to prevent. It is not a
# weaker claim, it is a false one: `Holder.f::Function` and `TABLE[i](x)` really can reach a
# marked function while being statically invisible.
#
# The walk is over INFERRED, UNOPTIMISED IR — `code_typed_by_type(sig; optimize=false)`. Inference
# runs before inlining, so every call is still a call and every argument still has a type;
# `optimize=true` would show `mul_float` and find nothing. That also makes the two hard cases fall
# out rather than needing special handling: a callee inference typed as `Function` is exactly a
# call site with no unique method, and a function passed as a value is specialised on `typeof(f)`
# and resolves.

"""
    Unresolved

One call site the analysis could not pin to a method.

| field | |
|---|---|
| `callee` | the name being called, as far as the IR knows it |
| `signature` | what it was called with — the widened argument types |
| `why` | `:dynamic`, `:ambiguous`, `:maxdepth`, `:splat` or `:nomethod` |
| `file`, `line` | where to go and look |
| `within` | the method the call site is in |
| `candidates` | the marked methods this site *could* reach, if any are visible |

"Cannot tell" is only actionable if the reader can go and look, which is what `file`/`line` are
for. `candidates` is the difference between "some call here is dynamic" and "this call could go
to `k(::KB)`, which is marked".
"""
struct Unresolved
    callee::Symbol
    signature::Any
    why::Symbol
    file::Symbol
    line::Int
    within::Union{Method,Nothing}
    candidates::Vector{Mark}
end

function Base.show(io::IO, u::Unresolved)
    return print(io, "Unresolved(", u.callee, ", ", u.why, ", ", u.file, ":", u.line, ")")
end

"""
    Reached

One marked definition the analysis proved reachable from the entry point.

`method` is the method that was resolved — `nothing` when the dependency is not a call, which is
what a marked `const` is. `path` is the chain of names from the entry point down to it, so the
reader learns which of their own code to distrust rather than only that something is wrong.
"""
struct Reached
    mark::Mark
    method::Union{Method,Nothing}
    file::Symbol
    line::Int
    path::Vector{Symbol}
end

function Base.show(io::IO, r::Reached)
    return print(
        io, "Reached(", r.mark.mod, ".", r.mark.name, " via ", join(r.path, " → "), ")"
    )
end

"""
    Reach

What [`reach`](@ref) found.

| field | |
|---|---|
| `entry` | what was analysed |
| `reached` | the marked definitions proved reachable |
| `unresolved` | the call sites that could not be pinned to a method |
| `through_modules` | every module the walk went through |
| `affected_entries` | for a module or script entry: the public entry points that are not clean |
| `visited` | how many distinct signatures were inferred |
| `truncated` | whether a depth limit stopped the walk |

There is deliberately **no** `verdict` field. A stored verdict makes `:clean` with a non-empty
`unresolved` representable, and that state is the single thing this analysis must never report.
[`verdict`](@ref) derives it instead, the way [`isbreaking`](@ref) derives its answer from a
[`Diff`](@ref).
"""
struct Reach
    entry::Any
    reached::Vector{Reached}
    unresolved::Vector{Unresolved}
    through_modules::Vector{Module}
    affected_entries::Vector{NamedTuple{(:name, :verdict),Tuple{Symbol,Symbol}}}
    visited::Int
    truncated::Bool
end

"""
    verdict(r::Reach) -> Symbol

`:depends`, `:unknown` or `:clean`, derived from what [`reach`](@ref) found.

  * `:depends` — a marked definition is reachable. Proved, not suspected.
  * `:clean` — the whole call graph was resolved and nothing marked is in it.
  * `:unknown` — at least one call site could not be pinned to a method, and nothing marked was
    proved reachable through the rest.

`:depends` wins over `:unknown`: an unresolvable call elsewhere does not make a proved dependency
less proved. `:unknown` wins over `:clean`, which is the whole point.
"""
function verdict(r::Reach)
    isempty(r.reached) || return :depends
    isempty(r.unresolved) || return :unknown
    return :clean
end

"""
    isclean(r::Reach) -> Bool

Whether [`verdict`](@ref) is `:clean`. `false` for `:unknown` as well as for `:depends` — the
predicate answers "may I rely on this", and the honest non-answer is not a yes.
"""
isclean(r::Reach) = verdict(r) === :clean

"""
    combine(a::Symbol, b::Symbol) -> Symbol

Fold two verdicts into one: `:clean` < `:unknown` < `:depends`.

Needed because [`reach`](@ref) on a module folds one answer per public entry point into one
answer for the module. Commutative and associative, so the order the entry points come back in
cannot change the result.
"""
function combine(a::Symbol, b::Symbol)
    return _verdict_rank(a) >= _verdict_rank(b) ? a : b
end

function _verdict_rank(v::Symbol)
    v === :depends && return 2
    v === :unknown && return 1
    v === :clean && return 0
    return throw(
        ArgumentError("not a verdict: $(repr(v)) — expected :clean, :unknown or :depends")
    )
end

# The walk's mutable state, so the recursion carries one argument instead of six.
mutable struct _Walk
    world::UInt
    maxdepth::Int
    maxcandidates::Int
    ignore::Set{Symbol}
    visited::Set{Any}
    reached::Vector{Reached}
    unresolved::Vector{Unresolved}
    modules::Vector{Module}
    marked::Dict{Method,Union{Mark,Nothing}}
    truncated::Bool
end

function _Walk(maxdepth::Int, ignore, maxcandidates::Int=16)
    return _Walk(
        Base.get_world_counter(),
        maxdepth,
        maxcandidates,
        Set{Symbol}(Symbol[ignore...]),
        Set{Any}(),
        Reached[],
        Unresolved[],
        Module[],
        Dict{Method,Union{Mark,Nothing}}(),
        false,
    )
end

"""
    reach(f, types::Type{<:Tuple}; maxdepth = 32, ignore = Symbol[]) -> Reach
    reach(m::Module; kwargs...) -> Reach

Report whether calling `f` with `types` can reach anything declared [`@experimental`](@ref) —
including through callers that never name it.

```julia
r = reach(analyse, Tuple{Model,Float64})
verdict(r) === :clean || error("depends on: ", [x.mark.name for x in r.reached])
```

The module form folds every public entry point of `m` into one answer and reports which of them
are affected in `affected_entries`: function-by-function does not scale to a package.

`ignore` names marks to treat as absent, which answers "what would removing this mark change?"
without removing it. `maxdepth` bounds the walk and `maxcandidates` bounds how many methods a
single ambiguous call site is willing to check; hitting either bound is reported as `:unknown`,
never as `:clean`.

# What it can and cannot resolve

| call site | |
|---|---|
| a named call, however deep | resolved |
| a function passed as a value | resolved — Julia specialises on `typeof(f)` |
| `@nospecialize`d callee, called with a concrete function | resolved |
| `invoke(f, Tuple{Integer}, x)` | resolved to the method `invoke` pins, not the one dispatch would pick |
| a `Union`- or abstract-typed argument with methods on both sides | **`:unknown`** — no unique method |
| a callee read out of a field or a table | **`:unknown`** |
| a marked `const` or `struct` used in the body | `:depends` |

A more specific unmarked method shadowing a marked one is resolved as what actually runs: `Int`
goes to `more_specific(::Int)` and is clean, while `UInt8` falls through to the marked
`::Integer` and is not.

!!! warning "It answers about code, not about a run"
    This is static: it says what *could* be reached. [`entered`](@ref) and [`record`](@ref) say
    what *was*. A path this reports is not necessarily taken, and a `:clean` here is only as good
    as the call graph being closed — which is what `:unknown` exists to admit.
"""
function reach(
    @nospecialize(f),
    @nospecialize(types::Type);
    maxdepth::Int=32,
    maxcandidates::Int=16,
    ignore=Symbol[],
)
    sig = Base.signature_type(f, types)
    st = _Walk(maxdepth, ignore, maxcandidates)
    matches = _matching_methods(st, sig)
    (matches === nothing || isempty(matches)) && throw(
        ArgumentError(
            "reach: no method of $(f) matches $(types) — there is nothing to analyse. " *
            "Check the entry signature against `methods($(f))`.",
        ),
    )
    for match in matches
        _enter!(st, match, 0, Symbol[])
    end
    return _finish(st, f => types, similar_entries())
end

similar_entries() = NamedTuple{(:name, :verdict),Tuple{Symbol,Symbol}}[]

function reach(m::Module; maxdepth::Int=32, maxcandidates::Int=16, ignore=Symbol[])
    st = _Walk(maxdepth, ignore, maxcandidates)
    entries = similar_entries()
    for n in surface(m)
        isdefined(m, n) || continue
        v = try
            getglobal(m, n)
        catch
            continue
        end
        (v isa Function || v isa Type) || continue
        ml = try
            methods(v)
        catch
            continue
        end
        isempty(ml) && continue
        # A FRESH walk per entry point. Sharing one `visited` set across them would make the
        # second entry that reaches a marked definition through an already-walked callee look
        # clean — the mark is real, it was simply reported under the first entry's name.
        own = _Walk(maxdepth, ignore, maxcandidates)
        for mm in ml
            mm.module === m || continue
            _enter!(own, mm, 0, Symbol[n])
        end
        _absorb!(st, own)
        vn = verdict_of(own)
        vn === :clean || push!(entries, (name=n, verdict=vn))
    end
    return _finish(st, m, entries)
end

# The same derivation `verdict` makes from a `Reach`, over the walk that produced one entry.
function verdict_of(st::_Walk)
    isempty(st.reached) || return :depends
    isempty(st.unresolved) || return :unknown
    return :clean
end

function _absorb!(into::_Walk, from::_Walk)
    append!(into.reached, from.reached)
    append!(into.unresolved, from.unresolved)
    for mod in from.modules
        mod in into.modules || push!(into.modules, mod)
    end
    union!(into.visited, from.visited)
    into.truncated |= from.truncated
    return nothing
end

function _finish(st::_Walk, @nospecialize(entry), entries)
    return Reach(
        entry,
        st.reached,
        st.unresolved,
        st.modules,
        entries,
        length(st.visited),
        st.truncated,
    )
end

"""
    reach_script(path::AbstractString; kwargs...) -> Reach

The same analysis for a **script** — a file that produces a figure rather than a package.

Top-level declarations that cannot live inside a function (`using`, `import`, `module`, `const`,
type definitions) are evaluated in a scratch module, because the analysis has to resolve the names
the script uses; everything else is analysed as one thunk. So this **loads the script's
dependencies**, and a script whose top level has side effects will have them.
"""
function reach_script(
    path::AbstractString; maxdepth::Int=32, maxcandidates::Int=16, ignore=Symbol[]
)
    isfile(path) || throw(ArgumentError("reach_script: no such file: $path"))
    ex = Meta.parseall(read(path, String); filename=path)
    scratch = Module(Symbol("ReachScript_", basename(path)))
    Core.eval(scratch, :(eval(x) = Core.eval($scratch, x)))
    body = Expr(:block)
    for st in ex.args
        if st isa LineNumberNode
            push!(body.args, st)
        elseif _is_toplevel_only(st)
            Core.eval(scratch, st)
        else
            push!(body.args, st)
        end
    end
    thunk = Core.eval(scratch, Expr(:function, Expr(:call, gensym(:script)), body))
    r = reach(thunk, Tuple{}; maxdepth, maxcandidates, ignore)
    return Reach(
        path,
        r.reached,
        r.unresolved,
        r.through_modules,
        [(name=Symbol(basename(path)), verdict=verdict(r))],
        r.visited,
        r.truncated,
    )
end

function _is_toplevel_only(st)
    st isa Expr || return false
    return st.head in (
        :using,
        :import,
        :export,
        :public,
        :module,
        :const,
        :struct,
        :abstract,
        :primitive,
        :macro,
    )
end

# ── the walk ─────────────────────────────────────────────────────────────────────────────────

function _enter!(st::_Walk, match, depth::Int, path::Vector{Symbol})
    mm = match isa Method ? match : match.method
    sig = match isa Method ? match.sig : match.spec_types
    if depth > st.maxdepth
        st.truncated = true
        push!(
            st.unresolved,
            Unresolved(mm.name, sig, :maxdepth, mm.file, Int(mm.line), mm, Mark[]),
        )
        return nothing
    end
    sig in st.visited && return nothing
    push!(st.visited, sig)
    # The flag `@experimental` emits is this package's own code, and under `ignore` the walk goes
    # through it rather than stopping at the mark. Following it would report the recorder's
    # internals — `backtrace`, and everything Base does to format one — as the caller's
    # dependencies. Nothing in here is ever marked, so there is nothing to lose by stopping.
    Base.moduleroot(mm.module) === ExperimentalAPI && return nothing
    mm.module in st.modules || push!(st.modules, mm.module)

    mk = _mark_of(st, mm)
    if mk !== nothing
        push!(
            st.reached,
            Reached(mk, mm, mm.file, Int(mm.line), vcat(path, [_display_name(mm)])),
        )
        # No recursion past a mark: it is already reported, and everything under it is suspect
        # for the same reason.
        return nothing
    end
    _scan_body!(st, mm, sig, depth, vcat(path, [_display_name(mm)]))
    return nothing
end

_display_name(mm::Method) = mm.name

function _mark_of(st::_Walk, mm::Method)
    cached = get(st.marked, mm, missing)
    cached === missing || return cached
    mk = mark(mm)
    mk !== nothing && mk.name in st.ignore && (mk = nothing)
    st.marked[mm] = mk
    return mk
end

function _scan_body!(
    st::_Walk, mm::Method, @nospecialize(sig), depth::Int, path::Vector{Symbol}
)
    ci = _inferred(sig)
    ci === nothing && return nothing
    code = ci.code
    for pc in eachindex(code)
        stmt = code[pc]
        _scan_stmt!(st, ci, stmt, pc, mm, depth, path)
    end
    return nothing
end

function _scan_stmt!(
    st::_Walk, ci, @nospecialize(stmt), pc::Int, mm::Method, depth::Int, path
)
    if stmt isa GlobalRef
        _check_global!(st, stmt, mm, _line(ci, pc, mm), path)
        return nothing
    end
    stmt isa Expr || return nothing
    if stmt.head === :(=) && length(stmt.args) == 2
        return _scan_stmt!(st, ci, stmt.args[2], pc, mm, depth, path)
    end
    if stmt.head === :return || stmt.head === :gotoifnot
        for a in stmt.args
            a isa GlobalRef && _check_global!(st, a, mm, _line(ci, pc, mm), path)
        end
        return nothing
    end
    if stmt.head === :new
        for a in stmt.args
            a isa GlobalRef && _check_global!(st, a, mm, _line(ci, pc, mm), path)
        end
        return nothing
    end
    stmt.head === :call || return nothing
    for a in stmt.args
        a isa GlobalRef && _check_global!(st, a, mm, _line(ci, pc, mm), path)
    end
    return _resolve_call!(st, ci, stmt, pc, mm, depth, path)
end

function _resolve_call!(st::_Walk, ci, stmt::Expr, pc::Int, mm::Method, depth::Int, path)
    args = stmt.args
    isempty(args) && return nothing
    fval = _const_value(ci, args[1])
    line = _line(ci, pc, mm)

    # `invoke(f, Tuple{Integer}, x)` pins a method dispatch would not pick. Reading the argument
    # types alone would resolve it to `more_specific(::Int)` and report clean.
    if fval === Core.invoke && length(args) >= 3
        target = _const_value(ci, args[2])
        pinned = _const_value(ci, args[3])
        if target !== nothing && pinned isa Type
            sig = Base.signature_type(target, pinned)
            # `invoke` semantics, not dispatch semantics: the method chosen for arguments of the
            # DECLARED type. Resolving `Tuple{typeof(more_specific), Integer}` by dispatch finds
            # both `::Int` and `::Integer` and reports the site unresolved, which is exactly the
            # over-caution an analysis that ignores `invoke` would show.
            pin = try
                which(sig)
            catch
                nothing
            end
            if pin isa Method
                return _enter!(st, pin, depth + 1, path)
            end
            return _resolve_sig!(st, sig, _callee_name(ci, args[2]), mm, line, depth, path)
        end
    end
    # `f(x; k = 1)` goes through `Core.kwcall(nt, f, x)`; the mark is on `f`'s own method.
    if fval === Core.kwcall && length(args) >= 3
        rest = Any[_argtype(ci, a) for a in args[4:end]]
        ft = _argtype(ci, args[3])
        sig = _tuple_type(ft, rest)
        sig === nothing ||
            _resolve_sig!(st, sig, _callee_name(ci, args[3]), mm, line, depth, path)
    end
    # `f(xs...)` goes through `_apply_iterate`. A splat of a known-length tuple — which is what
    # `*(promote(x, y)...)` is, and most of Base with it — has an arity inference already knows,
    # so it resolves; anything else genuinely hides the arity and is reported as unresolved.
    if fval === Core._apply_iterate && length(args) >= 3
        name = _callee_name(ci, args[3])
        ft = _argtype(ci, args[3])
        flat = _flatten_splat(ci, args[4:end])
        if ft !== nothing && flat !== nothing && _is_callable_type(ft)
            sig = _tuple_type(ft, flat)
            sig === nothing || return _resolve_sig!(st, sig, name, mm, line, depth, path)
        end
        push!(
            st.unresolved,
            Unresolved(name, ft, :splat, mm.file, line, mm, _marks_named(ci, args[3])),
        )
        return nothing
    end
    fval isa Core.Builtin && return nothing
    fval isa Core.IntrinsicFunction && return nothing

    ft = _argtype(ci, args[1])
    ft === nothing && return nothing
    # The callee is a builtin whose identity inference did not make constant — `tuple` reached
    # through a slot, for instance. Builtins have no Julia body and nothing marked behind them.
    (ft <: Core.Builtin || ft <: Core.IntrinsicFunction) && return nothing
    if ft === Any || !_is_callable_type(ft)
        push!(
            st.unresolved,
            Unresolved(_callee_name(ci, args[1]), ft, :dynamic, mm.file, line, mm, Mark[]),
        )
        return nothing
    end
    sig = _tuple_type(ft, Any[_argtype(ci, a) for a in args[2:end]])
    sig === nothing && return nothing
    return _resolve_sig!(st, sig, _callee_name(ci, args[1]), mm, line, depth, path)
end

function _resolve_sig!(
    st::_Walk, @nospecialize(sig), name::Symbol, mm::Method, line::Int, depth::Int, path
)
    matches = _matching_methods(st, sig)
    if matches === nothing
        push!(st.unresolved, Unresolved(name, sig, :dynamic, mm.file, line, mm, Mark[]))
        return nothing
    end
    if length(matches) == 1
        return _enter!(st, matches[1], depth + 1, path)
    end
    if isempty(matches)
        # Statically a `MethodError`. Nothing is reachable through it, but saying `:clean` about
        # a call that cannot run is not a claim worth making either.
        push!(st.unresolved, Unresolved(name, sig, :nomethod, mm.file, line, mm, Mark[]))
        return nothing
    end
    # Several methods match and nothing in the IR says which. Reporting `:depends` because one of
    # them is marked would over-claim; reporting `:clean` because none is *proved* reached is the
    # false answer this whole file guards.
    #
    # But "which method runs" is only worth knowing if the answer could differ. Every candidate is
    # walked in its own right, and when none of them reaches anything marked the site is resolved
    # after all — that is not a guess, it is having checked all of them. Without this,
    # `convert(::Type, ::UInt32)` — dozens of matching methods, none of them anybody's research
    # code — makes every caller that formats a string `:unknown`.
    if length(matches) > st.maxcandidates
        push!(st.unresolved, Unresolved(name, sig, :ambiguous, mm.file, line, mm, Mark[]))
        return nothing
    end
    cands = Mark[]
    opaque = false
    for match in matches
        sub = _subwalk(st)
        _enter!(sub, match, depth + 1, path)
        for r in sub.reached
            r.mark in cands || push!(cands, r.mark)
        end
        isempty(sub.unresolved) || (opaque = true)
        for mod in sub.modules
            mod in st.modules || push!(st.modules, mod)
        end
        st.truncated |= sub.truncated
    end
    (isempty(cands) && !opaque) && return nothing
    push!(st.unresolved, Unresolved(name, sig, :ambiguous, mm.file, line, mm, cands))
    return nothing
end

# A walk with its own bookkeeping and the parent's settings. `visited` deliberately starts empty:
# a candidate already reached under a different branch still has to be walked here, or the branch
# would be reported clean on the strength of somebody else's traversal.
function _subwalk(st::_Walk)
    return _Walk(
        st.world,
        st.maxdepth,
        st.maxcandidates,
        st.ignore,
        Set{Any}(),
        Reached[],
        Unresolved[],
        Module[],
        st.marked,
        false,
    )
end

# A marked `const` or `struct` is not a call site. Either the analysis reads globals out of the
# IR or the case is out of scope — what it must not do is report `:clean`.
function _check_global!(st::_Walk, g::GlobalRef, mm::Method, line::Int, path)
    isdefined(g.mod, g.name) || return nothing
    v = try
        getglobal(g.mod, g.name)
    catch
        return nothing
    end
    # Functions are reached through their call sites, where dispatch narrows the claim to one
    # method. Treating a mere mention of the name as a dependency would make every sibling method
    # of a marked one guilty.
    v isa Function && return nothing
    mk = mark(g.mod, g.name)
    (mk === nothing || !isnamewide(mk) || mk.name in st.ignore) && return nothing
    any(r -> r.mark === mk, st.reached) && return nothing
    push!(st.reached, Reached(mk, nothing, mm.file, line, vcat(path, [g.name])))
    return nothing
end

function _marks_named(ci, x)
    g = x isa GlobalRef ? x : nothing
    g === nothing && return Mark[]
    mk = mark(g.mod, g.name)
    return mk === nothing ? Mark[] : Mark[mk]
end

# ── reading the IR ───────────────────────────────────────────────────────────────────────────

function _matching_methods(st::_Walk, @nospecialize(sig))
    r = try
        Base._methods_by_ftype(sig, -1, st.world)
    catch
        return nothing
    end
    (r === nothing || r === false) && return nothing
    return r
end

const _INFERRED = IdDict{Any,Any}()

function _inferred(@nospecialize(sig))
    haskey(_INFERRED, sig) && return _INFERRED[sig]
    ci = try
        cis = Base.code_typed_by_type(sig; optimize=false, debuginfo=:source)
        # Not every signature has a body to hand back: a builtin comes back paired with its
        # `Method` rather than a `CodeInfo`, and reading `.code` off that is a `FieldError` from
        # somewhere three frames below where the mistake was made.
        c = isempty(cis) ? nothing : cis[1][1]
        c isa Core.CodeInfo ? c : nothing
    catch
        nothing
    end
    _INFERRED[sig] = ci
    return ci
end

function _argtype(ci, @nospecialize(x))
    x isa Core.SSAValue && return _widen(_ssatype(ci, x.id))
    x isa Core.Argument && return _widen(_slottype(ci, x.n))
    x isa Core.SlotNumber && return _widen(_slottype(ci, x.id))
    x isa GlobalRef && return _widen(_globaltype(x))
    x isa QuoteNode && return Core.Typeof(x.value)
    x isa Expr && return Any
    x isa Type && return Type{x}
    return Core.Typeof(x)
end

function _ssatype(ci, i::Int)
    t = ci.ssavaluetypes
    t isa Vector || return Any
    return (1 <= i <= length(t)) ? t[i] : Any
end

function _slottype(ci, i::Int)
    t = ci.slottypes
    t isa Vector || return Any
    return (1 <= i <= length(t)) ? t[i] : Any
end

function _globaltype(g::GlobalRef)
    isdefined(g.mod, g.name) || return Any
    isconst(g.mod, g.name) || return Any
    v = try
        getglobal(g.mod, g.name)
    catch
        return Any
    end
    return Core.Typeof(v)
end

# The lattice elements inference hands back are not all types. Anything not understood widens to
# `Any`, which turns into an unresolved call site rather than a wrong resolution.
function _widen(@nospecialize(t))
    t isa Type && return t
    t isa Core.Const && return Core.Typeof(t.val)
    if t isa Core.PartialStruct
        u = t.typ
        u isa Type && return u
    end
    if isdefined(Core, :PartialOpaque) && t isa Core.PartialOpaque
        u = t.typ
        u isa Type && return u
    end
    hasproperty(t, :thentype) && return Bool          # Conditional
    hasproperty(t, :typ) && (getproperty(t, :typ) isa Type) && return getproperty(t, :typ)
    return Any
end

function _const_value(ci, @nospecialize(x))
    x isa GlobalRef || return _const_of(_raw_type(ci, x))
    isdefined(x.mod, x.name) || return nothing
    isconst(x.mod, x.name) || return nothing
    return try
        getglobal(x.mod, x.name)
    catch
        nothing
    end
end

function _raw_type(ci, @nospecialize(x))
    x isa Core.SSAValue && return _ssatype(ci, x.id)
    x isa Core.Argument && return _slottype(ci, x.n)
    x isa Core.SlotNumber && return _slottype(ci, x.id)
    return nothing
end

_const_of(@nospecialize(t)) = t isa Core.Const ? t.val : nothing

function _callee_name(ci, @nospecialize(x))
    x isa GlobalRef && return x.name
    t = _raw_type(ci, x)
    if t isa Core.Const
        v = t.val
        v isa Function && return nameof(v)
        v isa Type && return nameof(v)
    end
    w = _widen(t === nothing ? Any : t)
    w isa DataType && isdefined(w, :instance) && return nameof(w.instance)
    return :?
end

# `Tuple{ft, args...}` is only a signature if the pieces are types. A `Vararg` or an unwidened
# lattice element would make `_methods_by_ftype` throw.
function _tuple_type(@nospecialize(ft), args::Vector{Any})
    ft isa Type || return nothing
    ts = Any[ft]
    for a in args
        a isa Type || return nothing
        a isa Core.TypeofVararg && return nothing
        push!(ts, a)
    end
    return try
        Tuple{ts...}
    catch
        nothing
    end
end

# Whether a type can be the first parameter of a signature that dispatch could pin. `Function`
# and `Any` cannot: they are the shapes a field read or a table lookup produces.
#
# `Type{Float64}` is the exception the flag alone gets wrong. Julia marks it abstract, but a
# constant type in call position is a constructor call and dispatch pins it exactly.
function _is_callable_type(@nospecialize(ft))
    ft === Any && return false
    ft === Function && return false
    ft isa DataType || return false
    if ft <: Type
        return length(ft.parameters) == 1 && !(ft.parameters[1] isa TypeVar)
    end
    isabstracttype(ft) && return false
    return true
end

# The element types a splatted argument contributes, or `nothing` if its arity is not known.
function _flatten_splat(ci, args)
    out = Any[]
    for a in args
        t = _argtype(ci, a)
        t isa DataType || return nothing
        t <: Tuple || return nothing
        Base.isvatuple(t) && return nothing
        for p in t.parameters
            p isa Type || return nothing
            push!(out, p)
        end
    end
    return out
end

function _line(ci, pc::Int, mm::Method)
    fallback = Int(mm.line)
    if hasproperty(ci, :debuginfo) &&
        isdefined(Base, :IRShow) &&
        isdefined(Base.IRShow, :getdebugidx)
        try
            l = Base.IRShow.getdebugidx(ci.debuginfo, pc)[1]
            l > 0 && return Int(l)
        catch
        end
    end
    try
        cl = getfield(ci, :codelocs)
        lt = getfield(ci, :linetable)
        if cl isa Vector && lt isa Vector && pc <= length(cl)
            i = Int(cl[pc])
            1 <= i <= length(lt) && return Int(lt[i].line)
        end
    catch
    end
    return fallback
end

"""
    dependents(m::Module, name::Symbol; kwargs...) -> Vector{Symbol}

The public names of `m` whose call graph reaches `name`.

Propagation read backwards, which is the direction the question is actually asked in: a mark gets
deleted because somebody looked at the definition, not at who reaches it. Compare
`reach(m; ignore = [name])` to see what removing it would change.
"""
function dependents(m::Module, name::Symbol; maxdepth::Int=32)
    out = Symbol[]
    for n in surface(m)
        n === name && continue
        isdefined(m, n) || continue
        v = try
            getglobal(m, n)
        catch
            continue
        end
        (v isa Function || v isa Type) || continue
        ml = try
            methods(v)
        catch
            continue
        end
        found = false
        for mm in ml
            mm.module === m || continue
            st = _Walk(maxdepth, Symbol[])
            _enter!(st, mm, 0, Symbol[n])
            any(r -> r.mark.name === name, st.reached) && (found=true; break)
        end
        found && push!(out, n)
    end
    return out
end

function Base.show(io::IO, ::MIME"text/plain", r::Reach)
    v = verdict(r)
    println(io, "Reach(", r.entry, ") — ", uppercase(string(v)))
    for x in r.reached
        println(io, "  reached  ", x.mark.mod, ".", x.mark.name, " — ", x.mark.reason)
        println(io, "           via ", join(x.path, " → "), "  @ ", x.file, ":", x.line)
    end
    for u in r.unresolved
        println(io, "  unresolved ", u.callee, " (", u.why, ")  @ ", u.file, ":", u.line)
        for c in u.candidates
            println(io, "             could reach ", c.mod, ".", c.name, " — ", c.reason)
        end
    end
    r.truncated && println(io, "  (a depth limit stopped the walk)")
    return nothing
end
