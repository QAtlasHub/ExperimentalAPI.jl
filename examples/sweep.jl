# A sweep that returns a number, and nothing in the number says which code path behind it was
# never validated. Run it as its own process — `julia --project=examples examples/sweep.jl` — and
# read what comes out AFTER the result: the summary fires at exit, so it cannot be demonstrated
# from inside a docs build that never exits.

module Ising

using ExperimentalAPI

public energy, correlator, susceptibility, sweep

"""
    energy(β)

Free energy density of the 1D Ising chain at inverse temperature `β`.
"""
@experimental "convergence not established below β ≈ 0.1" energy(β) = -log(2cosh(β)) / β

"""
    correlator(β, r)

Two-point function at separation `r`. Settled: the closed form is exact for the 1D chain.
"""
correlator(β, r) = tanh(β)^r

"""
    susceptibility(β)

Magnetic susceptibility. Marked, and never called by this script — so the summary has to leave it
out rather than report it with a count of zero.
"""
@experimental "extrapolated; no reference value" susceptibility(β) = exp(2β) / β

"""
    sweep(βs)

Mean energy density over `βs`. The caller never names `energy`.
"""
sweep(βs) = sum(energy, βs) / length(βs)

end # module Ising

result = Ising.sweep(0.05:0.05:2.0)

println("mean energy density = ", result)
println("correlation length at β = 1: ", -1 / log(tanh(1.0)))
