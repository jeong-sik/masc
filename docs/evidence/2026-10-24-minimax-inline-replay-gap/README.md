# Native MiniMax inline replay gap (#27924)

This is a deliberately failing offline contract probe, preserved while responding
to [the #45689 review](https://github.com/jeong-sik/masc/pull/45689#pullrequestreview-5637209628).
The reviewer allowed separating inline conformance from this fixture-only PR when
the production repair exceeds its scope. The admitted fixture covers **split
reasoning, structured reasoning and tool calls without thinking**, in sync and
SSE modes. Removing the false inline assertion does not repair inline replay.

## Observed failure

[observed.json](observed.json) records both production parse → canonical assistant
history → final request-builder paths. Each receives
`content: "<think>check forecast</think>"` with the same tool call. Each replays
`content: null` and `reasoning_content: "check forecast"` after a later user turn.
The original inline carrier is lost. The contract probe returns **1**, with
`inline original-content contract failed in 2/2 modes`.

[MiniMax's official OpenAI SDK contract](https://platform.minimax.io/docs/api-reference/text-openai-api),
reread 2026-10-24, names MiniMax-M3 among the models whose original inline
`<think>` content must be preserved completely in `content`. Separately returned
`reasoning_content` has its own preservation rule. Moving the text between those
fields does not satisfy the inline requirement. No live request or provider
rejection is claimed here.

## Execution boundary

The input fixture and inspected source were taken from PR head
`d069323ed726e7d8224d1c7a8b13397219cc0a00`. No Dune build was run. The small probe
was linked directly with existing `llm_provider.cmxa` and
`agent_core_strings.cmxa` artifacts from checkout
`90269c9233e34ab22940a4e8d5ca386033916d8c`.
[source-match.json](source-match.json) records identical bytes for the eight
relevant production source files and model catalog in that reused build tree.
This source comparison is not a clean build of d069, CI, installed-runtime,
MiniMax account-access or live-provider evidence.

[inline_replay_gap.ml](inline_replay_gap.ml) is outside the passing test suite.
It emits both observations and fails if original content is not preserved. It
must not be changed to expect null content. A future repair should carry a typed
original-wire witness through sync parsing, streaming events/accumulation,
canonical history persistence and same-provider request projection; it must keep
inline reasoning out of the visible answer. Reconstructing tags from merged
`Thinking` text cannot preserve their original placement and bytes.

## Reproduce using existing artifacts

Set `probe_lib_dir` to an already-built `packages/agent_core/lib` directory. The
following command only compiles the small probe; it does not invoke Dune. Copy the
source to a temporary directory so compiler products stay outside this evidence.

```sh
probe_tmp_dir=$(mktemp -d)
cp docs/evidence/2026-10-24-minimax-inline-replay-gap/inline_replay_gap.ml "$probe_tmp_dir/"
ocamlfind ocamlopt -thread -linkpkg \
  -package digestif.c,alcotest,yojson,otoml,ppx_deriving_yojson.runtime,eio,eio.unix,eio_main,threads,unix,str,cohttp-eio,cohttp,http,tls,tls-eio,ca-certs,cstruct,mirage-crypto-rng,mirage-crypto-rng.unix,mtime.clock.os,domain-name,ipaddr,uri,ppx_inline_test.runtime-lib \
  -I "$probe_lib_dir/strings/.agent_core_strings.objs/byte" \
  -I "$probe_lib_dir/strings/.agent_core_strings.objs/native" \
  -I "$probe_lib_dir/llm_provider/.llm_provider.objs/byte" \
  -I "$probe_lib_dir/llm_provider/.llm_provider.objs/native" \
  "$probe_lib_dir/strings/agent_core_strings.cmxa" \
  "$probe_lib_dir/llm_provider/llm_provider.cmxa" \
  "$probe_tmp_dir/inline_replay_gap.ml" -o "$probe_tmp_dir/inline_replay_gap.exe"
"$probe_tmp_dir/inline_replay_gap.exe"
```

The observed run failed its content-preservation contract as described above.
That failure remains tracked by #27924. It is not a passing native conformance
receipt or an additional ordinary-PR CI admission gate.
