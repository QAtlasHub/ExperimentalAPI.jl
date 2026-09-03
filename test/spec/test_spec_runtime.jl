# What a real run touched — and what it costs when nobody asks.
#
# The question is provenance for a result, not documentation: after a twelve-hour DMRG run, which
# unverified code paths did it go through, and how often? A docstring cannot answer that. This is
# the part of the intent that a reviewer cannot dismiss as "put it in the docstring".
#
# Two routes were measured on 2026-09-03, **Julia 1.12.2**, and the cheap one does NOT work:
#
#   sampling profiler + Method-set membership   -> 0 samples attributed
#       `Profile.fetch` frames for inlined callees carry no `MethodInstance`, so exactly the
#       small functions most likely to be marked disappear. `@noinline` did not rescue it.
#
#   custom AbstractInterpreter (static)         -> works, see test_spec_propagate.jl
#       but answers "could reach", not "did reach, N times".
#
# So the runtime half still needs a mechanism. Whatever it is, the constraint below is the one
# that must not be traded away.

using ExperimentalAPI: ExperimentalAPI, @experimental
using Test

module Hot

using ExperimentalAPI

public inner, driver, cold_path

@experimental "not validated below β ≈ 0.1" inner(x::Float64) = x * 1.0000001
function driver(n::Int, x::Float64)
    s = 0.0
    for _ in 1:n
        s += inner(x)
    end
    return s
end

@experimental "never called by the fixture" cold_path(x::Float64) = x - 1.0

end # module Hot

@testset "the mark does not wrap the call" begin
    # The property the package currently advertises and must keep: `@experimental` emits the
    # definition unchanged plus one `push!` at load time. If instrumentation ever becomes
    # unconditional, an inner loop pays for it on every iteration.
    # Reading `src/mark.jl` for a prose phrase would pass for a regression that wrapped the call
    # and left the sentence alone. Look at what the macro emits.
    emitted = string(@macroexpand @experimental "why" f(x) = x)
    @test occursin("f(x)", emitted)                # the definition is there…
    @test !occursin("function f", replace(emitted, "f(x)" => ""))   # …and not wrapped in another
    @test Hot.driver(3, 1.0) ≈ 3 * 1.0000001
end

@testset "a marked definition is not slower than the same definition unmarked" begin
    unmarked(x::Float64) = x * 1.0000001
    function loop(f)
        acc = 0.0
        for _ in 1:2_000_000
            acc += f(1.0)
        end
        return acc
    end
    loop(Hot.inner)
    loop(unmarked)                       # warm both before timing either
    a = @elapsed loop(Hot.inner)
    b = @elapsed loop(unmarked)
    # Loose on purpose: this is a floor against wrapping, not a benchmark. A wrapper that
    # increments a counter would not fit inside this margin.
    @test a < 5b + 1e-3
end

@testset "recording is off unless it is asked for" begin
    @test_broken ExperimentalAPI.recording() === false
end

@testset "a recorded run reports which marked definitions it entered" begin
    @test_broken :inner in
        [h.name for h in ExperimentalAPI.record(() -> Hot.driver(1000, 1.0))]
end

@testset "a recorded run reports how many times" begin
    # "Did it touch experimental code" and "was 97% of the run inside it" are different answers,
    # and only the second tells you whether the result is worth anything.
    @test_broken ExperimentalAPI.record(() -> Hot.driver(1000, 1.0))[1].count == 1000
end

@testset "a marked definition the run never entered is not reported as touched" begin
    # Without this, a recorder that lists every mark in the module passes the two tests above.
    @test_broken :cold_path ∉
        [h.name for h in ExperimentalAPI.record(() -> Hot.driver(10, 1.0))]
end

@testset "recording survives inlining" begin
    # The reason the sampling-profiler route failed. Whatever mechanism is chosen has to be
    # demonstrated on a small function that the optimiser would normally inline away — which is
    # most of what gets marked.
    @test_broken ExperimentalAPI.record(() -> Hot.driver(100, 1.0))[1].count == 100
end

@testset "the record attributes to a method, not just a name" begin
    # `QAtlas.fetch` has 570 methods (measured 2026-09-03, not re-derived here). "the run touched `fetch`" is not usable; "the run took the
    # Numerical × Float64 path 4.7M times" is.
    @test_broken first(ExperimentalAPI.record(() -> Hot.driver(10, 1.0))).method isa Method
end

@testset "a run with no marked code reports nothing rather than failing" begin
    @test_broken isempty(ExperimentalAPI.record(() -> sum(1:10)))
end

@testset "the record is data on the normal return path" begin
    # Same convention as `audit` and `test_surface`: the caller gets the numbers back whether or
    # not it asked for printing.
    @test_broken ExperimentalAPI.record(() -> Hot.driver(10, 1.0)) isa AbstractVector
end
