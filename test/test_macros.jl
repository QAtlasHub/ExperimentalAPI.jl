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
    # The NUMBER, not `\d+` — which any digits satisfy, including a hardcoded one.
    @test occursin("$(length(ExperimentalAPI.probes())) observable marked definitions", out)
    # Control: the two answers really are different text, so a report that always printed one of
    # them could not pass both this and the testset above.
    _, dirty = grab(() -> ExperimentalAPI.@entered MacroFixture.driver(0.5, 2))
    @test !occursin("entered nothing marked", dirty)
end

@testset "several marks in one call are all listed, and the columns line up" begin
    # Every other test drives `driver`, which enters `energy` alone — so the loop over the hits
    # and the width computation ran with exactly one row and `for h in rec[1:1]` would have been
    # invisible.
    _, out = grab() do
        ExperimentalAPI.@entered begin
            MacroFixture.driver(0.5, 3)
            MacroFixture.correlator(0.5, 2)
        end
    end
    @test occursin("MacroFixture.energy", out)
    @test occursin("MacroFixture.correlator", out)
    rows = [l for l in split(out, "\n") if startswith(l, "│")]
    @test length(rows) == 2
    # Sorted by name, so the order does not move with the measurement and two runs can be diffed.
    @test occursin("correlator", rows[1]) && occursin("energy", rows[2])
    # One column: the `×` starts at the same offset on every row.
    @test allequal(findfirst("×", r).start for r in rows)
end

@testset "the footer counts what was NOT entered, and the arithmetic holds" begin
    # This line is the reason the report exists, and nothing asserted it: deleting the whole
    # footer left the suite green.
    _, out = grab(() -> ExperimentalAPI.@entered MacroFixture.driver(0.5, 2))
    m = match(
        r"└ (\d+) of (\d+) observable marked definitions? (?:was|were) not entered", out
    )
    @test m !== nothing
    rest, total = parse(Int, m[1]), parse(Int, m[2])
    @test total == length(ExperimentalAPI.probes())
    @test rest == total - 1                       # exactly one mark was entered
    @test occursin(rest == 1 ? " was not entered" : " were not entered", out)
end

@testset "the header is a label: long expressions are cut, blocks are one line" begin
    # Both branches of `_short_expr` past the happy path, neither of which any test reached.
    _, long = grab() do
        ExperimentalAPI.@entered MacroFixture.driver(
            0.5 + 0.0 + 0.0 + 0.0 + 0.0 + 0.0 + 0.0 + 0.0 + 0.0 + 0.0 + 0.0, 2
        )
    end
    header = first(split(long, "\n"))
    @test occursin("...", header)
    @test length(header) < 100                    # cut, not merely long

    _, block = grab() do
        ExperimentalAPI.@entered begin
            MacroFixture.driver(0.5, 1)
            MacroFixture.driver(0.5, 1)
        end
    end
    blockheader = first(split(block, "\n"))
    @test occursin("begin", blockheader)
    @test !occursin("\n", blockheader)            # collapsed onto one line
    # …and a nested macro call does not leak its `#= file:line =#` into the label.
    _, nested = grab(
        () ->
            ExperimentalAPI.@entered (ExperimentalAPI.@entered MacroFixture.driver(0.5, 1))
    )
    @test !occursin("#=", nested)
end

@testset "the value comes back from the record, and `return` inside it does not" begin
    # `record` now carries `f`'s result, so measuring a call no longer costs its value — and the
    # macro reads it from there rather than out of a box that an early `return` leaves undefined.
    r = ExperimentalAPI.record(() -> MacroFixture.driver(0.5, 2))
    @test r.value ≈ MacroFixture.driver(0.5, 2)

    # The one place the `@time` comparison breaks, pinned so it cannot break further: `record`
    # takes a function, so `return` exits the expression rather than the enclosing method. It used
    # to leave the value unreachable and raise `UndefRefError`; now it is the macro's value.
    early(x) = (ExperimentalAPI.@entered (x > 5 && return :early); :normal)
    @test grab(() -> early(10))[1] === :normal
    kept(x) = ExperimentalAPI.@entered (x > 5 ? :early : MacroFixture.driver(0.5, 1))
    @test grab(() -> kept(10))[1] === :early
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

@testset "@entered writes where it is told, and only there" begin
    # The knob exists because the report is text on a stream: a caller who wants it in a log, or
    # does not want it at all, otherwise has to redirect the whole process to get at one line.
    buf = IOBuffer()
    value, printed = grab() do
        ExperimentalAPI.@entered buf MacroFixture.energy(2.0)
    end
    @test value == MacroFixture.energy(2.0)
    report = String(take!(buf))
    @test occursin("@entered", report)
    @test occursin("MacroFixture.energy", report)
    # Control: naming an `io` MOVES the report rather than copying it. Without this the two-arg
    # form would pass while still printing to the terminal.
    @test isempty(printed)

    # And the default is still looked up when the block runs, not when the macro expands, so a
    # redirect around the call reaches it.
    _, printed2 = grab() do
        ExperimentalAPI.@entered MacroFixture.energy(2.0)
    end
    @test occursin("@entered", printed2)
end
