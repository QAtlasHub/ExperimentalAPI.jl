# A mark and a docstring are different accounts, and must coexist.
#
# Scope: a mark is never a substitute for prose. `Base.Experimental` is the precedent — Base
# marks an experimental surface AND documents it. Pinned by named entries rather than by a count,
# which moves with the Julia version and the counting rule.

using ExperimentalAPI:
    ExperimentalAPI, @experimental, audit, experimental, isdocumented, isexperimental, mark
using Test

module Both

using ExperimentalAPI

public documented_and_marked,
    marked_only, documented_only, silent, @marked_macro, separately

"""
Documented, and declared unfinished. Both statements are true at once and neither replaces the
other: the prose says what it does, the mark says how much to trust it.
"""
@experimental "convergence not established at low β" documented_and_marked(x) = x

@experimental "no prose yet" marked_only(x) = x

"Documented and settled."
documented_only(x) = x

silent(x) = x

"A marked macro keeps its docstring."
@experimental "shape not settled" macro marked_macro(x)
    return esc(x)
end

# a docstring attached separately rather than adjacent to the definition
@experimental "declared here, documented below" separately(x) = x
@doc "Documented in a second statement." separately

end # module Both

@testset "Julia itself documents its experimental surface" begin
    @test isdefined(Base, :Experimental)
    for n in (Symbol("@optlevel"), Symbol("@compiler_options"), :Const)
        @testset "Base.Experimental.$n" begin
            @test isdefined(Base.Experimental, n)
            @test Base.Docs.hasdoc(Base.Experimental, n)
        end
    end
end

@testset "a docstring survives the macro" begin
    # `Expr(:meta, :doc)` attaches the docstring to the definition rather than to the expanded
    # block. Without it the two accounts are mutually exclusive in practice.
    @test Base.Docs.hasdoc(Both, :documented_and_marked)
    @test isexperimental(Both, :documented_and_marked)
    @test occursin(
        "Both statements are true at once", string(@doc Both.documented_and_marked)
    )
end

@testset "a marked macro keeps its docstring" begin
    @test Base.Docs.hasdoc(Both, Symbol("@marked_macro"))
    @test isexperimental(Both, Symbol("@marked_macro"))
end

@testset "a docstring attached in a separate statement also works" begin
    @test Base.Docs.hasdoc(Both, :separately)
    @test isexperimental(Both, :separately)
end

@testset "the four combinations land where they should" begin
    a = audit(Both)
    @test :documented_and_marked in a.documented
    @test :documented_and_marked in a.declared      # both accounts, deliberately
    @test :marked_only in a.declared
    @test :marked_only ∉ a.documented
    @test :documented_only in a.documented
    @test :documented_only ∉ a.declared
    @test :silent in a.unaccounted                  # neither — the finding
end

@testset "a mark is not an excuse for missing prose" begin
    # Scope: a marked name with no docstring is still undocumented. Today `declared` absorbs it.
    a = audit(Both)
    @test_broken :marked_only in a.undocumented
    @test_broken hasproperty(a, :undocumented)
end

@testset "the check can require a docstring regardless of the mark" begin
    # Scope: a package adopting both this and Aqua must not have to choose between them.
    @test_broken ExperimentalAPI.test_surface(Both; require_docstring=true) isa
        ExperimentalAPI.Audit
end

@testset "the reason is reachable from the rendered documentation" begin
    # Scope: the reason must reach the docs site without the author typing it twice.
    @test_broken ExperimentalAPI.docstring_note(Both, :documented_and_marked) isa
        AbstractString
end

@testset "what Documenter's checkdocs sees is not what audit sees" begin
    # `checkdocs = :public` has no third answer; `audit` accepts a mark. Both are legitimate.
    a = audit(Both)
    undocumented_by_base = setdiff(Base.Docs.undocumented_names(Both), [nameof(Both)])
    @test :marked_only in undocumented_by_base      # Base would flag it
    @test :marked_only ∉ a.unaccounted              # audit accepts the mark
    @test :silent in undocumented_by_base
    @test :silent in a.unaccounted                  # both flag this one
end
