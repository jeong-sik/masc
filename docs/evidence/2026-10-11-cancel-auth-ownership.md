# Cancellation authentication ownership

Base: 70603a573a83689c081a9f42423a3686dcac41a7 (#42398).

Five failure scenarios were reproduced before this repair: an old-auth successful cancellation removed current recovery tracking and cleared the current error; an old-auth failure replaced the current error; an older pending cancellation prevented a new-auth cancellation for the same operation; and an accepted, aborted send resumed operation recovery under replacement credentials after its cancellation await. Independent review identified a fifth sequence: same-auth cancellation remains pending while a failed stream completes history reconciliation; stream cleanup removed the cancellation owner and discarded its later valid receipt. The actual send/cancel fixture reproduced retained recovery tracking before repair. Cancellation now owns its lifetime independently of stream cleanup.

Pending cancellation ownership now binds the exact Keeper/operation pair, admitted authentication revision and unique request token. Only that owner can publish cancellation results or errors. A new authentication revision may start its own cancellation while an older request remains pending. Old cleanup cannot delete the replacement request. The aborted send rechecks stream admission immediately after awaiting cancellation, preserving received raw assistant content and accepted recovery records on withdrawal.

Current source validation: 111 keeper-actions behavioral tests passed; TypeScript noEmit and git diff --check passed. These checks verify request, state and recovery decisions. They do not establish installed runtime behavior, actual screenshots, provider parity, formal GitHub approval or merge. Independent source review is in progress.
