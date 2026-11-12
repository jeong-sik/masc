(** Authoritative operator-snapshot HTTP projection.

    The default summary retains its captured observation until an original
    source change or semantic deadline owes a read. Parameterized requests
    compute Current under their own actor/query. Store failures cannot return
    an earlier approval row as the failed read's answer. *)

open Server_utils
open Server_auth

module Core_cache = Server_dashboard_http_core_cache
module Owner = Server_dashboard_operator_snapshot_observation
module Core_operator_query = Server_dashboard_http_core_operator_query

(* Only the parameterized path computes this request's rows directly. Never
   attach the current workspace to a cached default publication: that would
   turn an unrelated old publication into apparent response authority. *)
let with_workspace_attestation ~(config : Workspace.config) json =
  match json with
  | `Assoc fields ->
    (try
       let identity = `Assoc
         [ "base_path", `String (Unix.realpath config.base_path)
         ; "masc_root", `String (Unix.realpath (Workspace.masc_dir config))
         ; "state_ready", `Bool (Server_startup_state.snapshot ()).state_ready ] in
       `Assoc (("workspace_identity", identity)
         :: List.remove_assoc "workspace_identity" fields)
     with Unix.Unix_error _ ->
       `Assoc ["error", `String "Operator snapshot workspace paths are unavailable"])
  | other -> other

let with_captured_instance ~(scope : Mcp_server.workspace_scope) = function
  | `Assoc fields -> `Assoc (("observer_instance_id", `String (Server_observer_scope.instance_id scope))
      :: List.remove_assoc "observer_instance_id" fields)
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
      invalid_arg "Operator Snapshot response must be an object"

let operator_snapshot_http_json ~state ~sw ~clock request =
  let scope = Mcp_server.workspace_scope state in
  let config = scope.config in
  let owner = Owner.owner_for_scope ~state scope in
  let actor = dashboard_actor_for_request ~base_path:config.base_path request in
  let view = query_param request "view" in
  let default_summary_request = actor = None
    && query_param request "include_messages" = None
    && query_param request "include_keepers" = None
    && match view with None -> true
      | Some raw -> String.equal (String.lowercase_ascii (String.trim raw)) "summary" in
  if default_summary_request then (
    let query = Core_operator_query.operator_snapshot_default_query () in
    let attach () = Owner.publication_json (Owner.publication owner) in
    if Owner.observation_is_usable owner then attach () else (
      let attempt = Owner.begin_attempt owner ~origin:Default_request in
      try
        let observation = Server_dashboard_operator_snapshot_compute.observe_current
            ~state ~scope ~sw ~clock ~query ~actor:"dashboard" ~view:"summary"
            ~include_messages:true ~include_keepers:true ~include_summary_fields:false
            ~lightweight_summary:true () in
        ignore (Owner.publish_observation attempt observation);
        attach ()
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn ->
          ignore (Owner.publish_failure_message attempt (Printexc.to_string exn));
          attach ()))
  else (
    let include_messages = match query_param request "include_messages" with
      | Some ("0" | "false" | "no") -> false | Some _ | None -> true in
    let include_keepers = match query_param request "include_keepers" with
      | Some ("0" | "false" | "no") -> false | Some _ | None -> true in
    let lightweight_summary = match view with
      | Some raw -> String.equal (String.lowercase_ascii (String.trim raw)) "summary"
      | None -> false in
    let query = Core_operator_query.operator_snapshot_query_json
        ~actor ~view ~include_messages ~include_keepers ~lightweight_summary ~default_summary_request in
    let result = Watched_work.run
        ~watcher:(fun () -> Eio.Time.sleep clock Core_cache.dashboard_request_timeout_s; Error `Timeout)
        (fun () -> Ok (Server_dashboard_operator_snapshot_compute.observe_current
          ~state ~scope ~sw ~clock ~query ?actor ?view ~include_messages ~include_keepers
          ~include_summary_fields:(not lightweight_summary) ~lightweight_summary ())) in
    match result with
    | Ok observation ->
        Dashboard_projection_read.json_with_read_diagnostics observation
        |> with_workspace_attestation ~config |> with_captured_instance ~scope
    | Error `Timeout ->
        `Assoc ["error", `String "timeout";
          "message", `String "Operator snapshot timed out after 30s";
          "generated_at", `String (Masc_domain.now_iso ())]
        |> Core_operator_query.with_operator_snapshot_metadata ~config ~query)
