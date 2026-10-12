# Approval call authority

Base: 6163c5e1472e81319ea27368a9d0ac2667875ac0.

Approval_requested used call ID to attach arguments without filtering native
activity, earlier attempt or earlier segment. Restrict argument enrichment to
eligible MASC execution calls in the current attempt and segment; preserve the
explicit approval prompt when the call is missing or ambiguous. Approval_settled
previously ignored its supplied call ID. A matching approval ID with conflicting
call correlation now records a diagnostic and leaves its admission pending;
matching correlation still settles normally. Approval ID remains the primary
identity and an unrelated old approval cannot clear a newer wait.

Artifacts: /tmp/masc-tui-approval-call-authority-20261012/.
Actual approval event arms and actual unique-call lookup/update functions are
interpreted with minimal typed call/state/event surroundings. Parent exits 1 for
foreign-authority/old-call argument mutation. A second parent probe isolating
settlement exits 1 for conflicting-call admission clearing. Current exits 0 for
native, old attempt and old segment preservation, current MASC argument update,
conflicting settlement refusal and matching settlement acceptance.
This does not execute provider ingress, canonical approval ID decoding, full
transcript reduction or UI rendering. Prompt ordering/replay tombstones are not
certified by this change.

Two changed OCaml files passed syntax-only parsing and diff whitespace check.
Two registered state fixtures are unexecuted. Full typecheck/build, approval
producer integration, journal replay, installed runtime, UI/screenshots, CI,
formal approval and merge remain unverified.
