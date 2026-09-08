---
name: observe-act-verify
description: Learn and operate an unfamiliar turn-based interface using screen observation, ordinary input, checkpoints, and verified state changes.
---

# Observe, act, verify

Use this when the next action depends on an unfamiliar game or application screen. Use the environment's existing observation, image-reading, input and save tools; a new domain-specific tool is not needed for each menu command.

## Discover a transition

Capture the current surface and its identity: application/session, frame or revision, and image artifact. Read the visible prompt, selected item and relevant values. An OCR interpretation is a hypothesis: preserve uncertain text as uncertain, and prefer an unambiguous option number over a guessed translation.

When asking another model to read an image, first ask for the visible text, prompt, selection and values without supplying the screen you expect to see. Compare that independent reading with the prior state afterward. An expected outcome in the question can bias the reading toward an outcome the image does not show.

A visible candidate, highlight or confirmation prompt is not a committed selection. Confirm the result on the following screen before naming a checkpoint as a completed choice or reporting that the choice took effect. An unconfirmed prompt can still be saved under a name that describes the observed prompt. A checkpoint name records an interpretation; it is not evidence that the interpretation is true. Likewise, a populated telemetry array does not prove every listed item is active or visible.

Choose an action that answers a concrete question or advances the user's task. State what visible change would support success. Execute it, then capture again and compare the resulting prompt and values. Do not interpret a successful input call, increasing frame counter or a stationary program counter as completed work.

Differentiate an action that takes effect immediately from one that opens another prompt. Stop a learned sequence at any new decision or unrecognized screen. Text entry is an ordered sequence of key edges; a list of simultaneously held keys is not a string. Use a composition's explicit ordering edges for a known sequence when available, keeping decisions between observations model-directed.

## Retain what was learned

Record a reusable transition with:

- Precondition: the visible prompt and relevant application/version or checkpoint.
- Input: exact keys/arguments, order, and release behavior.
- Observed outcome: next prompt and changed values, with before/after artifacts.
- Confidence: observed, inferred, or unresolved; name the missing evidence.

Keep the current session's progress separate from the reusable procedure. A saved old screen is a reference, not a new observation. Reuse its interpretation only when the actual current image content matches and no relevant hidden state is required.

## Continue safely

For a shared session, agree with the current driver on a handoff before sending input or restoring. A cooperative agreement is not an enforced lease: if another caller intervenes, discard the pending input sequence, observe again and coordinate who continues. Being loaded or being watched does not by itself establish ownership.

Use an available checkpoint before an uncertain irreversible decision and at meaningful progress boundaries. When saving replaces a named slot, choose a fresh identifier for each retained checkpoint and verify the successful save receipt identifies that slot and the intended state. A prefix alone does not prevent overwriting. Restore only after confirming the shared session is still yours to drive; other participants may have advanced it after the checkpoint.

On an unexpected result, retain the last good checkpoint and the failing input/observation. Try a different action only with a new hypothesis or evidence. A transport timeout does not prove the action failed: observe the destination before repeating a write. If another participant could have acted, the resulting screen alone does not attribute the change to your timed-out call; use an available caller-tagged receipt or action history, otherwise leave attribution unresolved. Empty polling and repeated blind input are not progress.

For a game, distinguish a menu, a completed turn, defeat, an observer-only ending and the player's requested victory. Report the outcome that was actually observed.
