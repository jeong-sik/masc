open Masc
module Api = Server_dashboard_http_keeper_api
open Yojson.Safe.Util

let () = Server_startup_state.mark_state_ready () |> Result.get_ok

let rec remove_tree path =
  if Sys.file_exists path then
    if Sys.is_directory path then (
      Sys.readdir path
      |> Array.iter (fun name -> remove_tree (Filename.concat path name));
      Unix.rmdir path)
    else Sys.remove path

(* The chat-history route separates an unknown name (404) from an unreadable
   one (503). "editor" owns tool-call rows here, so give it retained metadata
   like a Keeper that exists but is offline. *)
let write_offline_meta config name =
  let meta = Masc_test_deps.meta_of_json_fixture
      (`Assoc [ "name", `String name; "trace_id", `String ("test-" ^ name) ])
      |> Result.get_ok in
  let path = Filename.concat (Workspace.keepers_runtime_dir config)
      (Keeper_runtime_root_entry.keeper_basename ~keeper_name:name Keeper_runtime_root_entry.Metadata) in
  Fs_compat.mkdir_p (Filename.dirname path);
  let oc = open_out path in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () ->
    output_string oc (Keeper_meta_json.meta_to_json meta |> Yojson.Safe.to_string))

let with_workspace f =
  Eio_main.run (fun env ->
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    Eio.Switch.run (fun sw ->
      let base = Filename.temp_file "keeper-tool-lookup" "" in
      Sys.remove base;
      Unix.mkdir base 0o700;
      let state = Mcp_server.For_testing.create_state ~base_path:base in
      let config = Mcp_server.workspace_config state in
      write_offline_meta config "editor";
      let location =
        Dated_jsonl.Store.(at (Workspace.dated_store_root config) Root.Tool_calls)
      in
      let ledger = Dated_jsonl.Store.dir location in
      let store = Dated_jsonl.open_store location in
      Eio.Switch.on_release sw (fun () ->
        Dated_jsonl.prepare_for_directory_removal store;
        Keeper_tool_call_index.forget_for_ledger ~ledger_dir:ledger;
        remove_tree base);
      f env sw state config store))

(* Content fixtures exercise the GET subroute; authorization cases pass the
   actual dashboard router to cross its token-bound permission middleware. *)
let get ?router ?token state target =
  let output = Buffer.create 1024 in
  let connection = Httpun.Server_connection.create (fun reqd ->
    let req = Httpun.Reqd.request reqd in
    match router with
    | Some router -> Http_server_eio.Router.dispatch router req reqd
    | None -> Api.handle_keeper_get_subroutes state req req reqd)
  in
  let authorization = match token with
    | None -> ""
    | Some token -> "Authorization: Bearer " ^ token ^ "\r\n" in
  let wire = "GET " ^ target ^ " HTTP/1.1\r\nHost: localhost\r\n" ^ authorization ^ "\r\n" in
  let input = Bigstringaf.of_string ~off:0 ~len:(String.length wire) wire in
  ignore (Httpun.Server_connection.read_eof connection input ~off:0
            ~len:(Bigstringaf.length input));
  let rec drain () =
    match Httpun.Server_connection.next_write_operation connection with
    | `Write iovecs ->
      let bytes = List.fold_left (fun total (iov : Bigstringaf.t Httpun.IOVec.t) ->
        Buffer.add_string output
          (Bigstringaf.substring iov.buffer ~off:iov.off ~len:iov.len);
        total + iov.len) 0 iovecs in
      Httpun.Server_connection.report_write_result connection (`Ok bytes);
      drain ()
    | `Yield | `Close _ -> ()
  in
  drain ();
  let wire = Buffer.contents output in
  let lines = String.split_on_char '\n' wire in
  let status = match lines with
    | first :: _ ->
      (match String.split_on_char ' ' first with
       | _ :: code :: _ -> int_of_string code
       | _ -> Alcotest.fail "invalid HTTP status line")
    | [] -> Alcotest.fail "missing HTTP response"
  in
  let rec body = function
    | "\r" :: rest -> String.concat "\n" rest
    | _ :: rest -> body rest
    | [] -> Alcotest.fail "missing HTTP header boundary"
  in
  status, Yojson.Safe.from_string (body lines)

let target keeper id =
  Uri.make ~path:("/api/v1/keepers/" ^ keeper ^ "/tool-calls")
    ~query:[ "execution_id", [ id ] ] () |> Uri.to_string

let row ~keeper ~execution_id ~ts ~output =
  let evidence =
    Keeper_file_change_evidence.edit_occurrence
      ~old_start_line:2 ~new_start_line:2 ~old_string:"before\n" ~new_string:"after\n"
    |> fun occurrence -> Keeper_file_change_evidence.edited [ occurrence ]
    |> Keeper_file_change_evidence.to_yojson
  in
  `Assoc
    [ "record_kind", `String "tool_call"; "wire_outcome", `String "ok"
    ; "duration_ms", `Float 3.
    ; "route_evidence", `Assoc [ "descriptor_id", `String "agent.edit_file" ]
    ; "keeper", `String keeper; "execution_id", `String execution_id
    ; "ts", `Float ts; "tool", `String "Edit"; "output", `String output
    ; "input", `Assoc [ "path", `String "story.md" ]
    ; "file_change_evidence", evidence
    ; "artifact_refs", `List [ `Assoc [ "_blob", `Assoc [ "sha256", `String (String.make 64 'a');
        "bytes", `Int 123; "mime", `String "application/octet-stream"; "preview", `String "" ] ] ]
    ]

let append store row = Dated_jsonl.append store row

let test_old_edit_and_peer_identity () =
  with_workspace (fun _env _sw state _config store ->
    let opaque = "old execution/+?&= 한글" in
    let original = row ~keeper:"editor" ~execution_id:opaque ~ts:1. ~output:"old edit output" in
    append store original;
    append store (row ~keeper:"peer" ~execution_id:opaque ~ts:2. ~output:"peer output");
    List.init 250 (fun i ->
      row ~keeper:"editor" ~execution_id:(Printf.sprintf "new-%d" i)
        ~ts:(float_of_int (i + 3)) ~output:"new output")
    |> List.iter (append store);
    let recent = match Keeper_tool_call_index.recent_rows ~store ~keeper_name:"editor" ~n:200 () with
      | Ok rows -> rows | Error e -> Alcotest.fail e in
    Alcotest.(check bool) "old edit is outside the recent window" false
      (List.exists (fun r -> r |> member "execution_id" = `String opaque) recent);
    let status, body = get state (target "editor" opaque) in
    Alcotest.(check int) "old exact execution HTTP status" 200 status;
    Alcotest.(check string) "response keeper" "editor" (body |> member "keeper" |> to_string);
    Alcotest.(check string) "opaque identity retained" opaque (body |> member "execution_id" |> to_string);
    let entry = body |> member "entry" in
    List.iter (fun key ->
      Alcotest.(check string) ("stored " ^ key ^ " retained")
        (Yojson.Safe.to_string (original |> member key))
        (Yojson.Safe.to_string (entry |> member key)))
      [ "keeper"; "execution_id"; "input"; "output"; "file_change_evidence"; "artifact_refs" ];
    let peer_status, peer = get state (target "peer" opaque) in
    Alcotest.(check int) "peer exact execution HTTP status" 200 peer_status;
    Alcotest.(check string) "peer row stays scoped" "peer output"
      (peer |> member "entry" |> member "output" |> to_string);
    let missing, _ = get state (target "absent" opaque) in
    Alcotest.(check int) "foreign keeper cannot select editor evidence" 404 missing;
    let unknown, _ = get state (target "editor" "unknown") in
    Alcotest.(check int) "unknown identity is absent" 404 unknown)

let test_ambiguity_and_invalid_query () =
  with_workspace (fun _env _sw state config store ->
    let stored = row ~keeper:"editor" ~execution_id:"duplicate" ~ts:1. ~output:"first" in
    append store stored;
    let status, _ = get state (target "editor" "duplicate") in
    Alcotest.(check int) "unique row initially served" 200 status;
    append store stored;
    let status, body = get state (target "editor" "duplicate") in
    Alcotest.(check int) "even identical canonical rows are ambiguous" 409 status;
    Alcotest.(check string) "ambiguity is explicit" "tool_call_ambiguous"
      (body |> member "code" |> to_string);
    List.iter (fun query ->
      let status, _ = get state ("/api/v1/keepers/editor/tool-calls?" ^ query) in
      Alcotest.(check int) query 400 status)
      [ "execution_id"; "execution_id="; "execution_id=%20%09"
      ; "execution_id=duplicate&execution_id=duplicate"
      ; "execution_id=&execution_id=duplicate" ];
    let req = Httpun.Request.create `GET "/api/v1/keepers/editor/tool-calls?limit=200" in
    Alcotest.(check bool) "absent identity leaves recent route in charge" true
      (Api.keeper_tool_call_lookup_response ~config ~keeper_name:"editor" req = None))

let test_store_failure_is_unavailable () =
  with_workspace (fun _env _sw state _config store ->
    let ledger = Dated_jsonl.base_dir store in
    let parent = Filename.dirname ledger in
    Fs_compat.mkdir_p parent;
    if Sys.file_exists ledger then Unix.rmdir ledger;
    let oc = open_out ledger in
    output_string oc "not a ledger directory";
    close_out oc;
    let status, body = get state (target "editor" "unknown") in
    Alcotest.(check int) "unreadable ledger is not an empty success" 503 status;
    Alcotest.(check string) "storage error is explicit" "tool_call_store_unavailable"
      (body |> member "code" |> to_string))

let test_raw_io_routes_require_admin () =
  with_workspace (fun env sw state config store ->
    Auth.save_auth_config config.base_path
      { Masc_domain.default_auth_config with enabled = true; require_token = true };
    let token agent_name role =
      match Auth.create_token config.base_path ~agent_name ~role with
      | Ok (raw, _) -> raw
      | Error error -> Alcotest.fail (Masc_domain.masc_error_to_string error) in
    let worker = token "lookup-worker" Masc_domain.Worker in
    let admin = token "lookup-admin" Masc_domain.Admin in
    let saved = Server_auth.For_testing.snapshot_server_state () in
    Eio.Switch.on_release sw (fun () -> Server_auth.For_testing.restore_server_state saved);
    Server_auth.publish_server_state state;
    let router = Server_routes_http_routes_dashboard.add_routes
      ~sw ~clock:(Eio.Stdenv.clock env) (Http_server_eio.Router.create ()) in
    let secret = "operator-only retained Read or Shell output" in
    (* Exact lookup opens the supplied ledger directly; the ordinary tail
       reads the startup-initialized log store. Point both at this fixture. *)
    Keeper_tool_call_log.init ~base_path:config.base_path ();
    Eio.Switch.on_release sw Keeper_tool_call_log.reset_for_testing;
    append store (row ~keeper:"editor" ~execution_id:"protected"
      ~ts:(Unix.gettimeofday ()) ~output:secret);
    List.iter (fun path ->
      let anonymous, _ = get ~router state path in
      let denied, denied_body = get ~router ~token:worker state path in
      let allowed, body = get ~router ~token:admin state path in
      Alcotest.(check int) "anonymous denied" 401 anonymous;
      Alcotest.(check int) "Worker denied" 403 denied;
      Alcotest.(check bool) "denied response withholds raw I/O" false
        (String_util.contains_substring (Yojson.Safe.to_string denied_body) secret);
      Alcotest.(check int) "Admin allowed" 200 allowed;
      Alcotest.(check bool) "Admin receives retained raw I/O" true
        (String_util.contains_substring (Yojson.Safe.to_string body) secret))
      [target "editor" "protected"; "/api/v1/keepers/editor/tool-calls?limit=200"];
    let trace_id="trace-protected-original" in
    let turn_ref=Ids.Turn_ref.make ~trace_id ~absolute_turn:1 in
    append store (`Assoc ["ts",`Float (Unix.gettimeofday ());
      "record_kind",`String "tool_call";"keeper",`String "editor";
      "agent_name",`String "editor";"execution_id",`String "protected-original";
      "trace_id",`String trace_id;"session_id",`String trace_id;
      "keeper_turn_id",`Int 1;"turn",`Int 0;"planned_index",`Int 0;
      "turn_kind",`String "direct";"tool",`String "Execute";
      "tool_use_id",`String "provider-original";
      "tool_observation",Tool_observation.to_yojson
        {attribution=Agent_observation.Pathless;turn_ref;declared_progress=None}]);
    let original_target expected_base = Uri.make
      ~path:"/api/v1/keepers/editor/tool-result"
      ~query:["execution_id",["protected-original"];
        "expected_base_path",[expected_base];
        "expected_masc_root",[Filename.concat expected_base Common.masc_dirname]] ()
      |> Uri.to_string in
    let original_path=original_target config.base_path in
    let anonymous,_=get ~router state original_path in
    let worker_status,_=get ~router ~token:worker state original_path in
    let admin_status,body=get ~router ~token:admin state original_path in
    Alcotest.(check int) "original source denies anonymous reads" 401 anonymous;
    Alcotest.(check int) "original source denies Worker reads" 403 worker_status;
    Alcotest.(check int) "workspace-bound Admin original read is accepted" 200 admin_status;
    (match Keeper_tool_result_page.of_json ~keeper:"editor"
        ~execution_id:"protected-original" body with
     | Ok Pending -> ()
     | Ok (Unavailable _ | Page _) | Error _ -> Alcotest.fail "unpublished original turn must remain pending");
    let wrong_status,wrong_body=get ~router ~token:admin state
        (original_target (Filename.concat config.base_path "different-workspace")) in
    Alcotest.(check int) "original read cannot cross workspace precondition" 409 wrong_status;
    Alcotest.(check string) "workspace conflict comes from common middleware"
      "workspace_precondition_failed" (wrong_body |> member "code" |> to_string);
    Alcotest.(check bool) "safe chat history does not acquire raw-record permission" true
      (Api.keeper_get_permission "/api/v1/keepers/editor/chat/history" = None);
    let safe_status, safe_body = get ~router ~token:worker state
      "/api/v1/keepers/editor/chat/history" in
    Alcotest.(check int) "Worker retains safe chat history access" 200 safe_status;
    Alcotest.(check bool) "safe history does not return raw ledger output" false
      (String_util.contains_substring (Yojson.Safe.to_string safe_body) secret))

(* How long the history request is given to answer while the only executor
   worker is busy. Encoded on the serving fiber it answers within a few
   milliseconds; encoded on the executor it cannot answer at all until the
   worker frees. *)
let busy_worker_polls = 100
let busy_worker_poll_interval_s = 0.01

(* The history body is large and polled, so its serialisation, validator and
   compression run on the CPU executor: with the only worker busy the response
   waits, and once the worker frees it is served. *)
let test_chat_history_body_is_encoded_on_the_cpu_executor () =
  with_workspace (fun env sw state _config _store ->
    let pool = Eio.Executor_pool.create ~sw ~domain_count:1 (Eio.Stdenv.domain_mgr env) in
    Executor_pool_ref.For_testing.with_pool pool (fun () ->
      let occupied, occupied_u = Eio.Promise.create () in
      let release, release_u = Eio.Promise.create () in
      Eio.Fiber.fork ~sw (fun () ->
        Executor_pool_ref.submit_or_inline (fun () ->
          Eio.Promise.resolve occupied_u ();
          Eio.Promise.await release));
      Eio.Promise.await occupied;
      let answered = ref None in
      let clock = Eio.Stdenv.clock env in
      Eio.Fiber.both
        (fun () -> answered := Some (get state "/api/v1/keepers/editor/chat/history"))
        (fun () ->
          let rec wait polls =
            if polls > 0 && Option.is_none !answered then (
              Eio.Time.sleep clock busy_worker_poll_interval_s;
              wait (polls - 1))
          in
          wait busy_worker_polls;
          Alcotest.(check bool) "the response waits for the busy worker" true
            (Option.is_none !answered);
          Eio.Promise.resolve release_u ());
      match !answered with
      | Some (status, _) -> Alcotest.(check int) "then it is served" 200 status
      | None -> Alcotest.fail "the history route never answered"))

let () =
  Alcotest.run "keeper_exact_tool_output_http"
    [ "GET /tool-calls?execution_id",
      [ Alcotest.test_case "old edit survives tail and peer traffic" `Quick test_old_edit_and_peer_identity
      ; Alcotest.test_case "ambiguity and invalid query are rejected" `Quick test_ambiguity_and_invalid_query
      ; Alcotest.test_case "storage failure remains unavailable" `Quick test_store_failure_is_unavailable
      ; Alcotest.test_case "raw I/O requires an Admin token" `Quick test_raw_io_routes_require_admin
      ; Alcotest.test_case "the chat history body is encoded on the CPU executor" `Quick
          test_chat_history_body_is_encoded_on_the_cpu_executor
      ] ]
