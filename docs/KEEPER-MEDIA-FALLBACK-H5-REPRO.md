# H5 reproduction bundle (real Poppler, real STT, forced failover)

Status: written for the people who run H5 where the tools exist. Nothing here
is a result. Fake-endpoint results and real results are recorded separately;
H5-S1 and H5-S2 stay `not_measured` until the integration observation in
section 4 is made.

## 1. Where Poppler already exists
`.github/workflows/test.yml` installs `poppler-utils` unless `minimal` is set
(os-packages line: `jq ripgrep poppler-utils ffmpeg libreoffice-impress ...`).
`main` has no test-running CI (build + taxonomy only), so the way to run a
Poppler-dependent suite on a head is a manual dispatch of `Test`, a targeted
run (TARGET_SUITES set), not PR-check success:

    gh workflow run test.yml -R jeong-sik/masc --ref <branch> \
      -f suite=test_verification_pdf_inspection_budgets,test_keeper_turn_driver_failover,test_voice_runtime_overlay \
      -f minimal=false

Read the result from the run's job log and cite run id, head SHA and the suite
list together. In test_verification_pdf_inspection_budgets the cases that need
Poppler print `skipped, pdftotext/pdftoppm not installed` and still pass when
it is absent, so a green run with those lines is not a real extraction. Look for
the absence of `skipped` for: `H5 real Poppler extracts the PDF-only fact`,
`H5 real Poppler reaches the projection`, and the existing 7 inspect cases.

## 2. PDF fixture (real, one page)
Inline in test/test_verification_pdf_inspection_budgets.ml (`h5_ledger_pdf`),
611 bytes, one uncompressed page. The fact exists only in the PDF text:

    The ledger year is 1987.

Expected: `Verification_pdf_inspection.extract_text` returns one page text
containing `ledger year is 1987`; `Keeper_media_reading` projects it with
`status=read` and `sha256:<hex of the PDF bytes>`; the capture directory is
removed. Local recipe on a host with Poppler:

    pdftotext -bbox-layout -enc UTF-8 h5-ledger.pdf - | grep 'ledger'
    dune build ./test/test_verification_pdf_inspection_budgets.exe
    DUNE_SOURCEROOT=$PWD ./_build/default/test/test_verification_pdf_inspection_budgets.exe

## 3. Real STT input (not in this repository)
No speech audio is committed. The fixture is made on a host with a speaker
voice and a STT stack, e.g. macOS:

    say -o h5-vault.aiff "The vault code is four one seven two"
    ffmpeg -i h5-vault.aiff -ar 16000 -ac 1 h5-vault.wav
    # whisper.cpp:  whisper-cli -m <model.bin> -f h5-vault.wav -nt

Required: a configured `[voice.stt]` (voice config JSON or runtime.toml
`[voice]`) with one enabled endpoint (`whisper_cli` with `command` and a model
file, or an HTTP STT endpoint with its key env). Expected: the transcript
contains `4172` or `four one seven two`; write the exact transcript and the
endpoint id in the receipt. whisper-cli reads WAV, FLAC and MP3 only.

## 4. Forced provider failover, next turn, restart (integration, not yet written)
There is no integration test for this yet; the unit tests inject the reader.
The observation to make, with real readers:
1. Runtime config with a lane whose head can take audio and document but fails
   (an endpoint that refuses connections, as in
   `runtime_toml_media_lane_with_global_outside`: `endpoint = "http://127.0.0.1:1"`)
   followed by a text-only candidate.
2. Send one turn carrying the PDF block (section 2) and the question
   "what is the ledger year?" through `Keeper_turn_driver.run_named`. The head
   fails; the walk reaches the text-only candidate; its model input must contain
   the `status=read` block with the fact. Record the manifest rows
   (`media_degraded_to_text`, `media_projected_*`) and the model's answer.
3. Next turn on the same keeper: the stored reading under
   `<base_path>/media-readings/<keeper>/` is reused, with no reader call
   (observe by making the reader unavailable, e.g. PATH without Poppler).
4. Restart the keeper process and repeat (3).
5. Negative (H5-S3), kept apart from 2-4. A stored reading is looked up before
   any reader runs, so for the same keeper, bytes and MIME that already have a
   stored reading, hiding Poppler or the STT endpoint yields a normal `read`
   reuse. That is the behaviour 3-4 observe, not a failure. The negative run
   therefore uses a new keeper/base path, or new source bytes (a corrupt or
   different PDF has another sha256), and records at its start that no durable
   reading exists for that key. Keep the earlier successful readings; do not
   delete them. Then, with the reader failing (Poppler absent, or a corrupt
   PDF, or the STT endpoint stopped), the block must say `status=unavailable`,
   name the reason, keep the original in history, and contain no text derived
   from the PDF or audio.
The same sequence applies to the audio fixture, with the STT endpoint stopped
for (5) on a new key. Do not count (5) as a substitute for (2).

## 5. What is still unmeasured
Real PDF extraction at a CI head until the run in section 1 reports the H5 real
Poppler cases without `skipped`; real STT; forced failover with a real provider
head; next turn and restart integration. Needs: an environment with Poppler
(CI Test workflow qualifies), a speech fixture and STT endpoint, and a lane
config with a failing head plus a text-only fallback.
