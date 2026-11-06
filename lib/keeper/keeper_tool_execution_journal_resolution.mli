(** The continuation marker of a prepared run, and how an operator observes
    and resolves a continuation.

    [continuation_marker] names the async request that continues a run.
    [continuation_directory] and [continuation_filename] say where a marker is
    stored, [decode_continuation_marker] reads one, and
    [prepare_continuation_marker] writes the marker of an open journal.
    [continuation_snapshot] reads a marker file under its lock, and
    [continuation_receipt] returns the value of a transaction receipt and
    logs a failed settlement. [retire_resolution_marker] retires the marker a
    resolution recorded. [with_resolution_terminal] runs a function on the
    terminal entry of a request that is waiting or lost. [observe_resolution]
    reads the resolution state of a request, [resolve_continuation] records an
    operator's decision on it, and [observe_request] reads what the journal
    holds for a request.
    [Keeper_tool_execution_journal] includes this module. *)

open Keeper_tool_execution_journal_types
open Keeper_tool_execution_journal_model

type continuation_marker =
  { request_id : string; keeper_name : string
  ; composition_run_id : Keeper_tool_plan.Composition_run_id.t }

val continuation_directory : base_path:string -> string

val continuation_filename : string -> string

val decode_continuation_marker :
  string ->
  (continuation_marker, error)
  result

val continuation_receipt :
  string -> 'a Fs_compat.private_jsonl_success_receipt -> 'a

val continuation_snapshot :
  root:string ->
  string ->
  (Fs_compat.private_jsonl_snapshot,
   error)
  result

val prepare_continuation_marker :
  t ->
  request_id:string ->
  (unit, error) result

val retire_resolution_marker :
  root:string ->
  path:string ->
  snapshot:Fs_compat.private_jsonl_snapshot ->
  resolution ->
  (unit, error) result

val with_resolution_terminal :
  t ->
  string ->
  (Keeper_msg_async.entry ->
   ('a, error) result) ->
  ('a, error) result

val observe_resolution :
  base_path:string ->
  keeper_name:string ->
  composition_run_id:Keeper_tool_plan.Composition_run_id.t ->
  request_id:string ->
  (resolution_observation,
   error)
  result

val resolve_continuation :
  base_path:string ->
  keeper_name:string ->
  composition_run_id:Keeper_tool_plan.Composition_run_id.t ->
  request_id:string ->
  expected_version:string ->
  decision:resolution_decision ->
  requested_by:string ->
  reason:string ->
  now:float ->
  (resolution_report,
   error)
  result

val observe_request :
  base_path:string ->
  composition_run_id:Keeper_tool_plan.Composition_run_id.t ->
  Keeper_msg_async.entry ->
  (request_observation,
   error)
  result
