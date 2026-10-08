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
