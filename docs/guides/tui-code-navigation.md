# Reading files in Code

Open Code from a Workspace repository or with `:`, `go Code`, Enter.
Ctrl-P lists readable tracked and nonignored files from the owning Git
checkout, including files outside the current directory. Type to filter and
press Enter to read a selection. Esc closes the finder. A failed selection
keeps the original file and directory.

`D` asks for a definition on the cursor line. `B` returns through the locations
left by definition jumps and successful finder selections. A location includes
the workspace scope, directory, file, cursor, vertical and horizontal offsets,
tree selection and focused pane. Shift-Left and Shift-Right pan file content.

With file content focused, `y` sends the whole currently readable file to the
terminal clipboard through OSC 52. It copies the original response bytes,
including indentation, tabs and line endings, rather than rebuilding text from
coloured or sanitized display rows. The status names the file and byte count;
terminal clipboard support is unconfirmed. An initial read, a failed or suspended
reading, or an unconfirmed workspace cannot supply copy bytes. A same-file
refresh keeps the previously observed source until the new bytes arrive. Close History,
Diff or Notes before copying the file. Mouse selection still copies displayed
rows. Code remains read-only; copying does not save or edit a workspace file.

Returning to another file keeps the current reading on screen until the
destination read succeeds. A missing file or unavailable workspace leaves the
return entry available; press B to retry. Repeating B during the read shares
that return. Another key, paste or mouse action cancels the pending return.
Received content waits for queued input before navigating. Leaving Code,
changing the source reading, or losing workspace authority retires old results.
Positions are clamped if the destination content became shorter or narrower.

The header shows return or location progress while the original navigation
still owns the current reading, including received content waiting behind
queued input. Cancelling or changing the source ends that activity. Pending
navigation retains the last settled question or failure observation; cancelling
does not replace it with a progress message. A failed read ends activity and
leaves its failure available while a later retry is pending.

Returning to an already readable current file or to a directory-only location
does not need a file request. Jump history belongs to this TUI session.

Following an LSP location in another file also keeps the source on screen
until reading succeeds. The containing directory changes with the destination,
and B records the source position only after that success. A failed or
cancelled location creates no extra history entry. B can replace an unfinished
location read with a return. A new language-server question cancels pending
navigation. A single location follows after queued input has priority and
focuses file content; B restores the source position and pan.

When a definition or references answer contains several locations, choose the
file and line in the result picker. Type to filter, move with Up/Down and press
Enter to open the selected result. Esc keeps the original reading. Results
outside the workspace show their address without requesting a workspace file.
An answer arriving after another key, paste or mouse action cannot take over
that newer input. A different source reading, question or workspace retires
the original choices. A cancelled question or closed picker stays cancelled
when the workspace reconnects.

A question shows progress only while its original request is still pending for
the current file and workspace. Receiving a reply or cancelling the question
ends that progress indication. Asking another question clears the previous
answer note only when the new request is accepted. Asking the same question
again also has its own pending request, including while the fetched source
retains an earlier answer. A previous success or failure does not mean the new
attempt has already finished.

Definition, hover and references requests keep the selected name's position
when Korean text, emoji or other Unicode characters precede it on the line.
Malformed source encoding is reported as a failed question.
# Workspace file revision and save API

The Code editor integration uses `GET /api/v1/workspace/file?path=...` with the
existing optional `keeper` or `repo_id` scope. Besides the original `content`,
the response includes an opaque SHA256 `revision` bound to those bytes, the
canonical selected workspace root and the resolved target. A same-named file
in another root cannot borrow the revision.

`POST /api/v1/workspace/file` replaces an existing file. Select at most one
nonempty `keeper` or `repo_id` query parameter and send exactly:

```json
{
  "path": "src/example.ml",
  "expected_revision": "<revision from the original read>",
  "content": "<edited source bytes>",
  "expected_workspace": {
    "base_path": "<confirmed server base path>",
    "masc_root": "<confirmed server MASC root>"
  }
}
```

The route requires Admin permission and the confirmed server workspace pair.
Unknown or unavailable scopes cannot fall back to a project write. Confidential,
traversal and symlink-escape paths use the same rejection policy as reads.
The new content must fit the existing configured file-read size limit.

The server compares the observed revision under its shared resolved-path lock.
This coordinates server writers; it is optimistic concurrency, not a filesystem
transaction against non-cooperating external writers. A revision conflict is
HTTP409 (`workspace_file_changed`) and leaves the current file intact. The
atomic replacement preserves exact bytes and ordinary permission bits, including
executable bits, and requires payload and parent-directory fsync. An unchanged
candidate needs no replacement; an explicitly empty candidate remains valid.

On success, the response returns the revision of the committed bytes. A failure
after rename uses `workspace_file_save_uncertain`: retain the draft and reread
before considering another save. A missing response likewise does not establish
whether a write happened. This API does not by itself add a Code edit key,
retained drafts or a conflict comparison view; those remain separate TUI work.
