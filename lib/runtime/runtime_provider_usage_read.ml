(* Asking a provider for its own usage windows without a model turn. See the
   [.mli]. *)

(* The same bound [masc runtime-probe] gives an account admission: the read
   is initialize, account/read and one request, with no model work. *)
let read_timeout_s = 20.0

let codex_config (exec : Runtime_execution.codex_app_server) =
  let bound = Float.min read_timeout_s exec.timeout_s in
  { (Runtime_codex_app_server.default_config ()) with
    cli_path = exec.cli_path
  ; account_home = exec.account_home
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
        let scope = Runtime.quota_scope_of_runtime rt in
        if List.exists (fun r -> Runtime_quota_window.scope_equal r.scope scope) acc
        then acc
        else { scope; codex } :: acc
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

(* Scopes a background read is running for. Keepers sharing one account are
   refused around the same moment; one read answers all of them. *)
let reading : Runtime_quota_window.scope list Atomic.t = Atomic.make []

let rec claim scope =
  let current = Atomic.get reading in
  if List.exists (Runtime_quota_window.scope_equal scope) current
  then false
  else if Atomic.compare_and_set reading current (scope :: current)
  then true
  else claim scope
;;

let rec release scope =
  let current = Atomic.get reading in
  let rest =
    List.filter (fun held -> not (Runtime_quota_window.scope_equal held scope)) current
  in
  if not (Atomic.compare_and_set reading current rest) then release scope
;;

type background =
  | Started
  | Already_reading
  | No_root_switch

(* The caller is usually a turn that is about to end, and the read takes
   seconds (spawn, initialize, account/read, the request). A fiber on the
   turn's switch would be cancelled when the turn returns, so the read runs
   on the server's root switch, forked on the domain that owns it. *)
let read_codex_in_background ~clock ~cwd ~scope codex =
  Eio_context.run_on_owner_domain (fun () ->
    match Eio_context.get_root_switch_opt () with
    | None -> No_root_switch
    | Some sw ->
      if not (claim scope)
      then Already_reading
      else (
        Eio.Fiber.fork ~sw (fun () ->
          Fun.protect
            ~finally:(fun () -> release scope)
            (fun () ->
              (* A raise here would fail the server's root switch; a read
                 that goes wrong is only an unanswered observation. *)
              match read_codex ~mgr:Posix_spawn_process_mgr.mgr ~clock ~cwd ~scope codex with
              | Ok () -> ()
              | Error detail ->
                Log.Runtime_agent.warn
                  "provider usage read failed for %s: %s"
                  (Runtime_quota_window.scope_to_string scope)
                  detail
              | exception (Eio.Cancel.Cancelled _ as cancelled) -> raise cancelled
              | exception exn ->
                Log.Runtime_agent.warn
                  "provider usage read raised for %s: %s"
                  (Runtime_quota_window.scope_to_string scope)
                  (Printexc.to_string exn)));
        Started))
;;
