open Masc_tui_core
open Masc_tui_net
open Masc_tui_protocol
open Masc_tui_store
open Masc_tui_term

type bus_key =
  | Key_get of string
  | Key_freshness of Subscriptions.stream_id

let equal_bus_key a b =
  match a, b with
  | Key_get x, Key_get y -> String.equal x y
  | Key_freshness x, Key_freshness y -> Subscriptions.equal_stream_kind x y
  | Key_get _, Key_freshness _ | Key_freshness _, Key_get _ -> false

let stream_kind_tag = function
  | Subscriptions.Stream_observer -> 0
  | Subscriptions.Stream_fleet -> 1
  | Subscriptions.Stream_model_metrics -> 2
  | Subscriptions.Stream_tool_metrics_series -> 3
  | Subscriptions.Stream_logs _ -> 4

let hash_bus_key = function
  | Key_get path -> Hashtbl.hash (0, path)
  | Key_freshness stream -> Hashtbl.hash (1, stream_kind_tag stream)

type bus = (bus_key, Msg.t, Msg.t) Ui_bus.t

let create_bus ?stream_capacity ?on_wake () =
  Ui_bus.create ?stream_capacity ~key_equal:equal_bus_key
    ~key_hash:hash_bus_key ?on_wake ()

let admin_token_path ~base_path =
  Filename.concat (Common.auth_dir_from_base_path ~base_path) "admin.token"

let nonblank_trimmed s =
  let t = String.trim s in
  if String.equal t "" then None else Some t

let read_first_nonblank_line path =
  match In_channel.open_text path with
  | ic ->
      Fun.protect
        ~finally:(fun () -> In_channel.close_noerr ic)
        (fun () ->
          let rec scan () =
            match In_channel.input_line ic with
            | None -> None
            | Some line -> (
                match nonblank_trimmed line with
                | Some tok -> Some tok
                | None -> scan ())
          in
          scan ())
  | exception (Sys_error _ | Unix.Unix_error _) -> None

let load_bearer_token ?(getenv = Sys.getenv_opt) ~base_path () =
  match Option.bind (getenv "MASC_TOKEN") nonblank_trimmed with
  | Some _ as env_tok -> env_tok
  | None -> read_first_nonblank_line (admin_token_path ~base_path)

let endpoint_of_cli ?bearer_token (cli : Cli_args.config) =
  let token =
    match bearer_token with
    | Some tok_opt -> tok_opt
    | None -> load_bearer_token ~base_path:cli.base_path ()
  in
  Http_client.make_endpoint ~scheme:cli.scheme ~host:cli.host ~port:cli.port
    ?bearer_token:token ()

let msg_error_of_http = function
  | Http_client.Transport err -> Msg.Transport err
  | Http_client.Workspace_mismatch
      {
        expected_instance;
        observed_instance;
        observed_workspace_sha256;
        message;
      } ->
      Msg.Workspace_mismatch
        {
          expected_instance;
          observed_instance;
          observed_workspace_sha256;
          message;
        }
  | Http_client.Http_error { status; body; api_error } ->
      Msg.Http_error { status; body; api_error }
  | Http_client.Decode_error msg -> Msg.Decode_error msg

let stream_spec_of_id = function
  | Subscriptions.Stream_observer -> Sse_hub.Stream_spec.default_observer
  | Subscriptions.Stream_fleet -> Sse_hub.Stream_spec.default_fleet
  | Subscriptions.Stream_model_metrics -> Sse_hub.Stream_spec.model_metrics
  | Subscriptions.Stream_tool_metrics_series ->
      Sse_hub.Stream_spec.tool_metrics_series
  | Subscriptions.Stream_logs { since_seq } ->
      Sse_hub.Stream_spec.logs ?since_seq ()

let stream_id_of_kind = function
  | Sse_hub.Stream_spec.Observer -> Subscriptions.Stream_observer
  | Sse_hub.Stream_spec.Fleet -> Subscriptions.Stream_fleet
  | Sse_hub.Stream_spec.Model_metrics -> Subscriptions.Stream_model_metrics
  | Sse_hub.Stream_spec.Tool_metrics_series ->
      Subscriptions.Stream_tool_metrics_series
  | Sse_hub.Stream_spec.Logs { since_seq } ->
      Subscriptions.Stream_logs { since_seq }

let is_safe_external_url url =
  let trimmed = String.trim url in
  let has_scheme =
    String.starts_with ~prefix:"http://" trimmed
    || String.starts_with ~prefix:"https://" trimmed
  in
  if not has_scheme then false
  else
    let len = String.length trimmed in
    let rec check i =
      if i = len then true
      else
        let code = Char.code trimmed.[i] in
        if code <= 0x20 || code = 0x7F then false else check (i + 1)
    in
    check 0

let fetch_planning_with_tasks ~observed_at ~fetch_planning ~fetch_tasks =
  match fetch_planning () with
  | Error _ as err -> err
  | Ok (snap : Wire_work.planning_snapshot) when snap.tasks <> [] -> Ok snap
  | Ok snap -> (
      match fetch_tasks () with
      | Ok tasks ->
          Ok (Wire_work.enrich_planning_with_tasks ~observed_at snap tasks)
      | Error _ as err -> err)

let is_health_body_ready body =
  match Yojson.Safe.from_string body with
  | json -> (
      match Wire_common.decode_server_health json with
      | Ok health -> (
          health.ok
          &&
          match health.ready with
          | Some false -> false
          | Some true | None -> true)
      | Error _ -> false)
  | exception Yojson.Json_error _ -> false

let is_local_host host =
  match String.lowercase_ascii (String.trim host) with
  | "127.0.0.1" | "localhost" | "::1" | "[::1]" -> true
  | _ -> false

let editor_file_path ~base_path = function
  | Cmd.Edit_runtime_toml ->
      let config_dir =
        Filename.concat (Common.masc_dir_from_base_path ~base_path) "config"
      in
      Some (Filename.concat config_dir "runtime.toml")
  | Cmd.Edit_keeper_toml keeper ->
      let keepers_dir =
        Filename.concat
          (Filename.concat (Common.masc_dir_from_base_path ~base_path) "config")
          "keepers"
      in
      Some (Filename.concat keepers_dir (Common.safe_filename keeper ^ ".toml"))
  | Cmd.Edit_wiki_page _ -> None

type editor_handoff = {
  pause_terminal : unit -> unit;
  resume_terminal : unit -> unit;
}

let noop_editor_handoff =
  { pause_terminal = (fun () -> ()); resume_terminal = (fun () -> ()) }

type t = {
  sw : Eio.Switch.t;
  closed : bool Atomic.t;
  io : Io_domain.t;
  worker : Worker_pool.t;
  clock : float Eio.Time.clock_ty Eio.Resource.t;
  cli : Cli_args.config;
  bus : bus;
  explicit_bearer_override : bool;
  endpoint : Http_client.endpoint Atomic.t;
  stream_epoch : Epoch.t Atomic.t;
  owned_server : Masc_server_lifecycle.owned_server option Atomic.t;
  sse_hub : Sse_hub.t;
  voice_runner : Voice_runner.t;
  editor_handoff : editor_handoff;
  on_quit : Exit_reason.t -> unit;
  on_restart : unit -> unit;
}

let dynamic_voice_backend ~io ~clock ~endpoint_ref : Voice_runner.backend =
  let current () =
    Voice_runner.http_and_local_backend ~io ~clock
      ~endpoint:(Atomic.get endpoint_ref)
  in
  {
    Voice_runner.probe = (fun () -> (current ()).probe ());
    record_until_stopped =
      (fun ~device ~stop_signal ~on_level ->
        (current ()).record_until_stopped ~device ~stop_signal ~on_level);
    transcribe = (fun ~audio_path -> (current ()).transcribe ~audio_path);
    speak = (fun ~text ~voice_id -> (current ()).speak ~text ~voice_id);
    cleanup_audio =
      (fun ~audio_path -> (current ()).cleanup_audio ~audio_path);
  }

let msg_of_voice_event = function
  | Voice_runner.Phase_changed Voice_runner.Voice_idle -> Msg.Voice_idle
  | Voice_runner.Phase_changed (Voice_runner.Voice_recording _) ->
      Msg.Voice_started
  | Voice_runner.Phase_changed Voice_runner.Voice_transcribing ->
      Msg.Voice_transcribing
  | Voice_runner.Phase_changed Voice_runner.Voice_speaking -> Msg.Voice_speaking
  | Voice_runner.Phase_changed (Voice_runner.Voice_failed reason) ->
      Msg.Voice_failed reason
  | Voice_runner.Level_meter db -> Msg.Voice_level db
  | Voice_runner.Transcript_ready text -> Msg.Voice_transcript text
  | Voice_runner.Speak_done -> Msg.Voice_idle
  | Voice_runner.Capabilities c ->
      Msg.Voice_capabilities
        {
          recorder_available = c.recorder_available;
          recorder_cmd = c.recorder_cmd;
          stt_available = c.stt_available;
          tts_available = c.tts_available;
        }
  | Voice_runner.Voice_error reason -> Msg.Voice_failed reason

let decode_log_frame_entries json =
  match Wire_infra.decode_system_log_snapshot json with
  | Ok entries ->
      (* Live /api/v1/dashboard/logs/stream sends newest-first batch frames
         ({"reset": bool, "entries": [...]}). Emit oldest-first so append_log
         preserves chronological order. *)
      List.rev entries
  | Error _ -> (
      match Wire_infra.decode_system_log_entry json with
      | Ok entry -> [ entry ]
      | Error _ -> [])

let decode_hub_event_msgs ~epoch ~observed_at ev =
  match ev with
  | Sse_hub.Freshness { stream; freshness } ->
      let sid = stream_id_of_kind stream in
      [ (Some (Key_freshness sid), Msg.Sse_freshness { epoch; stream = sid; freshness }) ]
  | Sse_hub.Observer_handshake hs ->
      [ (None, Msg.Sse_event { epoch; event = Msg.Sse_observer_handshake hs }) ]
  | Sse_hub.Observer_delivery delivery ->
      [ (None, Msg.Sse_event { epoch; event = Msg.Sse_observer_delivery delivery }) ]
  | Sse_hub.Fleet_event fleet_ev ->
      [ (None, Msg.Sse_event { epoch; event = Msg.Sse_fleet fleet_ev }) ]
  | Sse_hub.Raw_frame { stream; frame } -> (
      match stream with
      | Sse_hub.Stream_spec.Logs _ -> (
          match Yojson.Safe.from_string frame.data with
          | json ->
              decode_log_frame_entries json
              |> List.map (fun entry ->
                     (None, Msg.Sse_event { epoch; event = Msg.Sse_log_entry entry }))
          | exception Yojson.Json_error _ -> [])
      | Sse_hub.Stream_spec.Model_metrics -> (
          match Yojson.Safe.from_string frame.data with
          | json ->
              if Wire_common.has_field json "schema" then (
                match Wire_runtime.decode_efficiency_month ~observed_at json with
                | Ok eff ->
                    [
                      ( None
                      , Msg.Sse_event { epoch; event = Msg.Sse_model_metrics eff } );
                    ]
                | Error _ -> [])
              else if Wire_common.has_field json "window_minutes" then (
                match Wire_runtime.decode_models_metrics ~observed_at json with
                | Ok snap when snap.bucket_minutes > 0 ->
                    [
                      ( None
                      , Msg.Sse_event
                          {
                            epoch;
                            event = Msg.Sse_models_metrics_snapshot snap;
                          } );
                    ]
                | Ok _ | Error _ ->
                    (* Unbucketed (bucket_minutes = 0) 30m aggregate frames do
                       not carry hourly series and must not overwrite the 24h
                       60m-bucketed chart state. *)
                    [])
              else if Wire_common.has_field json "error" then
                let detail =
                  match Wire_common.optional_nonblank_string json "error" with
                  | Ok (Some msg) -> "model metrics stream: " ^ msg
                  | Ok None | Error _ -> "model metrics stream error"
                in
                [
                  ( None
                  , Msg.Sse_event
                      {
                        epoch;
                        event =
                          Msg.Sse_observer_delivery
                            {
                              cursor = None;
                              decoded = Wire_observer.Undecodable detail;
                            };
                      } );
                ]
              else []
          | exception Yojson.Json_error _ -> [])
      | Sse_hub.Stream_spec.Tool_metrics_series -> (
          match Yojson.Safe.from_string frame.data with
          | json -> (
              match Wire_runtime.decode_tool_series json with
              | Ok series ->
                  [
                    ( None
                    , Msg.Sse_event { epoch; event = Msg.Sse_tool_series series } );
                  ]
              | Error _ -> [])
          | exception Yojson.Json_error _ -> [])
      | Sse_hub.Stream_spec.Observer | Sse_hub.Stream_spec.Fleet -> [])

let publish_hub_event ~bus ~stream_epoch ev =
  let epoch = Atomic.get stream_epoch in
  let observed_at = Clock.Mono.now () in
  List.iter
    (function
      | Some key, msg -> Ui_bus.publish_snapshot bus ~key msg
      | None, msg -> Ui_bus.publish_stream bus msg)
    (decode_hub_event_msgs ~epoch ~observed_at ev)

let create ~sw ~io ~worker ~clock ~cli ~bus ?bearer_token ?voice_backend
    ?(editor_handoff = noop_editor_handoff) ~on_quit ~on_restart () =
  Eio.Switch.check sw;
  let clock = (clock :> float Eio.Time.clock_ty Eio.Resource.t) in
  let explicit_bearer_override =
    (match bearer_token with Some _ -> true | None -> false)
    || Option.is_some (Option.bind (Sys.getenv_opt "MASC_TOKEN") nonblank_trimmed)
  in
  let initial_ep = endpoint_of_cli ?bearer_token cli in
  let endpoint = Atomic.make initial_ep in
  let stream_epoch = Atomic.make Epoch.initial in
  let owned_server = Atomic.make None in
  let sse_hub =
    Sse_hub.create ~io ~clock ~endpoint:initial_ep
      ~on_event:(publish_hub_event ~bus ~stream_epoch)
  in
  let backend =
    match voice_backend with
    | Some b -> b
    | None -> dynamic_voice_backend ~io ~clock ~endpoint_ref:endpoint
  in
  let voice_runner =
    Voice_runner.create ~sw ~backend ~on_event:(fun ev ->
        Ui_bus.publish_stream bus (Msg.Voice_event (msg_of_voice_event ev)))
  in
  let closed = Atomic.make false in
  Eio.Switch.on_release sw (fun () -> Atomic.set closed true);
  {
    sw;
    closed;
    io;
    worker;
    clock;
    cli;
    bus;
    explicit_bearer_override;
    endpoint;
    stream_epoch;
    owned_server;
    sse_hub;
    voice_runner;
    editor_handoff;
    on_quit;
    on_restart;
  }

let current_endpoint t = Atomic.get t.endpoint

let update_workspace_guard t ~instance_id ~workspace_sha256 =
  let guard : Http_client.workspace_guard =
    { expected_instance = instance_id; expected_workspace = workspace_sha256 }
  in
  let next_ep = Http_client.with_guard (Atomic.get t.endpoint) guard in
  Atomic.set t.endpoint next_ep;
  Sse_hub.update_endpoint t.sse_hub next_ep

let worker_decode_threshold_bytes = 4096

let decode_raw_json t ~decode raw_body =
  let work () =
    match Yojson.Safe.from_string raw_body with
    | json -> (
        match decode json with
        | Ok v -> Ok v
        | Error msg -> Error (Msg.Decode_error msg))
    | exception Yojson.Json_error msg ->
        Error (Msg.Decode_error ("invalid JSON: " ^ msg))
  in
  if String.length raw_body > worker_decode_threshold_bytes then
    Worker_pool.submit_cpu t.worker ~name:"tui_json_decode" work
  else work ()

let fetch_and_decode_get ?timeout_sec t ~path ~decode =
  let ep = Atomic.get t.endpoint in
  match Http_client.get_raw ~io:t.io ~clock:t.clock ?timeout_sec ep ~path with
  | Error err -> Error (msg_error_of_http err)
  | Ok raw -> decode_raw_json t ~decode raw

let post_and_decode t ~path ~body ~decode =
  let ep = Atomic.get t.endpoint in
  let body_str = Yojson.Safe.to_string body in
  match
    Http_client.post_raw ~io:t.io ~clock:t.clock ~content_type:"application/json"
      ~body:body_str ep ~path
  with
  | Error err -> Error (msg_error_of_http err)
  | Ok raw -> decode_raw_json t ~decode raw

let post_ack t ~path ~body =
  let ep = Atomic.get t.endpoint in
  let body_str = Yojson.Safe.to_string body in
  match
    Http_client.post_raw ~io:t.io ~clock:t.clock ~content_type:"application/json"
      ~body:body_str ep ~path
  with
  | Error err -> Error (msg_error_of_http err)
  | Ok _ -> Ok ()

let fork_safe t fn =
  if Atomic.get t.closed then ()
  else begin
    Eio.Switch.check t.sw;
    Eio.Fiber.fork ~sw:t.sw (fun () ->
        match fn () with
        | () -> ()
        | exception (Eio.Cancel.Cancelled _ as ex) -> raise ex
        | exception Io_domain.Closed -> ()
        | exception ex ->
            Ui_bus.publish_stream t.bus
              (Msg.Http_reply
                 {
                   epoch = Atomic.get t.stream_epoch;
                   reply =
                     Msg.Reply_action_ack
                       {
                         label =
                           Say.make ~ko:"비동기 요청 오류"
                             ~en:"Async command error";
                         result =
                           Error
                             (Msg.Transport
                                (Health.Other_io (Printexc.to_string ex)));
                       };
                 }))
  end

let execute_get t ~epoch req =
  let path = Cmd.get_request_path req in
  fork_safe t (fun () ->
      let observed_at = Clock.Mono.now () in
      let msg =
        match req with
        | Cmd.Get_health ->
            let result =
              fetch_and_decode_get t ~path
                ~decode:Wire_common.decode_server_health
            in
            Msg.Server_health_result { epoch; result }
        | Cmd.Get_dashboard_shell ->
            let reply =
              Msg.Reply_dashboard_shell
                (fetch_and_decode_get t ~path
                   ~decode:(Wire_fleet.decode_dashboard_shell ~observed_at))
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_keepers_roster ->
            let roster_res =
              fetch_and_decode_get t ~path ~decode:(fun json ->
                  match Wire_fleet.decode_keepers_roster ~observed_at json with
                  | Error _ as err -> err
                  | Ok keepers ->
                      let extras =
                        match Wire_fleet.decode_keepers_roster_extras json with
                        | Ok ex -> Some ex
                        | Error _ -> None
                      in
                      Ok (keepers, extras))
            in
            let reply =
              match roster_res with
              | Ok (keepers, extras_opt) ->
                  Option.iter
                    (fun ex ->
                      Ui_bus.publish_snapshot t.bus
                        ~key:(Key_get (path ^ "#extras"))
                        (Msg.Http_reply
                           { epoch; reply = Msg.Reply_keepers_roster_extras ex }))
                    extras_opt;
                  Msg.Reply_keepers_roster (Ok keepers)
              | Error _ as err -> Msg.Reply_keepers_roster err
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_keeper_turns ->
            let reply =
              Msg.Reply_keeper_turns
                (fetch_and_decode_get t ~path
                   ~decode:Wire_fleet.decode_keeper_turns)
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_chat_history { keeper; _ } ->
            let result =
              fetch_and_decode_get t ~path
                ~decode:Wire_fleet.decode_chat_history_page
            in
            Msg.Http_reply
              { epoch; reply = Msg.Reply_chat_history { keeper; result } }
        | Cmd.Get_planning ->
            let planning_res =
              fetch_planning_with_tasks ~observed_at
                ~fetch_planning:(fun () ->
                  fetch_and_decode_get t ~path ~decode:(fun json ->
                      match
                        Wire_work.decode_planning_snapshot ~observed_at json
                      with
                      | Error _ as err -> err
                      | Ok snap ->
                          (match Wire_work.decode_planning_backlog_counts json with
                          | Ok (Some counts) ->
                              Ui_bus.publish_snapshot t.bus
                                ~key:(Key_get (path ^ "#backlog"))
                                (Msg.Http_reply
                                   {
                                     epoch;
                                     reply = Msg.Reply_planning_backlog counts;
                                   })
                          | Ok None | Error _ -> ());
                          Ok snap))
                ~fetch_tasks:(fun () ->
                  fetch_and_decode_get t ~path:Wire_work.execution_tasks_path
                    ~decode:(fun json ->
                      (match
                         Wire_fleet.decode_execution_keeper_enrichments json
                       with
                      | Ok ((_ :: _ as enrichments), candle_opt) ->
                          Ui_bus.publish_snapshot t.bus
                            ~key:
                              (Key_get
                                 (Wire_work.execution_tasks_path ^ "#enrich"))
                            (Msg.Http_reply
                               {
                                 epoch;
                                 reply =
                                   Msg.Reply_execution_enrichments
                                     (enrichments, candle_opt);
                               })
                      | Ok ([], Some candle) ->
                          Ui_bus.publish_snapshot t.bus
                            ~key:
                              (Key_get
                                 (Wire_work.execution_tasks_path ^ "#enrich"))
                            (Msg.Http_reply
                               {
                                 epoch;
                                 reply =
                                   Msg.Reply_execution_enrichments
                                     ([], Some candle);
                               })
                      | Ok ([], None) | Error _ -> ());
                      Wire_work.decode_execution_tasks json))
            in
            let reply = Msg.Reply_planning planning_res in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_verifications _ ->
            let reply =
              Msg.Reply_verifications
                (fetch_and_decode_get t ~path
                   ~decode:Wire_work.decode_verification_snapshot)
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_schedules _ ->
            let reply =
              Msg.Reply_schedules
                (fetch_and_decode_get t ~path
                   ~decode:Wire_work.decode_schedules_snapshot)
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_asks _ ->
            let reply =
              Msg.Reply_asks
                (fetch_and_decode_get t ~path
                   ~decode:Wire_work.decode_asks_snapshot)
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_tool_approvals ->
            let reply =
              Msg.Reply_tool_approvals
                (fetch_and_decode_get t ~path
                   ~decode:Wire_work.decode_tool_approvals)
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_gate_pending ->
            let reply =
              Msg.Reply_gate_pending
                (fetch_and_decode_get t ~path
                   ~decode:Wire_work.decode_gate_pending_list)
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_candle_ledger _ ->
            let reply =
              Msg.Reply_candle_ledger
                (fetch_and_decode_get t ~path
                   ~decode:Wire_work.decode_candle_ledger)
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_board_feed _ ->
            let reply =
              Msg.Reply_board_feed
                (fetch_and_decode_get t ~path
                   ~decode:(Wire_knowledge.decode_board_feed ~observed_at))
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_board_thread _ ->
            let reply =
              Msg.Reply_board_thread
                (fetch_and_decode_get t ~path
                   ~decode:(Wire_knowledge.decode_board_thread ~observed_at))
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_quarantines _ ->
            let reply =
              Msg.Reply_quarantines
                (fetch_and_decode_get t ~path
                   ~decode:Wire_knowledge.decode_quarantines)
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_wiki_index _ ->
            let reply =
              Msg.Reply_wiki_index
                (fetch_and_decode_get t ~path
                   ~decode:Wire_knowledge.decode_wiki_index)
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_wiki_page _ ->
            let reply =
              Msg.Reply_wiki_page
                (fetch_and_decode_get t ~path
                   ~decode:Wire_knowledge.decode_wiki_page_detail)
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_wiki_log _ ->
            let reply =
              Msg.Reply_wiki_log
                (fetch_and_decode_get t ~path
                   ~decode:Wire_knowledge.decode_wiki_log)
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_wiki_search _ ->
            let reply =
              Msg.Reply_wiki_search
                (fetch_and_decode_get t ~path
                   ~decode:Wire_knowledge.decode_wiki_search)
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_wiki_lint ->
            let reply =
              Msg.Reply_wiki_lint
                (fetch_and_decode_get t ~path
                   ~decode:Wire_knowledge.decode_wiki_lint)
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_artifacts ->
            let reply =
              Msg.Reply_artifacts
                (fetch_and_decode_get t ~path
                   ~decode:Wire_knowledge.decode_artifacts_list)
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_world_memory ->
            let primary =
              fetch_and_decode_get t ~path
                ~decode:Wire_knowledge.decode_world_memory
            in
            let resolved =
              match primary with
              | Error (Msg.Http_error { status = 404; _ }) ->
                  fetch_and_decode_get t
                    ~path:Wire_knowledge.workspace_memory_inventory_path
                    ~decode:
                      Wire_knowledge.decode_workspace_memory_inventory_as_world_memory
              | Ok _
              | Error
                  ( Msg.Http_error _
                  | Msg.Transport _
                  | Msg.Workspace_mismatch _
                  | Msg.Decode_error _ ) ->
                  primary
            in
            let reply = Msg.Reply_world_memory resolved in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_memory_diff { keeper; _ } ->
            let reply =
              Msg.Reply_memory_diff
                {
                  keeper;
                  result =
                    fetch_and_decode_get t ~path
                      ~decode:Wire_knowledge.decode_memory_diff;
                }
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_keeper_memory_os_internals { keeper } ->
            let reply =
              Msg.Reply_keeper_memory_os_internals
                {
                  keeper;
                  result =
                    fetch_and_decode_get t ~path
                      ~decode:Wire_knowledge.decode_memory_os_internals;
                }
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_keeper_memory_facts { keeper } ->
            let reply =
              Msg.Reply_keeper_memory_facts
                {
                  keeper;
                  result =
                    fetch_and_decode_get t ~path
                      ~decode:Wire_knowledge.decode_keeper_memory_facts;
                }
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_keeper_memory_activity { keeper; _ } ->
            let reply =
              Msg.Reply_keeper_memory_activity
                {
                  keeper;
                  result =
                    fetch_and_decode_get t ~path
                      ~decode:Wire_knowledge.decode_keeper_memory_activity;
                }
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_keeper_memory_health ->
            let reply =
              Msg.Reply_keeper_memory_health
                (fetch_and_decode_get t ~path
                   ~decode:Wire_knowledge.decode_keeper_memory_health_fleet)
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_provider_usage _ ->
            let reply =
              Msg.Reply_provider_usage_history
                (fetch_and_decode_get t ~path
                   ~decode:Wire_runtime.decode_provider_usage_history)
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_keeper_costs _ ->
            let reply =
              Msg.Reply_keeper_costs
                (fetch_and_decode_get t ~path
                   ~decode:(Wire_runtime.decode_keeper_costs_window ~observed_at))
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_efficiency _ ->
            let reply =
              Msg.Reply_efficiency
                (fetch_and_decode_get t ~path
                   ~decode:(Wire_runtime.decode_efficiency_month ~observed_at))
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_models_metrics _ ->
            let reply =
              Msg.Reply_models_metrics
                (fetch_and_decode_get t ~path
                   ~decode:(Wire_runtime.decode_models_metrics ~observed_at))
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_runtime_metrics ->
            let reply =
              Msg.Reply_runtime_metrics
                (fetch_and_decode_get t ~path
                   ~decode:(Wire_runtime.decode_runtime_metrics ~observed_at))
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_runtime_resolved ->
            let reply =
              Msg.Reply_runtime_resolved
                (fetch_and_decode_get t ~path
                   ~decode:Wire_runtime.decode_runtime_resolved)
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_runtime_config_raw ->
            let reply =
              Msg.Reply_runtime_config_raw
                (fetch_and_decode_get t ~path
                   ~decode:Wire_runtime.decode_runtime_config_raw_meta)
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_setup_inventory ->
            let reply =
              Msg.Reply_setup_inventory
                (fetch_and_decode_get t ~path
                   ~decode:Wire_runtime.decode_setup_inventory)
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_setup_login_status _ ->
            let reply =
              Msg.Reply_setup_login_receipt
                (fetch_and_decode_get t ~path
                   ~decode:Wire_runtime.decode_setup_login_receipt)
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_runtime_probe _ ->
            let reply =
              Msg.Reply_runtime_probe
                (fetch_and_decode_get t ~path
                   ~decode:Wire_runtime.decode_runtime_probe)
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_exact_lane_runs _ ->
            let reply =
              Msg.Reply_exact_lane_runs
                (fetch_and_decode_get t ~path
                   ~decode:Wire_runtime.decode_exact_lane_runs)
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_fusion_runs ->
            let reply =
              Msg.Reply_fusion_runs
                (fetch_and_decode_get t ~path
                   ~decode:Wire_runtime.decode_fusion_runs)
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_tool_series _ ->
            let reply =
              Msg.Reply_tool_series
                (fetch_and_decode_get t ~path
                   ~decode:Wire_runtime.decode_tool_series)
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_tools_catalog _ ->
            let reply =
              Msg.Reply_tools_catalog
                (fetch_and_decode_get t ~path
                   ~decode:(Wire_runtime.decode_tools_catalog ~observed_at))
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_connectors ->
            let reply =
              Msg.Reply_connectors
                (fetch_and_decode_get t ~path
                   ~decode:Wire_runtime.decode_connectors)
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_browser_lane ->
            let reply =
              Msg.Reply_browser_lane
                (fetch_and_decode_get t ~path
                   ~decode:Wire_runtime.decode_browser_lane)
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_mcp_clients ->
            let reply =
              Msg.Reply_mcp_clients
                (fetch_and_decode_get t ~path
                   ~decode:Wire_runtime.decode_mcp_clients)
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_sandboxes ->
            let reply =
              Msg.Reply_sandboxes
                (fetch_and_decode_get t ~path
                   ~decode:(Wire_infra.decode_sandboxes_snapshot ~observed_at))
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_keeper_sandbox _ ->
            let reply =
              Msg.Reply_keeper_sandbox
                (fetch_and_decode_get t ~path
                   ~decode:(Wire_infra.decode_keeper_sandbox ~observed_at))
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_repositories ->
            let reply =
              Msg.Reply_repositories
                (fetch_and_decode_get t ~path
                   ~decode:Wire_infra.decode_repositories)
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_file_changes { keeper; _ } ->
            let reply =
              Msg.Reply_file_changes
                {
                  keeper;
                  result =
                    fetch_and_decode_get t ~path
                      ~decode:(Wire_infra.decode_file_changes ~observed_at);
                }
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_system_logs _ ->
            let reply =
              Msg.Reply_system_logs
                (fetch_and_decode_get t ~path
                   ~decode:Wire_infra.decode_system_log_snapshot)
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_tui_preferences ->
            let reply =
              Msg.Reply_tui_preferences
                (fetch_and_decode_get t ~path
                   ~decode:Wire_config.decode_tui_preferences)
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_config_schema _ ->
            let res =
              fetch_and_decode_get t ~path
                ~decode:Wire_config.decode_config_schema_with_meta
            in
            let reply =
              match res with
              | Ok (schema, meta) ->
                  if meta <> [] then
                    Ui_bus.publish_snapshot t.bus
                      ~key:(Key_get (path ^ "#meta"))
                      (Msg.Http_reply
                         {
                           epoch;
                           reply =
                             Msg.Reply_config_schema_meta
                               { target = schema.target; meta };
                         });
                  Msg.Reply_config_schema (Ok schema)
              | Error err -> Msg.Reply_config_schema (Error err)
            in
            Msg.Http_reply { epoch; reply }
      in
      Ui_bus.publish_snapshot t.bus ~key:(Key_get path) msg)

let is_terminal_setup_login_status status =
  match String.lowercase_ascii (String.trim status) with
  | "complete" | "completed" | "failed" | "cancelled" | "interrupted" -> true
  | _ -> false

let run_setup_login_stream
    ~(publish :
       (Wire_runtime.setup_login_receipt, Msg.http_error) result -> unit)
    ~(stream : on_chunk:(string -> unit) -> (unit, Msg.http_error) result) :
    unit =
  let sse_decoder = Sse_wire.create_decoder () in
  let saw_receipt = ref false in
  let terminal_published = ref false in
  let on_chunk raw =
    let frames = Sse_wire.feed sse_decoder raw in
    List.iter
      (fun (frame : Sse_wire.frame) ->
        match Yojson.Safe.from_string frame.data with
        | json -> (
            match Wire_runtime.decode_setup_login_receipt json with
            | Ok receipt ->
                saw_receipt := true;
                if is_terminal_setup_login_status receipt.status then (
                  if not !terminal_published then (
                    terminal_published := true;
                    publish (Ok receipt)))
                else if not !terminal_published then publish (Ok receipt)
            | Error _ -> ())
        | exception Yojson.Json_error _ -> ())
      frames
  in
  let stream_res = stream ~on_chunk in
  match !terminal_published, !saw_receipt, stream_res with
  | true, _, _ -> ()
  | false, _, Error err -> publish (Error err)
  | false, true, Ok () -> ()
  | false, false, Ok () ->
      publish
        (Error
           (Msg.Decode_error
              "setup login stream closed without a login receipt"))

let execute_post t ~epoch req =
  let path = Cmd.post_request_path req in
  let body = Cmd.post_request_body req in
  fork_safe t (fun () ->
      let reply_opt =
        match req with
        | Cmd.Post_ask_answer { keeper; ask_id; _ } ->
            let result = post_ack t ~path ~body in
            Some
              (Msg.Reply_work_mutation
                 {
                   label = Say.make ~ko:"질문 응답 완료" ~en:"Ask answered";
                   attention_id = Some ("ask:" ^ ask_id);
                   decision_kind = Some Work_store.Decision_ask_answered;
                   target_id = Some ask_id;
                   keeper = Some keeper;
                   result;
                 })
        | Cmd.Post_tool_approval { keeper; approval_id; decision; _ } ->
            let result = post_ack t ~path ~body in
            let label, decision_kind =
              match decision with
              | Wire_work.Tool_approve ->
                  ( Say.make ~ko:"도구 호출 승인됨" ~en:"Tool call approved"
                  , Work_store.Decision_tool_approved )
              | Wire_work.Tool_deny ->
                  ( Say.make ~ko:"도구 호출 거절됨" ~en:"Tool call denied"
                  , Work_store.Decision_tool_denied )
            in
            Some
              (Msg.Reply_work_mutation
                 {
                   label;
                   attention_id = Some ("tool:" ^ approval_id);
                   decision_kind = Some decision_kind;
                   target_id = Some approval_id;
                   keeper = Some keeper;
                   result;
                 })
        | Cmd.Post_gate_resolution { id; approved; _ } ->
            let result = post_ack t ~path ~body in
            let label, decision_kind =
              if approved then
                ( Say.make ~ko:"게이트 승인됨" ~en:"Gate approved"
                , Work_store.Decision_gate_approved )
              else
                ( Say.make ~ko:"게이트 거절됨" ~en:"Gate rejected"
                , Work_store.Decision_gate_rejected )
            in
            Some
              (Msg.Reply_work_mutation
                 {
                   label;
                   attention_id = Some ("gate:" ^ id);
                   decision_kind = Some decision_kind;
                   target_id = Some id;
                   keeper = None;
                   result;
                 })
        | Cmd.Post_goal_transition _ ->
            let result = post_ack t ~path ~body in
            Some
              (Msg.Reply_action_ack
                 {
                   label = Say.make ~ko:"목표 상태 변경됨" ~en:"Goal transitioned";
                   result;
                 })
        | Cmd.Post_goal_confirmation confirm ->
            let result = post_ack t ~path ~body in
            Some
              (Msg.Reply_work_mutation
                 {
                   label = Say.make ~ko:"목표 완료 확정됨" ~en:"Goal confirmed";
                   attention_id = Some ("goal:" ^ confirm.goal_id);
                   decision_kind = Some Work_store.Decision_goal_confirmed;
                   target_id = Some confirm.goal_id;
                   keeper = None;
                   result;
                 })
        | Cmd.Post_verification_verdict { verification_id; verdict; _ } ->
            let result = post_ack t ~path ~body in
            let label, decision_kind =
              match verdict with
              | Wire_work.Verdict_approve ->
                  ( Say.make ~ko:"검증 승인됨" ~en:"Verification approved"
                  , Work_store.Decision_verification_approved )
              | Wire_work.Verdict_reject _ ->
                  ( Say.make ~ko:"검증 반려됨" ~en:"Verification rejected"
                  , Work_store.Decision_verification_rejected )
            in
            Some
              (Msg.Reply_work_mutation
                 {
                   label;
                   attention_id = None;
                   decision_kind = Some decision_kind;
                   target_id = Some verification_id;
                   keeper = None;
                   result;
                 })
        | Cmd.Post_quarantine_requeue { keeper; quarantine_id; _ } ->
            let result = post_ack t ~path ~body in
            Some
              (Msg.Reply_work_mutation
                 {
                   label =
                     Say.make ~ko:"격리 후보 재큐잉 완료" ~en:"Quarantine requeued";
                   attention_id = Some ("quarantine:" ^ quarantine_id);
                   decision_kind = None;
                   target_id = Some quarantine_id;
                   keeper = Some keeper;
                   result;
                 })
        | Cmd.Post_memory_act { keeper; _ } ->
            let ep = Atomic.get t.endpoint in
            let body_str = Yojson.Safe.to_string body in
            let result =
              match
                Http_client.post_raw ~io:t.io ~clock:t.clock
                  ~content_type:"application/json" ~body:body_str ep ~path
              with
              | Ok raw ->
                  decode_raw_json t
                    ~decode:
                      (Wire_knowledge.decode_memory_act_answer ~status_code:200)
                    raw
              | Error (Http_client.Http_error { status; body = err_body; _ } as err)
                -> (
                  match
                    decode_raw_json t
                      ~decode:
                        (Wire_knowledge.decode_memory_act_answer
                           ~status_code:status)
                      err_body
                  with
                  | Ok ans -> Ok ans
                  | Error _ -> Error (msg_error_of_http err))
              | Error
                  (( Http_client.Transport _
                   | Http_client.Workspace_mismatch _
                   | Http_client.Decode_error _ ) as err) ->
                  Error (msg_error_of_http err)
            in
            Some (Msg.Reply_memory_act { keeper; result })
        | Cmd.Post_fusion_launch _ ->
            let result = post_ack t ~path ~body in
            Some (Msg.Reply_fusion_launch result)
        | Cmd.Post_runtime_assignment { keeper_name; runtime_id; _ } ->
            let result = post_ack t ~path ~body in
            Some
              (Msg.Reply_runtime_assignment { keeper_name; runtime_id; result })
        | Cmd.Post_runtime_default_route { runtime_id } ->
            let result = post_ack t ~path ~body in
            Some (Msg.Reply_runtime_routing { runtime_id; result })
        | Cmd.Post_setup_account_key { integration_id; _ } ->
            let result = post_ack t ~path ~body in
            Some (Msg.Reply_setup_account_key { integration_id; result })
        | Cmd.Post_setup_login_start _ ->
            let ep = Atomic.get t.endpoint in
            let body_str = Yojson.Safe.to_string body in
            let publish res =
              Ui_bus.publish_stream t.bus
                (Msg.Http_reply
                   { epoch; reply = Msg.Reply_setup_login_receipt res })
            in
            run_setup_login_stream ~publish
              ~stream:(fun ~on_chunk ->
                Http_client.post_stream ~io:t.io ~clock:t.clock
                  ~content_type:"application/json" ~body:body_str
                  ~on_response:(fun ~status:_ ~headers:_ -> ())
                  ~on_chunk ep ~path
                |> Result.map_error msg_error_of_http);
            None
        | Cmd.Post_sandbox_probe _ ->
            let result = post_ack t ~path ~body in
            Some
              (Msg.Reply_action_ack
                 {
                   label =
                     Say.make ~ko:"샌드박스 프로브 요청됨"
                       ~en:"Sandbox probe requested";
                   result;
                 })
        | Cmd.Post_config_patch patch_req ->
            let result =
              post_and_decode t ~path ~body
                ~decode:Wire_config.decode_patch_response
            in
            Some
              (Msg.Reply_config_patch { dry_run = patch_req.dry_run; result })
        | Cmd.Post_tui_preference _ ->
            let result = post_ack t ~path ~body in
            Some
              (Msg.Reply_action_ack
                 {
                   label = Say.make ~ko:"TUI 설정 저장됨" ~en:"Preferences saved";
                   result;
                 })
        | Cmd.Post_keeper_turn_interrupt { keeper; _ } ->
            let result =
              post_and_decode t ~path ~body
                ~decode:Wire_fleet.decode_turn_interrupt_response
            in
            Some (Msg.Reply_turn_interrupt { keeper; result })
        | Cmd.Post_board_create _ ->
            let result = post_ack t ~path ~body in
            Some
              (Msg.Reply_action_ack
                 {
                   label = Say.make ~ko:"게시글 작성 완료" ~en:"Board post created";
                   result;
                 })
        | Cmd.Post_schedule_create _ ->
            let result = post_ack t ~path ~body in
            Some
              (Msg.Reply_action_ack
                 {
                   label = Say.make ~ko:"일정 생성 완료" ~en:"Schedule created";
                   result;
                 })
        | Cmd.Post_connector_create _ ->
            let result = post_ack t ~path ~body in
            Some
              (Msg.Reply_action_ack
                 {
                   label = Say.make ~ko:"커넥터 연결 완료" ~en:"Connector bound";
                   result;
                 })
        | Cmd.Post_repo_add _ ->
            let result = post_ack t ~path ~body in
            Some
              (Msg.Reply_action_ack
                 {
                   label = Say.make ~ko:"저장소 추가 완료" ~en:"Repository added";
                   result;
                 })
        | Cmd.Post_task_cancel _ ->
            let result = post_ack t ~path ~body in
            Some
              (Msg.Reply_action_ack
                 {
                   label = Say.make ~ko:"작업 취소 완료" ~en:"Task cancelled";
                   result;
                 })
        | Cmd.Post_harness_overrule _ ->
            let result = post_ack t ~path ~body in
            Some
              (Msg.Reply_action_ack
                 {
                   label =
                     Say.make ~ko:"하네스 판정 재지정 완료"
                       ~en:"Harness label updated";
                   result;
                 })
      in
      Option.iter
        (fun reply ->
          Ui_bus.publish_stream t.bus (Msg.Http_reply { epoch; reply }))
        reply_opt)

let execute_put t ~epoch req =
  let path = Cmd.put_request_path req in
  let body = Cmd.put_request_body req in
  fork_safe t (fun () ->
      match req with
      | Cmd.Put_wiki_page { page; _ } ->
          let ep = Atomic.get t.endpoint in
          let result =
            Http_client.put_json ~io:t.io ~clock:t.clock ep ~path ~body
              ~decode:Wire_knowledge.decode_wiki_page_detail
            |> Result.map_error msg_error_of_http
          in
          Ui_bus.publish_stream t.bus
            (Msg.Http_reply { epoch; reply = Msg.Reply_wiki_put { page; result } }))

let execute_post_stream t ~epoch req =
  match req with
  | Cmd.Stream_keeper_chat { request; is_btw } ->
      fork_safe t (fun () ->
          let ep = Atomic.get t.endpoint in
          let body =
            Wire_fleet.encode_chat_submit_request request
            |> Yojson.Safe.to_string
          in
          let sse_decoder = Sse_wire.create_decoder () in
          let on_response ~status:_ ~headers:_ = () in
          let on_chunk raw =
            let frames = Sse_wire.feed sse_decoder raw in
            List.iter
              (fun (frame : Sse_wire.frame) ->
                match Yojson.Safe.from_string frame.data with
                | json -> (
                    match Wire_fleet.decode_chat_stream_chunk json with
                    | Ok Wire_fleet.Chunk_ignored -> ()
                    | Ok
                        (( Wire_fleet.Chunk_accepted _
                         | Wire_fleet.Chunk_run_started _
                         | Wire_fleet.Chunk_text_delta _
                         | Wire_fleet.Chunk_thinking_delta _
                         | Wire_fleet.Chunk_thinking_snapshot _
                         | Wire_fleet.Chunk_tool_start _
                         | Wire_fleet.Chunk_tool_args _
                         | Wire_fleet.Chunk_tool_end _
                         | Wire_fleet.Chunk_reply_details _
                         | Wire_fleet.Chunk_turn_done _
                         | Wire_fleet.Chunk_error _ ) as chunk) ->
                        Ui_bus.publish_stream t.bus
                          (Msg.Chat_stream_chunk
                             {
                               epoch;
                               keeper = request.keeper_name;
                               request_id = request.request_id;
                               is_btw;
                               chunk;
                             })
                    | Error reason ->
                        Ui_bus.publish_stream t.bus
                          (Msg.Chat_stream_decode_warning
                             {
                               epoch;
                               keeper = request.keeper_name;
                               request_id = request.request_id;
                               reason;
                             }))
                | exception Yojson.Json_error msg ->
                    Ui_bus.publish_stream t.bus
                      (Msg.Chat_stream_decode_warning
                         {
                           epoch;
                           keeper = request.keeper_name;
                           request_id = request.request_id;
                           reason = "invalid JSON SSE frame: " ^ msg;
                         }))
              frames
          in
          let result =
            Http_client.post_stream ~io:t.io ~clock:t.clock
              ~content_type:"application/json" ~body ~on_response ~on_chunk ep
              ~path:Wire_fleet.keeper_chat_stream_path
            |> Result.map_error msg_error_of_http
          in
          Ui_bus.publish_stream t.bus
            (Msg.Chat_stream_done
               {
                 epoch;
                 keeper = request.keeper_name;
                 request_id = request.request_id;
                 is_btw;
                 result;
               }))

let voice_cmd_of_store = function
  | Cmd.Start_ptt { device } -> Voice_runner.Start_ptt { device }
  | Cmd.Stop_ptt -> Voice_runner.Stop_ptt
  | Cmd.Cancel_ptt -> Voice_runner.Cancel_ptt
  | Cmd.Speak { text; voice_id } -> Voice_runner.Speak { text; voice_id }
  | Cmd.Probe_capabilities -> Voice_runner.Probe_capabilities

let rec wait_reap_pid pid =
  match Unix.waitpid [] pid with
  | _, Unix.WEXITED 0 -> Ok ()
  | _, Unix.WEXITED code ->
      Error (Printf.sprintf "url opener exited with status %d" code)
  | _, (Unix.WSIGNALED sig_num | Unix.WSTOPPED sig_num) ->
      Error (Printf.sprintf "url opener stopped by signal %d" sig_num)
  | exception Unix.Unix_error (Unix.EINTR, _, _) -> wait_reap_pid pid
  | exception Unix.Unix_error (Unix.ECHILD, _, _) -> Ok ()
  | exception Unix.Unix_error (err, fn, _) ->
      Error (Printf.sprintf "%s: %s" fn (Unix.error_message err))

let open_url_sync url =
  let opener =
    match Executable_path.absolute_on_path "open" with
    | Some bin -> Some bin
    | None -> Executable_path.absolute_on_path "xdg-open"
  in
  match opener with
  | None -> Error "neither 'open' nor 'xdg-open' found on PATH"
  | Some bin -> (
      match Unix.openfile "/dev/null" [ Unix.O_RDWR ] 0 with
      | devnull ->
          Fun.protect
            ~finally:(fun () ->
              try Unix.close devnull with Unix.Unix_error _ -> ())
            (fun () ->
              match
                Unix.create_process bin [| bin; url |] devnull devnull devnull
              with
              | pid -> wait_reap_pid pid
              | exception Unix.Unix_error (err, fn, _) ->
                  Error (Printf.sprintf "%s: %s" fn (Unix.error_message err)))
      | exception Unix.Unix_error (err, fn, _) ->
          Error (Printf.sprintf "%s: %s" fn (Unix.error_message err)))

let read_file_or_empty path =
  match In_channel.open_bin path with
  | ic ->
      Fun.protect
        ~finally:(fun () -> In_channel.close_noerr ic)
        (fun () -> Ok (In_channel.input_all ic))
  | exception Sys_error _ -> Ok ""

let run_editor_roundtrip t ~suffix initial =
  t.editor_handoff.pause_terminal ();
  match
    Eio_unix.run_in_systhread (fun () ->
        Masc_cli_editor.roundtrip
          ~restore:(fun () -> ())
          ~reenter:(fun () -> ())
          ~suffix initial)
  with
  | res ->
      t.editor_handoff.resume_terminal ();
      res
  | exception (Eio.Cancel.Cancelled _ as ex) ->
      Eio.Cancel.protect t.editor_handoff.resume_terminal;
      raise ex
  | exception ex ->
      Eio.Cancel.protect t.editor_handoff.resume_terminal;
      Error (Masc_cli_editor.Form_unreadable (Printexc.to_string ex))

let can_edit_local_toml t =
  is_local_host t.cli.host || Option.is_some (Atomic.get t.owned_server)

let remote_editor_blocked_message =
  "Remote server attached: edit config via Settings (HTTP /api/v1/config/patch), local $EDITOR blocked"

let execute_editor_escape_hatch t target =
  let epoch = Atomic.get t.stream_epoch in
  let ko = Say.equal_lang t.cli.lang Say.Lang_ko in
  let emit_ack ~label result =
    Ui_bus.publish_stream t.bus
      (Msg.Http_reply { epoch; reply = Msg.Reply_action_ack { label; result } })
  in
  match target with
  | Cmd.Edit_runtime_toml | Cmd.Edit_keeper_toml _ ->
      if not (can_edit_local_toml t) then
        emit_ack
          ~label:
            (Say.make
               ~ko:"원격 서버 연결: 설정 화면(HTTP /api/v1/config/patch)에서 편집하세요 (로컬 $EDITOR 차단)"
               ~en:remote_editor_blocked_message)
          (Error
             (Msg.Transport (Health.Other_io remote_editor_blocked_message)))
      else (
        match editor_file_path ~base_path:t.cli.base_path target with
      | None -> ()
      | Some path -> (
          let initial =
            match read_file_or_empty path with Ok s -> s | Error _ -> ""
          in
          match run_editor_roundtrip t ~suffix:".toml" initial with
          | Error abort ->
              let detail = Masc_cli_editor.abort_detail ~ko abort in
              emit_ack
                ~label:(Say.make ~ko:"편집기 종료" ~en:"Editor aborted")
                (Error (Msg.Transport (Health.Other_io detail)))
          | Ok edited ->
              if String.equal edited initial then
                emit_ack
                  ~label:(Say.make ~ko:"변경 사항 없음" ~en:"No changes made")
                  (Ok ())
              else begin
                Fs_compat.mkdir_p (Filename.dirname path);
                match Fs_compat.save_file_atomic path edited with
                | Ok () ->
                    emit_ack
                      ~label:
                        (Say.make ~ko:"TOML 파일 저장 완료"
                           ~en:"Saved TOML file")
                      (Ok ());
                    let schema_target =
                      match target with
                      | Cmd.Edit_runtime_toml -> Wire_config.Target_runtime
                      | Cmd.Edit_keeper_toml name ->
                          Wire_config.Target_keeper name
                      | Cmd.Edit_wiki_page _ -> Wire_config.Target_runtime
                    in
                    execute_get t ~epoch (Cmd.Get_config_schema schema_target)
                | Error err ->
                    emit_ack
                      ~label:(Say.make ~ko:"TOML 저장 실패" ~en:"Save TOML")
                      (Error (Msg.Transport (Health.Other_io err)))
              end))
  | Cmd.Edit_wiki_page page -> (
      let path = Wire_knowledge.wiki_page_path ~page in
      match
        fetch_and_decode_get ~timeout_sec:3.0 t ~path
          ~decode:Wire_knowledge.decode_wiki_page_detail
      with
      | Error err ->
          emit_ack
            ~label:(Say.make ~ko:"위키 문서 불러오기" ~en:"Load wiki page")
            (Error err)
      | Ok detail -> (
          match run_editor_roundtrip t ~suffix:".md" detail.body_markdown with
          | Error abort ->
              let detail_str = Masc_cli_editor.abort_detail ~ko abort in
              emit_ack
                ~label:(Say.make ~ko:"편집기 종료" ~en:"Editor aborted")
                (Error (Msg.Transport (Health.Other_io detail_str)))
          | Ok edited ->
              if String.equal edited detail.body_markdown then
                emit_ack
                  ~label:(Say.make ~ko:"변경 사항 없음" ~en:"No changes made")
                  (Ok ())
              else
                let put_req : Wire_knowledge.wiki_put_request =
                  {
                    expected_revision = Some detail.frontmatter.revision;
                    expected_sha256 = Some detail.sha256;
                    title = detail.frontmatter.title;
                    summary = detail.frontmatter.summary;
                    source = detail.frontmatter.source;
                    tags = detail.frontmatter.tags;
                    body = edited;
                    note = "edited via $EDITOR";
                  }
                in
                execute_put t ~epoch
                  (Cmd.Put_wiki_page { page; request = put_req })))

let stop_owned_server_async owned =
  Eio.Cancel.protect (fun () ->
      Eio_unix.run_in_systhread (fun () ->
          Masc_server_lifecycle.stop owned ~grace_sec:5.0))

let execute_start_local_server t =
  if not t.cli.auto_start then
    Ui_bus.publish_stream t.bus
      (Msg.Server_start_result (Error "auto-start disabled (--no-auto-start)"))
  else
    fork_safe t (fun () ->
        let discovery =
          Eio_unix.run_in_systhread (fun () ->
              Masc_server_lifecycle.discover_server_binary
                ~tui_exe:Sys.executable_name
                ~file_exists:Executable_path.regular_file_is_executable
                ~path_lookup:Executable_path.absolute_on_path
                ~base_path:t.cli.base_path ~host:t.cli.host ~port:t.cli.port)
        in
        match discovery with
        | Masc_server_lifecycle.Not_found { manual_command } ->
            Ui_bus.publish_stream t.bus
              (Msg.Server_start_result
                 (Error
                    ("masc binary not found; start manually: " ^ manual_command)))
        | Masc_server_lifecycle.Sibling masc_bin
        | Masc_server_lifecycle.On_path masc_bin -> (
            let start_res =
              Eio_unix.run_in_systhread (fun () ->
                  Masc_server_lifecycle.start ~masc_bin
                    ~base_path:t.cli.base_path ~host:t.cli.host
                    ~port:t.cli.port ~env:(Unix.environment ()))
            in
            match start_res with
            | Error err ->
                Ui_bus.publish_stream t.bus (Msg.Server_start_result (Error err))
            | Ok owned -> (
                (match Atomic.exchange t.owned_server (Some owned) with
                | Some prev -> stop_owned_server_async prev
                | None -> ());
                let health_ok () =
                  let ep = Atomic.get t.endpoint in
                  match
                    Http_client.get_raw ~io:t.io ~clock:t.clock ~timeout_sec:1.0
                      ep ~path:Wire_common.health_path
                  with
                  | Ok body -> is_health_body_ready body
                  | Error _ -> false
                in
                let child_exit () =
                  Eio_unix.run_in_systhread (fun () ->
                      Masc_server_lifecycle.exit_report owned)
                in
                let sleep () = Eio.Time.sleep t.clock 0.25 in
                match
                  Masc_server_lifecycle.wait_healthy ~health_ok ~child_exit
                    ~attempts:40 ~sleep
                with
                | Masc_server_lifecycle.Ready ->
                    (* Reload admin.token whenever no explicit MASC_TOKEN or
                       bearer_token override was supplied so a freshly minted
                       token replaces any stale pre-boot file token. *)
                    if not t.explicit_bearer_override then begin
                      let fresh_tok =
                        Eio_unix.run_in_systhread (fun () ->
                            load_bearer_token ~base_path:t.cli.base_path ())
                      in
                      let cur = Atomic.get t.endpoint in
                      let next_ep = { cur with bearer_token = fresh_tok } in
                      Atomic.set t.endpoint next_ep;
                      Sse_hub.update_endpoint t.sse_hub next_ep
                    end;
                    Ui_bus.publish_stream t.bus (Msg.Server_start_result (Ok ()))
                | Masc_server_lifecycle.Server_exited report ->
                    ignore (Atomic.exchange t.owned_server None : _ option);
                    let detail =
                      Printf.sprintf "%s (%s; %s)" report.status
                        (Masc_server_lifecycle.describe_last_line
                           report.last_line)
                        (Masc_server_lifecycle.describe_output report.output)
                    in
                    Ui_bus.publish_stream t.bus
                      (Msg.Server_start_result (Error detail))
                | Masc_server_lifecycle.Timed_out attempts ->
                    (match Atomic.exchange t.owned_server None with
                    | Some srv -> stop_owned_server_async srv
                    | None -> stop_owned_server_async owned);
                    let detail =
                      Printf.sprintf "server not healthy after %d probes (%s)"
                        attempts
                        (Masc_server_lifecycle.describe_output
                           (Masc_server_lifecycle.startup_output owned))
                    in
                    Ui_bus.publish_stream t.bus
                      (Msg.Server_start_result (Error detail)))))

let rec execute t = function
  | Cmd.Batch cmds -> List.iter (execute t) cmds
  | Cmd.Http_get { epoch; req } -> execute_get t ~epoch req
  | Cmd.Http_post { epoch; req } -> execute_post t ~epoch req
  | Cmd.Http_put { epoch; req } -> execute_put t ~epoch req
  | Cmd.Http_post_stream { epoch; req } -> execute_post_stream t ~epoch req
  | Cmd.Sync_streams { epoch; streams } ->
      (* On epoch transitions, fence & stop previous streams while stream_epoch
         still names the old epoch so old-epoch cancellation callbacks cannot
         tag events with the new epoch. *)
      if not (Epoch.equal (Atomic.get t.stream_epoch) epoch) then
        ignore
          (Sse_hub.sync_streams t.sse_hub [] : (Sse_hub.sync_diff, string) result);
      Atomic.set t.stream_epoch epoch;
      let specs = List.map stream_spec_of_id streams in
      (match Sse_hub.sync_streams t.sse_hub specs with
      | Ok _ -> ()
      | Error msg ->
          Ui_bus.publish_stream t.bus
            (Msg.Http_reply
               {
                 epoch;
                 reply =
                   Msg.Reply_action_ack
                     {
                       label =
                         Say.make ~ko:"SSE 스트림 동기화" ~en:"SSE stream sync";
                       result = Error (Msg.Transport (Health.Protocol_error msg));
                     };
               }))
  | Cmd.Update_workspace_guard { instance_id; workspace_sha256 } ->
      update_workspace_guard t ~instance_id ~workspace_sha256
  | Cmd.Voice_cmd vc -> Voice_runner.dispatch t.voice_runner (voice_cmd_of_store vc)
  | Cmd.Copy_clipboard text ->
      fork_safe t (fun () ->
          let write_osc52 seq =
            Terminal_out.write seq;
            Terminal_out.flush ()
          in
          let _outcome =
            Eio_unix.run_in_systhread (fun () ->
                let session = Clipboard.copy_session Sys.getenv_opt in
                Clipboard.copy_text session ~write_osc52 text)
          in
          ())
  | Cmd.Open_external_url url ->
      if is_safe_external_url url then
        fork_safe t (fun () ->
            match Eio_unix.run_in_systhread (fun () -> open_url_sync url) with
            | Ok () -> ()
            | Error detail ->
                Ui_bus.publish_stream t.bus
                  (Msg.Http_reply
                     {
                       epoch = Atomic.get t.stream_epoch;
                       reply =
                         Msg.Reply_action_ack
                           {
                             label =
                               Say.make ~ko:"외부 링크 열기"
                                 ~en:"Open external URL";
                             result =
                               Error (Msg.Transport (Health.Other_io detail));
                           };
                     }))
  | Cmd.Open_editor_escape_hatch target -> execute_editor_escape_hatch t target
  | Cmd.Start_local_server -> execute_start_local_server t
  | Cmd.Restart_tui -> t.on_restart ()
  | Cmd.Quit reason -> t.on_quit reason

let execute_all t cmds = List.iter (execute t) (Cmd.flatten cmds)

let shutdown ?(preserve_owned_server = false) t =
  Atomic.set t.closed true;
  Voice_runner.stop t.voice_runner;
  Sse_hub.shutdown t.sse_hub;
  if not preserve_owned_server then
    match Atomic.exchange t.owned_server None with
    | Some owned -> stop_owned_server_async owned
    | None -> ()
