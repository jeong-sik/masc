(** GraphQL API tests (read-only queries). *)

module Graphql_api = Masc.Graphql_api
module Workspace = Masc.Workspace
module Workspace_utils = Workspace_utils

let temp_dir () =
  let dir = Filename.temp_file "test_graphql_api_" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir

let cleanup_dir dir =
  let rec rm path =
    if Sys.is_directory path then begin
      Array.iter (fun name -> rm (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path
    end else
      Unix.unlink path
  in
  try rm dir with _ -> ()

let write_file path content =
  let ch = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr ch)
    (fun () -> output_string ch content)

let contains_substring ~needle haystack =
  let needle_len = String.length needle in
  let haystack_len = String.length haystack in
  let rec loop idx =
    if idx + needle_len > haystack_len then
      false
    else if String.equal (String.sub haystack idx needle_len) needle then
      true
    else
      loop (idx + 1)
  in
  String.equal needle "" || loop 0

let graphql_query config query =
  let body = Yojson.Safe.to_string (`Assoc [("query", `String query)]) in
  let response = Graphql_api.handle_request ~config body in
  (match response.status with
   | `OK -> ()
   | `Bad_request -> Alcotest.fail "GraphQL response status is bad_request");
  Yojson.Safe.from_string response.body

let test_status_query () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = temp_dir () in
  let config = Workspace_utils.default_config base_path in
  let _ = Workspace.init config ~agent_name:None in
  let json = graphql_query config "{ status { project paused } }" in
  let open Yojson.Safe.Util in
  let project = json |> member "data" |> member "status" |> member "project" |> to_string in
  let paused = json |> member "data" |> member "status" |> member "paused" |> to_bool in
  Alcotest.(check string) "project" (Filename.basename base_path) project;
  Alcotest.(check bool) "paused" false paused;
  cleanup_dir base_path

let test_tasks_connection () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = temp_dir () in
  let config = Workspace_utils.default_config base_path in
  let _ = Workspace.init config ~agent_name:None in
  let _ = Workspace.add_task config ~title:"GraphQL task" ~priority:2 ~description:"test" in
  let json =
    graphql_query config
      "{ tasks(first: 10) { totalCount edges { node { title } } } }"
  in
  let open Yojson.Safe.Util in
  let total = json |> member "data" |> member "tasks" |> member "totalCount" |> to_int in
  let edges = json |> member "data" |> member "tasks" |> member "edges" |> to_list in
  let title =
    match edges with
    | first :: _ -> first |> member "node" |> member "title" |> to_string
    | [] -> ""
  in
  Alcotest.(check int) "totalCount" 1 total;
  Alcotest.(check string) "title" "GraphQL task" title;
  cleanup_dir base_path

let test_tasks_connection_invalid_cursor_read_error () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = temp_dir () in
  let config = Workspace_utils.default_config base_path in
  let _ = Workspace.init config ~agent_name:None in
  let _ = Workspace.add_task config ~title:"GraphQL task" ~priority:2 ~description:"test" in
  let json =
    graphql_query config
      "{ tasks(first: 10, after: \"not_base64!!!\") { totalCount readErrors edges { node { title } } } }"
  in
  let open Yojson.Safe.Util in
  let total = json |> member "data" |> member "tasks" |> member "totalCount" |> to_int in
  let errors = json |> member "data" |> member "tasks" |> member "readErrors" |> to_list in
  let edges = json |> member "data" |> member "tasks" |> member "edges" |> to_list in
  Alcotest.(check int) "totalCount" 1 total;
  Alcotest.(check int) "readErrors" 1 (List.length errors);
  Alcotest.(check bool) "task cursor error is explicit" true
    (match errors with
     | [`String err] -> contains_substring ~needle:"invalid task cursor" err
     | _ -> false);
  Alcotest.(check int) "valid rows still returned" 1 (List.length edges);
  cleanup_dir base_path

let test_messages_temporal_decay_fields () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = temp_dir () in
  let config = Workspace_utils.default_config base_path in
  let _ = Workspace.init config ~agent_name:None in
  let _ =
    Workspace.broadcast config ~from_agent:"operator" ~content:"hello @sangsu"
  in
  let json =
    graphql_query config
      "{ messages(first: 10) { totalCount edges { node { from messageType content mention expiresAt relevance } } } }"
  in
  let open Yojson.Safe.Util in
  let total = json |> member "data" |> member "messages" |> member "totalCount" |> to_int in
  let edges = json |> member "data" |> member "messages" |> member "edges" |> to_list in
  let node =
    match edges with
    | first :: _ -> first |> member "node"
    | [] -> Alcotest.fail "missing message edge"
  in
  Alcotest.(check int) "totalCount" 1 total;
  Alcotest.(check string) "from" "operator" (node |> member "from" |> to_string);
  Alcotest.(check string) "messageType" "broadcast"
    (node |> member "messageType" |> to_string);
  Alcotest.(check string) "content" "hello @sangsu"
    (node |> member "content" |> to_string);
  Alcotest.(check string) "mention" "sangsu"
    (node |> member "mention" |> to_string);
  Alcotest.(check bool) "expiresAt null" true
    (node |> member "expiresAt" = `Null);
  Alcotest.(check string) "relevance" "medium"
    (node |> member "relevance" |> to_string);
  cleanup_dir base_path

let test_messages_connection_invalid_cursor_read_error () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = temp_dir () in
  let config = Workspace_utils.default_config base_path in
  let _ = Workspace.init config ~agent_name:None in
  let _ =
    Workspace.broadcast config ~from_agent:"operator" ~content:"hello @sangsu"
  in
  let bad_cursor = Graphql_api.encode_cursor ~kind:"message" "not-int" in
  let json =
    graphql_query config
      (Printf.sprintf
         "{ messages(first: 10, after: %S) { totalCount readErrors edges { node { content } } } }"
         bad_cursor)
  in
  let open Yojson.Safe.Util in
  let total = json |> member "data" |> member "messages" |> member "totalCount" |> to_int in
  let errors = json |> member "data" |> member "messages" |> member "readErrors" |> to_list in
  let edges = json |> member "data" |> member "messages" |> member "edges" |> to_list in
  Alcotest.(check int) "totalCount" 1 total;
  Alcotest.(check int) "readErrors" 1 (List.length errors);
  Alcotest.(check bool) "message cursor error is explicit" true
    (match errors with
     | [`String err] ->
         contains_substring ~needle:"decoded value must be an integer" err
     | _ -> false);
  Alcotest.(check int) "valid rows still returned" 1 (List.length edges);
  cleanup_dir base_path

let test_agents_connection_read_errors () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = temp_dir () in
  let config = Workspace_utils.default_config base_path in
  let _ = Workspace.init config ~agent_name:None in
  let agents_dir = Workspace_utils.agents_dir config in
  if not (Sys.file_exists agents_dir) then Unix.mkdir agents_dir 0o755;
  write_file (Filename.concat agents_dir "invalid-agent.json") "{";
  let json =
    graphql_query config
      "{ agents(first: 10) { totalCount readErrors edges { node { name } } } }"
  in
  let open Yojson.Safe.Util in
  let total = json |> member "data" |> member "agents" |> member "totalCount" |> to_int in
  let errors = json |> member "data" |> member "agents" |> member "readErrors" |> to_list in
  let edges = json |> member "data" |> member "agents" |> member "edges" |> to_list in
  Alcotest.(check int) "totalCount" 0 total;
  Alcotest.(check int) "readErrors" 1 (List.length errors);
  Alcotest.(check bool) "readError is explicit" true
    (match errors with
     | [`String err] -> String.trim err <> ""
     | _ -> false);
  Alcotest.(check int) "edges" 0 (List.length edges);
  cleanup_dir base_path

let () =
  let open Alcotest in
  run "Graphql_api"
    [
      ("status", [test_case "status query" `Quick test_status_query]);
      ( "tasks"
      , [ test_case "tasks connection" `Quick test_tasks_connection
        ; test_case
            "invalid cursor surfaces read error"
            `Quick
            test_tasks_connection_invalid_cursor_read_error
        ] );
      ( "messages"
      , [ test_case
            "temporal decay fields"
            `Quick
            test_messages_temporal_decay_fields
        ; test_case
            "invalid cursor surfaces read error"
            `Quick
            test_messages_connection_invalid_cursor_read_error
        ] );
      ("agents", [test_case "read errors are surfaced" `Quick test_agents_connection_read_errors]);
    ]
