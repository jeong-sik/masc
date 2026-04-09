open Masc_mcp

let find_assoc key = function
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None

let string_field key json =
  match find_assoc key json with
  | Some (`String value) -> Some value
  | _ -> None

let list_field key json =
  match find_assoc key json with
  | Some (`List rows) -> rows
  | _ -> []

let find_list_row_by_id rows id =
  List.find_opt
    (fun row ->
      match string_field "id" row with
      | Some value -> String.equal value id
      | None -> false)
    rows

let test_help_includes_attached_session_and_templates () =
  let json = Server_command_plane_http.command_plane_help_http_json () in
  let docs = list_field "docs" json in
  let doc_paths =
    docs |> List.filter_map (fun row -> string_field "path" row)
  in
  Alcotest.(check bool) "llms.txt listed" true
    (List.mem "llms.txt" doc_paths);
  Alcotest.(check bool) "llms-full.txt listed" true
    (List.mem "llms-full.txt" doc_paths);
  let golden_paths = list_field "golden_paths" json in
  let path_ids =
    golden_paths |> List.filter_map (fun row -> string_field "id" row)
  in
  Alcotest.(check bool) "attached team session path present" true
    (List.mem "attached_team_session" path_ids);
  let supervisor_path =
    match find_list_row_by_id golden_paths "supervisor_session" with
    | Some row -> row
    | None -> Alcotest.fail "supervisor_session path missing"
  in
  let attached_path =
    match find_list_row_by_id golden_paths "attached_team_session" with
    | Some row -> row
    | None -> Alcotest.fail "attached_team_session path missing"
  in
  Alcotest.(check (option string)) "supervisor path title"
    (Some "Supervisor / Session Runtime")
    (string_field "title" supervisor_path);
  Alcotest.(check (option string)) "attached path title"
    (Some "Attached Execution Session")
    (string_field "title" attached_path);
  let templates = list_field "workload_templates" json in
  let template_ids =
    templates |> List.filter_map (fun row -> string_field "id" row)
  in
  Alcotest.(check (list string)) "template ids"
    [ "coding_team"; "research_team"; "ops_governance_team" ]
    template_ids

let () =
  Alcotest.run "Command_plane_help"
    [
      ( "help",
        [
          Alcotest.test_case
            "includes attached session and workload templates"
            `Quick
            test_help_includes_attached_session_and_templates;
        ] );
    ]
