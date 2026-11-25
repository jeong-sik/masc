(** Unified Keeper projection for persistent ACP v1 official runtimes
    (Antigravity, Kimi Code, Mistral Vibe, Muse Code). *)

open Result.Syntax
module Host = Keeper_official_client_host
module Session_store = Keeper_official_client_session_store
module Acp = Runtime_acp_client
module Muse_log = Runtime_muse_session_log

let config_error = Host.config_error
let internal_error = Host.internal_error
let rollover_threshold = 0.80
let unbounded_start_capacity_bytes = max_int
let idle_ttl_s = 1800.0
let rollover_subdir = "acp-rollover"

let valid_rollover_keeper_id keeper_id =
  keeper_id <> ""
  && keeper_id <> "."
  && keeper_id <> ".."
  && not (String.contains keeper_id '/')
  && not (String.contains keeper_id '\\')
;;

(* In an append-only ACP session, a strict drop in reported context occupancy
   between consecutive turns structurally indicates native compaction/reset. *)
let compaction_detected ~prev_used ~cur_used =
  match prev_used, cur_used with
  | Some prev, Some cur when prev > 0 && cur > 0 -> cur < prev
  | _ -> false
;;

(* Both values are counted or declared, never estimated: the window the agent
   reports ([usage_update.size]) and the operator's declared limit. The
   smaller one is where this session ends. *)
let effective_context_limit_tokens ~context_size ~(input_limit : Llm_provider.Input_budget.t) =
  let limit = Llm_provider.Input_budget.to_int input_limit in
  match context_size with
  | Some size when size > 0 -> min size limit
  | Some _ | None -> limit
;;

(* A session that has used [rollover_threshold] of its window by the agent's
   own count ends after this turn, and the next turn opens a fresh one. *)
type rollover =
  { used_tokens : int
  ; limit_tokens : int
  }

let rollover_of_usage ~context_used ~context_size ~input_limit =
  let limit_tokens = effective_context_limit_tokens ~context_size ~input_limit in
  match context_used with
  | Some used_tokens
    when used_tokens > 0
         && Float.of_int used_tokens /. Float.of_int limit_tokens >= rollover_threshold ->
    Some { used_tokens; limit_tokens }
  | Some _ | None -> None
;;

let rollover_dir_for_base_path ~base_path =
  Filename.concat
    (Filename.concat
       (Common.masc_dir_from_base_path ~base_path)
       Config_dir_resolver.runtime_dirname)
    rollover_subdir
;;

let rollover_marker_path ~base_path ~keeper_id =
  Filename.concat (rollover_dir_for_base_path ~base_path) (keeper_id ^ ".json")
;;

let record_rollover_marker ~base_path ~keeper_id ~runtime_id ~session_id =
  if valid_rollover_keeper_id keeper_id
  then (
    let dir = rollover_dir_for_base_path ~base_path in
    let path = rollover_marker_path ~base_path ~keeper_id in
    let payload =
      `Assoc [ "runtime_id", `String runtime_id; "session_id", `String session_id ]
      |> Yojson.Safe.to_string
    in
    try
      Fs_compat.mkdir_p dir;
      ignore (Fs_compat.save_file_atomic path payload : (unit, string) result)
    with
    | Sys_error _ | Unix.Unix_error _ -> ())
;;

let rollover_marker_matches ~base_path ~keeper_id ~runtime_id ~session_id =
  if not (valid_rollover_keeper_id keeper_id)
  then false
  else (
    let path = rollover_marker_path ~base_path ~keeper_id in
    if not (Sys.file_exists path)
    then false
    else (
      match Fs_compat.load_file path with
      | raw ->
        (match Yojson.Safe.from_string raw with
         | `Assoc fields ->
           (match List.assoc_opt "runtime_id" fields, List.assoc_opt "session_id" fields with
            | Some (`String rt), Some (`String sid) ->
              String.equal rt runtime_id && String.equal sid session_id
            | _ -> false)
         | _ -> false
         | exception (Yojson.Json_error _ | Failure _) -> false)
      | exception (Sys_error _ | Unix.Unix_error _) -> false))
;;

let clear_rollover_marker ~base_path ~keeper_id =
  if valid_rollover_keeper_id keeper_id
  then (
    let path = rollover_marker_path ~base_path ~keeper_id in
    try if Sys.file_exists path then Unix.unlink path with
    | Sys_error _ | Unix.Unix_error _ -> ())
;;

let prefer_handoff_for_start ~planned_fresh_rollover ~force_fresh_retry =
  planned_fresh_rollover || force_fresh_retry
;;

let is_non_carried_message (m : Agent_core.Types.message) =
  m.role <> Agent_core.Types.System && not (Host.is_carried_on_resume m)
;;

let hydrate_start_messages ?(appended_nudges = []) ~keepers_dir ~keeper_id ~prefer_handoff messages =
  if prefer_handoff
  then (
    match Keeper_canonical_turn_store.load_handoff_context ~keepers_dir ~keeper_id with
    | Ok handoff when handoff.messages <> [] ->
      let carried_system =
        List.filter
          (fun (m : Agent_core.Types.message) ->
             m.role = Agent_core.Types.System || Host.is_carried_on_resume m)
          messages
      in
      let safe_nudges = List.filter is_non_carried_message appended_nudges in
      carried_system @ handoff.messages @ safe_nudges
    | Ok _ | Error _ ->
      (match
         Keeper_canonical_turn_store.hydrate_missing_turns
           ~keepers_dir
           ~keeper_id
           ~existing_messages:messages
       with
       | Ok [] -> messages
       | Ok extra_msgs -> messages @ extra_msgs
       | Error _ -> messages))
  else (
    match
      Keeper_canonical_turn_store.hydrate_missing_turns
        ~keepers_dir
        ~keeper_id
        ~existing_messages:messages
    with
    | Ok [] -> messages
    | Ok extra_msgs -> messages @ extra_msgs
    | Error err ->
      Log.Keeper.warn
        ~keeper_name:keeper_id
        "canonical handoff context load skipped for ACP start: %s"
        (Keeper_canonical_turn_store.store_error_to_string err);
      messages)
;;

let runtime_label_of_driver driver =
  "ACP(" ^ Acp.driver_to_string driver ^ ")"
;;

let acp_error_to_core_error = function
  | Acp.Invalid_config detail -> config_error ~field:"acp" detail
  | Acp.Spawn_refused refusal ->
    Agent_core.Error.Provider
      (Llm_provider.Error.ProviderUnavailable
         { provider = "acp"
         ; detail =
             "ACP client spawn refused: " ^ Process_eio.spawn_refusal_to_string refusal
         })
  | Acp.Protocol_error { stage; detail } ->
    Agent_core.Error.Provider
      (Llm_provider.Error.ParseError
         { detail = Printf.sprintf "ACP protocol error (%s): %s" stage detail })
  | Acp.Rpc_error { method_name; code; message; refusal; _ } as rpc_err ->
    let detail = Acp.error_to_string rpc_err in
    (match refusal with
     | Some (Llm_provider.Retry.Signal_context_overflow { limit; _ }) ->
       Agent_core.Error.Api
         (Agent_core.Retry.ContextOverflow
            { message =
                Printf.sprintf "ACP RPC %s context overflow (%d): %s" method_name code message
            ; limit
            })
     | Some (Llm_provider.Retry.Signal_request_body_too_large _) ->
       Agent_core.Error.Api
         (Agent_core.Retry.InvalidRequest
            { message = detail
            ; reason = Agent_core.Retry.Request_body_refused_by_provider { status = 413 }
            })
     | Some (Llm_provider.Retry.Signal_hard_quota { retry_after; _ }) ->
       Agent_core.Error.Provider
         (Llm_provider.Error.HardQuota { provider = "acp"; retry_after; detail })
     | Some (Llm_provider.Retry.Signal_rate_limited { retry_after; _ }) ->
       Agent_core.Error.Provider
         (Llm_provider.Error.RateLimit { provider = "acp"; retry_after; detail })
     | Some (Llm_provider.Retry.Signal_auth_error _) ->
       Agent_core.Error.Provider
         (Llm_provider.Error.AuthError { provider = "acp"; detail })
     | Some (Llm_provider.Retry.Signal_authorization_error _) ->
       Agent_core.Error.Provider
         (Llm_provider.Error.AuthorizationError { provider = "acp"; detail })
     | Some (Llm_provider.Retry.Signal_provider_unavailable _) ->
       Agent_core.Error.Provider
         (Llm_provider.Error.ProviderUnavailable { provider = "acp"; detail })
     | None ->
       Agent_core.Error.Provider
         (Llm_provider.Error.ProviderReportedError
            { provider = "acp"
            ; error_type = Some (Printf.sprintf "rpc_%d" code)
            ; detail
            }))
  | Acp.Timeout { stage; timeout_s } ->
    Agent_core.Error.Api
      (Agent_core.Retry.Timeout
         { message = Printf.sprintf "ACP timeout in %s after %.1fs" stage timeout_s
         ; phase = None
         })
  | Acp.Process_exited { detail; stderr_tail } ->
    let tail = String.trim stderr_tail in
    let detail =
      if tail = ""
      then "ACP process exited: " ^ detail
      else Printf.sprintf "ACP process exited: %s (stderr: %s)" detail tail
    in
    Agent_core.Error.Provider
      (Llm_provider.Error.ProviderUnavailable { provider = "acp"; detail })
  | Acp.Client_closed ->
    Agent_core.Error.Provider
      (Llm_provider.Error.ProviderUnavailable
         { provider = "acp"; detail = "ACP client closed" })
;;

(* Preserve a healthy persistent ACP child across upstream quota / rate-limit
   RPC refusals so quota exhaustion does not trigger infinite CLI respawn
   storms. Transport, timeout, protocol, and non-quota RPC failures still evict
   the entry to keep session state clean. *)
let should_evict_persistent_child_on_error = function
  | Acp.Rpc_error { refusal; _ } ->
    (match refusal with
     | Some (Llm_provider.Retry.Signal_hard_quota _ | Llm_provider.Retry.Signal_rate_limited _) -> false
     | Some (Llm_provider.Retry.Signal_context_overflow _)
     | Some (Llm_provider.Retry.Signal_request_body_too_large _)
     | Some (Llm_provider.Retry.Signal_auth_error _)
     | Some (Llm_provider.Retry.Signal_authorization_error _)
     | Some (Llm_provider.Retry.Signal_provider_unavailable _)
     | None -> true)
  | Acp.Invalid_config _
  | Acp.Spawn_refused _
  | Acp.Protocol_error _
  | Acp.Timeout _
  | Acp.Process_exited _
  | Acp.Client_closed -> true
;;

let recovery_failure_of_acp_error = function
  | Acp.Invalid_config _ -> Session_store.Pre_dispatch_failed
  | Acp.Spawn_refused refusal -> Session_store.recovery_failure_of_spawn_refusal refusal
  | Acp.Protocol_error _ -> Session_store.Protocol_failed
  | Acp.Rpc_error { refusal = Some (Llm_provider.Retry.Signal_context_overflow _); _ } ->
    Session_store.Input_rejected Session_store.Bootstrap_floor_exceeded
  | Acp.Rpc_error
      { refusal =
          ( None
          | Some
              ( Llm_provider.Retry.Signal_request_body_too_large _
              | Llm_provider.Retry.Signal_hard_quota _
              | Llm_provider.Retry.Signal_rate_limited _
              | Llm_provider.Retry.Signal_auth_error _
              | Llm_provider.Retry.Signal_authorization_error _
              | Llm_provider.Retry.Signal_provider_unavailable _ ) )
      ; _
      } -> Session_store.Provider_rejected
  | Acp.Timeout _ -> Session_store.Transport_interrupted
  | Acp.Process_exited _ -> Session_store.Transport_interrupted
  | Acp.Client_closed -> Session_store.Transport_interrupted
;;

let classify_prompt_error ~is_gate_continuation ~activity_observed = function
  | Acp.Rpc_error
      { method_name
      ; code
      ; message
      ; refusal = Some (Llm_provider.Retry.Signal_context_overflow _)
      ; _
      } as rpc_err ->
    if is_gate_continuation
    then
      ( Session_store.Vendor_session_full
          (if activity_observed
           then Session_store.Activity_observed
           else Session_store.No_activity_observed)
      , Agent_core.Error.Provider
          (Llm_provider.Error.ProviderReportedError
             { provider = "acp"
             ; error_type = Some (Printf.sprintf "rpc_%d" code)
             ; detail =
                 Printf.sprintf
                   "ACP Gate continuation session full in %s (%d): %s"
                   method_name
                   code
                   message
             }) )
    else if activity_observed
    then
      ( Session_store.Input_rejected Session_store.Effect_fenced
      , Agent_core.Error.Provider
          (Llm_provider.Error.ProviderReportedError
             { provider = "acp"
             ; error_type = Some (Printf.sprintf "rpc_%d" code)
             ; detail =
                 Printf.sprintf
                   "ACP RPC %s context overflow after observed activity (%d): %s"
                   method_name
                   code
                   message
             }) )
    else
      ( Session_store.Input_rejected Session_store.Bootstrap_floor_exceeded
      , acp_error_to_core_error rpc_err )
  | ( Acp.Invalid_config _
    | Acp.Spawn_refused _
    | Acp.Protocol_error _
    | Acp.Rpc_error
        { refusal =
            ( None
            | Some
                ( Llm_provider.Retry.Signal_request_body_too_large _
                | Llm_provider.Retry.Signal_hard_quota _
                | Llm_provider.Retry.Signal_rate_limited _
                | Llm_provider.Retry.Signal_auth_error _
                | Llm_provider.Retry.Signal_authorization_error _
                | Llm_provider.Retry.Signal_provider_unavailable _ ) )
        ; _
        }
    | Acp.Timeout _
    | Acp.Process_exited _
    | Acp.Client_closed ) as err ->
    recovery_failure_of_acp_error err, acp_error_to_core_error err
;;

let should_evict_on_session_setup_error = function
  | Acp.Timeout _ | Acp.Protocol_error _ | Acp.Process_exited _ | Acp.Client_closed -> true
  | Acp.Invalid_config _ | Acp.Spawn_refused _ | Acp.Rpc_error _ -> false
;;

let api_usage_of_acp_usage ~driver (u : Acp.usage) : Agent_core.Types.api_usage =
  let normalized = Acp.normalize_usage driver u in
  { Agent_core.Types.input_tokens = normalized.input_tokens
  ; output_tokens = normalized.output_tokens
  ; cache_creation_input_tokens = normalized.cache_creation_input_tokens
  ; cache_read_input_tokens = normalized.cache_read_input_tokens
  ; cost_usd = None
  }
;;

let usage_is_nonzero (u : Agent_core.Types.api_usage) =
  u.input_tokens > 0
  || u.output_tokens > 0
  || u.cache_creation_input_tokens > 0
  || u.cache_read_input_tokens > 0
;;

(* A Muse turn's token counts come from the host's session journal. The ledger
   and the response hold the sum of the model requests, the approval reviews
   and the observers' requests; this line is where the three can be told
   apart. An observer still running or linked without a journal adds nothing,
   and the line counts them. A journal that could not be read leaves the turn
   without counts, and the line says why. *)
let log_usage_source ~keeper_name ~turn_id (source : Acp.usage_source) =
  match source with
  | Acp.Usage_from_acp -> ()
  | Acp.Usage_from_muse_journal turn ->
    let main = turn.Muse_log.main
    and review = turn.Muse_log.review
    and observers = turn.Muse_log.observers in
    let observer_counts = observers.Muse_log.counts in
    Log.Keeper.info
      ~keeper_name
      "Muse turn usage turn_id=%s requests=%d input=%d cache_read=%d output=%d reasoning=%d \
       reviews=%d review_input=%d review_cache_read=%d review_output=%d review_reasoning=%d \
       observers=%d observers_running=%d observers_without_journal=%d observer_input=%d \
       observer_cache_read=%d observer_output=%d observer_reasoning=%d"
      turn_id
      turn.Muse_log.main_requests
      main.Muse_log.input_tokens
      main.Muse_log.cache_read_tokens
      main.Muse_log.output_tokens
      main.Muse_log.reasoning_tokens
      turn.Muse_log.reviews
      review.Muse_log.input_tokens
      review.Muse_log.cache_read_tokens
      review.Muse_log.output_tokens
      review.Muse_log.reasoning_tokens
      observers.Muse_log.finished
      observers.Muse_log.running
      observers.Muse_log.without_journal
      observer_counts.Muse_log.input_tokens
      observer_counts.Muse_log.cache_read_tokens
      observer_counts.Muse_log.output_tokens
      observer_counts.Muse_log.reasoning_tokens
  | Acp.Usage_unreadable err ->
    Log.Keeper.warn
      ~keeper_name
      "Muse turn usage unreadable turn_id=%s: %s"
      turn_id
      (Muse_log.error_to_string err)
;;

let effective_context_used ~driver (u : Acp.usage) =
  match u.context_used with
  | Some n when n > 0 -> Some n
  | Some _ | None ->
    let normalized = Acp.normalize_usage driver u in
    if normalized.input_tokens > 0 then Some normalized.input_tokens else None
;;

let process_config_sha256
      ~(native_posture : Runtime_native_tools.posture)
      ~(skills_dirs : string list)
      (config : Runtime_execution.acp_client)
  =
  let strings xs = `List (List.map (fun s -> `String s) xs) in
  let payload =
    `Assoc
      [ "driver", `String (Acp.driver_to_string config.driver)
      ; "cli_path", `String config.cli_path
      ; "args", strings config.args
      ; "strip_env", strings config.strip_env
      ; "skills_dirs", strings skills_dirs
      ; "contributor_mode", `String (Acp.contributor_mode_to_string config.contributor_mode)
      ; "oauth_source_present", `Bool (Option.is_some config.oauth_source)
      ; "oauth_source", `String (Option.value config.oauth_source ~default:"")
      ; "native_posture", `String (Runtime_native_tools.to_string native_posture)
      ]
    |> Yojson.Safe.to_string
  in
  Agent_core_sha256.(digest_string payload |> to_hex)
;;

let stop_reason_of_acp_stop_reason : Acp.stop_reason -> Agent_core.Types.stop_reason = function
  | Acp.End_turn -> Agent_core.Types.EndTurn
  | Acp.Max_tokens -> Agent_core.Types.MaxTokens
  | Acp.Refusal -> Agent_core.Types.Refusal
  | Acp.Max_turn_requests -> Agent_core.Types.PauseTurn
  | Acp.Cancelled -> Agent_core.Types.PauseTurn
  | Acp.Other_stop_reason _ -> Agent_core.Types.PauseTurn
;;

let provider_turn_identity ~session_id ~turn_count =
  Printf.sprintf "acp:%s:%d" session_id turn_count
;;

let tool_spec (tool : Host.dynamic_tool) : Yojson.Safe.t =
  `Assoc
    [ "name", `String tool.name
    ; "description", `String tool.description
    ; "inputSchema", tool.input_schema
    ]
;;

let find_tool (tools : Host.dynamic_tool list) name =
  List.find_opt (fun (tool : Host.dynamic_tool) -> String.equal tool.name name) tools
;;

let tool_result (result : Host.dynamic_tool_result) : Runtime_official_client_mcp.tool_result =
  { Runtime_official_client_mcp.success = result.success
  ; content = result.content
  ; content_blocks = result.content_blocks
  }
;;

(* ── Per-Keeper persistent ACP process & MCP bridge pool ──────────────────── *)

type active_turn_binding =
  { client : Acp.t
  ; tools : Host.dynamic_tool list
  ; on_tool_started :
      call_id:string -> tool_name:string -> arguments:Yojson.Safe.t -> bool
  ; on_tool_finished : call_id:string -> unit
  }

module Pool_key = struct
  type t =
    { keeper_name : string
    ; runtime_id : string
    ; tool_surface_sha256 : string
    ; process_config_sha256 : string
    ; cwd : string
    ; dangerously_skip_permissions : bool
    }

  let equal a b =
    String.equal a.keeper_name b.keeper_name
    && String.equal a.runtime_id b.runtime_id
    && String.equal a.tool_surface_sha256 b.tool_surface_sha256
    && String.equal a.process_config_sha256 b.process_config_sha256
    && String.equal a.cwd b.cwd
    && Bool.equal a.dangerously_skip_permissions b.dangerously_skip_permissions
  ;;

  let hash k =
    Hashtbl.hash
      ( k.keeper_name
      , k.runtime_id
      , k.tool_surface_sha256
      , k.process_config_sha256
      , k.cwd
      , k.dangerously_skip_permissions )
  ;;
end

module Pool_tbl = Hashtbl.Make (Pool_key)

module Keeper_pool = struct
  type 'a t =
    { table : 'a Pool_tbl.t
    ; mutex : Stdlib.Mutex.t
    }

  let create () = { table = Pool_tbl.create 16; mutex = Stdlib.Mutex.create () }

  let with_lock t f =
    Stdlib.Mutex.lock t.mutex;
    match f () with
    | v ->
      Stdlib.Mutex.unlock t.mutex;
      v
    | exception exn ->
      Stdlib.Mutex.unlock t.mutex;
      raise exn
  ;;

  let count t = with_lock t (fun () -> Pool_tbl.length t.table)
  let find_opt t key = with_lock t (fun () -> Pool_tbl.find_opt t.table key)

  let install_for_keeper t ~(key : Pool_key.t) ~fresh ~is_alive ~close =
    let winner, to_close =
      with_lock t (fun () ->
        match Pool_tbl.find_opt t.table key with
        | Some current when is_alive current -> current, [ fresh ]
        | Some _ | None ->
          (* Enforce at most one live persistent ACP entry per Keeper: any
             superseded key (runtime_id, cwd, tool_surface_sha256, or posture
             switch) and any dead entry at [key] is atomically evicted here. *)
          let stale =
            Pool_tbl.fold
              (fun (k : Pool_key.t) entry acc ->
                 if String.equal k.keeper_name key.keeper_name
                 then (k, entry) :: acc
                 else acc)
              t.table
              []
          in
          List.iter (fun (k, _) -> Pool_tbl.remove t.table k) stale;
          Pool_tbl.replace t.table key fresh;
          fresh, List.map snd stale)
    in
    List.iter close to_close;
    winner
  ;;

  let evict_if_same t ~key ~target ~close =
    let removed =
      with_lock t (fun () ->
        match Pool_tbl.find_opt t.table key with
        | Some current when current == target ->
          Pool_tbl.remove t.table key;
          Some current
        | Some _ | None -> None)
    in
    Option.iter close removed
  ;;

  let evict_keeper t ~keeper_name ~close =
    let matching =
      with_lock t (fun () ->
        let entries =
          Pool_tbl.fold
            (fun (key : Pool_key.t) entry acc ->
               if String.equal key.keeper_name keeper_name then (key, entry) :: acc else acc)
            t.table
            []
        in
        List.iter (fun (key, _) -> Pool_tbl.remove t.table key) entries;
        List.map snd entries)
    in
    List.iter close matching
  ;;

  let evict_all t ~close =
    let entries =
      with_lock t (fun () ->
        let all = Pool_tbl.fold (fun _ entry acc -> entry :: acc) t.table [] in
        Pool_tbl.clear t.table;
        all)
    in
    List.iter close entries
  ;;

  let evict_idle t ~now ~idle_ttl_s ~last_used_at ~is_busy ~close =
    let stale =
      with_lock t (fun () ->
        let entries =
          Pool_tbl.fold
            (fun key entry acc ->
               if (not (is_busy entry)) && now -. last_used_at entry >= idle_ttl_s
               then (key, entry) :: acc
               else acc)
            t.table
            []
        in
        List.iter (fun (key, _) -> Pool_tbl.remove t.table key) entries;
        List.map snd entries)
    in
    List.iter close stale
  ;;
end

type pool_entry =
  { client : Acp.t
  ; bridge : Runtime_official_client_mcp_http.t
  ; mcp_server : Acp.mcp_http_server
  ; acp_cwd : string
  ; turn_slot : active_turn_binding option ref
  ; turn_slot_mutex : Stdlib.Mutex.t
  ; turn_mutex : Eio.Mutex.t
  ; in_flight : bool Atomic.t
  ; mutable last_used_at : float
  ; mutable session_id : string option
  ; mutable session_info : Acp.session_info option
  ; mutable last_context_used : int option
  ; stop_owner : unit -> unit
  }

let pool : pool_entry Keeper_pool.t = Keeper_pool.create ()
let root_switch_mu = Stdlib.Mutex.create ()
let registered_root_switch : Eio.Switch.t option ref = ref None

let close_pool_entry (entry : pool_entry) =
  Eio.Cancel.protect (fun () ->
    Acp.close entry.client;
    entry.stop_owner ())
;;

let with_slot_lock mutex f =
  Stdlib.Mutex.lock mutex;
  match f () with
  | v ->
    Stdlib.Mutex.unlock mutex;
    v
  | exception exn ->
    Stdlib.Mutex.unlock mutex;
    raise exn
;;

let evict_entry_if_same key (target : pool_entry) =
  Keeper_pool.evict_if_same pool ~key ~target ~close:close_pool_entry
;;

let evict_keeper ~keeper_name =
  Keeper_pool.evict_keeper pool ~keeper_name ~close:close_pool_entry
;;

let evict_keeper_for_workspace ~base_path ~keeper_name =
  evict_keeper ~keeper_name;
  clear_rollover_marker ~base_path ~keeper_id:keeper_name
;;

let evict_all () =
  Keeper_pool.evict_all pool ~close:close_pool_entry
;;

let ensure_root_switch_cleanup root_sw =
  let needs_register =
    Stdlib.Mutex.protect root_switch_mu (fun () ->
      match !registered_root_switch with
      | Some existing when existing == root_sw -> false
      | Some _ | None ->
        registered_root_switch := Some root_sw;
        true)
  in
  if needs_register
  then
    Eio.Switch.on_release root_sw (fun () ->
      Stdlib.Mutex.protect root_switch_mu (fun () ->
        match !registered_root_switch with
        | Some existing when existing == root_sw -> registered_root_switch := None
        | Some _ | None -> ());
      evict_all ())
;;

(* Serialize turns on a pooled entry's [Eio.Mutex.t].
   Because [Eio.Mutex.use_rw] permanently poisons the mutex whenever its body
   raises (including [Eio.Cancel.Cancelled]), the holder MUST evict the pooled
   entry BEFORE unwinding out of [use_rw] so no subsequent turn can inherit a
   poisoned mutex or a half-cancelled vendor session. A waiter cancelled before
   acquiring the mutex unwinds without entering the body and leaves the active
   holder untouched; a waiter observing [Eio.Mutex.Poisoned] from a failing
   holder receives a typed [Client_closed] error rather than an uncaught
   exception. *)
let run_serialized_turn
      ~(mutex : Eio.Mutex.t)
      ~(on_holder_exception : unit -> unit)
      (f : unit -> ('a, Agent_core.Error.t) result)
  : ('a, Agent_core.Error.t) result
  =
  try
    Eio.Mutex.use_rw ~protect:false mutex (fun () ->
      try f ()
      with
      | exn ->
        let bt = Printexc.get_raw_backtrace () in
        on_holder_exception ();
        Printexc.raise_with_backtrace exn bt)
  with
  | Eio.Mutex.Poisoned _ -> Error (acp_error_to_core_error Acp.Client_closed)
;;

let start_mcp_bridge ~driver ~keeper_name ~sw ~env ~pinned_tool_specs ~turn_slot ~turn_slot_mutex =
  Runtime_official_client_mcp_http.start
    ~sw
    ~net:(Eio.Stdenv.net env)
    ~secure_random:(Eio.Stdenv.secure_random env)
    (* The bridge is named for its Keeper here, once. The policy and the
       stream projection read the name back from the started bridge, never
       from the driver. *)
    ~server_name:(Acp.bridge_server_name driver ~owner:keeper_name)
    (* Pool_key pins tool_surface_sha256, so returning the pinned tool schemas
       unconditionally ensures tools/list serves the full MASC tool catalog
       during Acp.start and session/new before any turn_slot is bound. *)
    ~tool_specs:(fun () -> pinned_tool_specs)
    ~tool_execution_mode:(fun ~name ~arguments ->
      let binding = with_slot_lock turn_slot_mutex (fun () -> !turn_slot) in
      match binding with
      | None -> None
      | Some b ->
        find_tool b.tools name
        |> Option.map (fun (tool : Host.dynamic_tool) -> tool.execution_mode arguments))
    ~call_tool:(fun ~name ~call_id ~arguments ->
      let binding = with_slot_lock turn_slot_mutex (fun () -> !turn_slot) in
      match binding with
      | None -> None
      | Some b ->
        find_tool b.tools name
        |> Option.map (fun (tool : Host.dynamic_tool) ->
          if not (b.on_tool_started ~call_id ~tool_name:name ~arguments)
          then
            { Runtime_official_client_mcp_http.outcome =
                { Runtime_official_client_mcp.success = false
                ; content =
                    "ACP turn has already closed or call_id is already active; tool call was not dispatched"
                ; content_blocks = None
                }
            ; stop = None
            ; after_response_sent = ignore
            }
          else
            Fun.protect
              ~finally:(fun () ->
                Eio.Cancel.protect (fun () -> b.on_tool_finished ~call_id))
              (fun () ->
                Acp.with_external_activity b.client (fun () ->
                  let result = tool.call ~call_id arguments in
                  let on_response_sent =
                    Runtime_official_client_tool.response_observer Mcp result
                  in
                  { Runtime_official_client_mcp_http.outcome = tool_result result
                  ; stop = result.abort_turn
                  ; after_response_sent =
                      (fun () ->
                        Runtime_official_client_tool.notify_response_sent on_response_sent)
                  }))))
    ()
;;

let discover_skills_dirs ~base_path (config : Runtime_execution.acp_client) =
  let candidates =
    config.skills_dirs
    @ [ Filename.concat base_path ".masc/skills"
      ; Filename.concat base_path ".agents/skills"
      ]
  in
  List.filter (fun dir -> String.trim dir <> "" && Sys.file_exists dir) candidates
  |> List.sort_uniq String.compare
;;

let spawn_persistent_entry
      ~root_sw
      ~env
      ~proc_mgr
      ~clock
      ~(key : Pool_key.t)
      ~native_posture
      ~skills_dirs
      ~pinned_tool_specs
      ~(config : Runtime_execution.acp_client)
  : (pool_entry, Acp.error) result
  =
  let ready_promise, resolve_ready = Eio.Promise.create () in
  let shutdown_promise, resolve_shutdown = Eio.Promise.create () in
  let stop_flag = Atomic.make false in
  let stop_owner () =
    if Atomic.compare_and_set stop_flag false true
    then Eio.Promise.resolve resolve_shutdown ()
  in
  let turn_slot = ref None in
  let turn_slot_mutex = Stdlib.Mutex.create () in
  Eio.Fiber.fork_daemon ~sw:root_sw (fun () ->
    (try
       Eio.Switch.run (fun keeper_sw ->
         if Atomic.get stop_flag
         then Eio.Promise.resolve resolve_ready (Error Acp.Client_closed)
         else (
           let acp_cwd_res =
             match native_posture with
             | Runtime_native_tools.Native_none ->
               Acp.create_isolated_workspace ~sw:keeper_sw ~prefix:("keeper-" ^ key.keeper_name) ()
             | Runtime_native_tools.Native_read | Runtime_native_tools.Native_full ->
               Ok key.cwd
           in
           match acp_cwd_res with
           | Error err -> Eio.Promise.resolve resolve_ready (Error err)
           | Ok acp_cwd ->
             let bridge =
               start_mcp_bridge
                 ~driver:config.driver
                 ~keeper_name:key.keeper_name
                 ~sw:keeper_sw
                 ~env
                 ~pinned_tool_specs
                 ~turn_slot
                 ~turn_slot_mutex
             in
             let mcp_server = Acp.mcp_http_server_of_bridge bridge in
             let acp_config : Acp.config =
               { driver = config.driver
               ; cli_path = config.cli_path
               ; args = config.args
               ; strip_env = config.strip_env
               ; skills_dirs
               ; contributor_mode = config.contributor_mode
               ; cwd = acp_cwd
               ; oauth_source = config.oauth_source
               ; dangerously_skip_permissions = key.dangerously_skip_permissions
               ; admission_timeout_s = config.admission_timeout_s
               }
             in
             match
               Acp.start
                 ~sw:keeper_sw
                 ~proc_mgr
                 ~clock
                 ~fs:(Eio.Stdenv.fs env)
                 ~config:acp_config
                 ~mcp_server
                 ~native_posture
                 ()
             with
             | Error err -> Eio.Promise.resolve resolve_ready (Error err)
             | Ok client ->
               if Atomic.get stop_flag
               then (
                 Acp.close client;
                 Eio.Promise.resolve resolve_ready (Error Acp.Client_closed))
               else (
                 let entry =
                   { client
                   ; bridge
                   ; mcp_server
                   ; acp_cwd
                   ; turn_slot
                   ; turn_slot_mutex
                   ; turn_mutex = Eio.Mutex.create ()
                   ; in_flight = Atomic.make false
                   ; last_used_at = Time_compat.now ()
                   ; session_id = None
                   ; session_info = None
                   ; last_context_used = None
                   ; stop_owner
                   }
                 in
                 Eio.Switch.on_release keeper_sw (fun () ->
                   Keeper_pool.evict_if_same pool ~key ~target:entry ~close:ignore);
                 Eio.Promise.resolve resolve_ready (Ok entry);
                 Eio.Promise.await shutdown_promise)))
     with
     | Eio.Cancel.Cancelled _ as exn ->
       (match Eio.Promise.peek ready_promise with
        | None -> Eio.Promise.resolve resolve_ready (Error Acp.Client_closed)
        | Some _ -> ());
       raise exn
     | exn ->
       (match Eio.Promise.peek ready_promise with
        | None ->
          Eio.Promise.resolve
            resolve_ready
            (Error (Acp.Protocol_error { stage = "persistent_spawn"; detail = Printexc.to_string exn }))
        | Some _ -> ()));
    `Stop_daemon);
  try Eio.Promise.await ready_promise with
  | Eio.Cancel.Cancelled _ as exn ->
    Eio.Cancel.protect (fun () ->
      stop_owner ();
      match Eio.Promise.peek ready_promise with
      | Some (Ok entry) -> close_pool_entry entry
      | Some (Error _) | None -> ());
    raise exn
;;

let acquire_persistent_entry
      ~root_sw
      ~env
      ~proc_mgr
      ~clock
      ~(key : Pool_key.t)
      ~native_posture
      ~skills_dirs
      ~pinned_tool_specs
      ~(config : Runtime_execution.acp_client)
  : (pool_entry, Acp.error) result
  =
  ensure_root_switch_cleanup root_sw;
  Keeper_pool.evict_idle
    pool
    ~now:(Time_compat.now ())
    ~idle_ttl_s
    ~last_used_at:(fun entry -> entry.last_used_at)
    ~is_busy:(fun entry -> Atomic.get entry.in_flight)
    ~close:close_pool_entry;
  let existing = Keeper_pool.find_opt pool key in
  match existing with
  | Some entry when Acp.is_alive entry.client -> Ok entry
  | Some dead ->
    evict_entry_if_same key dead;
    let* fresh =
      spawn_persistent_entry
        ~root_sw
        ~env
        ~proc_mgr
        ~clock
        ~key
        ~native_posture
        ~skills_dirs
        ~pinned_tool_specs
        ~config
    in
    let winner =
      Keeper_pool.install_for_keeper
        pool
        ~key
        ~fresh
        ~is_alive:(fun entry -> Acp.is_alive entry.client)
        ~close:close_pool_entry
    in
    Ok winner
  | None ->
    let* fresh =
      spawn_persistent_entry
        ~root_sw
        ~env
        ~proc_mgr
        ~clock
        ~key
        ~native_posture
        ~skills_dirs
        ~pinned_tool_specs
        ~config
    in
    let winner =
      Keeper_pool.install_for_keeper
        pool
        ~key
        ~fresh
        ~is_alive:(fun entry -> Acp.is_alive entry.client)
        ~close:close_pool_entry
    in
    Ok winner
;;

(* ── SSE stream projection ────────────────────────────────────────────────── *)

let should_fence_tool_call_started
      ?(server_isolation = Acp.Shared_or_multi_server)
      ~native_posture
      ~mcp_server_name
      ~allowed_tool_names
      (identity : Acp.tool_call_identity)
  =
  (* Pinned MASC MCP tools report their own exact effect boundary via
     Host.dynamic_tools, and MASC-managed lazy MCP schema reads are read-only
     metadata lookups. Any foreign/unpinned MCP call, unqualified
     Implicit_mcp_kind call under Shared_or_multi_server isolation, or
     posture-disallowed native CLI tool fences same-turn retry. *)
  match identity with
  | (Acp.Mcp_tool _ | Acp.Managed_mcp_schema_read _) as mcp_or_schema ->
    not
      (Acp.should_allow_tool_call
         ~server_isolation
         ~policy:(Acp.Allow_masc_mcp_only { mcp_server_name; allowed_tool_names })
         mcp_or_schema)
  | Acp.Native_tool { kind; _ } ->
    (match native_posture with
     | Runtime_native_tools.Native_full -> true
     | Runtime_native_tools.Native_read -> not (Acp.is_read_only_tool_kind kind)
     | Runtime_native_tools.Native_none -> true)
;;

type stream_projection =
  { on_acp_event : Acp.stream_event -> unit
  ; on_tool_started :
      call_id:string -> tool_name:string -> arguments:Yojson.Safe.t -> bool
  ; on_tool_finished : call_id:string -> unit
  ; finish :
      stop_reason:Agent_core.Types.stop_reason
      -> usage:Agent_core.Types.api_usage option
      -> unit
  ; observed_tool_calls : unit -> Yojson.Safe.t
  }

let delta_usage_of_api_usage (u : Agent_core.Types.api_usage) : Agent_core.Types.delta_usage =
  { Agent_core.Types.input_tokens = Some u.input_tokens
  ; output_tokens = Some u.output_tokens
  ; cache_creation_input_tokens = Some u.cache_creation_input_tokens
  ; cache_read_input_tokens = Some u.cache_read_input_tokens
  ; cost_usd = u.cost_usd
  ; reasoning_tokens = None
  ; cache_write_lifetime = None
  }
;;

let completion_of_acp_tool_status
  : Acp.tool_call_status -> Runtime_native_tools.completion option
  = function
  | Acp.Tool_pending | Acp.Tool_in_progress -> None
  | Acp.Tool_completed ->
    Some { Runtime_native_tools.outcome = Completion_reported; exit_code = None }
  | Acp.Tool_failed ->
    Some { Runtime_native_tools.outcome = Error_reported; exit_code = None }
  | Acp.Tool_other_status s ->
    Some { Runtime_native_tools.outcome = Unrecognized_status s; exit_code = None }
;;

let native_observation_of_acp ~tool_call_id ~title ~name : Runtime_native_tools.observation =
  let identity =
    if String.trim tool_call_id <> ""
    then Some (Runtime_native_tools.Call_id tool_call_id)
    else None
  in
  let tool_name =
    match name with
    | Some n when String.trim n <> "" -> Some n
    | Some _ | None ->
      let trimmed = String.trim title in
      if trimmed <> "" then Some trimmed else None
  in
  { Runtime_native_tools.identity; tool_name; origin = Runtime_native_tools.Built_in }
;;

let make_stream_projection
      ~driver
      ~mcp_server_name
      ~server_isolation
      ~keeper_name
      ~raw_trace_run
      ~model
      ~session_id
      ~turn_count
      ~official_turn
      ~position
      ~native_posture
      ~allowed_tool_names
      ~receipts
      ~observe_effect_attempted
      ~observe_activity
      ~on_session_meta_updated
      ~on_native_action
      ~on_native_tool_completion
      ~on_usage_report
      ~on_event
  : stream_projection
  =
  let stream_mu = Stdlib.Mutex.create () in
  let message_started = ref false in
  let finished = ref false in
  let next_index = ref 0 in
  let text_index = ref None in
  let thought_index = ref None in
  let tool_indices : (string, int * bool ref) Hashtbl.t = Hashtbl.create 8 in
  let native_tool_indices : (string, int * Runtime_native_tools.observation) Hashtbl.t =
    Hashtbl.create 8
  in
  let closed_native_tool_ids : (string, unit) Hashtbl.t = Hashtbl.create 8 in
  let anonymous_native_blocks : (int * Runtime_native_tools.observation) list ref = ref [] in
  let emit_queue : Agent_core.Types.sse_event Queue.t = Queue.create () in
  let emit_draining = ref false in
  let drain_waiters : unit Eio.Promise.u list ref = ref [] in
  let tool_calls_rev : Yojson.Safe.t list ref = ref [] in
  let tool_calls_mu = Stdlib.Mutex.create () in
  let turn_id = provider_turn_identity ~session_id ~turn_count in
  let emit event =
    Option.iter
      (fun callback ->
         try callback event with
         | Eio.Cancel.Cancelled _ as exn -> raise exn
         | exn when Keeper_operator_interrupt.is_operator_interrupt exn -> raise exn
         | exn ->
           Llm_provider.Reserved_exn.reraise_if_reserved exn;
           Log.Runtime_agent.warn
             "ACP Keeper stream callback raised (error=%s)"
             (Printexc.to_string exn))
      on_event
  in
  let pop_drain_waiters_locked () =
    let waiters = !drain_waiters in
    drain_waiters := [];
    waiters
  in
  let resolve_drain_waiters waiters =
    List.iter (fun resolver -> Eio.Promise.resolve resolver ()) waiters
  in
  (* Enqueue events while holding [stream_mu] so FIFO order across ACP stdout
     and loopback MCP HTTP fibers is strictly preserved, then drain outside the
     lock so yielding callbacks never hold [stream_mu]. *)
  let enqueue_events_locked events =
    List.iter (fun ev -> Queue.add ev emit_queue) events;
    if Queue.is_empty emit_queue || !emit_draining
    then false
    else (
      emit_draining := true;
      true)
  in
  let drain_events_if_owner should_drain =
    if should_drain
    then (
      let owner_active = ref true in
      let rec drain () =
        let next_ev, waiters =
          Stdlib.Mutex.protect stream_mu (fun () ->
            match Queue.take_opt emit_queue with
            | Some _ as ev -> ev, []
            | None ->
              emit_draining := false;
              owner_active := false;
              None, pop_drain_waiters_locked ())
        in
        resolve_drain_waiters waiters;
        match next_ev with
        | None -> ()
        | Some ev ->
          emit ev;
          drain ()
      in
      Fun.protect
        ~finally:(fun () ->
          let waiters =
            Stdlib.Mutex.protect stream_mu (fun () ->
              if !owner_active
              then (
                emit_draining := false;
                owner_active := false;
                pop_drain_waiters_locked ())
              else [])
          in
          resolve_drain_waiters waiters)
        drain)
  in
  let rec drain_all_remaining () =
    let action =
      Stdlib.Mutex.protect stream_mu (fun () ->
        if Queue.is_empty emit_queue && not !emit_draining
        then `Done
        else if not !emit_draining
        then (
          emit_draining := true;
          `Drain)
        else (
          let promise, resolver = Eio.Promise.create () in
          drain_waiters := resolver :: !drain_waiters;
          `Wait promise))
    in
    match action with
    | `Done -> ()
    | `Drain ->
      drain_events_if_owner true;
      drain_all_remaining ()
    | `Wait promise ->
      (match Fs_compat.execution_context () with
       | Fs_compat.Eio_fiber ->
         Eio.Promise.await promise;
         drain_all_remaining ()
       | Fs_compat.Non_eio -> ())
  in
  let ensure_message_started_locked () =
    if !message_started
    then []
    else (
      message_started := true;
      [ Agent_core.Types.MessageStart { id = turn_id; model; usage = None } ])
  in
  let close_open_text_locked () =
    match !text_index with
    | None -> []
    | Some idx ->
      text_index := None;
      [ Agent_core.Types.ContentBlockStop { index = idx } ]
  in
  let close_open_thought_locked () =
    match !thought_index with
    | None -> []
    | Some idx ->
      thought_index := None;
      [ Agent_core.Types.ContentBlockStop { index = idx } ]
  in
  let alloc_index_locked () =
    let i = !next_index in
    incr next_index;
    i
  in
  let record_tool_call_json entry =
    Stdlib.Mutex.protect tool_calls_mu (fun () -> tool_calls_rev := entry :: !tool_calls_rev)
  in
  let record_native_tool_started ~tool_call_id ~title ~name ~raw_input =
    let observation = native_observation_of_acp ~tool_call_id ~title ~name in
    let is_new, should_drain =
      Stdlib.Mutex.protect stream_mu (fun () ->
        if !finished
        then false, false
        else if tool_call_id <> ""
                && (Hashtbl.mem native_tool_indices tool_call_id
                    || Hashtbl.mem closed_native_tool_ids tool_call_id)
        then false, false
        else (
          let prefix =
            ensure_message_started_locked ()
            @ close_open_text_locked ()
            @ close_open_thought_locked ()
          in
          let idx = alloc_index_locked () in
          if tool_call_id <> ""
          then Hashtbl.replace native_tool_indices tool_call_id (idx, observation)
          else anonymous_native_blocks := (idx, observation) :: !anonymous_native_blocks;
          let drain =
            enqueue_events_locked
              (prefix
               @ [ Agent_core.Types.ContentBlockStart
                     { index = idx
                     ; content_type = Runtime_native_tools.stream_content_type
                     ; tool_id = Runtime_native_tools.call_id observation
                     ; tool_name = observation.tool_name
                     }
                 ])
          in
          true, drain))
    in
    if is_new
    then (
      record_tool_call_json
        (`Assoc
            [ "call_id", `String tool_call_id
            ; "tool_name", `String (Option.value observation.tool_name ~default:title)
            ; "origin", `String "native"
            ; "arguments", Option.value raw_input ~default:(`Assoc [])
            ]);
      Option.iter
        (fun observe ->
           Runtime_native_tools.observe_exact_action
             ~official_turn
             ~observe
             observation)
        on_native_action;
      Host.record_raw_native_tool
        ~keeper_name
        ~raw_trace_run
        ~phase:`Started
        observation);
    drain_events_if_owner should_drain
  in
  let on_acp_event = function
    | Acp.Text_delta delta ->
      observe_activity ();
      let should_drain =
        Stdlib.Mutex.protect stream_mu (fun () ->
          if !finished
          then false
          else (
            let prefix = ensure_message_started_locked () @ close_open_thought_locked () in
            let start_ev, idx =
              match !text_index with
              | Some i -> [], i
              | None ->
                let i = alloc_index_locked () in
                text_index := Some i;
                ( [ Agent_core.Types.ContentBlockStart
                      { index = i
                      ; content_type = "text"
                      ; tool_id = None
                      ; tool_name = None
                      }
                  ]
                , i )
            in
            enqueue_events_locked
              (prefix
               @ start_ev
               @ [ Agent_core.Types.ContentBlockDelta
                     { index = idx; delta = Agent_core.Types.TextDelta delta }
                 ])))
      in
      drain_events_if_owner should_drain
    | Acp.Thought_delta delta ->
      observe_activity ();
      let should_drain =
        Stdlib.Mutex.protect stream_mu (fun () ->
          if !finished
          then false
          else (
            let prefix = ensure_message_started_locked () @ close_open_text_locked () in
            let start_ev, idx =
              match !thought_index with
              | Some i -> [], i
              | None ->
                let i = alloc_index_locked () in
                thought_index := Some i;
                ( [ Agent_core.Types.ContentBlockStart
                      { index = i
                      ; content_type = "thinking"
                      ; tool_id = None
                      ; tool_name = None
                      }
                  ]
                , i )
            in
            enqueue_events_locked
              (prefix
               @ start_ev
               @ [ Agent_core.Types.ContentBlockDelta
                     { index = idx; delta = Agent_core.Types.ThinkingDelta delta }
                 ])))
      in
      drain_events_if_owner should_drain
    | Acp.Usage_updated
        { prompt_tokens
        ; completion_tokens
        ; cached_tokens
        ; cached_write_tokens
        ; thought_tokens
        ; total_tokens
        ; _
        } ->
      (match on_usage_report, prompt_tokens, completion_tokens with
       | Some report, Some raw_input, Some raw_output ->
         let raw : Acp.usage =
           { Acp.empty_usage with
             input_tokens = raw_input
           ; output_tokens = raw_output
           ; cached_read_tokens = Option.value cached_tokens ~default:0
           ; cached_write_tokens = Option.value cached_write_tokens ~default:0
           ; thought_tokens = Option.value thought_tokens ~default:0
           ; total_tokens = Option.value total_tokens ~default:0
           }
         in
         let usage = api_usage_of_acp_usage ~driver raw in
         if usage_is_nonzero usage
         then
           report
             { Keeper_client_usage_report.official_turn
             ; response_id = turn_id
             ; model
             ; conversation_id = session_id
             ; position
             ; usage_scope = Runtime_usage_scope.Turn_total
             ; count = Keeper_client_usage_report.Running_count usage
             ; vendor_total_tokens = total_tokens
             }
       | _ -> ())
    | Acp.Tool_call_started { tool_call_id; title; kind = _; status = _; raw_input; identity } ->
      observe_activity ();
      if should_fence_tool_call_started
           ~server_isolation
           ~native_posture
           ~mcp_server_name
           ~allowed_tool_names
           identity
      then observe_effect_attempted ();
      (match identity with
       | Acp.Native_tool { name; _ } ->
         record_native_tool_started ~tool_call_id ~title ~name ~raw_input
       | Acp.Mcp_tool _ | Acp.Managed_mcp_schema_read _ -> ())
    | Acp.Tool_call_updated
        { tool_call_id; title; kind = _; status; raw_input; raw_output = _; identity } ->
      observe_activity ();
      (match identity with
       | Some id ->
         if should_fence_tool_call_started
              ~server_isolation
              ~native_posture
              ~mcp_server_name
              ~allowed_tool_names
              id
         then observe_effect_attempted ()
       | None ->
         (* Uncorrelated update (missing toolCallId, unannounced call, or
            tracking-table eviction) fails closed on the same-turn retry fence. *)
         observe_effect_attempted ());
      (match identity with
       | Some (Acp.Native_tool { name; _ }) ->
         let fallback_title =
           match title, name with
           | Some t, _ when String.trim t <> "" -> t
           | (Some _ | None), Some n when String.trim n <> "" -> n
           | (Some _ | None), (Some _ | None) -> "tool_call"
         in
         record_native_tool_started ~tool_call_id ~title:fallback_title ~name ~raw_input
       | Some (Acp.Mcp_tool _ | Acp.Managed_mcp_schema_read _) | None -> ());
      (match status with
       | None -> ()
       | Some st ->
         (match completion_of_acp_tool_status st with
          | None -> ()
          | Some completion ->
            if tool_call_id <> ""
            then (
              let closed, should_drain =
                Stdlib.Mutex.protect stream_mu (fun () ->
                  if !finished
                  then None, false
                  else (
                    match Hashtbl.find_opt native_tool_indices tool_call_id with
                    | None -> None, false
                    | Some (idx, observation) ->
                      Hashtbl.remove native_tool_indices tool_call_id;
                      Hashtbl.replace closed_native_tool_ids tool_call_id ();
                      let drain =
                        enqueue_events_locked [ Agent_core.Types.ContentBlockStop { index = idx } ]
                      in
                      Some (idx, observation), drain))
              in
              Option.iter
                (fun (idx, observation) ->
                   Host.record_raw_native_tool
                     ~keeper_name
                     ~raw_trace_run
                     ~phase:`Finished
                     observation;
                   Option.iter
                     (fun notify ->
                        notify
                          ~block_index:idx
                          ~tool_call_id:(Runtime_native_tools.call_id observation)
                          completion)
                     on_native_tool_completion)
                closed;
              drain_events_if_owner should_drain)))
    | (Acp.Mode_updated _ | Acp.Config_options_updated _) as meta_ev ->
      on_session_meta_updated meta_ev
  in
  let on_tool_started ~call_id ~tool_name ~arguments =
    observe_activity ();
    let started_opt =
      Stdlib.Mutex.protect stream_mu (fun () ->
        if !finished || Hashtbl.mem tool_indices call_id
        then None
        else (
          let prefix =
            ensure_message_started_locked ()
            @ close_open_text_locked ()
            @ close_open_thought_locked ()
          in
          let idx = alloc_index_locked () in
          let receipt_started = ref false in
          Hashtbl.replace tool_indices call_id (idx, receipt_started);
          let drain =
            enqueue_events_locked
              (prefix
               @ [ Agent_core.Types.ContentBlockStart
                     { index = idx
                     ; content_type = "tool_use"
                     ; tool_id = Some call_id
                     ; tool_name = Some tool_name
                     }
                 ; Agent_core.Types.ContentBlockDelta
                     { index = idx
                     ; delta = Agent_core.Types.InputJsonSnapshot (Yojson.Safe.to_string arguments)
                     }
                 ])
          in
          Some (idx, receipt_started, drain)))
    in
    match started_opt with
    | None -> false
    | Some (idx, receipt_started, should_drain) ->
      let drained = ref false in
      (try
         record_tool_call_json
           (`Assoc
               [ "call_id", `String call_id
               ; "tool_name", `String tool_name
               ; "arguments", arguments
               ]);
         Option.iter
           (fun r ->
              Keeper_official_client_tool_receipts.start r ~call_id ~block_index:idx;
              receipt_started := true)
           receipts;
         drained := true;
         drain_events_if_owner should_drain;
         true
       with
       | exn ->
         let cleanup () =
           let need_drain =
             Stdlib.Mutex.protect stream_mu (fun () ->
               let found = Hashtbl.find_opt tool_indices call_id in
               Hashtbl.remove tool_indices call_id;
               let extra =
                 match found with
                 | Some (i, _) when not !finished ->
                   [ Agent_core.Types.ContentBlockStop { index = i } ]
                 | Some _ | None -> []
               in
               List.iter (fun ev -> Queue.add ev emit_queue) extra;
               if should_drain && not !drained
               then true
               else if Queue.is_empty emit_queue || !emit_draining
               then false
               else (
                 emit_draining := true;
                 true))
           in
           if !receipt_started
           then
             Option.iter
               (fun r -> Keeper_official_client_tool_receipts.finish r ~call_id)
               receipts;
           drain_events_if_owner need_drain
         in
         (match Fs_compat.execution_context () with
          | Fs_compat.Eio_fiber -> Eio.Cancel.protect cleanup
          | Fs_compat.Non_eio -> cleanup ());
         raise exn)
  in
  let on_tool_finished ~call_id =
    let receipt_started_opt, should_drain =
      Stdlib.Mutex.protect stream_mu (fun () ->
        let found = Hashtbl.find_opt tool_indices call_id in
        Hashtbl.remove tool_indices call_id;
        match found with
        | Some (idx, receipt_started) when not !finished ->
          let drain =
            enqueue_events_locked [ Agent_core.Types.ContentBlockStop { index = idx } ]
          in
          Some !receipt_started, drain
        | Some (_idx, receipt_started) -> Some !receipt_started, false
        | None -> None, false)
    in
    (match receipt_started_opt with
     | Some true ->
       Option.iter (fun r -> Keeper_official_client_tool_receipts.finish r ~call_id) receipts
     | Some false | None -> ());
    drain_events_if_owner should_drain
  in
  let finish ~stop_reason ~usage =
    let delta_usage = Option.map delta_usage_of_api_usage usage in
    let pending_native, should_drain =
      Stdlib.Mutex.protect stream_mu (fun () ->
        if !finished
        then [], false
        else (
          finished := true;
          let prefix =
            ensure_message_started_locked ()
            @ close_open_text_locked ()
            @ close_open_thought_locked ()
          in
          let unclosed_mcp =
            Hashtbl.fold (fun _ (idx, _) acc -> idx :: acc) tool_indices []
            |> List.sort Int.compare
          in
          let unclosed_native =
            (Hashtbl.fold (fun _ v acc -> v :: acc) native_tool_indices []
             @ !anonymous_native_blocks)
            |> List.sort (fun (a, _) (b, _) -> Int.compare a b)
          in
          Hashtbl.clear native_tool_indices;
          anonymous_native_blocks := [];
          let open_tool_stops =
            (unclosed_mcp @ List.map fst unclosed_native)
            |> List.sort_uniq Int.compare
            |> List.map (fun idx -> Agent_core.Types.ContentBlockStop { index = idx })
          in
          let drain =
            enqueue_events_locked
              (prefix
               @ open_tool_stops
               @ [ Agent_core.Types.MessageDelta
                     { stop_reason = Some stop_reason; usage = delta_usage }
                 ; Agent_core.Types.MessageStop
                 ])
          in
          unclosed_native, drain))
    in
    List.iter
      (fun (idx, observation) ->
         Host.record_raw_native_tool
           ~keeper_name
           ~raw_trace_run
           ~phase:`Finished
           observation;
         Option.iter
           (fun notify ->
              notify
                ~block_index:idx
                ~tool_call_id:(Runtime_native_tools.call_id observation)
                Runtime_native_tools.end_observed)
           on_native_tool_completion)
      pending_native;
    drain_events_if_owner should_drain;
    drain_all_remaining ()
  in
  let observed_tool_calls () =
    Stdlib.Mutex.protect tool_calls_mu (fun () -> `List (List.rev !tool_calls_rev))
  in
  { on_acp_event; on_tool_started; on_tool_finished; finish; observed_tool_calls }
;;

(* ── Proactive compaction & shrink-retry helpers ─────────────────────────── *)

let split_older_for_rollover (messages : Agent_core.Types.message list) =
  (* Ignore synthetic preambles and slice strictly on [Runtime_model_input_tail_window]
     [Atom] boundaries so pinned entries (System, compaction anchors, working state,
     outside context) are never counted/evicted and [Assistant(tool_use)] +
     [Tool(tool_result)] pairs are never split apart. *)
  let without_preamble =
    List.filter
      (fun (m : Agent_core.Types.message) ->
         not (Runtime_model_input_tail_window.is_synthetic_preamble m))
      messages
  in
  let labelled, atom_count = Runtime_model_input_tail_window.annotate without_preamble in
  if atom_count <= 2
  then []
  else (
    let keep_recent = max 2 (atom_count / 4) in
    let evict_atoms = max 1 (atom_count - keep_recent) in
    List.filter_map
      (fun (m, label) ->
         match label with
         | Runtime_model_input_tail_window.Atom idx when idx < evict_atoms -> Some m
         | Runtime_model_input_tail_window.Atom _ | Runtime_model_input_tail_window.Pinned ->
           None)
      labelled)
;;

let compact_for_rollover
      ?blob_store
      ~keepers_dir
      ~keeper_id
      ~(rollover : rollover)
      ~fallback_messages
      ()
  =
  let source_messages =
    match Keeper_canonical_turn_store.load_handoff_context ~keepers_dir ~keeper_id with
    | Ok handoff when handoff.messages <> [] -> handoff.messages
    | Ok _ | Error _ -> fallback_messages
  in
  let evicted_messages = split_older_for_rollover source_messages in
  if evicted_messages = []
  then ()
  else (
    let trigger =
      Keeper_compaction.Provider_counted_window
        { used_tokens = rollover.used_tokens; limit_tokens = rollover.limit_tokens }
    in
    match
      Keeper_compaction.compact_evicted_messages
        ?blob_store
        ~keepers_dir
        ~keeper_id
        ~trigger
        ~evicted_messages
        ()
    with
    | Ok _ -> ()
    | Error err ->
      Log.Keeper.warn
        ~keeper_name:keeper_id
        "proactive 80%% ACP context rollover compaction skipped: %s"
        (Keeper_compaction.store_error_to_string err))
;;

let effective_held_for_resume ~resume_system_notice previously_held =
  match resume_system_notice with
  | None -> previously_held
  | Some _ ->
    List.filter
      (fun (entry : Session_store.held_context) ->
         not
           (List.exists
              (fun block -> entry.context = Session_store.Context_block block)
              Host.standing_system_blocks))
      previously_held
;;

let rec drop_prefix n xs =
  if n <= 0
  then xs
  else (
    match xs with
    | [] -> []
    | _ :: rest -> drop_prefix (n - 1) rest)
;;

let resolve_input_rejected_for_shrink_retry ~base_path ~keeper_name ~runtime_id () =
  match
    Session_store.load_reconciled_for_runtime
      ~base_path
      ~keeper_name
      ~client_kind:Acp
      ~runtime_id
      ~current_owner_epoch:(Session_store.process_epoch ())
      ~required_at:(Time_compat.now ())
  with
  | Ok (Some ({ phase = Session_store.Recovery_required { recovery_id; failure; _ }; _ } as expected)) ->
    (match failure with
     | Session_store.Input_rejected Session_store.Bootstrap_floor_exceeded ->
       ignore
         (Session_store.resolve_recovery
            ~base_path
            ~keeper_name
            ~expected
            ~recovery_id
            ~resolution:Session_store.Restart_fresh
            ~resolved_by:"acp_shrink_retry"
            ~resolved_at:(Time_compat.now ()))
     | Session_store.Input_rejected Session_store.Effect_fenced
     | Pre_dispatch_failed | Spawn_resources_busy | Spawn_refused_same_input
     | Spawn_failed_cause_unknown | Owner_stopped_turn | Retryable_turn_failed
     | Transport_interrupted | Protocol_failed | Provider_rejected | Host_hook_failed
     | State_persistence_failed | Process_restarted | Vendor_session_full _ -> ())
  | Ok
      (Some
         { phase =
             ( Session_store.Ready
             | Session_store.Start _
             | Session_store.Active _
             | Session_store.Turn_inflight _
             | Session_store.Settled _ )
         ; _
         })
  | Ok None
  | Error _ -> ()
;;

(* ── Main Keeper ACP turn execution ───────────────────────────────────────── *)

let reconcile_prepared_tools ?account_home ?continuation ~native_posture ~claim_plan
      (prepared : Host.prepared_turn) =
  let digest = Session_store.tool_surface_sha256 ?account_home ~native_posture prepared.tools in
  let tool_surface_sha256 =
    match prepared.tools with
    | [] -> digest
    | _ :: _ ->
        (* Prior ACP sessions hashed the declared tools before hooks. A
           nonempty digest could therefore describe an empty bridge. Old empty
           digests are conclusive: a hook can remove tools but cannot add any. *)
        Agent_core_sha256.(digest_string ("masc.acp.prepared-tools.v1\000" ^ digest) |> to_hex)
  in
  match continuation with
  | Some (checkpoint : Keeper_semantic_execution.official_client_checkpoint)
    when not (String.equal checkpoint.tool_surface_sha256 tool_surface_sha256) ->
      Error (Keeper_official_client_session_refusal.core_error
               Keeper_official_client_session_refusal.Gate_continuation_unresumable)
  | Some _ | None ->
      Ok (Session_store.reconcile_tool_surface claim_plan ~tool_surface_sha256, tool_surface_sha256)
;;

(* The start range a fresh session sent, as the host composed it. Kept until
   the prompt answers so the agent's count is written against that very
   range. *)
type sent_start =
  { source_messages : Agent_core.Types.message list
  ; digest_at : int -> string option
  ; sends_from : int
  }

(* The host reports where the request starts as a message position
   ({!Keeper_request_start.sends_from}). The first atom whose opening message
   sits at or past it is the range's first atom. *)
let first_atom_of_sends_from messages ~sends_from =
  let labelled, atom_count = Runtime_model_input_tail_window.annotate messages in
  let rec first index = function
    | [] -> atom_count
    | (_, Runtime_model_input_tail_window.Atom atom) :: _ when index >= sends_from -> atom
    | (_, (Runtime_model_input_tail_window.Atom _ | Runtime_model_input_tail_window.Pinned))
      :: rest -> first (index + 1) rest
  in
  first 0 labelled
;;

let ledger_request ~system_prompt ~tools { source_messages; digest_at; sends_from } =
  let first_atom = first_atom_of_sends_from source_messages ~sends_from in
  let _, atom_count = Runtime_model_input_tail_window.annotate source_messages in
  let ends =
    match digest_at first_atom, digest_at (atom_count - 1) with
    | Some front_digest, Some end_digest when first_atom < atom_count ->
      Keeper_model_input_ledger.Carried_atoms { front_digest; end_digest }
    | (Some _ | None), (Some _ | None) -> Keeper_model_input_ledger.No_atom_carried
  in
  { Keeper_model_input_ledger.prefix_digest =
      Keeper_model_input_ledger.prefix_digest ~system_prompt ~tools
  ; first_atom
  ; atom_count
  ; ends
  ; tail_bytes = 0
  ; turn_context = true
  ; demote_before = 0
  ; working_state = None
  }
;;

(* The size signal on this lane (RFC keeper-context-window-in-tokens): the
   ledger holds the agent's own count for the last start range this runtime
   sent. When that count passed the declared limit, the next start opens
   where {!Keeper_turn_driver_try_provider.past_max_context} moves it, ahead
   of the stored seed, as the Agent Core lanes do. *)
let seed_past_max_context
      ~keeper_name
      ~runtime_id
      ~session_id
      ~input_limit
      ~librarian_front
      ~turn_start
      ~digest_at
      carried_front_seed
  =
  let ledger =
    match
      Keeper_model_input_ledger.Table.lookup_in_history
        ~keeper_name
        ~runtime_id
        ~session_id
        ~digest_at
    with
    | Keeper_model_input_ledger.Table.Holds ledger -> Some ledger
    | Keeper_model_input_ledger.Table.Dropped_stale _ | Keeper_model_input_ledger.Table.Absent ->
      None
  in
  match
    Keeper_turn_driver_try_provider.past_max_context
      ~input_limit:(Some input_limit)
      ~continuity:librarian_front
      ~history_digest_at:digest_at
      ~turn_boundary:turn_start
      ledger
  with
  | None -> carried_front_seed
  | Some { Keeper_turn_driver_try_provider.moved_to; window_first_atom; next_turn_peak; _ } ->
    Log.Keeper.info
      ~keeper_name
      "ACP start range passed max context runtime=%s peak_tokens=%d limit_tokens=%d \
       window_first_atom=%d moved_to_atom=%d"
      runtime_id
      next_turn_peak
      (Llm_provider.Input_budget.to_int input_limit)
      window_first_atom
      moved_to.Keeper_carried_front.first_atom;
    Some
      (fun ~runtime_id ->
        let read =
          match carried_front_seed with
          | Some read -> read ~runtime_id
          | None -> Keeper_carried_front.no_seed_read
        in
        match read.Keeper_carried_front.seed with
        | Some seed
          when seed.Keeper_carried_front.first_atom
               >= moved_to.Keeper_carried_front.first_atom -> read
        | Some _ | None -> { read with Keeper_carried_front.seed = Some moved_to })
;;

let run_without_lifecycle
      ~on_guidance_prepared
      ~result_scope
      ~capacity_bytes
      ~unbounded_capacity_bytes
      ~input_limit
      ~force_fresh_retry
      ~input_source
      ~media_store
      ~argument_source
      ~official_task_reference
      ~composed_context
      ~accepts_image_input
      ~on_session_settled
      ~on_results_ready
      ~official_client_continuation
      ~outbox_viewer
      ~read_retained_media
      ~required_native_posture
      ~runtime_id
      ~host:_
      ~configured_reasoning_effort
      ~turn_timeout_s
      ~keeper_name
      ~on_model_input_window_observation
      ~carried_front_seed
      ~librarian_front
      ~on_carried_front
      ~turn_start
      ~pre_tool_rejects
      ~base_path
      ~goal
      ~goal_blocks
      ~system_prompt
      ~tools
      ~loading_plan
      ~initial_messages
      ~model_input_projection
      ~on_transmitted_model_input
      ~hooks
      ~context_injector
      ~context
      ~terminal_effect_state
      ~on_official_client_tool_boundary
      ~on_official_client_result_handoff
      ~on_native_tool_completion
      ~on_native_action
      ~on_usage_report
      ~on_tool_execution
      ~event_bus
      ~raw_trace
      ~on_event
      ~observe_effect_attempted
      ~observe_effect_unavailable
      ~observe_effect_quiet
      ~has_effect_attempted
      ~(config : Runtime_execution.acp_client)
  : (Runtime_agent.run_result, Agent_core.Error.t) result
  =
  let runtime_label = runtime_label_of_driver config.driver in
  let profile = Acp.profile_of_driver config.driver in
  let hooks = Option.value hooks ~default:Agent_core.Hooks.empty in
  let receipts =
    Option.map
      (fun notify ->
         Keeper_official_client_tool_receipts.create
           ~delivery:Keeper_official_client_tool_receipts.Immediate
           ~notify)
      on_tool_execution
  in
  let tool_hooks =
    match receipts with
    | None -> hooks
    | Some r -> Keeper_official_client_tool_receipts.hooks r hooks
  in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  let blob_store = Tool_blob_store.create ~base_path in
  let* env =
    match Eio_context.get_env_opt () with
    | Some env -> Ok env
    | None -> Error (internal_error "Eio standard environment is not initialized for ACP runtime")
  in
  let clock = Eio.Stdenv.clock env in
  let proc_mgr = Posix_spawn_process_mgr.foreground_mgr ~clock ~grace_seconds:5.0 in
  let owner_epoch = Session_store.process_epoch () in
  let* stored_session =
    Session_store.load_reconciled_for_runtime
      ~base_path
      ~keeper_name
      ~client_kind:Acp
      ~runtime_id
      ~current_owner_epoch:owner_epoch
      ~required_at:(Time_compat.now ())
  in
  let* claim_plan =
    Session_store.plan_claim ~expected:stored_session ~client_kind:Acp ~runtime_id
    |> Result.map_error Session_store.core_error_of_claim_error
  in
  let* native_posture =
    match required_native_posture with
    | Some posture -> Ok posture
    | None ->
      Host.resolve_native_posture
        ~posture_source:Runtime_native_tools.Declared_on_disk
        ~base_path
        ~keeper_name
        ~client_label:runtime_label
        ~default:Runtime_native_tools.Native_none
        ~none_supported:(Runtime_execution.supports_native_none (Runtime_execution.Acp config))
  in
  let* () = on_guidance_prepared () in
  let* () =
    match official_client_continuation with
    | None -> Ok ()
    | Some (checkpoint : Keeper_semantic_execution.official_client_checkpoint) ->
      (* Refuse a different stored turn before invoking its hooks. The actual
         tool surface can be checked only after before_turn_params. *)
      Session_store.validate_continuation
        ~checkpoint ~expected:stored_session ~client_kind:Acp ~runtime_id
        ~tool_surface_sha256:checkpoint.tool_surface_sha256
      |> Result.map_error (fun (_ : string) ->
          Keeper_official_client_session_refusal.core_error
            Keeper_official_client_session_refusal.Gate_continuation_unresumable)
  in
  let* () =
    match official_task_reference with
    | None -> Ok ()
    | Some _ ->
      Error
        (Keeper_official_client_session_refusal.core_error
           Keeper_official_client_session_refusal.Task_reference_unsupported)
  in
  (* Run hooks once at the planned ordinal. The prepared surface, like the
     canonical context, can still require a fresh vendor session. *)
  let hook_turn_count = claim_plan.turn_count in
  let* goal_text, goal_images =
    match goal_blocks with
    | None -> Ok (goal, [])
    | Some blocks ->
      if accepts_image_input
      then
        Host.text_and_images_of_blocks
          ~media_store
          ~runtime_label
          ~field:"goal_blocks"
          blocks
      else
        Host.text_of_blocks ~runtime_label ~field:"goal_blocks" blocks
        |> Result.map (fun t -> t, [])
  in
  let* () =
    Runtime_official_client_tool.validate_image_inputs goal_images
    |> Result.map_error (config_error ~field:"goal_blocks")
  in
  let* prepared =
    Host.prepare_turn
      ~composed_context
      ~configured_reasoning_effort
      ~runtime_label
      ~keeper_name
      ~turn_count:hook_turn_count
      ~system_prompt
      ~tools
      ~initial_messages
      ~model_input_projection:None
      ~hooks:(Some hooks)
  in
  let* claim_plan, tool_surface_sha256 =
    reconcile_prepared_tools ?account_home:config.oauth_source ?continuation:official_client_continuation
      ~native_posture ~claim_plan prepared
  in
  let initial_non_carried_count =
    List.length (List.filter is_non_carried_message initial_messages)
  in
  let before_turn_nudges =
    prepared.messages
    |> List.filter is_non_carried_message
    |> drop_prefix initial_non_carried_count
  in
  let snapshot_messages =
    List.filter Host.is_canonical_source_snapshot_message prepared.messages
  in
  let system_guard =
    Host.canonical_system_guard
      ~raw_system_prompt:prepared.system_prompt
      ~static_notes:[]
      ~composed_context:prepared.composed_context
  in
  let snapshot_sha256 =
    Keeper_official_client_context_codec.canonical_source_sha256
      ~system_prompt:system_guard.guard_system_prompt
      ~messages:snapshot_messages
      ~rest:system_guard.guard_rest
  in
  let* claim_plan =
    match official_client_continuation with
    | Some _ when Option.is_some claim_plan.previous_settlement ->
      Session_store.validate_unchanged_context ~expected:stored_session ~snapshot_sha256
      |> Result.map (fun () -> claim_plan)
      |> Result.map_error (fun reason ->
        Keeper_official_client_session_refusal.core_error
          (Session_store.gate_context_refusal reason))
    | Some _ | None ->
      let reconciled =
        Session_store.reconcile_context claim_plan ~expected:stored_session ~snapshot_sha256
      in
      (match claim_plan.previous_settlement, reconciled.previous_settlement with
       | Some { session_id; _ }, None ->
         Log.Keeper.info
           "acp: keeper=%s vendor session %s did not settle against current canonical history and system prompt; starting a fresh session"
           keeper_name
           session_id
       | Some _, Some _ | None, (Some _ | None) -> ());
      Ok reconciled
  in
  let turn_count = claim_plan.turn_count in
  let* tool_outbox =
    Keeper_client_tool_outbox.load ~base_path ~keeper_name ~viewer:outbox_viewer
    |> Result.map_error internal_error
  in
  let planned_fresh_rollover =
    Option.is_none official_client_continuation
    &&
    match claim_plan.previous_settlement with
    | None -> false
    | Some { session_id; _ } ->
      force_fresh_retry
      || rollover_marker_matches ~base_path ~keeper_id:keeper_name ~runtime_id ~session_id
  in
  let is_resume = Option.is_some claim_plan.previous_settlement && not planned_fresh_rollover in
  let raw_prepared_messages = prepared.messages in
  let outbox_message =
    Keeper_client_tool_outbox.context_message
      ~read_media:read_retained_media
      tool_outbox
  in
  let reserved_bytes =
    String.length prepared.system_prompt
    + String.length goal_text
    + Option.fold ~none:0 ~some:Host.measure_message_bytes outbox_message
  in
  let sent_start = ref None in
  let project_start_messages ~prefer_handoff messages =
    let hydrated =
      hydrate_start_messages
        ~appended_nudges:before_turn_nudges
        ~keepers_dir
        ~keeper_id:keeper_name
        ~prefer_handoff
        messages
    in
    (* The same list the host composes from, so atom positions agree. *)
    let source_messages = Runtime_model_input_tail_window.for_compaction_replay hydrated in
    let digest_at = Runtime_model_input_tail_window.atom_opening_digest source_messages in
    let carried_front_seed =
      match Keeper_request_source.trace_id input_source with
      | None -> carried_front_seed
      | Some session_id ->
        seed_past_max_context
          ~keeper_name
          ~runtime_id
          ~session_id
          ~input_limit
          ~librarian_front
          ~turn_start
          ~digest_at
          carried_front_seed
    in
    let on_carried_front front ~transmitted_bytes ~sends_from =
      sent_start := Some { source_messages; digest_at; sends_from };
      Option.iter (fun observe -> observe front ~transmitted_bytes ~sends_from) on_carried_front
    in
    let* ranged =
      Host.start_range_projection
        ~input_source
        ?argument_projection:
          (Option.bind argument_source (fun source ->
             Host.argument_projection source ~tools:prepared.tools ~history_prefix:[]))
        ~measure_message_bytes:Host.measure_message_bytes
        ~capacity_bytes
        ~unbounded_capacity_bytes
        ~reserved_bytes
        ?on_model_input_window_observation
        ?carried_front_seed
        ?librarian_front
        ~on_carried_front
        ~turn_start
        ~keeper_name
        ~runtime_id
        hydrated
    in
    let source_project = Host.project_source model_input_projection in
    let* projected =
      try source_project ranged with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn when Keeper_operator_interrupt.is_operator_interrupt exn -> raise exn
      | exn ->
        Llm_provider.Reserved_exn.reraise_if_reserved exn;
        Error
          (internal_error
             (runtime_label ^ " model input projection raised: " ^ Printexc.to_string exn))
    in
    Ok (projected @ Option.to_list outbox_message)
  in
  let* prepared =
    if is_resume
    then (
      match model_input_projection with
      | None ->
        Ok { prepared with Host.messages = prepared.messages @ Option.to_list outbox_message }
      | Some project ->
        let* messages =
          try project prepared.messages with
          | Eio.Cancel.Cancelled _ as exn -> raise exn
          | exn when Keeper_operator_interrupt.is_operator_interrupt exn -> raise exn
          | exn ->
            Llm_provider.Reserved_exn.reraise_if_reserved exn;
            Error
              (internal_error
                 (runtime_label ^ " model input projection raised: " ^ Printexc.to_string exn))
        in
        Ok { prepared with Host.messages = messages @ Option.to_list outbox_message })
    else (
      let prefer_handoff =
        prefer_handoff_for_start ~planned_fresh_rollover ~force_fresh_retry
      in
      let* messages =
        project_start_messages ~prefer_handoff raw_prepared_messages
      in
      Ok { prepared with Host.messages = messages })
  in
  let composed_context = prepared.composed_context in
  let goal_with_handoff =
    if not is_resume
    then goal_text
    else (
      match claim_plan.previous_settlement with
      | None -> goal_text
      | Some { session_id; _ } ->
        Keeper_turn_bridge.prepend_resume_handoff
          ~input_source
          ~base_path
          ~keeper_name
          ~client_kind:Acp
          ~runtime_id
          ~session_id
          ~goal:goal_text)
  in
  let build_start_prompt ~use_meta_append ~goal:start_goal ~prepared:(start_prepared : Host.prepared_turn) =
    if use_meta_append
    then (
      (* Deliver standing system prompt natively via _meta.antigravity.systemPrompt.append;
         carry start history + goal in opening prompt without duplicating system prompt. *)
      let history_lines =
        List.map
          (fun msg ->
             Host.history_role_label msg.Agent_core.Types.role
             ^ Host.encode_start_message ~started_at:(Time_compat.now ()) msg)
          start_prepared.Host.messages
      in
      let body =
        match history_lines with
        | [] -> start_goal
        | lines -> String.concat "\n\n" lines ^ "\n\n" ^ start_goal
      in
      let with_obs = Host.start_prompt start_prepared body in
      Ok (Keeper_context_submission_link.text with_obs, Some start_prepared.Host.system_prompt))
    else (
      let* framed =
        Host.framed_prompt_for_turn
          ?composed_context
          ~held:[]
          ~delivery:(Host.Framed_start { started_at = Time_compat.now () })
          ~goal:start_goal
          start_prepared
      in
      Ok (framed, None))
  in
  (* Proper ~held delta tracking for ALL 3 ACP drivers: eliminates repeated
     World State / context-carrier resend on resume while refreshing standing
     System observations whenever [system_guard.resume_system_notice] is present. *)
  let resume_prompt_opt, held_context =
    if is_resume
    then (
      let previously_held =
        Session_store.held_context_for_resume claim_plan ~expected:stored_session
      in
      let effective_held =
        effective_held_for_resume
          ~resume_system_notice:system_guard.resume_system_notice
          previously_held
      in
      let resume_delivery =
        Host.resume_prompt
          ~goal:goal_with_handoff
          ~held:effective_held
          ~turn_observation:prepared.turn_observation
          ?composed_context
          prepared.messages
      in
      let prompt =
        match system_guard.resume_system_notice with
        | Some notice -> notice ^ "\n\n" ^ resume_delivery.prompt
        | None -> resume_delivery.prompt
      in
      Some prompt, resume_delivery.held_context)
    else (
      let held =
        Host.start_held_context
          ~turn_observation:prepared.turn_observation
          ?composed_context
          prepared.messages
      in
      None, held)
  in
  let effective_timeout_s =
    match turn_timeout_s with
    | None -> Some config.timeout_s
    | Some secs when secs <= 0.0 -> None
    | Some secs -> Some secs
  in
  let effective_effort =
    Acp.resolve_effective_effort
      ?turn_effort:prepared.reasoning_effort
      ?provider_effort:config.effort
      ()
  in
  let effective_mode =
    Acp.resolve_mode_for_posture
      ~driver:config.driver
      ~posture:native_posture
      ~configured_mode:config.mode
  in
  let raw_trace_prompt = Option.value resume_prompt_opt ~default:goal_with_handoff in
  let raw_trace_run =
    Host.start_raw_trace
      ~keeper_name
      ~raw_trace
      ~prompt:raw_trace_prompt
      ~model:(Acp.model_selection_to_string config.model)
      ?reasoning_effort:(Option.map Llm_provider.Reasoning_effort.to_string effective_effort)
      ()
  in
  let terminal_error = ref None in
  let* dynamic_tools, result_producer =
    Host.dynamic_tools
      ~result_scope:(Some result_scope)
      ~base_path
      ~content_transport:Runtime_official_client_tool.Mcp
      ~accepts_image_input
      ~tool_approval:None
      ~runtime_label
      ~keeper_name
      ~turn_count:hook_turn_count
      ~tools:prepared.tools
      ~loading_plan
      ~hooks:tool_hooks
      ~event_bus
      ~context_injector
      ~context
      ~terminal_effect_state
      ~terminal_error
      ~pre_tool_rejects
      ~raw_trace_run
      ?on_tool_boundary:on_official_client_tool_boundary
      ~on_result_handoff:on_official_client_result_handoff
      ()
    |> Result.map_error (fun err ->
      Host.finish_raw_error ~keeper_name raw_trace_run err;
      err)
  in
  let dynamic_tools =
    List.map
      (Keeper_official_client_attempt.fence_effect_capable_call ~observe_effect_attempted)
      dynamic_tools
  in
  let produced_results = ref None in
  let close_delivery_frontier () =
    if Option.is_none !produced_results
    then
      produced_results :=
        Option.map Keeper_client_tool_outbox.close_delivery_frontier result_producer
  in
  let natural_completion = ref false in
  let context_frontier : Session_store.context_frontier =
    { message_count = List.length snapshot_messages
    ; delivery = Session_store.Canonical_source_guard { snapshot_sha256 }
    ; acknowledged_turn = None
    ; held_context
    }
  in
  let* claimed_session =
    match
      Session_store.claim_with_context_frontier
        ~context_frontier:(Some context_frontier)
        ~base_path
        ~keeper_name
        ~expected:stored_session
        ~client_kind:Acp
        ~owner_epoch
        ~runtime_id
        ~tool_surface_sha256
        ~updated_at:(Time_compat.now ())
    with
    | Ok session -> Ok session
    | Error detail ->
      let err = internal_error ("ACP session claim failed: " ^ detail) in
      Host.finish_raw_error ~keeper_name raw_trace_run err;
      Error err
  in
  let session_state = ref claimed_session in
  let recovery_failure = ref Session_store.Transport_interrupted in
  let update_session label transition =
    match transition !session_state with
    | Ok next ->
      session_state := next;
      Ok ()
    | Error detail ->
      recovery_failure := Session_store.State_persistence_failed;
      Error (Printf.sprintf "ACP session %s failed: %s" label detail)
  in
  let settle_failed_claim detail =
    match Session_store.failure_disposition !recovery_failure with
    | Transient ->
      (match !session_state with
       | { phase = (Ready | Settled _ | Recovery_required _); _ } -> Ok ()
       | { phase = (Start _ | Active _ | Turn_inflight _); _ } as expected ->
         Session_store.release_transient
           ~base_path
           ~keeper_name
           ~expected
           ~failure:!recovery_failure
           ~released_at:(Time_compat.now ())
         |> Result.map (fun released -> session_state := released))
    | Ambiguous | Fatal ->
      (match !session_state with
       | { phase = (Ready | Settled _ | Recovery_required _); _ } -> Ok ()
       | { phase = (Start _ | Active _ | Turn_inflight _); _ } as expected ->
         Session_store.require_recovery
           ~base_path
           ~keeper_name
           ~expected
           ~failure:!recovery_failure
           ~detail
           ~required_at:(Time_compat.now ())
         |> Result.map (fun recovery -> session_state := recovery))
  in
  let started_at = Time_compat.now () in
  let skills_dirs =
    match native_posture with
    | Runtime_native_tools.Native_none -> []
    | Runtime_native_tools.Native_read | Runtime_native_tools.Native_full ->
      discover_skills_dirs ~base_path config
  in
  let key : Pool_key.t =
    { keeper_name
    ; runtime_id
    ; tool_surface_sha256
    ; process_config_sha256 = process_config_sha256 ~native_posture ~skills_dirs config
    ; cwd = base_path
    ; dangerously_skip_permissions =
        (native_posture = Runtime_native_tools.Native_full)
    }
  in
  let fallback_start_messages_ref = ref prepared.messages in
  let build_fallback_start_prompt ~use_meta_append () =
    (* Resume fallback must run the same canonical hydration + bounded Start
       range projection as a fresh Start, using plain [goal_text] without
       prepending a redundant resume handoff onto the full history. *)
    let* projected_msgs =
      project_start_messages ~prefer_handoff:false raw_prepared_messages
    in
    fallback_start_messages_ref := projected_msgs;
    let fallback_prepared = { prepared with Host.messages = projected_msgs } in
    let* prompt, sys_append =
      build_start_prompt ~use_meta_append ~goal:goal_text ~prepared:fallback_prepared
    in
    Ok (prompt, sys_append, projected_msgs)
  in
  let blocks_of_prompt text =
    Acp.Text_block text
    :: List.map
         (fun (img : Runtime_official_client_tool.image_input) ->
            Acp.Image_block
              { mime_type = img.media_type; base64_data = img.base64_data })
         goal_images
  in
  let is_gate_continuation = Option.is_some official_client_continuation in
  let execute_with_entry (entry : pool_entry) ~persistent =
    let evict_or_close () =
      if persistent then evict_entry_if_same key entry else Acp.close entry.client
    in
    let close_session_best_effort sid =
      if (Acp.capabilities entry.client).close_session && Acp.is_alive entry.client
      then
        ignore
          (Acp.close_session ~timeout_s:1.5 entry.client ~session_id:sid
           : (unit, Acp.error) result)
    in
    run_serialized_turn
      ~mutex:entry.turn_mutex
      ~on_holder_exception:(fun () ->
        Atomic.set entry.in_flight false;
        evict_or_close ())
      (fun () ->
      Atomic.set entry.in_flight true;
      Fun.protect
        ~finally:(fun () ->
          entry.last_used_at <- Time_compat.now ();
          Atomic.set entry.in_flight false)
        (fun () ->
      let* () =
        if goal_images <> [] && not (Acp.capabilities entry.client).image_prompt
        then (
          recovery_failure := Session_store.Pre_dispatch_failed;
          Error
            (Agent_core.Error.Provider
               (Llm_provider.Error.ProviderReportedError
                  { provider = "acp"
                  ; error_type = Some "image_input_unsupported"
                  ; detail = Acp.image_input_unsupported_detail config.driver
                  })))
        else Ok ()
      in
      Runtime_official_client_mcp_http.begin_turn entry.bridge;
      let caps = Acp.capabilities entry.client in
      let use_meta_append =
        profile.system_prompt_channel = Acp.Meta_antigravity_append
        && caps.antigravity_system_prompt_append
      in
      let open_fresh_session ~prompt_text:fresh_prompt ~system_prompt_append:sys_append ~msgs =
        (match entry.session_id with
         | Some old_sid ->
           entry.session_id <- None;
           entry.session_info <- None;
           close_session_best_effort old_sid
         | None -> ());
        let* info =
          Acp.new_session
            entry.client
            ~cwd:entry.acp_cwd
            ?system_prompt_append:sys_append
            ~mcp_server:entry.mcp_server
            ~additional_directories:skills_dirs
            ~mode:effective_mode
            ~model:config.model
            ?effort:effective_effort
            ()
          |> Result.map_error (fun err ->
            if should_evict_on_session_setup_error err then evict_or_close ();
            recovery_failure := recovery_failure_of_acp_error err;
            acp_error_to_core_error err)
        in
        entry.session_id <- Some info.session_id;
        entry.session_info <- Some info;
        entry.last_context_used <- None;
        Ok (info, false, fresh_prompt, msgs)
      in
      (* Establish, reconfigure, or resume the ACP session on the persistent child. *)
      let* session_info, resumed, active_prompt_text, transmitted_messages =
        if not is_resume
        then (
          let* start_prompt_text, sys_append =
            build_start_prompt ~use_meta_append ~goal:goal_with_handoff ~prepared
          in
          open_fresh_session
            ~prompt_text:start_prompt_text
            ~system_prompt_append:sys_append
            ~msgs:prepared.messages)
        else (
          let active_resume_prompt =
            Option.value resume_prompt_opt ~default:goal_with_handoff
          in
          match claim_plan.previous_settlement, entry.session_id, entry.session_info with
          | Some { session_id; _ }, Some open_sid, Some open_info
            when String.equal session_id open_sid ->
            let* updated_info =
              Acp.reconfigure_session
                entry.client
                open_info
                ~mode:effective_mode
                ~model:config.model
                ?effort:effective_effort
                ()
              |> Result.map_error (fun err ->
                if should_evict_on_session_setup_error err then evict_or_close ();
                recovery_failure := recovery_failure_of_acp_error err;
                acp_error_to_core_error err)
            in
            entry.session_info <- Some updated_info;
            Ok (updated_info, true, active_resume_prompt, prepared.messages)
          | Some { session_id; _ }, _, _ ->
            (match entry.session_id with
             | Some old_sid when not (String.equal old_sid session_id) ->
               entry.session_id <- None;
               entry.session_info <- None;
               entry.last_context_used <- None;
               close_session_best_effort old_sid
             | Some _ | None -> ());
            let resume_outcome =
              if caps.resume_session
              then (
                match
                  Acp.resume_session
                    entry.client
                    ~session_id
                    ~cwd:entry.acp_cwd
                    ~mcp_server:entry.mcp_server
                    ~additional_directories:skills_dirs
                    ~mode:effective_mode
                    ~model:config.model
                    ?effort:effective_effort
                    ()
                with
                | Ok info -> `Resumed info
                | Error (Acp.Rpc_error _ | Acp.Protocol_error _)
                  when caps.load_session && Acp.is_alive entry.client ->
                  (match
                     Acp.load_session
                       entry.client
                       ~session_id
                       ~cwd:entry.acp_cwd
                       ~mcp_server:entry.mcp_server
                       ~additional_directories:skills_dirs
                       ~mode:effective_mode
                       ~model:config.model
                       ?effort:effective_effort
                       ()
                   with
                   | Ok info -> `Resumed info
                   | Error err -> `Failed err)
                | Error
                    (( Acp.Invalid_config _
                     | Acp.Spawn_refused _
                     | Acp.Protocol_error _
                     | Acp.Rpc_error _
                     | Acp.Timeout _
                     | Acp.Process_exited _
                     | Acp.Client_closed ) as err) ->
                  `Failed err)
              else if caps.load_session
              then (
                match
                  Acp.load_session
                    entry.client
                    ~session_id
                    ~cwd:entry.acp_cwd
                    ~mcp_server:entry.mcp_server
                    ~additional_directories:skills_dirs
                    ~mode:effective_mode
                    ~model:config.model
                    ?effort:effective_effort
                    ()
                with
                | Ok info -> `Resumed info
                | Error err -> `Failed err)
              else `Unsupported
            in
            (match resume_outcome with
             | `Resumed info ->
               entry.session_id <- Some info.session_id;
               entry.session_info <- Some info;
               (match info.replayed_context_used with
                | Some n when n > 0 -> entry.last_context_used <- Some n
                | Some _ | None -> ());
               Ok (info, true, active_resume_prompt, prepared.messages)
             | `Unsupported ->
               if is_gate_continuation
               then (
                 recovery_failure := Session_store.Pre_dispatch_failed;
                 Error
                   (Keeper_official_client_session_refusal.core_error
                      Keeper_official_client_session_refusal.Gate_continuation_unresumable))
               else (
                 let* fallback_prompt, fallback_sys, fallback_msgs =
                   build_fallback_start_prompt ~use_meta_append ()
                 in
                 open_fresh_session
                   ~prompt_text:fallback_prompt
                   ~system_prompt_append:fallback_sys
                   ~msgs:fallback_msgs)
             | `Failed err ->
               if should_evict_on_session_setup_error err then evict_or_close ();
               if is_gate_continuation
               then (
                 (* Gate continuation MUST bind strictly to its settled session;
                    never fall back to a fresh session and run effects there. *)
                 recovery_failure := Session_store.Pre_dispatch_failed;
                 Error
                   (Keeper_official_client_session_refusal.core_error
                      Keeper_official_client_session_refusal.Gate_continuation_unresumable))
               else if not (Acp.is_alive entry.client)
               then (
                 recovery_failure := recovery_failure_of_acp_error err;
                 Error (acp_error_to_core_error err))
               else (
                 (* Child restarted or prior session gone: open a clean session with
                    bounded hydrated start prompt + system prompt so zero context is lost. *)
                 let* fallback_prompt, fallback_sys, fallback_msgs =
                   build_fallback_start_prompt ~use_meta_append ()
                 in
                 open_fresh_session
                   ~prompt_text:fallback_prompt
                   ~system_prompt_append:fallback_sys
                   ~msgs:fallback_msgs))
          | None, _, _ ->
            let* start_prompt_text, sys_append =
              build_start_prompt ~use_meta_append ~goal:goal_with_handoff ~prepared
            in
            open_fresh_session
              ~prompt_text:start_prompt_text
              ~system_prompt_append:sys_append
              ~msgs:prepared.messages)
      in
      let session_id = session_info.session_id in
      let effective_model =
        match session_info.current_model_id with
        | Some m when String.trim m <> "" -> m
        | Some _ | None -> Acp.model_selection_to_string config.model
      in
      let prompt_blocks = blocks_of_prompt active_prompt_text in
      let position =
        if resumed then Keeper_usage_resolution.Resumed else Keeper_usage_resolution.Fresh
      in
      let allowed_tool_names =
        List.map (fun (tool : Host.dynamic_tool) -> tool.name) dynamic_tools
      in
      let response_or_tool_activity = Atomic.make false in
      let on_session_meta_updated = function
        | Acp.Mode_updated m ->
          (match entry.session_info with
           | Some info -> entry.session_info <- Some { info with current_mode_id = Some m }
           | None -> ())
        | Acp.Config_options_updated (_ :: _ as opts) ->
          (match entry.session_info with
           | Some info -> entry.session_info <- Some { info with config_options = opts }
           | None -> ())
        | Acp.Text_delta _
        | Acp.Thought_delta _
        | Acp.Tool_call_started _
        | Acp.Tool_call_updated _
        | Acp.Usage_updated _
        | Acp.Config_options_updated [] -> ()
      in
      let stream =
        make_stream_projection
          ~driver:config.driver
          ~mcp_server_name:(Runtime_official_client_mcp_http.server_name entry.bridge)
          ~server_isolation:(Acp.mcp_server_isolation entry.client)
          ~keeper_name
          ~raw_trace_run
          ~model:effective_model
          ~session_id
          ~turn_count
          ~official_turn:hook_turn_count
          ~position
          ~native_posture
          ~allowed_tool_names
          ~receipts
          ~observe_effect_attempted
          ~observe_activity:(fun () -> Atomic.set response_or_tool_activity true)
          ~on_session_meta_updated
          ~on_native_action
          ~on_native_tool_completion
          ~on_usage_report
          ~on_event
      in
      let* () =
        update_session "active transition" (fun expected ->
          Session_store.mark_active
            ~base_path
            ~keeper_name
            ~expected
            ~session_id
            ~updated_at:(Time_compat.now ()))
        |> Result.map_error internal_error
      in
      let* () =
        update_session "turn-starting transition" (fun expected ->
          Session_store.mark_turn_starting
            ~base_path
            ~keeper_name
            ~expected
            ~session_id
            ~updated_at:(Time_compat.now ()))
        |> Result.map_error internal_error
      in
      on_transmitted_model_input
        (if resumed
         then Host.Held_by_client_session
         else Host.Whole_input_transmitted transmitted_messages);
      (* Under Native_full, built-in CLI tools can perform side effects outside
         MASC's host handlers before a crash or timeout, so fence same-turn
         retry immediately prior to dispatch. *)
      (match native_posture with
       | Runtime_native_tools.Native_full -> observe_effect_unavailable ()
       | Runtime_native_tools.Native_none | Runtime_native_tools.Native_read -> ());
      with_slot_lock entry.turn_slot_mutex (fun () ->
        entry.turn_slot :=
          Some
            { client = entry.client
            ; tools = dynamic_tools
            ; on_tool_started = stream.on_tool_started
            ; on_tool_finished = stream.on_tool_finished
            });
      let clear_slot () =
        with_slot_lock entry.turn_slot_mutex (fun () -> entry.turn_slot := None)
      in
      let permission_policy =
        Acp.permission_policy_of_posture
          ~mcp_server_name:(Runtime_official_client_mcp_http.server_name entry.bridge)
          ~allowed_tool_names
          native_posture
      in
      let host_stop_ref = ref None in
      let cancel_settled = ref false in
      let is_gate_pause = function
        | Runtime_official_client_tool.Terminal_tool_boundary
            { outcome = Runtime_official_client_tool.Durable_stimulus_deferred; _ } -> true
        | Runtime_official_client_tool.Terminal_tool_boundary
            { outcome =
                ( Runtime_official_client_tool.Terminal_completed
                | Runtime_official_client_tool.Terminal_failed _ )
            ; _
            } -> false
      in
      let outcome =
        Fun.protect
          ~finally:clear_slot
          (fun () ->
            Watched_work.run
              (fun () ->
                let res =
                  Acp.prompt
                    entry.client
                    ~session_id
                    ~blocks:prompt_blocks
                    ~timeout_s:effective_timeout_s
                    ~permission_policy
                    ~on_event:(fun ev ->
                      if Option.is_none !host_stop_ref then stream.on_acp_event ev)
                    ()
                in
                (match res with
                 | Ok _ | Error (Acp.Rpc_error _) -> cancel_settled := true
                 | Error
                     ( Acp.Invalid_config _
                     | Acp.Spawn_refused _
                     | Acp.Protocol_error _
                     | Acp.Timeout _
                     | Acp.Process_exited _
                     | Acp.Client_closed ) -> ());
                `Runtime res)
              ~watcher:(fun () ->
                let stop = Runtime_official_client_mcp_http.await_host_stop entry.bridge in
                host_stop_ref := Some stop;
                clear_slot ();
                Acp.cancel entry.client ~session_id;
                if persistent && is_gate_pause stop && Acp.is_alive entry.client
                then Eio.Time.sleep clock 1.5;
                `Abort stop))
      in
      let outcome =
        match !host_stop_ref, outcome with
        | Some stop, _ -> `Abort (stop, !cancel_settled)
        | None, `Abort stop -> `Abort (stop, false)
        | None, (`Runtime _ as runtime_outcome) -> runtime_outcome
      in
      match outcome with
      | `Abort (stop, prompt_settled) ->
        stream.finish ~stop_reason:Agent_core.Types.PauseTurn ~usage:None;
        (* Keep a live persistent child & session intact across a Gate pause
           ([Durable_stimulus_deferred]) only after Turn 1's cancelled
           [session/prompt] RPC actually settled on the wire, so
           [official_client_continuation] can resume the exact vendor session
           and its isolated workspace without in-flight prompt collisions or
           trailing frame bleed; evict on every other host-stop boundary or
           when cancellation does not settle within the grace window. *)
        let preserve_for_gate_continuation =
          persistent
          && prompt_settled
          && is_gate_pause stop
          && Acp.is_alive entry.client
        in
        if not preserve_for_gate_continuation then evict_or_close ();
        Ok (`Stopped (session_id, effective_model, resumed, stop, stream.observed_tool_calls ()))
      | `Runtime (Ok prompt_res) ->
        let final_usage = api_usage_of_acp_usage ~driver:config.driver prompt_res.usage in
        let stream_usage = if usage_is_nonzero final_usage then Some final_usage else None in
        stream.finish
          ~stop_reason:(stop_reason_of_acp_stop_reason prompt_res.stop_reason)
          ~usage:stream_usage;
        let prev_used = entry.last_context_used in
        let cur_used = effective_context_used ~driver:config.driver prompt_res.usage in
        (match cur_used with
         | Some _ -> entry.last_context_used <- cur_used
         | None -> ());
        let compacted = compaction_detected ~prev_used ~cur_used in
        let rollover =
          rollover_of_usage
            ~context_used:cur_used
            ~context_size:prompt_res.usage.context_size
            ~input_limit
        in
        (* A fresh session carried a range masc composed: write the agent's
           count for it, so the next start can read the size signal. The count
           is [usage_update.used], the window the agent holds after the turn:
           the range plus this turn's growth, which the next turn's input
           carries at least. [usage.inputTokens] is not used: ACP reports it
           per turn, summed over every model request (and, on Muse, over
           reviews and observers), so it is no one request's input. A resumed
           session sent no range, so its count describes nothing masc chose. *)
        (* No count, no write: an observation without usage would replace the
           count the ledger already holds for this pair. *)
        (match
           ( resumed
           , !sent_start
           , Keeper_request_source.trace_id input_source
           , prompt_res.usage.Acp.context_used )
         with
         | false, Some sent, Some session_id, Some used when used > 0 ->
           let observation =
             Keeper_model_input_ledger.Table.observe
               ~keeper_name
               ~runtime_id
               ~session_id
               ~digest_at:sent.digest_at
               ~request:
                 (ledger_request
                    ~system_prompt:prepared.system_prompt
                    ~tools:prepared.tools
                    sent)
               ~usage:
                 (Keeper_model_input_ledger.usage_of_counts
                    ~input_tokens:used
                    ~cache_read_input_tokens:0)
           in
           Log.Keeper.debug
             ~keeper_name
             "ACP model input ledger runtime=%s %s"
             runtime_id
             (Yojson.Safe.to_string
                (Keeper_model_input_ledger.observation_to_json observation))
         | true, (Some _ | None), (Some _ | None), (Some _ | None)
         | false, None, (Some _ | None), (Some _ | None)
         | false, Some _, None, (Some _ | None)
         | false, Some _, Some _, (Some _ | None) -> ());
        if Option.is_some rollover
        then (
          close_session_best_effort session_id;
          evict_or_close ());
        close_delivery_frontier ();
        Ok
          (`Completed
              ( prompt_res
              , effective_model
              , cur_used
              , resumed
              , compacted
              , rollover
              , stream.observed_tool_calls () ))
      | `Runtime (Error err) ->
        if persistent
        then (
          if should_evict_persistent_child_on_error err || not (Acp.is_alive entry.client)
          then evict_entry_if_same key entry)
        else Acp.close entry.client;
        let activity_observed =
          Atomic.get response_or_tool_activity || has_effect_attempted ()
        in
        (* A clean pre-activity context overflow RPC proves the vendor rejected
           the request before running any Native_full built-in effect, so
           [Observation_unavailable] can downgrade cleanly to [No_effect_observed]
           (never clearing [Effect_attempted]). *)
        (match err with
         | Acp.Rpc_error { refusal = Some (Llm_provider.Retry.Signal_context_overflow _); _ }
           when not activity_observed ->
           observe_effect_quiet ()
         | Acp.Invalid_config _
         | Acp.Spawn_refused _
         | Acp.Protocol_error _
         | Acp.Rpc_error
             { refusal =
                 ( None
                 | Some
                     ( Llm_provider.Retry.Signal_context_overflow _
                     | Llm_provider.Retry.Signal_request_body_too_large _
                     | Llm_provider.Retry.Signal_hard_quota _
                     | Llm_provider.Retry.Signal_rate_limited _
                     | Llm_provider.Retry.Signal_auth_error _
                     | Llm_provider.Retry.Signal_authorization_error _
                     | Llm_provider.Retry.Signal_provider_unavailable _ ) )
             ; _
             }
         | Acp.Timeout _
         | Acp.Process_exited _
         | Acp.Client_closed -> ());
        let failure, core_err =
          classify_prompt_error ~is_gate_continuation ~activity_observed err
        in
        recovery_failure := failure;
        Error core_err))
  in
  let pinned_tool_specs = List.map tool_spec dynamic_tools in
  let run_client () =
    match Eio_context.get_root_switch_opt () with
    | Some root_sw when Eio_context.root_switch_on_current_domain () ->
      let* entry =
        acquire_persistent_entry
          ~root_sw
          ~env
          ~proc_mgr
          ~clock
          ~key
          ~native_posture
          ~skills_dirs
          ~pinned_tool_specs
          ~config
        |> Result.map_error (fun err ->
          recovery_failure := recovery_failure_of_acp_error err;
          acp_error_to_core_error err)
      in
      execute_with_entry entry ~persistent:true
    | _ ->
      (* Standalone test / non-owner domain fallback: turn-scoped switch. *)
      Eio.Switch.run (fun sw ->
        let* acp_cwd =
          (match native_posture with
           | Runtime_native_tools.Native_none ->
             Acp.create_isolated_workspace ~sw ~prefix:("keeper-" ^ keeper_name) ()
           | Runtime_native_tools.Native_read | Runtime_native_tools.Native_full ->
             Ok base_path)
          |> Result.map_error (fun err ->
            recovery_failure := recovery_failure_of_acp_error err;
            acp_error_to_core_error err)
        in
        let turn_slot = ref None in
        let turn_slot_mutex = Stdlib.Mutex.create () in
        let bridge =
          start_mcp_bridge
            ~driver:config.driver
            ~keeper_name
            ~sw
            ~env
            ~pinned_tool_specs
            ~turn_slot
            ~turn_slot_mutex
        in
        let mcp_server = Acp.mcp_http_server_of_bridge bridge in
        let acp_config : Acp.config =
          { driver = config.driver
          ; cli_path = config.cli_path
          ; args = config.args
          ; strip_env = config.strip_env
          ; skills_dirs
          ; contributor_mode = config.contributor_mode
          ; cwd = acp_cwd
          ; oauth_source = config.oauth_source
          ; dangerously_skip_permissions = key.dangerously_skip_permissions
          ; admission_timeout_s = config.admission_timeout_s
          }
        in
        let* client =
          Acp.start
            ~sw
            ~proc_mgr
            ~clock
            ~fs:(Eio.Stdenv.fs env)
            ~config:acp_config
            ~mcp_server
            ~native_posture
            ()
          |> Result.map_error (fun err ->
            recovery_failure := recovery_failure_of_acp_error err;
            acp_error_to_core_error err)
        in
        let entry =
          { client
          ; bridge
          ; mcp_server
          ; acp_cwd
          ; turn_slot
          ; turn_slot_mutex
          ; turn_mutex = Eio.Mutex.create ()
          ; in_flight = Atomic.make false
          ; last_used_at = Time_compat.now ()
          ; session_id = None
          ; session_info = None
          ; last_context_used = None
          ; stop_owner = ignore
          }
        in
        execute_with_entry entry ~persistent:false)
  in
  let commit_acp_canonical_turn ~turn_id ~tool_calls_json ~assistant_output ~usage_json =
    let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
    let compaction_epoch_id =
      match Keeper_compaction.latest_anchor ~keepers_dir ~keeper_id:keeper_name with
      | Ok (Some anchor) -> Some anchor.Keeper_compaction.epoch_id
      | Ok None | Error _ -> None
    in
    match
      Keeper_canonical_turn_store.commit_turn
        ~keepers_dir
        ~keeper_id:keeper_name
        ~turn_id:(Ids.Turn_id.of_string turn_id)
        ~runtime_kind:Keeper_canonical_turn_store.Acp_cli
        ~runtime_id
        ~user_input:goal
        ~tool_calls_json
        ~assistant_output
        ~usage_json
        ?compaction_epoch_id
        ~created_at:(Time_compat.now ())
        ()
    with
    | Ok _ -> ()
    | Error err ->
      Log.Keeper.warn
        ~keeper_name
        "canonical turn store commit skipped for ACP turn_id=%s: %s"
        turn_id
        (Keeper_canonical_turn_store.store_error_to_string err)
  in
  let turn_result =
    try
      match run_client () with
      | Error err -> Error err
      | Ok (`Stopped (session_id, effective_model, resumed, stop, acp_tool_calls_json)) ->
        let turn_id = provider_turn_identity ~session_id ~turn_count in
        let* () =
          update_session "host-stop turn identity" (fun expected ->
            Session_store.mark_turn_started
              ~base_path
              ~keeper_name
              ~expected
              ~session_id
              ~turn_id
              ~turn_count
              ~updated_at:(Time_compat.now ()))
          |> Result.map_error internal_error
        in
        let latency_ms =
          Int.of_float (Float.max 0.0 ((Time_compat.now () -. started_at) *. 1000.0))
        in
        let projected =
          Host.host_stop_result
            ~runtime_id
            ~model:effective_model
            ~session_id
            ~turn_id
            ~provider_turn_ordinal:hook_turn_count
            ~turns_used:turn_count
            ~latency_ms:(Some latency_ms)
            ~request_context:None
            stop
        in
        let* () =
          match projected with
          | Error _ -> Ok ()
          | Ok result ->
            Host.invoke_turn_completion_hooks
              ~runtime_label
              ~keeper_name
              ~turn_count:hook_turn_count
              ~hooks
              result.response
        in
        recovery_failure := Session_store.State_persistence_failed;
        let* settled =
          (if Option.is_some claim_plan.previous_settlement && not resumed
           then
             Session_store.settle_holding
               ~held_context:
                 (Host.start_held_context
                    ~turn_observation:prepared.turn_observation
                    ?composed_context
                    !fallback_start_messages_ref)
               ~base_path
               ~keeper_name
               ~expected:!session_state
               ~session_id
               ~turn_id
               ~updated_at:(Time_compat.now ())
           else
             Session_store.settle
               ~base_path
               ~keeper_name
               ~expected:!session_state
               ~session_id
               ~turn_id
               ~updated_at:(Time_compat.now ()))
          |> Result.map_error (fun detail ->
            internal_error ("ACP host-stop settlement failed: " ^ detail))
        in
        if planned_fresh_rollover || force_fresh_retry
        then clear_rollover_marker ~base_path ~keeper_id:keeper_name;
        session_state := settled;
        on_session_settled settled;
        (* Commit settled non-error host-stopped turns (e.g. terminal surface
           post / durable receipt wait) with empty visible prose so finalize's
           [bind_turn_ref] rebinds them cleanly instead of dropping the turn. *)
        (match projected with
         | Ok _ ->
           commit_acp_canonical_turn
             ~turn_id
             ~tool_calls_json:acp_tool_calls_json
             ~assistant_output:""
             ~usage_json:(`Assoc [])
         | Error _ -> ());
        projected
      | Ok
          (`Completed
              ( prompt_res
              , effective_model
              , (_ : int option)
              , resumed
              , compacted
              , rollover
              , acp_tool_calls_json )) ->
        natural_completion := true;
        let session_id = prompt_res.session_id in
        let turn_id = provider_turn_identity ~session_id ~turn_count in
        let* () =
          update_session "turn identity transition" (fun expected ->
            Session_store.mark_turn_started
              ~base_path
              ~keeper_name
              ~expected
              ~session_id
              ~turn_id
              ~turn_count
              ~updated_at:(Time_compat.now ()))
          |> Result.map_error internal_error
        in
        recovery_failure := Session_store.Host_hook_failed;
        let* () =
          match !terminal_error with
          | None -> Ok ()
          | Some detail -> Error (internal_error detail)
        in
        let latency_ms =
          Int.of_float (Float.max 0.0 ((Time_compat.now () -. started_at) *. 1000.0))
        in
        let usage = api_usage_of_acp_usage ~driver:config.driver prompt_res.usage in
        let nonzero_usage = usage_is_nonzero usage in
        log_usage_source ~keeper_name ~turn_id prompt_res.usage_source;
        (match on_usage_report with
         | Some report when nonzero_usage ->
           report
             { Keeper_client_usage_report.official_turn = hook_turn_count
             ; response_id = turn_id
             ; model = effective_model
             ; conversation_id = session_id
             ; position =
                 (if resumed
                  then Keeper_usage_resolution.Resumed
                  else Keeper_usage_resolution.Fresh)
             ; usage_scope = Runtime_usage_scope.Turn_total
             ; count = Keeper_client_usage_report.Running_count usage
             ; vendor_total_tokens = Some prompt_res.usage.total_tokens
             }
         | Some _ | None -> ());
        let content =
          (if String.trim prompt_res.thought <> ""
           then
             [ Agent_core.Types.Thinking
                 { signature = None; content = prompt_res.thought }
             ]
           else [])
          @ [ Agent_core.Types.Text prompt_res.text ]
        in
        let response : Agent_core.Types.api_response =
          { id = turn_id
          ; model = effective_model
          ; unreadable_tool_uses = []
          ; stop_reason = stop_reason_of_acp_stop_reason prompt_res.stop_reason
          ; content
          ; usage = if nonzero_usage then Some usage else None
          ; telemetry =
              Some
                { Agent_core.Types.default_inference_telemetry with
                  request_latency_ms = Some latency_ms
                ; canonical_model_id = Some effective_model
                ; reported_cache_usage =
                    if nonzero_usage
                    then
                      Some
                        { Agent_core.Types.cache_creation_input_tokens =
                            Some prompt_res.usage.cached_write_tokens
                        ; cache_read_input_tokens =
                            Some prompt_res.usage.cached_read_tokens
                        }
                    else None
                }
          }
        in
        let* () =
          Host.invoke_turn_completion_hooks
            ~runtime_label
            ~keeper_name
            ~turn_count:hook_turn_count
            ~hooks
            response
        in
        recovery_failure := Session_store.State_persistence_failed;
        (* If context occupancy dropped sharply, clear held_context on settlement
           so the next resume re-delivers current World State blocks cleanly. If a
           planned resume fell back to a fresh ACP session, record the fresh start
           held_context so the next resume diffs against what this session holds. *)
        let* settled =
          (if compacted || Option.is_some rollover
           then
             Session_store.settle_holding
               ~held_context:[]
               ~base_path
               ~keeper_name
               ~expected:!session_state
               ~session_id
               ~turn_id
               ~updated_at:(Time_compat.now ())
           else if Option.is_some claim_plan.previous_settlement && not resumed
           then
             Session_store.settle_holding
               ~held_context:
                 (Host.start_held_context
                    ~turn_observation:prepared.turn_observation
                    ?composed_context
                    !fallback_start_messages_ref)
               ~base_path
               ~keeper_name
               ~expected:!session_state
               ~session_id
               ~turn_id
               ~updated_at:(Time_compat.now ())
           else
             Session_store.settle
               ~base_path
               ~keeper_name
               ~expected:!session_state
               ~session_id
               ~turn_id
               ~updated_at:(Time_compat.now ()))
          |> Result.map_error (fun detail ->
            internal_error ("ACP session settlement failed: " ^ detail))
        in
        session_state := settled;
        on_session_settled settled;
        (* Commit canonically into per-Keeper SQLite WAL so ACP turns preserve
           full unbroken dialogue & tool continuity across ACP <-> HTTP failover. *)
        (let usage_json =
           if nonzero_usage
           then
             `Assoc
               [ "input_tokens", `Int usage.Agent_core.Types.input_tokens
               ; "output_tokens", `Int usage.Agent_core.Types.output_tokens
               ; "cache_creation_input_tokens", `Int usage.Agent_core.Types.cache_creation_input_tokens
               ; "cache_read_input_tokens", `Int usage.Agent_core.Types.cache_read_input_tokens
               ; "total_tokens", `Int prompt_res.usage.total_tokens
               ]
           else `Assoc []
         in
         commit_acp_canonical_turn
           ~turn_id
           ~tool_calls_json:acp_tool_calls_json
           ~assistant_output:prompt_res.text
           ~usage_json);
        (match rollover with
         | Some rollover ->
          compact_for_rollover
            ~blob_store
            ~keepers_dir
            ~keeper_id:keeper_name
            ~rollover
            ~fallback_messages:prepared.messages
            ();
          record_rollover_marker ~base_path ~keeper_id:keeper_name ~runtime_id ~session_id;
          Log.Keeper.info
            ~keeper_name
            "ACP context occupancy reached >=80%% (%d/%d tokens); compacted anchor and armed fresh session rollover"
            rollover.used_tokens
            rollover.limit_tokens
         | None ->
          if planned_fresh_rollover || force_fresh_retry
          then clear_rollover_marker ~base_path ~keeper_id:keeper_name);
        let capture, _metrics =
          Runtime_observation.runtime_metrics_for_candidates ~runtime_id ~keeper_name ()
        in
        Runtime_observation.record_attempt_terminal
          capture
          ~model_id:effective_model
          ~latency_ms:(Some latency_ms)
          ~error:None;
        let runtime_observation =
          Runtime_observation.runtime_observation_with_metrics
            ~selected_model:(Some effective_model)
            ~capture
            ~attempt_details_source:("acp_" ^ Acp.driver_to_string config.driver)
            ~agent_core_internal_runtime_allowed:false
            ~usage_scope:Runtime_usage_scope.Turn_total
            ()
        in
        Ok
          { Runtime_agent.response
          ; checkpoint = None
          ; session_id
          ; session_resumed = Some resumed
          ; turns = turn_count
          ; trace_ref = None
          ; run_validation = None
          ; runtime_observation = Some runtime_observation
          ; cooperative_boundary = None
          ; stop_reason = Completed { provider_turn_ordinal = hook_turn_count }
          }
    with
    | Eio.Cancel.Cancelled _ as exn ->
      let bt = Printexc.get_raw_backtrace () in
      recovery_failure :=
        (if Keeper_owner_signals.is_owner_cancel_reason exn
         then Session_store.Owner_stopped_turn
         else Session_store.Transport_interrupted);
      ignore (Eio.Cancel.protect (fun () -> settle_failed_claim "ACP turn cancelled"));
      Eio.Cancel.protect (fun () ->
        Host.finish_raw_error ~keeper_name raw_trace_run (internal_error "ACP turn cancelled"));
      Printexc.raise_with_backtrace exn bt
    | exn when Keeper_owner_signals.is_owner_cancel_reason exn ->
      let bt = Printexc.get_raw_backtrace () in
      recovery_failure := Session_store.Owner_stopped_turn;
      ignore (Eio.Cancel.protect (fun () -> settle_failed_claim "ACP turn stopped by owner"));
      Eio.Cancel.protect (fun () ->
        Host.finish_raw_error ~keeper_name raw_trace_run (internal_error "ACP turn stopped by owner"));
      Printexc.raise_with_backtrace exn bt
    | exn ->
      let bt = Printexc.get_raw_backtrace () in
      Llm_provider.Reserved_exn.reraise_if_reserved exn;
      let detail = "ACP turn raised unexpected exception: " ^ Printexc.to_string exn in
      recovery_failure := Session_store.Transport_interrupted;
      ignore (Eio.Cancel.protect (fun () -> settle_failed_claim detail));
      Eio.Cancel.protect (fun () ->
        Host.finish_raw_error ~keeper_name raw_trace_run (internal_error detail));
      Printexc.raise_with_backtrace exn bt
  in
  let turn_result =
    let* result = turn_result in
    let produced = if !natural_completion then Option.to_list !produced_results else [] in
    on_results_ready
      (Some (Keeper_client_tool_outbox.pending_consumption (tool_outbox :: produced)));
    Ok result
  in
  match turn_result with
  | Ok result -> Ok (Host.finish_raw_success ~keeper_name raw_trace_run result)
  | Error original_error ->
    let original_detail = Agent_core.Error.to_string original_error in
    let final_error =
      match Eio.Cancel.protect (fun () -> settle_failed_claim original_detail) with
      | Ok () -> original_error
      | Error recovery_detail ->
        internal_error
          (Printf.sprintf
             "ACP turn failed and recovery persistence also failed: original=%s recovery=%s"
             original_detail
             recovery_detail)
    in
    Eio.Cancel.protect (fun () ->
      Host.finish_raw_error ~keeper_name raw_trace_run final_error);
    Error final_error
;;

(* Named by what the refused attempt sent. A resumed session sent no range,
   and an uncapped start was refused by the agent alone: both are the
   provider's overflow against the declared limit. Only a start masc capped
   carries bytes it measured, and those bytes, never the cap, are what was
   observed. *)
let overflow_trigger ~input_limit ~previous_capacity ~refused_sent_bytes ~capacity =
  match refused_sent_bytes with
  | Some observed_bytes when previous_capacity <> unbounded_start_capacity_bytes ->
    Keeper_compaction.Explicit_hard_limit { capacity_bytes = capacity; observed_bytes }
  | Some _ | None ->
    Keeper_compaction.Provider_context_overflow
      { provider_limit_tokens = Some (Llm_provider.Input_budget.to_int input_limit) }
;;

let compact_once_for_overflow_with
      ?blob_store
      ~already_compacted
      ~keepers_dir
      ~keeper_id
      ~input_limit
      ~previous_capacity
      ~refused_sent_bytes
      ~capacity
      ~initial_messages
      ()
  =
  if not !already_compacted
  then (
    let evicted_messages = split_older_for_rollover initial_messages in
    if evicted_messages <> []
    then (
      let trigger =
        overflow_trigger ~input_limit ~previous_capacity ~refused_sent_bytes ~capacity
      in
      match
        Keeper_compaction.compact_evicted_messages
          ?blob_store
          ~keepers_dir
          ~keeper_id
          ~trigger
          ~evicted_messages
          ()
      with
      | Ok (Some _) -> already_compacted := true
      | Ok None | Error _ -> ()))
;;

let compact_once_for_overflow
      ~already_compacted
      ~keepers_dir
      ~keeper_id
      ~input_limit
      ~previous_capacity
      ~refused_sent_bytes
      ~capacity
      ~initial_messages
  =
  compact_once_for_overflow_with
    ~already_compacted
    ~keepers_dir
    ~keeper_id
    ~input_limit
    ~previous_capacity
    ~refused_sent_bytes
    ~capacity
    ~initial_messages
    ()
;;

let run
      ?(on_guidance_prepared = fun () -> Ok ())
      ~input_limit
      ~input_source
      ~media_store
      ?argument_source
      ?official_task_reference
      ?composed_context
      ~accepts_image_input
      ?required_native_posture
      ?official_client_continuation
      ~runtime_id
      ~host
      ~configured_reasoning_effort
      ~turn_timeout_s
      ~keeper_name
      ~pre_tool_rejects
      ~base_path
      ~outbox_viewer
      ~read_retained_media
      ~goal
      ~goal_blocks
      ~system_prompt
      ~tools
      ?(loading_plan = Host.All_on_demand)
      ~initial_messages
      ~model_input_projection
      ~on_transmitted_model_input
      ~hooks
      ~context_injector
      ~context
      ?(terminal_effect_state = fun () -> Keeper_tools_agent_core.Terminal_effect_open)
      ?on_model_input_window_observation
      ?carried_front_seed
      ?librarian_front
      ?on_carried_front
      ~turn_start
      ?on_official_client_tool_boundary
      ?(on_official_client_result_handoff = fun ~invocation:_ ~content:_ -> ())
      ?on_native_tool_completion
      ?on_native_action
      ?on_usage_report
      ?on_tool_execution
      ~event_bus
      ~raw_trace
      ~on_event
      ~config
      ()
  =
  (* Bytes of the start range the current attempt sent, measured by the host
     projection. A typed overflow halves what was really sent, not a size
     converted from tokens. [None] when the attempt resumed and sent no range. *)
  let sent_start_bytes = ref None in
  let on_carried_front front ~transmitted_bytes ~sends_from =
    sent_start_bytes := Some transmitted_bytes;
    Option.iter (fun observe -> observe front ~transmitted_bytes ~sends_from) on_carried_front
  in
  let min_reserve_bytes = String.length system_prompt + String.length goal in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  let blob_store = Tool_blob_store.create ~base_path in
  let force_fresh_retry = ref false in
  let compacted_for_overflow = ref false in
  Keeper_official_client_attempt.run
    ~event_bus
    ~keeper_name
    (fun ~result_scope
         { Keeper_official_client_attempt.on_session_settled
         ; on_results_ready
         ; effect_cell
         } ->
       let observe_effect_attempted () =
         Keeper_official_client_attempt.Effect_cell.attempted effect_cell
       in
       let observe_effect_unavailable () =
         Keeper_official_client_attempt.Effect_cell.unobserved effect_cell
       in
       let observe_effect_quiet () =
         Keeper_official_client_attempt.Effect_cell.quiet effect_cell
       in
       let has_effect_attempted () =
         Keeper_official_client_attempt.Effect_cell.read effect_cell
         = Keeper_provider_attempt_effect.Effect_attempted
       in
       Keeper_turn_driver_try_provider.context_overflow_shrink_sequence
         ~starting_capacity:unbounded_start_capacity_bytes
         ~shrink_capacity:(fun ~capacity ~default_capacity ->
           match !sent_start_bytes with
           | Some sent when sent < capacity ->
             Keeper_turn_driver_try_provider.default_context_overflow_shrink_capacity
               ~capacity:sent
           | Some _ | None -> default_capacity)
         ~same_run_retry_authorized:(fun () ->
           if Option.is_some official_client_continuation
           then false
           else (
             match input_source with
             | Keeper_request_source.Completion_review -> false
             | Keeper_request_source.Keeper_history _ ->
               Keeper_official_client_attempt.Effect_cell.read effect_cell
               = Keeper_provider_attempt_effect.No_effect_observed))
         ~shrink_admits_history:(fun ~capacity -> capacity > min_reserve_bytes)
         ~on_shrink_retry:
           (fun ~shrink_attempt ~previous_capacity ~capacity ->
              resolve_input_rejected_for_shrink_retry ~base_path ~keeper_name ~runtime_id ();
              evict_keeper_for_workspace ~base_path ~keeper_name;
              force_fresh_retry := true;
              compact_once_for_overflow_with
                ~blob_store
                ~already_compacted:compacted_for_overflow
                ~keepers_dir
                ~keeper_id:keeper_name
                ~input_limit
                ~previous_capacity
                ~refused_sent_bytes:!sent_start_bytes
                ~capacity
                ~initial_messages
                ();
              Log.Keeper.warn
                ~keeper_name
                "ACP typed context overflow; shrinking start history on fresh session: attempt=%d previous_capacity_bytes=%d capacity_bytes=%d"
                shrink_attempt
                previous_capacity
                capacity)
         ~attempt:(fun ~capacity:capacity_bytes ->
           sent_start_bytes := None;
           run_without_lifecycle
             ~on_guidance_prepared
             ~result_scope
             ~capacity_bytes
             ~unbounded_capacity_bytes:unbounded_start_capacity_bytes
             ~input_limit
             ~force_fresh_retry:!force_fresh_retry
             ~input_source
             ~media_store
             ~argument_source
             ~official_task_reference
             ~composed_context
             ~accepts_image_input
             ~on_session_settled
             ~on_results_ready
             ~official_client_continuation
             ~outbox_viewer
             ~read_retained_media
             ~required_native_posture
             ~runtime_id
             ~host
             ~configured_reasoning_effort
             ~turn_timeout_s
             ~keeper_name
             ~on_model_input_window_observation
             ~carried_front_seed
             ~librarian_front
             ~on_carried_front:(Some on_carried_front)
             ~turn_start
             ~pre_tool_rejects
             ~base_path
             ~goal
             ~goal_blocks
             ~system_prompt
             ~tools
             ~loading_plan
             ~initial_messages
             ~model_input_projection
             ~on_transmitted_model_input
             ~hooks
             ~context_injector
             ~context
             ~terminal_effect_state
             ~on_official_client_tool_boundary
             ~on_official_client_result_handoff
             ~on_native_tool_completion
             ~on_native_action
             ~on_usage_report
             ~on_tool_execution
             ~event_bus
             ~raw_trace
             ~on_event
             ~observe_effect_attempted
             ~observe_effect_unavailable
             ~observe_effect_quiet
             ~has_effect_attempted
             ~config)
         ())
;;

module For_testing = struct
  let acp_error_to_core_error = acp_error_to_core_error
  let should_evict_persistent_child_on_error = should_evict_persistent_child_on_error
  let recovery_failure_of_acp_error = recovery_failure_of_acp_error
  let classify_prompt_error = classify_prompt_error
  let api_usage_of_acp_usage = api_usage_of_acp_usage
  let usage_is_nonzero = usage_is_nonzero
  let effective_context_used = effective_context_used
  let stop_reason_of_acp_stop_reason = stop_reason_of_acp_stop_reason
  let compaction_detected = compaction_detected
  let effective_context_limit_tokens = effective_context_limit_tokens
  let rollover_of_usage ~context_used ~context_size ~input_limit =
    Option.map
      (fun { used_tokens; limit_tokens } -> used_tokens, limit_tokens)
      (rollover_of_usage ~context_used ~context_size ~input_limit)
  ;;

  let first_atom_of_sends_from = first_atom_of_sends_from
  let should_fence_tool_call_started = should_fence_tool_call_started
  let process_config_sha256 = process_config_sha256
  let rollover_threshold = rollover_threshold
  let record_rollover_marker = record_rollover_marker
  let rollover_marker_matches = rollover_marker_matches
  let clear_rollover_marker = clear_rollover_marker
  let split_older_for_rollover = split_older_for_rollover
  let prefer_handoff_for_start = prefer_handoff_for_start
  let hydrate_start_messages = hydrate_start_messages
  let compact_once_for_overflow = compact_once_for_overflow
  let overflow_trigger = overflow_trigger

  let project_stream_for_testing
        ?(server_isolation = Acp.Shared_or_multi_server)
        ?official_turn
        ?on_effect_attempted
        ?on_native_action
        ?on_native_tool_completion
        ?on_usage_report
        ?on_tool_execution
        ?on_event
        ~driver
        ~mcp_server_name
        ~model
        ~session_id
        ~turn_count
        ~native_posture
        ~allowed_tool_names
        ()
    =
    let receipts =
      Option.map
        (fun notify ->
           Keeper_official_client_tool_receipts.create
             ~delivery:Keeper_official_client_tool_receipts.Immediate
             ~notify)
        on_tool_execution
    in
    let stream =
      make_stream_projection
        ~driver
        ~mcp_server_name
        ~server_isolation
        ~keeper_name:"test-keeper"
        ~raw_trace_run:None
        ~model
        ~session_id
        ~turn_count
        ~official_turn:(Option.value official_turn ~default:turn_count)
        ~position:Keeper_usage_resolution.Fresh
        ~native_posture
        ~allowed_tool_names
        ~receipts
        ~observe_effect_attempted:(Option.value on_effect_attempted ~default:ignore)
        ~observe_activity:ignore
        ~on_session_meta_updated:ignore
        ~on_native_action
        ~on_native_tool_completion
        ~on_usage_report
        ~on_event
    in
    ( stream.on_acp_event
    , stream.on_tool_started
    , stream.on_tool_finished
    , stream.finish
    , stream.observed_tool_calls )
  ;;

  let reconcile_prepared_tools = reconcile_prepared_tools

  let start_mcp_bridge_for_specs ~driver ~keeper_name ~sw ~env ~pinned_tool_specs =
    let turn_slot = ref None in
    let turn_slot_mutex = Stdlib.Mutex.create () in
    start_mcp_bridge ~driver ~keeper_name ~sw ~env ~pinned_tool_specs ~turn_slot ~turn_slot_mutex
  ;;

  type pool_key = Pool_key.t =
    { keeper_name : string
    ; runtime_id : string
    ; tool_surface_sha256 : string
    ; process_config_sha256 : string
    ; cwd : string
    ; dangerously_skip_permissions : bool
    }

  let run_serialized_turn = run_serialized_turn

  module Pool = Keeper_pool
end
