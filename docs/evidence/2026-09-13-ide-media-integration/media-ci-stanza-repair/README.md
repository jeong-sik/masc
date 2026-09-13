# Duplicate-stanza failure and repaired-head CI request

Test 34705688030 at 31bdf7597b failed before native target execution because
`test_verifier_official_client` was declared twice in `test/dune`. The raw excerpt
retains both reported Dune failures. Remote commit
`7bd85f6bd6924a0619d7113f3347f0d0b19346d3` independently removed one identical
stanza. This worktree fast-forwarded that change; both agent and root reviewed
its exact diff and found no concrete P1/P2 issue.

The existing Dune stanza parser expanded 1,327 executable declarations with no
remaining duplicate name; each of the nine requested native targets appears
once. The tenth target is the Python setup alias. No native behavioral result
follows from these static checks.

After confirming local and remote source identity, the same ten-target Test
34707024488 and branch artifact Release 34707026611 were dispatched once.
Their handles both name the repaired source head. No outcome has been observed.
`declaration-audit.json` was captured before those requests; `dispatch.json`
records the subsequent handles. This evidence is deliberately left as a
follow-up change so it does not change the CI target source head.
