# The examples are documentation that runs.
#
# `docs/src/walkthrough.md` is generated from `examples/walkthrough.jl` by Literate at build time,
# so every output on that page is whatever the script printed. This file is the other half of that
# arrangement: without it, a change in `src/` could quietly rewrite what the documentation claims
# and nothing would go red until somebody read the rendered page.
#
# Twice in this package's first week a documented sample output turned out to be something the
# code could not produce. Both would have failed here.

using ExperimentalAPI: ExperimentalAPI, entered, reach, verdict
using Test

const EXAMPLES = joinpath(@__DIR__, "..", "examples")

"Everything `script` wrote, as its own process, with the two streams kept apart."
function run_example(script)
    out, err = IOBuffer(), IOBuffer()
    cmd = `$(Base.julia_cmd()) --startup-file=no --project=$(Base.active_project()) $script`
    run(pipeline(cmd; stdout=out, stderr=err))
    return String(take!(out)), String(take!(err))
end

@testset "examples/sweep.jl keeps the result and the notice on different streams" begin
    out, err = run_example(joinpath(EXAMPLES, "sweep.jl"))
    @test occursin("mean energy density", out)
    # The claim the front page makes: `julia sweep.jl > result.dat` keeps the data clean. If the
    # summary ever moves to `stdout` it corrupts every machine-readable output in the wild.
    @test !occursin("ExperimentalAPI:", out)
    @test occursin("this run entered 1 experimental definition", err)
    # The REASON travels, not just the symbol — that is the whole difference from a linter.
    @test occursin("convergence not established below", err)
    # …and the control, which is what makes a clean answer worth anything: `susceptibility` is
    # marked and was never called, so it is ABSENT rather than reported with a count of zero.
    @test !occursin("susceptibility", err)
end

# Run once; assert against it below. Loading it into a module of its own keeps its `Ising` out of
# `Main`, where the rest of the suite lives.
const WALK = Module(:WalkthroughExample)
Base.include(WALK, joinpath(EXAMPLES, "walkthrough.jl"))

@testset "examples/walkthrough.jl still shows what the page says it shows" begin
    Ising = WALK.Ising
    βs = collect(0.05:0.05:2.0)

    # The three-valued answer, in the order the page presents it. A verdict that flips is a page
    # that lies, and these are the three sentences the page spends the most words on.
    @test verdict(reach(Ising.report, Tuple{Vector{Float64}})) === :depends
    @test verdict(reach(Ising.normalise, Tuple{Vector{Float64},Float64})) === :clean
    @test verdict(reach(Ising.apply, Tuple{Vector{Function},Float64})) === :unknown

    # "Two definitions are marked; one is in this run." Both halves, because the second is the
    # control for the first.
    marked = Set(mk.name for mk in ExperimentalAPI.experimental(Ising))
    @test marked == Set([:energy, :susceptibility])
    rec = ExperimentalAPI.record(() -> Ising.report(βs); paths=false, timing=false)
    @test Set(h.name for h in rec) == Set([:energy])
    # Forty calls for a forty-point sweep — the page prints this count, and it is exact rather
    # than sampled, which is the property that makes printing it defensible.
    @test only(rec).count == length(βs)

    # The audit's finding. `apply` is public, undocumented and unmarked, and the page says so.
    a = ExperimentalAPI.audit(Ising)
    @test a.unaccounted == [:apply]

    # The release gate, both ways round: the same removal is breaking or not depending on whether
    # the notice was given at the definition site.
    old = ExperimentalAPI.snapshot(Ising)
    push!(old["stable"], "old_verb")
    old["experimental"]["draft_energy"] = Dict("reason" => "never validated")
    @test ExperimentalAPI.isbreaking(ExperimentalAPI.compare(old, Ising))
    only_experimental = ExperimentalAPI.snapshot(Ising)
    only_experimental["experimental"]["draft_energy"] = Dict("reason" => "never validated")
    @test !ExperimentalAPI.isbreaking(ExperimentalAPI.compare(only_experimental, Ising))
end
