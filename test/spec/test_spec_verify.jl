# "How well is this experimental thing actually verified?"
#
# This is the half of the intent that is cheap. A mark carries `file` and `line`; Julia's
# `--code-coverage` writes per-line execution counts. Joining them answers, with no new
# machinery: which marked definitions does the test suite never execute?
#
# It matters because the failure mode being guarded against is not a crash. It is a number that
# comes back and looks fine. A marked method with zero coverage is the worst case: unverified
# code, shipped, and never even run by its own suite.

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

# The suite that "verifies" the module. Deliberately partial — a fixture that exercised
# everything could not tell a working coverage join from one that always reports 100%.
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
        # The recorded line is the declaration, and the definition starts at or after it.
        @test occursin("@experimental", readlines(String(mk.file))[mk.line])
    end
end

@testset "a marked definition with no coverage at all is reported" begin
    @test_broken :never_exercised in [mk.name for mk in ExperimentalAPI.unverified(Covered)]
end

@testset "a marked definition that IS covered is not reported" begin
    # Without this, a checker that reports everything would pass the previous test.
    @test_broken :exercised ∉ [mk.name for mk in ExperimentalAPI.unverified(Covered)]
end

@testset "partial coverage is reported as partial, not as verified" begin
    @test_broken 0.0 < ExperimentalAPI.coverage(Covered, :half_exercised) < 1.0
end

@testset "coverage is absent, not zero, when the run had none enabled" begin
    # Julia writes no `.cov` files without `--code-coverage`. Reporting 0% then would call every
    # marked definition unverified on every ordinary test run — a false alarm that would get the
    # check switched off.
    @test_broken ExperimentalAPI.coverage(Covered, :exercised) === missing ||
        ExperimentalAPI.coverage(Covered, :exercised) isa Real
end

@testset "a mark whose line no longer matches its definition is reported stale" begin
    # Marks record file:line at macro-expansion. An edit above the definition moves the code but
    # not a previously written coverage file, and joining them then attributes the wrong lines.
    @test_broken ExperimentalAPI.stale_marks(Covered) isa AbstractVector
end

@testset "the verification report is data, not a printout" begin
    # Same convention as `audit`: the trust number comes back on the normal return path so a
    # release script can read it, rather than being printed for a human to eyeball.
    @test_broken ExperimentalAPI.verification(Covered) isa AbstractVector
end
