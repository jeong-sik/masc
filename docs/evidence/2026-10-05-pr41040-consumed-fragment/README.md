# PR #41040 consumed-fragment reconciliation

The published v0.49.0 tag `8304fa2124ca3100958f6df8fb512963538678ab` already records #41040 in [its detailed notes](https://github.com/jeong-sik/masc/blob/v0.49.0/docs/releases/v0.49.0-details.md). Current baseline `199eeca06bd69336307422eec9a3663bd448d50b` differs from its direct parent only by the restored fragment, with no new implementation or fixture. That fragment must not advertise an old repair again when the next bump assembles Unreleased. It is removed here; the published notes and original commits remain unchanged.

Only documentation/changelog changes and real local parent merges are included. No build, behavior test, CI, release selection, tag or TerminalBench was run. Earlier evidence remains scoped to its recorded candidate.
