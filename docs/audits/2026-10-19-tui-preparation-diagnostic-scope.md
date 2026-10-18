# Selected preparation diagnostic scope and rejection reasons

Source baseline: `168289b9a104ddf99ce99b9d2ad3ed05639960be` (#43828).
Scope: the existing selected durable preparation read and its diagnostic rows.
No TUI, trace reader, test or performance trial was executed.

| Boundary | Before | After in source |
| --- | --- | --- |
| Scanned malformed JSON and manifest rows | Same `Invalid_rows` constructor | Separate typed scan categories |
| Scan diagnostics and returned-row decoding | Shared unsupported/invalid categories | Three scan categories and two returned-row categories |
| Rejected report explanation | Decoder detail discarded by display | Actual reason retained in the detail row |
| Diagnostic text boundary | Direct text assembly | Existing single-line terminal-safe projection |
| Read ownership and reuse | Selected journal object/revision, request capability and workspace authority | Same ownership and reuse |
| Loading duration, input, paint and useful work | Unmeasured | Unmeasured |

The server scans a tail of one Keeper/trace manifest. Unsupported events have
a matching turn identity. Malformed JSON and manifest rows cannot pass that
identity filter, so their scan counts cannot be attributed to the selected turn.
Returned rows have a separate decode scope. These observations are not failed
Task counts and are not summed. Existing partial-scan and partial-return issues
remain distinct; no new request, timer, cache or retry policy is introduced.

The existing compound durable-report scenario now authors a damaged actual
manifest, reads it through the actual runtime-trace API and selected decoder,
and requires separate JSON/manifest scan issues while retaining the original
valid report. It also retains unsupported scan scope and returned-row
distinctions. This scenario is authored and unexecuted. No wording, layout,
row-order, snapshot, PTY or helper-mirror test is added.

Source inspection followed the real selection, asynchronous dispatch, result
application, cache and rendering callers. Workspace read suspension already
discards preparation state, so this layer does not claim a newly proven
infinite-loading defect or a measured responsiveness improvement. Parsing
checks are syntax evidence only; typing, behavior and visible results remain
unverified.
