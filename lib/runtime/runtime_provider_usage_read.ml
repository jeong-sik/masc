(* Asking a provider for its own usage windows without a model turn. See the
   [.mli]. *)

(* The same bound [masc runtime-probe] gives an account admission: the Codex
   read is initialize, account/read and one request, with no model work. An
   HTTP read is one GET under the same bound. *)
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

type http_read =
  { credential : Llm_provider.Provider_config.credential_source * Llm_provider.Secret.t
  ; usage_read : Runtime_schema.usage_read
  }

type how =
  | Codex of Runtime_execution.codex_app_server
  | Http of http_read

type readable =
  { scope : Runtime_quota_window.scope
  ; how : how
  }

(* An HTTP runtime whose provider declares [usage-read] is read with the key
   its execution was materialized with: the same load that froze the
   runtime's quota scope (Runtime.quota_scope_of_materialized), so the
   windows land on the account the dispatch uses.  Re-resolving the
   credential here would re-run alias selection against the process
   environment of the read.  runtime.toml refuses [usage-read] on an
   official-client protocol; a Codex app-server answers without a turn. *)
let how_of_runtime (rt : Runtime.t) =
  match rt.execution with
  | Runtime_execution.Agent_core config ->
    Option.map
      (fun usage_read ->
        Http { credential = config.credential_source, config.api_key; usage_read })
      rt.provider.usage_read
  | Runtime_execution.Codex_app_server codex -> Some (Codex codex)
  | Runtime_execution.Antigravity_cli _ | Runtime_execution.Claude_code _ -> None
;;

(* One runtime per account: every runtime of a quota scope shares the
   account, so reading it once answers for all of them. *)
let readable_scopes () =
  List.fold_left
    (fun acc (rt : Runtime.t) ->
      let scope = Runtime.quota_scope_of_runtime rt in
      if List.exists (fun r -> Runtime_quota_window.scope_equal r.scope scope) acc
      then acc
      else (
        match how_of_runtime rt with
        | Some how -> { scope; how } :: acc
        | None -> acc))
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

type http_error =
  | Credential_unavailable
  | Request_failed of Llm_provider.Http_client.http_error
  | Http_status of int
  | Body_not_json
  | Decode_failed of Runtime_provider_usage_window.decode_error

(* Neither the response body nor the key reaches the log: an HTTP error keeps
   only its status, and a JSON parse error only that it failed, because
   Yojson's message quotes the body. *)
let request_error_to_string : Llm_provider.Http_client.http_error -> string = function
  | HttpError { code; _ } -> Printf.sprintf "HTTP %d" code
  | NetworkError { message; _ } -> "network: " ^ message
  | TimeoutError { message; _ } -> "timeout: " ^ message
  | AcceptRejected { reason } -> "rejected: " ^ reason
  | ProviderTerminal { message; _ } -> "provider terminal: " ^ message
  | ProviderFailure { kind; message } ->
    Llm_provider.Http_client.provider_failure_to_string ~kind ~message
;;

let http_error_to_string = function
  | Credential_unavailable -> "the runtime's credential is empty or could not be refreshed"
  | Request_failed error -> request_error_to_string error
  | Http_status status -> Printf.sprintf "status %d" status
  | Body_not_json -> "the body is not JSON"
  | Decode_failed error -> Runtime_provider_usage_window.decode_error_to_string error
;;

let decoder_of_shape : Runtime_schema.usage_read_shape -> _ = function
  | Openrouter_key -> Runtime_provider_usage_window.decode_openrouter_key
  | Zai_quota_limit -> Runtime_provider_usage_window.decode_zai_quota_limit
  | Kimi_coding_usages -> Runtime_provider_usage_window.decode_kimi_coding_usages
  | Ollama_usage -> Runtime_provider_usage_window.decode_ollama_usage
;;

let is_success_status status = status >= 200 && status < 300

let parse_json body =
  match Yojson.Safe.from_string body with
  | json -> Ok json
  | exception Yojson.Json_error _ -> Error Body_not_json
;;

let get_usage ~net ~clock ~api_key url =
  let headers =
    [ "Authorization", "Bearer " ^ Llm_provider.Secret.header_value api_key ]
  in
  Eio.Switch.run
  @@ fun sw ->
  match
    Llm_provider.Http_client.get_sync
      ~clock
      ~timeout_s:read_timeout_s
      ~sw
      ~net
      ~url
      ~headers
      ()
  with
  | Error error -> Error (Request_failed error)
  | Ok response when is_success_status response.status -> Ok response.body
  | Ok response -> Error (Http_status response.status)
;;

(* A refreshable credential (an OAuth token) is refreshed like a dispatch
   would; a static one is the key the execution was built with. *)
let api_key_of_credential : Llm_provider.Provider_config.credential_source * _ -> _ =
  function
  | Static_credential, api_key -> Ok api_key
  | Refreshable_credential refresh, _ ->
    Result.map_error (fun (_ : Llm_provider.Provider_config.credential_refresh_error) ->
      Credential_unavailable)
      (refresh ())
;;

let usage_report ~fetch { credential; usage_read } =
  let ( let* ) = Result.bind in
  let* api_key = api_key_of_credential credential in
  let* () =
    if Llm_provider.Secret.is_empty api_key then Error Credential_unavailable else Ok ()
  in
  let* body = fetch ~api_key usage_read.url in
  let* json = parse_json body in
  decoder_of_shape usage_read.shape json
  |> Result.map_error (fun error -> Decode_failed error)
;;

let shape_label (http : http_read) =
  Runtime_schema.usage_read_shape_to_string http.usage_read.shape
;;

let read_http ~fetch ~scope http =
  let ( let* ) = Result.bind in
  let* (report : Runtime_provider_usage_window.report) = usage_report ~fetch http in
  (match report.windows with
   | [] ->
     Log.Runtime_agent.info
       "provider usage read for %s (shape %s) stated no windows"
       (Runtime_quota_window.scope_to_string scope)
       (shape_label http)
   | _ :: _ ->
     Runtime_provider_usage_window.record ~scope ~observed_at:(Time_compat.now ()) report);
  Ok ()
;;

(* One scope's read, with its failure logged.  A read that raises is logged
   with its scope too, so it never skips the scopes after it; only a
   cancellation passes through.  An HTTP read that raises logs only the
   exception's constructor: the request carried the key, and nothing
   bounds what an HTTP client's exception message quotes. *)
let read_scope ~codex ~fetch { scope; how } =
  let scope_label = Runtime_quota_window.scope_to_string scope in
  match how with
  | Codex exec ->
    (match codex ~scope exec with
     | Ok () -> ()
     | Error detail ->
       Log.Runtime_agent.warn "provider usage read failed for %s: %s" scope_label detail
     | exception (Eio.Cancel.Cancelled _ as cancelled) -> raise cancelled
     | exception exn ->
       Log.Runtime_agent.warn
         "provider usage read raised for %s: %s"
         scope_label
         (Printexc.to_string exn))
  | Http http ->
    (match read_http ~fetch ~scope http with
     | Ok () -> ()
     | Error error ->
       Log.Runtime_agent.warn
         "provider usage read failed for %s (shape %s): %s"
         scope_label
         (shape_label http)
         (http_error_to_string error)
     | exception (Eio.Cancel.Cancelled _ as cancelled) -> raise cancelled
     | exception exn ->
       Log.Runtime_agent.warn
         "provider usage read raised for %s (shape %s): %s"
         scope_label
         (shape_label http)
         (Printexc.exn_slot_name exn))
;;

let read_scopes ~codex ~fetch readables = List.iter (read_scope ~codex ~fetch) readables

let read_all ~mgr ~net ~clock ~cwd =
  let codex ~scope exec = read_codex ~mgr ~clock ~cwd ~scope exec in
  let fetch ~api_key url = get_usage ~net ~clock ~api_key url in
  read_scopes ~codex ~fetch (readable_scopes ())
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
