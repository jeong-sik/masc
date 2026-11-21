open Alcotest
open Masc
open Keeper_official_client_session_store

let temp_workspace prefix =
  let path = Filename.temp_file prefix "" in
  Unix.unlink path;
  Unix.mkdir path 0o755;
  path
;;

let cleanup_tree root =
  let rec remove path =
    if Sys.file_exists path
    then if Sys.is_directory path
      then (
        Sys.readdir path |> Array.iter (fun name -> remove (Filename.concat path name));
        Unix.rmdir path)
      else Unix.unlink path
  in
  try remove root with
  | _ -> ()
;;

let with_workspace prefix f =
  let base_path = temp_workspace prefix in
  Fun.protect ~finally:(fun () -> cleanup_tree base_path) (fun () -> f base_path)
;;

let test_turn_bridge_uncheckpointed_turns_and_resume_handoff () =
  with_workspace "masc-turn-bridge-" (fun base_path ->
    let keeper_name = "bridge-keeper" in
    let trace_id = "trace-bridge-1" in
    let keepers_dir = Common.keepers_runtime_dir_of_base ~base_path in
    let session_base_dir = Keeper_fs.session_store_path_for_base_path base_path in
    let session_dir = Filename.concat session_base_dir trace_id in
    let session = Keeper_context_runtime.create_session ~session_id:trace_id ~base_dir:session_base_dir in
    let t1 = Ids.Turn_ref.make ~trace_id ~absolute_turn:1 in
    let t2 = Ids.Turn_ref.make ~trace_id ~absolute_turn:2 in
    let t3 = Ids.Turn_ref.make ~trace_id ~absolute_turn:3 in
    let t4 = Ids.Turn_ref.make ~trace_id ~absolute_turn:4 in
    let append_turn ~turn_ref ~position ~recorded_at =
      Keeper_turn_boundaries.append
        ~keepers_dir
        ~keeper_id:keeper_name
        { recorded_at
        ; event =
            Keeper_turn_boundaries.Turn_ended
              { turn_ref
              ; task_context = Keeper_turn_task_context.Admission_not_recorded
              ; history_at_start = Keeper_turn_boundaries.Continued_history
              ; position
              }
        }
      |> Result.get_ok
    in
    let persist_turn ~turn_ref ~user_text ~assistant_text =
      Keeper_context_runtime.persist_message
        ~keeper_name
        ~turn_ref
        ~source:Keeper_types_support.Direct_user
        session
        (Agent_core.Types.user_msg user_text);
      Keeper_context_runtime.persist_message
        ~keeper_name
        ~turn_ref
        ~source:Keeper_types_support.Direct_assistant
        session
        (Agent_core.Types.assistant_msg assistant_text)
    in
    (* Turn 1: Codex settles session thread-codex-1 *)
    persist_turn ~turn_ref:t1 ~user_text:"codex ask 1" ~assistant_text:"codex reply 1";
    append_turn ~turn_ref:t1 ~position:Keeper_turn_boundaries.No_atom_history ~recorded_at:10.;
    Keeper_turn_bridge.record_official_client_settlement
      ~base_path
      ~keeper_name
      ~turn_ref:t1
      ~client_kind:Codex
      ~runtime_id:"codex.default"
      ~session_id:"thread-codex-1"
      ~updated_at:10.
    |> Result.get_ok;
    (* Turn 2: Agent_core checkpoints an Atom_history turn *)
    persist_turn ~turn_ref:t2 ~user_text:"core ask 2" ~assistant_text:"core reply 2";
    append_turn
      ~turn_ref:t2
      ~position:(Keeper_turn_boundaries.Atom_history { end_atom = 1; last_atom_digest = "d1" })
      ~recorded_at:20.;
    (* Turn 3: Claude_code runs with a tool observation *)
    persist_turn ~turn_ref:t3 ~user_text:"claude ask 3" ~assistant_text:"claude reply 3";
    Keeper_context_runtime.persist_tool_observation
      ~keeper_name
      ~turn_ref:t3
      session
      ~tool_name:"masc_status"
      ~outcome:Tool_result.Ok;
    append_turn ~turn_ref:t3 ~position:Keeper_turn_boundaries.No_atom_history ~recorded_at:30.;
    (* Turn Bridge for Agent_core switching in after Claude_code: should bridge ONLY Turn 3 *)
    let bridged =
      Keeper_turn_bridge.uncheckpointed_official_turns
        ~keepers_dir
        ~keeper_name
        ~trace_id
        ~session_dir
        ~existing_messages:[]
      |> Result.get_ok
    in
    check int "only trailing uncheckpointed Turn 3 bridged" 2 (List.length bridged);
    let combined_text =
      String.concat "\n" (List.map Agent_core.Types.text_of_message bridged)
    in
    check bool "bridged user prompt preserved" true (String_util.contains_substring combined_text "claude ask 3");
    check bool "bridged assistant reply preserved" true (String_util.contains_substring combined_text "claude reply 3");
    check bool "bridged tool observation preserved" true (String_util.contains_substring combined_text "masc_status (ok)");
    (* Deduplication on reload *)
    let deduped =
      Keeper_turn_bridge.uncheckpointed_official_turns
        ~keepers_dir
        ~keeper_name
        ~trace_id
        ~session_dir
        ~existing_messages:bridged
      |> Result.get_ok
    in
    check int "already bridged turn not duplicated" 0 (List.length deduped);
    (* Resuming Codex after Agent_core Turn 2 + Claude_code Turn 3 *)
    let handoff =
      Keeper_turn_bridge.intervening_context_for_official_resume
        ~base_path
        ~keeper_name
        ~trace_id
        ~client_kind:Codex
        ~runtime_id:"codex.default"
        ~session_id:"thread-codex-1"
      |> Result.get_ok
    in
    (match handoff with
     | None -> fail "expected intervening handoff for Codex resume"
     | Some text ->
       check bool "handoff includes Agent_core turn 2" true (String_util.contains_substring text "core ask 2");
       check bool "handoff includes Claude_code turn 3" true (String_util.contains_substring text "claude reply 3");
       check bool "handoff excludes Codex own turn 1" false (String_util.contains_substring text "codex ask 1"));
    (* Settling Codex Turn 4 advances its cursor so Turn 5 sees no intervening handoff *)
    persist_turn ~turn_ref:t4 ~user_text:"codex ask 4" ~assistant_text:"codex reply 4";
    append_turn ~turn_ref:t4 ~position:Keeper_turn_boundaries.No_atom_history ~recorded_at:40.;
    Keeper_turn_bridge.record_official_client_settlement
      ~base_path
      ~keeper_name
      ~turn_ref:t4
      ~client_kind:Codex
      ~runtime_id:"codex.default"
      ~session_id:"thread-codex-1"
      ~updated_at:40.
    |> Result.get_ok;
    let after_settle =
      Keeper_turn_bridge.intervening_context_for_official_resume
        ~base_path
        ~keeper_name
        ~trace_id
        ~client_kind:Codex
        ~runtime_id:"codex.default"
        ~session_id:"thread-codex-1"
      |> Result.get_ok
    in
    check bool "settled cursor leaves zero intervening turns" true (after_settle = None);
    (* History_restarted resets uncheckpointed official turns *)
    Keeper_turn_boundaries.append
      ~keepers_dir
      ~keeper_id:keeper_name
      { recorded_at = 50.
      ; event = Keeper_turn_boundaries.History_restarted { trace_id }
      }
    |> Result.get_ok;
    let after_restart =
      Keeper_turn_bridge.uncheckpointed_official_turns
        ~keepers_dir
        ~keeper_name
        ~trace_id
        ~session_dir
        ~existing_messages:[]
      |> Result.get_ok
    in
    check int "History_restarted resets uncheckpointed official turns" 0 (List.length after_restart));
  (* Repeated Turn_ended lines for the same turn_ref must not double-bridge. *)
  with_workspace "masc-turn-bridge-dedup-" (fun base_path ->
    let keeper_name = "bridge-dedup-keeper" in
    let trace_id = "trace-bridge-dedup" in
    let keepers_dir = Common.keepers_runtime_dir_of_base ~base_path in
    let session_base_dir = Keeper_fs.session_store_path_for_base_path base_path in
    let session_dir = Filename.concat session_base_dir trace_id in
    let session = Keeper_context_runtime.create_session ~session_id:trace_id ~base_dir:session_base_dir in
    let t1 = Ids.Turn_ref.make ~trace_id ~absolute_turn:1 in
    Keeper_context_runtime.persist_message
      ~keeper_name
      ~turn_ref:t1
      ~source:Keeper_types_support.Direct_user
      session
      (Agent_core.Types.user_msg "ask once");
    Keeper_context_runtime.persist_message
      ~keeper_name
      ~turn_ref:t1
      ~source:Keeper_types_support.Direct_assistant
      session
      (Agent_core.Types.assistant_msg "reply once");
    let append recorded_at =
      Keeper_turn_boundaries.append
        ~keepers_dir
        ~keeper_id:keeper_name
        { recorded_at
        ; event =
            Keeper_turn_boundaries.Turn_ended
              { turn_ref = t1
              ; task_context = Keeper_turn_task_context.Admission_not_recorded
              ; history_at_start = Keeper_turn_boundaries.Continued_history
              ; position = Keeper_turn_boundaries.No_atom_history
              }
        }
      |> Result.get_ok
    in
    append 10.;
    append 11.;
    let bridged =
      Keeper_turn_bridge.uncheckpointed_official_turns
        ~keepers_dir
        ~keeper_name
        ~trace_id
        ~session_dir
        ~existing_messages:[]
      |> Result.get_ok
    in
    check int "duplicate pending turn_ref is bridged only once" 2 (List.length bridged))
;;

let () =
  run
    "official_client_session_store_turn_boundaries"
    [ ( "durable owner"
      , [ test_case
            "turn bridge projects uncheckpointed turns and resume handoff"
            `Quick
            test_turn_bridge_uncheckpointed_turns_and_resume_handoff
        ] )
    ]
;;
