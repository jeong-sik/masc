# Approval call authority

Base: `a983c031e1082df6db93dec5443b82b892fddd60` (rebuilt L38 tip; original base `6163c5e1472e81319ea27368a9d0ac2667875ac0`).

Approval_requested used call ID to attach arguments without filtering native
activity, earlier attempt or earlier segment. Restrict argument enrichment to
eligible MASC execution calls in the current attempt and segment; preserve the
explicit approval prompt when the call is missing or ambiguous.

The settlement/admission half of the original change (approval-ID correlation
diagnostics) is not ported: this base keys approvals by call ID only, and the
settlement guard for a superseded call is already present. Approval-ID
correlation stays separate work.
