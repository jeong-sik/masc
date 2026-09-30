# A record reference cannot replace captured-deck equality

Review found that both earlier rotation journeys changed the record digest as
well as the deck bytes. They could therefore pass even if the grader's separate
immutable snapshot comparison was removed.

The refusal-and-recovery scenario now changes only the answer inside its fact.
It explicitly preserves the entire cited record, source ID, declared incarnation
and fact ID while requiring different captured-deck evidence. Current code
refuses the stale question without a grade or score and accepts the fresh
question tied to the replacement capture.

`stdio-tests.log` retains 27 successful Python package-worker stdio scenarios.
`snapshot-comparison-removed.log` retains the strengthened journey failing
against an isolated grader mutation: the stale answer is incorrectly confirmed.
`mutation.patch` removes only snapshot URI/SHA equality; the source/incarnation/
fact-ID join and record comparison stay present. `provenance.json` records the
parent candidate, commands, exact source hashes and mutant hash. The earlier
snapshot-binding and question-identity evidence folders remain unchanged.

This is local Python stdio evidence with synthetic sources. No native build,
Docker image, host, Keeper, deployment, network call or CI run was performed.
