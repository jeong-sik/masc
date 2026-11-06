(** Real local H1 transport, public-read admission and Fusion decoders around
    a controlled SSE frame. The UI executable's mailbox is not run here. *)
open Alcotest
module Http = Masc.Http_server_eio
module Types = Masc_tui_types
module Updates = Masc_tui_fusion_updates
module Read = Masc_tui_workspace_read
module Loader = Masc_tui_loader
module Observer = Masc_tui_observer

let () = Masc.Server_startup_state.mark_state_ready () |> Result.get_ok

let rec remove_tree path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR ->
      Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path
  | Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK ->
      Unix.unlink path

let identity base : Masc.Tui_decode.server_identity =
  let canonical path = Masc.Tui_decode.Canonical_path.of_path (Unix.realpath path) in
  { sid_version = "test"; sid_binary_commit = "test"; sid_binary_commit_age_s = None
  ; sid_runtime_instance_id = None
  ; sid_base_path = canonical base; sid_masc_root = canonical (Filename.concat base ".masc")
  ; sid_executable_in_worktree = None; sid_state_ready = Some true; sid_uptime = None
  ; sid_sse_clients = None; sid_gc = None; sid_scheduler = None; sid_operator_action = None }

let run_json =
  `Assoc [ "run_id", `String "a"; "keeper", `String "analyst"; "preset", `String "trio"
         ; "topology", `String "simple"; "started_at", `Float 1.; "finished_at", `Null
         ; "status", `String "running"; "stage", `String "accepted"; "progress", `Assoc [] ]

let list_json =
  `Assoc [ "generated_at", `String "fixture"; "count", `Int 1; "runs", `List [ run_json ]
         ; "replay", `Assoc [ "status", `String "not_replayed" ]
         ; "historical_evidence", `List [] ]

let detail_json =
  `Assoc [ "generated_at", `String "fixture"; "run", run_json
         ; "evidence", `Assoc [ "status", `String "pending"; "post", `Null ] ]

let board_json =
  `Assoc [ "id", `String "post"; "author", `String "author"; "title", `String "evidence"
         ; "body", `String "original"; "meta", `Assoc []
         ; "origin", `Assoc [ "source", `String "fusion"; "fusion_run_id", `String "a" ] ]

let reference : Masc.Tui_decode_fusion.fusion_historical_evidence =
  { fhe_run_id = "a"; fhe_post_id = "post"; fhe_title = "evidence"; fhe_created_at = 1. }

let require = function Some x -> x | None -> fail "expected a new request"
let ok = function Ok x -> x | Error detail -> fail detail

let with_fixture run =
  let base_a = Filename.temp_dir "fusion-bound-a-" "" in
  let base_b = Filename.temp_dir "fusion-bound-b-" "" in
  let previous_server = Server_auth.For_testing.snapshot_server_state () in
  Fun.protect ~finally:(fun () ->
    Server_auth.For_testing.restore_server_state previous_server;
    remove_tree base_a;
    remove_tree base_b) (fun () ->
    Masc_test_deps.with_process_env "MASC_HTTP_BASE_URL" None @@ fun () ->
    Masc_test_deps.with_process_env "MASC_HTTP_AUTH_STRICT" None @@ fun () ->
    Masc_test_deps.with_process_env Masc_tui_credential.token_env_var None @@ fun () ->
    Eio_main.run @@ fun env ->
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    Eio.Switch.run @@ fun io_sw ->
    Masc_tui_http.start_io_domain ~sw:io_sw ~env;
    Eio.Switch.run @@ fun sw ->
    Eio_context.with_test_env ~net:(Eio.Stdenv.net env) ~clock:(Eio.Stdenv.clock env)
      ~mono_clock:(Eio.Stdenv.mono_clock env) ~sw (fun () ->
      let server_a = Masc.Mcp_server.For_testing.create_state ~base_path:base_a in
      let server_b = Masc.Mcp_server.For_testing.create_state ~base_path:base_b in
      ignore (Masc.Workspace.init (Masc.Mcp_server.workspace_config server_a) ~agent_name:None);
      ignore (Masc.Workspace.init (Masc.Mcp_server.workspace_config server_b) ~agent_name:None);
      Server_auth.For_testing.restore_server_state (Some server_a);
      let lists = ref 0 and details = ref 0 and boards = ref 0 in
      let respond counter json _state request reqd =
        incr counter;
        Http.Response.json_value ~request json reqd in
      let router = Http.Router.create ()
        |> Server_route.get Server_route.Public_read "/api/v1/dashboard/fusion-runs" (respond lists list_json)
        |> Server_route.prefix_get Server_route.Public_read "/api/v1/dashboard/fusion-runs/" (respond details detail_json)
        |> Server_route.prefix_get Server_route.Public_read "/api/v1/board/" (respond boards board_json) in
      let socket = Eio.Net.listen (Eio.Stdenv.net env) ~sw ~backlog:8 ~reuse_addr:true
          (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0)) in
      let port = match Eio.Net.listening_addr socket with
        | `Tcp (_, port) -> port | `Unix _ -> fail "expected loopback TCP" in
      let authority = match Server_request_authority.of_host_port ~host:"127.0.0.1" ~port with
        | Ok authority -> authority | Error `Malformed -> fail "invalid fixture authority" in
      let connections = ref [] in
      Eio.Fiber.fork_daemon ~sw (fun () ->
        while true do
          let flow, client = Eio.Net.accept ~sw socket in
          connections := flow :: !connections;
          Eio.Fiber.fork_daemon ~sw (fun () ->
            Eio.Switch.run (fun conn_sw ->
              let handler = Httpun_eio.Server.create_connection_handler ~sw:conn_sw
                ~request_handler:(fun _ (incoming : Httpun.Reqd.t Gluten.Reqd.t) ->
                  let reqd = incoming.Gluten.Reqd.reqd in
                  let request = Httpun.Reqd.request reqd in
                  Server_request_authority.with_current authority (fun () ->
                    Http.Router.dispatch router request reqd))
                ~error_handler:(fun _ ?request:_ _error respond ->
                  let body = respond (Httpun.Headers.of_list []) in
                  Httpun.Body.Writer.close body) in
              handler client flow);
            `Stop_daemon)
        done;
        `Stop_daemon);
      Masc_http_client.with_scoped_pool ~sw ~env @@ fun () ->
      Fun.protect ~finally:(fun () -> List.iter Eio.Flow.close !connections) (fun () ->
        Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 10.0 (fun () ->
          run ~server_a ~server_b ~base_a ~port ~lists ~details ~boards))))

let test_bound_transport_and_delayed_delivery () =
  with_fixture (fun ~server_a ~server_b ~base_a ~port ~lists ~details ~boards ->
    let host = "127.0.0.1" and expected = identity base_a in
    let bound expected read = Read.with_binding ~host ~port ~expected
        ~proof:Read.Request_precondition read in
    let list expected = bound expected (fun () -> Loader.load_fusion_runs ~host ~port) in
    let detail expected = bound expected (fun () -> Loader.load_fusion_detail ~host ~port ~run_id:"a") in
    let board expected = bound expected (fun () -> Loader.load_fusion_historical_detail ~host ~port ~reference) in
    let state = Types.create_state ~workspace:base_a ~port () in
    state.view <- Types.Fusion;
    state.server_identity <- Some expected;
    state.workspace_identity <- Types.Workspace_identity_match;
    let first = require (Updates.begin_runs state ~demand:Share) in
    let delayed = list expected |> ok in
    let parser = Observer.create () in
    let frames = Observer.feed parser
      "id: 1\ndata: {\"type\":\"fusion_run_status\",\"run\":{\"run_id\":\"a\",\"keeper\":\"analyst\",\"status\":\"running\"}}\n\n" in
    let changes = List.fold_left (fun changed (delivery : Observer.delivery) ->
      match delivery.decoded with
      | Observer.Event (Observer.Fusion_run_status { run_id; _ }) ->
          Updates.note_run_changed ~open_run_id:None changed ~run_id
      | Observer.Event _ | Observer.Undecodable _ -> changed)
        Updates.no_changed_runs frames in
    check bool "real SSE frame names a Fusion change" true changes.any;
    if changes.any then ignore (Updates.begin_runs state ~demand:After_change);
    check bool "delayed HTTP completion requests exactly one follow-up" true
      (Updates.runs_loaded state first (Ok delayed) = Updates.Reread);
    let next = require (Updates.begin_runs state ~demand:Share) in
    check bool "bound follow-up settles" true
      (Updates.runs_loaded state next (list expected) = Updates.Applied);
    check int "one initial GET and one follow-up GET" 2 !lists;
    ignore (detail expected |> ok);
    ignore (board expected |> ok);
    check (pair int int) "bound detail and Board original reached their routes" (1, 1) (!details, !boards);
    let old_a = require (Updates.begin_runs state ~demand:Share) in
    let delayed_a = list expected |> ok in
    Server_auth.For_testing.restore_server_state (Some server_b);
    let before = !lists, !details, !boards in
    List.iter (fun result -> check bool "foreign workspace refuses old expected roots" true (Result.is_error result))
      [ Result.map (fun _ -> ()) (list expected)
      ; Result.map (fun _ -> ()) (detail expected)
      ; Result.map (fun _ -> ()) (board expected) ];
    check (triple int int int) "foreign requests never reached projection handlers" before (!lists, !details, !boards);
    Types.withdraw_fusion_workspace state;
    let base_b = (Masc.Mcp_server.workspace_config server_b).base_path in
    let expected_b = identity base_b in
    state.server_identity <- Some expected_b;
    let old_b = require (Updates.begin_runs state ~demand:Share) in
    let delayed_b = list expected_b |> ok in
    Types.withdraw_fusion_workspace state;
    Server_auth.For_testing.restore_server_state (Some server_a);
    state.server_identity <- Some expected;
    let current_a = require (Updates.begin_runs state ~demand:Share) in
    check bool "delayed A response stays obsolete after observed A to B to A" true
      (Updates.runs_loaded state old_a (Ok delayed_a) = Updates.Obsolete);
    check bool "delayed B response stays obsolete after return to A" true
      (Updates.runs_loaded state old_b (Ok delayed_b) = Updates.Obsolete);
    check bool "new A response settles" true
      (Updates.runs_loaded state current_a (list expected) = Updates.Applied);
    let config = Masc.Mcp_server.workspace_config server_a in
    let nested = Filename.concat base_a "nested" in
    Unix.mkdir nested 0o700;
    (match Masc.Mcp_server.set_workspace_config server_a { config with workspace_path = nested } with
     | Ok () -> () | Error error -> fail (Masc.Mcp_server.workspace_switch_error_to_string error));
    check bool "same base and root do not distinguish a changed workspace scope" true
      (Result.is_ok (list expected)))

let test_missing_receipts_refused () =
  with_fixture (fun ~server_a:_ ~server_b:_ ~base_a ~port ~lists:_ ~details:_ ~boards:_ ->
    let host = "127.0.0.1" and expected = identity base_a in
    let cache = Masc_tui_kept_reads.create () in
    let receipt = Masc.Workspace.read_precondition_admission_header in
    let send_response = ref { Masc_http_client.status = 200
      ; headers = [ receipt; "etag", "\"same\"" ]; body = Yojson.Safe.to_string list_json } in
    let read () = Read.with_binding ~host ~port ~expected ~proof:Read.Request_precondition (fun () ->
      Read.read_json ~kept_reads:cache ~address_of:(fun ~path -> path)
        ~send:(fun ~path:_ ~headers:_ -> Ok !send_response)
        ~decode:(fun ~allow_empty ~status_code ~body ->
          Masc.Tui_decode.decode_json_response_body ~allow_empty ~status_code ~body)
        ~host ~port ~path:"/api/v1/dashboard/fusion-runs") in
    ignore (read () |> ok);
    send_response := { status = 304; headers = []; body = "" };
    check bool "unattested 304 cannot reuse the cached A payload" true (Result.is_error (read ()));
    send_response := { status = 200; headers = []; body = Yojson.Safe.to_string list_json };
    check bool "unattested 200 cannot publish a payload" true (Result.is_error (read ())))

let () =
  run "tui_fusion_workspace"
    [ "transport",
      [ test_case "bound H1, SSE frame and delayed workspace changes" `Quick test_bound_transport_and_delayed_delivery
      ; test_case "missing admission receipts" `Quick test_missing_receipts_refused ] ]
