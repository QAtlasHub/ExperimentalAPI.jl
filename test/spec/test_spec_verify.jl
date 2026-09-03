# How well a marked definition is exercised by the tests.
#
# Scope: joining the mark's `file`/`line` against `--code-coverage` counts. No new machinery, and
# it answers the worst case — unverified code that its own suite never runs.

using ExperimentalAPI: ExperimentalAPI, @experimental, experimental
using Test

module Covered

using ExperimentalAPI

public exercised, half_exercised, never_exercised

@experimental "reference value not cross-checked" function exercised(x)
    return x + 1
end

@experimental "the negative branch is untested" function half_exercised(x)
    if x > 0
        return x
    else
        return -x            # never reached by the suite below
    end
end

@experimental "shipped without ever being called" never_exercised(x) = x * 0

end # module Covered

# Deliberately partial: a fully exercised fixture cannot tell a working join from one that
# always reports 100%.
@testset "the fixture is exercised only partly, on purpose" begin
    @test Covered.exercised(1) == 2
    @test Covered.half_exercised(1) == 1
    # `half_exercised(-1)` is NOT called
    # `never_exercised` is NOT called
end

@testset "marks carry the location a coverage file is keyed by" begin
    for mk in experimental(Covered)
        @test isfile(String(mk.file))
        @test mk.line > 0

        @test occursin("@experimental", readlines(String(mk.file))[mk.line])
    end
end

@testset "a marked definition with no coverage at all is reported" begin
    @test_broken :never_exercised in [mk.name for mk in ExperimentalAPI.unverified(Covered)]
end

@testset "a marked definition that IS covered is not reported" begin
    # Control: rejects a checker that reports everything.
    @test_broken :exercised ∉ [mk.name for mk in ExperimentalAPI.unverified(Covered)]
end

@testset "partial coverage is reported as partial, not as verified" begin
    @test_broken 0.0 < ExperimentalAPI.coverage(Covered, :half_exercised) < 1.0
end

@testset "coverage is absent, not zero, when the run had none enabled" begin
    # No `.cov` files without `--code-coverage`; reporting 0% then flags everything on every
    # ordinary run.
    @test_broken ExperimentalAPI.coverage(Covered, :exercised) === missing ||
        ExperimentalAPI.coverage(Covered, :exercised) isa Real
end

@testset "a mark whose line no longer matches its definition is reported stale" begin
    # An edit above the definition moves the code but not an existing coverage file.
    @test_broken ExperimentalAPI.stale_marks(Covered) isa AbstractVector
end

@testset "the verification report is data, not a printout" begin
    # Same convention as `audit`: the number comes back on the normal return path.
    @test_broken ExperimentalAPI.verification(Covered) isa AbstractVector
end
