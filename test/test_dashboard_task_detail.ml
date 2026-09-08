open Alcotest
module Detail = Server_dashboard_task_detail

let task id description =
  let json = `Assoc [
    "id", `String id; "title", `String "Complete task";
    "description", `String description; "priority", `Int 2;
    "status", `String "todo"; "files", `List [];
    "created_at", `String "2026-09-09T00:00:00Z";
    "contract", `Assoc ["strict", `Bool true;
      "completion_contract", `List [`String "Verify the visible result"];
      "required_evidence", `List [`String "artifact://proof"];
      "inspect_gate_evidence", `List []; "verify_gate_evidence", `List []]
  ] in
  match Masc_domain.task_of_yojson json with
  | Ok task -> task
  | Error detail -> fail detail

let test_complete_task () =
  let description = String.make 65536 'x' ^ " 마지막 검색어" in
  let selected = task "task-selected" description in
  let index = Hashtbl.create 1 in
  Hashtbl.add index selected.id ["goal-1"];
  let response = Detail.find ~tasks:[task "task-other" "other"; selected]
    ~goal_task_index:index ~task_id:" task-selected " in
  let status, body = Detail.response response in
  check bool "found" true (status = `OK);
  let open Yojson.Safe.Util in
  let row = member "task" body in
  check string "exact task selected" selected.id (row |> member "id" |> to_string);
  check string "full description including distant search text" description
    (row |> member "description" |> to_string);
  check string "goal linkage retained" "goal-1" (row |> member "goal_id" |> to_string);
  check string "completion criterion retained" "Verify the visible result"
    (row |> member "contract" |> member "completion_contract" |> to_list |> List.hd |> to_string);
  check string "required evidence retained" "artifact://proof"
    (row |> member "contract" |> member "required_evidence" |> to_list |> List.hd |> to_string)

let test_missing () =
  let index = Hashtbl.create 0 in
  let check_status id expected =
    let status, body = Detail.find ~tasks:[task "task-1" "body"]
      ~goal_task_index:index ~task_id:id |> Detail.response in
    check bool "distinct HTTP failure" true (status = expected);
    check bool "failure does not masquerade as task" false
      (match body with `Assoc fields -> List.mem_assoc "task" fields | _ -> false)
  in
  check_status " \t" `Bad_request;
  check_status "task-missing" `Not_found

let test_authoritative_storage () =
  let base_path = Filename.temp_dir "dashboard-task-detail-" "" in
  Fun.protect
    ~finally:(fun () -> Fs_compat.remove_tree base_path)
    (fun () ->
      let config = Masc.Workspace.default_config base_path in
      let check_read id expected =
        let status, body = Detail.read ~config ~task_id:(Some id) |> Detail.response in
        check bool "authoritative storage status" true (status = expected);
        if status = `Service_unavailable then
          check string "storage diagnostics stay private" "task detail unavailable"
            Yojson.Safe.Util.(body |> member "error" |> to_string)
      in
      let missing_status, _ = Detail.read ~config ~task_id:None |> Detail.response in
      check bool "absent query is bad request before storage access" true
        (missing_status = `Bad_request);
      check_read " \t" `Bad_request;
      check_read "task-selected" `Service_unavailable;
      ignore (Masc.Workspace.init config ~agent_name:(Some "task-detail-test"));
      let backlog = match Workspace_backlog.read_backlog_r config with
        | Ok backlog -> backlog
        | Error detail -> fail detail in
      Workspace_backlog.write_backlog config
        { backlog with tasks = [task "task-selected" "current body"] };
      check_read "task-selected" `OK;
      let corrupt path body =
        Out_channel.with_open_bin path (fun oc -> output_string oc body) in
      let links_path = Workspace_goal_index.goal_task_links_path config in
      corrupt links_path "{broken";
      check_read "task-selected" `Service_unavailable;
      Workspace_goal_index.write_goal_task_links config
        ["goal-1", ["task-selected"]];
      check_read "task-selected" `OK;
      (* A valid recovery registry must not hide failure of the current one. *)
      corrupt links_path "{broken";
      check_read "task-selected" `Service_unavailable;
      (* A missing task needs no goal registry read. *)
      check_read "task-missing" `Not_found;
      corrupt (Workspace_backlog.backlog_path config) "{broken";
      (* The writer retained a valid recovery snapshot, but it is not current. *)
      check_read "task-selected" `Service_unavailable;
      check_read "task-missing" `Service_unavailable)

let () = run "Dashboard task details" ["read", [
  test_case "complete selected task" `Quick test_complete_task;
  test_case "missing input and missing task" `Quick test_missing;
  test_case "authoritative storage failures" `Quick test_authoritative_storage]]
