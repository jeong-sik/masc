# Completed-message replay identity

Base: `51912569e64b4514a408f776d31957888b27ab54`.

Muse emits Text_completed for every matching agent-message item completion.
The shared text stream previously treated a replay of an earlier completed
message as a new message once a later message had started. The whole completed
body was appended again, changing the current message and corrupting subsequent
completion reconciliation.

The stream now records completed wire identities for its turn lifetime. Each
identity can contribute completion text once. The identity is recorded before
processing its payload, including empty completions. This decision does not
compare bodies or infer identity from words. Existing prefix-based suffix
reconciliation remains unchanged and is not claimed eliminated by this unit.

Actual lightweight execution used OCaml 5.5.1's interpreter to load the changed
pure module directly; no local compilation or Dune build occurred. A replay
reproduction exited 1 before the change and 0 afterward. Nine direct module
behavior assertions then passed, including missing suffix, replay after another
message, independent equal bodies, and empty terminal completion. The adapter
fixture was extended but has not been executed.

Reproduction artifacts: /tmp/chat-completion-replay-repro.ml,
/tmp/chat-completion-replay-red.log, /tmp/chat-completion-replay-green.log,
/tmp/chat-completion-identity-cases.ml, /tmp/chat-completion-identity-cases.log.

Syntax-only parsing passed for the interface, implementation and adapter fixture;
whitespace checks passed. No provider process, CI, formal approval, installation
or screenshot proof is claimed. Delayed first completion of an earlier message,
divergent completion snapshots and deltas after completed identities still need
explicit protocol/ownership handling.
