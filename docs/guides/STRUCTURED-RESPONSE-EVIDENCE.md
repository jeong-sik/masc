# Inspect a failed Vision or Fusion structured response

Vision candidate failures and Fusion judge parser failures retain a private
record after the actual response arrives. The failure remains a failure;
recording evidence does not dispatch another request or relax validation.

The public error contains `structured_evidence_id: <UUID>` only after the
private record commits. Inspect that exact file under the receiving workspace:

```text
<base-path>/.masc/traces/structured-output/<UUID>.jsonl
```

Each record includes the actual candidate runtime, its ordinal, a unique
parser-owner invocation, and the original bounded parser detail and response
preview. Vision also retains its supplied parent tool-call and trace IDs.
The parser invocation is separate from an SDK run ID. Fusion's failed seat
attempt retains the public error reference, including when a later candidate
succeeds; concurrent invocations use separate record IDs.

`raw_len` counts the full original response bytes. The preview and parser
detail use Agent Core's 4 KiB evidence bound, ending before a UTF-8 character
crosses that boundary. For fenced Fusion output, evidence is the original
response before fence removal. SDK structured failures keep their original
bounded preview and original byte count. Public error text contains neither
the model output nor the parser's input-dependent detail.

Files use the existing private 0600 JSONL writer and its fsync/settlement
contract. They are local operator evidence, outside public artifact download
and ordinary event JSON. They do not certify hardware power-loss persistence.
A missing workspace or failed write returns `structured_evidence_unavailable`
instead of inventing a usable reference or returning the raw output inline.
Cancellation still propagates. No existing approval or runtime data is reset.

The observability artifact registry identifies the workspace operator as the
lifecycle owner. These exact failure records have no automatic age expiry;
explicit operator cleanup is separate from diagnosing the failure.
