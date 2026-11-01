# Keeper native image observations — 2026-11-01

Two real Keeper image-attachment requests produced correct visual answers on
running binary `5d58ef2f9746539c50c6544c2c811f1637b789d2`. Three configured Claude
Code accounts accepted native image messages but did not produce a verified
visual answer. These observations precede the guidance corrections in #47259
and do not prove that those new instructions were deployed.

## Retained evidence

[observations.json](observations.json) is an intentionally selected, sanitized
derivative of the original durable operation/status captures, provider input
snapshots and native client submission receipts. It retains operation/turn IDs,
input hashes, replies, terminal outcomes and cleanup observations. Full prompts,
raw logs, credentials, account identities and host paths remain private. A
recorded native-frame digest describes the original private frame, not this
derived JSON, and cannot be independently reconstructed from this bundle alone.

The two PNG files retain their original bytes:

| Input | SHA256 | Size |
| --- | --- | ---: |
| [GLM input](glm-input.png) | `4ff566a39fc8008736678546ad1298dd42d047632a106e09f6bd6e4658ce6c2f` | 8,601 bytes |
| [Codex / Claude input](codex-claude-input.png) | `fb1c5d14ee41b53ad741ee0b6ff8b3cb6d90a5dbfa7435303856d0dd8a3b7223` | 8,887 bytes |

## Method and observed results

Each input was a fresh 640×360 PNG containing a random code, a blue circle on
the left and a red triangle on the right. The question asked for those three
items without putting the code in request text or Keeper instructions. Each
fixture used an explicitly selected runtime and on-demand activation, with
instructions to avoid tools, OCR and delegation.

The real `/api/v1/keepers/chat/stream` endpoint received typed `user_blocks`
and PNG `attachments`. After admission, the original operation ID was read
through `masc_keeper_delegate_status` to its terminal state. GLM's initial
client stream timed out; its accepted operation was not replayed, and its
success/reply were recovered from durable status.

| Runtime | Result | Observed reply / limitation |
| --- | --- | --- |
| GLM `glm-5.3-flash` | PASS | `9DBV4ZM`, blue circle, red triangle; one model attempt, no tools; 203,226 ms end to end |
| Codex app-server `gpt-6.1-sol` | PASS | `5WE28VJ`, blue circle, red triangle; one attempt, no tools or fallback; 58,316 ms end to end |
| Claude Code A / B | Visual result unverified | Native image input written; hard quota rejection, HTTP 429, `response_emitted=false` |
| Claude Code C | Visual result unverified | Native image input written; quota rejection with `api_status=unknown` and `response_emitted=true`; terminal `provider_attempt_effect_fenced`, `observation_unavailable`, `effect_review_required` |

GLM's provider input snapshot included the original stored image hash. Codex
`turn/start` and all three Claude Code native user messages were reconstructed
from the exact PNG and assembled prompt; their UTF-8 lengths and SHA256 values
matched the recorded successful stdin writes. An independent read-only agent
reviewed the original records and these comparisons. That review is not a
formal GitHub approval or a second provider execution.

All five dedicated Keepers were observed paused, with keepalive stopped and
shutdown finalized. Metadata and traces were retained. Claude C's uncertain
response observation was neither cleared nor automatically replayed.

## Scope limits

- These were image attachments, not browser screenshot capture or a
  `keeper_image_read` tool-result round trip. The native artifact-reading
  procedure is separately traced in source; see the
  [Keeper manual](../../KEEPER-USER-MANUAL.md#inspect-images-directly).
- Claude native serialization is verified; Claude image-reading success is
  unverified. A quota error does not prove absent image capability.
- These results do not cover every configured runtime, model or account, a
  later binary, new prompt text, applied Skill revisions, or full regression.
- Source correction, independent source review, live prompt/Skill application
  and a successful native visual reply remain separate evidence.

To check the retained image bytes, run from the repository root:

```bash
python3 - <<'PY'
from pathlib import Path
import hashlib, json
root = Path('docs/evidence/keeper-native-image-input-20261101')
record = json.loads((root / 'observations.json').read_text())
for image in record['images']:
    data = (root / image['file']).read_bytes()
    assert len(data) == image['bytes']
    assert hashlib.sha256(data).hexdigest() == image['sha256']
    print(image['file'], 'verified')
PY
```
