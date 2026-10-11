# Pending file input belongs to the shared draft

Base: `faac5abdcc0d55ca28d88f113891ecc882c654ee` (#42418).

## Reproduction

A persisted ChatComposer with authored text selects a file while the attachment reader is deferred. The actual native file-change event invokes collectAttachments; Enter on the previous source calls onSend with text alone, before the selected file resolves. The corrected fixture reproduces this failure against the exact parent product source and passes on the candidate. An initial fixture using testing-library fireEvent.change did not invoke collectAttachments and is explicitly excluded from failure evidence; an initial missing act import was also a fixture error.

## Change

The immutable credential/Keeper draft snapshot includes identities of active file preparation work. Admission happens synchronously before reading. Every composer sharing that draft shows preparation status and waits to submit until admitted work settles. Completion updates the captured credential/Keeper draft even when its initial composer unmounts, retaining ordinary edits made during file reading. Failure releases its exact work identity without clearing authored input. Independent review identified duplicate IDs from parallel collectors using the same prior attachment list. A real deferred composer fixture completed two identical-file results in reverse order and reproduced two attachments with only one unique ID. Completion now uses the existing identity allocator inside the canonical snapshot update, allocating each prepared result against the latest owned attachments. Both authored files remain distinct. Errors are presented only while the originating component, credential and host context remain current. Nonpersisted composers retain local active work identities with a synchronous send guard.

## Verification and limits

262 focused store/composer/Keeper/Copilot tests passed. Focused DOM scenarios cover premature Enter, remount and text edits during read, reader failure retaining text, and parallel completion assigning distinct IDs. TypeScript noEmit and diff-check passed before final source review.

This is in-process DOM with a deferred attachment reader; it does not prove actual provider runtime or installed UI/screenshots. Voice capture/transcription ownership, complete attachment capacity/order reconciliation, cancellation/recovery UI and full active goal remain separate work. Historical source approvals do not certify this changed scope. CI, formal approval and merge are not established.
