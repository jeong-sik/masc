(** Durable current-owner state between one Keeper and one official Codex thread.

    This is not an OAS checkpoint. Codex owns the thread transcript; MASC owns
    the exact settlement phase needed to resume without silently duplicating an
    externally admitted turn. *)

type settlement =
  { thread_id : string
  ; turn_id : string
  }

type recovery_failure =
  | Transport_interrupted
  | Protocol_failed
  | Provider_rejected
  | Host_hook_failed
  | State_persistence_failed

type recovery_required =
  { recovery_id : string
  ; previous_settlement : settlement option
  ; observed_thread_id : string option
  ; observed_turn_id : string option
  ; failure : recovery_failure
  ; detail : string
  ; required_at : float
  }

type phase =
  | Ready
  | Start of { previous_settlement : settlement option }
  | Active of
      { thread_id : string
      ; previous_settlement : settlement option
      }
  | Turn_inflight of
      { thread_id : string
      ; turn_id : string option
      ; previous_settlement : settlement option
      }
  | Recovery_required of recovery_required
  | Settled of settlement

type recovery_resolution =
  | Retry_previous
  | Restart_fresh
  | Adopt_verified of settlement

type recovery_resolution_record =
  { recovery_id : string
  ; failure : recovery_failure
  ; resolution : recovery_resolution
  ; resolved_by : string
  ; resolved_at : float
  }

type t =
  { runtime_id : string
  ; phase : phase
  ; turn_count : int
  ; tool_surface_sha256 : string
  ; last_recovery_resolution : recovery_resolution_record option
  ; updated_at : float
  }

val path : base_path:string -> keeper_name:string -> (string, string) result

val tool_surface_sha256 : Agent_sdk.Tool.t list -> string
(** Stable digest of the exact typed dynamic-tool surface. Tool order,
    parameter order, and JSON object field order do not affect the digest;
    names, descriptions, parameter semantics, and input schemas do. *)

val load : base_path:string -> keeper_name:string -> (t option, string) result
(** Missing state is [Ok None]. Malformed, retired, or ambiguous state is an
    error and never degrades to a new thread. *)

val claim :
  base_path:string ->
  keeper_name:string ->
  expected:t option ->
  runtime_id:string ->
  tool_surface_sha256:string ->
  updated_at:float ->
  (t, string) result

val mark_active :
  base_path:string ->
  keeper_name:string ->
  expected:t ->
  thread_id:string ->
  updated_at:float ->
  (t, string) result

val mark_turn_starting :
  base_path:string ->
  keeper_name:string ->
  expected:t ->
  thread_id:string ->
  updated_at:float ->
  (t, string) result

val mark_turn_started :
  base_path:string ->
  keeper_name:string ->
  expected:t ->
  thread_id:string ->
  turn_id:string ->
  updated_at:float ->
  (t, string) result

val settle :
  base_path:string ->
  keeper_name:string ->
  expected:t ->
  thread_id:string ->
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
(** Convert the exact incomplete claim into an explicit operator-visible
    recovery state. This never retries or clears a possibly executed turn. *)

val resolve_recovery :
  base_path:string ->
  keeper_name:string ->
  expected:t ->
  recovery_id:string ->
  resolution:recovery_resolution ->
  resolved_by:string ->
  resolved_at:float ->
  (t, string) result
(** Resolve one exact recovery claim with compare-and-swap authority.
    [Retry_previous] restores the last settled thread, [Restart_fresh] makes
    the next claim start a new thread, and [Adopt_verified] records an
    operator-verified terminal turn. *)
(** Every phase change is a process-safe durable compare-and-swap followed by
    exact read-back. Any incomplete phase blocks a later automatic claim. *)
