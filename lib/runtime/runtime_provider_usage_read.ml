(* Asking a provider for its own usage windows without a model turn. See the
   [.mli]. *)

(* The same bound [masc runtime-probe] gives an account admission: the read
   is initialize, account/read and one request, with no model work. *)
let read_timeout_s = 20.0

let codex_config (exec : Runtime_execution.codex_app_server) =
  let bound = Float.min read_timeout_s exec.timeout_s in
  { (Runtime_codex_app_server.default_config ()) with
    cli_path = exec.cli_path
  ; model = exec.model
  ; admission_timeout_s = bound
  ; timeout_s = Some bound
  }
;;

type readable =
  { scope : Runtime_quota_window.scope
  ; codex : Runtime_execution.codex_app_server
  }

(* One runtime per account: every runtime of a quota scope shares the
   account, so reading it once answers for all of them. *)
let readable_scopes () =
  List.fold_left
    (fun acc (rt : Runtime.t) ->
      match rt.execution with
      | Runtime_execution.Codex_app_server codex ->
        (match Runtime.quota_scope_of_runtime_id rt.id with
         | Some scope when not (List.exists (fun r -> r.scope = scope) acc) ->
           { scope; codex } :: acc
         | Some _ | None -> acc)
      | Runtime_execution.Agent_core _
      | Runtime_execution.Antigravity_cli _
      | Runtime_execution.Claude_code _ -> acc)
    []
    (Runtime.get_runtimes ())
  |> List.rev
;;

let read_codex ~mgr ~clock ~cwd ~scope codex =
  match
    Runtime_codex_app_server.read_rate_limits ~mgr ~clock ~cwd (codex_config codex)
  with
  | Ok report ->
    Runtime_provider_usage_window.record ~scope ~observed_at:(Time_compat.now ()) report;
    Ok ()
  | Error error -> Error (Runtime_codex_app_server.error_to_string error)
;;

let read_all ~mgr ~clock ~cwd =
  List.iter
    (fun { scope; codex } ->
      match read_codex ~mgr ~clock ~cwd ~scope codex with
      | Ok () -> ()
      | Error detail ->
        Log.Runtime_agent.warn
          "provider usage read failed for %s: %s"
          (Runtime_quota_window.scope_to_string scope)
          detail)
    (readable_scopes ())
;;
