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
          surface that the stored session no longer holds. Only the
          continuation's own runtime reaches this check
          ({!Continuation_on_other_runtime} answers every other candidate
          first), so the mismatch is a fact of the stored session, which no
          candidate changes. *)
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
          original vendor session. The check compares the continuation
          checkpoint with the reference's original turn; neither depends on
          the candidate, so every candidate meets it. *)
  | Continuation_on_other_runtime
      (** A Gate or checkpoint continuation is bound to the official-client
          runtime that settled its vendor session, and this lane candidate is
          another runtime. The turn driver refuses it before the runtime
          adapter runs, so no task reference or Gate session check is reached.
          The candidate that is the continuation's runtime can take it. *)

val all : t list
(** Every constructor, in declaration order. *)

val code : t -> string
(** The turn terminal reason code. Distinct per constructor. *)

val to_string : t -> string

(** What the lane walk does after this refusal. *)
type lane_step =
  | Next_candidate
      (** the refusal is a fact of this candidate: its client or its runtime
          identity *)
  | Stop_lane
      (** the refusal is a fact of the session or of this process; every
          candidate that reaches the check meets it *)

val lane_step : t -> lane_step

val core_error : t -> Agent_core.Error.t
(** [Internal_carried] whose carrier holds this value. *)

val of_core_error : Agent_core.Error.t -> t option
(** [Some] only for an error built by {!core_error}. *)

val should_try_next : Agent_core.Error.t -> bool
(** [true] only for a refusal whose {!lane_step} is [Next_candidate]. *)
