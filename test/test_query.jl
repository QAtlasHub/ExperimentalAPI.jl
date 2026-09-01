# The query side: what a tool gets back, and the guarantees it can rely on.

using ExperimentalAPI: MARKS_BINDING, Mark, experimental, isexperimental, mark

module Queried
using ExperimentalAPI
public zeta, alpha, mu
@experimental "z" zeta(x) = x
@experimental "a" alpha(x) = x
@experimental "m" mu(x) = x
end

@testset "results are sorted, so a tool's output is stable across runs" begin
    @test [mk.name for mk in experimental(Queried)] == [:alpha, :mu, :zeta]
    # Declaration order is not sorted order — otherwise this would pass without sorting.
    @test [mk.name for mk in getfield(Queried, MARKS_BINDING)] == [:zeta, :alpha, :mu]
end

@testset "the returned vector is a copy" begin
    v = experimental(Queried)
    n = length(v)
    empty!(v)
    @test length(experimental(Queried)) == n
end

@testset "mark carries the reason to whoever needs it" begin
    @test mark(Queried, :alpha).reason == "a"
    @test mark(Queried, :alpha).mod === Queried
    @test mark(Queried, :nope) === nothing
    @test isexperimental(Queried, :alpha)
    @test !isexperimental(Queried, :nope)
end

@testset "marking is orthogonal to visibility" begin
    # A name can be marked without being public, and public without being marked. Neither
    # implies the other, which is the whole reason this is a separate axis.
    @test isexperimental(Queried, :alpha) && Base.ispublic(Queried, :alpha)
    @test !isexperimental(Base, :sum) && Base.ispublic(Base, :sum)
end

@testset "a Mark prints its reason and its site" begin
    s = sprint(show, MIME"text/plain"(), mark(Queried, :alpha))
    @test occursin("reason:", s)
    @test occursin("\"a\"", sprint(show, mark(Queried, :alpha)))
    @test occursin("declared:", s)
end
