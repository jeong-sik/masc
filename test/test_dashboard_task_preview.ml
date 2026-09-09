open Alcotest

let task description =
  match Masc_domain.task_of_yojson (`Assoc [
    "id", `String "task-preview"; "title", `String "Task";
    "description", `String description; "priority", `Int 2;
    "status", `String "todo"; "files", `List [];
    "created_at", `String "2026-09-09T00:00:00Z";
    "contract", `Assoc ["strict", `Bool true;
      "completion_contract", `List [`String "verify actual output"];
      "required_evidence", `List [`String "artifact://proof"];
      "inspect_gate_evidence", `List []; "verify_gate_evidence", `List []];
    "handoff_context", `Assoc ["summary", `String "retained handoff";
      "evidence_refs", `List [`String "artifact://handoff"]] ]) with
  | Ok value -> value | Error message -> fail message

let test_preview () =
  let index = Hashtbl.create 1 in
  Hashtbl.add index "task-preview" ["goal-preview"];
  let full t = Dashboard_execution.task_json ~goal_task_index:index t in
  let preview t = Dashboard_execution.task_list_json ~goal_task_index:index t in
  let field json name = Yojson.Safe.Util.(json |> member name |> to_string) in
  let description = String.make 159 'x' ^ "한글" ^ String.make 65536 'y' ^ " distant search" in
  let t = task description in
  check bool "fixture carries handoff evidence" true (Option.is_some t.handoff_context);
  check bool "fixture carries completion contract" true (Option.is_some t.contract);
  let row = preview t and complete = full t in
  check string "summary marker" "summary" (field row "detail_level");
  check string "does not split Korean character" (String.make 159 'x') (field row "description");
  check string "full detail retained" description (field complete "description");
  check string "exact full text revision"
    Digestif.SHA256.(digest_string description |> to_hex) (field row "description_revision");
  let retained = function
    | `Assoc fields -> `Assoc (List.filter (fun (key, _) ->
        not (List.mem key ["description"; "detail_level"; "description_revision"])) fields)
    | _ -> fail "object required" in
  check string "all contracts, evidence, identity and handoff remain intact"
    (Yojson.Safe.to_string (retained complete)) (Yojson.Safe.to_string (retained row));
  let full_bytes = String.length (Yojson.Safe.to_string complete) in
  let preview_bytes = String.length (Yojson.Safe.to_string row) in
  Printf.printf "Task description payload: full=%d preview=%d bytes\n%!" full_bytes preview_bytes;
  check bool "long description no longer dominates list bytes" true (preview_bytes < full_bytes / 2);
  List.iter (fun description ->
    let t = task description in
    check string "short and empty tasks stay complete"
      (Yojson.Safe.to_string (full t)) (Yojson.Safe.to_string (preview t)))
    [""; "짧은 설명"; String.make 160 'a'];
  let changed = preview (task (description ^ " changed tail")) in
  check string "same preview despite tail edit" (field row "description") (field changed "description");
  check bool "tail edit invalidates search text" false
    (String.equal (field row "description_revision") (field changed "description_revision"))

let () = run "Dashboard task previews"
  ["projection", [test_case "bounded preview with complete detail and metadata" `Quick test_preview]]
