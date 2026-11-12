(** The last time a provider refused a credential, per credential scope.

    A provider that answers "this credential is not valid" (HTTP 401, an
    official client reporting it is not logged in) states a fact about the
    credential, not about one turn. The Keeper walk rotates past it within the
    turn and keeps nothing ({!Keeper_turn_driver}: a credential denial is no
    ordering evidence), so the runtime list showed such a runtime exactly as
    it showed a healthy one (2026-11-12: one Keeper failed 49 turns on an
    invalid API key while its runtime row read as available).

    This table is an observation for operators. Nothing orders, demotes or
    holds a candidate from it. An entry stays until a call on the same scope
    gets an answer; the moment it was noted is returned with it, so a reader
    sees how old the observation is. The table lives in process memory. *)

val note_refused : scope:Runtime_quota_window.scope -> at:float -> unit
(** The provider refused the credential of [scope] at [at] (Unix seconds).
    A later refusal replaces the moment. *)

val note_answered : scope:Runtime_quota_window.scope -> unit
(** A call on [scope] got an answer, so its credential was accepted and the
    earlier refusal no longer describes it. *)

val refused_at : scope:Runtime_quota_window.scope -> float option
(** When [scope]'s credential was last refused with no answer since. *)
