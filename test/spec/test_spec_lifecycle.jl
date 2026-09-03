# The mark's exit — when it may be removed — and entry points that are not a single function.
#
# Scope: a mark that can only ever be added is a decoration. The exit is what makes it a work
# item. The entry point has to be a module or a script, as `#print axioms` answers for any
# declaration and not only for one it is handed.

using ExperimentalAPI: ExperimentalAPI, @experimental, audit, experimental, mark
using Test

module Lifecycle

using ExperimentalAPI

public verified_now, still_unverified, tracked_but_unresolved, settled, consumer, entry

# Reason discharged: reference value exists, suite exercises it. This one is removable.
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

# Without a third mark, the two above differ only in whether `tracking` is set, and a rule keyed
# on that alone would satisfy every assertion below. This one has a link and is still not ready.
@experimental(
    "reference value exists but disagrees with the literature at the third digit",
    since = v"0.1.0",
    tracking = "https://example.invalid/issues/2",
    tracked_but_unresolved(β::Float64) = β + 1e-9
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
    # Function-by-function does not scale to a package.
    @test_broken ExperimentalAPI.verdict(ExperimentalAPI.reach(Lifecycle)) === :depends
end

@testset "the module-level answer names which public entry points are affected" begin
    # "Something in here is experimental" is not actionable at package scale.
    @test_broken :entry in
        [e.name for e in ExperimentalAPI.reach(Lifecycle).affected_entries]
    # Control: `settled` reaches nothing marked and must not be listed.
    @test_broken :settled ∉
        [e.name for e in ExperimentalAPI.reach(Lifecycle).affected_entries]
end

@testset "a module with nothing marked comes back clean" begin
    # Control for the two above.
    @eval module CleanModule
    "Settled."
    f(x) = x
    public f
    end
    @test_broken ExperimentalAPI.verdict(ExperimentalAPI.reach(Main.CleanModule)) === :clean
end

@testset "a script can be the entry point" begin
    # The shape a researcher has: a file that produces a figure, not a package. The file must be
    # written — `tempname()` alone throws regardless of the implementation.
    path = tempname()
    write(path, "1 + 1\n")
    @test isfile(path)
    @test_broken hasproperty(ExperimentalAPI.reach_script(path), :reached)
end

# ── the exit: what licenses removing a mark ──────────────────────────────────────────────────

@testset "the tool says a mark is ready to be removed, and why" begin
    # Not "is this marked" but "may this stop being marked", with nameable evidence.
    @test_broken ExperimentalAPI.ready_to_promote(Lifecycle, :verified_now) === true
end

@testset "a mark whose reason still stands is NOT reported ready" begin
    # Control: rejects a checker that says "ready" for everything. All three are exercised by
    # this suite, so coverage cannot be the whole criterion.
    @test_broken ExperimentalAPI.ready_to_promote(Lifecycle, :still_unverified) === false
end

@testset "having a tracking link is not the same as being ready" begin
    # Control: rejects a rule keyed on `tracking` alone.
    @test mark(Lifecycle, :tracked_but_unresolved).tracking !== nothing
    @test mark(Lifecycle, :verified_now).tracking !== nothing
    @test mark(Lifecycle, :still_unverified).tracking === nothing
    @test_broken ExperimentalAPI.ready_to_promote(Lifecycle, :tracked_but_unresolved) ===
        false
end

@testset "removing a mark is reported as not breaking" begin
    # Stated in the direction a person asks it: I am about to delete this line, is that a
    # release event?
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
    # Control: promoting a mark and deleting the name both read as "the mark is gone", and only
    # one is safe.
    d = ExperimentalAPI.compare(
        Dict("stable" => ["settled", "verified_now"], "experimental" => Dict()),
        Dict("stable" => ["settled"], "experimental" => Dict()),
    )
    @test d.removed_stable == [:verified_now]
    @test ExperimentalAPI.isbreaking(d)
end

@testset "removing the mark flips its callers, and only its callers" begin
    # `consumer` becomes clean; `entry` does not, since it still reaches `still_unverified`.
    @test_broken ExperimentalAPI.verdict(
        ExperimentalAPI.reach(Lifecycle.consumer, Tuple{Float64}; ignore=[:verified_now])
    ) === :clean
    @test_broken ExperimentalAPI.verdict(
        ExperimentalAPI.reach(Lifecycle.entry, Tuple{Float64}; ignore=[:verified_now])
    ) === :depends
end

@testset "how long a mark has been standing is answerable" begin
    # `since` is recorded and nothing reads it; a mark that never expires is just a label.
    @test mark(Lifecycle, :still_unverified).since == v"0.1.0"
    # The number the caller needs, not `isa Any` — which is true of `nothing` from a stub.
    @test_broken ExperimentalAPI.age(Lifecycle, :still_unverified, v"0.9.0") == 8
end

@testset "the number of marks can only go down under a ratchet" begin
    # Same shape as `test_surface`'s skip list. Not `isa Audit`: that comes back whether the cap
    # was honoured or ignored, so assert what the cap does.
    @test length(experimental(Lifecycle)) == 3
    @test_broken ExperimentalAPI.exceeds_mark_cap(Lifecycle, 1) === true
    @test_broken ExperimentalAPI.exceeds_mark_cap(Lifecycle, 5) === false
end

@testset "a mark removed while callers still depend on it is caught" begin
    # Propagation read backwards: the line gets deleted because the author looked at the
    # definition, not at who reaches it.
    @test_broken :consumer in ExperimentalAPI.dependents(Lifecycle, :verified_now)
    # Control: rejects a `dependents` that returns every public name.
    @test_broken :settled ∉ ExperimentalAPI.dependents(Lifecycle, :verified_now)
end

@testset "the exit works at method granularity too" begin
    # The intersection neither this file nor `test_spec_dispatch.jl` covers: promoting one
    # method must not promote its siblings.
    @test_broken ExperimentalAPI.ready_to_promote isa Function
end
