#md # ```@meta
#md # CurrentModule = ExperimentalAPI
#md # ```
#md #
# # A walkthrough, run rather than typed
#
# Every output on this page was produced by executing the code above it. The script is
# `examples/walkthrough.jl` in the repository and it runs on its own:
#
# ```console
# $ julia --project=examples examples/walkthrough.jl
# ```
#
# That is not a stylistic choice. Twice in this package's first week a documented sample output
# turned out to be something the code could not produce — a report shown in the wrong order, and
# a frame count written from a simplified trace. Both were prose describing behaviour rather than
# behaviour producing prose. This page is the other way round.

# ## The situation the package is for
#
# A run finishes and hands back a number. Nothing in the number says which of the code paths
# behind it had never been validated.

module Ising

using ExperimentalAPI

public energy, correlator, susceptibility, sweep, report, scale, normalise, apply

"""
    energy(β)

Free energy density of the 1D Ising chain at inverse temperature `β`.
"""
@experimental "convergence not established below β ≈ 0.1" energy(β::Float64) =
    -log(2cosh(β)) / β

"""
    correlator(β, r)

Two-point function at separation `r`. Exact in closed form for the 1D chain.
"""
correlator(β::Float64, r::Int) = tanh(β)^r

"""
    susceptibility(β)

Magnetic susceptibility. Marked, and deliberately not on the path this page walks — it is the
control for every "the run entered nothing" answer below.
"""
@experimental "extrapolated; no reference value" susceptibility(β::Float64) = exp(2β) / β

"Mean energy density over `βs`."
sweep(βs::Vector{Float64}) = sum(energy, βs) / length(βs)

"The number a caller actually asks for. It never names `energy`."
report(βs::Vector{Float64}) = round(sweep(βs); digits=4)

"Rescale one already-computed value."
scale(x::Float64, c::Float64) = c * x

"Post-processing. Nothing unvalidated is behind this one."
function normalise(xs::Vector{Float64}, c::Float64)
    total = 0.0
    for x in xs
        total += scale(x, c)
    end
    return total
end

apply(fs::Vector{Function}, β::Float64) = fs[1](β)

end # module Ising

βs = collect(0.05:0.05:2.0)
Ising.report(βs)

# One `Float64`. It is correct, it is the number that goes in the plot, and it went through a
# definition whose own author wrote down that they had not established convergence below
# `β ≈ 0.1` — which is where this sweep starts.
#
# The mark that says so is one line at the definition site:
#
# ```julia
# @experimental "convergence not established below β ≈ 0.1" energy(β::Float64) = …
# ```
#
# `public` already decides *who may call* `energy`. Whether it is *finished* is the orthogonal
# question, and the usual place it gets answered is a sentence in a docstring that no tool reads.

# ## What the run went through
#
# [`entered`](@ref) answers it after the fact, about the run, for somebody who is not the author.

# One macro is exported, because it is written at a definition site. Everything else is `public`
# and asked for by name.

using ExperimentalAPI:
    ExperimentalAPI, audit, compare, entered, isbreaking, reach, record, snapshot, verdict

entered(Ising)

# The reason travels with the answer, so a reader a year later needs no source — and
# `susceptibility` is **absent** rather than reported with a count of zero, which is what makes a
# clean answer worth anything. Two definitions are marked; one is in this run.
#
# A fresh accounting comes from opening a [`record`](@ref) block, which clears every flag on entry.
# That is also the control for the paragraph above: `normalise` is arithmetic on numbers already in
# hand, so a caller with nothing unvalidated behind it produces an **empty** answer, not a small
# one:

record(() -> Ising.normalise(βs, 0.5); paths=false, timing=false)

# ## One call, rather than the whole process
#
# [`@entered`](@ref) asks the same question about a single expression, and returns its value, so
# it drops into existing code the way `@time` does.

value = ExperimentalAPI.@entered Ising.report(βs)

# ## How often, and how much of the run
#
# [`record`](@ref) is the opt-in layer. It counts exactly — the count survives inlining, because
# opening a block clears every flag and the *write* side does the counting — and it reports its
# own overhead so the number is never quietly load-bearing.

rec = record(() -> Ising.report(βs); paths=false, timing=false)
[(h.mod, h.name, h.count) for h in rec]

# Forty calls for a forty-point sweep. Nothing in `Ising` changed to get that number.

# ## Without running anything
#
# The previous answers are all about a run that happened. [`reach`](@ref) asks about code:
# *could* this caller get there? The answer is three-valued, and the third value is the point.

verdict(reach(Ising.report, Tuple{Vector{Float64}}))

# `report` never writes the word `energy`. It calls `sweep`, which does. A grep for the name
# finds nothing; the call graph finds it.

verdict(reach(Ising.normalise, Tuple{Vector{Float64},Float64}))

# `:clean` is the expensive claim — it means the *whole* call graph was resolved and nothing marked
# is in it, Base included. `:depends` needs one witness; `:clean` needs all of them.
#
# That asymmetry has a consequence worth knowing before you rely on it. Measured 2026-09-09: a
# version of this function that called `tanh` came back `:clean` on Julia 1.12.2 and `:unknown` on
# 1.14.0-DEV, because resolving `tanh` reaches into Base internals that moved between them. The
# verdict did not get worse; the compiler did. A `:clean` is a statement about the analysis on the
# Julia you ran it on, which is one of the reasons [`reach`](@ref) is itself declared
# `@experimental`.
#
# And the third value is the point of having three:

verdict(reach(Ising.apply, Tuple{Vector{Function},Float64}))

# `fs[1](β)` really can reach anything. Reporting that as `:clean` would not be a weaker claim,
# it would be a false one.

# ## The surface, and what neither account covers
#
# [`audit`](@ref) compares `names(M)` against two independent accounts — a docstring, and a mark.
# They are not alternatives; the docstring is owed either way.

audit(Ising)

# `apply` is public, undocumented and unmarked. It is not a bug and the audit does not call it
# one — it says that the module has published a name and said nothing about it, which is a
# decision somebody should make on purpose.

# ## Is dropping it breaking?
#
# This is the payoff for marking anything at all. Take a snapshot at each release; hand the old
# one and the new module to [`compare`](@ref). Here the "old" release is the current surface plus
# two names that this release drops — one settled, one marked.

old = snapshot(Ising)
push!(old["stable"], "old_verb")
old["experimental"]["draft_energy"] = Dict(
    "reason" => "never validated; superseded by energy"
)

d = compare(old, Ising)
(removed_stable=d.removed_stable, removed_experimental=d.removed_experimental)

# Two removals, and the gate answers differently for them:

isbreaking(d)

# `true`, because `old_verb` was settled. Drop only the marked one and the same function says:

old2 = snapshot(Ising)
old2["experimental"]["draft_energy"] = Dict(
    "reason" => "never validated; superseded by energy"
)
isbreaking(compare(old2, Ising))

# `false`. "Changing an experimental name is not breaking" stops being an argument in a review
# thread and becomes a function call — because the notice was given in the source, at the
# definition, before the removal.
#
# Read it as a floor on breakage and never as a clearance: `compare` reads name sets, so a name
# present in both whose signature changed is a break it cannot see.
# [`compare_methods`](@ref) is the finer instrument.

# ## The one answer nobody asked for
#
# Everything above was asked for. This is not: a process that loaded a marked package and entered
# marked code says so on its way out.
#
# It cannot be shown from inside this page, because the summary fires at exit and a documentation
# build does not exit between blocks — which is exactly why this output used to be typed by hand.
# So the block below runs `examples/sweep.jl` as its own process and prints what came back.

script = joinpath(pkgdir(ExperimentalAPI), "examples", "sweep.jl")
out, err = IOBuffer(), IOBuffer()
run(
    pipeline(
        `$(Base.julia_cmd()) --startup-file=no --project=$(Base.active_project()) $script`;
        stdout=out,
        stderr=err,
    ),
)
print(String(take!(out)))

# That is the program's own output, on `stdout`, exactly as a pipe or a redirect would receive
# it. The summary is not in it, because it goes to `stderr`:

print(String(take!(err)))

# Nobody wrote a line to produce that. It carries the **reason**, not just the symbol; a marked
# definition the run never entered is absent rather than reported as zero; and being on `stderr`
# means `julia sweep.jl > result.dat` keeps the data clean and still puts the notice in front of
# whoever ran it.
#
# `ENV["EXPERIMENTALAPI_SUMMARY"] = "0"` before `using` turns it off. The default is on because
# the person who needs this answer is usually not the person who would think to ask for it.
