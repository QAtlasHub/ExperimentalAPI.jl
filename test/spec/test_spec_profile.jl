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
    @test :energy in [h.name for h in ExperimentalAPI.record(() -> Sim.driver(M, 100))]
end

@testset "a run reports how many times each was entered" begin
    @test ExperimentalAPI.record(() -> Sim.driver(M, 100))[1].count == 100
    # …and the count is of THIS block, not of the process: the same call again reports 100 and
    # not 200, which is what makes a record a measurement of one run.
    @test ExperimentalAPI.record(() -> Sim.driver(M, 100))[1].count == 100
end

@testset "a marked definition the run never entered is absent, not zero" begin
    # Control: separates observed from enumerated.
    @test :cold ∉ [h.name for h in ExperimentalAPI.record(() -> Sim.driver(M, 10))]
end

@testset "a run that touches nothing marked reports an empty record, not an error" begin
    @test ExperimentalAPI.record(() -> sum(1:10)) == []
end

@testset "a record distinguishes 'touched nothing' from 'recording was off'" begin
    # Both are an empty vector otherwise, and they mean opposite things.
    @test ExperimentalAPI.record(() -> sum(1:10)).enabled === true
end

# ── granularity ──────────────────────────────────────────────────────────────────────────────

@testset "attribution is to a method, not to a name" begin
    h = first(ExperimentalAPI.record(() -> Sim.driver(M, 10)))
    @test h.method isa Method
    @test h.method === which(Sim.energy, Tuple{Sim.Model})
end

@testset "two marked definitions in one run are reported separately" begin
    r = ExperimentalAPI.record(() -> (Sim.driver(M, 10); Sim.sweep(M, 10)))
    @test length(r) == 2
    @test Set(h.name for h in r) == Set([:energy, :correlator])
end

@testset "the call site that reached the mark is recorded" begin
    # Scope: which part of the caller's own code to distrust, not just that a mark was hit.
    callers = first(ExperimentalAPI.record(() -> Sim.driver(M, 10))).callers
    @test !isempty(callers)
    # The immediate caller, not the marked definition itself — a `callers` list whose only entry
    # is `energy` is a list of the wrong thing, and it reads exactly the same.
    @test :inner in callers
    @test :energy ∉ callers
end

@testset "the whole path from the entry point is available" begin
    paths = first(ExperimentalAPI.record(() -> Sim.driver(M, 10))).paths
    @test :driver in paths[1]
    # Innermost first, starting at the marked definition, so a reader can follow it outwards.
    @test paths[1][1] === :energy
end

# ── proportion, not just presence ────────────────────────────────────────────────────────────

@testset "the record says what fraction of the run was inside experimental code" begin
    # Long enough to be sampled: the timing backend is Julia's sampling profiler, and a run that
    # finishes inside one sampling interval has no fraction to report. Two million iterations of
    # a recorded body is tens of milliseconds — hundreds of samples, not a handful.
    r = ExperimentalAPI.record(() -> Sim.driver(M, 2_000_000))
    @test r.sampled                                   # …the backend really was loaded
    f = ExperimentalAPI.experimental_fraction(r)
    @test 0.0 < f <= 1.0
end

@testset "inclusive and exclusive time are distinguished" begin
    # Scope: a marked wrapper over settled code is not a marked kernel.
    h = first(ExperimentalAPI.record(() -> Sim.driver(M, 1000)))
    @test h.inclusive >= h.exclusive
    @test h.inclusive isa Float64
end

@testset "without a timing backend the fraction is missing, not zero" begin
    # Control for the two above: `Profile` is loaded in this file, so the only way to see the
    # other branch is to ask a record that was not sampled. Zero would say the run spent no time
    # in marked code, which is the opposite of "nobody measured".
    r = ExperimentalAPI.record(() -> Sim.driver(M, 100); timing=false)
    @test r.sampled === false
    @test ExperimentalAPI.experimental_fraction(r) === missing
    @test first(r).inclusive === missing
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
    # mechanism. `Sim.energy` is one multiplication and is inlined into `inner`, which is inlined
    # into `driver`; the count still has to be exact. This is why the sampling route was rejected.
    @test ExperimentalAPI.record(() -> Sim.driver(M, 100))[1].count == 100
end

@testset "detection is on by default; counting is not" begin
    @test ExperimentalAPI.detecting() === true
    @test ExperimentalAPI.recording() === false
    # …and it is on exactly inside the block, which is the whole cost argument.
    @test ExperimentalAPI.record(() -> ExperimentalAPI.recording()) isa AbstractVector
    inside = Ref(false)
    ExperimentalAPI.record(() -> (inside[] = ExperimentalAPI.recording()))
    @test inside[] === true
    @test ExperimentalAPI.recording() === false
end

@testset "the default layer's cost is stated, and it is the flag's cost" begin
    # Not `>= 0`, which every number satisfies. Above a few percent it has become a counter.
    @test ExperimentalAPI.overhead_when_detecting() < 0.10
    # Stated rather than re-measured: a wall-clock figure taken on a shared runner is a flake
    # generator, and a number that moves with the machine is not one a caller can plan against.
    @test ExperimentalAPI.overhead_when_detecting() ===
        ExperimentalAPI.overhead_when_detecting()
end

@testset "the opt-in layer's overhead is measured and reported, not discovered" begin
    r = ExperimentalAPI.record(() -> Sim.driver(M, 1000))
    @test r.overhead isa Real
    @test 0.0 <= r.overhead <= 1.0
end

@testset "recording nests without double counting" begin
    @test ExperimentalAPI.record(() -> ExperimentalAPI.record(() -> Sim.driver(M, 10)))[1].count ==
        10
end

@testset "an exception inside the recorded block still yields a record" begin
    r = ExperimentalAPI.record(() -> (Sim.driver(M, 7); error("boom")); rethrow=false)
    @test r isa AbstractVector
    # The part that ran is in it: a record that swallowed the exception AND the counts would be
    # indistinguishable from a block that did nothing.
    @test r[1].count == 7
    # …and by default the exception is not swallowed.
    @test_throws ErrorException ExperimentalAPI.record(() -> error("boom"))
end

@testset "…and the default propagates the caller's own exception" begin
    # `rethrow = true` is the default, and the assertion above it — `@test_throws
    # ErrorException` — passed for the wrong reason. `Base.rethrow(err)` outside a `catch` raises
    # `ErrorException("rethrow(exc) not allowed outside a catch block")`, which satisfies a check
    # on the exception TYPE while the caller never saw their own error. Pin the message.
    e = try
        ExperimentalAPI.record(() -> error("the caller's own message"))
        nothing
    catch err
        err
    end
    @test e isa ErrorException
    @test occursin("the caller's own message", sprint(showerror, e))
    # Control: the message that used to come out instead.
    @test !occursin("not allowed outside a catch block", sprint(showerror, e))
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
    @test ExperimentalAPI.record(threaded)[1].count == 800
end

@testset "per-thread storage is sized by maxthreadid, not nthreads" begin
    # The interactive pool is counted separately, so `threadid()` exceeds `nthreads()` — an
    # `nthreads()`-sized vector throws on the first hit from a REPL task.
    @test Threads.maxthreadid() >= Threads.nthreads()
    @test ExperimentalAPI.record(() -> Sim.driver(M, 10)).slots >= Threads.maxthreadid()
end

@testset "a merged record is still a record" begin
    # `isa AbstractVector` would let the merge return a plain `Vector` with no `.enabled`.
    @test hasproperty(
        ExperimentalAPI.merge_records([ExperimentalAPI.record(() -> Sim.driver(M, 10))]),
        :enabled,
    )
end

@testset "records from separate processes merge into one" begin
    m = ExperimentalAPI.merge_records([
        ExperimentalAPI.record(() -> Sim.driver(M, 10)) for _ in 1:2
    ])
    @test m isa AbstractVector
    # Counts ADD. A merge that took the maximum, or the last one, would also be a record.
    @test m[1].count == 20
end

@testset "merging is associative and order-independent" begin
    # Workers finish in arbitrary order; provenance must not depend on that.
    a = ExperimentalAPI.record(() -> Sim.driver(M, 10))
    b = ExperimentalAPI.record(() -> Sim.sweep(M, 10))
    @test ExperimentalAPI.merge_records([a, b]) == ExperimentalAPI.merge_records([b, a])
    # …and the fixture can disagree: the two records are not equal to each other.
    @test a != b
end

# ── coexistence with the profiler people already use ─────────────────────────────────────────

# `Sim.energy` is one multiplication, and after inlining there is no frame for a sampler to
# attribute anything to — see `attribute`'s docstring, and note that this is exactly why
# `record`'s counts come from a counter and not from samples. The fixture for the sampling
# question therefore has to be a marked definition that is worth a sample.
module Hot

using ExperimentalAPI

public grind, settled_grind

@experimental "the summation order is provisional" function grind(n::Int)
    s = 0.0
    for i in 1:n
        s += sqrt(abs(sin(i * 1.0)))
    end
    return s
end

"Settled, and just as hot."
function settled_grind(n::Int)
    s = 0.0
    for i in 1:n
        s += sqrt(abs(cos(i * 1.0)))
    end
    return s
end

end # module Hot

@testset "recording does not disturb Profile" begin
    # `with_profile = true` means the caller is already using the buffer: whatever is in it stays.
    #
    # Two things this measures rather than assumes. The buffer has to be filled by a run that is
    # long compared with the sampling interval — `Sim.driver(M, 200_000)` is about one interval at
    # the default rate, and came back with **zero** samples on macOS, which made the whole
    # assertion a coin flip. And the size is read with `Profile.len_data`, not by fetching:
    # `fetch(; include_meta = false)` strips metadata behind an `@assert` that fires on
    # 1.14.0-DEV.3115 for a buffer this test did not fill.
    Hot.grind(10)
    Profile.clear()
    Profile.init(; delay=1e-5)
    Profile.@profile Hot.grind(2_000_000)
    before = Profile.len_data()
    @test before > 0
    r = ExperimentalAPI.record(() -> Sim.driver(M, 10); with_profile=true)
    @test r isa AbstractVector
    @test Profile.len_data() >= before
    # Control: without the keyword the buffer is cleared, so the keyword is doing the work.
    ExperimentalAPI.record(() -> Sim.driver(M, 10))
    @test Profile.len_data() < before
    Profile.clear()
end

@testset "an existing Profile buffer can be attributed after the fact" begin
    # Scope: a twelve-hour run already profiled must not have to be run again.
    Hot.grind(10)
    Hot.settled_grind(10)
    Profile.clear()
    Profile.init(; delay=1e-4)
    Profile.@profile (Hot.grind(2_000_000); Hot.settled_grind(2_000_000))
    a = ExperimentalAPI.attribute(Profile.fetch())
    @test a isa AbstractVector
    @test :grind in [x.name for x in a]
    # Samples, never calls: a sampling profiler cannot count entries, and a field called `count`
    # holding a sample total would read as a measurement it did not make.
    @test all(x -> x isa ExperimentalAPI.Attribution, a)
    @test !any(x -> hasproperty(x, :count), a)
    # Control: `settled_grind` is exactly as hot and carries no mark, so it must not appear.
    @test :settled_grind ∉ [x.name for x in a]
    Profile.clear()
end

# ── the output is evidence, not a printout ───────────────────────────────────────────────────

@testset "a record is serialisable" begin
    path = ExperimentalAPI.write_record(
        tempname(), ExperimentalAPI.record(() -> Sim.driver(M, 10))
    )
    @test path isa AbstractString
    # Readable without this package: plain TOML, with the reason in it.
    @test occursin("convergence not established", read(path, String))
end

@testset "a serialised record round-trips" begin
    r = ExperimentalAPI.record(() -> Sim.driver(M, 10))
    back = ExperimentalAPI.read_record(ExperimentalAPI.write_record(tempname(), r))
    @test back isa AbstractVector
    @test length(back) == length(r)
    @test back[1].count == r[1].count
    @test back[1].reason == r[1].reason
    # A `Method` is not a thing a file can carry, and inventing one on the way back in would
    # claim the code in this process is the code that produced the record.
    @test back[1].method === nothing
end

@testset "a record names the versions it was taken against" begin
    # `energy` being experimental in v0.3 says nothing about v0.9.
    v = ExperimentalAPI.record(() -> Sim.driver(M, 10)).versions
    @test v isa AbstractDict
    @test !isempty(v)
end

@testset "the reason is carried into the record" begin
    # Scope: readable a year later by someone who never saw the source.
    @test occursin(
        "convergence", first(ExperimentalAPI.record(() -> Sim.driver(M, 10))).reason
    )
end

# ── using it as a gate ───────────────────────────────────────────────────────────────────────

@testset "a run can be asserted to have touched nothing experimental" begin
    @test ExperimentalAPI.assert_clean(() -> 1 + 1)
end

@testset "the assertion fails, naming the mark, when the run is not clean" begin
    # Control: a gate that cannot be shown to fire is not a gate.
    @test !ExperimentalAPI.assert_clean(() -> Sim.driver(M, 10); throw=false)
    e = try
        ExperimentalAPI.assert_clean(() -> Sim.driver(M, 10))
        nothing
    catch err
        err
    end
    @test e isa ErrorException
    msg = sprint(showerror, e)
    @test occursin("energy", msg)
    @test occursin("convergence not established", msg)   # the reason, not only the name
end
