# Captured verifier read authority on the current owner

Base: `a862236ceff5da8af63a9b01bfa05e1357706d07` (#45471). Source repair before documentation/changelog: `b7e699a310c1b2fb79c7add459fb4cc909210cd0` (#45524). This is an upper layer in Native Stack #45472; it does not rewrite the owner's refs.

## Concrete source repair

The owner now retains its prompt, images, exact output contract and an opaque Task review bound to its submitted header, full tool schemas/evidence and route. Those existing changes superseded root's parallel frozen-prompt implementation; that alternative was not applied.

A configuration check followed by another endpoint resolution can still read a replacement endpoint. The repair captures a typed endpoint and its declared path authority together, derives the retained route from that same endpoint, and passes it explicitly through endpoint path admission, host-to-endpoint translation, actual Read, Grep and its type-list recovery, media byte-prefix/escalation, and remote layout. The current Task route validator remains: a changed configuration refuses a new Task lookup; a later change cannot redirect the admitted command. No ambient override, extra registry, serialized dispatch closure or second process runner is introduced. Docker keeps its existing shared-tree route. MicroVM uses its attached endpoint without starting a guest.

The new controlled SSH fixture records actual transport destination and cwd. After replacing the endpoint configuration, the old raw surface still targets its captured endpoint and refuses newly declared paths, while a newly created surface uses its own replacement endpoint. This tests endpoint ownership separately from the Task review's existing live-configuration refusal. The fake SSH endpoint is not a real SSH host or provider.

The current owner's success fixture incorrectly sent internal `path` to the model-facing Read descriptor. It now sends public `file_path`, which descriptor validation accepts and translates to internal `path`. This is specific to this base. An earlier private claim against a different fixture was withdrawn: that earlier fixture already used the correct public field.

## Evidence boundary

- Independent adversarial review read the complete17-file source delta and direct consumers, including current opaque authority creation/binding, validator and worker. No P0/P1/P2 was found in this bounded repair.
- All17 changed OCaml files passed parser-only checks; diff checks passed. [Parser receipt](parser-checks.json) and [source manifest](source-manifest.json) identify that source repair.
- No typing, local Dune build, executable test, actual SSH/MicroVM/provider, installed-runtime or visible-UI success is asserted. A CI request is not an executed result.

The first selected execution, [run39930397133](https://github.com/jeong-sik/masc/actions/runs/39930397133) at exact4253fd369fb64309a14bca02b654f59d48162837, failed during aggregate compilation: the existing worker fixture used `Masc.Workspace_verification_store`, but this module belongs to the unwrapped `masc.masc_workspace` library. All four selected suites were unexecuted. The follow-up uses the actual top-level `Workspace_verification_store`, as existing collaboration-evidence consumers do. Parser/source checks do not establish that this repaired candidate executed successfully.

The second selected execution, [run39932285399](https://github.com/jeong-sik/masc/actions/runs/39932285399) at exact `e97373e95dcf1ed54568dc2a998a555486e81c38`, also stopped during aggregate compilation: the same fixture qualified a configuration field as `config.Workspace.base_path` without binding `Workspace`. The fixture now explicitly aliases `Masc.Workspace`, matching the existing completion trust harness. All four selected suites were again unexecuted; neither failed run proves test behavior.

## Required lifecycle work remains

[Current-head source findings](https://github.com/jeong-sik/masc/pull/45471#issuecomment-6361503931) include a separate P2: `next_attempt` allocates highest+1 on every wake while the actual host/worker do not durably advance dispatch, judgment or commit progress. Cancellation, uncertain dispatch and judgment-before-commit must recover the original frontier; merely choosing a new ordinal cannot authorize another provider call. A typed definite refusal can authorize its own retry policy, distinct from an unknown result. Original54 D03/D04/D06/E06 completion is not established by this endpoint repair. Whole-stack integration remains separate and must include all current-head independent reviews and outstanding lifecycle repairs.
