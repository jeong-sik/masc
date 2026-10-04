# #41197 canonical-parent integration

Merged the current #40960 repair into local candidate `9802ec2880` while preserving both child reply-minimum cases and all six new parent regressions. Only the test registration list conflicted; both sides were retained. Focused worker compilation succeeded and all 43 cases passed in 7.652 seconds. Store source equals parent c5d6ec3e47499e87e2113ab07f5bb3e3f1e35013; the child reply-minimum implementation is unchanged. Logs and executable hash are pinned in the manifest. No hosted CI, full regression, release, or Terminal-Bench result is claimed.
