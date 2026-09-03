# Profiling: what a real run actually went through.
#
# This is the half of the intent a reviewer cannot answer with "put it in the docstring". After a
# twelve-hour DMRG run the question is not "is this function experimental" but "did the number I
# am about to put in a paper come out of code nobody has validated, and how much of it".
#
# Everything here is `@test_broken`. The cheap route was measured on 2026-09-03 and does not
# work: `Profile.fetch` frames for inlined callees carry no `MethodInstance`, so a sampling
# profiler attributes ZERO samples to marked methods — and small functions, which is most of what
# gets marked, are exactly the ones that get inlined.

using ExperimentalAPI: ExperimentalAPI, @experimental
using Test

module Sim

using ExperimentalAPI

public energy, correlator, driver, sweep, cold, Model

struct Model
    β::Float64
end

@experimental "convergence not established below β ≈ 0.1" energy(m::Model) = m.β * 1.0000001
@experimental "edge cases at zero separation untested" correlator(m::Model, r::Int) =
    m.β / (r + 1)
"Settled."
partition(m::Model) = exp(-m.β)

inner(m::Model) = energy(m) + partition(m)
function driver(m::Model, n::Int)
    s = 0.0
    for _ in 1:n
        s += inner(m)
    end
    return s
end
function sweep(m::Model, n::Int)
    s = 0.0
    for r in 1:n
        s += correlator(m, r)
    end
    return s
end
@experimental "never exercised by the fixture" cold(m::Model) = m.β

end # module Sim

const M = Sim.Model(0.5)

# ── the basic question ───────────────────────────────────────────────────────────────────────

@testset "a run reports which marked definitions it entered" begin
    @test_broken :energy in
        [h.name for h in ExperimentalAPI.record(() -> Sim.driver(M, 100))]
end

@testset "a run reports how many times each was entered" begin
    @test_broken ExperimentalAPI.record(() -> Sim.driver(M, 100))[1].count == 100
end

@testset "a marked definition the run never entered is absent, not zero" begin
    # A recorder that lists every mark in the module passes the two tests above. This is the
    # control that separates "observed" from "enumerated".
    @test_broken :cold ∉ [h.name for h in ExperimentalAPI.record(() -> Sim.driver(M, 10))]
end

@testset "a run that touches nothing marked reports an empty record, not an error" begin
    @test_broken ExperimentalAPI.record(() -> sum(1:10)) == []
end

@testset "a record distinguishes 'touched nothing' from 'recording was off'" begin
    # Both would otherwise be an empty vector, and they mean opposite things: one is a clean
    # result, the other is a measurement that never happened.
    @test_broken ExperimentalAPI.record(() -> sum(1:10)).enabled === true
end

# ── granularity ──────────────────────────────────────────────────────────────────────────────

@testset "attribution is to a method, not to a name" begin
    # `QAtlas.fetch` has 570 methods. "the run touched fetch" is unusable.
    @test_broken first(ExperimentalAPI.record(() -> Sim.driver(M, 10))).method isa Method
end

@testset "two marked definitions in one run are reported separately" begin
    @test_broken length(
        ExperimentalAPI.record(() -> (Sim.driver(M, 10); Sim.sweep(M, 10)))
    ) == 2
end

@testset "the call site that reached the mark is recorded" begin
    # `energy` was entered from `inner`, which was entered from `driver`. Knowing only that a
    # mark was hit does not tell you which part of your own code to distrust.
    @test_broken !isempty(first(ExperimentalAPI.record(() -> Sim.driver(M, 10))).callers)
end

@testset "the whole path from the entry point is available" begin
    @test_broken :driver in first(ExperimentalAPI.record(() -> Sim.driver(M, 10))).paths[1]
end

# ── proportion, not just presence ────────────────────────────────────────────────────────────

@testset "the record says what fraction of the run was inside experimental code" begin
    # "It touched experimental code" and "97% of the run was inside it" are different verdicts
    # about the same result, and only the second decides whether the number is usable.
    @test_broken 0.0 <
        ExperimentalAPI.experimental_fraction(
            ExperimentalAPI.record(() -> Sim.driver(M, 100_000))
        ) <=
        1.0
end

@testset "inclusive and exclusive time are distinguished" begin
    # A marked wrapper that spends all its time in settled code is not the same risk as a marked
    # kernel that does the arithmetic itself.
    @test_broken let h = first(ExperimentalAPI.record(() -> Sim.driver(M, 1000)))
        h.inclusive >= h.exclusive
    end
end

# ── mechanism constraints ────────────────────────────────────────────────────────────────────

@testset "recording survives inlining" begin
    # The measured reason the sampling route failed. `Sim.energy` is a one-line function; the
    # optimiser will inline it. Any mechanism that only works on `@noinline` code is not a
    # mechanism for this problem.
    @test_broken ExperimentalAPI.record(() -> Sim.driver(M, 100))[1].count == 100
end

@testset "recording is off by default" begin
    @test_broken ExperimentalAPI.recording() === false
end

@testset "the run pays nothing when recording is off" begin
    # The property `@experimental` currently advertises. If instrumentation becomes
    # unconditional, every iteration of an inner loop pays for a mark nobody is reading.
    @test_broken ExperimentalAPI.overhead_when_disabled() == 0.0
end

@testset "the overhead when recording IS on is measured and reported" begin
    # A tool that slows a twelve-hour run by 40x will not be used on a twelve-hour run. Whatever
    # it costs, the number has to be available rather than discovered.
    @test_broken ExperimentalAPI.record(() -> Sim.driver(M, 1000)).overhead isa Real
end

@testset "recording nests without double counting" begin
    @test_broken ExperimentalAPI.record(
        () -> ExperimentalAPI.record(() -> Sim.driver(M, 10))
    )[1].count == 10
end

@testset "an exception inside the recorded block still yields a record" begin
    # A run that crashed halfway is exactly when you want to know what it went through.
    @test_broken ExperimentalAPI.record(() -> error("boom"); rethrow=false) isa
        AbstractVector
end

# ── concurrency and distribution ─────────────────────────────────────────────────────────────

@testset "hits from every thread are attributed" begin
    # HPC code is threaded. A recorder that only sees the main thread reports a fraction of the
    # truth and calls it the truth.
    threaded() = Threads.@threads for _ in 1:8
        Sim.driver(M, 100)
    end
    @test_broken ExperimentalAPI.record(threaded)[1].count == 800
end

@testset "records from separate processes merge into one" begin
    # The same shape as TestShards' shard records: a distributed sweep produces one record per
    # worker, and the provenance statement is about the whole run.
    @test_broken ExperimentalAPI.merge_records([
        ExperimentalAPI.record(() -> Sim.driver(M, 10)) for _ in 1:2
    ]) isa AbstractVector
end

@testset "merging is associative and order-independent" begin
    # Workers finish in arbitrary order; the provenance must not depend on that.
    @test_broken let a = ExperimentalAPI.record(() -> Sim.driver(M, 10)),
        b = ExperimentalAPI.record(() -> Sim.sweep(M, 10))

        ExperimentalAPI.merge_records([a, b]) == ExperimentalAPI.merge_records([b, a])
    end
end

# ── coexistence with the profiler people already use ─────────────────────────────────────────

@testset "recording does not disturb Profile" begin
    # Nobody will adopt a provenance tool that breaks their performance workflow.
    @test_broken ExperimentalAPI.record(() -> Sim.driver(M, 10); with_profile=true) isa
        AbstractVector
end

@testset "an existing Profile buffer can be attributed after the fact" begin
    # If someone already profiled a run, they should not have to run it again for twelve hours.
    @test_broken ExperimentalAPI.attribute(Profile.fetch()) isa AbstractVector
end

# ── the output is evidence, not a printout ───────────────────────────────────────────────────

@testset "a record is serialisable" begin
    # The point is to put it next to a figure in a paper. A pretty-printed table is not evidence.
    @test_broken ExperimentalAPI.write_record(
        tempname(), ExperimentalAPI.record(() -> Sim.driver(M, 10))
    ) isa AbstractString
end

@testset "a serialised record round-trips" begin
    @test_broken ExperimentalAPI.read_record(
        ExperimentalAPI.write_record(
            tempname(), ExperimentalAPI.record(() -> Sim.driver(M, 10))
        ),
    ) isa AbstractVector
end

@testset "a record names the versions it was taken against" begin
    # `energy` being experimental in v0.3 says nothing about v0.9. A provenance record that does
    # not pin the version is not provenance.
    @test_broken ExperimentalAPI.record(() -> Sim.driver(M, 10)).versions isa AbstractDict
end

@testset "the reason is carried into the record" begin
    # The record has to be readable a year later by someone who never saw the source.
    @test_broken occursin(
        "convergence", first(ExperimentalAPI.record(() -> Sim.driver(M, 10))).reason
    )
end

# ── using it as a gate ───────────────────────────────────────────────────────────────────────

@testset "a run can be asserted to have touched nothing experimental" begin
    # The publishable-result gate: this figure was produced without entering unvalidated code.
    @test_broken ExperimentalAPI.assert_clean(() -> 1 + 1)
end

@testset "the assertion fails, naming the mark, when the run is not clean" begin
    # A gate that cannot be shown to fire has not been shown to be a gate.
    @test_broken !ExperimentalAPI.assert_clean(() -> Sim.driver(M, 10); throw=false)
end
