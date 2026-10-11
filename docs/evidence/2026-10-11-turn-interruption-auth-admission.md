# Turn interruption outcome admission

Base: 219aaf4b9399645e354e011b2ac195420a08a1df (#42400).

An old-auth interruption success reported success and cleared replacement-scope errors; an old-auth failure rejected and published its error. Both deferred result fixtures failed before repair. A credential transition at the local-cancellation await also reached the interruption POST under replacement credentials. The initial fixture omitted a valid default response and produced a fixture TypeError; that exception is excluded from product failure evidence. The fixture now returns a valid signal result and verifies no POST after withdrawal.

Capture interruption authentication before local cancellation and recheck after that await, after the POST result and in its failure path. Superseded observations do not publish errors or signal success. Replace the boolean action result with a closed outcome for signalled, not_signalled and authentication_superseded, carrying the admitted revision.

Independent review identified the boolean false consumer as another bug: it asserted there was no active turn after authentication withdrawal. Both actual UI consumers now check the outcome kind and revision before notifications; signal success describes a sent signal rather than completed turn termination. The toolbar error path checks its captured revision. The operation panel checks authentication before follow-up refresh acquisition and error publication after awaits. Waiting-inventory fetch isolation itself is outside this change.

Validation: 141 focused keeper-actions and keeper-shared tests, TypeScript noEmit and whitespace checks passed. Two actual DOM callback fixtures assert no notification for superseded or stale signalled results. These are behavioral fixtures, not live browser or screenshot evidence. Independent source review of the four implementation/test files passed; final committed scope review is separate. No formal GitHub approval, CI, merge, installation, actual server interruption, provider parity or runtime screenshot proof is claimed.
