# `@entered expr` — the expression-level spelling of the observing layer.
#
# Scope: what the macro adds over `record(() -> expr)`. Two of those are things only a macro can
# get wrong — evaluating its argument twice, and reporting a location that is not the caller's —
# and one is the distinction the whole report exists for: a call that entered nothing is not the
# same state as a package that has nothing marked.

using ExperimentalAPI: ExperimentalAPI, @experimental
using Test

module MacroFixture

using ExperimentalAPI

public energy, correlator, driver, cold, boom

@experimental "convergence not established below β ≈ 0.1" energy(x) = x * 1.0000001
@experimental "edge cases at zero separation untested" correlator(x, r) = x / (r + 1)
@experimental "never exercised by this file" cold(x) = x

"Settled."
partition(x) = exp(-x)
inner(x) = energy(x) + partition(x)
driver(x, n) = sum(inner(x) for _ in 1:n)

"Documented, and it throws."
boom(x) = (energy(x); error("boom"))

# Counts how many times the macro evaluated its argument. A macro that splices `expr` twice —
# once to run and once to report — doubles every count it prints, and the count is the answer.
const CALLS = Ref(0)
bump(x) = (CALLS[] += 1; driver(x, 3))

end # module MacroFixture

"Everything `f` wrote to `stdout`, and its value."
function grab(f)
    old = stdout
    rd, wr = redirect_stdout()
    value = try
        f()
    finally
        redirect_stdout(old)
        close(wr)
    end
    return value, read(rd, String)
end

@testset "@entered returns the value of the expression, not the record" begin
    # The property that lets it be dropped into existing code, the way `@time` is.
    v, _ = grab(() -> ExperimentalAPI.@entered MacroFixture.driver(0.5, 4))
    @test v isa Float64
    @test v ≈ MacroFixture.driver(0.5, 4)
    # Control: it is emphatically NOT the record, which is what a first implementation returns.
    @test !(v isa AbstractVector)
end

@testset "the expression is evaluated exactly once" begin
    # A macro that splices `expr` into both the run and the report doubles every count it prints,
    # and the count is the answer. Nothing else in this file would notice.
    MacroFixture.CALLS[] = 0
    grab(() -> ExperimentalAPI.@entered MacroFixture.bump(0.5))
    @test MacroFixture.CALLS[] == 1
end

@testset "the report names what was entered, how often, and why" begin
    _, out = grab(() -> ExperimentalAPI.@entered MacroFixture.driver(0.5, 10))
    @test occursin("MacroFixture.energy", out)
    @test occursin("×10", out)                                   # the count, not just presence
    @test occursin("convergence not established", out)           # the reason travels
    # A definition that was never entered is ABSENT, not reported with a count of zero.
    @test !occursin("cold", out)
    @test !occursin("×0", out)
end

@testset "a call that entered nothing says so, and says what was loaded" begin
    # The distinction the last line exists for. Without the count, "entered nothing marked" reads
    # the same on a package with seventeen marks and on one with none — and the second is the
    # state every package is in before it adopts this.
    _, out = grab(() -> ExperimentalAPI.@entered sum(1:10))
    @test occursin("entered nothing marked", out)
    @test occursin(r"\d+ observable marked definitions were loaded", out)
    # Control: the two answers really are different text, so a report that always printed one of
    # them could not pass both this and the testset above.
    _, dirty = grab(() -> ExperimentalAPI.@entered MacroFixture.driver(0.5, 2))
    @test !occursin("entered nothing marked", dirty)
end

@testset "the report names the call and the line it was written on" begin
    # What the macro knows and a closure does not. The line is asserted against `@__LINE__` taken
    # on the same line, so a report that printed the macro's own definition site would fail.
    line = 0
    _, out = grab() do
        line = @__LINE__
        ExperimentalAPI.@entered MacroFixture.driver(0.5, 2)
    end
    @test occursin("driver(0.5, 2)", out)
    @test occursin("test_macros.jl:$(line + 1)", out)
end

@testset "recording is not left on" begin
    grab(() -> ExperimentalAPI.@entered MacroFixture.driver(0.5, 2))
    @test ExperimentalAPI.recording() === false
end

@testset "an exception propagates, and the flag it set survives" begin
    # Stated rather than silent: the report is not printed for a run that threw. `record` with
    # `rethrow = false` is the form that reports what a failed run went through, and the
    # docstring says so.
    @test_throws ErrorException grab(() -> ExperimentalAPI.@entered MacroFixture.boom(0.5))
    # …and the default layer still saw it, because that is the layer that costs nothing.
    @test :energy in [e.name for e in ExperimentalAPI.entered(MacroFixture)]
end

@testset "@experimental is still the only exported name" begin
    # `@entered` is `public` and qualified, like everything but the mark itself. Written at a
    # call site rather than a definition site, it is the one that would most tempt an export.
    @test Base.ispublic(ExperimentalAPI, Symbol("@entered"))
    @test !Base.isexported(ExperimentalAPI, Symbol("@entered"))
end
