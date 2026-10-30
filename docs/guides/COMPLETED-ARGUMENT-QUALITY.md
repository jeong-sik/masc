# Completed tool argument response quality

Issue [#37853](https://github.com/jeong-sik/masc/issues/37853) requires a real
model comparison with and without completed argument demotion. The manual
`keeper_argument_quality_cli` executable prepares three paired synthetic tasks:
recover hidden fields, compare corresponding fields, and reuse the exact nested
operational request. It does not execute a shell command or change a live Keeper.

Both arms use `Small`, identical source messages, system prompt, question, tool
schemas and an explicitly selected concrete runtime. The verbatim arm omits
`argument_demotion_seed`; the projected arm supplies the same raw history as
that seed. Both arms retain the same completed tool cycles behind a verified
completed boundary and a Librarian position. Using `Wide` as the baseline would
also change range and result behavior, so this experiment does not use it.

The original argument envelopes have different labels and long notes before
the nested requests. The requests have equal argv and operation token but
different targets. A different blob hash therefore cannot answer the comparison.
Fresh opaque values are generated once and shared across the pair. Notes exceed
the canonical artifact reader's largest page, placing the meaningful request
beyond both its first page and the actual reference preview. The offline oracle
is stored privately with the corpus and is never sent in a tool description,
schema, current question, receipt, or grading feedback.

Ask the designated executor to build this executable from the candidate head.
External coding agents follow the constitution's build and CI protocol. Run the
already built candidate with an explicit runtime configuration and a new private
directory whose parent exists:

```sh
./_build/default/test/keeper_argument_quality_cli.exe \
  --runtime-config /path/to/runtime.toml \
  --runtime-id PROVIDER.MODEL \
  --output-dir /path/to/new-private-evidence
```

The CLI accepts an active AgentCore binding. It rejects lanes and official-client
bindings rather than silently choosing a model. It runs each arm once; a single
paired sample is evidence about that sample, not a statistical quality estimate.
The experiment intentionally has no synthetic turn, token, time or tool-call
budget. Provider failures and incomplete evidence remain in the report.

`corpus.json` contains the source and oracle. Each arm writes its full observations
and actual checkpoint sink snapshots. Every saved checkpoint is decoded from
disk and its original history prefix is compared with the source; normal appended
answers and tool results are allowed. The report records the binary identity,
configuration digest, actual provider/model/codec, canonical input copies, tool
schemas, reader pages, submitted answers and terminal provider response. Treat
these files as private model input/output evidence. No credentials or HTTP
headers are recorded.

The wire observer exposes exact prepared-body byte counts and hashes, not raw HTTP
bodies. The canonical capture is the caller projection after transmitted-history
dialect replay projection and bounded demotion, before final unread normalization
and backend merge, prefix verification and serialization. The HTTP observer
separately records client entry, dispatch, response status and client return; its
call IDs distinguish identical retries. The report distinguishes first prepared
request size, total serialized bytes and total bytes submitted to the HTTP client.
These are byte counts, not a claim about token savings or peer-acknowledged bytes.
The response's reported usage is retained without relabeling it as whole-turn usage.
Every observed HTTP call must have a corresponding serialization receipt;
unmatched calls make the pair inconclusive. Successful CLI exit means the report
was written, not that quality or the issue's completion requirements passed.

`retained` and `improved` require comparable actual inputs and a single observed
provider/model path, successful transport evidence, unchanged durable source
prefixes, and reader pages covering the hidden request before a later model round
submits the answer. A read and submission in the same model response do not establish
that the model saw the page. Correct answers without this retrieval evidence are
reported separately. Wrong answers remain `regression` or `both_failed` when the
pair has the required structural and transport evidence. Other gaps are
`inconclusive`; raw correctness and evidence flags remain visible.

This checks exact reuse of the nested operational request, not reproduction of
the surrounding long notes/envelope. It does not establish official-client,
fleet, installation or visible UI behavior. Official Codex, Claude, Antigravity
and Muse Start/reseed paths bind their own raw completed seed and actual prepared
reader surface through the shared Host projection. They preserve the canonical
source and only materialize arguments in the transmitted range. Resume leaves
the remote conversation held by its client and performs no argument projection.
These adapters have separate fake-client serialization and recovery scenarios;
those fixtures and this AgentCore-only runner require their own execution
evidence. This runner does not establish official-client response quality or
retroactively rewrite a remote client-held conversation. Actual official-lane
and paired model verification remain requirements for #37853.
