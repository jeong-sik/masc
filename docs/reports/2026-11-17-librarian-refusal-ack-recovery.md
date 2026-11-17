# Recover a receipt-proved refusal after a partial ACK

A permanent counterpart-capacity refusal can stop after writing its actual
range receipts and acknowledging external input, before advancing the official
history position. The next ordinary wake used the initial publication lock
scope again. That scope required the captured external preparation and history
prefix, so the wake failed when its own previous ACK or normal retention had
already changed them.

Refusal settlement now chooses its source lock scope from the actual receipt
state. A first write still requires the strict original source and preparation.
When all original range receipts already exist, recovery uses the existing
settlement scope instead. It rereads those receipts, the original owner record
and its effect fence under the same source locks. Missing or partial receipts
cannot grant recovery authority. The shared settlement path separately checks
the captured or already settled frontiers before any remaining ACK or position
write. Neither path repeats inference or a proved Memory write.

The added configured-worker fixture obtains an actual provider capacity refusal
and actual empty-disposition range receipts. It interrupts after the external
ACK, removes the official fragment prefix, then uses an ordinary worker wake to
finish the official ACK and archive the same original. It also checks that the
recovery changes neither the Memory revision nor the provider request count.
The interruption hook models this boundary; it is not a process-kill test.

This change does not resolve a Cut by abandoning its input. Cut continuation
still requires its separate resolution authority and preserved original.

The preceding candidate's targeted Test run 43910663654 failed during compilation
on head d188839326eb006361199ad465246a4d64d9423f, before either requested suite ran.
The record-field order and missing test module alias were corrected in the base
of this change. This candidate has not yet passed type or behavior checks, been
installed, or recovered the outstanding live originals.
