# PR #41043 consumed-fragment reconciliation

The published v0.49.0 tag `8304fa2124ca3100958f6df8fb512963538678ab` already records #41043 in [its detailed notes](https://github.com/jeong-sik/masc/blob/v0.49.0/docs/releases/v0.49.0-details.md). Current baseline `c4fb7990b20f9a2cc356cc751f911cc2355cd0b6` differs from its direct parent only by the restored fragment, with no new implementation or fixture. That fragment must not advertise an old repair again when the next bump assembles Unreleased. It is removed here; the published notes and original commits remain unchanged.

The actual published #41043 entry is shorter than the current parent’s archived full fragment (its drop/move clause is not in that tag entry). This reconciliation relies on the current PR’s zero implementation/fixture delta and the consumed-fragment deletion in `62e106bfdc3a67aff06aa6908a2984d08f16505d`, not a false claim that those note strings are identical.

Only documentation/changelog changes and real local parent merges are included. No build, behavior test, CI, release selection, tag or TerminalBench was run. Earlier evidence remains scoped to its recorded candidate.
