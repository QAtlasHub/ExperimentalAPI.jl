# The definition forms a real package hits on its second afternoon: kwargs, parametric
# signatures, callable structs, constructors, operators, stacked macros.
#
# Scope: each form either works, or the refusal names the alternative. Silently marking the wrong
# symbol is the outcome this file exists to prevent.

using ExperimentalAPI: ExperimentalAPI, @experimental, experimental, isexperimental, mark
using Test

module FormsSpec

using ExperimentalAPI

public kw_fn, where_fn, vararg_fn, ret_typed, Callable, Ctor, INTERP

@experimental "keyword arguments" kw_fn(x; scale=1.0, kwargs...) = x * scale
@experimental "parametric" where_fn(x::T, y::T) where {T<:Real} = x + y
@experimental "varargs" vararg_fn(x, rest...) = x
@experimental "return type annotation" ret_typed(x)::Float64 = x

# A marked type covers the constructors it implies: `MarkedStruct(x)` is a call, and an analysis
# that only looked at named functions would report constructing one as clean.
@experimental "the call operator's scaling rule is provisional" struct Callable
    k::Float64
end
(c::Callable)(x) = c.k * x
struct Ctor
    v::Int
end

# an interpolated reason
const WHY = "tolerance chosen by hand"
@experimental "$(WHY); see the sweep in issue 12" INTERP = 1e-8

end # module FormsSpec

@testset "forms that already work" begin
    got = Dict(mk.name => mk for mk in experimental(FormsSpec))
    for n in (:kw_fn, :where_fn, :vararg_fn, :ret_typed, :INTERP)
        @testset "$n" begin
            @test haskey(got, n)
            @test !isempty(strip(got[n].reason))
        end
    end
    @test FormsSpec.kw_fn(2.0; scale=3.0) == 6.0
    @test FormsSpec.where_fn(1, 2) == 3
end

@testset "an interpolated reason is evaluated, not stored as source" begin
    @test occursin("tolerance chosen by hand", mark(FormsSpec, :INTERP).reason)
end

# ── forms that are not covered ───────────────────────────────────────────────────────────────

@testset "a callable struct is marked on the type" begin
    # `(c::C)(x)` has no function name. Reading the argument name out of the `::` is what the
    # first implementation did, and it produced a mark on `:c` — a local that is not a binding
    # anywhere. The name a reader recognises is the TYPE.
    @eval module CallableMarked
    using ExperimentalAPI
    struct C
        k::Float64
    end
    @experimental "scaling rule provisional" (c::C)(x) = c.k * x
    end
    got = [mk.name for mk in experimental(Main.CallableMarked)]
    @test :C in got
    @test :c ∉ got                                       # the argument name, and it was the bug
    @test !isdefined(Main.CallableMarked, :c)
    # …and the mark is about the call operator, not about the constructor.
    @test ExperimentalAPI.mark(Main.CallableMarked, :C).sig ===
        Tuple{Main.CallableMarked.C,Any}
end

@testset "…and the audit reports neither a dangling mark nor an undeclared name" begin
    # The compounding failure the fix has to clear: a mark on `:c` made the audit report a
    # declaration for a name that does not exist AND a public name with no declaration, so it
    # told the author to go and declare the very thing that line declares. Both halves move
    # together, so both are checked together.
    @eval module CallablePublic
    using ExperimentalAPI
    public C
    struct C
        k::Float64
    end
    @experimental "scaling rule provisional" (c::C)(x) = c.k * x
    end
    a = ExperimentalAPI.audit(Main.CallablePublic; methods=false)
    @test isempty(a.dangling)
    @test :C ∉ a.unaccounted
    @test :C in a.declared
    @test Main.CallablePublic.C(2.0)(3.0) == 6.0
end

@testset "a constructor method is marked on the type" begin
    # Already correct: the mark lands on `:T`.
    @eval module CtorMarked
    using ExperimentalAPI
    struct T
        v::Int
    end
    @experimental "validation not implemented" T(s::AbstractString) = T(parse(Int, s))
    end
    got = Set(mk.name for mk in experimental(Main.CtorMarked))
    @test :T in got
    # Control: an over-inclusive walk would mark the argument name here too.
    @test :s ∉ got
end

@testset "a marked type covers its constructors, and says so" begin
    # Included or excluded is a decision; silence is not. Included: `MarkedStruct(x)` is a call,
    # and an analysis that treated construction as unmarked would report building one as clean.
    mk = mark(FormsSpec, :Callable)
    @test hasproperty(mk, :includes_constructors)
    @test mk.includes_constructors === true
    @test ExperimentalAPI.isexperimental(which(FormsSpec.Callable, Tuple{Float64}))
    # Control: a mark attached to a function covers no constructor, because there is none.
    @test mark(FormsSpec, :kw_fn).includes_constructors === false
end

@testset "an operator method can be marked" begin
    # Each ends in a Bool and checks what was marked: `@eval module` returns a Module, which
    # reports "non-Boolean" instead of the Unexpected Pass this directory relies on, and accepting
    # the syntax while recording the wrong symbol is the defect above.
    @test begin
        @eval module OpMarked
        using ExperimentalAPI
        struct V
            x::Float64
        end
        @experimental "no identity element yet" Base.:+(a::V, b::V) = V(a.x + b.x)
        end
        :+ in [mk.name for mk in experimental(Main.OpMarked)]
    end
end

@testset "a generated function can be marked" begin
    @test begin
        @eval module GenMarked
        using ExperimentalAPI
        @experimental "generator is a prototype" @generated g(x) = :(x)
        end
        :g in [mk.name for mk in experimental(Main.GenMarked)]
    end
end

@testset "Base.@kwdef stacks with the mark" begin
    # Two macros that both wrap a definition must compose in at least one order, and which one
    # must be documented.
    @test begin
        @eval module KwdefMarked
        using ExperimentalAPI
        @experimental "defaults are guesses" Base.@kwdef struct S
            a::Int = 1
        end
        end
        :S in [mk.name for mk in experimental(Main.KwdefMarked)]
    end
end

@testset "@inline and the mark compose in both orders" begin
    # "Compose" was asserted as `Set([:f, :g])` — the names are marked — and that is satisfied by
    # a mark that can never fire. Measured: the two orders did NOT compose the same way. With the
    # mark outside, `_instrument` saw a `:macrocall` and returned `nothing`, so the flag was
    # registered and nothing ever set it; with the mark inside, the flag worked. `entered` said
    # `[:g]` after calling both. An `@inline` kernel is exactly what this package is for, so the
    # claim has to be about the observation, not about the name.
    @eval module InlineMarked
    using ExperimentalAPI
    @experimental "kernel unverified" @inline f(x) = x
    @inline @experimental "kernel unverified" g(x) = x
    end
    @test Set([mk.name for mk in experimental(Main.InlineMarked)]) == Set([:f, :g])
    @test Set(p.name for p in ExperimentalAPI.probes(Main.InlineMarked)) == Set([:f, :g])
    Main.InlineMarked.f(1)
    Main.InlineMarked.g(1)
    @test Set(e.name for e in ExperimentalAPI.entered(Main.InlineMarked)) == Set([:f, :g])
end

@testset "every annotating macro carries the flag, and the opaque ones still do not" begin
    # The control the testset above cannot be on its own: a fix that instrumented EVERY macrocall
    # would satisfy it while putting a probe inside `@generated`'s returned expression, where it
    # is generated rather than run. The split between the two lists is the claim.
    @eval module Annotated
    using ExperimentalAPI
    @experimental "a" @inline a(x) = x
    @experimental "b" @noinline b(x) = x
    @experimental "c" Base.@propagate_inbounds c(x) = x
    @experimental "d" Base.@assume_effects :terminates_locally d(x) = x
    @experimental "e" @generated e(x) = :(x)
    @experimental "f" Base.@kwdef struct Opaque
        n::Int = 1
    end
    end
    for n in (:a, :b, :c, :d)
        Core.eval(Main.Annotated, :($n(1)))
    end
    Main.Annotated.e(1)
    Main.Annotated.Opaque()
    @test Set(e.name for e in ExperimentalAPI.entered(Main.Annotated)) ==
        Set([:a, :b, :c, :d])
    # …and the two that are not observed are still marked, queryable and audited.
    @test Set(mk.name for mk in experimental(Main.Annotated)) ==
        Set([:a, :b, :c, :d, :e, :Opaque])
    @test Set(p.name for p in ExperimentalAPI.probes(Main.Annotated)) ==
        Set([:a, :b, :c, :d])
end

@testset "a definition produced by @eval can be marked by name" begin
    # Metaprogrammed definitions cannot be attached to, so the name-list form must reach them.
    @test begin
        @eval module EvalMarked
        using ExperimentalAPI
        # Built with `Expr` rather than `@eval $n(...)`: inside an `@eval module` the outer
        # macro interpolates `$n` first, where `n` does not exist yet.
        for n in (:a, :b)
            Core.eval(@__MODULE__, Expr(:(=), Expr(:call, n, :x), :x))
        end
        @experimental "generated in a loop" a b
        end
        Set([mk.name for mk in experimental(Main.EvalMarked)]) == Set([:a, :b])
    end
end

@testset "a mark inside a function body is refused" begin
    # Refused by Julia, not by this package: `const` in local scope fails during lowering, before
    # any emitted code runs, so no check of ours can intercept it. The one lever is where the
    # error points, and the expansion carries the caller's `LineNumberNode`.
    #
    # The misuse must arrive from a FILE: written through `@eval` the message carries no location
    # at all, so a location assertion made that way is vacuous. Built line by line so the
    # formatter cannot shift line 4.
    dir = mktempdir()
    path = joinpath(dir, "caller_side.jl")
    write(
        path,
        join(
            [
                "module CallerSide",
                "using ExperimentalAPI",
                "function outer()",
                "    @experimental \"why\" inner(x) = x",
                "    return inner",
                "end",
                "end",
            ],
            "\n",
        ),
    )
    e = try
        include(path)
        nothing
    catch err
        err isa LoadError ? err.error : err
    end
    @test e isa ErrorException
    msg = sprint(showerror, e)
    @test occursin("unsupported `const` declaration", msg)
    # The blame lands on the line the author wrote…
    @test occursin("caller_side.jl:4", msg)
    # …and nowhere in this package. Checked by file name: the repository path contains
    # "ExperimentalAPI", so asserting on that word passes by accident.
    @test !occursin("mark.jl", msg)
end

@testset "the refusal cannot name @experimental, and that is now a decision" begin
    # WITHDRAWN, with the measurement that withdrew it. The requirement was that the message name
    # `@experimental`. It cannot, and the three routes are exhausted:
    #
    #   * `const` in local scope fails during LOWERING, before any emitted code runs, so no check
    #     of ours can intercept it — and Julia's message does not name the variable either, so
    #     naming the binding `var"@experimental ..."` does not smuggle the word in. Measured on
    #     1.12.2: the message is byte-identical for `:__EXPERIMENTAL_API_MARKS__` and for a
    #     binding whose name is the whole sentence.
    #   * `global`, the one expansion that avoids `const`, fails SILENTLY in local scope — a
    #     worse outcome than a loud message pointing at the wrong vocabulary.
    #   * creating the registry through `Core.eval` removes the error altogether, which turns a
    #     refusal into a mark registered when the enclosing function is first called.
    #
    # What is kept is the part that is in this package's hands and is asserted above: the blame
    # lands on the line the author wrote, and never inside this package.
    e = try
        @eval module ClosureMarked2
        using ExperimentalAPI
        function outer()
            @experimental "why" inner(x) = x
            return inner
        end
        end
        nothing
    catch err
        err
    end
    msg = sprint(showerror, e isa LoadError ? e.error : e)
    @test occursin("unsupported `const` declaration", msg)
    @test !occursin("mark.jl", msg)
end

# Each of these three is refused today, and none of the messages was pinned by anything — measured
# 2026-09-08 by grepping `test/` for their text and finding zero hits. A refusal is half of what
# this macro does: the other half of "cannot guess which name this defines" is saying what to
# write instead, and a message can rot into a bare failure without a single test going red.
@testset "a wrapping macro this cannot read is refused by name, and points at the name list" begin
    for (label, body) in (
        "another @experimental" => """@experimental "outer" @experimental "inner" f(x) = x""",
        "an unknown macro" => """@experimental "why" @assert true""",
    )
        @testset "$label" begin
            e = try
                include_string(
                    Main,
                    "module Wrap_$(hash(label))\nusing ExperimentalAPI\n$body\nend",
                    "wrap.jl",
                )
                nothing
            catch err
                err
            end
            # Unwrapped in a loop, not once: a macro that throws while expanding a `module` body
            # passed through `include_string` comes back wrapped TWICE, and a single `.error`
            # leaves a `LoadError` that reads exactly like the failure it is hiding.
            while e isa LoadError
                e = e.error
            end
            @test e isa ArgumentError
            msg = sprint(showerror, e)
            # Names the macro it could not read, so the author knows which line to change…
            @test occursin("@", msg)
            # …and the form that always works, which is what makes it actionable.
            @test occursin("@experimental \"why\" the_name", msg)
        end
    end
end

@testset "a block of definitions is refused rather than half-marked" begin
    # The dangerous silence: `begin f(x)=x; g(x)=x end` has two names and the macro can only
    # record one. Marking the first and dropping the second would be a covenant that omits a
    # definition without saying so.
    e = try
        @eval module BlockSubject
        using ExperimentalAPI
        @experimental "why" begin
            f(x) = x
            g(x) = x
        end
        end
        nothing
    catch err
        err isa LoadError ? err.error : err
    end
    @test e isa ArgumentError
    msg = sprint(showerror, e)
    @test occursin("block", msg)
    @test occursin("the_name", msg)
end

@testset "a bare qualified name is refused, because the module it names is not ours to mark" begin
    # `@experimental "why" Sub.g` reads as marking somebody else's `g`. The name list records into
    # the module the macro ran in, so accepting it would file the mark in the wrong registry.
    e = try
        @eval module QualifiedBare
        using ExperimentalAPI
        module Sub
            g(x) = x
        end
        @experimental "why" Sub.g
        end
        nothing
    catch err
        err isa LoadError ? err.error : err
    end
    @test e isa ArgumentError
    msg = sprint(showerror, e)
    @test occursin("Sub.g", msg)        # the expression the author wrote, not a generic complaint
    @test occursin("WHICH method", msg)  # why a bare qualified name is not enough…
    @test occursin("Sub.g(::", msg)      # …and the form that is, spelled out with their own name
end

# ── metadata ─────────────────────────────────────────────────────────────────────────────────

@testset "since must be a version, and the refusal must say so" begin
    # Refused by a check rather than by accident. The first implementation let the field's own
    # conversion fail, which threw a `MethodError` naming neither `since` nor `@experimental` —
    # a refusal the author cannot act on is barely better than none.
    e = try
        @eval module BadSince
        using ExperimentalAPI
        @experimental("why", since = "0.4.0", f(x) = x)
        end
        nothing
    catch err
        err isa LoadError ? err.error : err
    end
    @test e isa ArgumentError
    msg = sprint(showerror, e)
    @test occursin("since", msg)
    @test occursin("VersionNumber", msg)
    # …and it says what to write instead, which is the whole difference from the MethodError.
    @test occursin("v\"0.4.0\"", msg)
end

@testset "an unknown keyword is refused rather than ignored" begin
    # A typo in a keyword name must not silently become part of the subject.
    @test_throws LoadError @eval module BadKw
    using ExperimentalAPI
    @experimental("why", trackign = "u", f(x) = x)
    end
end

@testset "tracking is carried through to every report" begin
    # Stored is not enough: it has to survive into the audit, and into the note the docs render.
    @test ExperimentalAPI.audit(FormsSpec; methods=false).tracking isa AbstractDict
    @eval module Tracked
    using ExperimentalAPI
    public f
    "Documented."
    @experimental(
        "shape undecided", tracking = "https://example.invalid/issues/3", f(x) = x
    )
    end
    a = ExperimentalAPI.audit(Main.Tracked; methods=false)
    @test a.tracking[:f] == "https://example.invalid/issues/3"
    @test occursin(
        "example.invalid/issues/3", ExperimentalAPI.docstring_note(Main.Tracked, :f)
    )
    # Control: a mark with no tracking link contributes no entry, so the table is not a list of
    # every mark with a blank beside most of them.
    @test :kw_fn ∉ keys(ExperimentalAPI.audit(FormsSpec; methods=false).tracking)
end

# Evaluate an expression in a fresh module and hand back the exception it raised, unwrapped.
function probe(ex)
    m = Module()
    Core.eval(m, :(using ExperimentalAPI))
    try
        Core.eval(m, ex)
        return nothing
    catch err
        return err isa LoadError ? err.error : err
    end
end

# ── writing it lazily ────────────────────────────────────────────────────────────────────────
#
# Scope: what happens when the reason — the payload, and knowledge only the author has — is left
# out. Every lazy form is refused; two by accident, and two with a message pointing the wrong way.

@testset "a bare @experimental is refused, and says which of the two is missing" begin
    # Each case pins its own phrase: `@test_throws Exception` for all six would be satisfied by
    # one generic message.
    for (ex, needle) in (
        (:(@experimental), "needs a reason"),
        (:(@experimental foo), "the reason comes first"),
        (:(@experimental function f(x)
            x
        end), "the reason comes first"),
        (:(@experimental struct S
            v::Int
        end), "the reason comes first"),
        (:(@experimental f(x) = x), "nothing to mark"),
        (:(@experimental const C = 1), "nothing to mark"),
    )
        @testset "$(first(string(ex), 36))" begin
            e = probe(ex)
            @test e isa ArgumentError
            @test occursin(needle, sprint(showerror, e))
        end
    end
end

@testset "an empty reason is refused, and the message says why" begin
    for r in ("", "   ", "\n\t ")
        @testset "reason=$(repr(r))" begin
            m = Module(:EmptyProbe)
            Core.eval(m, :(using ExperimentalAPI))
            e = try
                Core.eval(m, :(@experimental $r f(x) = x))
                nothing
            catch err
                err isa LoadError ? err.error : err
            end
            @test e isa ArgumentError
            @test occursin("reason", sprint(showerror, e))
        end
    end
end

@testset "a non-string reason is refused by a check, and the check says why" begin
    # Same shape as the `since` case: letting `strip` fail inside `_reason` also refused it, with
    # a `MethodError` naming neither `@experimental` nor `reason`.
    for r in (:(:sym), 42)
        @testset "reason=$(repr(r))" begin
            e = probe(:(@experimental $r f(x) = x))
            @test e isa ArgumentError
            @test occursin("reason", sprint(showerror, e))
        end
    end
end

@testset "forgetting the reason is diagnosed as a missing reason" begin
    # The message says "nothing to mark" when a definition was given and the reason was not —
    # pointing at the end of the call the author should not touch.
    e = probe(:(@experimental f(x) = x))
    @test e isa ArgumentError
    @test occursin("nothing to mark", sprint(showerror, e))        # today, and misleading
    @test occursin("reason", sprint(showerror, e))
end

@testset "nothing is marked when the macro refuses" begin
    # Checks the module is left clean, not just that an exception came out.
    m = Module(:RefusedProbe)
    Core.eval(m, :(using ExperimentalAPI))
    try
        Core.eval(m, :(@experimental f(x) = x))
    catch
    end
    @test isempty(experimental(m))
    @test !isdefined(m, :f)
end

# ── same name, two places ────────────────────────────────────────────────────────────────────

@testset "the same name marked in two modules stays separate" begin
    @eval module A1
    using ExperimentalAPI
    public f
    @experimental "reason A" f(x) = x
    end
    @eval module A2
    using ExperimentalAPI
    public f
    @experimental "reason B" f(x) = x
    end
    @test mark(A1, :f).reason == "reason A"
    @test mark(A2, :f).reason == "reason B"
end

@testset "re-marking with a different reason replaces rather than accumulates" begin
    @eval module A3
    using ExperimentalAPI
    public f
    f(x) = x
    @experimental "first" f
    @experimental "second" f
    end
    @test count(mk -> mk.name === :f, experimental(A3)) == 1
    @test mark(A3, :f).reason == "second"
end

@testset "the replacement is reported rather than silent" begin
    # Last-write-wins is a decision, and it should be visible: a reason that was overwritten is
    # exactly the thing a reader cannot reconstruct from the source they are looking at.
    @test ExperimentalAPI.superseded_marks isa Function
    sup = ExperimentalAPI.superseded_marks(A3)
    @test length(sup) == 1
    @test sup[1].reason == "first"
    # Control: a module whose marks were never replaced records nothing, so the log is not just
    # a copy of the registry.
    @test isempty(ExperimentalAPI.superseded_marks(FormsSpec))
end
