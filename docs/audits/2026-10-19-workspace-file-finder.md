# Workspace file finder: ownership and verification

Issue #43859; Native Stack #43867 contains catalog #43865 and Code finder
#43866. The stack targets main. Source review, build, actual HTTP behavior,
visible TUI behavior, GitHub approval and merge are separate evidence stages.
This increment does not complete the wider rich music and nonmusic TUI goal.

## User flow and file identity

In Workspace Code, Ctrl-P reads the owning Git checkout's tracked and
nonignored untracked files, including files outside the current directory.
The catalog retains exact NUL-delimited Git path identities. Display escaping
does not replace the path used for a file request. The existing confidentiality
and symlink policy excludes paths that cannot safely be read.

Filtering and selecting an entry do not replace the original Code reading.
Navigation commits only after a successful owned file read; failure retains
the old file, cursor, directory and sibling readers. B returns through Code
jump history. Original scope, file request, workspace and read authority own
the intent. Queued input, paste and incomplete terminal sequences take priority
over applying a received navigation success. A ready result cannot borrow a
later reconfirmed read authority.

Catalog and selected file reads use the shared workspace JSON path, including
expected workspace fields, response admission and the ETag/304 cache boundary.
The global workspace receipt alone does not certify the selected repository or
Keeper scope. That scope must still resolve when the server reads the file.

## Scope loss found during independent review

Independent review of upper head
`aed210b3814a003d72155ed126c10dc40ee4e195` found a P2: after a successful catalog,
removing the repository registration/checkout or Keeper metadata/playground
could make the old file route read a same-named project file. Its global
workspace identity still matched, allowing that wrong content to navigate.

The response changes the file route to reject missing/unknown scoped source
variants before path resolution or file I/O. The shared workspace resolver,
tree fallback, LSP and existing file identity/symlink/read boundaries retain
their own behavior. The interface documents this distinction.

Four real HTTP/Router regression cases materialize different selected and
project contents at the same relative path. They first read the selected
catalog/file, then remove the repository registration, checkout directory,
Keeper metadata or playground. The scoped file/catalog must return 404 without
content even though an explicit project read remains 200. Existing finder
state checks cover preserving the original reading on an Error response.
These test source cases are not an executed-suite claim.

## Current verification scope

The whole two-layer stack was rebased with `gh stack rebase` onto main
`56734b064a1428009ea0ef21c501e1869f123081`, including the main compilation
repair. Parsing of 23 changed OCaml source/interface files passed at the
pre-response heads `fc58964bfa3cf4a90785e750dc022e62ad928a16` and
`aed210b3814a003d72155ed126c10dc40ee4e195`; this is syntax evidence only.
The scope-loss response also has focused parser/whitespace checks. No local
Dune build was run.

Older focused-test run 39191689297 and native-artifact run 39191695257 completed
successfully for `2804cd99aff243866874ac937fb4bfacbd2941c3`. They do not certify
the rebased or repaired heads. An artifact from that older source must not be
reported as the current executable.

CI Stack #43908 adds an explicit `workspace-files` native proof scenario. Its
guide describes building and packaging the matching server/TUI plus
`test_repo_git`, `test_tui_workspace_entries` and
`test_workspace_file_confidentiality` for a selected exact feature commit.
The workflow revision is separate from that source. A completed artifact and
an actual isolated same-source server/TUI round trip are still required;
request acceptance, source review and prepared fixtures do not prove them.
