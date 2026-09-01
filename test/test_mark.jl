# What `@experimental` accepts, what it refuses, and what the refusal says.
#
# Each accepted form gets its own module, because the thing under test is a top-level effect on
# the enclosing module — a `@testset` body is a function, and a mark written there would land
# somewhere no query looks.

using ExperimentalAPI:
    ExperimentalAPI, @experimental, Mark, experimental, isexperimental, mark

module Forms

using ExperimentalAPI

@experimental "long-form function" function f_long(x)
    return x
end
@experimental "short-form function" f_short(x) = x
@experimental "return-annotated" f_ret(x)::Int = x
@experimental "parametric" f_where(x::T) where {T} = x
@experimental "struct" struct S
    v::Int
end
@experimental "mutable struct" mutable struct MS
    v::Int
end
@experimental "parametric struct with a supertype" struct PS{T} <: AbstractVector{T}
    v::Vector{T}
end
@experimental "abstract type" abstract type A end
@experimental "primitive type" primitive type P 8 end
@experimental "macro" macro m(x)
    return esc(x)
end
@experimental "const" const C = 1
@experimental "plain assignment" G = 2
module Sub end
@experimental "module" Sub

# The name-list form, for names defined somewhere the macro cannot see.
other_a(x) = x
other_b(x) = x
@experimental "declared, not attached" other_a other_b

# Metadata, and the ambiguity the parser has to resolve: `since = …` is a keyword because it is
# not the last argument, while `H = 3` is the subject because it is.
@experimental(
    "carries metadata", since = v"0.4.0", tracking = "https://example.invalid/pull/7", H = 3
)

end # module Forms

@testset "attached forms" begin
    got = Dict(mk.name => mk for mk in experimental(Forms))
    for (name, reason) in (
        :f_long => "long-form function",
        :f_short => "short-form function",
        :f_ret => "return-annotated",
        :f_where => "parametric",
        :S => "struct",
        :MS => "mutable struct",
        :PS => "parametric struct with a supertype",
        :A => "abstract type",
        :P => "primitive type",
        Symbol("@m") => "macro",
        :C => "const",
        :G => "plain assignment",
    )
        @testset "$name" begin
            @test haskey(got, name)
            @test got[name].reason == reason
            @test got[name].mod === Forms
        end
    end
end

module Documented
using ExperimentalAPI
public both, marked_macro
"""
A name can be documented AND declared unfinished. The two accounts are not exclusive, and a
package that has to choose between them will pick the cheaper one.
"""
@experimental "shape still moving" both(x) = x
"A marked macro keeps its docstring too."
@experimental "not settled" macro marked_macro(x)
    return esc(x)
end
end

@testset "a marked definition can still carry a docstring" begin
    # `\"\"\"docs\"\"\" @experimental ...` has to work, or the audit's two accounts become mutually
    # exclusive and every author is forced to pick one.
    @test Base.Docs.hasdoc(Documented, :both)
    @test Base.Docs.hasdoc(Documented, Symbol("@marked_macro"))
    @test isexperimental(Documented, :both)
    @test occursin("not exclusive", string(@doc Documented.both))
    @test Documented.both(3) == 3
end

@testset "the definition is emitted unchanged" begin
    # The mark must not wrap, rename or otherwise touch what it marks.
    @test Forms.f_long(3) == 3
    @test Forms.f_short(3) == 3
    @test Forms.f_where(3) == 3
    @test Forms.S(1).v == 1
    @test Forms.C == 1
    @test Forms.G == 2
    @test Forms.A isa Type && isabstracttype(Forms.A)
    @test (@eval Forms @m 1 + 1) == 2
end

@testset "name-list form" begin
    @test isexperimental(Forms, :Sub)      # a module can only be marked this way
    @test Forms.Sub isa Module
    @test isexperimental(Forms, :other_a)
    @test isexperimental(Forms, :other_b)
    @test mark(Forms, :other_a).reason == "declared, not attached"
end

@testset "metadata rides with the mark" begin
    mk = mark(Forms, :H)
    @test mk.since == v"0.4.0"
    @test mk.tracking == "https://example.invalid/pull/7"
    @test Forms.H == 3            # …and `H = 3` was still the subject, not a keyword
end

@testset "the declaration site is recorded" begin
    mk = mark(Forms, :f_long)
    @test String(mk.file) == @__FILE__
    @test mk.line > 0
    # The line is the `@experimental` line, which in the attached form is the definition site.
    @test occursin("long-form function", readlines(@__FILE__)[mk.line])
end

@testset "reason is normalised, never invented" begin
    @test ExperimentalAPI._reason("  spaced  ") == "spaced"
    @test_throws ArgumentError ExperimentalAPI._reason("   ")
end

module Rewritten
using ExperimentalAPI
g(x) = x
@experimental "first reading" g
@experimental "second reading, after a re-include" g
end

@testset "re-marking replaces rather than appends" begin
    # Revise, or an `include` reached twice, must not make one name appear twice.
    @test count(mk -> mk.name === :g, experimental(Rewritten)) == 1
    @test mark(Rewritten, :g).reason == "second reading, after a re-include"
end

@testset "a module with no marks answers, it does not fail" begin
    @test isempty(experimental(Base))
    @test mark(Base, :sum) === nothing
    @test !isexperimental(Base, :sum)
end

@testset "refusals name the problem" begin
    # A definition this macro cannot read a name out of must not be guessed at.
    @test_throws LoadError @eval module R1
    using ExperimentalAPI
    @experimental "why" @doc "x" f(x) = x
    end
    # A qualified definition adds a method to a name this module does not own.
    @test_throws LoadError @eval module R2
    using ExperimentalAPI
    @experimental "why" Base.sum(x::Int) = x
    end
    # The reason is not optional, and forgetting it is caught rather than read as a name.
    @test_throws LoadError @eval module R3
    using ExperimentalAPI
    @experimental function f(x)
        return x
    end
    end
    # Metadata with nothing to attach it to.
    @test_throws LoadError @eval module R4
    using ExperimentalAPI
    @experimental "why" tracking = "u"
    end
    # A name list with one entry that is not a name silently dropping the rest is the failure
    # this checks against.
    @test_throws LoadError @eval module R5
    using ExperimentalAPI
    @experimental "why" a f(x) = x
    end
    # `module` is top-level-only and cannot be wrapped, so it is refused rather than mangled.
    @test_throws LoadError @eval module R8
    using ExperimentalAPI
    @experimental "why" module Inner end
    end
end

@testset "refusals say what to do instead" begin
    err = try
        @eval module R6
        using ExperimentalAPI
        @experimental "why" Base.sum(x::Int) = x
        end
        nothing
    catch e
        e
    end
    @test err isa LoadError
    msg = sprint(showerror, err.error)
    @test occursin("another module", msg)

    err2 = try
        @eval module R7
        using ExperimentalAPI
        @experimental "why" @doc "x" f(x) = x
        end
        nothing
    catch e
        e
    end
    @test occursin("Name it instead", sprint(showerror, err2.error))
end
