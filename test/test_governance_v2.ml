open Alcotest

module GV2 = Council.Governance_v2

let base_path = "/tmp/masc-test-governance-v2"

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path
      |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path
    end else
      Unix.unlink path

let with_base f =
  Fun.protect
    ~finally:(fun () -> try rm_rf base_path with _ -> ())
    (fun () ->
      try rm_rf base_path with _ -> ();
      GV2.reset_legacy_storage base_path;
      f ())

let submit ~title ~subject_type ~requested_action ~source_refs ~created_by =
  GV2.submit_petition base_path
    ~title
    ~origin:created_by
    ~subject_type
    ~risk_class:GV2.High
    ~requested_action
    ~source_refs
    ~created_by

let set_param_request ~param_key ~value =
  Some
    {
      GV2.action_type = "set_param";
      target_type = Some "runtime_param";
      target_id = Some param_key;
      payload =
        Some
          (`Assoc
            [
              ("param_key", `String param_key);
              ("value", value);
            ]);
    }

let test_same_action_payload_merges_different_titles () =
  with_base @@ fun () ->
  let requested_action = set_param_request ~param_key:"db_timeout" ~value:(`Int 10) in
  let first =
    match
      submit
        ~title:"Increase DB timeout to 10 seconds"
        ~subject_type:"param_change"
        ~requested_action
        ~source_refs:[ "task-a" ]
        ~created_by:"agent-a"
    with
    | Ok value -> value
    | Error err -> fail err
  in
  let second =
    match
      submit
        ~title:"Increase PostgreSQL connection wait timeout to 10 seconds"
        ~subject_type:"param_change"
        ~requested_action
        ~source_refs:[ "task-b" ]
        ~created_by:"agent-b"
    with
    | Ok value -> value
    | Error err -> fail err
  in
  check bool "second petition merged" true second.merged;
  check string "same case id" first.case_.id second.case_.id;
  check int "single case" 1 (List.length (GV2.list_cases ~include_test:true base_path))

let test_semantic_title_merge_without_action () =
  with_base @@ fun () ->
  let first =
    match
      submit
        ~title:"Restart DB service"
        ~subject_type:"service_operation"
        ~requested_action:None
        ~source_refs:[]
        ~created_by:"agent-a"
    with
    | Ok value -> value
    | Error err -> fail err
  in
  let second =
    match
      submit
        ~title:"Reboot database service"
        ~subject_type:"service_operation"
        ~requested_action:None
        ~source_refs:[]
        ~created_by:"agent-b"
    with
    | Ok value -> value
    | Error err -> fail err
  in
  check bool "semantic title merged" true second.merged;
  check string "same case id" first.case_.id second.case_.id;
  check int "single case" 1 (List.length (GV2.list_cases ~include_test:true base_path))

let test_different_action_payload_creates_new_case () =
  with_base @@ fun () ->
  let first =
    match
      submit
        ~title:"Increase DB timeout to 10 seconds"
        ~subject_type:"param_change"
        ~requested_action:(set_param_request ~param_key:"db_timeout" ~value:(`Int 10))
        ~source_refs:[]
        ~created_by:"agent-a"
    with
    | Ok value -> value
    | Error err -> fail err
  in
  let second =
    match
      submit
        ~title:"Increase DB timeout to 30 seconds"
        ~subject_type:"param_change"
        ~requested_action:(set_param_request ~param_key:"db_timeout" ~value:(`Int 30))
        ~source_refs:[]
        ~created_by:"agent-b"
    with
    | Ok value -> value
    | Error err -> fail err
  in
  check bool "different payload not merged" false second.merged;
  check bool "different case id" true (first.case_.id <> second.case_.id);
  check int "two cases" 2 (List.length (GV2.list_cases ~include_test:true base_path))

(* ── Canonical action normalization tests ──────────────── *)

(** "clear_param" and "reset_param" should merge to the same case
    because clear→reset and param→parameter via canonical synonyms. *)
let test_synonym_action_merge () =
  with_base @@ fun () ->
  let make_action action_type =
    Some { GV2.action_type; target_type = Some "runtime_param";
           target_id = Some "db_timeout";
           payload = Some (`Assoc [("param_key", `String "db_timeout")]) }
  in
  let first =
    match submit ~title:"Clear db_timeout to default"
      ~subject_type:"param_change"
      ~requested_action:(make_action "clear_param")
      ~source_refs:[] ~created_by:"agent-a"
    with Ok v -> v | Error e -> fail e
  in
  let second =
    match submit ~title:"Reset db_timeout"
      ~subject_type:"param_change"
      ~requested_action:(make_action "reset_param")
      ~source_refs:[] ~created_by:"agent-b"
    with Ok v -> v | Error e -> fail e
  in
  check bool "synonym actions merge" true second.merged;
  check string "same case id" first.case_.id second.case_.id

(** "set_param" and "update_param" should merge. *)
let test_set_update_synonym_merge () =
  with_base @@ fun () ->
  let make_action action_type =
    Some { GV2.action_type; target_type = Some "runtime_param";
           target_id = Some "max_conn";
           payload = Some (`Assoc [("param_key", `String "max_conn"); ("value", `Int 100)]) }
  in
  let first =
    match submit ~title:"Set max_conn to 100"
      ~subject_type:"param_change"
      ~requested_action:(make_action "set_param")
      ~source_refs:[] ~created_by:"agent-a"
    with Ok v -> v | Error e -> fail e
  in
  let second =
    match submit ~title:"Update max_conn to 100"
      ~subject_type:"param_change"
      ~requested_action:(make_action "update_param")
      ~source_refs:[] ~created_by:"agent-b"
    with Ok v -> v | Error e -> fail e
  in
  check bool "set/update synonym merge" true second.merged;
  check string "same case id" first.case_.id second.case_.id

(** Truly different actions should NOT merge even with synonyms. *)
let test_different_canonical_actions_no_merge () =
  with_base @@ fun () ->
  let make_action action_type =
    Some { GV2.action_type; target_type = Some "runtime_param";
           target_id = Some "db_timeout";
           payload = Some (`Assoc [("param_key", `String "db_timeout")]) }
  in
  let first =
    match submit ~title:"Set db_timeout"
      ~subject_type:"param_change"
      ~requested_action:(make_action "set_param")
      ~source_refs:[] ~created_by:"agent-a"
    with Ok v -> v | Error e -> fail e
  in
  let second =
    match submit ~title:"Delete db_timeout"
      ~subject_type:"param_change"
      ~requested_action:(make_action "delete_param")
      ~source_refs:[] ~created_by:"agent-b"
    with Ok v -> v | Error e -> fail e
  in
  check bool "different canonical actions do not merge" false second.merged;
  check bool "different case ids" true (first.case_.id <> second.case_.id)

(** "clear_param" and "revert_param" should NOT merge because
    clear→reset and revert→revert are now distinct canonical groups. *)
let test_clear_vs_revert_no_merge () =
  with_base @@ fun () ->
  let make_action action_type =
    Some { GV2.action_type; target_type = Some "runtime_param";
           target_id = Some "db_timeout";
           payload = Some (`Assoc [("param_key", `String "db_timeout")]) }
  in
  let first =
    match submit ~title:"Clear db_timeout"
      ~subject_type:"param_change"
      ~requested_action:(make_action "clear_param")
      ~source_refs:[] ~created_by:"agent-a"
    with Ok v -> v | Error e -> fail e
  in
  let second =
    match submit ~title:"Revert db_timeout"
      ~subject_type:"param_change"
      ~requested_action:(make_action "revert_param")
      ~source_refs:[] ~created_by:"agent-b"
    with Ok v -> v | Error e -> fail e
  in
  check bool "clear vs revert do not merge" false second.merged;
  check bool "different case ids" true (first.case_.id <> second.case_.id)

(** Different target_type values must produce separate cases. *)
let test_different_target_type_no_merge () =
  with_base @@ fun () ->
  let make_action target_type =
    Some { GV2.action_type = "set_param"; target_type = Some target_type;
           target_id = Some "max_conn";
           payload = Some (`Assoc [("param_key", `String "max_conn"); ("value", `Int 100)]) }
  in
  let first =
    match submit ~title:"Set max_conn"
      ~subject_type:"param_change"
      ~requested_action:(make_action "runtime_param")
      ~source_refs:[] ~created_by:"agent-a"
    with Ok v -> v | Error e -> fail e
  in
  let second =
    match submit ~title:"Set max_conn"
      ~subject_type:"param_change"
      ~requested_action:(make_action "system_param")
      ~source_refs:[] ~created_by:"agent-b"
    with Ok v -> v | Error e -> fail e
  in
  check bool "different target_type do not merge" false second.merged;
  check bool "different case ids" true (first.case_.id <> second.case_.id)

let () =
  run "governance_v2"
    [
      ( "petition_dedup",
        [
          test_case "same action payload merges different titles" `Quick
            test_same_action_payload_merges_different_titles;
          test_case "semantic title merge without action" `Quick
            test_semantic_title_merge_without_action;
          test_case "different action payload creates new case" `Quick
            test_different_action_payload_creates_new_case;
        ] );
      ( "canonical_normalization",
        [
          test_case "clear/reset synonym merge" `Quick
            test_synonym_action_merge;
          test_case "set/update synonym merge" `Quick
            test_set_update_synonym_merge;
          test_case "set vs delete no merge" `Quick
            test_different_canonical_actions_no_merge;
          test_case "clear vs revert no merge" `Quick
            test_clear_vs_revert_no_merge;
          test_case "different target_type no merge" `Quick
            test_different_target_type_no_merge;
        ] );
    ]
