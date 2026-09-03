# The definition forms the macro has not been shown to handle.
#
# `test_spec_declare.jl` covers the forms that work today. These are the ones a real package hits
# on its second afternoon: keyword arguments, parametric signatures, callable structs,
# constructors, operators, stacked macros. Each one either works, or the refusal has to name the
# alternative — silently marking the wrong symbol is the outcome this file exists to prevent.

using ExperimentalAPI: ExperimentalAPI, @experimental, experimental, isexperimental, mark
using Test

module Forms

using ExperimentalAPI

public kw_fn, where_fn, vararg_fn, ret_typed, Callable, Ctor, Gen, KwStruct, INTERP

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

end # module Forms

@testset "forms that already work" begin
    got = Dict(mk.name => mk for mk in experimental(Forms))
    for n in (:kw_fn, :where_fn, :vararg_fn, :ret_typed, :INTERP)
        @testset "$n" begin
            @test haskey(got, n)
            @test !isempty(strip(got[n].reason))
        end
    end
    @test Forms.kw_fn(2.0; scale=3.0) == 6.0
    @test Forms.where_fn(1, 2) == 3
end

@testset "an interpolated reason is evaluated, not stored as source" begin
    @test occursin("tolerance chosen by hand", mark(Forms, :INTERP).reason)
end

# ── forms that are not covered ───────────────────────────────────────────────────────────────

@testset "a callable struct is marked on the WRONG symbol today" begin
    # Measured 2026-09-03. `(c::C)(x) = c.k * x` has no function name, and `_signame` walks the
    # `::` and returns the ARGUMENT name. The mark lands on `:c`, a local that is not a binding
    # anywhere, so it is silently meaningless — the exact failure this file exists to catch.
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

@testset "a callable struct marks the type, or refuses" begin
    # Either answer is defensible. Marking the argument name is not.
    @test_broken :C in [mk.name for mk in experimental(Main.CallableMarked)]
end

@testset "a constructor method is marked on the type" begin
    # This one already resolves correctly: the mark lands on `:T`.
    @eval module CtorMarked
    using ExperimentalAPI
    struct T
        v::Int
    end
    @experimental "validation not implemented" T(s::AbstractString) = T(parse(Int, s))
    end
    @test :T in [mk.name for mk in experimental(Main.CtorMarked)]
end

@testset "an inner constructor inside a marked struct is not separately marked" begin
    # Marking the struct should not silently also claim its inner constructors are unfinished,
    # nor silently exclude them. Whichever it is has to be stated.
    @test_broken hasproperty(mark(Forms, :Callable), :includes_constructors)
end

@testset "an operator method can be marked" begin
    @test_broken @eval module OpMarked
    using ExperimentalAPI
    struct V
        x::Float64
    end
    @experimental "no identity element yet" Base.:+(a::V, b::V) = V(a.x + b.x)
    end
end

@testset "a generated function can be marked" begin
    @test_broken @eval module GenMarked
    using ExperimentalAPI
    @experimental "generator is a prototype" @generated g(x) = :(x)
    end
end

@testset "Base.@kwdef stacks with the mark" begin
    # `@kwdef` expands to a block carrying `Expr(:meta, :doc)`. Two macros that both wrap a
    # definition must compose in at least one order, and the order that works must be documented.
    @test_broken @eval module KwdefMarked
    using ExperimentalAPI
    @experimental "defaults are guesses" Base.@kwdef struct S
        a::Int = 1
    end
    end
end

@testset "@inline and the mark compose in both orders" begin
    @test_broken @eval module InlineMarked
    using ExperimentalAPI
    @experimental "kernel unverified" @inline f(x) = x
    @inline @experimental "kernel unverified" g(x) = x
    end
end

@testset "a definition produced by @eval can be marked by name" begin
    # Metaprogrammed definitions cannot be attached to; the name-list form is the answer and it
    # has to be reachable.
    @test_broken @eval module EvalMarked
    using ExperimentalAPI
    for n in (:a, :b)
        @eval $n(x) = x
    end
    @experimental "generated in a loop" a b
    end
end

@testset "a mark inside a function body is refused" begin
    # It IS refused today, but by Julia rather than by this package: the emitted `const` is
    # illegal in local scope, so the message is
    #   syntax: unsupported `const` declaration on local variable
    # which says nothing about `@experimental` and points at a line the author did not write.
    e = try
        @eval module ClosureMarked
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
    @test e isa ErrorException
    @test occursin("unsupported `const` declaration", sprint(showerror, e))
end

@testset "the refusal names @experimental rather than leaking the emitted const" begin
    # A macro whose diagnostic is about its own expansion has handed the reader a puzzle. The
    # message should say that a mark belongs at module top level, next to `export` and `public`.
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

@testset "since must be a version, not a string" begin
    @test_broken @eval module BadSince
    using ExperimentalAPI
    @experimental("why", since = "0.4.0", f(x) = x)
    end
end

@testset "an unknown keyword is refused rather than ignored" begin
    # `@experimental "why" tracking_url="..." f(x)=x` — a typo in a keyword name must not silently
    # become part of the subject.
    @test_throws LoadError @eval module BadKw
    using ExperimentalAPI
    @experimental("why", trackign = "u", f(x) = x)
    end
end

@testset "tracking is carried through to every report" begin
    # The field that turns a warning into something a reader can act on. It is stored today; it
    # has to survive into the audit and the record as well.
    @test_broken ExperimentalAPI.audit(Forms).tracking isa AbstractDict
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
    # Two different reasons for one name usually means two authors disagreed, or a stale mark was
    # left behind. Last-write-wins is a decision, and it should be visible.
    @test_broken ExperimentalAPI.superseded_marks isa Function
end
