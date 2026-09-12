# DOS counter evidence

`STATE.BIN` is exactly eight bytes: ASCII `LANE`, little-endian uint16 format
version `1`, then a little-endian uint16 counter. The guest increments modulo
65536 for each N key read by BIOS. The adapter never writes this counter after
boot. During bootstrap the supplied virtual file contains the distinct sentinel
`PEND0000`; it is not a valid observation.

The VGA image is 320×200. The background is black. A white rectangle occupies
x=[16,304), y=[32,48). The green bar occupies x=[16,17+(counter mod 256)),
y=[80,96). The file is closed before the guest draws the corresponding image.
The adapter waits until both observations agree before publishing a verified
capture. PNG palette intensity depends on the backend; channel relationships and
rectangle positions are checked, rather than a screenshot hash alone.

Each capture has the host instance incarnation and a capture sequence. Intermediate
frame callbacks are coalesced. Coverage describes the latest verified capture,
not every frame or every CPU instruction. `actor=null` identifies no LLM actor;
the host's action receipt supplies the requesting Keeper's execution provenance.

`confirmed` proves the stated guest-file/bar observation. `failed_before_effect`
means this request did not send a key. `outcome_unknown` means a key might have
been applied and must not be automatically replayed. Read these typed fields,
not prose matching, to distinguish the cases.

State exists in the package's own WASM memory. There is no machine restore, fork,
commercial game, external Browser tab, host keyboard focus or remote disk.
