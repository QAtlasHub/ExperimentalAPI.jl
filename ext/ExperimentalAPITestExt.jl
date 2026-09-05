# `test_surface` lives in an extension so that `ExperimentalAPI` — which is loaded by the package
# being marked, not only by its test suite — never drags `Test` into a runtime dependency.

module ExperimentalAPITestExt

using ExperimentalAPI:
    ExperimentalAPI,
    Audit,
    audit,
    extends_base,
    isdocumented,
    isexperimental,
    experimental,
    partition_holds
using Test: Test, @test, @testset

# The knobs below are the newest part of this package and the least settled: which of them a
# project should turn on is a question no measurement has answered yet, and the answer will change
# what they mean. The mark is written here, in the extension that defines them, which is also the
# case `experimental(m; extensions = true)` exists for.
ExperimentalAPI.@experimental(
    "which gates a project should run, and therefore what these keywords should default to, is " *
        "undecided; `require_tracking` and `max_marks` may be replaced by one policy argument",
    since = v"0.1.0",
    until = () -> false,
    test_surface,
)

function ExperimentalAPI.test_surface(
    m::Module;
    skip::AbstractVector{Symbol}=Symbol[],
    require_tracking::Bool=false,
    max_marks::Union{Int,Nothing}=nothing,
    methods::Bool=true,
    require_methods::Symbol=:foreign,
    outputlevel::Int=0,
)
    require_methods in (:none, :foreign, :all) || throw(
        ArgumentError(
            "test_surface: require_methods must be :none, :foreign or :all, got " *
            repr(require_methods),
        ),
    )
    a = audit(m; methods)
    outputlevel ≥ 1 && show(stdout, MIME"text/plain"(), a)
    @testset "public surface of $(nameof(m))" begin
        # Assertions that run whatever the audit found. Everything below iterates over a set of
        # findings, so on a clean module all of it collapses to nothing and the testset would
        # report `0 tests passed` — a green indistinguishable from the extension having failed to
        # load, or from `m` having no public names at all. These make the pass mean something.
        @testset "every public name has a docstring" begin
            @test isempty(setdiff(a.undocumented, skip))
            @test isempty(a.dangling)
            @test partition_holds(a)
        end
        # One testset per name, so a failing CI log names the symbol in its header rather than
        # printing a set difference the reader has to diff by eye.
        @testset "$n has a docstring" for n in setdiff(a.undocumented, skip)
            @test isdocumented(m, n)
        end
        # The allowlist can only shrink. An entry that has since been documented or deleted fails
        # here — otherwise adopting this on a package with a backlog would leave a list that
        # silently stops describing anything, and a green suite would mean less every release.
        #
        # `skip` is the only way to pass an undocumented name, and it is per-name and visible.
        # There is deliberately no switch that turns the docstring requirement off wholesale: a
        # mark records that a shape is unsettled, and that is never a reason to say nothing about
        # what the name does.
        @testset "skip entry $n is still needed" for n in skip
            @test n in a.undocumented
        end
        # Needs no oracle: the module marked a name it never made public.
        @testset "@experimental $n is public" for n in a.dangling
            @test n in a.surface
        end
        # A mark with no tracking link is a note to nobody. Off by default because whether a
        # project can require one depends on whether it has an issue tracker at all.
        if require_tracking
            @testset "@experimental $(mk.name) says where it is being decided" for mk in
                                                                                   experimental(
                m
            )
                @test mk.tracking !== nothing
            end
        end
        # The ratchet. `nothing` rather than `typemax`: a cap that is off must not read as a cap
        # that is enormous, because the second is a number somebody has to justify.
        if max_marks !== nothing
            @testset "at most $max_marks marks" begin
                @test length(experimental(m)) <= max_marks
            end
        end
        # A method contributed to another module's generic is invisible to `names(m)`, so for a
        # package whose surface is such methods every assertion above passes having looked at
        # nothing.
        #
        # `:foreign` by default rather than `:all`: `Base.show(io, ::Audit)` is a protocol Base
        # documents, and a default that reports every `show`, `==` and `getindex` method as a
        # finding is a default that gets switched off wholesale. See `extends_base` for the rule.
        checked = if require_methods === :none
            Method[]
        elseif require_methods === :all
            a.unaccounted_methods
        else
            filter(!extends_base, a.unaccounted_methods)
        end
        @testset "contributed method $(mm.name)$(mm.sig) is accounted for" for mm in checked
            @test isdocumented(mm) || isexperimental(mm)
        end
    end
    return a
end

end # module
