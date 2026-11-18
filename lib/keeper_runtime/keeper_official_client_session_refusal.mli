(** Why an official-client runtime (Antigravity, Claude Code, Codex, Muse)
    refused a turn because of the state of its durable vendor session, before
    provider dispatch (#38402).

    These refusals used to leave the runtime as
    [Agent_core.Error.Config (InvalidConfig _)]. The receipt then asked the
    operator to edit the runtime's toml, which never helps, and the lane
    stopped at the first candidate even where the refusal named a limit of
    that one client. The producer now names the refusal, and every reader
    (terminal reason, receipt, failure route, lane walk) decides per
    constructor. *)

type t =
  | Gate_continuation_unresumable
      (** A Gate continuation names a vendor session, turn, runtime or tool
          surface that the stored session no longer holds. The continuation
          is bound to that session, so no candidate can take it. *)
  | Gate_context_frontier_missing
      (** A Gate continuation would resume a vendor session that has no
          acknowledged canonical-context frontier, so unchanged history
          cannot be shown. *)
  | Gate_canonical_context_changed
      (** A Gate continuation would resume a vendor session whose canonical
          history or core instructions changed since it settled. A fresh
          session would run the effects and then fail completion. *)
  | Claim_held_by_this_process
      (** The stored session holds an incomplete claim owned by this same
          process epoch: another turn of this process has it open. *)
  | Task_reference_unsupported
      (** The client cannot carry a historical task reference without
          replaying it as user input (Antigravity). Another candidate can. *)
  | Task_reference_unbound
      (** The historical task reference is not bound to the operation's
          original vendor session. *)

val all : t list
(** Every constructor, in declaration order. *)

val code : t -> string
(** The turn terminal reason code. Distinct per constructor. *)

val of_code : string -> t option
(** Exact inverse of {!code}, for terminal reason codes read back from
    receipts. *)

val to_string : t -> string

(** What the lane walk does after this refusal. *)
type lane_step =
  | Next_candidate  (** the refusal is a limit of this candidate's client *)
  | Stop_lane  (** the refusal is a fact of the session; every candidate meets it *)

val lane_step : t -> lane_step

val core_error : t -> Agent_core.Error.t
(** [Internal_carried] whose carrier holds this value. *)

val of_core_error : Agent_core.Error.t -> t option
(** [Some] only for an error built by {!core_error}. *)

val should_try_next : Agent_core.Error.t -> bool
(** [true] only for a refusal whose {!lane_step} is [Next_candidate]. *)
