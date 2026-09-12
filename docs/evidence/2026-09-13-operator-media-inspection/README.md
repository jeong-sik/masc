# Operator inspection of original media

The installed command can run the same original-file inspection as verifier Read
without submitting or resubmitting a Task or Goal:

```sh
masc inspect-file --base-path WORKSPACE ORIGINAL.pdf
masc inspect-file --base-path WORKSPACE ORIGINAL.pptx
masc inspect-file --base-path WORKSPACE ORIGINAL.mp4
```

The command emits one JSON object on stdout and returns zero only for completed
inspection. `source` identifies the complete captured input by path, SHA-256 and
byte count, including when a dependency or parser later fails. `result` preserves
the shared inspector's disposition, typed failure classification and evidence.
`content` carries actual PDF/PPTX PNG page bytes in MCP image format, with each
page's corresponding hash in the inspection metadata. `llm_verdict: not_run`
states that no model evaluated those images or approved an artifact.

The existing inspectors own parsing, rendering, full audio/video decoding,
private capture cleanup, and their uninspected-scope statements. Their source
files are unchanged. Result construction moved from verifier Read to a shared
module used by both callers. Presentation parsing still requires the selected
workspace's managed Python environment, and native renderer/decoder commands
are resolved from the invoking process's PATH. The CLI installs nothing.

No workspace initialization, credentials, server, model turn, Task completion,
Goal proof or confirmation is invoked. Temporary capture directories are the
only workspace output; the inspectors remove their temporary files afterward.

Six OCaml source/interface parse checks, Python syntax and declaration checks
passed locally. The native CLI feature suite uses the existing actual PDF/MP4
and CI-generated PPTX fixtures and checks original hashes, every returned PNG,
full stream decoding, missing dependencies, truncated inputs, explicit file
errors and unchanged domain state. It has not yet run; neither native compilation
nor installed CLI behavior is claimed by these source checks.

The native fixtures also include repair `04bdb26e8f` (cherry-picked as
`375dc5d82f`): Python and OCaml resolve the presentation fixture below the system
temporary directory, and the tool-plan test includes BrowserGoto's output
contract. The CLI presentation case uses that same fixture root.
