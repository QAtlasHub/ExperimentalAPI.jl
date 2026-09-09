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

"""
    documented_and_marked(x)

Documented AND marked, which is the shape `audit` asks for: a docstring is owed either way, and
the mark is the second account. It is also the shape whose coverage came back `missing`.
"""
@experimental "documented, and still unfinished" documented_and_marked(x) = x + 2

end # module Covered

# Deliberately partial: a fully exercised fixture cannot tell a working join from one that
# always reports 100%.
@testset "the fixture is exercised only partly, on purpose" begin
    @test Covered.exercised(1) == 2
    @test Covered.half_exercised(1) == 1
    @test Covered.documented_and_marked(1) == 3
    # `half_exercised(-1)` is NOT called
    # `never_exercised` is NOT called
end

@testset "a docstring above the mark does not hide the coverage" begin
    # `"docstring"` above a definition parses into ONE statement, `Core.@doc "…" <definition>`,
    # whose start line is the docstring's. The span search matched a sibling starting exactly on
    # `mk.line`, nothing started there, and the fraction came back `missing` — "no information" —
    # for a definition that had just run. Measured: entered once each in the same process, the
    # bare mark reported 1/1 and the documented one 0/0 `missing`.
    #
    # It matters because this is the shape the package RECOMMENDS. `audit` asks every public name
    # for a docstring and the unfinished ones for a mark, so a package following the advice got
    # the broken half.
    vs = Dict(v.mark.name => v for v in ExperimentalAPI.verification(Covered))
    doc = vs[:documented_and_marked]
    bare = vs[:exercised]
    if bare.fraction === missing
        # No coverage in this run at all — then BOTH must say so, which is the claim either way.
        @test doc.fraction === missing
    else
        @test doc.fraction !== missing
        @test doc.fraction == bare.fraction == 1.0
        @test doc.total > 0
    end
end

@testset "marks carry the location a coverage file is keyed by" begin
    for mk in experimental(Covered)
        @test isfile(String(mk.file))
        @test mk.line > 0

        @test occursin("@experimental", readlines(String(mk.file))[mk.line])
    end
end

# Which half of each claim below can run depends on whether this process has coverage counters at
# all. Both halves are assertions: without `--code-coverage` the contract under test is that the
# answer is `missing` rather than a number, and that contract is exactly what stops every marked
# definition being reported unverified on an ordinary run. CI runs the suite with coverage on, so
# the measured half is what gates a pull request.
const COVERED = ExperimentalAPI.coverage_enabled()

@testset "the run knows whether it has coverage counters at all" begin
    @test COVERED == (Base.JLOptions().code_coverage != 0)
end

@testset "a marked definition the suite never entered is reported" begin
    # Unconditional: the signal is the probe the mark already emits, not the coverage data.
    # `--code-coverage` cannot answer this on every version — measured on 1.14.0-DEV.3115, the
    # definition line of a method nothing ever called now carries a counter, so a one-line
    # definition reads as fully covered on the strength of having been defined.
    @test :never_exercised in [mk.name for mk in ExperimentalAPI.unverified(Covered)]
    @test ExperimentalAPI.coverage(Covered, :never_exercised) == 0.0
end

@testset "a marked definition that IS covered is not reported" begin
    # Control: rejects a checker that reports everything.
    @test :exercised ∉ [mk.name for mk in ExperimentalAPI.unverified(Covered)]
end

@testset "partial coverage is reported as partial, not as verified" begin
    c = ExperimentalAPI.coverage(Covered, :half_exercised)
    if COVERED
        @test 0.0 < c < 1.0
        # …and the fully exercised one is not reported as partial, so the number is not a
        # constant that happens to sit inside the interval.
        @test ExperimentalAPI.coverage(Covered, :exercised) == 1.0
    else
        @test c === missing
    end
end

@testset "coverage is absent, not zero, when the run had none enabled" begin
    # No counters without `--code-coverage`; reporting 0% then flags everything on every
    # ordinary run.
    c = ExperimentalAPI.coverage(Covered, :exercised)
    @test COVERED ? c isa Real : c === missing
    # A name that carries no mark has no definition to measure, whatever the run was started with.
    @test ExperimentalAPI.coverage(Covered, :not_a_name) === missing
end

@testset "a mark whose line no longer matches its definition is reported stale" begin
    # An edit above the definition moves the code but not the mark, and every join keyed on that
    # line — the coverage one here — then describes the wrong lines silently.
    @test ExperimentalAPI.stale_marks(Covered) isa AbstractVector
    # This file has not been edited under itself, so nothing is stale…
    @test isempty(ExperimentalAPI.stale_marks(Covered))

    # …and the check can fire. Written to a file, loaded, then the file edited above the
    # declaration: an in-memory module whose source has moved is exactly the state a long REPL
    # session is in.
    dir = mktempdir()
    path = joinpath(dir, "moved.jl")
    write(
        path,
        """
        module Moved
        using ExperimentalAPI
        public f
        @experimental "shape not settled" f(x) = x
        end
        """,
    )
    include(path)
    @test isempty(ExperimentalAPI.stale_marks(Main.Moved))     # before the edit
    write(path, "# a line inserted above the declaration\n" * read(path, String))
    empty!(ExperimentalAPI._SOURCE_CACHE)
    empty!(ExperimentalAPI._PARSE_CACHE)
    @test !isempty(ExperimentalAPI.stale_marks(Main.Moved))    # after it
    @test only(ExperimentalAPI.stale_marks(Main.Moved)).name === :f
end

@testset "the verification report is data, not a printout" begin
    # Same convention as `audit`: the number comes back on the normal return path.
    vs = ExperimentalAPI.verification(Covered)
    @test vs isa AbstractVector
    @test length(vs) == length(ExperimentalAPI.experimental(Covered))
    @test all(v -> v isa ExperimentalAPI.Verification, vs)
    @test Set(v.mark.name for v in vs) ==
        Set([:exercised, :half_exercised, :never_exercised, :documented_and_marked])
end
