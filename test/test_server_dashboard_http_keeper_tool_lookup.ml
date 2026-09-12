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
      f state config store))

(* Exercise the actual GET subroute and HTTP response writer. Authentication
   remains at its existing outer router boundary, not bypassed by a new route. *)
let get state target =
  let output = Buffer.create 1024 in
  let connection = Httpun.Server_connection.create (fun reqd ->
    let req = Httpun.Reqd.request reqd in
    Api.handle_keeper_get_subroutes state req req reqd)
  in
  let wire = "GET " ^ target ^ " HTTP/1.1\r\nHost: localhost\r\n\r\n" in
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
  with_workspace (fun state _config store ->
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
  with_workspace (fun state config store ->
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
  with_workspace (fun state _config store ->
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

let () =
  Alcotest.run "keeper_exact_tool_output_http"
    [ "GET /tool-calls?execution_id",
      [ Alcotest.test_case "old edit survives tail and peer traffic" `Quick test_old_edit_and_peer_identity
      ; Alcotest.test_case "ambiguity and invalid query are rejected" `Quick test_ambiguity_and_invalid_query
      ; Alcotest.test_case "storage failure remains unavailable" `Quick test_store_failure_is_unavailable
      ] ]
