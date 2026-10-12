# Terminal finish cannot erase observed failure

The live transcript RUN_FINISHED arm previously assigned Stream_ended for all states except active resumable checkpoints. A finish after Run_failed erased the observed failure; repeated finish on Stream_ended moved ended_at and changed ending_source even though settled_at retained the first settlement.

Already-terminal Stream_ended/Stream_failed states now ignore RUN_FINISHED. Waiting/Working keep their existing first-completion and operation-checkpoint behavior. Run_failed remains separately able to retain a later authoritative failure after recorded reply; that existing contract is unchanged.

Interpreted actual parent/current complete RUN_FINISHED arm and existing settle helper with minimal external phase/reply/source record definitions. Parent failed `finish erased terminal truth`. Current passed failure/completion preservation including ending source and ended_at, ordinary first completion and operation checkpoint reset. No computational stub was used. Artifacts `/tmp/masc-finish-terminal-failure-20261012/{parent,current}.{ml,log}`.

Extended existing registered state fixture to check failure phase and settlement preservation after trailing finish. Fixture remains unexecuted. Both changed OCaml files passed syntax-only parsing; git diff --check passed. This is selected reducer-state evidence, not complete live decoding, replay or rendered outcome proof. Full typecheck/build/CI/provider/runtime/installation/screenshots/formal approval/merge remain unverified.
