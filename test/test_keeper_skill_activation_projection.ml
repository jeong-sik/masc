open Alcotest
open Masc

module Ledger = Keeper_skill_activation_ledger
module Projection = Keeper_skill_activation_projection

let rec remove_tree path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR ->
    Sys.readdir path
    |> Array.iter (fun name -> remove_tree (Filename.concat path name));
    Unix.rmdir path
  | Unix.S_REG | Unix.S_LNK | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO
  | Unix.S_SOCK -> Unix.unlink path
;;

let with_workspace operation =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let root = Filename.temp_dir "skill-activation-projection-" "" in
  let config = Workspace.default_config root in
  ignore (Workspace.init config ~agent_name:(Some "test"));
  Fun.protect
    ~finally:(fun () -> remove_tree root)
    (fun () -> operation config)
;;

let meta keeper_name =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
         [ "name", `String keeper_name
         ; "trace_id", `String "trace-projection"
         ])
  with
  | Ok meta -> meta
  | Error detail -> fail detail
;;

let persist_session config keeper_name =
  let meta = meta keeper_name in
  (match Keeper_meta_store.replace_snapshot config meta with
   | Ok () -> ()
   | Error detail -> fail detail);
  let session_dir =
    Keeper_fs.keeper_session_dir
      config
      (Keeper_id.Trace_id.to_string meta.runtime.trace_id)
  in
  Unix.mkdir session_dir 0o700;
  meta
;;

let test_missing_keeper_is_no_session () =
  with_workspace @@ fun config ->
  match Projection.resolve ~config ~keeper_name:"absent" with
  | Projection.No_session { keeper_name } ->
    check string "exact Keeper" "absent" keeper_name
  | Projection.Available _ | Projection.Unavailable _ ->
    fail "missing Keeper did not remain no_session"
;;

let source_id =
  match Skill_source_config.source_id_of_string "workspace" with
  | Ok source_id -> source_id
  | Error detail -> fail detail
;;

let package_id =
  match Skill_reference.package_id_of_directory "review" with
  | Ok package_id -> package_id
  | Error _ -> fail "invalid package fixture"
;;

let revision parse value =
  match parse value with
  | Ok revision -> revision
  | Error _ -> fail "invalid revision fixture"
;;

let record_one config (meta : Keeper_meta_contract.keeper_meta) =
  let reference =
    Skill_reference.make
      ~identity:
        (Skill_reference.make_identity
           ~source_id
           ~package_id
           ~name:"review")
      ~content_revision:
        (revision
           Skill_reference.content_revision_of_string
           (String.make 64 'a'))
  in
  let activation =
    match
      Ledger.make_activation
        ~identity:reference.identity
        ~content_revision:reference.content_revision
        ~snapshot_revision:
          (revision
             Skill_catalog_snapshot.snapshot_revision_of_string
             (String.make 64 'b'))
        ~turn_ref:
          (Ids.Turn_ref.make
             ~trace_id:(Keeper_id.Trace_id.to_string meta.runtime.trace_id)
             ~absolute_turn:1)
        ~runtime_id:"test.runtime"
        ~skill_tool_use_id:"call-projection"
        ~agent_core_turn:0
        ~invocation:
          (Ledger.Instruction_invocation
             { origin = Ledger.Session_instruction
             ; served_content =
                 Ledger.Skill_body
                   { bytes = String.length "projection body"
                   ; sha256 =
                       Agent_core_sha256.(digest_string "projection body" |> to_hex)
                   }
             })
        ~activated_at:"2026-08-26T00:00:00Z"
    with
    | Ok activation -> activation
    | Error _ -> fail "activation fixture rejected"
  in
  match Ledger.record ~config ~trace_id:meta.runtime.trace_id activation with
  | Ok _ -> ()
  | Error error -> fail (Ledger.store_error_to_string error)
;;

let activation_count json =
  let open Yojson.Safe.Util in
  json
  |> member "skill_activations"
  |> member "ledger"
  |> member "activations"
  |> to_list
  |> List.length
;;

let summary_count field json =
  let open Yojson.Safe.Util in
  json
  |> member "skill_activations"
  |> member "summary"
  |> member field
  |> to_int
;;

let test_dashboard_projection_is_live_outside_inventory_cache () =
  with_workspace @@ fun config ->
  Fun.protect ~finally:Dashboard_snapshot.reset_for_test @@ fun () ->
  Dashboard_snapshot.publish_for_test
    (Dashboard_snapshot.make_for_test ~config ~shell:`Null
       ~tools:(`Assoc [ "snapshot_only", `Bool true ])
       ~namespace_truth:`Null ~telemetry_summary:`Null ());
  let keeper_name = "projection-keeper" in
  let meta = persist_session config keeper_name in
  let live_tools () =
    match Server_dashboard_snapshot_select.select_tools_response ~keeper:keeper_name config with
    | Tools_json json -> json
    | Tools_prepared _ -> fail "exact Keeper reused default snapshot bytes"
  in
  let before =
    live_tools ()
  in
  check int "empty live ledger" 0 (activation_count before);
  check int "empty invocation summary" 0
    (summary_count "instruction_invocations" before);
  record_one config meta;
  let after =
    live_tools ()
  in
  check int "same cached inventory gets fresh activation ledger" 1
    (activation_count after);
  check int "one exact invocation" 1
    (summary_count "instruction_invocations" after);
  check int "one body served" 1
    (summary_count "skill_bodies_served" after);
  check int "no inferred provider delivery" 0
    (summary_count "instruction_provider_deliveries" after);
  check int "no inferred official client handoff" 0
    (summary_count "instruction_official_client_handoffs" after);
  check int "strict ledger has no invalid transitions" 0
    (summary_count "invalid_transitions" after)
;;

let test_corrupt_ledger_is_unavailable_not_empty () =
  with_workspace @@ fun config ->
  let keeper_name = "corrupt-ledger" in
  let meta = persist_session config keeper_name in
  let path =
    Filename.concat
      (Keeper_fs.keeper_session_dir
         config
         (Keeper_id.Trace_id.to_string meta.runtime.trace_id))
      "skill-activation-events.jsonl"
  in
  let channel = open_out_bin path in
  output_string channel "not-json";
  close_out channel;
  match Projection.resolve ~config ~keeper_name with
  | Projection.Unavailable { reason; _ } ->
    check string "typed reason" "activation_ledger_unreadable" reason
  | Projection.Available _ | Projection.No_session _ ->
    fail "corrupt ledger was projected as an empty success"
;;

let test_exact_trace_projection_uses_typed_ledger () =
  with_workspace @@ fun config ->
  let keeper_name = "historical-projection-keeper" in
  let meta = persist_session config keeper_name in
  record_one config meta;
  match Projection.resolve_trace ~config ~trace_id:meta.runtime.trace_id with
  | Projection.Trace_available { trace_id; ledger } ->
    check string "exact trace id"
      (Keeper_id.Trace_id.to_string meta.runtime.trace_id)
      (Keeper_id.Trace_id.to_string trace_id);
    check int "one typed activation" 1 (List.length (Ledger.activations ledger));
    let json =
      Projection.trace_to_yojson
        (Projection.Trace_available { trace_id; ledger })
    in
    check string "available status" "available"
      Yojson.Safe.Util.(json |> member "status" |> to_string);
    check string "projection schema" "masc.dashboard.skill-activations/v1"
      Yojson.Safe.Util.(json |> member "schema" |> to_string);
    check int "derived summary"
      1
      Yojson.Safe.Util.(json |> member "summary" |> member "instruction_invocations" |> to_int)
  | Projection.Trace_not_recorded _ -> fail "recorded exact trace was absent"
  | Projection.Trace_unavailable _ -> fail "exact trace projection was unavailable"
;;

let chat_row turn_ref =
  `Assoc
    [ "id", `String ("autonomous:" ^ turn_ref)
    ; "role", `String "assistant"
    ; "content", `Null
    ; "turn_ref", `String turn_ref
    ; "autonomous_turn", `Assoc [ "turn_id", `String turn_ref ]
    ; ( "blocks"
      , `List
          [ `Assoc
              [ "t", `String "trace"
              ; ( "trace"
                , `List
                    [ `Assoc
                        [ "kind", `String "tool"
                        ; "name", `String "keeper_skill"
                        ; "status", `String "ok"
                        ]
                    ] )
              ]
          ] )
    ]
;;

let attached_skill_projection config ~keeper_name turn_ref =
  let open Yojson.Safe.Util in
  Server_dashboard_http_keeper_api.attach_keeper_chat_skill_activations
    ~config ~keeper_name (`List [ chat_row turn_ref ])
  |> to_list |> List.hd |> member "skill_activations"
;;

let test_chat_history_attaches_the_exact_activation () =
  with_workspace @@ fun config ->
  let keeper_name = "chat-projection-keeper" in
  let meta = persist_session config keeper_name in
  record_one config meta;
  let projection = attached_skill_projection config ~keeper_name "trace-projection#1" in
  let open Yojson.Safe.Util in
  check string "typed chat projection schema"
    "masc.keeper_chat.skill_activations.v2"
    (projection |> member "schema" |> to_string);
  check string "the exact activation is available" "available"
    (projection |> member "status" |> to_string);
  let activation = projection |> member "activations" |> to_list |> List.hd in
  check string "the canonical ledger identity reaches chat" "review"
    (activation |> member "identity" |> member "name" |> to_string);
  check bool "served content does not invent delivery" true
    (activation |> member "delivery" = `Null)
;;

let test_chat_history_marks_an_unmatched_raw_skill_call () =
  with_workspace @@ fun config ->
  let keeper_name = "chat-missing-projection-keeper" in
  let meta = persist_session config keeper_name in
  record_one config meta;
  let projection = attached_skill_projection config ~keeper_name "trace-projection#2" in
  let open Yojson.Safe.Util in
  check string "same trace but another turn is not borrowed" "missing"
    (projection |> member "status" |> to_string);
  check int "no activation is attached across turn_refs" 0
    (projection |> member "activations" |> to_list |> List.length)
;;

let test_missing_exact_trace_is_not_recorded () =
  with_workspace @@ fun config ->
  let trace_id =
    match Keeper_id.Trace_id.of_string "trace-never-recorded" with
    | Ok trace_id -> trace_id
    | Error detail -> fail detail
  in
  match Projection.resolve_trace ~config ~trace_id with
  | Projection.Trace_not_recorded { trace_id = observed } ->
    check string "exact missing trace"
      (Keeper_id.Trace_id.to_string trace_id)
      (Keeper_id.Trace_id.to_string observed);
    let json =
      Projection.trace_to_yojson
        (Projection.Trace_not_recorded { trace_id = observed })
    in
    check string "typed absence" "not_recorded"
      Yojson.Safe.Util.(json |> member "status" |> to_string);
    let session_dir =
      Keeper_fs.keeper_session_dir config (Keeper_id.Trace_id.to_string trace_id)
    in
    check bool "read-only absence leaves no lock" false
      (Sys.file_exists (session_dir ^ ".checkpoint.lock"))
  | Projection.Trace_available _ -> fail "missing trace was synthesized as available"
  | Projection.Trace_unavailable _ -> fail "missing trace was reported unreadable"
;;

let test_invalid_exact_trace_is_rejected_before_resolution () =
  with_workspace @@ fun config ->
  match Projection.resolve_trace_string ~config "../escape" with
  | Error _ -> ()
  | Ok _ -> fail "invalid trace id reached historical resolution"
;;

let test_corrupt_exact_trace_is_unavailable () =
  with_workspace @@ fun config ->
  let meta = persist_session config "corrupt-historical-ledger" in
  let path =
    Filename.concat
      (Keeper_fs.keeper_session_dir
         config
         (Keeper_id.Trace_id.to_string meta.runtime.trace_id))
      "skill-activation-events.jsonl"
  in
  let channel = open_out_bin path in
  output_string channel "{}";
  close_out channel;
  match Projection.resolve_trace ~config ~trace_id:meta.runtime.trace_id with
  | Projection.Trace_unavailable { reason; _ } ->
    check string "typed reason" "activation_ledger_unreadable" reason
  | Projection.Trace_available _ -> fail "corrupt exact trace was projected"
  | Projection.Trace_not_recorded _ -> fail "corrupt exact trace disappeared"
;;

(* A Keeper that does not exist is an answer, not a cold cache. The tools
   payload used to seed a "warming" effective surface for any keeper name
   until the shared inventory cache filled, so a keeper an admin had taken
   down read as one the server had not looked at yet. The surface is now
   resolved live on every request, and the first read of an unknown name
   says keeper_not_found. *)
let test_absent_keeper_is_not_found_not_warming () =
  with_workspace @@ fun config ->
  let json =
    Server_dashboard_http_runtime_info.dashboard_tools_http_json
      ~keeper:"never-registered"
      config
  in
  let open Yojson.Safe.Util in
  let surface = json |> member "effective_keeper_surface" in
  check string "unavailable, not warming" "unavailable"
    (surface |> member "status" |> to_string);
  check string "and it says why" "keeper_not_found"
    (surface |> member "reason" |> to_string);
  check string "for that keeper" "never-registered"
    (surface |> member "keeper_name" |> to_string)
;;

let composition_fixture config meta =
  record_one config meta;
  let ledger = match Ledger.load ~config ~trace_id:meta.Keeper_meta_contract.runtime.trace_id with
    | Ok ledger -> ledger | Error error -> fail (Ledger.store_error_to_string error) in
  let seed = List.hd (Ledger.activations ledger) in
  let activation = match Ledger.make_activation
      ~identity:seed.identity ~content_revision:seed.content_revision
      ~snapshot_revision:seed.snapshot_revision ~turn_ref:seed.turn_ref
      ~runtime_id:seed.runtime_id ~skill_tool_use_id:"composition-call" ~agent_core_turn:0
      ~invocation:(Ledger.Composition_invocation { origin = Ledger.Session_composition;
        tool_name = "keeper_compose_review"; execution_id = Ids.Execution_id.of_string "physical-original" })
      ~activated_at:seed.activated_at with
    | Ok value -> value | Error _ -> fail "composition fixture rejected" in
  (match Ledger.record ~config ~trace_id:meta.runtime.trace_id activation with
   | Ok _ -> () | Error error -> fail (Ledger.store_error_to_string error));
  activation

let composition_execution_row keeper_name disposition =
  `Assoc [ "ts", `Float 1.; "keeper", `String keeper_name;
    "record_kind", `String "tool_call"; "execution_id", `String "physical-original";
    "trace_id", `String "trace-projection"; "session_id", `String "trace-projection";
    "keeper_turn_id", `Int 1; "turn", `Int 0; "runtime_profile", `String "test.runtime";
    "tool_use_id", `String "composition-call"; "tool", `String "keeper_compose_review";
    "disposition", `String disposition; "wire_outcome", `String "ok" ]

let replace_field key value = function
  | `Assoc fields -> `Assoc ((key, value) :: List.remove_assoc key fields)
  | _ -> fail "fixture is not an object"

let test_composition_joins_only_its_original_execution () =
  with_workspace @@ fun config ->
  let keeper_name = "execution-projection-keeper" in
  let meta = persist_session config keeper_name in
  let activation = composition_fixture config meta in
  let row = composition_execution_row keeper_name "failed" in
  let project rows = Keeper_skill_execution_projection.of_rows ~keeper_name ~rows:(Ok rows) activation
    |> Keeper_skill_execution_projection.to_yojson in
  let status rows = Yojson.Safe.Util.(project rows |> member "status" |> to_string) in
  List.iter (fun disposition ->
    check string "original typed disposition remains distinct" disposition
      (status [ composition_execution_row keeper_name disposition ])) ["completed";"deferred";"failed"];
  check string "assignment profile is not the actual failover runtime" "failed"
    (status [replace_field "runtime_profile" (`String "assignment-before-failover") row]);
  let later = replace_field "execution_id" (`String "physical-later")
      (composition_execution_row keeper_name "completed") in
  check string "later same-provider-id success cannot replace original failure" "failed" (status [row;later]);
  check string "later execution cannot supply missing original" "unrecorded" (status [later]);
  check string "duplicate canonical execution is not selected" "unavailable" (status [row;row]);
  List.iter (fun (field, value) ->
    check string ("source coordinate refused: " ^ field) "unavailable"
      (status [ replace_field field value row ]))
    ["keeper", `String "other"; "trace_id", `String "other"; "session_id", `String "other";
     "keeper_turn_id", `Int 2; "turn", `Int 1;
     "tool_use_id", `String "other"; "tool", `String "keeper_compose_other";
     "record_kind", `String "composition_run"; "disposition", `String "unknown"];
  let without_disposition = match row with `Assoc fields -> `Assoc (List.remove_assoc "disposition" fields)
    | _ -> fail "fixture is not an object" in
  check string "wire ok alone cannot establish execution completion" "unrecorded" (status [without_disposition])

let test_chat_history_reads_execution_beyond_the_trace () =
  with_workspace @@ fun config ->
  let keeper_name = "execution-chat-keeper" in
  let meta = persist_session config keeper_name in
  let activation = composition_fixture config meta in
  let content = "composition failure" in
  (match Ledger.observe_delivery ~config ~trace_id:meta.runtime.trace_id
    ~turn_ref:activation.turn_ref
    ~tool_results:[ { Ledger.tool_use_id = "composition-call"; content_bytes = String.length content;
      content_sha256 = Agent_core_sha256.(digest_string content |> to_hex) } ]
    ~boundary:(Ledger.Model_response { agent_core_turn = 1 })
    ~runtime_id:"test.runtime" ~delivered_at:"2026-08-26T00:00:01Z" with
   | Ok _ -> () | Error error -> fail (Ledger.store_error_to_string error));
  let store = Dated_jsonl.open_store (Dated_jsonl.Store.at (Workspace.dated_store_root config)
      Dated_jsonl.Store.Root.Tool_calls) in
  Dated_jsonl.append store (composition_execution_row keeper_name "failed");
  let projection = attached_skill_projection config ~keeper_name "trace-projection#1" in
  let open Yojson.Safe.Util in
  let activation = projection |> member "activations" |> to_list
    |> List.find (fun row -> row |> member "skill_tool_use_id" |> to_string = "composition-call") in
  check string "exact canonical result survives a trace with no composition step" "failed"
    (activation |> member "execution" |> member "status" |> to_string);
  check string "physical anchor is preserved" "physical-original"
    (activation |> member "execution" |> member "execution_id" |> to_string);
  check bool "the error result remains delivered despite failed execution" true
    (activation |> member "delivery" <> `Null)

let () =
  run
    "keeper Skill activation projection"
    [ ( "projection"
      , [ test_case "composition exact execution authority" `Quick test_composition_joins_only_its_original_execution
        ; test_case "chat reads exact execution without trace membership" `Quick test_chat_history_reads_execution_beyond_the_trace
        ; test_case "missing Keeper is no_session" `Quick
            test_missing_keeper_is_no_session
        ; test_case "dashboard attachment bypasses inventory cache" `Quick
            test_dashboard_projection_is_live_outside_inventory_cache
 ; test_case "absent keeper is not found, not warming" `Quick
     test_absent_keeper_is_not_found_not_warming
        ; test_case "corrupt ledger is unavailable" `Quick
            test_corrupt_ledger_is_unavailable_not_empty
        ; test_case "exact trace uses typed ledger" `Quick
            test_exact_trace_projection_uses_typed_ledger
        ; test_case "chat history attaches exact Skill evidence" `Quick
            test_chat_history_attaches_the_exact_activation
        ; test_case "chat history does not borrow another turn" `Quick
            test_chat_history_marks_an_unmatched_raw_skill_call
        ; test_case "missing exact trace is not recorded" `Quick
            test_missing_exact_trace_is_not_recorded
        ; test_case "invalid exact trace is rejected" `Quick
            test_invalid_exact_trace_is_rejected_before_resolution
        ; test_case "corrupt exact trace is unavailable" `Quick
            test_corrupt_exact_trace_is_unavailable
        ] )
    ]
;;
