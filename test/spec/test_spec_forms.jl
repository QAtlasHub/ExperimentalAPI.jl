# The definition forms the macro has not been shown to handle.
#
# `test_spec_declare.jl` covers the forms that work today. These are the ones a real package hits
# on its second afternoon: keyword arguments, parametric signatures, callable structs,
# constructors, operators, stacked macros. Each one either works, or the refusal has to name the
# alternative — silently marking the wrong symbol is the outcome this file exists to prevent.

using ExperimentalAPI: ExperimentalAPI, @experimental, experimental, isexperimental, mark
using Test

module FormsSpec

using ExperimentalAPI

public kw_fn, where_fn, vararg_fn, ret_typed, Callable, Ctor, INTERP

@experimental "keyword arguments" kw_fn(x; scale=1.0, kwargs...) = x * scale
@experimental "parametric" where_fn(x::T, y::T) where {T<:Real} = x + y
@experimental "varargs" vararg_fn(x, rest...) = x
@experimental "return type annotation" ret_typed(x)::Float64 = x

struct Callable
    k::Float64
end
struct Ctor
    v::Int
end

# an interpolated reason
const WHY = "tolerance chosen by hand"
@experimental "$(WHY); see the sweep in issue 12" INTERP = 1e-8

end # module FormsSpec

@testset "forms that already work" begin
    got = Dict(mk.name => mk for mk in experimental(FormsSpec))
    for n in (:kw_fn, :where_fn, :vararg_fn, :ret_typed, :INTERP)
        @testset "$n" begin
            @test haskey(got, n)
            @test !isempty(strip(got[n].reason))
        end
    end
    @test FormsSpec.kw_fn(2.0; scale=3.0) == 6.0
    @test FormsSpec.where_fn(1, 2) == 3
end

@testset "an interpolated reason is evaluated, not stored as source" begin
    @test occursin("tolerance chosen by hand", mark(FormsSpec, :INTERP).reason)
end

# ── forms that are not covered ───────────────────────────────────────────────────────────────

@testset "a callable struct is marked on the WRONG symbol today" begin
    # Measured 2026-09-03. `(c::C)(x) = c.k * x` has no function name, and `_signame` walks the
    # `::` and returns the ARGUMENT name. The mark lands on `:c`, a local that is not a binding
    # anywhere, so it is silently meaningless — the exact failure this file exists to catch.
    @eval module CallableMarked
    using ExperimentalAPI
    struct C
        k::Float64
    end
    @experimental "scaling rule provisional" (c::C)(x) = c.k * x
    end
    @test :c in [mk.name for mk in experimental(CallableMarked)]     # today, and wrong
    @test !isdefined(CallableMarked, :c)                             # marks a non-binding
end

@testset "and the audit compounds it: C is reported as UNDECLARED" begin
    # The second wrong signal, and the worse one. Because the mark landed on `:c`, the audit sees
    # a declaration for a name that does not exist AND a public name with no declaration — so it
    # tells the author to go declare `C`, which is the very thing the line above declares. A
    # reader who follows that advice writes the mark a second time and still gets both signals.
    #
    # Recorded here so that whoever fixes `_signame` knows BOTH halves have to move together:
    # correcting the recorded symbol without re-running the audit leaves `dangling` empty but
    # `unaccounted` unchanged if the audit keys off something else.
    @eval module CallablePublic
    using ExperimentalAPI
    public C
    struct C
        k::Float64
    end
    @experimental "scaling rule provisional" (c::C)(x) = c.k * x
    end
    a = ExperimentalAPI.audit(Main.CallablePublic)
    @test :c in a.dangling          # declared, but no such binding
    @test :C in a.unaccounted       # public, and — per the audit — never declared
    @test Main.CallablePublic.C(2.0)(3.0) == 6.0   # the definition itself is fine; the mark is not
end

@testset "a callable struct marks the type, or refuses" begin
    # Either answer is defensible. Marking the argument name is not.
    @test_broken :C in [mk.name for mk in experimental(Main.CallableMarked)]
end

@testset "…and fixing that clears BOTH signals" begin
    # The paired assertion for the testset above. `_signame` returning `:C` is necessary but not
    # sufficient: the audit is what the author actually reads, and it has to go quiet too.
    a = ExperimentalAPI.audit(Main.CallablePublic)
    @test_broken isempty(a.dangling) && :C ∉ a.unaccounted
end

@testset "a constructor method is marked on the type" begin
    # This one already resolves correctly: the mark lands on `:T`.
    @eval module CtorMarked
    using ExperimentalAPI
    struct T
        v::Int
    end
    @experimental "validation not implemented" T(s::AbstractString) = T(parse(Int, s))
    end
    got = Set(mk.name for mk in experimental(Main.CtorMarked))
    @test :T in got
    # …and the ARGUMENT name is not also marked. The sibling testset above found exactly that
    # defect for `(c::C)(x)`; an over-inclusive walk would reintroduce it here unnoticed.
    @test :s ∉ got
end

@testset "an inner constructor inside a marked struct is not separately marked" begin
    # Marking the struct should not silently also claim its inner constructors are unfinished,
    # nor silently exclude them. Whichever it is has to be stated.
    @test_broken hasproperty(mark(FormsSpec, :Callable), :includes_constructors)
end

@testset "an operator method can be marked" begin
    # `@eval module … end` evaluates to a Module, never a Bool, so wrapping it directly in
    # `@test_broken` reports "Expression evaluated to non-Boolean" on success rather than the
    # "Unexpected Pass" this directory relies on. Each of these now ends in a Bool AND checks
    # WHAT was marked — accepting the syntax while recording the wrong symbol is the defect this
    # file already caught once, for `(c::C)(x)`.
    @test_broken begin
        @eval module OpMarked
        using ExperimentalAPI
        struct V
            x::Float64
        end
        @experimental "no identity element yet" Base.:+(a::V, b::V) = V(a.x + b.x)
        end
        :+ in [mk.name for mk in experimental(Main.OpMarked)]
    end
end

@testset "a generated function can be marked" begin
    @test_broken begin
        @eval module GenMarked
        using ExperimentalAPI
        @experimental "generator is a prototype" @generated g(x) = :(x)
        end
        :g in [mk.name for mk in experimental(Main.GenMarked)]
    end
end

@testset "Base.@kwdef stacks with the mark" begin
    # `@kwdef` expands to a block carrying `Expr(:meta, :doc)`. Two macros that both wrap a
    # definition must compose in at least one order, and the order that works must be documented.
    @test_broken begin
        @eval module KwdefMarked
        using ExperimentalAPI
        @experimental "defaults are guesses" Base.@kwdef struct S
            a::Int = 1
        end
        end
        :S in [mk.name for mk in experimental(Main.KwdefMarked)]
    end
end

@testset "@inline and the mark compose in both orders" begin
    @test_broken begin
        @eval module InlineMarked
        using ExperimentalAPI
        @experimental "kernel unverified" @inline f(x) = x
        @inline @experimental "kernel unverified" g(x) = x
        end
        Set([mk.name for mk in experimental(Main.InlineMarked)]) == Set([:f, :g])
    end
end

@testset "a definition produced by @eval can be marked by name" begin
    # Metaprogrammed definitions cannot be attached to; the name-list form is the answer and it
    # has to be reachable.
    @test_broken begin
        @eval module EvalMarked
        using ExperimentalAPI
        for n in (:a, :b)
            @eval $n(x) = x
        end
        @experimental "generated in a loop" a b
        end
        Set([mk.name for mk in experimental(Main.EvalMarked)]) == Set([:a, :b])
    end
end

@testset "a mark inside a function body is refused" begin
    # It IS refused by Julia rather than by this package: `const` in local scope is a LOWERING
    # error, which fires before any code this macro emits can run, so there is no point at which
    # a check of ours could intercept it. The one lever left is where the error points, and it
    # used to point at `ExperimentalAPI/src/mark.jl` — reading as a bug in the package rather
    # than a misuse of it, whose natural next step is to file an issue here. The expansion now
    # carries the CALLER's `LineNumberNode`, so the message names the line the author wrote.
    #
    # The misuse has to arrive from a FILE. Measured 2026-09-03: the same misuse written through
    # `@eval` or `Core.eval` — which is how every other refusal in this file is probed — produces
    # `"syntax: unsupported `const` declaration on local variable"` with NO location at all, so a
    # location assertion made that way is vacuous and would pass just as well against the old
    # expansion. The source is built line by line so the formatter cannot shift line 4.
    dir = mktempdir()
    path = joinpath(dir, "caller_side.jl")
    write(
        path,
        join(
            [
                "module CallerSide",
                "using ExperimentalAPI",
                "function outer()",
                "    @experimental \"why\" inner(x) = x",
                "    return inner",
                "end",
                "end",
            ],
            "\n",
        ),
    )
    e = try
        include(path)
        nothing
    catch err
        err isa LoadError ? err.error : err
    end
    @test e isa ErrorException
    msg = sprint(showerror, e)
    @test occursin("unsupported `const` declaration", msg)
    # The half that is fixed: the blame lands on the line the author actually wrote…
    @test occursin("caller_side.jl:4", msg)
    # …and nowhere in this package. Checked against the FILE NAME: the repository path contains
    # the string "ExperimentalAPI", so a negative assertion on that word passes by accident.
    @test !occursin("mark.jl", msg)
end

@testset "the refusal names @experimental rather than leaking the emitted const" begin
    # The half that is NOT fixed. The message now points at the right line, but it still talks
    # about a `const` the author never wrote; it should say that a mark belongs at module top
    # level, next to `export` and `public`. Whether that is reachable at all is open — the error
    # comes from lowering, so this may only be answerable by not emitting `const`, and the
    # alternative (`global`) fails SILENTLY in local scope, which is strictly worse.
    e = try
        @eval module ClosureMarked2
        using ExperimentalAPI
        function outer()
            @experimental "why" inner(x) = x
            return inner
        end
        end
        nothing
    catch err
        err
    end
    @test_broken occursin("@experimental", sprint(showerror, e))
end

# ── metadata ─────────────────────────────────────────────────────────────────────────────────

@testset "since must be a version, and the refusal must say so" begin
    # It IS refused today, but by accident: `Mark.since::Union{VersionNumber,Nothing}` cannot
    # convert a String, so the error is
    #   MethodError: Cannot `convert` an object of type String to an object of type VersionNumber
    # which names neither `since` nor `@experimental`. A deliberate check would keep throwing, so
    # asserting "it throws" could never signal that the fix had landed — assert the DIAGNOSTIC.
    e = try
        @eval module BadSince
        using ExperimentalAPI
        @experimental("why", since = "0.4.0", f(x) = x)
        end
        nothing
    catch err
        err isa LoadError ? err.error : err
    end
    @test e isa MethodError                                   # today, and accidental
    @test_broken occursin("since", sprint(showerror, e))
end

@testset "an unknown keyword is refused rather than ignored" begin
    # `@experimental("why", trackign = "u", f(x) = x)` — a typo in a keyword name must not
    # silently become part of the subject.
    @test_throws LoadError @eval module BadKw
    using ExperimentalAPI
    @experimental("why", trackign = "u", f(x) = x)
    end
end

@testset "tracking is carried through to every report" begin
    # The field that turns a warning into something a reader can act on. It is stored today; it
    # has to survive into the audit and the record as well.
    @test_broken ExperimentalAPI.audit(FormsSpec).tracking isa AbstractDict
end

# Evaluate an expression in a fresh module and hand back the exception it raised, unwrapped.
# The `Module(...)` + `Core.eval` + `LoadError`-stripping plumbing was written out five times
# before this; it carries none of the claim, so it is a helper rather than part of each test.
function probe(ex)
    m = Module()
    Core.eval(m, :(using ExperimentalAPI))
    try
        Core.eval(m, ex)
        return nothing
    catch err
        return err isa LoadError ? err.error : err
    end
end

# ── writing it lazily ────────────────────────────────────────────────────────────────────────
#
# The reason is the payload: why a name is not settled is knowledge only the author has. So the
# interesting question is not "does the good form work" but "what happens when someone writes it
# without one". Measured 2026-09-03: every lazy form IS refused — but two of them are refused by
# accident, and two more are refused with a message pointing the wrong way.

@testset "a bare @experimental is refused, and says which of the two is missing" begin
    # `@test_throws Exception` for all six would be satisfied by one generic
    # `ArgumentError("@experimental: invalid usage")`. The section exists to check that the
    # message points the right way, so each case pins the phrase it should carry.
    for (ex, needle) in (
        (:(@experimental), "needs a reason"),
        (:(@experimental foo), "the reason comes first"),
        (:(@experimental function f(x)
            x
        end), "the reason comes first"),
        (:(@experimental struct S
            v::Int
        end), "the reason comes first"),
        (:(@experimental f(x) = x), "nothing to mark"),
        (:(@experimental const C = 1), "nothing to mark"),
    )
        @testset "$(first(string(ex), 36))" begin
            e = probe(ex)
            @test e isa ArgumentError
            @test occursin(needle, sprint(showerror, e))
        end
    end
end

@testset "an empty reason is refused, and the message says why" begin
    for r in ("", "   ", "\n\t ")
        @testset "reason=$(repr(r))" begin
            m = Module(:EmptyProbe)
            Core.eval(m, :(using ExperimentalAPI))
            e = try
                Core.eval(m, :(@experimental $r f(x) = x))
                nothing
            catch err
                err isa LoadError ? err.error : err
            end
            @test e isa ArgumentError
            @test occursin("reason", sprint(showerror, e))
        end
    end
end

@testset "a non-string reason is refused by accident, not by a check" begin
    # `@experimental :sym f(x) = x` and `@experimental 42 f(x) = x` both die inside `_reason`
    # with `MethodError: no method matching strip(::Symbol)` / `strip(::Int64)`. Refused, yes —
    # but by `strip` failing, with a message that names neither `@experimental` nor `reason`.
    # Same shape as the `since = "0.4.0"` case above.
    for r in (:(:sym), 42)
        @testset "reason=$(repr(r))" begin
            e = probe(:(@experimental $r f(x) = x))
            @test e isa MethodError                       # today, and accidental
            @test_broken occursin("reason", sprint(showerror, e))
        end
    end
end

@testset "forgetting the reason is diagnosed as a missing reason" begin
    # `@experimental f(x) = x` is refused with "nothing to mark — give a definition or a name".
    # The author DID give a definition; what is missing is the reason. The message points at the
    # wrong end of the call, which is how someone ends up deleting a correct definition.
    e = probe(:(@experimental f(x) = x))
    @test e isa ArgumentError
    @test occursin("nothing to mark", sprint(showerror, e))        # today, and misleading
    @test_broken occursin("reason", sprint(showerror, e))
end

@testset "nothing is marked when the macro refuses" begin
    # A refusal that still recorded a mark would be worse than either outcome. Checks the module
    # is left clean, not just that an exception came out.
    m = Module(:RefusedProbe)
    Core.eval(m, :(using ExperimentalAPI))
    try
        Core.eval(m, :(@experimental f(x) = x))
    catch
    end
    @test isempty(experimental(m))
    @test !isdefined(m, :f)
end

# ── same name, two places ────────────────────────────────────────────────────────────────────

@testset "the same name marked in two modules stays separate" begin
    @eval module A1
    using ExperimentalAPI
    public f
    @experimental "reason A" f(x) = x
    end
    @eval module A2
    using ExperimentalAPI
    public f
    @experimental "reason B" f(x) = x
    end
    @test mark(A1, :f).reason == "reason A"
    @test mark(A2, :f).reason == "reason B"
end

@testset "re-marking with a different reason replaces rather than accumulates" begin
    @eval module A3
    using ExperimentalAPI
    public f
    f(x) = x
    @experimental "first" f
    @experimental "second" f
    end
    @test count(mk -> mk.name === :f, experimental(A3)) == 1
    @test mark(A3, :f).reason == "second"
end

@testset "the replacement is reported rather than silent" begin
    # Two different reasons for one name usually means two authors disagreed, or a stale mark was
    # left behind. Last-write-wins is a decision, and it should be visible.
    @test_broken ExperimentalAPI.superseded_marks isa Function
end
