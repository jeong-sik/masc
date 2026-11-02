(** Read-only queue outcomes for the sources selected by one exact Keeper turn.
    The manifest supplies the selection; the reaction ledger supplies terminal
    receipts through the core's public observation API. No queue state,
    operation, Task or business result is changed. *)

val project :
  config:Workspace.config ->
  keeper_name:string ->
  trace_id:string ->
  turn_id:int option ->
  Server_dashboard_http_keeper_runtime_manifest_scan.runtime_manifest_scan ->
  Yojson.Safe.t
(** A unique, completely scanned [turn_started] is required to select sources.
    Match each receipt by stimulus id, canonical source snapshot and admitted
    revision, never by time or id alone. Distinct receipts are retained rather
    than choosing the newest. Duplicate projections of one receipt coalesce.

    [observed_at] is the end of this read, retained by the runtime-trace cache.
    The ledger is streamed, not an atomic snapshot: even a readable store and
    an empty receipt list do not prove that a source remains pending. Damaged
    rows and storage failures are explicit; independently valid matches survive
    partial reads. Source bodies and diagnostic payloads are not projected. *)
