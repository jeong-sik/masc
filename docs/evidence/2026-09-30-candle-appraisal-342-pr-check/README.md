# Candle appraiser parent PR-check failure

Run [36647962228](https://github.com/jeong-sik/masc/actions/runs/36647962228), head `3420179195605aa87b628c1eaa301a798e9c4d2e`, failed the edited-tests step. The complete cached GitHub job log is retained in edited-tests.log.gz; audit.json records its SHA256.

The one reported failing suite was test_keeper_gate_effect_coverage. Its per-keeper exact-lane case expected an unknown-lane error listing six published lanes; the runtime correctly also listed candle_appraiser. The suite ran30cases with one failure. The edited-tests summary says ran312, skipped2; those counters are not a new whole-feature release verdict.

The repair adds the registered lane to the explicit expected contract. Unknown identifiers must still be refused with the complete list, and refusal must still store zero preferences. No runtime routing, preference policy or appraiser semantics change. A matching fixture already passed the integrated885 gate-effect suite; that is not current parent-head PR evidence. Replacement parent-head checks remain unverified until their result is inspected.
