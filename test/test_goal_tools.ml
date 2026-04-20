(** Goal tool coverage — shared Goal Store surface through Tool_coord. *)

open Alcotest
open Masc_mcp

let temp_dir () =
  let path = Filename.temp_file "goal_tool_test" "" in
  Sys.remove path;
  Unix.mkdir path 0o755;
  path

let rm_rf dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then begin
        Sys.readdir path
        |> Array.iter (fun entry -> rm (Filename.concat path entry));
        Unix.rmdir path
      end else
        Sys.remove path
  in
  try rm dir with _ -> ()

let with_room f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = temp_dir () in
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () ->
    let config = Coord.default_config dir in
    ignore (Coord.init config ~agent_name:(Some "planner"));
    f config)

let coord_ctx config : Tool_coord.context =
  { Tool_coord.config; agent_name = "planner" }

let parse_json_result = function
  | true, body -> Yojson.Safe.from_string body
  | false, body -> fail body

let test_goal_upsert_and_list () =
  with_room @@ fun config ->
  let created =
    Tool_coord.dispatch (coord_ctx config) ~name:"masc_goal_upsert"
      ~args:
        (`Assoc
          [
            ("title", `String "Ship Goal Surface");
            ("horizon", `String "mid");
            ("priority", `Int 2);
          ])
  in
  let created_json =
    match created with
    | Some result -> parse_json_result result
    | None -> fail "masc_goal_upsert not handled"
  in
  let goal_id =
    match Yojson.Safe.Util.member "goal_id" created_json with
    | `String id when id <> "" -> id
    | _ -> fail "goal_id missing from upsert response"
  in
  let task_marker =
    match Yojson.Safe.Util.member "task_title_marker" created_json with
    | `String marker -> marker
    | _ -> fail "task_title_marker missing from upsert response"
  in
  check bool "task marker embeds goal id" true
    (String.equal task_marker (Printf.sprintf "[goal:%s]" goal_id));
  let listed =
    Tool_coord.dispatch (coord_ctx config) ~name:"masc_goal_list"
      ~args:(`Assoc [ ("horizon", `String "mid") ])
  in
  let listed_json =
    match listed with
    | Some result -> parse_json_result result
    | None -> fail "masc_goal_list not handled"
  in
  let count =
    match Yojson.Safe.Util.member "count" listed_json with
    | `Int n -> n
    | _ -> fail "count missing from goal list response"
  in
  check int "one listed goal" 1 count

let test_goal_review_updates_status () =
  with_room @@ fun config ->
  let goal, _kind =
    match Goal_store.upsert_goal config ~title:"Review me" () with
    | Ok payload -> payload
    | Error msg -> fail msg
  in
  let reviewed =
    Tool_coord.dispatch (coord_ctx config) ~name:"masc_goal_review"
      ~args:
        (`Assoc
          [
            ("goal_id", `String goal.id);
            ("outcome", `String "done");
            ("note", `String "completed from test");
          ])
  in
  let reviewed_json =
    match reviewed with
    | Some result -> parse_json_result result
    | None -> fail "masc_goal_review not handled"
  in
  let goal_json = Yojson.Safe.Util.member "goal" reviewed_json in
  let status =
    match Yojson.Safe.Util.member "status" goal_json with
    | `String s -> s
    | _ -> fail "status missing from goal review response"
  in
  check string "status updated to done" "done" status

let () =
  run "goal_tools"
    [
      ( "tool_coord",
        [
          test_case "upsert and list" `Quick test_goal_upsert_and_list;
          test_case "review updates status" `Quick test_goal_review_updates_status;
        ] );
    ]
