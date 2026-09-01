# `test_surface` is the reason the rest of the package exists, so the thing to establish is not
# that it passes on a clean module — it is that it FAILS on a dirty one, and fails naming the
# right symbol. A check that cannot be shown to fail has not been shown to check anything.
#
# `Recorder` collects results instead of throwing, which is what lets a passing suite contain a
# deliberate failure.

using ExperimentalAPI: audit, test_surface
using Test: Test

struct Recorder <: Test.AbstractTestSet
    description::String
    results::Vector{Any}
end
Recorder(desc::AbstractString; kwargs...) = Recorder(String(desc), [])
Test.record(ts::Recorder, res) = (push!(ts.results, res); res)
# A nested Recorder attaches to its Recorder parent — that tree is the thing being read — but a
# Recorder never attaches to the enclosing DefaultTestSet: the failures staged below are the
# fixture, and they must not reach the suite that is asserting they happened.
function Test.finish(ts::Recorder)
    if Test.get_testset_depth() > 0
        parent = Test.get_testset()
        parent isa Recorder && Test.record(parent, ts)
    end
    return ts
end

# The leaves of a nested Recorder tree, paired with the description path that reached them.
function leaves(ts::Recorder, prefix=String[])
    out = Pair{Vector{String},Any}[]
    path = vcat(prefix, ts.description)
    for r in ts.results
        r isa Recorder ? append!(out, leaves(r, path)) : push!(out, path => r)
    end
    return out
end

failures(ts::Recorder) = [p for (p, r) in leaves(ts) if !(r isa Test.Pass)]
failed_names(ts::Recorder) = Set(last(p) for p in failures(ts))

module Clean
using ExperimentalAPI
export documented
public marked
"documented"
documented(x) = x
@experimental "not settled" marked(x) = x
end

module Dirty
using ExperimentalAPI
export documented
public silent_one, silent_two
"documented"
documented(x) = x
silent_one(x) = x
silent_two(x) = x
@experimental "marked but never made public" not_public(x) = x
end

@testset "the extension loads with Test" begin
    @test isdefined(Base, :get_extension)
    @test Base.get_extension(ExperimentalAPI, :ExperimentalAPITestExt) !== nothing
    @test !isempty(methods(test_surface))
end

@testset "a clean module passes" begin
    ts = Test.@testset Recorder "clean" begin
        test_surface(Clean)
    end
    @test isempty(failures(ts))
end

@testset "a dirty module fails, and names what is wrong" begin
    ts = Test.@testset Recorder "dirty" begin
        test_surface(Dirty)
    end
    names = failed_names(ts)
    @test "silent_one is documented or @experimental" in names
    @test "silent_two is documented or @experimental" in names
    @test "@experimental not_public is public" in names
    # The documented name is not among the complaints.
    @test !any(occursin("documented is", n) for n in names)
    @test length(names) == 3
end

@testset "skip suppresses a known gap" begin
    ts = Test.@testset Recorder "skipped" begin
        test_surface(Dirty; skip=[:silent_one, :silent_two])
    end
    @test failed_names(ts) == Set(["@experimental not_public is public"])
end

@testset "a stale skip entry fails" begin
    # This is what stops the allowlist from quietly becoming a list of nothing. Three ways an
    # entry can go stale, and all three have to be caught.
    ts = Test.@testset Recorder "stale" begin
        test_surface(
            Dirty;
            skip=[:silent_one, :documented, :marked_elsewhere, :silent_two, :not_public],
        )
    end
    names = failed_names(ts)
    @test "skip entry documented is still needed" in names        # since documented
    @test "skip entry marked_elsewhere is still needed" in names   # never existed
    @test "skip entry not_public is still needed" in names         # not on the surface at all
    @test "skip entry silent_one is still needed" ∉ names          # genuinely still needed
end

@testset "the audit comes back whether it passed or not" begin
    # The trust number is on the normal return path — the caller never has to re-run the check
    # to find out what it saw.
    for m in (Clean, Dirty)
        local got = nothing
        ts = Test.@testset Recorder "r" begin
            got = test_surface(m; skip=collect(audit(m).unaccounted))
        end
        @test got isa ExperimentalAPI.Audit
        @test got.mod === m
        @test got.surface == audit(m).surface
    end
end

@testset "outputlevel prints, and nothing else depends on it" begin
    quiet = mktemp() do path, io
        redirect_stdout(io) do
            Test.@testset Recorder "q" begin
                test_surface(Clean; outputlevel=0)
            end
        end
        flush(io)
        read(path, String)
    end
    loud = mktemp() do path, io
        redirect_stdout(io) do
            Test.@testset Recorder "l" begin
                test_surface(Clean; outputlevel=1)
            end
        end
        flush(io)
        read(path, String)
    end
    @test isempty(strip(quiet))
    @test occursin("Public surface of Main.Clean", loud) ||
        occursin("Public surface of Clean", loud)
end
