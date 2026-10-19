# Owned Code location reads

Issue #43919. Different-file LSP locations now use the same owned navigation
read as B returns. This increment continues the rich music and nonmusic TUI
work; it does not certify the whole TUI or implement a multiple-location picker.

Previously a location pushed history before starting an ordinary file load.
Failure could replace the source file with an error, while Code's directory
still named the source directory. A typed navigation action now distinguishes
returning through history from following an LSP location. Both retain the
source reading and history until an owned success, bind the destination scope
and confirmed workspace to HTTP, and yield to queued input before committing.
A return consumes the existing entry; a location records the source only when
it commits. Both update directory and clamp position against actual content.

B replaces a pending location with a return instead of accidentally sharing
that unrelated read. A new LSP question retires a pending navigation. Same-file
locations still move the cursor immediately; they retire an ordinary refresh
before restoring their location, reset horizontal offset and focus the file.
The source position, including its old pan/focus, remains available through B.

The existing workspace-entry suite adds production state scenarios for location
success followed by B, failed/cancelled/retried reads, EOF clamping, B replacing
an unrelated location, changed authority/view/scope and new questions. Existing
return scenarios use the shared navigation implementation. Checks concern
requests, saved state and decisions, with no screen wording/layout assertions.
Changed-source parsing and whitespace checks passed. No local Dune build was
run. New-source compilation, executed suites, independent review and actual
candidate UI remain separate verification stages.

Existing immediate same-file LSP response timing and multiple-result selection
remain outside this increment. File-finder and predecessor return artifacts
must not be cited as execution proof for this source.

Independent review of first lower `ba20f5ce3e8fddbe27808d208530228ae4e4fd22`
found a P1: broad field-prefix renaming had changed two unrelated `Micro_vm`
constructors to nonexistent `Micno_vm`. A separate response restores both
constructors and checks the complete seven-file delta for incidental renames.
This demonstrates why the prior parser result is not compilation evidence.
The repaired exact heads require renewed independent review and focused native
execution; earlier failure/PASS scopes are not silently reused.
