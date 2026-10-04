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
  ; account_home = exec.account_home
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
  | Antigravity of Runtime_execution.antigravity_cli
  | Http of http_read

type readable =
  { scope : Runtime_quota_window.scope
  ; how : how
  }

(* An HTTP runtime whose provider declares [usage-read] is read with the key
   its execution was materialized with: the same load that froze the
   runtime's quota scope in [Runtime_instance.of_binding], so the
   windows land on the account the dispatch uses.  Re-resolving the
   credential here would re-run alias selection against the process
   environment of the read.  runtime.toml refuses [usage-read] on an
   official-client protocol; a Codex app-server and the Antigravity CLI
   answer without a turn. Claude Code states its windows only during one.
   Muse Code is read only after a failed turn, via its selected account. *)
let how_of_runtime (rt : Runtime_instance.t) =
  match rt.execution with
  | Runtime_execution.Agent_core config ->
    Option.map
      (fun usage_read ->
        Http { credential = config.credential_source, config.api_key; usage_read })
      rt.provider.usage_read
  | Runtime_execution.Codex_app_server codex -> Some (Codex codex)
  | Runtime_execution.Antigravity_cli antigravity -> Some (Antigravity antigravity)
  | Runtime_execution.Claude_code _ | Runtime_execution.Muse_serve _ -> None
;;

(* One runtime per account: every runtime of a quota scope shares the
   account, so reading it once answers for all of them. *)
let readable_scopes () =
  List.fold_left
    (fun acc (rt : Runtime_instance.t) ->
      let scope = Runtime_instance.quota_scope_of_runtime rt in
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

(* The windows reach the operator projection on every read, stamped with the
   time the answer arrived; whether the same answer also rests the scope is
   the caller's ([read_codex_after_spent_usage_refusal]). *)
let read_codex_report ~mgr ~clock ~cwd ~scope codex =
  match
    Runtime_codex_app_server.read_rate_limits ~mgr ~clock ~cwd (codex_config codex)
  with
  | Ok report ->
    let observed_at = Time_compat.now () in
    Runtime_provider_usage_window.record ~scope ~observed_at report;
    Ok (observed_at, report)
  | Error error -> Error (Runtime_codex_app_server.error_to_string error)
;;

let read_codex ~mgr ~clock ~cwd ~scope codex =
  Result.map
    (fun ((_ : float), (_ : Runtime_provider_usage_window.report)) -> ())
    (read_codex_report ~mgr ~clock ~cwd ~scope codex)
;;

let read_muse ~mgr ~clock ~cwd ~scope (config : Runtime_muse_serve.config) =
  let config =
    { config with
      Runtime_muse_serve.admission_timeout_s =
        Float.min read_timeout_s config.admission_timeout_s
    ; timeout_s = Some read_timeout_s
    }
  in
  match Runtime_muse_serve.read_usage ~mgr ~clock ~cwd config with
  | Ok usage ->
    Option.iter
      (fun usage ->
        Option.iter
          (fun reset_ms ->
            Runtime_quota_window.note_exhausted
              ~scope ~resets_at:(float_of_int reset_ms /. 1000.))
          (Runtime_muse_msp.exhausted_subscription_reset_ms usage))
      usage;
    Ok ()
  | Error error -> Error (Runtime_muse_serve.error_to_string error)
;;

let read_antigravity ~scope (antigravity : Runtime_execution.antigravity_cli) =
  match
    Runtime_antigravity_usage.read
      ~cli_path:antigravity.cli_path
      ~oauth_source:antigravity.oauth_source
  with
  | Ok (report : Runtime_provider_usage_window.report) ->
    (match report.windows with
     | [] ->
       Log.Runtime_agent.info
         "provider usage read for %s (antigravity /usage) stated no windows"
         (Runtime_quota_window.scope_to_string scope)
     | _ :: _ ->
       Runtime_provider_usage_window.record ~scope ~observed_at:(Time_compat.now ()) report);
    Ok ()
  | Error error -> Error (Runtime_antigravity_usage.error_to_string error)
;;

type http_error =
  | Credential_unavailable
  | Credential_not_refreshed
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
  | Credential_not_refreshed ->
    "the runtime's credential needs a refresh, which a read after a refusal does not do"
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

let usage_report ?(api_key_of = api_key_of_credential) ~fetch { credential; usage_read } =
  let ( let* ) = Result.bind in
  let* api_key = api_key_of credential in
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

(* One HTTP read, with its failure logged.  A read that raises logs only the
   exception's constructor: the request carried the key, and nothing bounds
   what an HTTP client's exception message quotes. *)
let read_http_logged ~fetch ~scope http =
  let scope_label = Runtime_quota_window.scope_to_string scope in
  match read_http ~fetch ~scope http with
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
      (Printexc.exn_slot_name exn)
;;

(* An official client's read, with its failure logged. *)
let read_client_logged ~scope read =
  let scope_label = Runtime_quota_window.scope_to_string scope in
  match read () with
  | Ok () -> ()
  | Error detail ->
    Log.Runtime_agent.warn "provider usage read failed for %s: %s" scope_label detail
  | exception (Eio.Cancel.Cancelled _ as cancelled) -> raise cancelled
  | exception exn ->
    Log.Runtime_agent.warn
      "provider usage read raised for %s: %s"
      scope_label
      (Printexc.to_string exn)
;;

(* One scope's read, with its failure logged.  A read that raises is logged
   with its scope too, so it never skips the scopes after it; only a
   cancellation passes through. *)
let read_scope ~codex ~antigravity ~fetch { scope; how } =
  match how with
  | Codex exec -> read_client_logged ~scope (fun () -> codex ~scope exec)
  | Antigravity exec -> read_client_logged ~scope (fun () -> antigravity ~scope exec)
  | Http http -> read_http_logged ~fetch ~scope http
;;

let read_scopes ~codex ~antigravity ~fetch readables =
  List.iter (read_scope ~codex ~antigravity ~fetch) readables
;;

let read_all ~mgr ~net ~clock ~cwd =
  let codex ~scope exec = read_codex ~mgr ~clock ~cwd ~scope exec in
  let fetch ~api_key url = get_usage ~net ~clock ~api_key url in
  read_scopes ~codex ~antigravity:read_antigravity ~fetch (readable_scopes ())
;;

(* A static key that is empty never reaches a request ([usage_report]
   refuses it first) and stays empty while the runtime lives, so repeating
   its read would only repeat the warning the start read logged.  A
   refreshable credential may answer on a later read. *)
let may_answer (http : http_read) =
  match http.credential with
  | Llm_provider.Provider_config.Static_credential, api_key ->
    not (Llm_provider.Secret.is_empty api_key)
  | Llm_provider.Provider_config.Refreshable_credential _, _ -> true
;;

let repeat_period (http : http_read) =
  if may_answer http then http.usage_read.refresh_s else None
;;

(* The account's HTTP read as [readables] declares it, while it repeats. *)
let repeat_of readables scope =
  List.find_map
    (fun (readable : readable) ->
       match readable.how with
       | Http http when Runtime_quota_window.scope_equal readable.scope scope ->
         Option.map (fun period -> period, http) (repeat_period http)
       | Http _ | Codex _ | Antigravity _ -> None)
    readables
;;

let rec refresh_scope ~clock ~fetch ~catalogue scope period =
  Eio.Time.sleep clock period;
  match repeat_of (catalogue ()) scope with
  | None ->
    Log.Runtime_agent.info
      "provider usage refresh for %s stopped: the catalogue no longer holds a \
       usage-read.refresh-s it can answer"
      (Runtime_quota_window.scope_to_string scope)
  | Some (period, http) ->
    read_http_logged ~fetch ~scope http;
    refresh_scope ~clock ~fetch ~catalogue scope period
;;

let refresh_readables ~clock ~fetch ~catalogue =
  let repeating =
    List.filter_map
      (fun (readable : readable) ->
         match readable.how with
         | Http http -> Option.map (fun period -> readable.scope, period) (repeat_period http)
         | Codex _ | Antigravity _ -> None)
      (catalogue ())
  in
  Eio.Fiber.List.iter
    (fun (scope, period) -> refresh_scope ~clock ~fetch ~catalogue scope period)
    repeating
;;

let rec watch_readables ~clock ~codex ~antigravity ~fetch ~catalogue ~revision ~await_change =
  let current = revision () in
  Eio.Fiber.first
    (fun () -> ignore (await_change ~after:current))
    (fun () ->
      read_scopes ~codex ~antigravity ~fetch (catalogue ());
      refresh_readables ~clock ~fetch ~catalogue;
      Eio.Fiber.await_cancel ());
  watch_readables ~clock ~codex ~antigravity ~fetch ~catalogue ~revision ~await_change
;;

let watch_declared ~mgr ~net ~clock ~cwd =
  let codex ~scope exec = read_codex ~mgr ~clock ~cwd ~scope exec in
  let fetch ~api_key url = get_usage ~net ~clock ~api_key url in
  watch_readables ~clock ~codex ~antigravity:read_antigravity ~fetch
    ~catalogue:readable_scopes ~revision:Runtime.catalogue_revision
    ~await_change:Runtime.await_catalogue_change
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
  | Scheduling_failed

(* The caller is usually a turn that is about to end, and the read takes
   seconds (spawn, initialize, account/read, the request). A fiber on the
   turn's switch would be cancelled when the turn returns, so the read runs
   on the server's root switch, forked on the domain that owns it. *)
let start_background ~scope ~fork ~read =
  if not (claim scope)
  then Already_reading
  else (
    match fork (fun () -> Fun.protect ~finally:(fun () -> release scope) read) with
    | () -> Started
    | exception (Eio.Cancel.Cancelled _ as cancelled) ->
      release scope;
      raise cancelled
    | exception exn ->
      release scope;
      Log.Runtime_agent.warn
        "provider usage read could not be scheduled for %s: %s"
        (Runtime_quota_window.scope_to_string scope)
        (Printexc.exn_slot_name exn);
      Scheduling_failed)
;;

let read_client_in_background ~clock ~cwd ~scope read =
  let read_logged () =
    (* A read failure is only an unanswered observation; it must not fail
       the server's root switch or alter the original provider error. *)
    match read
            ~mgr:(Posix_spawn_process_mgr.foreground_mgr ~clock
              ~grace_seconds:Process_eio.child_exit_grace_seconds)
            ~clock ~cwd ~scope with
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
        (Printexc.to_string exn)
  in
  match
    Eio_context.run_on_owner_domain (fun () ->
      match Eio_context.get_root_switch_opt () with
      | None -> No_root_switch
      | Some sw ->
        start_background ~scope ~fork:(Eio.Fiber.fork ~sw) ~read:read_logged)
  with
  | outcome -> outcome
  | exception (Eio.Cancel.Cancelled _ as cancelled) -> raise cancelled
  | exception exn ->
    Log.Runtime_agent.warn
      "provider usage read could not reach the root owner for %s: %s"
      (Runtime_quota_window.scope_to_string scope)
      (Printexc.exn_slot_name exn);
    Scheduling_failed
;;

let read_muse_in_background ~clock ~cwd ~scope config =
  read_client_in_background ~clock ~cwd ~scope
    (fun ~mgr ~clock ~cwd ~scope -> read_muse ~mgr ~clock ~cwd ~scope config)
;;

module For_testing = struct
  let start_background = start_background
end


(* After an account refusal: the reads whose answer the walk reads.

   An HTTP 403 does not say why the account was refused. Kimi For Coding
   sends the same body type for a spent 5-hour window and for a client the
   plan does not admit. The provider's usage endpoint answers the question
   with counts: a window that gates model calls and whose used count reached
   its limit is spent until its stated reset. Only that answer rests the
   scope; the status alone rests nothing. Codex account snapshots cannot
   attribute a bucket to a refused call. *)

type account_refusal_read =
  | Spent_until of float
  | Spent_without_reset
  | Spent_in_several_limits of string option list
  | No_window_spent

(* [used] reached [limit]. Count windows are decoded as [used / limit]
   ([fraction_of_counts]), which is exactly 1.0 when the two are equal. *)
let window_spent (window : Runtime_provider_usage_window.window) =
  match window.utilization with
  | Runtime_provider_usage_window.Fraction used -> Float.compare used 1.0 >= 0
  | Runtime_provider_usage_window.Percent used -> used >= 100
  | Runtime_provider_usage_window.Usd { used; limit = Some limit } -> used >= limit
  | Runtime_provider_usage_window.Usd { limit = None; _ } -> false
;;

(* Only a window that gates model calls can explain a refused model call. *)
let gates_model_calls (window : Runtime_provider_usage_window.window) =
  match window.role with
  | Runtime_provider_usage_window.Gates_model_calls -> true
  | Runtime_provider_usage_window.Counts_other_use
  | Runtime_provider_usage_window.Unclassified_limit -> false
;;

(* The latest stated reset among the spent gating windows: every one of them
   refuses calls until it resets. A spent gating window that states no reset
   keeps the scope resting until its next success, whatever the others say. *)
(* The spent gating windows of one limit. Codex reads every metered limit
   ([rateLimitsByLimitId]) and a spent-usage refusal does not name the limit
   that refused the call, so spent windows of two limits cannot say how long
   the refused call stays refused: one bucket may reset in an hour and another
   in a week. Only a single spent limit names the rest; within it the latest
   reset is when every spent window of that limit has room again. *)
let account_refusal_read_of_report (report : Runtime_provider_usage_window.report) =
  let spent =
    List.filter
      (fun (window : Runtime_provider_usage_window.window) ->
         gates_model_calls window && window_spent window)
      report.windows
  in
  match
    List.sort_uniq
      (Option.compare String.compare)
      (List.map (fun (window : Runtime_provider_usage_window.window) -> window.limit_id) spent)
  with
  | [] -> No_window_spent
  | _ :: _ :: _ as limit_ids -> Spent_in_several_limits limit_ids
  | [ _ ] ->
    List.fold_left
      (fun acc (window : Runtime_provider_usage_window.window) ->
         match acc, window.resets_at with
         | Spent_without_reset, (Some _ | None)
         | (No_window_spent | Spent_until _ | Spent_in_several_limits _), None ->
           Spent_without_reset
         | (No_window_spent | Spent_in_several_limits _), Some resets_at ->
           Spent_until (Float.of_int resets_at)
         | Spent_until held, Some resets_at ->
           Spent_until (Float.max held (Float.of_int resets_at)))
      No_window_spent
      spent
;;

let account_refusal_read_to_string = function
  | Spent_until resets_at -> Printf.sprintf "a gating window is spent until %.0f" resets_at
  | Spent_without_reset -> "a gating window is spent and states no reset"
  | Spent_in_several_limits limit_ids ->
    Printf.sprintf
      "gating windows of %d limits are spent (%s) and the refusal names none of them"
      (List.length limit_ids)
      (String.concat
         ", "
         (List.map
            (function
              | Some limit_id -> limit_id
              | None -> "a window without a limit id")
            limit_ids))
  | No_window_spent -> "no gating window is spent"
;;

(* The refused call just used this credential. A token that needs a refresh
   is not refreshed on the failing path for a diagnostic read; the read is
   skipped instead. *)
let materialized_api_key : Llm_provider.Provider_config.credential_source * _ -> _ =
  function
  | Static_credential, api_key -> Ok api_key
  | Refreshable_credential _, _ -> Error Credential_not_refreshed
;;

(* A spent window whose stated reset is not after the moment the answer
   arrived (a zero, a stale backend, a skewed clock) names no rest. Planted
   as a window it would replace the refusal's observation with one already
   over, and the scope would look available on the next cycle; the turn
   driver drops a hint that is not ahead for the same reason
   ([Keeper_runtime_failure_route.usable_retry_after]). It stays a spent
   window without a reset. Returns the read as rested. *)
let rest_on_account_refusal_read ~scope ~observed_at read =
  let read =
    match read with
    | Spent_until resets_at when Float.compare resets_at observed_at <= 0 ->
      Log.Runtime_agent.info
        "provider usage read for %s states a spent window that reset at %.0f, not \
         after the answer at %.0f: the scope rests until its next success"
        (Runtime_quota_window.scope_to_string scope)
        resets_at
        observed_at;
      Spent_without_reset
    | Spent_until _ | Spent_without_reset | Spent_in_several_limits _ | No_window_spent ->
      read
  in
  (match read with
   | Spent_until resets_at -> Runtime_quota_window.note_exhausted ~scope ~resets_at
   | Spent_without_reset -> Runtime_quota_window.note_observed_exhausted ~scope
   | Spent_in_several_limits _ ->
     Log.Runtime_agent.info
       "provider usage read for %s: %s; the scope rests until its next success"
       (Runtime_quota_window.scope_to_string scope)
       (account_refusal_read_to_string read);
     Runtime_quota_window.note_observed_exhausted ~scope
   | No_window_spent -> ());
  read
;;

let read_after_account_refusal ~fetch ~scope http =
  let ( let* ) = Result.bind in
  let* (report : Runtime_provider_usage_window.report) =
    usage_report ~api_key_of:materialized_api_key ~fetch http
  in
  let observed_at = Time_compat.now () in
  Runtime_provider_usage_window.record ~scope ~observed_at report;
  Ok (rest_on_account_refusal_read ~scope ~observed_at (account_refusal_read_of_report report))
;;

(* The refusal carries no metered limit_id. The read's default snapshot and
   per-limit map identify observed buckets, not the bucket of that failed
   call. Even a single reported bucket cannot establish that attribution.
   Keep the turn's Observed evidence and refresh only the operator projection. *)
let read_codex_after_spent_usage_refusal ~clock ~cwd ~scope codex =
  read_client_in_background ~clock ~cwd ~scope (fun ~mgr ~clock ~cwd ~scope ->
    Result.map
      (fun (_observed_at, _report) ->
        Log.Runtime_agent.info
          "Codex usage read for %s has no rejected limit_id attribution; keeping the refusal observation without a reset"
          (Runtime_quota_window.scope_to_string scope))
      (read_codex_report ~mgr ~clock ~cwd ~scope codex))
;;

let http_read_of_runtime (rt : Runtime_instance.t) =
  match how_of_runtime rt with
  | Some (Http http) -> Some http
  | Some (Codex _ | Antigravity _) | None -> None
;;

type account_refusal_skip =
  | No_usage_read
  | Scope_already_resting
  | Already_reading
  | No_net_or_clock

type account_refusal_outcome =
  | Read of account_refusal_read
  | Read_failed of http_error
  | Read_raised of string
  | Skipped of account_refusal_skip

let account_refusal_skip_to_string = function
  | No_usage_read -> "the provider declares no usage-read"
  | Scope_already_resting -> "the scope already rests"
  | Already_reading -> "a read for the scope is already running"
  | No_net_or_clock -> "no Eio net or clock"
;;

let fetch_of_context () =
  match Eio_context.get_net_opt (), Eio_context.get_clock_opt () with
  | Some net, Some clock -> Some (fun ~api_key url -> get_usage ~net ~clock ~api_key url)
  | None, _ | _, None -> None
;;

let read_runtime_after_account_refusal ?fetch (rt : Runtime_instance.t) =
  let scope = Runtime_instance.quota_scope_of_runtime rt in
  let outcome =
    match http_read_of_runtime rt with
    | None -> Skipped No_usage_read
    | Some http ->
      (* A sibling on the same account refused a moment ago and its read
         already rests the scope; the walk has nothing more to learn. *)
      if Runtime_quota_window.is_exhausted ~scope ~now:(Time_compat.now ())
      then Skipped Scope_already_resting
      else (
        let fetch =
          match fetch with
          | Some fetch -> Some fetch
          | None -> fetch_of_context ()
        in
        match fetch with
        | None -> Skipped No_net_or_clock
        | Some fetch ->
          if not (claim scope)
          then Skipped Already_reading
          else
            Fun.protect
              ~finally:(fun () -> release scope)
              (fun () ->
                match read_after_account_refusal ~fetch ~scope http with
                | Ok read -> Read read
                | Error error -> Read_failed error
                | exception (Eio.Cancel.Cancelled _ as cancelled) -> raise cancelled
                (* The request carried the key and nothing bounds what an
                   HTTP client's exception message quotes: keep the
                   constructor only. *)
                | exception exn -> Read_raised (Printexc.exn_slot_name exn)))
  in
  let scope_label = Runtime_quota_window.scope_to_string scope in
  (match outcome with
   | Read read ->
     Log.Runtime_agent.info
       "provider usage read after a 403 for %s: %s"
       scope_label
       (account_refusal_read_to_string read)
   | Read_failed error ->
     Log.Runtime_agent.warn
       "provider usage read after a 403 failed for %s: %s"
       scope_label
       (http_error_to_string error)
   | Read_raised name ->
     Log.Runtime_agent.warn "provider usage read after a 403 raised for %s: %s" scope_label name
   | Skipped skip ->
     Log.Runtime_agent.info
       "provider usage not read after a 403 for %s: %s"
       scope_label
       (account_refusal_skip_to_string skip));
  outcome
;;
