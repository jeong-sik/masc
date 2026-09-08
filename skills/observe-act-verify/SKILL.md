---
name: observe-act-verify
description: Learn and operate an unfamiliar turn-based interface using screen observation, ordinary input, checkpoints, and verified state changes.
---

# Observe, act, verify

Use this when the next action depends on an unfamiliar game or application screen. Use the environment's existing observation, image-reading, input and save tools; a new domain-specific tool is not needed for each menu command.

## Discover a transition

Capture the current surface and its identity: application/session, frame or revision, and image artifact. Read the visible prompt, selected item and relevant values. An OCR interpretation is a hypothesis: preserve uncertain text as uncertain, and prefer an unambiguous option number over a guessed translation.

When asking another model to read an image, first ask for the visible text, prompt, selection and values without supplying the screen you expect to see. Compare that independent reading with the prior state afterward. An expected outcome in the question can bias the reading toward an outcome the image does not show.

For a small or ambiguous prompt, narrow the image question to that visible region and ask only for literal transcription with line breaks and unreadable characters marked. Do not bundle this with a scene summary, translation, proposed action, or questions about messages you expect to exist. Use coordinates only when they refer to the actual image dimensions. Compare the returned text with the source before interpreting it: a fluent answer, successful image call, or repeated answer does not establish accuracy. A region-specific query can reduce invented context, but a successful example does not validate the reader on every screen.

A visible candidate, highlight or confirmation prompt is not a committed selection. Confirm the result on the following screen before naming a checkpoint as a completed choice or reporting that the choice took effect. An unconfirmed prompt can still be saved under a name that describes the observed prompt. A checkpoint name records an interpretation; it is not evidence that the interpretation is true. Likewise, a populated telemetry array does not prove every listed item is active or visible.

Choose an action that answers a concrete question or advances the user's task. State what visible change would support success. Execute it, then capture again and compare the resulting prompt and values. Do not interpret a successful input call, increasing frame counter or a stationary program counter as completed work.

Differentiate an action that takes effect immediately from one that opens another prompt. Stop a learned sequence at any new decision or unrecognized screen. Text entry is an ordered sequence of key edges; a list of simultaneously held keys is not a string. Use a composition's explicit ordering edges for a known sequence when available, keeping decisions between observations model-directed.

## Resume after an observation boundary

A turn can end after a successful capture but before its image is interpreted. Preserve the returned artifact handle, surface identity and the next unfinished step. On resume, read that exact artifact to finish interpreting the captured state instead of restarting the capture step by habit. Copy the handle from the successful receipt; do not reconstruct it from memory or a checkpoint name. If the artifact is unavailable, obtain a new capture and use its returned handle.

Interpreting a retained artifact is not permission to act on stale state. Before input, establish whether the same session is still yours and whether it has advanced since that capture, using available current revision or caller-tagged action evidence. If the state has advanced or its continuity is unknown, capture and interpret the current state before acting. A new capture does not establish driving ownership. An unchanged turn-based prompt may be waiting for input; repeated observation is useful only when there is a concrete reason to expect new information. A runtime repetition notice describes prior calls, not a promise that future observations cannot change.

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

## Isolate a failed action

Preserve the failing state before recovery when a snapshot tool is available. Keep it separate from the last known good state. In an isolated session, replay the accepted actions from that same good state, then compare a second run that omits only the suspected action. Preserve both input lists, source identity and resulting observations. Rejected calls are not accepted actions; verify replay tools actually consumed the expected events and reached the intended final state before comparing outcomes.

A different result supports the suspected action's involvement in that sequence. It does not establish a universal cause or prove the entire workflow is fixed. Record both the demonstrated boundary and remaining uncertainty. Do not use values observed after corruption as progress evidence until a coherent state is independently confirmed.
