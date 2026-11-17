# Document followup: result boundaries

[Results](results.json) records the 2026-11-17 work-boundary reads of the named GitHub runs, jobs and PRs. Original Actions logs supplied the actual checkout commits. The retained JSON is a selected derivative, not a copy of those logs; `log_content_sha256` identifies their original decoded content. Linked jobs provide the source.

Three `PR type-check (dune build @check)` jobs ran successfully on the recorded synthetic merge objects. Two Schedule jobs were skipped although their workflows succeeded. These are neither behavior-suite results nor checks of a later Gemini followup.

At the initial capture, the [Keeper comment](https://github.com/jeong-sik/masc/pull/52620#issuecomment-6935761315) and original operation `kmsg-2a3760bb349072a26f5374a5cd9c84b9` report the two maintained suites at exact parent 4ccdd508: 12 and 51 cases, zero failures and skips. Actual compiler was 5.5.1. Build logs m1/m2 arrived and match their declared byte lengths and full SHA-256. The first r1 transfer decodes to 1,173 bytes instead of the declared 1,174 and has a different hash; r2 bytes have not arrived. Original preserved-file transfer was requested again without rerunning tests. These incomplete transfers do not establish direct verification of either execution log. This is explicitly reported execution evidence, not a 5.5.2 result or a new Gemini test result.

Gemini followup b88ffb072fde moves document admission into `Backend_gemini.project_history`, preserves canonical documents and existing signature checks, and extends an existing registered test case with four Gemini combinations. Four full changed OCaml files parse on 5.5.2 and an independent reviewer read the delta. Those checks do not execute the new combinations. Shared elapsed-deadline removal did not make the projector immutable: its walk-owned mutable memo remains.

All three Schedule members were separately observed merged. Their merge commits differ from their CI checkout objects. The shared GitHub login does not identify the session that marked them Ready or initiated integration. This author performed neither action.

This record does not establish external media-reader support, real PDF/STT/provider execution, deployment, restart recovery or the original multi-Keeper Farm success conditions.

## Gemini execution failure and repair

The later actual Keeper operation `kmsg-5478d8d25b623eabf4d1a0f184971e43`
built and ran the maintained tests at exact `9036a38c2366a0a4c73d4eb040ba956dc29d584e`
(tree `b8e15385009ecaf8a504606aa8b715879bdce3ba`). The lane used OCaml 5.5.1,
Dune 3.24.2 and Alcotest 1.9.1. Document admission built successfully but failed
1 of 18 cases, with zero skips; a second run reproduced the same failure.
The existing Gemini suite built and passed all 55 cases. These results are
reported by the original execution reply; full execution-log transfer is a
separate operation, not another test run. See the [public failure record](https://github.com/jeong-sik/masc/pull/52636#issuecomment-6936555969).

The failing input was a PDF in a ToolResult with document support enabled.
Preflight retained its bytes, but the serializer emitted only the tool summary.
An accompanying image happened to move the PDF to a user followup. The repair
uses [generateContent FunctionResponse parts](https://aistudio.google.com/api-reference/generate-content#Resource:FunctionResponse),
with an independent `supports_function_response_parts` declaration. The generic
Gemini preset defaults to false; the catalog's named Gemini chat rows declare
support. The [function-calling guide](https://aistudio.google.com/docs/function-calling#multimodal)
documents multimodal results for Gemini 3 and later. Its Interactions examples
are not the request schema used here.

The native serializer preserves the correlated call id/name, summary, JSON,
failure state and nested media positions. Media references cannot capture an
existing JSON `$ref` name. Without native response support, document/audio
omissions occur during shared projection; image followups preserve the original
nested result tree and carry matching source-position labels. Direct user
media keeps its separate input-capability boundary. The original failing
combination remains in the test matrix alongside both declaration axes.

The repair adds two registered Gemini cases (57 total), three capability cases
(126 total) and one provider-catalog case (22 total). Document admission still
has 18 registered cases; its matrix has expanded inside an existing case.
Registration and syntax checks do not establish a successful repair execution.
The same candidate still needs the actual lane's four maintained suites.
The formal change request on old head 9036 remains historical evidence until
an independent reviewer re-evaluates the new head.

## Earlier reader test-log transfer completed

The preserved `4ccdd508` execution logs subsequently arrived intact. All four
byte lengths and full SHA-256 values were checked locally: m1 40 bytes
`5e6f0a12e1aa994587b65bfd31479759d2c56faf540e241357146341a7d9497b`,
m2 0 bytes `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`,
r1 1,174 bytes `8137a0dd33ae2edf073bb3b67f5ec2c798b2a0114c30af560fde62058c21e405`,
r2 4,379 bytes `6693b59c676e4e4913bf23ccef0e32022072c9e05fc48b216bc0adcf163f5132`.
The earlier damaged transfer is preserved; this later receipt supersedes the
initial incomplete-transfer status above. The logs contain 12 and 51 successful
cases and match that source's registrations. Compiler, head, dependencies and
exit statuses remain facts from the execution report, not facts encoded by
those stdout files. None of these 63 cases executes the new Gemini repair.
