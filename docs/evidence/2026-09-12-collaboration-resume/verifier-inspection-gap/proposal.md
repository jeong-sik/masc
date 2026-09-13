# Standalone verifier inspection boundary audit

No implementation, live writes, model calls or resubmission performed.

## Existing entrypoints

Deployed integration source2578 contains `lib/verification_authority_tools.ml`:
- `tool`/`all_tools` lines7–18: Read_file, Search_files, Web_fetch only.
- `create` and `create_goal_proof`: Task binds the submitting producer's sandbox root; Goal binds the shared playground root. These roots must remain the only file authority.
- `schema_of_tool`/`dispatch`: descriptor input preparation, typed dispatch and exactly-once verifier callback stay unchanged.
- `media_result` lines409+: probe then `read_complete_sandbox_bytes` or `read_complete_owned_bytes`, selecting PDF/images. All other binary outputs fail `lookup_output_invalid_utf8`.
- `pdf_result`/`Verification_pdf_inspection.inspect`: captures complete bytes into a private immutable copy, hashes those bytes, runs fixed Poppler argv with scrubbed environment, parses XML through Markup_document, renders every page, checks admitted images and verifies captured source equality. Return is typed metadata plus canonical image content_blocks.
- `Workspace_metric_hooks` supplies this common authority surface to Task and Goal verification; native-client transport already accepts typed images. A producer-supplied PDF/image manifest is not proof that it derives from a specific PPTX/MP4.

No reusable slide/notes or video-file verifier is implemented. `Voice_bridge_core.audio_duration_seconds` is audio-only and returns an optional scalar; it cannot stand in for stream metadata or full decode proof.

## Minimal supported file-inspection contract

Keep `tool_read_file(path)` as the entrypoint. Detect declared media at its boundary, require a complete source read, and reject offset/limit for whole-file inspectors. Internally dispatch an explicit media kind; do not run arbitrary producer commands or load producer Python scripts. Return original source SHA/bytes, parser identity, observed metadata, actual process status/diagnostics and derivative hashes. Unknown values stay unknown. Failure and dependency absence remain typed failures.

1. **MP4 first, one bounded unit.** Capture immutable bytes using the existing complete-read/private-copy pattern. Invoke installed FFprobe with fixed argv to obtain JSON format/stream metadata, parse numeric fields explicitly, expose codec, dimensions, duration and audio stream presence. Independently invoke FFmpeg to decode every selected video/audio stream to the null sink with error-stop behavior, preserving direct process status and stderr; use no shell pipeline. Optional requested-timestamp frame extraction must read the same captured source and return timestamp/source hash/frame hash plus actual PNG content_blocks. Full decode establishes decodability; selected frames do not prove every instant's visual accessibility. Missing FFmpeg, invalid/truncated media and decode failure are errors, not an inferred PASS.

2. **PPTX next, independent bounded unit.** Use an established presentation parser such as python-pptx on the captured bytes for presentation order, slide count, slide text and existing speaker notes. Guard `has_notes_slide` before reading notes; do not create notes on read. Do not infer slide order from ZIP filename sorting. Return a structured per-slide list and original source identity. For independent rendering, run fixed LibreOffice conversion against the same captured copy in a private profile/output directory, then reuse `Verification_pdf_inspection` for complete PDF text/pages. Verify the PDF really exists and is parsable and preserve direct converter process status; generated render is explicitly a derivative of the captured PPTX. Metadata and render inspection have distinct outcomes. Missing notes and incomplete relationship/slide content must not be silently synthesized.

Both units need fixtures through the actual verifier Read dispatch, with real valid files, malformed/truncated files, producer/sandbox containment and missing-dependency errors. Existing image policy applies to derivatives. No cumulative turn/time/page caps or generic Execute access are needed.

## Referenced Board/Fusion sources: small independent unit

Extend the verifier's closed read-only allowlist with canonical ID-based lookup, reusing `Board_dispatch.get_post_and_comments`, `Board_dispatch.find_post_by_run_id`, exact typed origin and the full evidence projection from PR35511. Return original post/comment IDs, authors, turn refs, full body/meta, original panel/judge/source_context, evidence hash and separately recorded Keeper decisions. Do not treat a linked ID, event ack or text summary as an original source read.

Task review should bind the request to the actual submitting Keeper for its own Fusion source while allowing the referenced peer discussion to be read under the existing workspace visibility authority. Goal review has no producer identity: use a workspace-scoped read authority rather than inventing a Keeper or reusing a mutation context. The precise visibility rule for Direct/Internal records must be made explicit in this unit; do not bypass it by exposing `.masc` as a file root. No general search, shell, write or decision tool is required for the standalone judge. Test owner/foreign or wrong-origin/missing source and unchanged no-write authority. This unit can land separately from binary inspection.

## Dependency reality

This audit host has FFmpeg and FFprobe on PATH. `soffice` is absent and Python `pptx` is not installed in the inspected host Python. The producer Docker image declares FFmpeg, LibreOffice Impress and Poppler, but that does not install them in the verifier service environment. Its declared Python packages do not include python-pptx. PPTX inspection therefore needs an explicit prerequisite/runtime packaging path, or a correctly isolated existing worker with the required dependencies; a host-only workaround cannot count as portable release support. The fixed inspector must report its actual dependency availability.

## Exact rejection and priority

`rejection.redacted.json` preserves the authoritative14:05:31Z verdict and its source-line hash. The verifier successfully inspected the8-page PDF and images but could not independently inspect PPTX/MP4 or Board/Fusion sources. It also rejected genuine current-hash/image-manifest/review inconsistencies. Source capability repairs do not erase those producer defects, and no automatic acceptance or equivalent resubmission is proposed.

Suggested first unit is MP4 inspection, because the fixed FFmpeg/FFprobe ecosystem and complete-byte capture already exist; in parallel, the smaller Board/Fusion authority extension can reuse the just-finished canonical lookup. PPTX requires the explicit parser/renderer dependency decision and should stay a separate unit.

Primary ecosystem references:
- https://ffmpeg.org/ffprobe.html
- https://python-pptx.readthedocs.io/en/latest/api/presentation.html
- https://python-pptx.readthedocs.io/en/latest/_modules/pptx/slide.html
