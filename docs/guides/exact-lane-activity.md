# Exact Lane activity

Each `[runtime.exact_output_lanes.<id>]` table accepts `enabled`. Omitting the
key means `true`. Set it to `false` to refuse new implicit work while retaining
`slots`, `cli_slots`, their order, `thinking` and `max_output_tokens`.

```toml
[runtime.exact_output_lanes.librarian_exact]
enabled = false
slots = ["provider.model"]
cli_slots = ["official.client"]
```

The IDs above are examples; keep the candidates already declared for your
deployment. An optional lane may be off with empty candidate lists. Enabling it
requires at least one candidate and the usual admission checks. Malformed or
duplicate candidates remain configuration errors even when off.

The existing Required lanes, Board Attention and HITL auto-judge, cannot be
disabled. Loading or saving such a declaration is refused. Librarian, Workspace
Curator, Verifier, Browser Stagehand Exact and Candle Appraiser are Optional.
Stagehand Exact activity controls its model requests; Browser executor/session
activity is a separate owner.

Save through the existing runtime TOML editor. Its revision check, validation
and commit receipt still apply. A saved file alone does not establish that the
registry was replaced: read the application receipt. Activity is published in
the same immutable registry as the lane's candidates. An off acquisition returns
`Exact_lane_off`; already acquired snapshots remain usable. A Required lane
cannot be disabled through a publication exception or replacement transaction.

Librarian acquires its candidates before JEV preflight. Off prevents both a new
JEV judgment and a new full generation; the pending range remains unconsumed.
A pass already in JEV retains its acquired candidates for generation fallback
and can finish normally. Verifier refuses new implicit reviews, while an accepted
review retains its declared CLI execution constraint. An explicit single-runtime
evaluator override remains independent of the Verifier lane's activity.

TUI and Web observations show `off` separately from unavailable/unconfigured.
Declared candidates and retained run evidence remain visible, including accepted
work still finishing. `running_count` describes retained observation coverage,
not an atomic census of all processes. Browser Stagehand has no standalone run
history. The inventory read never starts or stops work.

This change provides the configuration owner and its readout. A dedicated TUI
toggle/save interaction and Web activity control remain follow-up work. Enabling
a lane allows its next request; this change does not send a new wake to a parked
Workspace Curator owner. Its next owner request resumes processing.

## Upgrade notes

Existing declarations with no `enabled` keep their behavior. Install a binary
that accepts the key before adding it to a live configuration. This change does
not require new tables/keys in every deployment or edit operator configuration.

Native backend and TUI execution evidence is separate from parser, isolated
decoder/display and synthetic Web evidence in the corresponding evidence folders.
