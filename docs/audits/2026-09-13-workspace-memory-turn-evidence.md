# Captured Keeper turn inspection

The installed discovery probe checks a publication and Dashboard prompt previews.
Those observations cannot establish that a Keeper turn received the affordance,
called the read tool, or used the proposal. `scripts/inspect-workspace-memory-turn.py`
inspects the next evidence boundary without converting it into semantic approval.

Capture the selected Keeper's `/turn-records` response, its `/provider-input?turn_ref=…`
response, and the exact raw trace referenced by that TurnRecord. Supply the
publication descriptor and resolved discovery fragment preserved by the installed
discovery probe. URL-encode `#` in the turn reference as `%23` when making HTTP
requests. Keep captures private: provider input can contain full historical tool
arguments, source content and conversation text.

```sh
python3 scripts/inspect-workspace-memory-turn.py \
  --keeper exhibit-editor \
  --turn-ref 'trace-example#502' \
  --turn-records /path/to/turn-records.json \
  --provider-input /path/to/provider-input.json \
  --raw-trace /path/to/selected-turn.jsonl \
  --publication /path/to/discovery/publication.json \
  --fragment /path/to/discovery/resolved-discovery-fragment.txt \
  --output /path/to/new-private-output
```

The output directory must be new. It retains exact source bytes and hashes plus
an inspection receipt. The inspector joins the selected Keeper, turn reference,
trace session and worker identities, checks the captured run sequence, counts
complete fragment occurrences, and records exact-ID read invocations and their
matching tool completions. Missing reads, absent fragments and tool errors remain
explicit observations; they do not become successful discovery or adoption.

Exit zero means the supplied evidence was inspected, not that the feature passed.
The source files are not authenticated runtime attestations. The wire snapshot
records pre-dispatch serialization, not remote model receipt. Fragment occurrence
does not establish dynamic-context provenance, and tool completion alone does not
establish complete proposal delivery. A large tool result may refer to an artifact;
inspect the retained result and subsequent artifact reads. Then compare the Keeper's
actual decisions with original source evidence before claiming understanding or
semantic adoption. Keep deployed source/binary identity and current memory currency
as separate evidence.

The CLI fixture suite exercises matching reads, absent and duplicated fragments,
wrong proposal IDs, tool errors, missing completions and contradictory identities.
It is offline fixture coverage, not native or installed-runtime acceptance.
