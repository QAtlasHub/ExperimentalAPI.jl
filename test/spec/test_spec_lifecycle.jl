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

# The exit condition is written down where the reason is, and it is a predicate rather than a
# sentence: "what would discharge this" is knowledge the author has and nobody else can recover.
const REFERENCE = Ref(false)

# Reason discharged: the reference value now exists, so this one is removable.
@experimental(
    "no reference value yet",
    since = v"0.1.0",
    tracking = "https://example.invalid/issues/1",
    until = () -> REFERENCE[],
    verified_now(β::Float64) = 2 * β
)

# A mark whose reason still stands, and which never said what would settle it. `ready_to_promote`
# can only ever answer `false` for this one, which is itself a finding.
@experimental(
    "convergence not established below β ≈ 0.1",
    since = v"0.1.0",
    still_unverified(β::Float64) = β * 1.0000001
)

# Without a third mark, the two above differ only in whether `tracking` is set, and a rule keyed
# on that alone would satisfy every assertion below. This one has a link, has a stated exit, and
# the exit is not met.
@experimental(
    "reference value exists but disagrees with the literature at the third digit",
    since = v"0.1.0",
    tracking = "https://example.invalid/issues/2",
    until = () -> false,
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
    @test ExperimentalAPI.verdict(ExperimentalAPI.reach(Lifecycle)) === :depends
end

@testset "the module-level answer names which public entry points are affected" begin
    # "Something in here is experimental" is not actionable at package scale.
    @test :entry in [e.name for e in ExperimentalAPI.reach(Lifecycle).affected_entries]
    # Control: `settled` reaches nothing marked and must not be listed.
    @test :settled ∉ [e.name for e in ExperimentalAPI.reach(Lifecycle).affected_entries]
end

@testset "a module with nothing marked comes back clean" begin
    # Control for the two above.
    @eval module CleanModule
    "Settled."
    f(x) = x
    public f
    end
    @test ExperimentalAPI.verdict(ExperimentalAPI.reach(Main.CleanModule)) === :clean
end

@testset "a script can be the entry point" begin
    # The shape a researcher has: a file that produces a figure, not a package. The file must be
    # written — `tempname()` alone throws regardless of the implementation.
    #
    # `hasproperty(…, :reached)` was the whole of this claim for a while, and it is satisfied by
    # an implementation that returns an empty `Reach` for every input. So the script that reaches
    # a mark and the one that does not are both run, and the verdicts have to differ.
    dir = mktempdir()
    plain = joinpath(dir, "plain.jl")
    write(plain, "1 + 1\n")
    @test isfile(plain)
    r = ExperimentalAPI.reach_script(plain)
    @test hasproperty(r, :reached)
    @test ExperimentalAPI.verdict(r) === :clean

    # A script in the shape it is actually written in: `using`, then work. The `using` line is
    # evaluated in a scratch module — that is what `reach_script` costs, and it is why the
    # analysis can resolve `Lifecycle.consumer` at all.
    dirty = joinpath(dir, "figure.jl")
    write(
        dirty,
        """
        using Main: Lifecycle
        const RESULT = Lifecycle.consumer(0.5)
        RESULT
        """,
    )
    d = ExperimentalAPI.reach_script(dirty)
    @test ExperimentalAPI.verdict(d) === :depends
    @test :verified_now in [x.mark.name for x in d.reached]
    # …and the entry is named after the file, so a directory of scripts is readable.
    @test :figure in [e.name for e in d.affected_entries] || Symbol("figure.jl") in [e.name for e in d.affected_entries]

    # Control of the same shape: same `using`, same depth, nothing marked behind it.
    settled_path = joinpath(dir, "settled.jl")
    write(
        settled_path,
        """
        using Main: Lifecycle
        const RESULT = Lifecycle.settled(0.5)
        RESULT
        """,
    )
    @test ExperimentalAPI.verdict(ExperimentalAPI.reach_script(settled_path)) === :clean
end

# ── the exit: what licenses removing a mark ──────────────────────────────────────────────────

@testset "the tool says a mark is ready to be removed, and why" begin
    # Not "is this marked" but "may this stop being marked", answered by the thing that knows:
    # the condition the author wrote next to the reason.
    Lifecycle.REFERENCE[] = false
    @test ExperimentalAPI.ready_to_promote(Lifecycle, :verified_now) === false
    Lifecycle.REFERENCE[] = true
    @test ExperimentalAPI.ready_to_promote(Lifecycle, :verified_now) === true
    # …and the verdict follows the world, not the source: nothing about the declaration changed
    # between those two lines.
    @test :verified_now in [mk.name for mk in ExperimentalAPI.promotable(Lifecycle)]
end

@testset "a mark whose reason still stands is NOT reported ready" begin
    # Control: rejects a checker that says "ready" for everything. All three are exercised by
    # this suite, so coverage cannot be the whole criterion.
    @test ExperimentalAPI.ready_to_promote(Lifecycle, :still_unverified) === false
    # …and it is reported as the different finding it is: a mark that never said what would
    # settle it can be added and never mechanically retired.
    @test :still_unverified in
        [mk.name for mk in ExperimentalAPI.marks_without_exit(Lifecycle)]
    @test :verified_now ∉ [mk.name for mk in ExperimentalAPI.marks_without_exit(Lifecycle)]
end

@testset "having a tracking link is not the same as being ready" begin
    # Control: rejects a rule keyed on `tracking` alone.
    @test mark(Lifecycle, :tracked_but_unresolved).tracking !== nothing
    @test mark(Lifecycle, :verified_now).tracking !== nothing
    @test mark(Lifecycle, :still_unverified).tracking === nothing
    @test ExperimentalAPI.ready_to_promote(Lifecycle, :tracked_but_unresolved) === false
    # …and neither is having an exit condition: this one has one, and it is not met.
    @test mark(Lifecycle, :tracked_but_unresolved).until !== nothing
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
    @test ExperimentalAPI.verdict(
        ExperimentalAPI.reach(Lifecycle.consumer, Tuple{Float64}; ignore=[:verified_now])
    ) === :clean
    @test ExperimentalAPI.verdict(
        ExperimentalAPI.reach(Lifecycle.entry, Tuple{Float64}; ignore=[:verified_now])
    ) === :depends
end

@testset "how long a mark has been standing is answerable" begin
    # `since` was recorded and nothing read it; a mark that never expires is just a label.
    @test mark(Lifecycle, :still_unverified).since == v"0.1.0"
    # The number the caller needs, not `isa Any` — which is true of `nothing` from a stub.
    @test ExperimentalAPI.age(Lifecycle, :still_unverified, v"0.9.0") == 8
    # Counted on the axis a bump is breaking along: under 0.x that is the minor component.
    @test ExperimentalAPI.age(Lifecycle, :still_unverified, v"0.1.9") == 0
    @test ExperimentalAPI.age(Lifecycle, :still_unverified, v"3.0.0") == 3
    # A mark with no `since` has no age, and `missing` is the honest answer rather than zero.
    @eval module NoSince
    using ExperimentalAPI
    public f
    @experimental "undated" f(x) = x
    end
    @test ExperimentalAPI.age(Main.NoSince, :f, v"9.9.9") === missing
    # The list form a CI job asks for, and a control that it is not everything.
    @test length(ExperimentalAPI.stale_since(Lifecycle, v"0.9.0")) == 3
    @test isempty(ExperimentalAPI.stale_since(Lifecycle, v"0.1.0"))
end

@testset "the number of marks can only go down under a ratchet" begin
    # Same shape as `test_surface`'s skip list. Not `isa Audit`: that comes back whether the cap
    # was honoured or ignored, so assert what the cap does.
    @test length(experimental(Lifecycle)) == 3
    @test ExperimentalAPI.exceeds_mark_cap(Lifecycle, 1) === true
    @test ExperimentalAPI.exceeds_mark_cap(Lifecycle, 5) === false
    @test ExperimentalAPI.exceeds_mark_cap(Lifecycle, 3) === false     # the cap is inclusive
end

@testset "a mark removed while callers still depend on it is caught" begin
    # Propagation read backwards: the line gets deleted because the author looked at the
    # definition, not at who reaches it.
    @test :consumer in ExperimentalAPI.dependents(Lifecycle, :verified_now)
    # Control: rejects a `dependents` that returns every public name.
    @test :settled ∉ ExperimentalAPI.dependents(Lifecycle, :verified_now)
end

@testset "the exit works at method granularity too" begin
    # The intersection neither this file nor `test_spec_dispatch.jl` covers: promoting one
    # method must not promote its siblings.
    @test ExperimentalAPI.ready_to_promote isa Function
    @eval module MethodExit
    using ExperimentalAPI
    public g
    struct A end
    struct B end
    g(::A) = 1
    @experimental("the B branch is a placeholder", until = () -> true, g(::B) = 2)
    end
    a = which(Main.MethodExit.g, Tuple{Main.MethodExit.A})
    b = which(Main.MethodExit.g, Tuple{Main.MethodExit.B})
    @test ExperimentalAPI.ready_to_promote(ExperimentalAPI.mark(b)) === true
    # Control: the sibling carries no mark at all, so there is nothing to promote…
    @test ExperimentalAPI.mark(a) === nothing
    # …and promoting one method's mark is not a statement about the name.
    @test ExperimentalAPI.isexperimental(Main.MethodExit, :g)
end
