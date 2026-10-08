# Keeper media fallback (H5): audio and document meaning across provider failover

Status: design record for task-2187. Draft; no behavior change in this commit.
Source audited: main 5d0f1558. Acceptance: board p-963d6bf387f1bbd6e217054ad293c155 (H5-S1..S3).

## Gap (verified by reading source and running the existing harness)

When a candidate runtime cannot take `Audio` or `Document` blocks,
`Keeper_turn_driver.project_input_for_attempt` runs
`Runtime_agent.strip_unsupported_modality_*`. The block is dropped and the turn
carries only `media_degrade_note` ("N media inputs were omitted"). Images are
different: `Keeper_vision_ingest.fallback_projector` turns an unsupported image
into a durable placeholder plus a reading. Audio and document have no such
projection, so a fact present only in the audio or document is lost to the text
fallback, although the canonical block is kept in the caller's history.

`test_h5_media_failover_continuity` (merged, #41770) proves the boundaries
(bytes round-trip, fail-closed sources, checkpoint round-trip, drop is
announced). It does not prove that the fact survives. This change adds that.

## Design

### 1. Where the result lives
A per-keeper media-reading record, written next to the existing vision artifact
store (`Multimodal.Vision_artifact_store`) so retention, per-keeper isolation and
checkpoint migration reuse one mechanism. The record is a small JSON document:

    { handle; kind = audio | document; media_type; source_sha256;
      reader = { id; version }; status = read | unavailable;
      text (when read); reason (when unavailable); read_at }

The original `Audio`/`Document` block is never rewritten in canonical history.
Only the per-attempt projection replaces it with a text block that carries the
handle, media type, source_sha256 and the reading (or the unavailable reason).

### 2. Identity and source revision
The key is `(kind, source_sha256, media_type)` of the inline base64 payload.
Inline content is content-addressed, so a changed attachment is a new key and a
stale reading can never answer for it; this is the source revision binding.
`Url` and `File_id` sources are references, not payloads: they stay unread
reference text (same rule the image projector already applies) and are reported
as `unavailable: reference_not_fetched`. They are not fetched.
The reader `{id; version}` is part of the record. A record from a different
reader version is not reused as `read`.

### 3. Reuse conditions (next turn and restart)
A projection looks the key up before calling any reader.
- `read` with the same reader version: reused, no reader call.
- `unavailable`: not reused as success. It is retried, and its reason is shown.
- absent: read once per lane walk (cached for later candidates of that walk,
  like the image projector), then stored.
Because the record is on disk, a restart sees the same record. Checkpoint
messages are projected with the same rule at attempt time, which is how a later
turn on a text-only runtime still answers from the reading.

### 4. Readers (existing contracts only)
- Audio: `Voice_bridge.transcribe_audio ~audio_file ?language_code ()` returns
  `(Yojson.Safe.t, string) result` through the configured STT endpoint chain.
  It needs a file path, so the decoded bytes go to a temporary file inside the
  keeper sandbox that is removed after the call. When voice/STT is not
  configured it returns `Error "no enabled STT endpoints configured"`; that
  becomes `unavailable`, never an invented transcript.
- Document: the only extraction code found is `Verification_pdf_inspection`
  (Poppler, PDF only, owned by the verification/review path and bounded by that
  path's review slots). It is not wired for the keeper turn path. First step
  reuses its text extraction for `application/pdf` only if its budget and
  slot behavior are safe off the review path; if not, the document reader is
  reported as an explicit gap and S2 stays `not_measured` rather than adding a
  second extractor here. Non-PDF documents are `unavailable: no_reader`.

### 5. Failure behavior (H5-S3)
Any reader error, timeout, missing dependency, empty output or oversize payload
yields `status = unavailable` with a closed reason. The projection says the
content could not be read and that the original is kept; it contains no text
derived from the media. The turn proceeds as text, as it does today.

### 6. Not in scope
UI upload, external channel file collection, fetching `Url`/`File_id`, a
generic document extractor, and any change to canonical history.

## Verification plan
Fixtures in the existing harness, each first observed red on the current main:
- S1: audio-only fact; head runtime forced to fail; text fallback answers the
  fact and cites the handle; second turn and a simulated restart (reload from
  disk) give the same reading with zero extra reader calls.
- S2: same for a document-only fact.
- S3: reader returns an error; projection states unavailable, names the kept
  original, contains no media-derived text; a later success for the same key
  replaces the unavailable record.
Reader calls are injected at the module boundary (as
`Keeper_vision_ingest.For_testing.fallback_projector` does for vision) so the
red/green result is deterministic and does not depend on an STT service.
A real-endpoint run, if an STT endpoint is available in the lane, is recorded
separately and never substituted for the fixtures.

## Implementation notes (first wiring)
- `Keeper_media_reading` (new) owns identity, store and projection;
  `Keeper_turn_driver.project_input_for_attempt` calls it for the goal, the
  pre-turn history and the resumed checkpoint before the generic strip, and
  gains an optional `?project_media` seam for tests. The manifest row keeps the
  `media_degraded_to_text` action and adds `media_projected_*` fields.
- Audio uses the configured STT chain; **no document reader is wired**, so a
  document is projected as `unavailable: no_document_reader`. H5-S2 therefore
  only proves the projection and reuse with an injected reader. It does not
  prove a real PDF extraction. That stays `not_measured` until a reader is
  chosen (open question: reuse the Poppler path from
  `Verification_pdf_inspection` after checking its slot/budget behavior off the
  review path).
- A reading is stored without a byte cap, following the rule against numeric
  size caps. A very long transcript therefore reaches the fallback input
  unabridged; if that proves a problem it belongs to the token-budget
  mechanism, not to a number here.
- Reuse is keyed by payload sha256, media type and reader version; the first
  version is `1`.

## Document reader: what `Verification_pdf_inspection` is, and a minimal share
Read at main 5d0f1558 (lib/verification_pdf_inspection.ml, lib/pdf_runtime_dependencies.ml,
callers: lib/verification_media_inspection.ml, lib/verification_authority_tools.ml).
Nothing below is adopted yet; it is the proposal the leader asked for
(c-9ac508438a0b501a4495a01acaf7923e). No code in this commit uses it.

### Facts from the source
1. `inspect` is one function that does three things in one pass: runs
   `pdftotext -bbox-layout` into an XHTML file, parses it into per-page text
   (`parsed_pages`), then renders **every** page to PNG with `pdftoppm` and
   returns text and images together. Text-only use is not possible today; a
   caller always pays for the render.
2. Its failure set is review-shaped. `Image_policy_rejected`,
   `Rendered_bytes_exceeded` (24 MiB of PNG across pages) and `Too_many_pages`
   (64) are refusals of the image half; a PDF whose text is readable but whose
   page render is over the image policy still comes back `Error`.
3. The "review slot" is **not** in this module. The code holds no semaphore and
   takes no approval. The slot limit (four global) appears only in comments
   (lines ~97 and ~134) and is held by the review caller around
   `inspect`; I did not find the semaphore itself in the files read. What the
   module does own is an inspection-wide 60 s wall clock
   (`Monotonic_deadline`) shared by all Poppler calls, a 64 MiB source cap, a
   2 MiB extracted-text cap, a scrubbed environment (`Env_keeper_scrub`), and a
   private 0o700 directory under
   `Keeper_execute_output_files.capture_directory ~base_path`, removed on
   release.
4. Dependencies: `pdftotext` and `pdftoppm` must be installed
   (`Pdf_runtime_dependencies.missing`). The module's own doc says bundled
   release archives do not provide Poppler. A missing tool is an explicit
   `Dependency_unavailable`, so the keeper path can show it as unavailable.

### Minimal share (proposal)
Factor the text half out as `Verification_pdf_inspection.extract_text ?max_extracted_bytes
~base_path ~bytes ()` returning page texts only. It would keep the same
safety: source cap, owned private directory, scrubbed env, one shared
deadline, extracted-text cap, and the same dependency check. `inspect` would
call it first and then render, so the review path's behavior is unchanged. No
rendering, no image policy, no review slot, no approval is reachable from
`extract_text`.

### Who owns what on the keeper turn
- The call site is `Keeper_media_reading.production_reader` (Document,
  `application/pdf` only; other document types stay
  `unavailable: no_document_reader`).
- The keeper turn does not take a review slot and does not use the review
  approval. It owns: calling, mapping every error to a closed reason
  (`dependency_unavailable`, `budget_spent`, `payload_too_large`,
  `extraction_failed`), and storing nothing when it fails.
- Time budget: the 60 s wall clock exists to protect review slots; a fallback
  attempt that blocks a turn for up to a minute is a different trade. The
  deadline should be a parameter of `extract_text`. Its value for the turn path
  is an open decision for the leader/operator; this record does not pick one.
- Cancellation: `Process_eio` runs the child under Eio, so a cancelled turn
  cancels the extraction; the owned directory is removed on release.

### Not done / not claimed
No `extract_text`, no wiring, and no PDF run yet. H5-S2 stays `not_measured`
for real extraction. Until this proposal is accepted, document projection in
production stays `unavailable: no_document_reader`.

## Time budget for the keeper-turn reader (answer to c-1e3cdd3ef158bda3432ea0958e5aa616)
Read at main 5d0f1558. Coordinates are lib/keeper/ unless noted.

### What exists
- `provider_call_deadline_sec` is resolved in keeper_runtime_resolved.ml:129-131
  (operator value from `turn.provider_call_deadline_sec`, else the failsafe
  floor), read by `Keeper_runtime_resolved.provider_call_deadline_sec ()`
  (:230-231) and injected into the provider context at
  keeper_turn_driver.ml:3212-3213. In keeper_turn_driver_try_provider.ml
  (:434, :2068-2070, :2155) it is the **no-progress ceiling on one provider
  attempt**, measured against the keeper's live progress signal
  (`provider_progress_probe`, keeper_turn_driver.ml:~3214-3260), armed per
  attempt inside the provider run (`run_started_at`, :2073).
- `stream_idle_timeout_sec`, `first_event_timeout_sec` and the body timeout
  govern the provider stream, not anything before it.
- `Monotonic_deadline` exists (used by `Verification_pdf_inspection`), with
  `after ~seconds` and `remaining_seconds`.

### What does not exist
- I found **no whole-turn deadline with a remaining time** and **no reserved
  budget for fallback provider calls** in lib/ (searched turn_deadline,
  turn_budget, walk_deadline, lane_deadline, attempt_deadline,
  remaining_budget, fallback_reserv; the only hits were unrelated).
  `turn_budget` in keeper_agent_run.ml:2281 is a context-token budget.
- `project_input_for_attempt` (keeper_turn_driver.ml:1347, called at ~:2342)
  runs inside the candidate walk **before** the attempt's provider run, so the
  per-attempt no-progress watchdog is not yet armed while it executes. A reader
  invoked there is bounded only by what the reader enforces itself.
- `Voice_bridge.transcribe_audio` takes no deadline argument; it walks the STT
  endpoint chain with each endpoint's own transport behavior. The audio reader
  therefore has the same exposure today.

### Consequence and proposal
There is no "remaining turn time" to hand to `extract_text`, and no reservation
to subtract. Per the leader's rule (no new fixed seconds; unavailable/incomplete
when no budget can be passed):
1. `extract_text` takes a caller-supplied `Monotonic_deadline.t` and returns
   `Poppler_budget_spent`-style failure when it is spent. It adds no constant.
   `inspect` keeps its existing 60 s deadline, error set and directory cleanup
   unchanged (it constructs its own deadline exactly as today).
2. The keeper turn builds that deadline from an **existing operator-declared
   value**: `Keeper_runtime_resolved.provider_call_deadline_sec ()`. This is a
   semantic reuse (a no-progress ceiling used as a wall-clock cap for the one
   pre-provider step), not a remaining-turn computation. If the leader does not
   accept that reuse, the alternative is the stated rule: pass no budget and
   report the document as `unavailable: no_budget`, which keeps H5-S2 not
   measured for real PDFs.
3. A true remaining-turn budget would be a new policy (a turn start time held in
   the walk, a reservation for the fallback provider call). That is a separate
   decision and is not started here.
4. The audio reader's missing deadline is recorded as a gap, not changed here.

### For the independent review requested
That `inspect` still gets the same 60 s deadline, the same error variants
(`Poppler_budget_spent`, `Too_many_pages`, `Rendered_bytes_exceeded`,
`Image_policy_rejected`, `Payload_budget_exceeded`, `Storage_failed`) and the
same `Fs_compat.remove_tree` on release after `extract_text` is factored out.

## Implementation of the accepted budget (leader c-e3614999a360e1d946bad3981df63479)
- Meaning of the value: `turn.provider_call_deadline_sec` keeps its original
  meaning, the no-progress ceiling of one provider attempt. For the H5 reader
  step it is **also** used as a wall-clock cap for the pre-provider projection.
  It is not a turn-wide deadline and reserves nothing for the fallback provider
  call. No new constant was added.
- One deadline per projection: `project_input_for_attempt` builds a single
  `Monotonic_deadline.t` and passes it to every attachment of that projection
  (goal, history, checkpoint). Attachments do not restart the clock; a
  reading that must still be read after the deadline is spent is not started and
  is marked `unavailable: budget_spent` (original kept). A stored reading needs
  no budget.
- `Verification_pdf_inspection.extract_text ~deadline ~budget_sec` is the text
  half of `inspect`; `inspect` now reuses the same internals (`with_source`,
  `make_runner`) and still builds its own 60 s deadline.
- Open gap, not closed: `Voice_bridge.transcribe_audio` has no deadline
  parameter. The STT chain runs each endpoint under its own transport timeout
  (voice_bridge_transport.ml, `Env_config_runtime.Voice.http_request_timeout_sec`,
  curl `--max-time 30`) and can spend several. The audio reader refuses to
  start after the deadline but cannot stop a running STT call at it. H5-S1's
  time bound is therefore not measured.

## Audio STT now takes the shared deadline (leader c-ede6adaa4d64e397022716bb33ce46af)
`Voice_bridge.transcribe_audio` gained `?deadline` (default: none, behaviour
unchanged). With it: each endpoint's process timeout is the configured
`http_request_timeout_sec` capped by the time left (and curl `--max-time` is
capped to the same remaining seconds, rounded up); no endpoint starts once the
deadline has passed; an endpoint running at the deadline is ended by the
process timeout and the chain stops instead of trying the next endpoint with a
fresh budget. `Keeper_media_reading.production_reader` passes the projection's
deadline, so the closed gap above is the STT chain's own, now bounded by the
same clock as the PDF reader.
Still not measured: a real STT endpoint; the fake-command chain in
test_voice_runtime_overlay.ml covers a slow first endpoint, a spent deadline
and unchanged failover without a deadline.
Unchanged on purpose: the microphone-capture and probe paths do not pass a
deadline.
