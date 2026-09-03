# Propagation: a caller that never names a marked thing still depends on it.
#
# The model is Lean's `sorry`. Measured 2026-09-03 with Lean 4.33.1:
#
#     P.lean:1:8: warning: declaration uses `sorry`
#     'unproven'   depends on axioms: [sorryAx]
#     'downstream' depends on axioms: [sorryAx]     <- never wrote `sorry` itself
#     'honest'     does not depend on any axioms
#
# Julia cannot match that exactly, and the difference is the most important thing in this file.
# Lean's kernel has a closed dependency graph of proof terms; Julia's call graph is not closed.
# So the answer is not a Bool. It is three-valued:
#
#     :depends   a marked definition is reachable
#     :clean     the whole call graph was resolved and nothing marked is in it
#     :unknown   some call site could not be resolved — the honest non-answer
#
# Collapsing `:unknown` into `:clean` is the one failure this file exists to prevent. A tool that
# reports "no experimental dependency" about a call graph it could not see has not made a weaker
# claim, it has made a false one.
#
# Feasibility was measured on 2026-09-03, **Julia 1.12.2**, with a custom
# `Core.Compiler.AbstractInterpreter` hooking `abstract_call_method`. Inference runs before
# inlining, so the call graph is intact there; post-processing `code_typed(...; optimize=true)`
# sees only `mul_float`/`add_float` and finds nothing.
#
# The Julia version is load-bearing and is stated for the same reason `Lean 4.33.1` is above:
# `Core.Compiler` is internal and carries no stability guarantee across releases. This repository's
# CI spans 1.11 and 1.12, and the measurement was taken on one of them.

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

# a function passed as a value. Julia specialises on `typeof(f)`, so inference resolves this.
apply(f, x::Float64) = f(x)
top_arg(x::Float64) = apply(unstable, x)

# `@nospecialize` — measured to STILL resolve
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

# A chain deep enough that a depth limit MUST truncate before reaching the mark. `top_recursive`
# calls `unstable` in its own body, so it is visible at depth 1 whatever `maxdepth` says — a
# depth test written against it would pass for an implementation that ignores the keyword.
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
# `Mark` and `Audit` are both pinned nominally somewhere in this directory (`isa Mark`,
# `isa Audit`). The propagation result is not: before these tests it was pinned purely by field
# name, so a `NamedTuple` with `.reached`/`.unresolved` satisfied every assertion in four files
# and `verdict` could be duck-typed on `hasproperty`.

@testset "the result has a type, not just field names" begin
    @test_broken ExperimentalAPI.reach(Chain.top_bad, ENTRY) isa ExperimentalAPI.Reach
end

@testset "verdict is derived, never stored" begin
    # `isbreaking(d::Diff)` is a pure function over `d.removed_stable`/`d.demoted`, never a cached
    # field — which is why a `Diff` cannot claim "not breaking" while carrying a removal. Same
    # rule here: if `verdict` were a stored field, `:clean` with a non-empty `.unresolved` would
    # become representable, and that is the one state this whole file exists to forbid.
    @test_broken !hasproperty(ExperimentalAPI.reach(Chain.top_bad, ENTRY), :verdict)
end

@testset "a boolean gate exists alongside the three-valued answer" begin
    # Every existing verdict in this package is a named predicate — `isbreaking`,
    # `isexperimental`, `isdocumented` — never a comparison the caller writes out. The spec
    # hand-writes `verdict(...) === :clean` and friends 26 times, which is the smell.
    @test_broken ExperimentalAPI.isclean(ExperimentalAPI.reach(Chain.top_good, ENTRY)) ===
        true
    @test_broken ExperimentalAPI.isclean(ExperimentalAPI.reach(Chain.top_bad, ENTRY)) ===
        false
end

@testset ":unknown absorbs when results are combined" begin
    # `reach(Module)` has to fold the verdicts of every public entry into one answer, so the
    # algebra has to exist. It is stated here rather than discovered: a module with one
    # `:unknown` entry is not clean, whatever the others say, and folding is order-independent.
    @test_broken ExperimentalAPI.combine(:clean, :unknown) === :unknown
    @test_broken ExperimentalAPI.combine(:depends, :unknown) === :depends
    @test_broken ExperimentalAPI.combine(:clean, :depends) === :depends
    @test_broken ExperimentalAPI.combine(:clean, :clean) === :clean
    @test_broken ExperimentalAPI.combine(:unknown, :clean) ===
        ExperimentalAPI.combine(:clean, :unknown)
end

# ── the core claim ───────────────────────────────────────────────────────────────────────────

@testset "a caller two hops away is reported as depending" begin
    @test_broken ExperimentalAPI.verdict(ExperimentalAPI.reach(Chain.top_bad, ENTRY)) ===
        :depends
    @test_broken :unstable in
        [mk.name for mk in ExperimentalAPI.reach(Chain.top_bad, ENTRY).reached]
end

@testset "an equally deep caller with nothing marked is reported clean" begin
    # Without this the previous test passes for a tool that always says `:depends`.
    @test_broken ExperimentalAPI.verdict(ExperimentalAPI.reach(Chain.top_good, ENTRY)) ===
        :clean
    @test_broken isempty(ExperimentalAPI.reach(Chain.top_good, ENTRY).reached)
end

@testset "a function passed as a value is still followed" begin
    # Measured: Julia specialises on `typeof(f)`, so this resolves. It is NOT a dynamic hole.
    @test_broken ExperimentalAPI.verdict(ExperimentalAPI.reach(Chain.top_arg, ENTRY)) ===
        :depends
end

@testset "@nospecialize does not hide the callee" begin
    @test_broken ExperimentalAPI.verdict(
        ExperimentalAPI.reach(Chain.top_nospec, Tuple{typeof(Chain.unstable),Float64})
    ) === :depends
end

# ── the honest non-answer ────────────────────────────────────────────────────────────────────

@testset "an abstract-typed callee field is :unknown, NOT :clean" begin
    # `Holder.f::Function` can hold `unstable`. Reporting `:clean` here would be a lie, and it is
    # exactly what the prototype did before the third value existed.
    @test_broken ExperimentalAPI.verdict(
        ExperimentalAPI.reach(Chain.top_field, Tuple{Chain.Holder,Float64})
    ) === :unknown
    @test_broken !isempty(
        ExperimentalAPI.reach(Chain.top_field, Tuple{Chain.Holder,Float64}).unresolved
    )
end

@testset "a run-time table lookup is :unknown, NOT :clean" begin
    @test_broken ExperimentalAPI.verdict(
        ExperimentalAPI.reach(Chain.top_table, Tuple{Int,Float64})
    ) === :unknown
    @test_broken !isempty(
        ExperimentalAPI.reach(Chain.top_table, Tuple{Int,Float64}).unresolved
    )
end

@testset "every unresolved site says where it is" begin
    # "cannot tell" is only actionable if the user can go and look.
    @test_broken all(
        u -> hasproperty(u, :file) && hasproperty(u, :line),
        ExperimentalAPI.reach(Chain.top_field, Tuple{Chain.Holder,Float64}).unresolved,
    )
end

@testset "a depth limit reports :unknown rather than :clean" begin
    # `deep_1` is five hops from the mark, so `maxdepth=2` must truncate. Asserting `:unknown`
    # rather than `!== :clean` is what separates "the limit produced the honest non-answer" from
    # "the limit was silently ignored and the mark was found anyway".
    @test_broken ExperimentalAPI.verdict(
        ExperimentalAPI.reach(Chain.deep_1, ENTRY; maxdepth=2)
    ) === :unknown
    # …and the same entry point WITHOUT the limit finds it, so the fixture can disagree.
    @test_broken ExperimentalAPI.verdict(ExperimentalAPI.reach(Chain.deep_1, ENTRY)) ===
        :depends
end

# ── termination ──────────────────────────────────────────────────────────────────────────────

@testset "self-recursion terminates and still finds the mark" begin
    @test_broken ExperimentalAPI.verdict(
        ExperimentalAPI.reach(Chain.top_recursive, Tuple{Int,Float64})
    ) === :depends
end

@testset "mutual recursion terminates" begin
    @test_broken ExperimentalAPI.verdict(
        ExperimentalAPI.reach(Chain.top_mutual_a, Tuple{Int,Float64})
    ) === :depends
end

# ── things that are not calls ────────────────────────────────────────────────────────────────

@testset "a marked const is seen where it is used" begin
    # A const is not a call site, so the call-graph walk cannot find it. Either the analysis
    # reads globals out of the IR as well, or this case has to be declared out of scope in the
    # documentation. What it must not do is report `:clean`.
    @test_broken ExperimentalAPI.verdict(
        ExperimentalAPI.reach(Chain.top_uses_const, ENTRY)
    ) !== :clean
end

@testset "a marked struct is seen at construction" begin
    @test_broken ExperimentalAPI.verdict(
        ExperimentalAPI.reach(Chain.top_constructs, ENTRY)
    ) === :depends
end

@testset "marking a module marks what it contains" begin
    # Or it does not, and that is stated. Either way it is a decision, not an omission.
    @test_broken hasproperty(ExperimentalAPI.reach(Chain.top_bad, ENTRY), :through_modules)
end

# ── across packages ──────────────────────────────────────────────────────────────────────────

@testset "a mark in a dependency propagates into the dependent" begin
    # The QAtlas case: a downstream analysis calls `fetch`, which is marked in QAtlas.
    # Requires the fixture package, so it is only pinned as an API shape here.
    @test_broken ExperimentalAPI.reach isa Function
end

# ── cost ─────────────────────────────────────────────────────────────────────────────────────

@testset "the macro emits nothing but the definition and one push" begin
    # The previous version of this test filtered `methods(_mark!)` for a name containing "reach".
    # `Method.name` is the GENERIC FUNCTION's name — always `:_mark!`, never derived from what the
    # body calls — so the filter was unconditionally empty and the assertion could not fail even
    # if `_mark!` called `reach` directly. Look at the expansion instead.
    emitted = string(@macroexpand @experimental "why" f(x) = x)
    @test occursin("_mark!", emitted)                       # the one load-time effect
    @test occursin("__EXPERIMENTAL_API_MARKS__", emitted)
    for forbidden in ("reach", "verdict", "record", "abstract_call_method", "code_typed")
        @testset "no $forbidden in the expansion" begin
            @test !occursin(forbidden, emitted)
        end
    end
end
