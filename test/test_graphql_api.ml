(** GraphQL API tests (read-only queries). *)

module Graphql_api = Masc_mcp.Graphql_api
module Coord = Masc_mcp.Coord
module Coord_utils = Coord_utils

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
  let config = Coord_utils.default_config base_path in
  let _ = Coord.init config ~agent_name:None in
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
  let config = Coord_utils.default_config base_path in
  let _ = Coord.init config ~agent_name:None in
  let _ = Coord.add_task config ~title:"GraphQL task" ~priority:2 ~description:"test" in
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

let test_messages_temporal_decay_fields () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = temp_dir () in
  let config = Coord_utils.default_config base_path in
  let _ = Coord.init config ~agent_name:None in
  let _ =
    Coord.broadcast config ~from_agent:"operator" ~content:"hello @sangsu"
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

let () =
  let open Alcotest in
  run "Graphql_api"
    [
      ("status", [test_case "status query" `Quick test_status_query]);
      ("tasks", [test_case "tasks connection" `Quick test_tasks_connection]);
      ("messages", [test_case "temporal decay fields" `Quick test_messages_temporal_decay_fields]);
    ]
