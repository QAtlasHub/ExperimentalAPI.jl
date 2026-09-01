# The package runs its own check on itself. Every public name of ExperimentalAPI is either
# documented or declared @experimental — including the release layer, which is declared because
# its file format is a guess, not because declaring it was convenient.

using ExperimentalAPI: ExperimentalAPI, audit, experimental, test_surface
using Test

@testset "ExperimentalAPI accounts for its own surface" begin
    test_surface(ExperimentalAPI)
end

@testset "the release layer says what it is" begin
    declared = Set(mk.name for mk in experimental(ExperimentalAPI))
    @test declared ==
        Set([:snapshot, :read_snapshot, :write_snapshot, :compare, :isbreaking, :Diff])
    for mk in experimental(ExperimentalAPI)
        @test occursin("schema", mk.reason)      # the reason is the real one, not a placeholder
        @test !isempty(strip(mk.reason))
    end
end

@testset "@experimental is the only exported name" begin
    # Visibility is the language's job and this package leans on it: one macro is exported
    # because it is written at a definition site, and everything else is `public` and qualified.
    @test names(ExperimentalAPI; all=false) ⊇ [Symbol("@experimental")]
    @test Base.isexported(ExperimentalAPI, Symbol("@experimental"))
    for n in audit(ExperimentalAPI).surface
        n === Symbol("@experimental") && continue
        @test !Base.isexported(ExperimentalAPI, n)
        @test Base.ispublic(ExperimentalAPI, n)
    end
end

@testset "the registry binding is not part of the surface" begin
    @test ExperimentalAPI.MARKS_BINDING ∉ audit(ExperimentalAPI).surface
    @test ExperimentalAPI.MARKS_BINDING ∈ names(ExperimentalAPI; all=true)
end
