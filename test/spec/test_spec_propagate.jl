# A caller that never names a marked thing still depends on it.
#
# Modelled on Lean's `sorry`, but Julia's call graph is not closed, so the answer is three-valued:
#
#     :depends   a marked definition is reachable
#     :clean     the whole call graph was resolved and nothing marked is in it
#     :unknown   some call site could not be resolved — the honest non-answer
#
# Scope: collapsing `:unknown` into `:clean` is the one failure this file exists to prevent. It is
# not a weaker claim, it is a false one.
#
# The mechanism is a `Core.Compiler.AbstractInterpreter` hooking `abstract_call_method`, because
# inference runs before inlining; `code_typed(...; optimize=true)` sees only `mul_float` and finds
# nothing.

using ExperimentalAPI: ExperimentalAPI, @experimental, experimental
using Test

module Chain

using ExperimentalAPI

public unstable,
    solid,
    mid_bad,
    mid_good,
    top_bad,
    top_good,
    top_arg,
    top_nospec,
    top_field,
    top_table,
    top_recursive,
    top_mutual_a,
    CONSTANT_BAD,
    top_uses_const,
    MarkedStruct,
    top_constructs

@experimental "convergence is not established below β ≈ 0.1" unstable(x::Float64) =
    x * 1.0000001
"Settled."
solid(x::Float64) = x * 2.0

# one hop
mid_bad(x::Float64) = unstable(x) + 1.0
mid_good(x::Float64) = solid(x) + 1.0

# two hops — neither `top_*` mentions `unstable`
top_bad(x::Float64) = mid_bad(x) * 3
top_good(x::Float64) = mid_good(x) * 3

# passed as a value — Julia specialises on `typeof(f)`, so this resolves
apply(f, x::Float64) = f(x)
top_arg(x::Float64) = apply(unstable, x)

# `@nospecialize` — still resolves
top_nospec(@nospecialize(f), x::Float64) = f(x)

# genuinely unresolvable: the callee is a value chosen at run time
struct Holder
    f::Function
end
top_field(h::Holder, x::Float64) = h.f(x)

const TABLE = Function[unstable, solid]
top_table(i::Int, x::Float64) = TABLE[i](x)

# termination
top_recursive(n::Int, x::Float64) = n <= 0 ? unstable(x) : top_recursive(n - 1, x)

# Deep enough that a depth limit must truncate. `top_recursive` calls `unstable` in its own body,
# so a depth test written against that one would pass for an implementation ignoring the keyword.
deep_5(x::Float64) = unstable(x)
deep_4(x::Float64) = deep_5(x)
deep_3(x::Float64) = deep_4(x)
deep_2(x::Float64) = deep_3(x)
deep_1(x::Float64) = deep_2(x)
top_mutual_a(n::Int, x::Float64) = n <= 0 ? unstable(x) : top_mutual_b(n - 1, x)
top_mutual_b(n::Int, x::Float64) = top_mutual_a(n - 1, x)

# a marked const is not a call site — a different mechanism is needed to see its use
@experimental "the tolerance is a guess" const CONSTANT_BAD = 1e-8
top_uses_const(x::Float64) = x + CONSTANT_BAD

# a marked struct: construction is a call, field access is not
@experimental "layout not settled" struct MarkedStruct
    v::Float64
end
top_constructs(x::Float64) = MarkedStruct(x).v

end # module Chain

const ENTRY = Tuple{Float64}

@testset "the mark itself is in place, so the fixture can disagree" begin
    names = Set(mk.name for mk in experimental(Chain))
    @test :unstable in names
    @test :CONSTANT_BAD in names
    @test :MarkedStruct in names
    @test :solid ∉ names          # the negative control really is unmarked
end

# ── the type the answer lives in ─────────────────────────────────────────────────────────────
#
# `Mark` and `Audit` are pinned nominally elsewhere in this directory. Without the same here, a
# `NamedTuple` with the right field names satisfies every assertion in four files.

@testset "the result has a type, not just field names" begin
    @test ExperimentalAPI.reach(Chain.top_bad, ENTRY) isa ExperimentalAPI.Reach
end

@testset "verdict is derived, never stored" begin
    # A stored `verdict` makes `:clean` with a non-empty `.unresolved` representable, which is
    # the one state this file forbids. Same rule as `isbreaking(d::Diff)`.
    @test !hasproperty(ExperimentalAPI.reach(Chain.top_bad, ENTRY), :verdict)
end

@testset "a boolean gate exists alongside the three-valued answer" begin
    # Every other verdict here is a named predicate, never a comparison the caller writes out.
    @test ExperimentalAPI.isclean(ExperimentalAPI.reach(Chain.top_good, ENTRY)) === true
    @test ExperimentalAPI.isclean(ExperimentalAPI.reach(Chain.top_bad, ENTRY)) === false
end

@testset ":unknown absorbs when results are combined" begin
    # `reach(Module)` folds every public entry into one answer, so the algebra must exist: one
    # `:unknown` is not clean whatever the others say, and folding is order-independent.
    @test ExperimentalAPI.combine(:clean, :unknown) === :unknown
    @test ExperimentalAPI.combine(:depends, :unknown) === :depends
    @test ExperimentalAPI.combine(:clean, :depends) === :depends
    @test ExperimentalAPI.combine(:clean, :clean) === :clean
    @test ExperimentalAPI.combine(:unknown, :clean) ===
        ExperimentalAPI.combine(:clean, :unknown)
end

# ── the core claim ───────────────────────────────────────────────────────────────────────────

@testset "a caller two hops away is reported as depending" begin
    @test ExperimentalAPI.verdict(ExperimentalAPI.reach(Chain.top_bad, ENTRY)) === :depends
    # `.reached` holds `Reached`, which pairs the mark with the method and the path it was
    # reached by — the name alone would not say through which of the caller's own code.
    @test :unstable in
        [r.mark.name for r in ExperimentalAPI.reach(Chain.top_bad, ENTRY).reached]
end

@testset "an equally deep caller with nothing marked is reported clean" begin
    # Control: rejects a tool that always says `:depends`.
    @test ExperimentalAPI.verdict(ExperimentalAPI.reach(Chain.top_good, ENTRY)) === :clean
    @test isempty(ExperimentalAPI.reach(Chain.top_good, ENTRY).reached)
end

@testset "a function passed as a value is still followed" begin
    # Specialisation on `typeof(f)` resolves this; it is not a dynamic hole.
    @test ExperimentalAPI.verdict(ExperimentalAPI.reach(Chain.top_arg, ENTRY)) === :depends
end

@testset "@nospecialize does not hide the callee" begin
    @test ExperimentalAPI.verdict(
        ExperimentalAPI.reach(Chain.top_nospec, Tuple{typeof(Chain.unstable),Float64})
    ) === :depends
end

# ── the honest non-answer ────────────────────────────────────────────────────────────────────

@testset "an abstract-typed callee field is :unknown, NOT :clean" begin
    # `Holder.f::Function` can hold `unstable`, so `:clean` here is a lie.
    @test ExperimentalAPI.verdict(
        ExperimentalAPI.reach(Chain.top_field, Tuple{Chain.Holder,Float64})
    ) === :unknown
    @test !isempty(
        ExperimentalAPI.reach(Chain.top_field, Tuple{Chain.Holder,Float64}).unresolved
    )
end

@testset "a run-time table lookup is :unknown, NOT :clean" begin
    @test ExperimentalAPI.verdict(
        ExperimentalAPI.reach(Chain.top_table, Tuple{Int,Float64})
    ) === :unknown
    @test !isempty(ExperimentalAPI.reach(Chain.top_table, Tuple{Int,Float64}).unresolved)
end

@testset "every unresolved site says where it is" begin
    # "cannot tell" is actionable only if the user can go and look.
    @test all(
        u -> hasproperty(u, :file) && hasproperty(u, :line),
        ExperimentalAPI.reach(Chain.top_field, Tuple{Chain.Holder,Float64}).unresolved,
    )
end

@testset "a depth limit reports :unknown rather than :clean" begin
    # `:unknown` rather than `!== :clean`: the latter cannot separate "the limit truncated" from
    # "the limit was ignored and the mark was found anyway".
    @test ExperimentalAPI.verdict(
        ExperimentalAPI.reach(Chain.deep_1, ENTRY; maxdepth=2)
    ) === :unknown
    # …and without the limit it is found, so the fixture can disagree.
    @test ExperimentalAPI.verdict(ExperimentalAPI.reach(Chain.deep_1, ENTRY)) === :depends
end

# ── termination ──────────────────────────────────────────────────────────────────────────────

@testset "self-recursion terminates and still finds the mark" begin
    @test ExperimentalAPI.verdict(
        ExperimentalAPI.reach(Chain.top_recursive, Tuple{Int,Float64})
    ) === :depends
end

@testset "mutual recursion terminates" begin
    @test ExperimentalAPI.verdict(
        ExperimentalAPI.reach(Chain.top_mutual_a, Tuple{Int,Float64})
    ) === :depends
end

# ── things that are not calls ────────────────────────────────────────────────────────────────

@testset "a marked const is seen where it is used" begin
    # A const is not a call site. Either the analysis reads globals out of the IR, or the case is
    # declared out of scope — what it must not do is report `:clean`.
    @test ExperimentalAPI.verdict(ExperimentalAPI.reach(Chain.top_uses_const, ENTRY)) !==
        :clean
end

@testset "a marked struct is seen at construction" begin
    @test ExperimentalAPI.verdict(ExperimentalAPI.reach(Chain.top_constructs, ENTRY)) ===
        :depends
end

@testset "marking a module marks what it contains" begin
    # Or it does not, stated. Either way a decision, not an omission.
    @test hasproperty(ExperimentalAPI.reach(Chain.top_bad, ENTRY), :through_modules)
end

# ── across packages ──────────────────────────────────────────────────────────────────────────

@testset "a mark in a dependency propagates into the dependent" begin
    # `reach isa Function` was the whole of this claim for a while, and it is satisfied by an
    # implementation that answers `:clean` for everything. The real question is whether a mark
    # written while ANOTHER package was precompiled — in a process that has since exited — is
    # visible to a caller here, and that needs a package rather than a module.
    #
    # `test/test_precompile.jl` is where it is asked, because it is the file that owns the scratch
    # depot and the two subprocess runs. This asserts it is asked there rather than restating it:
    # a claim checked in one place and mentioned in another is one that goes stale in the second.
    src = read(joinpath(@__DIR__, "..", "test_precompile.jl"), String)
    @test occursin("REACH=", src)
    @test occursin("\"REACH\"] == \"depends\"", src)
    @test occursin("\"REACHCONTROL\"] == \"clean\"", src)

    # What CAN be asked without a second package: the same shape across a module boundary, where
    # the mark is in one module and the caller in another that never names it.
    boundary(x::Float64) = Chain.top_bad(x)
    @test ExperimentalAPI.verdict(ExperimentalAPI.reach(boundary, ENTRY)) === :depends
    control(x::Float64) = Chain.top_good(x)
    @test ExperimentalAPI.verdict(ExperimentalAPI.reach(control, ENTRY)) === :clean
end

# ── cost ─────────────────────────────────────────────────────────────────────────────────────

@testset "the macro emits nothing but the definition and one push" begin
    # Look at the expansion: `Method.name` is the generic function's name, so filtering methods
    # by what their bodies call is unconditionally empty.
    emitted = string(@macroexpand @experimental "why" f(x) = x)
    @test occursin("_mark!", emitted)                       # the one load-time effect
    @test occursin("__EXPERIMENTAL_API_MARKS__", emitted)
    for forbidden in ("reach", "verdict", "record", "abstract_call_method", "code_typed")
        @testset "no $forbidden in the expansion" begin
            @test !occursin(forbidden, emitted)
        end
    end
end
