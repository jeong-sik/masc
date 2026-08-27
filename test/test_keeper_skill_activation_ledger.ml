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

let task_ids values =
  let typed = List.map task_id values in
  match Ledger.task_id_set_of_list typed with
  | Ok value -> value
  | Error _ -> fail "invalid task id set fixture"
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
    ?(runtime_id = "test.runtime") ?skill_tool_use_id ?(agent_core_turn = 0)
    ?(body = "skill body")
    ?(absolute_turn = 1) ?(activated_at = "2026-08-26T00:00:00Z")
    ?(origin = Ledger.Task_instruction { task_ids = task_ids [ "task-001" ] })
    ?invocation () =
  let skill_tool_use_id =
    Option.value
      ~default:(Printf.sprintf "call-%s-%c" source revision)
      skill_tool_use_id
  in
  let invocation =
    Option.value
      ~default:
        (Ledger.Instruction_invocation
           { origin
           ; served_content =
               Ledger.Skill_body
                 { bytes = String.length body
                 ; sha256 = Digestif.SHA256.(digest_string body |> to_hex)
                 }
           })
      invocation
  in
  Ledger.make_activation
    ~identity:
      (Skill_catalog_snapshot.make_identity
         ~source_id:(source_id source)
         ~package_id:(package_id package)
         ~name)
    ~content_revision:(content_revision revision)
    ~snapshot_revision
    ~turn_ref:(Ids.Turn_ref.make ~trace_id:trace ~absolute_turn)
    ~runtime_id
    ~skill_tool_use_id
    ~agent_core_turn
    ~invocation
    ~activated_at
;;

let activation ?trace ?source ?package ?name ?revision ?runtime_id ?skill_tool_use_id
      ?agent_core_turn ?body ?absolute_turn ?activated_at ?origin ?invocation () =
  match
    activation_result
      ?trace
      ?source
      ?package
      ?name
      ?revision
      ?runtime_id
      ?skill_tool_use_id
      ?agent_core_turn
      ?body
      ?absolute_turn
      ?activated_at
      ?origin
      ?invocation
      ()
  with
  | Ok value -> value
  | Error _ -> fail "activation fixture was rejected"
;;

let receipt ?(content = "skill body") tool_use_id =
  Ledger.
    { tool_use_id
    ; content_bytes = String.length content
    ; content_sha256 = Digestif.SHA256.(digest_string content |> to_hex)
    }
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

let test_same_skill_different_invocations_are_distinct () =
  with_session @@ fun config trace_id _session_dir ->
  let values =
    [ activation ~skill_tool_use_id:"call-first" ()
    ; activation ~skill_tool_use_id:"call-second" ()
    ]
  in
  List.iter
    (fun value ->
       match Ledger.record ~config ~trace_id value with
       | Ok (_, Ledger.Recorded _) -> ()
       | Ok (_, Already_recorded _) -> fail "distinct invocation was deduplicated"
       | Error error -> fail (Ledger.store_error_to_string error))
    values;
  match Ledger.load ~config ~trace_id with
  | Error error -> fail (Ledger.store_error_to_string error)
  | Ok ledger ->
    check int "two invocation activations" 2
      (List.length (Ledger.activations ledger))
;;

let test_session_origins_roundtrip () =
  with_session @@ fun config trace_id _session_dir ->
  let values =
    [ activation ~revision:'b' ~origin:Ledger.Session_instruction ()
    ; activation
        ~revision:'c'
        ~invocation:
          (Ledger.Composition_invocation
             { origin = Ledger.Session_composition
             ; tool_name = "keeper_compose_review"
             })
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
       List.map (fun (activation : Ledger.activation) -> activation.invocation)
         (Ledger.activations ledger)
     with
     | [ Ledger.Instruction_invocation { origin = Ledger.Session_instruction; _ }
       ; Ledger.Composition_invocation
           { origin = Ledger.Session_composition; tool_name }
       ] ->
       check string "composition tool" "keeper_compose_review" tool_name
     | _ -> fail "session origins did not survive durable roundtrip")
;;

let test_delivery_and_later_action_form_one_exact_chain () =
  with_session @@ fun config trace_id _session_dir ->
  let value = activation ~skill_tool_use_id:"call-skill" ~agent_core_turn:0 () in
  (match Ledger.record ~config ~trace_id value with
   | Ok _ -> ()
   | Error error -> fail (Ledger.store_error_to_string error));
  let turn_ref = Ids.Turn_ref.make ~trace_id:"trace-one" ~absolute_turn:1 in
  let delivered, matching_ids =
    match
      Ledger.observe_delivery
        ~config
        ~trace_id
        ~turn_ref
        ~tool_results:[ receipt "unrelated"; receipt "call-skill" ]
        ~boundary:(Ledger.Model_response { agent_core_turn = 1 })
        ~runtime_id:"runtime-delivery"
        ~delivered_at:"2026-08-26T00:00:01Z"
    with
    | Ok value -> value
    | Error error -> fail (Ledger.store_error_to_string error)
  in
  check (list string) "one matching Skill result" [ "call-skill" ] matching_ids;
  let activation =
    match Ledger.activations delivered with
    | [ activation ] -> activation
    | _ -> fail "delivery changed activation cardinality"
  in
  (match activation.delivery with
   | Some delivery ->
     check string "delivery runtime" "runtime-delivery" delivery.runtime_id;
     check int "delivery content bytes" 10 delivery.content_bytes;
     (match delivery.boundary with
      | Ledger.Model_response { agent_core_turn } ->
        check int "delivery round" 1 agent_core_turn
      | Ledger.Official_client_result_handoff _ ->
        fail "model response recorded as official-client handoff")
   | None -> fail "matching provider input did not record delivery");
  let with_action, added =
    match
      Ledger.observe_action
        ~config
        ~trace_id
        ~turn_ref
        ~active_skill_tool_use_ids:[ "call-skill" ]
        ~action_tool_use_id:"call-action"
        ~tool_name:"keeper_time_now"
        ~runtime_id:"runtime-action"
        ~agent_core_turn:1
        ~observed_at:"2026-08-26T00:00:02Z"
    with
    | Ok value -> value
    | Error error -> fail (Ledger.store_error_to_string error)
  in
  check int "one Skill linked to the action" 1 added;
  (match Ledger.activations with_action with
   | [ { actions = [ action ]; _ } ] ->
     check string "later action id" "call-action" action.tool_use_id;
     check string "later action tool" "keeper_time_now" action.tool_name
     ; check string "later action runtime" "runtime-action" action.runtime_id
   | _ -> fail "later action was not attached to the exact Skill invocation");
  let summary = Ledger.summarize with_action in
  check int "one instruction invocation" 1 summary.instruction_invocations;
  check int "one body served" 1 summary.skill_bodies_served;
  check int "one provider delivery" 1 summary.instruction_provider_deliveries;
  check int "zero official handoffs" 0
    summary.instruction_official_client_handoffs;
  check int "one later action" 1 summary.instruction_actions_observed;
  check int "zero invalid transitions" 0 summary.invalid_transitions;
  (match Ledger.summarize_by_scope with_action with
   | [ scoped ] ->
     check string "scope names invocation runtime" "test.runtime"
       scoped.scope.invocation_runtime_id;
     check
       (list (pair string int))
       "provider delivery runtime is separate"
       [ "runtime-delivery", 1 ]
       (List.map
          (fun (count : Ledger.runtime_count) -> count.runtime_id, count.count)
          scoped.provider_delivery_runtime_counts);
    check (list (pair string int)) "no official handoff runtime" []
      (List.map
         (fun (count : Ledger.runtime_count) -> count.runtime_id, count.count)
         scoped.official_client_handoff_runtime_counts);
     check
       (list (pair string int))
       "action runtime is separate"
       [ "runtime-action", 1 ]
       (List.map
          (fun (count : Ledger.runtime_count) -> count.runtime_id, count.count)
          scoped.action_runtime_counts)
   | _ -> fail "one invocation produced the wrong scoped summary count");
  let _, repeated =
    match
      Ledger.observe_action
        ~config
        ~trace_id
        ~turn_ref
        ~active_skill_tool_use_ids:[ "call-skill" ]
        ~action_tool_use_id:"call-action"
        ~tool_name:"keeper_time_now"
        ~runtime_id:"runtime-action"
        ~agent_core_turn:1
        ~observed_at:"2026-08-26T00:00:03Z"
    with
    | Ok value -> value
    | Error error -> fail (Ledger.store_error_to_string error)
  in
  check int "repeated action observation is idempotent" 0 repeated
;;

let test_demoted_skill_result_is_not_delivery_or_invalid_transition () =
  with_session @@ fun config trace_id _session_dir ->
  let value = activation ~skill_tool_use_id:"call-demoted" () in
  (match Ledger.record ~config ~trace_id value with
   | Ok _ -> ()
   | Error error -> fail (Ledger.store_error_to_string error));
  let turn_ref = Ids.Turn_ref.make ~trace_id:"trace-one" ~absolute_turn:1 in
  let ledger, matched =
    match
      Ledger.observe_delivery
        ~config
        ~trace_id
        ~turn_ref
        ~tool_results:[ receipt ~content:"[demoted]" "call-demoted" ]
        ~boundary:(Ledger.Model_response { agent_core_turn = 1 })
        ~runtime_id:"runtime-b"
        ~delivered_at:"2026-08-26T00:00:01Z"
    with
    | Ok value -> value
    | Error error -> fail (Ledger.store_error_to_string error)
  in
  check (list string) "digest mismatch is not delivered" [] matched;
  check int "demotion is not an invalid transition" 0
    (Ledger.summarize ledger).invalid_transitions;
  match Ledger.activations ledger with
  | [ { delivery = None; _ } ] -> ()
  | _ -> fail "demoted Skill result acquired a delivery receipt"
;;

let test_official_client_handoff_delivers_in_invocation_turn () =
  with_session @@ fun config trace_id _session_dir ->
  let value = activation ~skill_tool_use_id:"call-official" ~agent_core_turn:0 () in
  (match Ledger.record ~config ~trace_id value with
   | Ok _ -> ()
   | Error error -> fail (Ledger.store_error_to_string error));
  let turn_ref = Ids.Turn_ref.make ~trace_id:"trace-one" ~absolute_turn:1 in
  let ledger, matched =
    match
      Ledger.observe_delivery
        ~config
        ~trace_id
        ~turn_ref
        ~tool_results:[ receipt "call-official" ]
        ~boundary:
          (Ledger.Official_client_result_handoff { agent_core_turn = 0 })
        ~runtime_id:"codex-runtime"
        ~delivered_at:"2026-08-26T00:00:01Z"
    with
    | Ok value -> value
    | Error error -> fail (Ledger.store_error_to_string error)
  in
  check (list string) "official handoff exact id" [ "call-official" ] matched;
  (match Ledger.activations ledger with
   | [ { delivery = Some { boundary = Ledger.Official_client_result_handoff _; runtime_id; _ }; _ } ] ->
     check string "official handoff runtime" "codex-runtime" runtime_id
   | _ -> fail "official-client result handoff was not typed");
  let summary = Ledger.summarize ledger in
  check int "handoff is not provider delivery" 0
    summary.instruction_provider_deliveries;
  check int "one official client handoff" 1
    summary.instruction_official_client_handoffs;
  check int "handoff without action is incomplete" 0
    summary.instruction_actions_observed;
  (match Ledger.summarize_by_scope ledger with
   | [ scoped ] ->
     check (list (pair string int)) "no provider delivery runtime" []
       (List.map
          (fun (count : Ledger.runtime_count) -> count.runtime_id, count.count)
          scoped.provider_delivery_runtime_counts);
     check
       (list (pair string int))
       "official handoff runtime is separate"
       [ "codex-runtime", 1 ]
       (List.map
          (fun (count : Ledger.runtime_count) -> count.runtime_id, count.count)
          scoped.official_client_handoff_runtime_counts)
   | _ -> fail "official handoff produced the wrong scoped summary")
  ; let completed, added =
      match
        Ledger.observe_action
          ~config
          ~trace_id
          ~turn_ref
          ~active_skill_tool_use_ids:[ "call-official" ]
          ~action_tool_use_id:"call-after-handoff"
          ~tool_name:"keeper_time_now"
          ~runtime_id:"codex-runtime"
          ~agent_core_turn:0
          ~observed_at:"2026-08-26T00:00:02Z"
      with
      | Ok value -> value
      | Error error -> fail (Ledger.store_error_to_string error)
    in
    check int "later action completes official handoff proof" 1 added;
    check int "completed handoff has one action" 1
      (Ledger.summarize completed).instruction_actions_observed
;;

let test_cross_turn_tool_result_replay_is_not_delivery_or_rejection () =
  with_session @@ fun config trace_id _session_dir ->
  let value = activation ~skill_tool_use_id:"call-replayed" () in
  (match Ledger.record ~config ~trace_id value with
   | Ok _ -> ()
   | Error error -> fail (Ledger.store_error_to_string error));
  let replay_turn = Ids.Turn_ref.make ~trace_id:"trace-one" ~absolute_turn:2 in
  let ledger, matched =
    match
      Ledger.observe_delivery
        ~config
        ~trace_id
        ~turn_ref:replay_turn
        ~tool_results:[ receipt "call-replayed" ]
        ~boundary:(Ledger.Model_response { agent_core_turn = 1 })
        ~runtime_id:"runtime-next-turn"
        ~delivered_at:"2026-08-26T00:00:01Z"
    with
    | Ok value -> value
    | Error error -> fail (Ledger.store_error_to_string error)
  in
  check (list string) "cross-turn replay has no matched ids" [] matched;
  check int "cross-turn replay is not an invalid transition" 0
    (Ledger.summarize ledger).invalid_transitions;
  match Ledger.activations ledger with
  | [ { delivery = None; _ } ] -> ()
  | _ -> fail "cross-turn replay acquired a durable delivery"
;;

let test_conflicting_delivery_is_durable_transition_evidence () =
  with_session @@ fun config trace_id _session_dir ->
  let value = activation ~skill_tool_use_id:"call-conflict" () in
  (match Ledger.record ~config ~trace_id value with
   | Ok _ -> ()
   | Error error -> fail (Ledger.store_error_to_string error));
  let turn_ref = Ids.Turn_ref.make ~trace_id:"trace-one" ~absolute_turn:1 in
  (match
     Ledger.observe_delivery
       ~config
       ~trace_id
       ~turn_ref
       ~tool_results:[ receipt "call-conflict" ]
       ~boundary:(Ledger.Model_response { agent_core_turn = 1 })
       ~runtime_id:"runtime-delivery"
       ~delivered_at:"2026-08-26T00:00:01Z"
   with
   | Ok _ -> ()
   | Error error -> fail (Ledger.store_error_to_string error));
  (match
     Ledger.observe_delivery
       ~config
       ~trace_id
       ~turn_ref
       ~tool_results:[ receipt "call-conflict" ]
       ~boundary:(Ledger.Model_response { agent_core_turn = 2 })
       ~runtime_id:"runtime-delivery"
       ~delivered_at:"2026-08-26T00:00:02Z"
   with
   | Error (Ledger.Conflicting_delivery "call-conflict") -> ()
   | Error error -> fail (Ledger.store_error_to_string error)
   | Ok _ -> fail "conflicting delivery was accepted");
  let persisted =
    match Ledger.load ~config ~trace_id with
    | Ok ledger -> ledger
    | Error error -> fail (Ledger.store_error_to_string error)
  in
  check int "persisted invalid transition" 1
    (Ledger.summarize persisted).invalid_transitions;
  match Ledger.transition_rejections persisted with
  | [ Ledger.Delivery_conflict_rejected
        { skill_tool_use_id = "call-conflict"
        ; observed_agent_core_turn = 2
        ; _
        } ] -> ()
  | _ -> fail "conflicting delivery rejection did not survive readback"
;;

let test_action_before_delivery_is_durable_transition_evidence () =
  with_session @@ fun config trace_id _session_dir ->
  let value = activation ~skill_tool_use_id:"call-undelivered" () in
  (match Ledger.record ~config ~trace_id value with
   | Ok _ -> ()
   | Error error -> fail (Ledger.store_error_to_string error));
  let turn_ref = Ids.Turn_ref.make ~trace_id:"trace-one" ~absolute_turn:1 in
  (match
     Ledger.observe_action
       ~config
       ~trace_id
       ~turn_ref
       ~active_skill_tool_use_ids:[ "call-undelivered" ]
       ~action_tool_use_id:"call-too-early"
       ~tool_name:"keeper_time_now"
       ~runtime_id:"runtime-action"
       ~agent_core_turn:1
       ~observed_at:"2026-08-26T00:00:01Z"
   with
   | Error (Ledger.Action_before_delivery "call-undelivered") -> ()
   | Error error -> fail (Ledger.store_error_to_string error)
   | Ok _ -> fail "action before delivery was accepted");
  let persisted =
    match Ledger.load ~config ~trace_id with
    | Ok ledger -> ledger
    | Error error -> fail (Ledger.store_error_to_string error)
  in
  check int "persisted invalid transition" 1
    (Ledger.summarize persisted).invalid_transitions;
  match Ledger.transition_rejections persisted with
  | [ Ledger.Action_before_delivery_rejected
        { skill_tool_use_id = "call-undelivered"
        ; action_tool_use_id = "call-too-early"
        ; _
        } ] -> ()
  | _ -> fail "action-before-delivery rejection did not survive readback"
;;

let test_scoped_summaries_do_not_mix_runtime_or_exact_reference () =
  with_session @@ fun config trace_id _session_dir ->
  let first =
    activation
      ~skill_tool_use_id:"call-scope-a"
      ~runtime_id:"runtime-a"
      ~revision:'a'
      ()
  in
  let second =
    activation
      ~skill_tool_use_id:"call-scope-b"
      ~runtime_id:"runtime-b"
      ~revision:'b'
      ()
  in
  List.iter
    (fun value ->
       match Ledger.record ~config ~trace_id value with
       | Ok _ -> ()
       | Error error -> fail (Ledger.store_error_to_string error))
    [ first; second ];
  let turn_ref = Ids.Turn_ref.make ~trace_id:"trace-one" ~absolute_turn:1 in
  (match
     Ledger.observe_delivery
       ~config
       ~trace_id
       ~turn_ref
       ~tool_results:[ receipt "call-scope-a" ]
       ~boundary:(Ledger.Model_response { agent_core_turn = 1 })
       ~runtime_id:"runtime-a"
       ~delivered_at:"2026-08-26T00:00:01Z"
   with
   | Ok _ -> ()
   | Error error -> fail (Ledger.store_error_to_string error));
  (match
     Ledger.observe_delivery
       ~config
       ~trace_id
       ~turn_ref
       ~tool_results:[ receipt "call-scope-a" ]
       ~boundary:(Ledger.Model_response { agent_core_turn = 2 })
       ~runtime_id:"runtime-a"
       ~delivered_at:"2026-08-26T00:00:02Z"
   with
   | Error (Ledger.Conflicting_delivery _) -> ()
   | Error error -> fail (Ledger.store_error_to_string error)
   | Ok _ -> fail "scoped conflict was accepted");
  let ledger =
    match Ledger.load ~config ~trace_id with
    | Ok ledger -> ledger
    | Error error -> fail (Ledger.store_error_to_string error)
  in
  match Ledger.summarize_by_scope ledger with
  | [ first_scope; second_scope ] ->
    check string "first invocation runtime" "runtime-a"
      first_scope.scope.invocation_runtime_id;
    check int "first invocation" 1 first_scope.summary.instruction_invocations;
    check int "first provider delivery" 1
      first_scope.summary.instruction_provider_deliveries;
    check int "first rejection" 1 first_scope.summary.invalid_transitions;
    check
      (list (pair string int))
      "first delivery runtime counts"
      [ "runtime-a", 1 ]
      (List.map
         (fun (count : Ledger.runtime_count) -> count.runtime_id, count.count)
         first_scope.provider_delivery_runtime_counts);
    check string "second invocation runtime" "runtime-b"
      second_scope.scope.invocation_runtime_id;
    check int "second invocation" 1 second_scope.summary.instruction_invocations;
    check int "second provider delivery" 0
      second_scope.summary.instruction_provider_deliveries;
    check int "second rejection" 0 second_scope.summary.invalid_transitions;
    let first_json = Ledger.scoped_summary_to_yojson first_scope in
    check string "scope reference revision"
      (String.make 64 'a')
      Yojson.Safe.Util.(first_json |> member "scope" |> member "reference"
                        |> member "content_revision" |> to_string)
  | _ -> fail "scoped summaries did not preserve two exact scope tuples"
;;

let test_corrupt_ledger_is_typed () =
  with_session @@ fun config trace_id session_dir ->
  let path = Filename.concat session_dir "skill-activations.json" in
  let channel = open_out_bin path in
  output_string channel "not-json";
  close_out channel;
  match Ledger.load ~config ~trace_id with
  | Error (Ledger.Decode_failed _ as error) ->
    check string "typed cause code" "decode_failed.expected_object"
      (Ledger.store_error_code error)
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
      ; "transition_rejections", `List []
      ]
  in
  let revision =
    Digestif.SHA256.(digest_string (Yojson.Safe.to_string revision_input) |> to_hex)
  in
  let json =
    `Assoc
      [ "schema", `String "masc.skill-activations/v4"
      ; "workspace_key", `String workspace_key
      ; "session_id", `String session_id
      ; "revision", `String revision
      ; "activations", activations
      ; "transition_rejections", `List []
      ]
  in
  let workspace_root = Keeper_fs.session_base_dir config |> Unix.realpath in
  match
    Ledger.of_yojson
      ~expected_workspace_root:workspace_root
      ~expected_trace_id:trace
      json
  with
  | Error Ledger.Duplicate_skill_tool_use_id -> ()
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
  let invalid_tool_invocation =
    Ledger.Composition_invocation
      { origin = Ledger.Task_composition { task_ids = task_ids [ "task-001" ] }
      ; tool_name = "not/a/tool"
      }
  in
  match activation_result ~invocation:invalid_tool_invocation () with
  | Error (Ledger.Invalid_tool_name _) -> ()
  | Error _ | Ok _ -> fail "invalid composition tool name was not rejected"
;;

let test_task_id_sets_are_nonempty_and_unique () =
  (match Ledger.task_id_set_of_list [] with
   | Error Ledger.Empty_task_ids -> ()
   | Error _ | Ok _ -> fail "empty Task id set was accepted");
  let duplicate = task_id "task-001" in
  match Ledger.task_id_set_of_list [ duplicate; duplicate ] with
  | Error (Ledger.Duplicate_task_id "task-001") -> ()
  | Error _ | Ok _ -> fail "duplicate Task id set was accepted"
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

let test_projection_decoder_reuses_all_ledger_invariants () =
  with_session @@ fun config trace _session_dir ->
  let workspace_root = Keeper_fs.session_base_dir config |> Unix.realpath in
  let ledger = Ledger.empty ~workspace_root ~trace_id:trace in
  let json = Ledger.to_yojson ledger in
  (match Ledger.of_projection_yojson json with
   | Error error -> failf "canonical projection rejected: %s" (Ledger.decode_error_code error)
   | Ok decoded ->
     check string "workspace" (Ledger.workspace_key ledger)
       (Ledger.workspace_key decoded);
     check string "session"
       (Keeper_id.Trace_id.to_string trace)
       (Ledger.session_id decoded |> Keeper_id.Trace_id.to_string));
  let invalid_workspace =
    match json with
    | `Assoc fields ->
      `Assoc (("workspace_key", `String "not-a-digest")
              :: List.remove_assoc "workspace_key" fields)
    | other -> other
  in
  match Ledger.of_projection_yojson invalid_workspace with
  | Error (Ledger.Invalid_workspace_key _) -> ()
  | Error _ -> fail "invalid projection workspace returned wrong error"
  | Ok _ -> fail "invalid projection workspace was accepted"
;;

let () =
  run
    "keeper skill activation ledger"
    [ ( "session ledger"
      , [ test_case "empty, durable record, idempotent readback" `Quick
            test_empty_record_and_idempotent_readback
        ; test_case "exact identities and revisions remain distinct" `Quick
            test_same_name_different_identity_or_revision_is_distinct
        ; test_case "same Skill keeps distinct invocation activations" `Quick
            test_same_skill_different_invocations_are_distinct
        ; test_case "session origins survive durable roundtrip" `Quick
            test_session_origins_roundtrip
        ; test_case "delivery and later action share one exact chain" `Quick
            test_delivery_and_later_action_form_one_exact_chain
        ; test_case "demoted result is not delivery" `Quick
            test_demoted_skill_result_is_not_delivery_or_invalid_transition
        ; test_case "official client handoff is typed" `Quick
            test_official_client_handoff_delivers_in_invocation_turn
        ; test_case "cross-turn ToolResult replay is ignored" `Quick
            test_cross_turn_tool_result_replay_is_not_delivery_or_rejection
        ; test_case "conflicting delivery is durable evidence" `Quick
            test_conflicting_delivery_is_durable_transition_evidence
        ; test_case "action before delivery is durable evidence" `Quick
            test_action_before_delivery_is_durable_transition_evidence
        ; test_case "scoped summaries preserve exact runtime and reference" `Quick
            test_scoped_summaries_do_not_mix_runtime_or_exact_reference
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
        ; test_case "Task id sets are nonempty and unique" `Quick
            test_task_id_sets_are_nonempty_and_unique
        ; test_case "record rejects another trace" `Quick
            test_record_rejects_another_trace
        ; test_case "revision binds workspace and trace" `Quick
            test_revision_binds_workspace_and_trace
        ; test_case "projection decoder reuses all ledger invariants" `Quick
            test_projection_decoder_reuses_all_ledger_invariants
        ] )
    ]
;;
