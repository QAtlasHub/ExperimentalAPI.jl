# The package runs its own check on itself. Every public name of ExperimentalAPI is either
# documented or declared @experimental — including four whole layers that are declared because
# what they rest on is a guess, not because declaring them was convenient.

using ExperimentalAPI: ExperimentalAPI, audit, experimental, isexperimental, test_surface
using Test

@testset "ExperimentalAPI accounts for its own surface" begin
    test_surface(ExperimentalAPI)
end

# Which layers say they are not settled, and the fact each one's reason has to name. The anchor is
# a measured detail rather than the word "experimental", because a reason that could be written
# without doing the measurement is the placeholder this package exists to refuse.
const YOUNG_LAYERS = Dict(
    :release => (
        "schema",
        [
            :snapshot,
            :read_snapshot,
            :write_snapshot,
            :compare,
            :compare_methods,
            :isbreaking,
            :stamp,
            :Diff,
            :MethodDiff,
        ],
    ),
    :record => (
        "segfault",
        [
            :record,
            :recording,
            :Record,
            :Hit,
            :Attribution,
            :attribute,
            :experimental_fraction,
            :merge_records,
            :write_record,
            :read_record,
            :assert_clean,
            :TimingBackend,
            :timing_backend,
        ],
    ),
    :macros => ("changed twice", [Symbol("@entered")]),
    :reach => (
        "getdebugidx",
        [
            :reach,
            :reach_script,
            :Reach,
            :Reached,
            :Unresolved,
            :verdict,
            :isclean,
            :combine,
            :dependents,
        ],
    ),
    :verify => (
        "jl_write_coverage_data",
        [
            :verification,
            :Verification,
            :coverage,
            :coverage_enabled,
            :unverified,
            :stale_marks,
            :flush_coverage,
        ],
    ),
)

@testset "the young layers say what they are" begin
    declared = Set(mk.name for mk in experimental(ExperimentalAPI))
    @test declared == Set(Iterators.flatten(last(v) for v in values(YOUNG_LAYERS)))
    for (layer, (anchor, names)) in YOUNG_LAYERS, n in names
        mk = only(ExperimentalAPI.marks(ExperimentalAPI, n))
        @test occursin(anchor, mk.reason)
        @test !isempty(strip(mk.reason))
    end
end

@testset "the settled core is not declared experimental" begin
    # The control the testset above cannot be: an equality against a hand-written set is satisfied
    # by marking every name and updating the set to match. These are the names the front page
    # promises answers from, and a promise is exactly what a mark withdraws.
    for n in [
        Symbol("@experimental"),
        :Mark,
        :mark,
        :marks,
        :marks_on,
        :isexperimental,
        :experimental,
        :experimental_methods,
        :Probe,
        :entered,
        :probes,
        :detecting,
        :summary_text,
        :marked_modules,
        :Audit,
        :audit,
        :surface,
        :stable,
        :isdocumented,
        :own_methods,
        :contributed_methods,
        :ready_to_promote,
        :age,
        :docstring_note,
    ]
        @test n in audit(ExperimentalAPI).surface
        @test !isexperimental(ExperimentalAPI, n)
    end
end

@testset "the extension declares its own knobs, and the parent can see it" begin
    # An extension is a separate module: its public names are part of the surface a user sees and
    # are invisible to `names(ExperimentalAPI)`. `extensions = true` is what reaches them.
    ext = Base.get_extension(ExperimentalAPI, :ExperimentalAPITestExt)
    @test ext !== nothing
    @test !isempty(experimental(ext))
    @test any(mk -> mk.mod === ext, experimental(ExperimentalAPI; extensions=true))
    # Control: the parent's own marks do not answer this, so the keyword has to do something.
    @test !any(mk -> mk.mod === ext, experimental(ExperimentalAPI))
end

@testset "@experimental is the only exported name" begin
    # Visibility is the language's job and this package leans on it: one macro is exported
    # because it is written at a definition site, and everything else is `public` and qualified.
    @test names(ExperimentalAPI; all=false) ⊇ [Symbol("@experimental")]
    @test Base.isexported(ExperimentalAPI, Symbol("@experimental"))
    for n in audit(ExperimentalAPI).surface
        n === Symbol("@experimental") && continue
        @test !Base.isexported(ExperimentalAPI, n)
        @test Base.ispublic(ExperimentalAPI, n)
    end
end

@testset "the registry binding is not part of the surface" begin
    @test ExperimentalAPI.MARKS_BINDING ∉ audit(ExperimentalAPI).surface
    @test ExperimentalAPI.MARKS_BINDING ∈ names(ExperimentalAPI; all=true)
end
