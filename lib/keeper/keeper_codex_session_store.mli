(** Durable current-owner state between one Keeper and one official Codex thread.

    This is not an OAS checkpoint. Codex owns the thread transcript; MASC owns
    the exact settlement phase needed to resume without silently duplicating an
    externally admitted turn. *)

type phase =
  | Start of { previous_thread_id : string option }
  | Active of { thread_id : string }
  | Turn_inflight of
      { thread_id : string
      ; turn_id : string option
      }
  | Settled of
      { thread_id : string
      ; turn_id : string
      }

type t =
  { runtime_id : string
  ; phase : phase
  ; turn_count : int
  ; tool_surface_sha256 : string
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
(** Every phase change is a process-safe durable compare-and-swap followed by
    exact read-back. Any incomplete phase blocks a later automatic claim. *)
