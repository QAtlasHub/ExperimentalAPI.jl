# The mark has an exit, and something has to say when it may be taken.
#
# From the design letter on General#166832:
#
#   「この `@experimental` を安全に外していく、というのを中間ゴールに据えた開発が可能になります」
#
# That is the part that makes this a work item rather than a permanent label. A mark that can only
# ever be added is a decoration; a mark with a defined exit is a plan. Nothing in the rest of this
# directory covers the exit, so it is here.
#
# The other half is end-to-end analysis. The letter's reading of Lean is that `sorry` lets the
# whole development be checked with the unproven proposition still in it —
#
#   「`sorry`がついた真偽不明の命題として e2e でコードの解析を実行できる」
#
# — and `#print axioms` answers for any declaration, not only for one you hand it. The analogue
# here is an entry point that is a MODULE or a script, not just a function with argument types.

using ExperimentalAPI: ExperimentalAPI, @experimental, audit, experimental, mark
using Test

module Lifecycle

using ExperimentalAPI

public verified_now, still_unverified, settled, consumer, entry

# A mark whose reason has been discharged: the reference value now exists and the test suite
# exercises it. This is the one that should be removable.
@experimental(
    "no reference value yet",
    since = v"0.1.0",
    tracking = "https://example.invalid/issues/1",
    verified_now(β::Float64) = 2 * β
)

# A mark whose reason still stands.
@experimental(
    "convergence not established below β ≈ 0.1",
    since = v"0.1.0",
    still_unverified(β::Float64) = β * 1.0000001
)

"Settled from the start."
settled(β::Float64) = β

# A caller that depends on the mark. Removing the mark must flip its verdict, and nothing else.
consumer(β::Float64) = verified_now(β) + settled(β)

# The whole-module entry point: everything a user of this package can reach.
entry(β::Float64) = consumer(β) + still_unverified(β)

end # module Lifecycle

# ── the fixture can disagree ─────────────────────────────────────────────────────────────────

@testset "two marks, one of which is ready to go and one of which is not" begin
    names = Set(mk.name for mk in experimental(Lifecycle))
    @test :verified_now in names
    @test :still_unverified in names
    @test :settled ∉ names
    @test Lifecycle.verified_now(0.5) == 1.0      # both are exercised by this suite…
    @test Lifecycle.still_unverified(0.5) > 0.5   # …so coverage alone cannot separate them
end

# ── end-to-end: an entry point that is not a single function ─────────────────────────────────

@testset "a whole module can be the entry point" begin
    # `#print axioms` answers for any declaration; the analogue is "does anything this package
    # exposes reach unvalidated code". Asking function-by-function does not scale to a package.
    @test_broken ExperimentalAPI.verdict(ExperimentalAPI.reach(Lifecycle)) === :depends
end

@testset "the module-level answer names which public entry points are affected" begin
    # "Something in here is experimental" is not actionable for a package with 310 public names.
    @test_broken :entry in
        [e.name for e in ExperimentalAPI.reach(Lifecycle).affected_entries]
end

@testset "a module with nothing marked comes back clean" begin
    # The negative control for the two above.
    @eval module CleanModule
    "Settled."
    f(x) = x
    public f
    end
    @test_broken ExperimentalAPI.verdict(ExperimentalAPI.reach(Main.CleanModule)) === :clean
end

@testset "a script can be the entry point" begin
    # The shape a researcher actually has: not a package, a file that produces a figure.
    @test_broken ExperimentalAPI.reach_script(tempname()) isa Any
end

# ── the exit: what licenses removing a mark ──────────────────────────────────────────────────

@testset "the tool says a mark is ready to be removed, and why" begin
    # Not "is this marked" but "may this stop being marked". The evidence has to be nameable:
    # the reason discharged, the definition exercised, a reference value present.
    @test_broken ExperimentalAPI.ready_to_promote(Lifecycle, :verified_now) === true
end

@testset "a mark whose reason still stands is NOT reported ready" begin
    # Without this, a checker that says "ready" for everything passes the test above. Both
    # definitions in the fixture are exercised by this suite, so coverage cannot be the whole
    # criterion — which is the point.
    @test_broken ExperimentalAPI.ready_to_promote(Lifecycle, :still_unverified) === false
end

@testset "removing a mark is reported as not breaking" begin
    # `compare` already treats experimental → stable as non-breaking for names. The exit needs it
    # stated in the direction a person asks the question: I am about to delete this line, is that
    # a release event?
    # Already implemented — promoted from @test_broken after the suite reported Unexpected Pass,
    # which is the mechanism this directory exists for.
    @test !ExperimentalAPI.isbreaking(
        ExperimentalAPI.compare(
            Dict(
                "stable" => ["settled"],
                "experimental" => Dict("verified_now" => Dict("reason" => "r")),
            ),
            Dict("stable" => ["settled", "verified_now"], "experimental" => Dict()),
        ),
    )
end

@testset "…but DELETING it outright still is" begin
    # The negative control. Promoting a mark and deleting the name are both "the mark is gone" to
    # a careless reading, and only one of them is safe. Without this the test above would pass for
    # an `isbreaking` that always answers false.
    d = ExperimentalAPI.compare(
        Dict("stable" => ["settled", "verified_now"], "experimental" => Dict()),
        Dict("stable" => ["settled"], "experimental" => Dict()),
    )
    @test d.removed_stable == [:verified_now]
    @test ExperimentalAPI.isbreaking(d)
end

@testset "removing the mark flips its callers, and only its callers" begin
    # The propagation half of the exit. After `verified_now` is promoted, `consumer` becomes
    # clean; `entry` does not, because it still reaches `still_unverified`. A tool that flips
    # everything, or nothing, fails one of these.
    @test_broken ExperimentalAPI.verdict(
        ExperimentalAPI.reach(Lifecycle.consumer, Tuple{Float64}; ignore=[:verified_now])
    ) === :clean
    @test_broken ExperimentalAPI.verdict(
        ExperimentalAPI.reach(Lifecycle.entry, Tuple{Float64}; ignore=[:verified_now])
    ) === :depends
end

@testset "how long a mark has been standing is answerable" begin
    # `since` is recorded and nothing reads it. "Experimental" that never expires is just a label,
    # and the letter's framing — an intermediate goal — needs the clock to be visible.
    @test mark(Lifecycle, :still_unverified).since == v"0.1.0"
    @test_broken ExperimentalAPI.age(Lifecycle, :still_unverified, v"0.9.0") isa Any
end

@testset "the number of marks can only go down under a ratchet" begin
    # The mechanism that makes "an intermediate goal" real rather than aspirational, and the same
    # shape as `test_surface`'s skip list, which already only shrinks.
    @test_broken ExperimentalAPI.test_surface(Lifecycle; max_marks=1) isa
        ExperimentalAPI.Audit
end

@testset "a mark removed while callers still depend on it is caught" begin
    # The failure mode of removing one carelessly: the line is deleted because the author looked
    # at the definition, not at who reaches it. That is what propagation is for, read backwards.
    @test_broken !isempty(ExperimentalAPI.dependents(Lifecycle, :verified_now))
end
