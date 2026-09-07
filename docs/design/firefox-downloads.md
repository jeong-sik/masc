# Firefox downloads

Automation sessions request WebDriver BiDi during Classic session creation.
Before the session accepts actions, the native OCaml client connects, subscribes
to download and context events, and configures a private destination directory.
Setup failure deletes the known remote session; it does not silently open a
browser without download observation.

Use `BrowserAct` to click a download link, then
`BrowserRead {"lane":"automation","tabId":73,"mode":"downloads"}`. The read
returns a snapshot, not a blocking wait. Each record has a `downloadId`, source
context and URL, suggested filename, and one of `pending`, `completed`,
`canceled`, or `interrupted`. The enclosing `sessionId` identifies the Firefox
session. Context ancestry associates iframe downloads with the observed tab.
Download UUIDs distinguish concurrent transfers; navigation IDs can be null.

Only `browsingContext.downloadEnd` proves browser completion. A completed event
with no filepath returns `file=path_unavailable`; a reported path that cannot be
verified returns `file=unavailable`. No filename, size-stability or `.part`
heuristic changes the download state. A disconnected stream interrupts pending
records and refuses further actions until the session is closed and reopened.

Verified regular files inside the session staging directory are published into
the existing durable tool blob store. The `artifact.arguments` object contains
the exact `sha256` accepted by `keeper_artifact_read`; invoke that reader and
follow `next_offset` until `eof=true`. Its default page size is 16,384 source
bytes; inspect `encoding` because binary pages use base64. This reader works
across Keeper runtimes. The verified host `path` is diagnostic metadata, not a
promise that a sandbox's ordinary `Read` can open that host path. Publication
failure appears as `artifactError`, while the browser's completion evidence
remains intact. Successfully published artifacts are cached for the session.

One shared Firefox session has one fixed staging directory under the resolved
runtime `.masc/browser-downloads` root. A Keeper never supplies a destination
directory. Closing a tab preserves its observed-ID download lookup while the
session survives. Closing the session (including its final tab) releases the
WebSocket and clears session-local records. Read and retain artifact references
before closing the session. Staged files and published blobs are not deleted by
session closure; blob retention follows the existing store policy.

Firefox added `downloadEnd` in [145][145] and `setDownloadBehavior` in [149][149].
The integration requires those APIs and the current `download` UUID event
contract. Stock Firefox 155.0.1 with geckodriver 0.37.1 was measured locally;
older versions have not been exercised by this implementation. Missing APIs or
malformed event contracts produce explicit setup/interruption errors.

`test_browser_downloads` covers UUID correlation, descendant contexts,
interruption, unavailable paths, confined-file checks, and real durable
store-to-paged-reader binary recovery. `test_browser_webdriver` checks failed and
canceled setup rollback. The compiled Firefox proof additionally downloads
actual duplicate filenames, an HTML download attribute, and an iframe link;
it recovers their bytes through the production reader. Source-interpreter mode
exercises the same native WebSocket and driver code but substitutes the artifact
publisher with a byte-count probe; it does not claim the linked reader ran.

[145]: https://developer.mozilla.org/en-US/docs/Mozilla/Firefox/Releases/145
[149]: https://developer.mozilla.org/en-US/docs/Mozilla/Firefox/Releases/149
