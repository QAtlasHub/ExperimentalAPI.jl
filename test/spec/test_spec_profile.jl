# Profiling: what a real run actually went through.
#
# This is the half of the intent a reviewer cannot answer with "put it in the docstring". After a
# twelve-hour DMRG run the question is not "is this function experimental" but "did the number I
# am about to put in a paper come out of code nobody has validated, and how much of it".
#
# Everything here is `@test_broken`. The cheap route was measured on 2026-09-03, **Julia
# 1.12.2**, and does not
# work: `Profile.fetch` frames for inlined callees carry no `MethodInstance`, so a sampling
# profiler attributes ZERO samples to marked methods — and small functions, which is most of what
# gets marked, are exactly the ones that get inlined.

using ExperimentalAPI: ExperimentalAPI, @experimental
using Profile: Profile
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

# ── the default layer: you find out without asking ───────────────────────────────────────────
#
# The goal is a tool that says WHERE experimental code was used, and a user who learns they used
# it **without opting in**. Those are two layers, and which work goes in which is measured rather
# than chosen. 10M calls of a realistic numeric body, `sqrt(abs(sin(x)*cos(x) + exp(-|x|/1e6)))`,
# Julia 1.12.2, minimum of 7-9 trials:
#
#   | emitted into the body       | 1 thread | 8 threads | counts correctly? |
#   |-----------------------------|----------|-----------|-------------------|
#   | nothing                     |  1.00x   |  1.00x    |         -         |
#   | set-once flag, read-mostly  |  1.03x   |  0.985x   |        yes        |
#   | counter, plain shared `Ref` |  1.03x   |  3.76x    |      **no**       |
#   | counter, global atomic      |  1.17x   |  4.87x    |        yes        |
#   | counter, per-thread atomic  |  1.12x   |  2.79x    |        yes        |
#   | `@warn` guarded, fires once |  5.65x   |     -     |        yes        |
#   | `@warn maxlog=1`            | 59.57x   |     -     |        yes        |
#
# Two things decided the split. The plain counter is not merely slow in parallel — it recorded
# 95,406,048 of 160,000,000 calls, losing 40% to races, so it is *wrong* as well. And a flag
# written once and only read afterwards never dirties the cache line again, which is why it is
# free at eight threads while every counting scheme is not.
#
# So: **presence is detected by default and costs nothing; counts, call sites and paths are
# opt-in.** The `@warn` rows are why the notice is a summary at exit rather than a warning at the
# call: the cost is the logging call sitting in the body, not the warning being printed, and a
# guard that makes it fire only once does not recover it.

@testset "a run reports what it entered without being asked to record" begin
    # The default layer. No `record(...)` wrapper and no flag to set: the user ran their
    # calculation and can find out afterwards.
    Sim.driver(M, 10)
    @test_broken :energy in [h.name for h in ExperimentalAPI.entered()]
end

@testset "the default answer is presence, and does not pretend to be counts" begin
    # A count field that is always 1, or always the number of marks, would be worse than absent:
    # it reads as a measurement. The default layer knows "yes, at least once" and must say only
    # that.
    Sim.driver(M, 10)
    @test_broken ExperimentalAPI.entered()[1].count === nothing
end

@testset "a definition that was never entered is absent from the default answer too" begin
    # The control. Without it, an `entered()` that lists every mark in every loaded module passes.
    Sim.driver(M, 10)
    @test_broken :cold ∉ [h.name for h in ExperimentalAPI.entered()]
end

# The summary is a property of a process on its way out, so it has to be observed from outside
# one. Asserting that an `atexit` handler is registered in THIS process would pass for a handler
# that prints nothing, and asserting on `stdout` alone would pass trivially if the notice went to
# `stderr` — which stream a notice lands on is exactly what must not be assumed here.
module ChildRun

const WARMED = Ref(false)

function _cmd(code)
    return `$(Base.julia_cmd()) --startup-file=no --project=$(Base.active_project()) -e $code`
end

"""
    output(code) -> String

Everything a child `julia -e code` wrote, stdout and stderr merged. The first call warms the
precompilation cache with a throwaway child, so a `Precompiling …` banner is never mistaken for
the summary under test.
"""
function output(code::AbstractString)
    if !WARMED[]
        run(
            pipeline(
                ignorestatus(_cmd("using ExperimentalAPI")); stdout=devnull, stderr=devnull
            ),
        )
        WARMED[] = true
    end
    io = IOBuffer()
    run(pipeline(ignorestatus(_cmd(code)); stdout=io, stderr=io))
    return String(take!(io))
end

const ENTERS = """
using ExperimentalAPI
module Child
using ExperimentalAPI
public energy
@experimental "convergence not established below beta" energy(x) = x * 1.0000001
end
Child.energy(0.5)
"""

const LOADS_ONLY = """
using ExperimentalAPI
module Child
using ExperimentalAPI
public energy
@experimental "convergence not established below beta" energy(x) = x * 1.0000001
end
"""

end # module ChildRun

@testset "the summary is printed at process exit" begin
    # The whole point of the default layer: the user did not ask, and still finds out.
    @test_broken occursin("energy", ChildRun.output(ChildRun.ENTERS))
end

@testset "a process that loaded a mark but never entered it stays silent" begin
    # The control, and the thing that decides whether this package is tolerable as a dependency.
    # The two child scripts differ ONLY in the final call, so a summary keyed on "this module has
    # marks" rather than on "this run entered one" fails here and passes above.
    @test isempty(strip(ChildRun.output(ChildRun.LOADS_ONLY)))
end

@testset "the summary carries the reason, not just the name" begin
    # A name tells the user which line to look at; the reason is what tells them whether the
    # number they are about to publish is affected. The reason is the payload everywhere else in
    # this package, and must not be dropped at the one place a user reads by default.
    @test_broken occursin("convergence not established", ExperimentalAPI.summary_text())
end

@testset "the default layer can be turned off" begin
    # A package that cannot be quietened gets vendored around. The switch has to be readable
    # before `using` returns, so it is an environment variable rather than a function call.
    @test_broken ExperimentalAPI.detecting() === true
end

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
    # `QAtlas.fetch` has 570 methods — see `test_spec_foreign.jl`. "the run touched fetch" is unusable.
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

# ── the floor: what may be emitted into the body ─────────────────────────────────────────────
#
# Folded in from what used to be `test_spec_runtime.jl`. Its other eight testsets restated this
# file's claims on a strictly smaller fixture; only these two measured anything of their own.

# The control for the two assertions below. A predicate that has never returned `true` for
# anything is not evidence, and `!occursin(…)` is the shape most easily satisfied by an expansion
# that dropped the definition altogether. `@wrapping` does exactly what `@experimental` must never
# become, so the check can be shown to fire. Kept in a module because a macro defined at the top
# level of a test file is visible to every file after it in the same shard.
module WrapControl

"A macro that wraps the call it is given — the shape the emitted flag must stay inside."
macro wrapping(_reason, def)
    return esc(Expr(:function, def.args[1], Expr(:block, :(COUNTS[] += 1), def.args[2])))
end

"A macro that puts a logging call in the body — measured at 5.65x guarded, 59.6x unguarded."
macro logging(reason, def)
    return esc(
        Expr(
            :function,
            def.args[1],
            Expr(:block, :($Base.@warn $reason maxlog = 1), def.args[2]),
        ),
    )
end

"""
    method_bodies(ex) -> Vector

The body of every method definition inside an expanded expression, line numbers stripped. Walks
into `Expr(:escape, …)`, which is where a macro's own output lives.
"""
function method_bodies(ex)
    out = Any[]
    walk(x) =
        if x isa Expr
            if (x.head === :(=) || x.head === :function) &&
                x.args[1] isa Expr &&
                x.args[1].head === :call
                push!(out, x.args[2])
            end
            foreach(walk, x.args)
        end
    walk(Base.remove_linenums!(ex))
    return out
end

end # module WrapControl

@testset "today the expansion is untouched — which is what has to change" begin
    # This file used to require that `@experimental` never wrap the call at all. That requirement
    # is WITHDRAWN: the default layer cannot detect presence without emitting something into the
    # body. What replaces it is not weaker, it is narrower and measured — see the table at the
    # top. The emitted statement must be read-mostly, and must not drag the logging machinery in
    # with it.
    #
    # Compared at the AST, not as a string: the expansion contains `Expr(:escape, …)` and the
    # printed forms differ even when the bodies are identical.
    bare = WrapControl.method_bodies(@macroexpand f(x) = x * 2)
    marked = WrapControl.method_bodies(@macroexpand @experimental "why" f(x) = x * 2)
    @test length(bare) == 1
    @test marked == bare                     # the definition is emitted untouched
    # …and the comparison can fail, which is the half that makes the line above worth anything.
    wrapped = WrapControl.method_bodies(
        @macroexpand WrapControl.@wrapping "why" f(x) = x * 2
    )
    @test wrapped != bare
    # The target: exactly one statement more than the bare body, and no more.
    @test_broken length(marked[1].args) == length(bare[1].args) + 1
    @test Sim.driver(M, 3) ≈ 3 * (0.5 * 1.0000001 + exp(-0.5))
end

@testset "whatever is emitted, it is not a logging call" begin
    # The hard line, and the one measurable today rather than after the fact. `@warn` in the body
    # costs 59.6x unconditionally and **5.65x even when guarded so that it fires once** — the
    # guard does not help, because what stops the definition inlining is the call being there at
    # all. The summary at exit is the alternative that costs nothing.
    emitted = string(@macroexpand @experimental "why" f(x) = x * 2)
    @test !occursin("CoreLogging", emitted)
    # The positive control: the same predicate against an expansion that does log. Without it,
    # `!occursin(…)` is satisfied by any expansion whatsoever, including an empty one.
    @test occursin(
        "CoreLogging", string(@macroexpand WrapControl.@logging "why" f(x) = x * 2)
    )
end

# There is still no wall-clock assertion in this file, and that is a finding rather than a gap.
# Four routes were measured on 2026-09-03 and each failed for its own reason:
#
#   * A ratio `a < 5b + 1e-3` whose two arms did different work — `Sim.energy(Sim.Model(x))`, a
#     struct construction per iteration, against a bare call. The 5x margin was spent on the
#     fixture; it failed at a = 11.8 ms against b = 2.1 ms.
#   * The same ratio with the arms made identical. Over eight trials on an idle machine the ratio
#     ran 0.79 to 3.03, so the threshold sat inside the noise.
#   * `@allocated` equality. Deterministic, but measuring the wrong thing: 0 on Julia 1.12 and 16
#     on 1.11 for the SAME code, and a counter wrapper `push!`ing into a warmed vector allocates
#     zero too — so it cannot see the regression it was written to catch. The positive control is
#     what showed that.
#   * A ratio against a fixed threshold, now that a flag WILL be emitted. Ruled out in advance:
#     the numbers in the table at the top come from a throwaway benchmark on an idle machine, and
#     the same thresholds on a shared CI runner across three operating systems would be a flake
#     generator. What CI can check is the SHAPE of the expansion; what only a benchmark can check
#     is the cost, and that belongs in a benchmark.
#
# The claim is exact at the expansion and only ever approximate at run time, so it is checked
# where it is exact.

# ── mechanism constraints ────────────────────────────────────────────────────────────────────

@testset "recording survives inlining" begin
    # The measured reason the sampling route failed. `Sim.energy` is a one-line function; the
    # optimiser will inline it. Any mechanism that only works on `@noinline` code is not a
    # mechanism for this problem.
    @test_broken ExperimentalAPI.record(() -> Sim.driver(M, 100))[1].count == 100
end

@testset "detection is on by default; counting is not" begin
    # Inverted from what this file first required. "Recording off by default" was the safe answer
    # only while presence detection was assumed to cost what counting costs; measured, they
    # differ by a factor of four in parallel, and only one of them is affordable by default.
    @test_broken ExperimentalAPI.detecting() === true
    @test_broken ExperimentalAPI.recording() === false
end

@testset "the default layer's cost is stated, and it is the flag's cost" begin
    # Not `>= 0`, which every number satisfies. The measured figure for a read-mostly flag is
    # 0.985x-1.03x, so a default layer reporting overhead above a few percent has stopped being
    # the thing that was measured — most likely by having become a counter.
    @test_broken ExperimentalAPI.overhead_when_detecting() < 0.10
end

@testset "the opt-in layer's overhead is measured and reported, not discovered" begin
    # A tool that slows a twelve-hour run by 4x will not be used on a twelve-hour run — and 4x is
    # the measured figure for counting at eight threads, not a hypothetical. Whatever it costs,
    # the number has to come back with the record.
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

@testset "the suite runs with more than one thread" begin
    # `Threads.@threads for _ in 1:8` executes its body 8 times whatever `nthreads()` is, so the
    # test below would pass for a recorder that is not thread-safe at all if CI ran single
    # threaded. `.github/workflows/CI.yml` sets `JULIA_NUM_THREADS` for this reason; if that ever
    # regresses, this fails instead of the concurrency claim silently becoming untestable.
    @test Threads.nthreads() > 1
end

@testset "hits from every thread are attributed" begin
    # HPC code is threaded. A recorder that only sees the main thread reports a fraction of the
    # truth and calls it the truth — and so does one that races: measured on 8 threads, a plain
    # `Ref{Int}` incremented per call recorded 95,406,048 of 160,000,000 entries. It lost 40% and
    # cost 3.76x for the privilege, which is why counting is atomic and opt-in.
    threaded() = Threads.@threads for _ in 1:8
        Sim.driver(M, 100)
    end
    @test_broken ExperimentalAPI.record(threaded)[1].count == 800
end

@testset "per-thread storage is sized by maxthreadid, not nthreads" begin
    # Measured 2026-09-03 while benchmarking the counter with `-t 8`: `threadid()` returned 9,
    # because the interactive pool is counted separately from the default one. A recorder that
    # allocates an `nthreads()`-sized vector throws `BoundsError` on the first hit arriving from
    # an interactive task — which is any hit from the REPL.
    @test Threads.maxthreadid() >= Threads.nthreads()
    @test_broken ExperimentalAPI.record(() -> Sim.driver(M, 10)).slots >=
        Threads.maxthreadid()
end

@testset "a merged record is still a record" begin
    # `merge_records(...) isa AbstractVector` is the only constraint today, so a `record()` you
    # can ask `.overhead` of, merged with another, may legally come back as a plain `Vector` you
    # cannot. Losing the type across a verb's own merge is avoidable.
    @test_broken hasproperty(
        ExperimentalAPI.merge_records([ExperimentalAPI.record(() -> Sim.driver(M, 10))]),
        :enabled,
    )
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
