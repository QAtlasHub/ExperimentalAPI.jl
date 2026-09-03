# The case matrix

These files are the specification. They are written before the implementation, so most of them
are `@test_broken`.

`@test_broken` was chosen deliberately over comments or a TODO list:

  * an expression that throws (because the function does not exist yet) registers as **Broken**,
    not as an error, so the suite stays green while the spec is incomplete;
  * an expression that starts **passing** registers as `Error: Unexpected Pass`, which fails the
    suite until someone promotes it to `@test`.

So the spec cannot silently rot in either direction: it neither blocks work that has not been
done, nor lets finished work go unnoticed.

Anything already implemented is a plain `@test`. The ratio of `@test` to `@test_broken` in this
directory is the honest progress measure.

| file | concern |
|---|---|
| `test_spec_declare.jl`    | what can carry a mark: function, method, struct, const, module, macro, extension |
| `test_spec_propagate.jl`  | a caller that never names a marked thing still depends on it |
| `test_spec_docstring.jl`  | a mark and a docstring are different accounts and must coexist |
| `test_spec_verify.jl`     | how well is a marked thing exercised by the tests |
| `test_spec_runtime.jl`    | what a real run touched, and what it costs when nobody asks |
