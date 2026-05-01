# test/stanzas — Per-test dune stanza files

Each `.inc` file in this directory contains exactly one `(test ...)` dune
stanza.  They are included from `test/dune` via sorted `(include …)` directives.

## Why this structure?

`test/dune` used to contain all test stanzas inline. Because every new test
appended a stanza to the same region of the file, parallel autocoder PRs all
conflicted with each other on that region (*conflict cascade*).

By giving each test its own file the only shared edit is one `(include …)` line
in `test/dune`, inserted at its alphabetical position.  Two PRs whose test names
sort to different positions never conflict; two PRs whose names happen to sort
adjacently produce a trivial union conflict (add both lines).

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

2. **Add one line** to `test/dune` in the sorted `(include …)` section at the
   bottom of the file:

   ```dune
   (include stanzas/test_your_name.inc)
   ```

   Insert it in alphabetical order relative to its neighbours.

## Tests in the large group stanzas

Groups 1–4 in `test/dune` are legacy `(tests …)` stanzas kept for historical
tests.  New tests should **not** be added to those groups; use the per-file
pattern above instead.
