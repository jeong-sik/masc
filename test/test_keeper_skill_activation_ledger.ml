open Alcotest
open Masc

module Ledger = Masc.Keeper_skill_activation_ledger

let rec remove_tree path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR ->
    Sys.readdir path
    |> Array.iter (fun name -> remove_tree (Filename.concat path name));
    Unix.rmdir path
  | Unix.S_REG | Unix.S_LNK | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO
  | Unix.S_SOCK -> Unix.unlink path
;;

let trace_id value =
  match Keeper_id.Trace_id.of_string value with
  | Ok value -> value
  | Error detail -> fail detail
;;

let task_id value =
  match Keeper_id.Task_id.of_string value with
  | Ok value -> value
  | Error detail -> fail detail
;;

let with_session f =
  let root = Filename.temp_file "skill-activation-ledger-" "" in
  Sys.remove root;
  Unix.mkdir root 0o700;
  let config = Workspace.default_config root in
  let trace_id = trace_id "trace-one" in
  let session_dir = Keeper_fs.keeper_session_dir config "trace-one" in
  Unix.mkdir session_dir 0o700;
  Fun.protect
    ~finally:(fun () -> remove_tree root)
    (fun () -> f config trace_id session_dir)
;;

let copy_file ~source ~target =
  let input = open_in_bin source in
  let output = open_out_bin target in
  Fun.protect
    ~finally:(fun () -> close_in_noerr input; close_out_noerr output)
    (fun () -> output_string output (really_input_string input (in_channel_length input)))
;;

let source_id value =
  match Skill_source_config.source_id_of_string value with
  | Ok value -> value
  | Error detail -> fail detail
;;

let package_id value =
  match Skill_catalog_snapshot.package_id_of_directory value with
  | Ok value -> value
  | Error _ -> fail "invalid package fixture"
;;

let content_revision character =
  match
    Skill_catalog_snapshot.content_revision_of_string (String.make 64 character)
  with
  | Ok value -> value
  | Error _ -> fail "invalid content revision fixture"
;;

let snapshot_revision =
  match Skill_catalog_snapshot.snapshot_revision_of_string (String.make 64 'f') with
  | Ok value -> value
  | Error _ -> fail "invalid snapshot revision fixture"
;;

let activation_result ?(trace = "trace-one") ?(source = "workspace")
      ?(package = "review") ?(name = "review") ?(revision = 'a')
      ?(absolute_turn = 1) ?(activated_at = "2026-08-26T00:00:00Z")
      ?(origin = Ledger.Task_instruction { task_id = task_id "task-001" }) () =
  Ledger.make_activation
    ~identity:
      (Skill_catalog_snapshot.make_identity
         ~source_id:(source_id source)
         ~package_id:(package_id package)
         ~name)
    ~content_revision:(content_revision revision)
    ~snapshot_revision
    ~turn_ref:(Ids.Turn_ref.make ~trace_id:trace ~absolute_turn)
    ~activated_at
    ~origin
;;

let activation ?trace ?source ?package ?name ?revision ?absolute_turn ?activated_at
      ?origin () =
  match
    activation_result
      ?trace
      ?source
      ?package
      ?name
      ?revision
      ?absolute_turn
      ?activated_at
      ?origin
      ()
  with
  | Ok value -> value
  | Error _ -> fail "activation fixture was rejected"
;;

let test_empty_record_and_idempotent_readback () =
  with_session @@ fun config trace_id _session_dir ->
  let initial =
    match Ledger.load ~config ~trace_id with
    | Ok ledger -> ledger
    | Error error ->
      fail ("empty ledger load failed: " ^ Ledger.store_error_to_string error)
  in
  check int "empty session" 0 (List.length (Ledger.activations initial));
  let activation = activation () in
  let first, first_outcome =
    match Ledger.record ~config ~trace_id activation with
    | Ok value -> value
    | Error error ->
      fail ("first activation record failed: " ^ Ledger.store_error_to_string error)
  in
  (match first_outcome with
   | Ledger.Recorded _ -> ()
   | Already_recorded _ -> fail "first activation was already present");
  check int "one activation" 1 (List.length (Ledger.activations first));
  let second, second_outcome =
    match Ledger.record ~config ~trace_id activation with
    | Ok value -> value
    | Error _ -> fail "idempotent activation record failed"
  in
  (match second_outcome with
   | Ledger.Already_recorded _ -> ()
   | Recorded _ -> fail "same exact activation was recorded twice");
  check string
    "idempotent revision"
    (Ledger.ledger_revision_to_string (Ledger.revision first))
    (Ledger.ledger_revision_to_string (Ledger.revision second))
;;

let test_same_name_different_identity_or_revision_is_distinct () =
  with_session @@ fun config trace_id _session_dir ->
  let values =
    [ activation (); activation ~source:"user" (); activation ~revision:'b' () ]
  in
  List.iter
    (fun value ->
       match Ledger.record ~config ~trace_id value with
       | Ok (_, Ledger.Recorded _) -> ()
       | Ok (_, Already_recorded _) -> fail "distinct activation was deduplicated"
       | Error error ->
         fail ("distinct activation record failed: " ^ Ledger.store_error_to_string error))
    values;
  match Ledger.load ~config ~trace_id with
  | Error error -> fail ("ledger readback failed: " ^ Ledger.store_error_to_string error)
  | Ok ledger -> check int "three exact activations" 3 (List.length (Ledger.activations ledger))
;;

let test_session_origins_roundtrip () =
  with_session @@ fun config trace_id _session_dir ->
  let values =
    [ activation ~revision:'b' ~origin:Ledger.Session_instruction ()
    ; activation
        ~revision:'c'
        ~origin:(Ledger.Session_composition { tool_name = "keeper_compose_review" })
        ()
    ]
  in
  List.iter
    (fun value ->
       match Ledger.record ~config ~trace_id value with
       | Ok (_, Ledger.Recorded _) -> ()
       | Ok (_, Already_recorded _) -> fail "session origin was deduplicated"
       | Error error -> fail (Ledger.store_error_to_string error))
    values;
  match Ledger.load ~config ~trace_id with
  | Error error -> fail (Ledger.store_error_to_string error)
  | Ok ledger ->
    (match
       List.map (fun (activation : Ledger.activation) -> activation.origin)
         (Ledger.activations ledger)
     with
     | [ Ledger.Session_instruction
       ; Ledger.Session_composition { tool_name }
       ] ->
       check string "composition tool" "keeper_compose_review" tool_name
     | _ -> fail "session origins did not survive durable roundtrip")
;;

let test_corrupt_ledger_is_typed () =
  with_session @@ fun config trace_id session_dir ->
  let path = Filename.concat session_dir "skill-activations.json" in
  let channel = open_out_bin path in
  output_string channel "not-json";
  close_out channel;
  match Ledger.load ~config ~trace_id with
  | Error (Ledger.Decode_failed _) -> ()
  | Error error ->
    fail ("corrupt ledger returned the wrong typed error: " ^ Ledger.store_error_to_string error)
  | Ok _ -> fail "corrupt ledger loaded"
;;

let test_copied_ledger_is_rejected_by_session_identity () =
  with_session @@ fun config trace_one session_one ->
  let value = activation () in
  (match Ledger.record ~config ~trace_id:trace_one value with
   | Ok _ -> ()
   | Error error -> fail (Ledger.store_error_to_string error));
  let trace_two = trace_id "trace-two" in
  let session_two = Keeper_fs.keeper_session_dir config "trace-two" in
  Unix.mkdir session_two 0o700;
  let source = Filename.concat session_one "skill-activations.json" in
  let target = Filename.concat session_two "skill-activations.json" in
  copy_file ~source ~target;
  match Ledger.load ~config ~trace_id:trace_two with
  | Error (Ledger.Decode_failed Ledger.Session_id_mismatch) -> ()
  | Error error ->
    fail ("copied ledger returned wrong error: " ^ Ledger.store_error_to_string error)
  | Ok _ -> fail "ledger copied from another trace was accepted"
;;

let test_duplicate_exact_key_is_rejected_during_decode () =
  with_session @@ fun config trace _session_dir ->
  let activation_json, workspace_key =
    match Ledger.record ~config ~trace_id:trace (activation ()) with
    | Error error -> fail (Ledger.store_error_to_string error)
    | Ok (stored, _) ->
      (match Ledger.to_yojson stored with
       | `Assoc fields ->
         (match
            List.assoc_opt "activations" fields, List.assoc_opt "workspace_key" fields
          with
          | Some (`List [ row ]), Some (`String workspace_key) -> row, workspace_key
          | _ -> fail "stored activation projection missing")
       | _ -> fail "stored ledger projection invalid")
  in
  let activations = `List [ activation_json; activation_json ] in
  let session_id = Keeper_id.Trace_id.to_string trace in
  let revision_input =
    `Assoc
      [ "workspace_key", `String workspace_key
      ; "session_id", `String session_id
      ; "activations", activations
      ]
  in
  let revision =
    Digestif.SHA256.(digest_string (Yojson.Safe.to_string revision_input) |> to_hex)
  in
  let json =
    `Assoc
      [ "schema", `String "masc.skill-activations/v1"
      ; "workspace_key", `String workspace_key
      ; "session_id", `String session_id
      ; "revision", `String revision
      ; "activations", activations
      ]
  in
  let workspace_root = Keeper_fs.session_base_dir config |> Unix.realpath in
  match
    Ledger.of_yojson
      ~expected_workspace_root:workspace_root
      ~expected_trace_id:trace
      json
  with
  | Error Ledger.Duplicate_exact_activation -> ()
  | Error _ -> fail "duplicate exact key returned wrong decoder error"
  | Ok _ -> fail "duplicate exact key was accepted"
;;

let test_cross_workspace_copy_is_rejected () =
  with_session @@ fun source_config trace source_session ->
  (match Ledger.record ~config:source_config ~trace_id:trace (activation ()) with
   | Ok _ -> ()
   | Error error -> fail (Ledger.store_error_to_string error));
  let target_root = Filename.temp_file "skill-activation-target-" "" in
  Sys.remove target_root;
  Unix.mkdir target_root 0o700;
  Fun.protect
    ~finally:(fun () -> remove_tree target_root)
    (fun () ->
       let target_config = Workspace.default_config target_root in
       let target_session = Keeper_fs.keeper_session_dir target_config "trace-one" in
       Unix.mkdir target_session 0o700;
       copy_file
         ~source:(Filename.concat source_session "skill-activations.json")
         ~target:(Filename.concat target_session "skill-activations.json");
       match Ledger.load ~config:target_config ~trace_id:trace with
       | Error (Ledger.Decode_failed Ledger.Workspace_key_mismatch) -> ()
       | Error error ->
         fail
           ("cross-workspace copy returned wrong error: "
            ^ Ledger.store_error_to_string error)
       | Ok _ -> fail "same-trace ledger copied across workspaces was accepted")
;;

let test_official_unicode_skill_name_is_accepted () =
  ignore (activation ~name:"검토" ())
;;

let test_duplicate_json_field_is_rejected () =
  with_session @@ fun config trace _session_dir ->
  let workspace_root = Keeper_fs.session_base_dir config |> Unix.realpath in
  let json = Ledger.empty ~workspace_root ~trace_id:trace |> Ledger.to_yojson in
  let json =
    match json with
    | `Assoc fields ->
      `Assoc (("session_id", `String (Keeper_id.Trace_id.to_string trace)) :: fields)
    | _ -> fail "empty ledger projection invalid"
  in
  match
    Ledger.of_yojson
      ~expected_workspace_root:workspace_root
      ~expected_trace_id:trace
      json
  with
  | Error (Ledger.Duplicate_field { object_name = "ledger"; field = "session_id" }) ->
    ()
  | Error _ -> fail "duplicate JSON field returned wrong decoder error"
  | Ok _ -> fail "duplicate JSON field was accepted"
;;

let test_activation_boundaries_are_typed () =
  (match activation_result ~name:"Review_Name" () with
   | Error (Ledger.Invalid_skill_name _) -> ()
   | Error _ | Ok _ -> fail "non-canonical Skill name was not rejected");
  (match activation_result ~absolute_turn:0 () with
   | Error (Ledger.Invalid_turn_ref _) -> ()
   | Error _ | Ok _ -> fail "non-positive Turn_ref was not rejected");
  (match activation_result ~activated_at:"not-a-time" () with
   | Error (Ledger.Invalid_activated_at _) -> ()
   | Error _ | Ok _ -> fail "invalid activation time was not rejected");
  let invalid_tool_origin =
    Ledger.Task_composition
      { task_id = task_id "task-001"; tool_name = "not/a/tool" }
  in
  match activation_result ~origin:invalid_tool_origin () with
  | Error (Ledger.Invalid_tool_name _) -> ()
  | Error _ | Ok _ -> fail "invalid composition tool name was not rejected"
;;

let test_record_rejects_another_trace () =
  with_session @@ fun config trace _session_dir ->
  match Ledger.record ~config ~trace_id:trace (activation ~trace:"trace-two" ()) with
  | Error (Ledger.Decode_failed Ledger.Turn_ref_session_mismatch) -> ()
  | Error _ -> fail "cross-trace record returned wrong store error"
  | Ok _ -> fail "cross-trace activation was recorded"
;;

let test_revision_binds_workspace_and_trace () =
  with_session @@ fun config trace _session_dir ->
  let workspace_root = Keeper_fs.session_base_dir config |> Unix.realpath in
  let original = Ledger.empty ~workspace_root ~trace_id:trace |> Ledger.revision in
  let another_trace =
    Ledger.empty ~workspace_root ~trace_id:(trace_id "trace-two") |> Ledger.revision
  in
  check bool
    "trace changes revision"
    true
    (not
       (String.equal
          (Ledger.ledger_revision_to_string original)
          (Ledger.ledger_revision_to_string another_trace)));
  let another_root = Filename.temp_file "skill-ledger-revision-root-" "" in
  Sys.remove another_root;
  Unix.mkdir another_root 0o700;
  Fun.protect
    ~finally:(fun () -> Unix.rmdir another_root)
    (fun () ->
       let another_workspace =
         Ledger.empty ~workspace_root:another_root ~trace_id:trace |> Ledger.revision
       in
       check bool
         "workspace changes revision"
         true
         (not
            (String.equal
               (Ledger.ledger_revision_to_string original)
               (Ledger.ledger_revision_to_string another_workspace))))
;;

let () =
  run
    "keeper skill activation ledger"
    [ ( "session ledger"
      , [ test_case "empty, durable record, idempotent readback" `Quick
            test_empty_record_and_idempotent_readback
        ; test_case "exact identity and revision form the dedupe key" `Quick
            test_same_name_different_identity_or_revision_is_distinct
        ; test_case "session origins survive durable roundtrip" `Quick
            test_session_origins_roundtrip
        ; test_case "corrupt payload is typed" `Quick test_corrupt_ledger_is_typed
        ; test_case "copied ledger is bound to its trace" `Quick
            test_copied_ledger_is_rejected_by_session_identity
        ; test_case "duplicate exact key is rejected" `Quick
            test_duplicate_exact_key_is_rejected_during_decode
        ; test_case "same trace copied across workspaces is rejected" `Quick
            test_cross_workspace_copy_is_rejected
        ; test_case "official Unicode Skill name is accepted" `Quick
            test_official_unicode_skill_name_is_accepted
        ; test_case "duplicate JSON field is rejected" `Quick
            test_duplicate_json_field_is_rejected
        ; test_case "activation constructors enforce typed boundaries" `Quick
            test_activation_boundaries_are_typed
        ; test_case "record rejects another trace" `Quick
            test_record_rejects_another_trace
        ; test_case "revision binds workspace and trace" `Quick
            test_revision_binds_workspace_and_trace
        ] )
    ]
;;
