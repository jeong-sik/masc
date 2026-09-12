open Masc
module Api = Server_dashboard_http_keeper_api
open Yojson.Safe.Util

let rec remove_tree path =
  if Sys.file_exists path then
    if Sys.is_directory path then (
      Sys.readdir path
      |> Array.iter (fun name -> remove_tree (Filename.concat path name));
      Unix.rmdir path)
    else Sys.remove path

let with_workspace f =
  Eio_main.run (fun env ->
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    Eio.Switch.run (fun sw ->
      let base = Filename.temp_file "keeper-tool-lookup" "" in
      Sys.remove base;
      Unix.mkdir base 0o700;
      let state = Mcp_server.For_testing.create_state ~base_path:base in
      let config = Mcp_server.workspace_config state in
      let ledger = Filename.concat (Workspace.masc_root_dir config) "tool_calls" in
      let store = Dated_jsonl.create ~base_dir:ledger () in
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
    [ "record_kind", `String "tool_call"; "success", `Bool true
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
    Alcotest.(check bool) "safe chat history does not acquire raw-record permission" true
      (Api.keeper_get_permission "/api/v1/keepers/editor/chat/history" = None);
    let safe_status, safe_body = get ~router ~token:worker state
      "/api/v1/keepers/editor/chat/history" in
    Alcotest.(check int) "Worker retains safe chat history access" 200 safe_status;
    Alcotest.(check bool) "safe history does not return raw ledger output" false
      (String_util.contains_substring (Yojson.Safe.to_string safe_body) secret))

let () =
  Alcotest.run "keeper_exact_tool_output_http"
    [ "GET /tool-calls?execution_id",
      [ Alcotest.test_case "old edit survives tail and peer traffic" `Quick test_old_edit_and_peer_identity
      ; Alcotest.test_case "ambiguity and invalid query are rejected" `Quick test_ambiguity_and_invalid_query
      ; Alcotest.test_case "storage failure remains unavailable" `Quick test_store_failure_is_unavailable
      ; Alcotest.test_case "raw I/O requires an Admin token" `Quick test_raw_io_routes_require_admin
      ] ]
