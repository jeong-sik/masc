# Production verifier image delivery probe

## Baseline: aggregate submission rejection

A fresh isolated server at commit `1ef7ce2ec709b8b719e9687e774ea5258d87dee8`
received an actual Keeper message. Its configured synthetic producer emitted
`keeper_task_claim` then `keeper_task_done` with three valid PNG artifact refs,
497844 bytes total. The real tool returned `workflow_rejection`: aggregate
497844 bytes exceeds 51200 bytes, advising note conversion. The Keeper operation
finished Succeeded, but the primary Task remained in_progress; the verifier
provider received no request. Succeeded here means the chat operation ended,
not successful evidence submission.

The binary's three manifest hashes were checked before launch. It is an
unvalidated CI runtime probe build, not a release certification. The server was
stopped after the authoritative terminal Keeper operation and confirmed rejected
submission. Port 18937 and its data were untouched; the isolated port was 18945.

The baseline ran the first harness revision, before later uncertainty-cleanup
hardening. Its observed success path reached authoritative termination; no
uncertain cleanup path was exercised. The current harness additionally preserves
its server/provider on uncertain admission or read failure and waits for an exact
committed verifier verdict on the positive path.

Files under `baseline/` preserve real provider requests (including exact tool
input/result), primary backlog, operation readback, binary receipt, health and
server log. They contain only controlled fixture data. `sha256.json` binds the
stored bytes. Synthetic provider responses are transport fixtures and do not
establish document readability or semantic model approval.

## Production reviewer capability selection: small images

Both isolated runs used the same actual candidate `1ef7ce2ec7` and three 69-byte
valid PNGs (207 bytes total, below the still-present aggregate submit gate).
The Keeper and completion authority used real production dispatch and HTTP
runtime selection; no reviewer callback was replaced.

- `text-only-runtime/`: the AG catalog declared image support, but the concrete
  MASC runtime model omitted its `supports-image-input` capability. The runtime
  projected all three images to text references. The synthetic provider received
  zero image parts and reported REJECT. The primary Task returned to in_progress;
  the exact committed verdict and operation terminal state were observed before
  shutdown. This was a fixture declaration error, not an ingress regression.
- `image-capable-runtime/`: the concrete runtime model also declares image input.
  The actual provider request contains three PNG data URIs. Each decodes to 69
  bytes with SHA-256 `b1ff9c8ea3a780bad09b346c423d2d0e46815926879b18e841d928376a946640`,
  matching all three persisted snapshot bodies. The primary Task is done and its
  committed approved verdict binds request `vrf-f6d6abf55bf11a14f0c45026db305558`
  to evaluator runtime `image_fixture.vision`. The actual model ID was
  `image-verifier`; the Keeper operation was
  `kmsg-77f45c20a232fb22636391f348376215`.

The synthetic provider checks byte equality and returns a controlled verdict.
This proves production image assembly and capability selection, not visual
quality, actual GLM/Kimi image interpretation, or large-page admission.
Each directory contains raw provider requests, exact primary Task/verdict/request
records, the resolved input config, snapshot bodies, and SHA manifests.

## Actual PDF verifier lane audit

Read-only inspection of the existing isolated PDF server's current runtime TOML
found verifier slots `glm-coding.glm-5-3` then
`ollama_cloud.ollama-cloud-deepseek-v4-flash`. GLM's concrete runtime model omits
image support and DeepSeek explicitly disables it. The production source applies
runtime model media capabilities over the broader AG catalog, defaulting an
omitted image capability to false. Existing Kimi mappings declare image input,
but neither is selected in this verifier lane. Actual prior verdict logs name
`glm-coding.glm-5-3`. No live config was changed and no real external model was
called by this audit. A genuinely capable selected runtime and an actual visual
acceptance run remain necessary for the PDF scenario.

## Large-image aggregate repair

`large-image-runtime/` records the repaired candidate
`4a6723c3f54a597a52db26276635b4a2b8b6e871`, manifest verified before launch.
Its three complete 165948-byte PNG artifact submissions total 497844 bytes.
The production reviewer receives three exact image data URIs; every decoded
body matches its persisted snapshot and SHA-256
`ab93bd722e44681112edc97cf1f5d7b94524aa1b59b50cb9ced6a47ef21fe4b0`.
The primary Task is done and the committed approved event binds verification
`vrf-788f11e65028f26a6e9faa094061d7b0` to `image_fixture.vision`, with producer
operation `kmsg-249bf61fb7b5f1eb8d6c3e0f5ca278cc` Succeeded.

This closes the aggregate-submission and production image-transport scenario.
All pages remain below the per-image 200000-byte capture limit. The provider is
synthetic and its approval means exact byte receipt, not document readability.
Actual Kimi/PDF semantic verification remains a distinct run.
