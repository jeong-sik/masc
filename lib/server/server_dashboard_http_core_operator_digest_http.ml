module Owner = Server_dashboard_operator_digest_observation
module Core_cache = Server_dashboard_http_core_cache
module Query = Server_dashboard_http_core_operator_query

let attest_instance (scope : Mcp_server.workspace_scope) = function
  | `Assoc fields -> `Assoc (("observer_instance_id", `String (Server_observer_scope.instance_id scope))
      :: List.remove_assoc "observer_instance_id" fields)
  | (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _) as json -> json

let default_json ~state ~scope ~owner ~sw ~clock =
  let cached () = if Owner.has_terminal_answer owner
    then Some (Owner.publication owner).json else None in
  match cached () with
  | Some json -> json
  | None ->
      let key = "operator_digest:default:" ^ Owner.cache_identity owner in
      let attempted = ref None in
      let fail exn = Option.iter (fun attempt ->
        ignore (Owner.publish_failure_message attempt (Printexc.to_string exn))) !attempted in
      let work = Pool_work.cpu ~name:__FUNCTION__ (fun () ->
        let attempt = Owner.begin_attempt owner ~origin:Default_request in
        attempted := Some attempt;
        try
          let observation = match Server_dashboard_operator_digest_compute.observe_current
              ~state ~scope ~sw ~clock ~query:(Query.operator_digest_default_query ())
              ~actor:"dashboard" ~target_type:"workspace" () with
            | Ok observation -> observation
            | Error detail -> invalid_arg ("Operator Digest default read: " ^ detail) in
          ignore (Owner.publish_observation attempt observation);
          Dashboard_projection_read.json_with_read_diagnostics observation
        with
        | Eio.Cancel.Cancelled _ as exn -> raise exn
        | exn -> fail exn; raise exn) in
      let json = Dashboard_cache.get_or_compute_with_timeout key
          ~ttl:Core_cache.standard_cache_ttl_s ~clock
          ~timeout_sec:Core_cache.dashboard_request_timeout_s work in
      if Dashboard_cache.is_timeout_envelope json then (
        fail (Dashboard_cache.Compute_timeout {key; role = Dashboard_cache.Compute_owner});
        attest_instance scope json)
      else match cached () with Some current -> current | None -> attest_instance scope json

let operator_digest_http_json ~state ~sw ~clock request =
  (* Entry capture precedes auth resolution, cache waiting and actual compute. *)
  let scope = Mcp_server.workspace_scope state in
  let owner = Owner.owner_for_scope ~state scope in
  let config = scope.config in
  let actor = Server_auth.dashboard_actor_for_request ~base_path:config.base_path request in
  let target_type = Server_utils.query_param request "target_type" in
  let target_id = Server_utils.query_param request "target_id" in
  let include_workers = match Server_utils.query_param request "include_workers" with
    | Some ("0" | "false" | "no") -> Some false
    | Some ("1" | "true" | "yes") -> Some true
    | Some _ | None -> None in
  let workspace_target_type = function
    | None -> true
    | Some raw ->
        (match Operator_action_constants.target_type_of_string (String.lowercase_ascii (String.trim raw)) with
         | Some Operator_action_constants.Workspace -> true
         | Some (Keeper | Goal) | None -> false) in
  let effective_target_type = Option.value
      ~default:Operator_action_constants.workspace_target_type target_type in
  let default_namespace_request = actor = None && target_id = None && include_workers = None
      && workspace_target_type target_type in
  let query = Query.operator_digest_query_json ~actor ~target_type ~target_id ~include_workers
      ~effective_target_type ~default_namespace_request in
  let result =
    if default_namespace_request then default_json ~state ~scope ~owner ~sw ~clock
    else
      let key = "operator_digest:param:" ^ Yojson.Safe.to_string (`List [
        `String (Owner.cache_identity owner); query]) in
      Dashboard_cache.get_or_compute_with_timeout key ~ttl:Core_cache.standard_cache_ttl_s
        ~clock ~timeout_sec:Core_cache.dashboard_request_timeout_s
        (Pool_work.cpu ~name:__FUNCTION__ (fun () ->
          match Server_dashboard_operator_digest_compute.observe_current ~state ~scope ~sw ~clock
              ~query ?actor ~target_type:effective_target_type ?target_id ?include_workers () with
          | Ok observation -> Dashboard_projection_read.json_with_read_diagnostics observation
          | Error detail -> `Assoc ["error", `String "validation_error";
              "message", `String detail; "generated_at", `String (Masc_domain.now_iso ())])) in
  Ok (result |> Query.with_operator_digest_metadata ~config ~query |> attest_instance scope)
