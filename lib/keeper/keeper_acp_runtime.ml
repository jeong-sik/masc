(** Unified Keeper projection for persistent ACP v1 official runtimes
    (Antigravity, Kimi Code, Mistral Vibe). *)

open Result.Syntax
module Host = Keeper_official_client_host
module Session_store = Keeper_official_client_session_store
module Acp = Runtime_acp_client

let mcp_server_name = "masc"
let config_error = Host.config_error
let internal_error = Host.internal_error

(* In an append-only ACP session, a strict drop in reported context occupancy
   between consecutive turns structurally indicates native compaction/reset. *)
let compaction_detected ~prev_used ~cur_used =
  match prev_used, cur_used with
  | Some prev, Some cur when prev > 0 && cur > 0 -> cur < prev
  | _ -> false
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
  | Acp.Rpc_error { method_name; code; message } ->
    Agent_core.Error.Provider
      (Llm_provider.Error.ProviderReportedError
         { provider = "acp"
         ; error_type = Some (Printf.sprintf "rpc_%d" code)
         ; detail = Printf.sprintf "ACP RPC %s failed (%d): %s" method_name code message
         })
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

let recovery_failure_of_acp_error = function
  | Acp.Invalid_config _ -> Session_store.Pre_dispatch_failed
  | Acp.Spawn_refused refusal -> Session_store.recovery_failure_of_spawn_refusal refusal
  | Acp.Protocol_error _ -> Session_store.Protocol_failed
  | Acp.Rpc_error _ -> Session_store.Provider_rejected
  | Acp.Timeout _ -> Session_store.Transport_interrupted
  | Acp.Process_exited _ -> Session_store.Transport_interrupted
  | Acp.Client_closed -> Session_store.Transport_interrupted
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
  { tools : Host.dynamic_tool list
  ; on_tool_started :
      call_id:string -> tool_name:string -> arguments:Yojson.Safe.t -> unit
  ; on_tool_finished : call_id:string -> unit
  ; resolve_host_stop : Host.host_stop -> unit
  }

module Pool_key = struct
  type t =
    { keeper_name : string
    ; runtime_id : string
    ; tool_surface_sha256 : string
    ; cwd : string
    ; dangerously_skip_permissions : bool
    }

  let equal a b =
    String.equal a.keeper_name b.keeper_name
    && String.equal a.runtime_id b.runtime_id
    && String.equal a.tool_surface_sha256 b.tool_surface_sha256
    && String.equal a.cwd b.cwd
    && Bool.equal a.dangerously_skip_permissions b.dangerously_skip_permissions
  ;;

  let hash k =
    Hashtbl.hash
      (k.keeper_name, k.runtime_id, k.tool_surface_sha256, k.cwd, k.dangerously_skip_permissions)
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
end

type pool_entry =
  { client : Acp.t
  ; mcp_server : Acp.mcp_http_server
  ; turn_slot : active_turn_binding option ref
  ; turn_slot_mutex : Stdlib.Mutex.t
  ; turn_mutex : Eio.Mutex.t
  ; mutable session_id : string option
  ; mutable last_context_used : int option
  ; stop_owner : unit -> unit
  }

let pool : pool_entry Keeper_pool.t = Keeper_pool.create ()

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

let start_mcp_bridge ~sw ~env ~pinned_tool_specs ~turn_slot ~turn_slot_mutex =
  Runtime_official_client_mcp_http.start
    ~sw
    ~net:(Eio.Stdenv.net env)
    ~secure_random:(Eio.Stdenv.secure_random env)
    ~server_name:mcp_server_name
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
          b.on_tool_started ~call_id ~tool_name:name ~arguments;
          Fun.protect
            ~finally:(fun () -> b.on_tool_finished ~call_id)
            (fun () ->
              let result = tool.call ~call_id arguments in
              Option.iter b.resolve_host_stop result.abort_turn;
              let on_response_sent =
                Runtime_official_client_tool.response_observer Mcp result
              in
              { Runtime_official_client_mcp_http.outcome = tool_result result
              ; stop = None
              ; after_response_sent =
                  (fun () ->
                    Runtime_official_client_tool.notify_response_sent on_response_sent)
              })))
    ()
;;

let mcp_server_of_bridge bridge : Acp.mcp_http_server =
  let { Runtime_official_client_mcp_http.url; headers } =
    Runtime_official_client_mcp_http.endpoint bridge
  in
  { Acp.name = mcp_server_name; url; headers }
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
      ~base_path
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
  let skills_dirs = discover_skills_dirs ~base_path config in
  let acp_config : Acp.config =
    { driver = config.driver
    ; cli_path = config.cli_path
    ; args = config.args
    ; strip_env = config.strip_env
    ; skills_dirs
    ; cwd = key.cwd
    ; oauth_source = config.oauth_source
    ; dangerously_skip_permissions = key.dangerously_skip_permissions
    ; admission_timeout_s = Acp.init_timeout_s
    }
  in
  Eio.Fiber.fork_daemon ~sw:root_sw (fun () ->
    (try
       Eio.Switch.run (fun keeper_sw ->
         let bridge =
           start_mcp_bridge
             ~sw:keeper_sw
             ~env
             ~pinned_tool_specs
             ~turn_slot
             ~turn_slot_mutex
         in
         let mcp_server = mcp_server_of_bridge bridge in
         match Acp.start ~sw:keeper_sw ~proc_mgr ~clock ~config:acp_config ~mcp_server () with
         | Error err -> Eio.Promise.resolve resolve_ready (Error err)
         | Ok client ->
           let entry =
             { client
             ; mcp_server
             ; turn_slot
             ; turn_slot_mutex
             ; turn_mutex = Eio.Mutex.create ()
             ; session_id = None
             ; last_context_used = None
             ; stop_owner
             }
           in
           Eio.Switch.on_release keeper_sw (fun () ->
             Keeper_pool.evict_if_same pool ~key ~target:entry ~close:ignore);
           Eio.Promise.resolve resolve_ready (Ok entry);
           Eio.Promise.await shutdown_promise)
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
  Eio.Promise.await ready_promise
;;

let acquire_persistent_entry
      ~root_sw
      ~env
      ~proc_mgr
      ~clock
      ~(key : Pool_key.t)
      ~base_path
      ~pinned_tool_specs
      ~(config : Runtime_execution.acp_client)
  : (pool_entry, Acp.error) result
  =
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
        ~base_path
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
        ~base_path
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

type stream_projection =
  { on_acp_event : Acp.stream_event -> unit
  ; on_tool_started :
      call_id:string -> tool_name:string -> arguments:Yojson.Safe.t -> unit
  ; on_tool_finished : call_id:string -> unit
  }

let make_stream_projection
      ~driver
      ~model
      ~session_id
      ~turn_count
      ~position
      ~native_posture
      ~allowed_tool_names
      ~observe_effect_attempted
      ~on_usage_report
      ~on_event
  : stream_projection
  =
  let next_index = ref 0 in
  let text_index = ref None in
  let thought_index = ref None in
  let tool_indices : (string, int) Hashtbl.t = Hashtbl.create 8 in
  let emit event = Option.iter (fun f -> f event) on_event in
  let close_open_text () =
    match !text_index with
    | None -> ()
    | Some idx ->
      emit (Agent_core.Types.ContentBlockStop { index = idx });
      text_index := None
  in
  let close_open_thought () =
    match !thought_index with
    | None -> ()
    | Some idx ->
      emit (Agent_core.Types.ContentBlockStop { index = idx });
      thought_index := None
  in
  let alloc_index () =
    let i = !next_index in
    incr next_index;
    i
  in
  let on_acp_event = function
    | Acp.Text_delta delta ->
      close_open_thought ();
      let idx =
        match !text_index with
        | Some i -> i
        | None ->
          let i = alloc_index () in
          text_index := Some i;
          emit
            (Agent_core.Types.ContentBlockStart
               { index = i
               ; content_type = "text"
               ; tool_id = None
               ; tool_name = None
               });
          i
      in
      emit
        (Agent_core.Types.ContentBlockDelta
           { index = idx; delta = Agent_core.Types.TextDelta delta })
    | Acp.Thought_delta delta ->
      close_open_text ();
      let idx =
        match !thought_index with
        | Some i -> i
        | None ->
          let i = alloc_index () in
          thought_index := Some i;
          emit
            (Agent_core.Types.ContentBlockStart
               { index = i
               ; content_type = "thinking"
               ; tool_id = None
               ; tool_name = None
               });
          i
      in
      emit
        (Agent_core.Types.ContentBlockDelta
           { index = idx; delta = Agent_core.Types.ThinkingDelta delta })
    | Acp.Usage_updated { prompt_tokens; completion_tokens; cached_tokens; total_tokens; _ } ->
      (match on_usage_report, prompt_tokens, completion_tokens with
       | Some report, Some raw_input, Some raw_output ->
         let raw : Acp.usage =
           { Acp.empty_usage with
             input_tokens = raw_input
           ; output_tokens = raw_output
           ; cached_read_tokens = Option.value cached_tokens ~default:0
           ; total_tokens = Option.value total_tokens ~default:0
           }
         in
         let usage = api_usage_of_acp_usage ~driver raw in
         report
           { Keeper_client_usage_report.official_turn = turn_count
           ; response_id = provider_turn_identity ~session_id ~turn_count
           ; model
           ; conversation_id = session_id
           ; position
           ; usage_scope = Runtime_usage_scope.Turn_total
           ; count = Keeper_client_usage_report.Running_count usage
           ; vendor_total_tokens = total_tokens
           }
       | _ -> ())
    | Acp.Tool_call_started { title; kind; _ } ->
      (* MASC MCP tools report their own exact effect boundary via Host.dynamic_tools.
         Any non-MASC native CLI tool starting under Native_full (or non-read tool
         under Native_read / any native tool under Native_none) fences same-turn retry. *)
      let is_masc =
        Acp.is_masc_mcp_tool ~mcp_server_name ~allowed_tool_names ~title ~kind
      in
      if not is_masc
      then (
        match native_posture with
        | Runtime_native_tools.Native_full -> observe_effect_attempted ()
        | Runtime_native_tools.Native_read ->
          if not (Acp.is_read_only_tool_kind kind) then observe_effect_attempted ()
        | Runtime_native_tools.Native_none -> observe_effect_attempted ())
    | Acp.Tool_call_updated _
    | Acp.Mode_updated _
    | Acp.Config_options_updated _ -> ()
  in
  let on_tool_started ~call_id ~tool_name ~arguments =
    close_open_text ();
    close_open_thought ();
    let idx = alloc_index () in
    Hashtbl.replace tool_indices call_id idx;
    emit
      (Agent_core.Types.ContentBlockStart
         { index = idx
         ; content_type = "tool_use"
         ; tool_id = Some call_id
         ; tool_name = Some tool_name
         });
    emit
      (Agent_core.Types.ContentBlockDelta
         { index = idx
         ; delta = Agent_core.Types.InputJsonDelta (Yojson.Safe.to_string arguments)
         })
  in
  let on_tool_finished ~call_id =
    match Hashtbl.find_opt tool_indices call_id with
    | None -> ()
    | Some idx ->
      Hashtbl.remove tool_indices call_id;
      emit (Agent_core.Types.ContentBlockStop { index = idx })
  in
  { on_acp_event; on_tool_started; on_tool_finished }
;;

(* ── Main Keeper ACP turn execution ───────────────────────────────────────── *)

let run_without_lifecycle
      ~on_guidance_prepared
      ~result_scope
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
      ~on_native_tool_completion:_
      ~on_native_action:_
      ~on_usage_report
      ~on_tool_execution:_
      ~event_bus
      ~raw_trace
      ~on_event
      ~observe_effect_attempted
      ~observe_effect_unavailable:_
      ~(config : Runtime_execution.acp_client)
  : (Runtime_agent.run_result, Agent_core.Error.t) result
  =
  let runtime_label = runtime_label_of_driver config.driver in
  let profile = Acp.profile_of_driver config.driver in
  let hooks = Option.value hooks ~default:Agent_core.Hooks.empty in
  let* env =
    match Eio_context.get_env_opt () with
    | Some env -> Ok env
    | None -> Error (internal_error "Eio standard environment is not initialized for ACP runtime")
  in
  let clock = Eio.Stdenv.clock env in
  let proc_mgr = Eio.Stdenv.process_mgr env in
  let owner_epoch = Session_store.process_epoch () in
  let* stored_session =
    Session_store.load_for_runtime
      ~base_path
      ~keeper_name
      ~client_kind:Acp
      ~runtime_id
    |> Result.map_error (fun err ->
      internal_error ("ACP session store unreadable: " ^ Session_store.read_error_to_string err))
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
        ~none_supported:true
  in
  let* () = on_guidance_prepared () in
  let tool_surface_sha256 =
    Session_store.tool_surface_sha256 ~native_posture tools
  in
  let* () =
    match official_client_continuation with
    | None -> Ok ()
    | Some checkpoint ->
      Session_store.validate_continuation
        ~checkpoint
        ~expected:stored_session
        ~client_kind:Acp
        ~runtime_id
        ~tool_surface_sha256
      |> Result.map_error (fun (_ : string) ->
        Keeper_official_client_session_refusal.core_error
          Keeper_official_client_session_refusal.Gate_continuation_unresumable)
  in
  let claim_plan =
    Session_store.reconcile_tool_surface claim_plan ~tool_surface_sha256
  in
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
  let* tool_outbox =
    Keeper_client_tool_outbox.load ~base_path ~keeper_name ~viewer:outbox_viewer
    |> Result.map_error internal_error
  in
  let is_resume = Option.is_some claim_plan.previous_settlement in
  let* prepared =
    if is_resume
    then (
      match model_input_projection with
      | None -> Ok prepared
      | Some project ->
        let* messages =
          try project prepared.messages with
          | Eio.Cancel.Cancelled _ as exn -> raise exn
          | exn when Keeper_operator_interrupt.is_operator_interrupt exn -> raise exn
          | exn ->
            Error
              (internal_error
                 (runtime_label ^ " model input projection raised: " ^ Printexc.to_string exn))
        in
        Ok { prepared with messages })
    else (
      let project =
        Host.carried_history_projection
          ~input_source
          ?argument_projection:
            (Option.bind argument_source (fun source ->
               Host.argument_projection source ~tools:prepared.tools ~history_prefix:[]))
          ?on_model_input_window_observation
          ?carried_front_seed
          ?librarian_front
          ?on_carried_front
          ~turn_start
          ~keeper_name
          ~runtime_id
          model_input_projection
      in
      let* messages =
        try project prepared.messages with
        | Eio.Cancel.Cancelled _ as exn -> raise exn
        | exn when Keeper_operator_interrupt.is_operator_interrupt exn -> raise exn
        | exn ->
          Error
            (internal_error
               (runtime_label ^ " model input projection raised: " ^ Printexc.to_string exn))
      in
      Ok { prepared with messages })
  in
  let prepared =
    { prepared with
      Host.messages =
        prepared.messages
        @ Option.to_list
            (Keeper_client_tool_outbox.context_message
               ~read_media:read_retained_media
               tool_outbox)
    }
  in
  let composed_context = prepared.composed_context in
  let goal_with_handoff =
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
        ~goal:goal_text
  in
  (* Proper ~held delta tracking for ALL 3 ACP drivers: eliminates repeated
     World State / context-carrier resend on resume (fixing the 11.4M prompt
     resend bug). *)
  let* prompt_text, held_context, delivery, system_prompt_append =
    if is_resume
    then (
      let held = Session_store.held_context_for_resume claim_plan ~expected:stored_session in
      let resume_delivery =
        Host.resume_prompt
          ~goal:goal_with_handoff
          ~held
          ~turn_observation:prepared.turn_observation
          ?composed_context
          prepared.messages
      in
      Ok
        ( resume_delivery.prompt
        , resume_delivery.held_context
        , Session_store.Held_by_vendor_session
        , None ))
    else (
      let held =
        Host.start_held_context
          ~turn_observation:prepared.turn_observation
          ?composed_context
          prepared.messages
      in
      match profile.system_prompt_channel with
      | Acp.Meta_antigravity_append ->
        (* Deliver standing system prompt natively via _meta.antigravity.systemPrompt.append;
           carry start history + goal in opening prompt without duplicating system prompt. *)
        let start_body =
          let history_lines =
            List.map
              (fun msg ->
                 Host.history_role_label msg.Agent_core.Types.role
                 ^ Host.encode_start_message ~started_at:(Time_compat.now ()) msg)
              prepared.messages
          in
          let body =
            match history_lines with
            | [] -> goal_with_handoff
            | lines -> String.concat "\n\n" lines ^ "\n\n" ^ goal_with_handoff
          in
          let with_obs = Host.start_prompt prepared body in
          Keeper_context_submission_link.text with_obs
        in
        Ok
          ( start_body
          , held
          , Session_store.Prepared_start_context
          , Some prepared.system_prompt )
      | Acp.Framed_in_first_prompt ->
        let* framed =
          Host.framed_prompt_for_turn
            ?composed_context
            ~held:[]
            ~delivery:(Host.Framed_start { started_at = Time_compat.now () })
            ~goal:goal_with_handoff
            prepared
        in
        Ok (framed, held, Session_store.Prepared_start_context, None))
  in
  let effective_timeout_s =
    match turn_timeout_s with
    | None -> Some config.timeout_s
    | Some secs when secs <= 0.0 -> None
    | Some secs -> Some secs
  in
  let effective_effort =
    match prepared.reasoning_effort with
    | Some eff -> Some (Llm_provider.Reasoning_effort.to_string eff)
    | None -> config.effort
  in
  let effective_mode =
    match config.mode with
    | Some m -> m
    | None -> Acp.mode_of_posture config.driver native_posture
  in
  let raw_trace_run =
    Host.start_raw_trace
      ~keeper_name
      ~raw_trace
      ~prompt:prompt_text
      ~model:config.model
      ?reasoning_effort:effective_effort
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
      ~hooks
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
    { message_count = List.length prepared.messages
    ; delivery
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
  let key : Pool_key.t =
    { keeper_name
    ; runtime_id
    ; tool_surface_sha256
    ; cwd = base_path
    ; dangerously_skip_permissions =
        (native_posture = Runtime_native_tools.Native_full)
    }
  in
  let build_fallback_start_prompt () =
    match profile.system_prompt_channel with
    | Acp.Meta_antigravity_append ->
      let history_lines =
        List.map
          (fun msg ->
             Host.history_role_label msg.Agent_core.Types.role
             ^ Host.encode_start_message ~started_at:(Time_compat.now ()) msg)
          prepared.messages
      in
      let body =
        match history_lines with
        | [] -> goal_with_handoff
        | lines -> String.concat "\n\n" lines ^ "\n\n" ^ goal_with_handoff
      in
      let with_obs = Host.start_prompt prepared body in
      Ok (Keeper_context_submission_link.text with_obs, Some prepared.system_prompt)
    | Acp.Framed_in_first_prompt ->
      let* framed =
        Host.framed_prompt_for_turn
          ?composed_context
          ~held:[]
          ~delivery:(Host.Framed_start { started_at = Time_compat.now () })
          ~goal:goal_with_handoff
          prepared
      in
      Ok (framed, None)
  in
  let blocks_of_prompt text =
    Acp.Text_block text
    :: List.map
         (fun (img : Runtime_official_client_tool.image_input) ->
            Acp.Image_block
              { mime_type = img.media_type; base64_data = img.base64_data })
         goal_images
  in
  let execute_with_entry (entry : pool_entry) ~persistent =
    run_serialized_turn
      ~mutex:entry.turn_mutex
      ~on_holder_exception:(fun () ->
        if persistent then evict_entry_if_same key entry)
      (fun () ->
      let host_stop_promise, resolve_host_stop_u = Eio.Promise.create () in
      let host_stop_fired = Atomic.make false in
      let resolve_host_stop stop =
        if Atomic.compare_and_set host_stop_fired false true
        then Eio.Promise.resolve resolve_host_stop_u stop
      in
      (* Establish or reuse the ACP session on the persistent child. *)
      let* session_id, resumed, active_prompt_text =
        match claim_plan.previous_settlement, entry.session_id with
        | Some { session_id; _ }, Some open_sid when String.equal session_id open_sid ->
          Ok (open_sid, true, prompt_text)
        | Some { session_id; _ }, _ ->
          let caps = Acp.capabilities entry.client in
          let resume_res =
            if caps.resume_session
            then
              Acp.resume_session
                entry.client
                ~session_id
                ~cwd:base_path
                ~mcp_server:entry.mcp_server
                ()
            else if caps.load_session
            then
              Acp.load_session
                entry.client
                ~session_id
                ~cwd:base_path
                ~mcp_server:entry.mcp_server
                ()
            else Error (Acp.Protocol_error { stage = "resume"; detail = "unsupported" })
          in
          (match resume_res with
           | Ok info ->
             entry.session_id <- Some info.session_id;
             Ok (info.session_id, true, prompt_text)
           | Error _ ->
             (* Child restarted or prior session gone: open a clean session with
                full start prompt + system prompt so zero context is lost. *)
             let* fallback_prompt, fallback_sys = build_fallback_start_prompt () in
             let* info =
               Acp.new_session
                 entry.client
                 ~cwd:base_path
                 ?system_prompt_append:fallback_sys
                 ~mcp_server:entry.mcp_server
                 ~mode:effective_mode
                 ~model:config.model
                 ?effort:effective_effort
                 ()
               |> Result.map_error (fun err ->
                 recovery_failure := recovery_failure_of_acp_error err;
                 acp_error_to_core_error err)
             in
             entry.session_id <- Some info.session_id;
             entry.last_context_used <- None;
             Ok (info.session_id, false, fallback_prompt))
        | None, _ ->
          let* info =
            Acp.new_session
              entry.client
              ~cwd:base_path
              ?system_prompt_append
              ~mcp_server:entry.mcp_server
              ~mode:effective_mode
              ~model:config.model
              ?effort:effective_effort
              ()
            |> Result.map_error (fun err ->
              recovery_failure := recovery_failure_of_acp_error err;
              acp_error_to_core_error err)
          in
          entry.session_id <- Some info.session_id;
          entry.last_context_used <- None;
          Ok (info.session_id, false, prompt_text)
      in
      let prompt_blocks = blocks_of_prompt active_prompt_text in
      let position =
        if resumed then Keeper_usage_resolution.Resumed else Keeper_usage_resolution.Fresh
      in
      let allowed_tool_names =
        List.map (fun (tool : Host.dynamic_tool) -> tool.name) dynamic_tools
      in
      let stream =
        make_stream_projection
          ~driver:config.driver
          ~model:config.model
          ~session_id
          ~turn_count:hook_turn_count
          ~position
          ~native_posture
          ~allowed_tool_names
          ~observe_effect_attempted
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
         else Host.Whole_input_transmitted prepared.messages);
      with_slot_lock entry.turn_slot_mutex (fun () ->
        entry.turn_slot :=
          Some
            { tools = dynamic_tools
            ; on_tool_started = stream.on_tool_started
            ; on_tool_finished = stream.on_tool_finished
            ; resolve_host_stop
            });
      let clear_slot () =
        with_slot_lock entry.turn_slot_mutex (fun () -> entry.turn_slot := None)
      in
      let permission_policy =
        Acp.permission_policy_of_posture
          ~mcp_server_name
          ~allowed_tool_names
          native_posture
      in
      let outcome =
        Fun.protect
          ~finally:clear_slot
          (fun () ->
            Watched_work.run
              (fun () ->
                `Runtime
                  (Acp.prompt
                     entry.client
                     ~session_id
                     ~blocks:prompt_blocks
                     ~timeout_s:effective_timeout_s
                     ~permission_policy
                     ~on_event:stream.on_acp_event
                     ()))
              ~watcher:(fun () ->
                let stop = Eio.Promise.await host_stop_promise in
                Acp.cancel entry.client ~session_id;
                `Abort stop))
      in
      match outcome with
      | `Abort stop -> Ok (`Stopped (session_id, stop))
      | `Runtime (Ok prompt_res) ->
        let prev_used = entry.last_context_used in
        let cur_used = prompt_res.usage.context_used in
        entry.last_context_used <- cur_used;
        let compacted = compaction_detected ~prev_used ~cur_used in
        close_delivery_frontier ();
        Ok (`Completed (prompt_res, resumed, compacted))
      | `Runtime (Error err) ->
        if persistent then evict_entry_if_same key entry;
        recovery_failure := recovery_failure_of_acp_error err;
        Error (acp_error_to_core_error err))
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
          ~base_path
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
        let turn_slot = ref None in
        let turn_slot_mutex = Stdlib.Mutex.create () in
        let bridge =
          start_mcp_bridge ~sw ~env ~pinned_tool_specs ~turn_slot ~turn_slot_mutex
        in
        let mcp_server = mcp_server_of_bridge bridge in
        let acp_config : Acp.config =
          { driver = config.driver
          ; cli_path = config.cli_path
          ; args = config.args
          ; strip_env = config.strip_env
          ; skills_dirs = discover_skills_dirs ~base_path config
          ; cwd = base_path
          ; oauth_source = config.oauth_source
          ; dangerously_skip_permissions = key.dangerously_skip_permissions
          ; admission_timeout_s = Acp.init_timeout_s
          }
        in
        let* client =
          Acp.start ~sw ~proc_mgr ~clock ~config:acp_config ~mcp_server ()
          |> Result.map_error (fun err ->
            recovery_failure := recovery_failure_of_acp_error err;
            acp_error_to_core_error err)
        in
        let entry =
          { client
          ; mcp_server
          ; turn_slot
          ; turn_slot_mutex
          ; turn_mutex = Eio.Mutex.create ()
          ; session_id = None
          ; last_context_used = None
          ; stop_owner = ignore
          }
        in
        execute_with_entry entry ~persistent:false)
  in
  let turn_result =
    try
      match run_client () with
      | Error err -> Error err
      | Ok (`Stopped (session_id, stop)) ->
        let turn_id = provider_turn_identity ~session_id ~turn_count:hook_turn_count in
        let* () =
          update_session "host-stop turn identity" (fun expected ->
            Session_store.mark_turn_started
              ~base_path
              ~keeper_name
              ~expected
              ~session_id
              ~turn_id
              ~turn_count:hook_turn_count
              ~updated_at:(Time_compat.now ()))
          |> Result.map_error internal_error
        in
        let latency_ms =
          Int.of_float (Float.max 0.0 ((Time_compat.now () -. started_at) *. 1000.0))
        in
        let projected =
          Host.host_stop_result
            ~runtime_id
            ~model:config.model
            ~session_id
            ~turn_id
            ~provider_turn_ordinal:hook_turn_count
            ~turns_used:hook_turn_count
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
          Session_store.settle
            ~base_path
            ~keeper_name
            ~expected:!session_state
            ~session_id
            ~turn_id
            ~updated_at:(Time_compat.now ())
          |> Result.map_error (fun detail ->
            internal_error ("ACP host-stop settlement failed: " ^ detail))
        in
        session_state := settled;
        on_session_settled settled;
        projected
      | Ok (`Completed (prompt_res, resumed, compacted)) ->
        natural_completion := true;
        let session_id = prompt_res.session_id in
        let turn_id = provider_turn_identity ~session_id ~turn_count:hook_turn_count in
        let* () =
          update_session "turn identity transition" (fun expected ->
            Session_store.mark_turn_started
              ~base_path
              ~keeper_name
              ~expected
              ~session_id
              ~turn_id
              ~turn_count:hook_turn_count
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
        (match on_usage_report with
         | None -> ()
         | Some report ->
           report
             { Keeper_client_usage_report.official_turn = hook_turn_count
             ; response_id = turn_id
             ; model = config.model
             ; conversation_id = session_id
             ; position =
                 (if resumed
                  then Keeper_usage_resolution.Resumed
                  else Keeper_usage_resolution.Fresh)
             ; usage_scope = Runtime_usage_scope.Turn_total
             ; count = Keeper_client_usage_report.Running_count usage
             ; vendor_total_tokens = Some prompt_res.usage.total_tokens
             });
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
          ; model = config.model
          ; unreadable_tool_uses = []
          ; stop_reason = stop_reason_of_acp_stop_reason prompt_res.stop_reason
          ; content
          ; usage = Some usage
          ; telemetry =
              Some
                { Agent_core.Types.default_inference_telemetry with
                  request_latency_ms = Some latency_ms
                ; canonical_model_id = Some config.model
                ; reported_cache_usage =
                    Some
                      { Agent_core.Types.cache_creation_input_tokens =
                          Some prompt_res.usage.cached_write_tokens
                      ; cache_read_input_tokens =
                          Some prompt_res.usage.cached_read_tokens
                      }
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
          (if compacted
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
                    prepared.messages)
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
        let capture, _metrics =
          Runtime_observation.runtime_metrics_for_candidates ~runtime_id ~keeper_name ()
        in
        Runtime_observation.record_attempt_terminal
          capture
          ~model_id:config.model
          ~latency_ms:(Some latency_ms)
          ~error:None;
        let runtime_observation =
          Runtime_observation.runtime_observation_with_metrics
            ~selected_model:(Some config.model)
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
          ; turns = hook_turn_count
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
  in
  let turn_result =
    let* result = turn_result in
    let produced = if !natural_completion then Option.to_list !produced_results else [] in
    on_results_ready
      (Some (Keeper_client_tool_outbox.pending_consumption (tool_outbox :: produced)));
    Ok result
  in
  let turn_result =
    match turn_result with
    | Ok result -> Ok (Host.finish_raw_success ~keeper_name raw_trace_run result)
    | Error err ->
      Host.finish_raw_error ~keeper_name raw_trace_run err;
      Error err
  in
  let _ = official_task_reference in
  match turn_result with
  | Ok _ -> turn_result
  | Error original_error ->
    let original_detail = Agent_core.Error.to_string original_error in
    (match Eio.Cancel.protect (fun () -> settle_failed_claim original_detail) with
     | Ok () -> turn_result
     | Error recovery_detail ->
       Error
         (internal_error
            (Printf.sprintf
               "ACP turn failed and recovery persistence also failed: original=%s recovery=%s"
               original_detail
               recovery_detail)))
;;

let run
      ?(on_guidance_prepared = fun () -> Ok ())
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
       run_without_lifecycle
         ~on_guidance_prepared
         ~result_scope
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
         ~config)
;;

module For_testing = struct
  let acp_error_to_core_error = acp_error_to_core_error
  let recovery_failure_of_acp_error = recovery_failure_of_acp_error
  let api_usage_of_acp_usage = api_usage_of_acp_usage
  let stop_reason_of_acp_stop_reason = stop_reason_of_acp_stop_reason
  let compaction_detected = compaction_detected

  let start_mcp_bridge_for_specs ~sw ~env ~pinned_tool_specs =
    let turn_slot = ref None in
    let turn_slot_mutex = Stdlib.Mutex.create () in
    start_mcp_bridge ~sw ~env ~pinned_tool_specs ~turn_slot ~turn_slot_mutex
  ;;

  type pool_key = Pool_key.t =
    { keeper_name : string
    ; runtime_id : string
    ; tool_surface_sha256 : string
    ; cwd : string
    ; dangerously_skip_permissions : bool
    }

  let run_serialized_turn = run_serialized_turn

  module Pool = Keeper_pool
end
