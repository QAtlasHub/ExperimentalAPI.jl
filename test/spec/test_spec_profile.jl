# What a real run went through: which marked definitions it entered, how often, and how much of
# the run was spent inside them.
#
# Scope: two layers. Presence is detected by default and must cost nothing; counts, call sites
# and paths are opt-in. The measurements that put the boundary there are in `README.md`.

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

# ── the default layer: no opt-in ─────────────────────────────────────────────────────────────

@testset "a run reports what it entered without being asked to record" begin
    Sim.driver(M, 10)
    @test :energy in [h.name for h in ExperimentalAPI.entered()]
end

@testset "the default answer is presence, and does not pretend to be counts" begin
    # Scope: "at least once". A count field here would read as a measurement it did not make.
    Sim.driver(M, 10)
    @test ExperimentalAPI.entered()[1].count === nothing
end

@testset "a definition that was never entered is absent from the default answer too" begin
    # Control: separates observed from enumerated.
    Sim.driver(M, 10)
    @test :cold ∉ [h.name for h in ExperimentalAPI.entered()]
end

# Observed from a child process: an `atexit` handler registered in this one would pass for a
# handler that prints nothing, and stdout alone would pass if the notice went to stderr.
module ChildRun

const WARMED = Ref(false)

function _cmd(code)
    return `$(Base.julia_cmd()) --startup-file=no --project=$(Base.active_project()) -e $code`
end

"""
    output(code) -> String

Everything a child `julia -e code` wrote, stdout and stderr merged. The first call warms the
precompilation cache, so a `Precompiling …` banner is never mistaken for the summary under test.
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

# The two scripts differ only in the final call.
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
    @test occursin("energy", ChildRun.output(ChildRun.ENTERS))
end

@testset "a process that loaded a mark but never entered it stays silent" begin
    # Control: rejects a summary keyed on "this module has marks".
    @test isempty(strip(ChildRun.output(ChildRun.LOADS_ONLY)))
end

@testset "the summary carries the reason, not just the name" begin
    @test occursin("convergence not established", ExperimentalAPI.summary_text())
end

@testset "the default layer can be turned off" begin
    # Scope: read before `using` returns, so an environment variable rather than a call — the
    # `atexit` hook is registered at load time.
    @test ExperimentalAPI.detecting() === true
    @test withenv(ExperimentalAPI.detecting, "EXPERIMENTALAPI_SUMMARY" => "0") === false
end

# ── the opt-in layer: the basic question ─────────────────────────────────────────────────────

@testset "a run reports which marked definitions it entered" begin
    @test_broken :energy in
        [h.name for h in ExperimentalAPI.record(() -> Sim.driver(M, 100))]
end

@testset "a run reports how many times each was entered" begin
    @test_broken ExperimentalAPI.record(() -> Sim.driver(M, 100))[1].count == 100
end

@testset "a marked definition the run never entered is absent, not zero" begin
    # Control: separates observed from enumerated.
    @test_broken :cold ∉ [h.name for h in ExperimentalAPI.record(() -> Sim.driver(M, 10))]
end

@testset "a run that touches nothing marked reports an empty record, not an error" begin
    @test_broken ExperimentalAPI.record(() -> sum(1:10)) == []
end

@testset "a record distinguishes 'touched nothing' from 'recording was off'" begin
    # Both are an empty vector otherwise, and they mean opposite things.
    @test_broken ExperimentalAPI.record(() -> sum(1:10)).enabled === true
end

# ── granularity ──────────────────────────────────────────────────────────────────────────────

@testset "attribution is to a method, not to a name" begin
    @test_broken first(ExperimentalAPI.record(() -> Sim.driver(M, 10))).method isa Method
end

@testset "two marked definitions in one run are reported separately" begin
    @test_broken length(
        ExperimentalAPI.record(() -> (Sim.driver(M, 10); Sim.sweep(M, 10)))
    ) == 2
end

@testset "the call site that reached the mark is recorded" begin
    # Scope: which part of the caller's own code to distrust, not just that a mark was hit.
    @test_broken !isempty(first(ExperimentalAPI.record(() -> Sim.driver(M, 10))).callers)
end

@testset "the whole path from the entry point is available" begin
    @test_broken :driver in first(ExperimentalAPI.record(() -> Sim.driver(M, 10))).paths[1]
end

# ── proportion, not just presence ────────────────────────────────────────────────────────────

@testset "the record says what fraction of the run was inside experimental code" begin
    @test_broken 0.0 <
        ExperimentalAPI.experimental_fraction(
            ExperimentalAPI.record(() -> Sim.driver(M, 100_000))
        ) <=
        1.0
end

@testset "inclusive and exclusive time are distinguished" begin
    # Scope: a marked wrapper over settled code is not a marked kernel.
    @test_broken let h = first(ExperimentalAPI.record(() -> Sim.driver(M, 1000)))
        h.inclusive >= h.exclusive
    end
end

# ── the floor: what may be emitted into the body ─────────────────────────────────────────────

# Controls for the two testsets below. `!occursin(…)` is satisfied by an expansion that dropped
# the definition, so each check is also run against an expansion that does the forbidden thing.
# Kept in a module because a macro at the top level of a test file leaks into the whole shard.
module WrapControl

"Wraps the call it is given — the shape the emitted flag must stay inside."
macro wrapping(_reason, def)
    return esc(Expr(:function, def.args[1], Expr(:block, :(COUNTS[] += 1), def.args[2])))
end

"Puts a logging call in the body."
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

@testset "the expansion adds exactly one statement, and it is a short-circuit read" begin
    # Scope: what the default layer may put in a body. One statement, and a read that writes only
    # on the first call — an unconditional store costs 3.76x at eight threads.
    # Compared at the AST: the expansion carries `Expr(:escape, …)` and prints differently.
    bare = WrapControl.method_bodies(@macroexpand f(x) = x * 2)
    marked = WrapControl.method_bodies(@macroexpand @experimental "why" f(x) = x * 2)
    @test length(bare) == 1
    @test length(marked[1].args) == length(bare[1].args) + 1
    @test marked[1].args[1].head === :||
    # Control: `@wrapping` adds one statement too, and it is a store. Without this, `head === :||`
    # is the only thing separating the two and nothing checks that it can be otherwise.
    wrapped = WrapControl.method_bodies(
        @macroexpand WrapControl.@wrapping "why" f(x) = x * 2
    )
    @test length(wrapped[1].args) == length(bare[1].args) + 1
    @test wrapped[1].args[1].head !== :||
    @test Sim.driver(M, 3) ≈ 3 * (0.5 * 1.0000001 + exp(-0.5))
end

@testset "whatever is emitted, it is not a logging call" begin
    # The bound on what the flag may cost: a logging call in the body stops the definition
    # inlining whether or not it ever fires.
    emitted = string(@macroexpand @experimental "why" f(x) = x * 2)
    @test !occursin("CoreLogging", emitted)
    @test occursin(
        "CoreLogging", string(@macroexpand WrapControl.@logging "why" f(x) = x * 2)
    )
end

# No wall-clock assertion here by decision, not omission: the figures separating these designs
# come from an idle machine, and the same thresholds on a shared CI runner would be a flake
# generator. CI checks the shape of the expansion; cost belongs in a benchmark.

# ── mechanism constraints ────────────────────────────────────────────────────────────────────

@testset "recording survives inlining" begin
    # Scope: marked definitions are usually small, so a mechanism needing `@noinline` is no
    # mechanism. This is why the sampling route was rejected.
    @test_broken ExperimentalAPI.record(() -> Sim.driver(M, 100))[1].count == 100
end

@testset "detection is on by default; counting is not" begin
    @test ExperimentalAPI.detecting() === true
    @test_broken ExperimentalAPI.recording() === false
end

@testset "the default layer's cost is stated, and it is the flag's cost" begin
    # Not `>= 0`, which every number satisfies. Above a few percent it has become a counter.
    @test_broken ExperimentalAPI.overhead_when_detecting() < 0.10
end

@testset "the opt-in layer's overhead is measured and reported, not discovered" begin
    @test_broken ExperimentalAPI.record(() -> Sim.driver(M, 1000)).overhead isa Real
end

@testset "recording nests without double counting" begin
    @test_broken ExperimentalAPI.record(
        () -> ExperimentalAPI.record(() -> Sim.driver(M, 10))
    )[1].count == 10
end

@testset "an exception inside the recorded block still yields a record" begin
    @test_broken ExperimentalAPI.record(() -> error("boom"); rethrow=false) isa
        AbstractVector
end

# ── concurrency and distribution ─────────────────────────────────────────────────────────────

@testset "the suite runs with more than one thread" begin
    # `Threads.@threads for _ in 1:8` runs its body 8 times whatever `nthreads()` is, so without
    # this the concurrency claims below would pass single-threaded. Set in `CI.yml`.
    @test Threads.nthreads() > 1
end

@testset "hits from every thread are attributed" begin
    # Scope: a racing counter is as wrong as a main-thread-only one, and reports a number.
    threaded() = Threads.@threads for _ in 1:8
        Sim.driver(M, 100)
    end
    @test_broken ExperimentalAPI.record(threaded)[1].count == 800
end

@testset "per-thread storage is sized by maxthreadid, not nthreads" begin
    # The interactive pool is counted separately, so `threadid()` exceeds `nthreads()` — an
    # `nthreads()`-sized vector throws on the first hit from a REPL task.
    @test Threads.maxthreadid() >= Threads.nthreads()
    @test_broken ExperimentalAPI.record(() -> Sim.driver(M, 10)).slots >=
        Threads.maxthreadid()
end

@testset "a merged record is still a record" begin
    # `isa AbstractVector` would let the merge return a plain `Vector` with no `.enabled`.
    @test_broken hasproperty(
        ExperimentalAPI.merge_records([ExperimentalAPI.record(() -> Sim.driver(M, 10))]),
        :enabled,
    )
end

@testset "records from separate processes merge into one" begin
    @test_broken ExperimentalAPI.merge_records([
        ExperimentalAPI.record(() -> Sim.driver(M, 10)) for _ in 1:2
    ]) isa AbstractVector
end

@testset "merging is associative and order-independent" begin
    # Workers finish in arbitrary order; provenance must not depend on that.
    @test_broken let a = ExperimentalAPI.record(() -> Sim.driver(M, 10)),
        b = ExperimentalAPI.record(() -> Sim.sweep(M, 10))

        ExperimentalAPI.merge_records([a, b]) == ExperimentalAPI.merge_records([b, a])
    end
end

# ── coexistence with the profiler people already use ─────────────────────────────────────────

@testset "recording does not disturb Profile" begin
    @test_broken ExperimentalAPI.record(() -> Sim.driver(M, 10); with_profile=true) isa
        AbstractVector
end

@testset "an existing Profile buffer can be attributed after the fact" begin
    # Scope: a twelve-hour run already profiled must not have to be run again.
    @test_broken ExperimentalAPI.attribute(Profile.fetch()) isa AbstractVector
end

# ── the output is evidence, not a printout ───────────────────────────────────────────────────

@testset "a record is serialisable" begin
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
    # `energy` being experimental in v0.3 says nothing about v0.9.
    @test_broken ExperimentalAPI.record(() -> Sim.driver(M, 10)).versions isa AbstractDict
end

@testset "the reason is carried into the record" begin
    # Scope: readable a year later by someone who never saw the source.
    @test_broken occursin(
        "convergence", first(ExperimentalAPI.record(() -> Sim.driver(M, 10))).reason
    )
end

# ── using it as a gate ───────────────────────────────────────────────────────────────────────

@testset "a run can be asserted to have touched nothing experimental" begin
    @test_broken ExperimentalAPI.assert_clean(() -> 1 + 1)
end

@testset "the assertion fails, naming the mark, when the run is not clean" begin
    # Control: a gate that cannot be shown to fire is not a gate.
    @test_broken !ExperimentalAPI.assert_clean(() -> Sim.driver(M, 10); throw=false)
end
