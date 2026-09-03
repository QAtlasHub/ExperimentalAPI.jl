# A mark and a docstring are different accounts, and they must coexist.
#
# The registry reviewer's objection on 2026-09-02 was aimed at a README sentence that read
# "this name is public, it has no docstring, and that is deliberate". His position — public names
# should always have a docstring — is correct, and the package never required otherwise; the
# framing did.
#
# Julia's own code settles it. `Base.Experimental` holds 24 entries and the ones sampled on
# 2026-09-03 (`@optlevel`, `@compiler_options`, `Const`) all carry docstrings. Base marks an
# experimental surface AND documents it. The two are orthogonal, and this file pins that.

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
    # The precedent that makes "documented AND experimental" not a contradiction.
    @test isdefined(Base, :Experimental)
    for n in (Symbol("@optlevel"), Symbol("@compiler_options"), :Const)
        @testset "Base.Experimental.$n" begin
            @test isdefined(Base.Experimental, n)
            @test Base.Docs.hasdoc(Base.Experimental, n)
        end
    end
end

@testset "a docstring survives the macro" begin
    # The macro emits `Expr(:meta, :doc)` so a preceding docstring attaches to the definition
    # rather than to the block the macro expands to. Without it the two accounts would be
    # mutually exclusive in practice, whatever the documentation claimed.
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
    # Under the corrected framing, `marked_only` is not "fine because it is marked". It is a
    # public name with no docstring, and the audit has to be able to say so even though a mark
    # is present. Today `declared` absorbs it and the distinction is unavailable.
    a = audit(Both)
    @test_broken :marked_only in a.undocumented
    @test_broken hasproperty(a, :undocumented)
end

@testset "the check can require a docstring regardless of the mark" begin
    # `Aqua.test_undocumented_names` and `Docs.undocumented_names` already enforce
    # "every public name has a docstring". A package adopting both should not have to choose.
    @test_broken ExperimentalAPI.test_surface(Both; require_docstring=true) isa
        ExperimentalAPI.Audit
end

@testset "the reason is reachable from the rendered documentation" begin
    # A reader on the docs site should see that a name is declared unfinished, and why, without
    # the author repeating the reason by hand in the docstring — otherwise the two accounts drift.
    @test_broken ExperimentalAPI.docstring_note(Both, :documented_and_marked) isa
        AbstractString
end

@testset "what Documenter's checkdocs sees is not what audit sees" begin
    # `checkdocs = :public` fails a build on an undocumented public name and has no notion of a
    # third answer; `audit` accepts a mark instead. Both are legitimate and they disagree here.
    a = audit(Both)
    undocumented_by_base = setdiff(Base.Docs.undocumented_names(Both), [nameof(Both)])
    @test :marked_only in undocumented_by_base      # Base would flag it
    @test :marked_only ∉ a.unaccounted              # audit accepts the mark
    @test :silent in undocumented_by_base
    @test :silent in a.unaccounted                  # both flag this one
end
