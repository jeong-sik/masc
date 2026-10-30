(** Audit, SSE and chat views of already selected approval transitions.
    Queue storage and transition authority remain with [Keeper_approval_queue]. *)
open Keeper_approval_queue_rules_types
open Keeper_approval_queue_result

val pending_entry_json_fields :
  ?include_input:bool -> pending_approval -> (string * Yojson.Safe.t) list
val record_pending :
  call_summary:string option -> pending_approval -> Keeper_approval.Audit.receipt
val record_summary_updated : now:float -> pending_approval -> unit

val publish_chat_projection_append :
  keeper_name:string -> (Keeper_chat_store.append_once_result, string) result ->
  (unit, string) result
val append_chat_projection :
  base_path:string -> keeper_name:string -> Keeper_chat_store.approval_lifecycle ->
  (unit, string) result

val resolve_entry :
  ?before_terminal_publish:(unit -> unit) -> base_path:string -> pending_approval ->
  source:decision_source -> ?actor:string -> decision -> Keeper_approval.Audit.receipt
(** Records the resolution audit, calls the supplied publication hook, then
    broadcasts the resolution. The caller has already selected the resolution. *)

val ensure_resolution_chat_projection :
  base_path:string -> keeper_name:string -> approval_id:string ->
  tool_name:string option -> decision:decision -> (unit, string) result

val ensure_replay_chat_projection :
  base_path:string -> keeper_name:string -> approval_id:string ->
  tool_name:string option -> outcome:resolution_replay_outcome ->
  (unit, string) result

val continuation_settled_chat_projection_present :
  base_path:string -> keeper_name:string -> approval_id:string -> bool

val record_settled_continuation :
  base_path:string -> keeper_name:string -> approval_id:string ->
  readiness:continuation_readiness ->
  (continuation_projection_result, string) result
(** Project already selected readiness. No grant-store lookup or consumption.
    Copy the request's stored call summary and publish only a new chat row. *)

val record_failed_continuation :
  base_path:string -> keeper_name:string -> approval_id:string ->
  readiness:continuation_readiness -> route:Keeper_runtime_failure_route.route ->
  (continuation_projection_result, string) result
(** The same readiness boundary. Warn only when a failed settlement is newly
    appended, before broadcasting it. *)
