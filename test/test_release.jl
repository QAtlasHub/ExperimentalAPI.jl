# The release-decision layer: a snapshot survives a round trip through TOML, and a diff of two
# snapshots says which moves break callers.
#
# The fixture is a pair of hand-written snapshots rather than two loaded versions of a package,
# because that is how a real caller uses it: the old side comes off disk, from a file committed
# at the last release.

using ExperimentalAPI:
    Diff, compare, isbreaking, read_snapshot, snapshot, stable, write_snapshot, experimental

module Released
using ExperimentalAPI
export kept, dropped_stable, becomes_experimental
public kept_experimental, dropped_experimental, becomes_stable

"kept"
kept(x) = x
"dropped_stable"
dropped_stable(x) = x
"becomes_experimental"
becomes_experimental(x) = x
@experimental "a" kept_experimental(x) = x
@experimental "b" dropped_experimental(x) = x
@experimental "c" becomes_stable(x) = x
end

module Current
using ExperimentalAPI
export kept, added_stable, becomes_stable
public kept_experimental, added_experimental, becomes_experimental

"kept"
kept(x) = x
"added_stable"
added_stable(x) = x
"becomes_stable"
becomes_stable(x) = x
@experimental "a" kept_experimental(x) = x
@experimental "d" added_experimental(x) = x
@experimental "e" becomes_experimental(x) = x
end

@testset "snapshot records the covenant and the reasons" begin
    s = snapshot(Released)
    @test s["module"] == "Released"
    @test Symbol.(s["stable"]) == stable(Released)
    @test sort(collect(keys(s["experimental"]))) ==
        ["becomes_stable", "dropped_experimental", "kept_experimental"]
    @test s["experimental"]["kept_experimental"]["reason"] == "a"
end

module WithMetadata
using ExperimentalAPI
public detailed, bare
@experimental(
    "shape undecided",
    since = v"0.2.1",
    tracking = "https://example.invalid/issues/9",
    detailed(x) = x
)
@experimental "no metadata" bare(x) = x
end

@testset "metadata survives the snapshot" begin
    e = snapshot(WithMetadata)["experimental"]
    @test e["detailed"]["reason"] == "shape undecided"
    @test e["detailed"]["since"] == "0.2.1"
    @test e["detailed"]["tracking"] == "https://example.invalid/issues/9"
    # Absent metadata is absent from the file, not `nothing` — TOML has no null.
    @test collect(keys(e["bare"])) == ["reason"]
    mktempdir() do dir
        path = write_snapshot(joinpath(dir, "m.toml"), WithMetadata)
        @test read_snapshot(path) == snapshot(WithMetadata)
    end
end

@testset "TOML round trip" begin
    mktempdir() do dir
        path = joinpath(dir, "api.toml")
        @test write_snapshot(path, Released) == path
        back = read_snapshot(path)
        @test back == snapshot(Released)
        # Written as TOML, not as a Julia repr — a release script in any language can read it.
        @test occursin("[experimental.kept_experimental]", read(path, String))
    end
end

@testset "compare sorts each move into the right bucket" begin
    d = compare(snapshot(Released), Current)
    @test d isa Diff
    @test d.removed_stable == [:dropped_stable]
    @test d.demoted == [:becomes_experimental]
    @test d.removed_experimental == [:dropped_experimental]
    @test d.promoted == [:becomes_stable]
    @test d.added_stable == [:added_stable]
    @test d.added_experimental == [:added_experimental]
end

@testset "removing an experimental name is not breaking" begin
    # The claim the whole package exists to make mechanical. Same removal, twice: once from a
    # name that was declared, once from a name that was not.
    old = Dict(
        "module" => "M",
        "stable" => ["a", "b"],
        "experimental" => Dict("c" => Dict("reason" => "r")),
    )
    dropped_experimental = compare(
        old, Dict("module" => "M", "stable" => ["a", "b"], "experimental" => Dict())
    )
    dropped_stable = compare(
        old,
        Dict(
            "module" => "M",
            "stable" => ["a"],
            "experimental" => Dict("c" => Dict("reason" => "r")),
        ),
    )

    @test dropped_experimental.removed_experimental == [:c]
    @test !isbreaking(dropped_experimental)
    @test dropped_stable.removed_stable == [:b]
    @test isbreaking(dropped_stable)
end

@testset "withdrawing a promise is breaking" begin
    d = compare(
        Dict("module" => "M", "stable" => ["a"], "experimental" => Dict()),
        Dict(
            "module" => "M",
            "stable" => String[],
            "experimental" => Dict("a" => Dict("reason" => "r")),
        ),
    )
    @test d.demoted == [:a]
    @test isempty(d.removed_stable)
    @test isbreaking(d)
end

@testset "an unchanged surface is not breaking and moves nothing" begin
    d = compare(snapshot(Released), Released)
    @test !isbreaking(d)
    @test all(
        isempty,
        (
            d.removed_stable,
            d.demoted,
            d.removed_experimental,
            d.promoted,
            d.added_stable,
            d.added_experimental,
        ),
    )
end

@testset "compare reads a snapshot with missing sections" begin
    # A hand-written or truncated file must not throw; absent means empty.
    d = compare(Dict{String,Any}(), Dict("stable" => ["a"], "experimental" => Dict()))
    @test d.added_stable == [:a]
    @test !isbreaking(d)
end

@testset "show marks the breaking rows" begin
    s = sprint(show, MIME"text/plain"(), compare(snapshot(Released), Current))
    @test occursin("BREAKING", s)
    @test occursin("dropped_stable", s)
    @test !occursin(
        "BREAKING", sprint(show, MIME"text/plain"(), compare(snapshot(Released), Released))
    )
end
