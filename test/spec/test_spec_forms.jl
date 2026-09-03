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

struct Callable
    k::Float64
end
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

@testset "a callable struct is marked on the WRONG symbol today" begin
    # `(c::C)(x)` has no function name; `_signame` walks the `::` and returns the argument name.
    # The mark lands on `:c`, which is not a binding anywhere.
    @eval module CallableMarked
    using ExperimentalAPI
    struct C
        k::Float64
    end
    @experimental "scaling rule provisional" (c::C)(x) = c.k * x
    end
    @test :c in [mk.name for mk in experimental(CallableMarked)]     # today, and wrong
    @test !isdefined(CallableMarked, :c)                             # marks a non-binding
end

@testset "and the audit compounds it: C is reported as UNDECLARED" begin
    # The second wrong signal: the audit reports a declaration for a name that does not exist AND
    # a public name with no declaration, so it tells the author to declare what that line already
    # declares. Both halves have to move together.
    @eval module CallablePublic
    using ExperimentalAPI
    public C
    struct C
        k::Float64
    end
    @experimental "scaling rule provisional" (c::C)(x) = c.k * x
    end
    a = ExperimentalAPI.audit(Main.CallablePublic)
    @test :c in a.dangling          # declared, but no such binding
    @test :C in a.unaccounted       # public, and — per the audit — never declared
    @test Main.CallablePublic.C(2.0)(3.0) == 6.0   # the definition itself is fine; the mark is not
end

@testset "a callable struct marks the type, or refuses" begin
    # Either answer is defensible; the argument name is not.
    @test_broken :C in [mk.name for mk in experimental(Main.CallableMarked)]
end

@testset "…and fixing that clears BOTH signals" begin
    # `_signame` returning `:C` is necessary but not sufficient — the audit is what the author
    # reads.
    a = ExperimentalAPI.audit(Main.CallablePublic)
    @test_broken isempty(a.dangling) && :C ∉ a.unaccounted
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

@testset "an inner constructor inside a marked struct is not separately marked" begin
    # Included or excluded is a decision; silence is not.
    @test_broken hasproperty(mark(FormsSpec, :Callable), :includes_constructors)
end

@testset "an operator method can be marked" begin
    # Each ends in a Bool and checks what was marked: `@eval module` returns a Module, which
    # reports "non-Boolean" instead of the Unexpected Pass this directory relies on, and accepting
    # the syntax while recording the wrong symbol is the defect above.
    @test_broken begin
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
    @test_broken begin
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
    @test_broken begin
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
    @test_broken begin
        @eval module InlineMarked
        using ExperimentalAPI
        @experimental "kernel unverified" @inline f(x) = x
        @inline @experimental "kernel unverified" g(x) = x
        end
        Set([mk.name for mk in experimental(Main.InlineMarked)]) == Set([:f, :g])
    end
end

@testset "a definition produced by @eval can be marked by name" begin
    # Metaprogrammed definitions cannot be attached to, so the name-list form must reach them.
    @test_broken begin
        @eval module EvalMarked
        using ExperimentalAPI
        for n in (:a, :b)
            @eval $n(x) = x
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

@testset "the refusal names @experimental rather than leaking the emitted const" begin
    # The message still names a `const` the author never wrote. Whether this is reachable is
    # open: the only expansion avoiding `const` is `global`, which fails silently in local scope.
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
    @test_broken occursin("@experimental", sprint(showerror, e))
end

# ── metadata ─────────────────────────────────────────────────────────────────────────────────

@testset "since must be a version, and the refusal must say so" begin
    # Refused by accident: the field's conversion fails, with a message naming neither `since`
    # nor `@experimental`. A deliberate check would also throw, so assert the diagnostic.
    e = try
        @eval module BadSince
        using ExperimentalAPI
        @experimental("why", since = "0.4.0", f(x) = x)
        end
        nothing
    catch err
        err isa LoadError ? err.error : err
    end
    @test e isa MethodError                                   # today, and accidental
    @test_broken occursin("since", sprint(showerror, e))
end

@testset "an unknown keyword is refused rather than ignored" begin
    # A typo in a keyword name must not silently become part of the subject.
    @test_throws LoadError @eval module BadKw
    using ExperimentalAPI
    @experimental("why", trackign = "u", f(x) = x)
    end
end

@testset "tracking is carried through to every report" begin
    # Stored today; it has to survive into the audit and the record as well.
    @test_broken ExperimentalAPI.audit(FormsSpec).tracking isa AbstractDict
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

@testset "a non-string reason is refused by accident, not by a check" begin
    # Refused by `strip` failing inside `_reason`, with a message naming neither `@experimental`
    # nor `reason`. Same shape as the `since` case above.
    for r in (:(:sym), 42)
        @testset "reason=$(repr(r))" begin
            e = probe(:(@experimental $r f(x) = x))
            @test e isa MethodError                       # today, and accidental
            @test_broken occursin("reason", sprint(showerror, e))
        end
    end
end

@testset "forgetting the reason is diagnosed as a missing reason" begin
    # The message says "nothing to mark" when a definition was given and the reason was not —
    # pointing at the end of the call the author should not touch.
    e = probe(:(@experimental f(x) = x))
    @test e isa ArgumentError
    @test occursin("nothing to mark", sprint(showerror, e))        # today, and misleading
    @test_broken occursin("reason", sprint(showerror, e))
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
    # Last-write-wins is a decision, and it should be visible.
    @test_broken ExperimentalAPI.superseded_marks isa Function
end
