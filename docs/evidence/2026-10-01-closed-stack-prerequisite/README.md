# Closed native-stack prerequisite admission

The included lower member is `closed, merged=false`, not an already merged prerequisite. On the prior scope implementation, the new check-mode and fake-write test both failed: the guard returned exit0/WOULD MERGE or an asynchronous fake receipt. GitHub documents that a closed middle PR preserves stack membership and blocks upstack merges: https://docs.github.com/en/pull-requests/how-tos/merge-and-close-pull-requests/troubleshooting-stacked-pull-requests#you-closed-a-pull-request-in-the-middle-of-the-stack .

The shared snapshot now rejects that state before review admission/submission. The five focused tests passed after the patch; this includes both refusal modes, an already merged lower member, a closed upper member outside the selected scope, ordinary selected+downstack scope, and a non-native bottom PR. The named cases, file hashes and original outputs are in execution.json and before/after.output. Source/test bytes correspond to commit19b773c67e605dc53ed16ac286f4754a379fd43e; the evidence/changelog commit does not change them.

All GitHub calls used the isolated fake transport. This proves script admission behavior, not a real server approval bypass, a real merge, or the caller/selected PR of the historical #40379 incident. #40383 had already added the included-member approval checks; this follow-up corrects the closed/merged distinction. No Dune build, CI dispatch or production changes occurred.

After parent #40399 merged, main was integrated at b25b57c07c81b477519eb41fec72aca141c76dba. The entire scripts/review Git tree remains identical to tested19b773c67e; execution.json records the tree identity. No test/dune change remains relative to that main. This is input correspondence, not a second execution.
