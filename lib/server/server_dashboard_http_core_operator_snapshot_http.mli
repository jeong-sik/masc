(** Operator-snapshot dashboard HTTP handler. Parameterized responses compute
    their own rows and carry canonical
    [workspace_identity] paths with [state_ready]. Default cached publications
    retain their own identity and are not relabeled with the current workspace.
    Both preserve the query used by their actual read. Private responses carry
    the captured [observer_instance_id], but no default ordering/state and do
    not install their rows into the canonical owner. A no-result default error
    satisfies subsequent GETs until original input or existing worker retry
    recovers it; it never restores an earlier approval body. *)

val operator_snapshot_http_json :
  state:Mcp_server.server_state ->
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  Httpun.Request.t ->
  Yojson.Safe.t
