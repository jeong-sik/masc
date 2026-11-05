(** Loading a session's ledger from its store, and what this process
    remembers of each store.

    A [session_log] is a ledger with the file cursor it was read to and
    whether the store's header is on disk. This process keeps one per store
    path: [remember_session_log] sets it and [forget_session_log] drops it.
    [read_locked] reads a store under the session lock, from the remembered
    cursor when there is one and from the first byte otherwise.
    [cursor_result] gives the cursor of a store operation and logs a
    settlement error that came with it. [with_lock] runs a function under the
    session lock of a trace, and [load] returns the ledger read under it.
    [load_existing] and [load_existing_read_only_from_root] read a store
    without the lock and return [None] for a session that has none.
    [Keeper_skill_activation_ledger] includes this module. *)

open Keeper_skill_activation_ledger_errors
open Keeper_skill_activation_ledger_model

type session_log =
  { ledger : t
  ; cursor : Fs_compat.Private_jsonl_cursor.t
  ; header_written : bool
  }

val remember_session_log : string -> session_log -> unit

val forget_session_log : string -> unit

val cursor_result :
  path:string ->
  (Fs_compat.Private_jsonl_cursor.t,
   Fs_compat.private_jsonl_transaction_error)
  result ->
  (Fs_compat.Private_jsonl_cursor.t,
   Fs_compat.private_jsonl_transaction_error)
  result

val read_locked :
  ownership_root:string ->
  expected_trace_id:Keeper_id.Trace_id.t ->
  string ->
  (session_log, store_error)
  result

val with_lock :
  config:Workspace_utils_backend_setup.config ->
  trace_id:Keeper_id.Trace_id.t ->
  (ownership_root:string ->
   string ->
   ('a, store_error) result) ->
  ('a, store_error) result

val load :
  config:Workspace.config ->
  trace_id:Keeper_id.Trace_id.t ->
  (t, store_error) result

val load_existing_read_only_from_root :
  ownership_root:string ->
  trace_id:Keeper_id.Trace_id.t ->
  (t option, store_error) result

val load_existing :
  config:Workspace.config ->
  trace_id:Keeper_id.Trace_id.t ->
  (t option, store_error) result
