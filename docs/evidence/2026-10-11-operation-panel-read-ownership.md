# Operation panel read and action ownership

Base: 633b7ee2d1d1cc5c70ef4a98a01087b92b477b49 (#42403).

Two actual panel fixtures reproduced an old successful or failed list read replacing newer queued-operation rows. Each read now owns an AbortController and exact mounted panel scope. Publication checks the current Keeper, authentication revision, panel incarnation and read owner. Replacement/unmount cleanup aborts reads, and the list API accepts that caller signal. Cached snapshots are scoped by Keeper/revision and are masked outside that scope.

Independent review found mutation aftermath was still unscoped. An actual Keeper A to B fixture reproduced the late A mutation failure removing B's current operation row. Mutations now capture exact panel/action ownership for follow-up acquisition, errors and cleanup. Old finally cannot clear a newer action, and the operation-panel interruption callback checks panel ownership before notifications.

The unified snapshot introduced two further regressions. A mutation catch refreshed canonical queue rows then its captured error setter restored old rows; a subsequent failed push read erased the current mutation error. Both were reproduced through actual panel handlers. Functional updates now preserve current exact-scope rows when changing only error, and preserve current error on reads requested with clearError=false. Distinct auth, Keeper-change and remount fixtures verify read revocation and retained replacement rows.

Response headers alone were not the resource lifetime: the old list API detached upstream cancellation before response.json completed. A real ReadableStream response fixture reproduced external abort failing to reach the internal fetch signal while the body was pending. The list now uses the existing fetchWithTimeout consume overload, preserving cancellation and resource timeout through body decoding and protocol validation. No new timeout or matching heuristic was introduced.

Validation: 82 focused keeper-shared and api/keeper tests passed; TypeScript noEmit and whitespace checks passed. Six failure scenarios were directly reproduced across stale read, mutation, snapshot and pending-body boundaries. Independent review of the four source/test files passed; final committed full-scope review is separate. DOM/API/body fixtures are not actual browser screenshots, deployed runtime, formal GitHub approval, CI, merge or live server evidence. Complete provider/chat goal remains unproven.
