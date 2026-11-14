### Internal

- The Librarian continuity CLI test creates its `--publish-base-path`
  directory before the run. The blob store writes only under a base path that
  already exists, so the copy failed with `publication_error` and the test's
  last assertion found no blob (#50991, #PENDING).
