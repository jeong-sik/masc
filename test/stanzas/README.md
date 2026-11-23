# test/stanzas — Per-test dune stanza files

Most `.inc` files in this directory contain one `(test ...)` dune stanza.
Some hold an `(executable ...)`, `(rule ...)` or `(alias ...)` stanza as well
or instead.  They are included from `test/dune` via `(include …)` directives.

## Why this structure?

`test/dune` used to contain all test stanzas inline. Because every new test
appended a stanza to the same region of the file, parallel autocoder PRs all
conflicted with each other on that region (*conflict runtime*).

By giving each test its own file the only shared edit is one `(include …)` line
in `test/dune`.  Two PRs that add their lines at different places never
conflict; two PRs that add them next to each other produce a trivial union
conflict (add both lines).

## How to add a new test

1. **Create** `test/stanzas/test_your_name.inc` with the dune stanza:

   ```dune
   (test
    (name test_your_name)
    (modules test_your_name)
    (libraries masc_test_deps))
   ```

   Use different `(libraries …)` if needed.  For tests that require eio add
   `eio eio_main`; for tests with a special action block add `(action …)`.

2. **Add one line** to `test/dune`:

   ```dune
   (include stanzas/test_your_name.inc)
   ```

## Tests in the large group stanzas

The four `(tests …)` stanzas in `test/dune` hold older tests.  New tests should
**not** be added to those groups; use the per-file pattern above instead.
