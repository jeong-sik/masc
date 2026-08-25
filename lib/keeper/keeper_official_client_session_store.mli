(** Durable current-owner state between one Keeper and one official subscription
    client session.

    This is not an AGENT_CORE checkpoint. The external client owns its transcript;
    MASC owns the exact claim, observation, recovery, and settlement phase needed
    to avoid silently duplicating an externally admitted turn. *)

type client_kind =
  | Codex
  | Claude_code
  | Antigravity

type settlement =
  { session_id : string
  ; turn_id : string
  }

(* The provider rejected the bootstrap input itself as over capacity. Not
   auto-superseded by [plan_claim]; reopened only by [resolve_recovery].
   See the RFC comment on the implementation for the reason split. *)
type input_rejection_reason =
  | Bootstrap_floor_exceeded
  | Effect_fenced

type recovery_failure =
  | Transient_spawn_failed
  | Owner_stopped_turn
  | Transport_interrupted
  | Protocol_failed
  | Provider_rejected
  | Input_rejected of input_rejection_reason
  | Host_hook_failed
  | State_persistence_failed
  | Process_restarted

type failure_disposition =
  | Transient
  | Ambiguous
  | Fatal

val failure_disposition : recovery_failure -> failure_disposition

(** Wire label of a failure; the inverse of the decoder used by [of_yojson].
    Projections (dashboard) reuse this instead of restating labels. *)
val recovery_failure_to_string : recovery_failure -> string

type recovery_required =
  { recovery_id : string
  ; previous_settlement : settlement option
  ; observed_session_id : string option
  ; observed_turn_id : string option
  ; owner_epoch : string
  ; failure : recovery_failure
  ; detail : string
  ; required_at : float
  }

type phase =
  | Ready
  | Start of
      { owner_epoch : string
      ; previous_settlement : settlement option
      }
  | Active of
      { owner_epoch : string
      ; session_id : string
      ; previous_settlement : settlement option
      }
  | Turn_inflight of
      { owner_epoch : string
      ; session_id : string
      ; turn_id : string option
      ; previous_settlement : settlement option
      }
  | Recovery_required of recovery_required
  | Settled of settlement

type recovery_resolution =
  | Retry_previous
  | Restart_fresh

type recovery_resolution_application =
  | Applied
  | Replayed

type recovery_resolution_error =
  | Invalid_resolved_by
  | Invalid_resolved_at
  | Session_missing
  | Session_changed
  | Recovery_id_changed
  | Recovery_not_required
  | Retry_previous_unavailable
  | Resolution_conflict
  | Store_unavailable of string

type recovery_resolution_record =
  { recovery_id : string
  ; failure : recovery_failure
  ; resolution : recovery_resolution
  ; resolved_by : string
  ; resolved_at : float
  }

type transient_release_record =
  { failure : recovery_failure
  ; owner_epoch : string
  ; released_at : float
  }

type t =
  { client_kind : client_kind
  ; runtime_id : string
  ; phase : phase
  ; turn_count : int
  ; tool_surface_sha256 : string
  ; last_recovery_resolution : recovery_resolution_record option
  ; last_transient_release : transient_release_record option
  ; updated_at : float
  }

type claim_plan =
  { previous_settlement : settlement option
  ; turn_count : int
  ; required_tool_surface_sha256 : string option
  }

val process_epoch : unit -> string
(** One UUID for the current MASC process. A durable incomplete claim owned by
    another epoch is a restart ambiguity, not an active same-process turn. *)

val path : base_path:string -> keeper_name:string -> (string, string) result

val tool_surface_sha256 :
  native_posture:Runtime_native_tools.posture -> Agent_core.Tool.t list -> string
(** Stable digest of the exact typed dynamic-tool surface, the keeper's
    native-tool posture, and official-client context-message schema. Tool
    order, parameter order, and JSON object field order do not affect the
    digest; tool semantics, posture, and history framing do. A framing or
    posture change therefore starts a fresh provider conversation instead of
    resuming a session that cannot receive the new surface. *)

val load : base_path:string -> keeper_name:string -> (t option, string) result
(** Missing state is [Ok None]. Malformed, retired, or ambiguous state is an
    error and never degrades to a new session. *)

val plan_claim :
  expected:t option ->
  client_kind:client_kind ->
  runtime_id:string ->
  (claim_plan, string) result
(** Pure claim planning shared by every official-client adapter. The plan is
    the SSOT for fresh versus resumed execution, the next turn ordinal, and
    whether the prepared tool surface must match a settled session. *)

val reconcile_tool_surface : claim_plan -> tool_surface_sha256:string -> claim_plan
(** Fold a moved tool surface into the plan. A settled session whose stored
    digest differs from the prepared one is not resumable and cannot be
    recovered -- [Settled] never becomes [Recovery_required], so no id exists
    for the resolve endpoint. Rather than refusing the turn, the plan becomes
    the fresh-session plan [plan_claim] already produces for a changed
    [client_kind] or [runtime_id]: what the prior session settled against no
    longer describes this execution. Every adapter must apply this before
    [claim], and [claim] applies it again so a caller cannot skip it. *)

val claim :
  base_path:string ->
  keeper_name:string ->
  expected:t option ->
  client_kind:client_kind ->
  owner_epoch:string ->
  runtime_id:string ->
  tool_surface_sha256:string ->
  updated_at:float ->
  (t, string) result
(** Claim the next exact turn. A terminal binding may start fresh when its
    declared client kind or runtime id changes. Resuming the same settled
    client/runtime requires an identical tool surface. A same-process Start,
    Active, or Turn_inflight phase rejects a concurrent claim. A completed
    failure observation is superseded atomically by a fresh-session claim and
    never requires operator resolution before execution. *)

val mark_active :
  base_path:string ->
  keeper_name:string ->
  expected:t ->
  session_id:string ->
  updated_at:float ->
  (t, string) result

val mark_turn_starting :
  base_path:string ->
  keeper_name:string ->
  expected:t ->
  session_id:string ->
  updated_at:float ->
  (t, string) result

val mark_turn_started :
  base_path:string ->
  keeper_name:string ->
  expected:t ->
  session_id:string ->
  turn_id:string ->
  turn_count:int ->
  updated_at:float ->
  (t, string) result

val settle :
  base_path:string ->
  keeper_name:string ->
  expected:t ->
  session_id:string ->
  turn_id:string ->
  updated_at:float ->
  (t, string) result

val require_recovery :
  base_path:string ->
  keeper_name:string ->
  expected:t ->
  failure:recovery_failure ->
  detail:string ->
  required_at:float ->
  (t, string) result
(** Convert the exact incomplete claim into an operator-visible failure
    observation. The next claim may supersede it atomically; an operator may
    still resolve it first to choose the previous settlement or a fresh start. *)

val release_transient :
  base_path:string ->
  keeper_name:string ->
  expected:t ->
  failure:recovery_failure ->
  released_at:float ->
  (t, string) result
(** Release one exact incomplete claim only when [failure] is classified
    [Transient]. The previous settlement, if any, is restored atomically. *)

val reconcile_process_restart :
  base_path:string ->
  keeper_name:string ->
  expected:t ->
  current_owner_epoch:string ->
  required_at:float ->
  (t, string) result
(** Convert an incomplete claim owned by a different process epoch into an
    explicit ambiguous recovery. Same-epoch claims remain occupied. *)

val resolve_recovery :
  base_path:string ->
  keeper_name:string ->
  expected:t ->
  recovery_id:string ->
  resolution:recovery_resolution ->
  resolved_by:string ->
  resolved_at:float ->
  ((t * recovery_resolution_application), recovery_resolution_error) result
(** Resolve one exact recovery claim with compare-and-swap authority.
    [Retry_previous] restores the last settled session and drops only the turn
    that failed, so the next claim re-attempts the same ordinal against it.
    [Restart_fresh] abandons the conversation, so the ordinal restarts with it
    and the next claim asks for ordinal 1 -- the same reset an automatic
    supersede performs. Repeating the same recovery id and decision returns the
    already committed binding as [Replayed]; a different decision for the same
    recovery id is a conflict. *)
(** Every phase change is a process-safe durable compare-and-swap followed by
    exact read-back. Any incomplete phase blocks a later automatic claim. *)
