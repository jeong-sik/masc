
let get_ok = function
  | Ok x -> x
  | Error e -> Alcotest.fail (Trpg.Engine_state_machine.string_of_transition_error e)

let test_phase_transitions () =
  let st0 =
    Trpg.Engine_types.initial_room_state
      ~room_id:"room-1"
      ~scenario_id:"negotiation-v1"
      ~dm_control:Trpg.Engine_types.Keeper
      ~turn_order:["a"; "b"; "c"]
  in
  let st1 =
    st0
    |> fun s -> Trpg.Engine_state_machine.transition_phase s Trpg.Engine_types.Briefing
    |> get_ok
  in
  Alcotest.(check string)
    "lobby->briefing"
    "briefing"
    (Trpg.Engine_types.string_of_phase st1.phase);

  match Trpg.Engine_state_machine.transition_phase st1 Trpg.Engine_types.Ended with
  | Ok _ -> Alcotest.fail "briefing->end should fail"
  | Error _ -> ()

let test_turn_rotation () =
  let base =
    Trpg.Engine_types.initial_room_state
      ~room_id:"room-2"
      ~scenario_id:"trust-public-goods-v1"
      ~dm_control:Trpg.Engine_types.Human
      ~turn_order:["p1"; "p2"; "p3"]
  in
  let st_round =
    base
    |> fun s -> Trpg.Engine_state_machine.transition_phase s Trpg.Engine_types.Briefing
    |> get_ok
    |> fun s -> Trpg.Engine_state_machine.transition_phase s Trpg.Engine_types.Round
    |> get_ok
  in

  let st1 = Trpg.Engine_state_machine.next_turn st_round |> get_ok in
  Alcotest.(check (option string))
    "turn1 actor"
    (Some "p1")
    (Trpg.Engine_state_machine.current_turn_actor st1);
  Alcotest.(check int) "round stays" 1 st1.round;

  let st2 = Trpg.Engine_state_machine.next_turn st1 |> get_ok in
  Alcotest.(check (option string))
    "turn2 actor"
    (Some "p2")
    (Trpg.Engine_state_machine.current_turn_actor st2);
  Alcotest.(check int) "round stays 2nd turn" 1 st2.round;

  let st3 = Trpg.Engine_state_machine.next_turn st2 |> get_ok in
  Alcotest.(check (option string))
    "turn3 actor"
    (Some "p3")
    (Trpg.Engine_state_machine.current_turn_actor st3);
  Alcotest.(check int) "round still 1 at last actor" 1 st3.round;

  let st4 = Trpg.Engine_state_machine.next_turn st3 |> get_ok in
  Alcotest.(check (option string))
    "turn4 wraps actor"
    (Some "p1")
    (Trpg.Engine_state_machine.current_turn_actor st4);
  Alcotest.(check int) "round increments on wrap" 2 st4.round

let test_empty_turn_order () =
  let st =
    Trpg.Engine_types.initial_room_state
      ~room_id:"room-3"
      ~scenario_id:"rumor-propagation-v1"
      ~dm_control:Trpg.Engine_types.Keeper
      ~turn_order:[]
    |> fun s -> Trpg.Engine_state_machine.transition_phase s Trpg.Engine_types.Briefing
    |> get_ok
    |> fun s -> Trpg.Engine_state_machine.transition_phase s Trpg.Engine_types.Round
    |> get_ok
  in
  match Trpg.Engine_state_machine.next_turn st with
  | Ok _ -> Alcotest.fail "empty turn order should fail"
  | Error Trpg.Engine_state_machine.Empty_turn_order -> ()
  | Error e ->
      Alcotest.failf
        "expected Empty_turn_order, got: %s"
        (Trpg.Engine_state_machine.string_of_transition_error e)

let test_keeper_dm_player_round_orchestration () =
  let players = [ "player-1"; "player-2"; "player-3"; "player-4" ] in
  let base =
    Trpg.Engine_types.initial_room_state
      ~room_id:"room-orch-1"
      ~scenario_id:"negotiation-v1"
      ~dm_control:Trpg.Engine_types.Keeper
      ~turn_order:players
  in
  let st_round =
    base
    |> fun s -> Trpg.Engine_state_machine.transition_phase s Trpg.Engine_types.Briefing
    |> get_ok
    |> fun s -> Trpg.Engine_state_machine.transition_phase s Trpg.Engine_types.Round
    |> get_ok
  in
  let expected =
    [
      ("player-1", 1);
      ("player-2", 1);
      ("player-3", 1);
      ("player-4", 1);
      ("player-1", 2);
      ("player-2", 2);
    ]
  in
  let _final_state =
    List.fold_left
      (fun st (expected_actor, expected_round) ->
        let next = Trpg.Engine_state_machine.next_turn st |> get_ok in
        Alcotest.(check (option string))
          "current actor sequence"
          (Some expected_actor)
          (Trpg.Engine_state_machine.current_turn_actor next);
        Alcotest.(check int) "round progression" expected_round next.round;
        next)
      st_round
      expected
  in
  ()

let test_human_dm_phase_orchestration_path () =
  let base =
    Trpg.Engine_types.initial_room_state
      ~room_id:"room-orch-2"
      ~scenario_id:"trust-public-goods-v1"
      ~dm_control:Trpg.Engine_types.Human
      ~turn_order:[ "p1"; "p2" ]
  in
  let st_briefing =
    Trpg.Engine_state_machine.transition_phase base Trpg.Engine_types.Briefing
    |> get_ok
  in
  let st_round =
    Trpg.Engine_state_machine.transition_phase st_briefing Trpg.Engine_types.Round
    |> get_ok
  in
  let st_resolution =
    Trpg.Engine_state_machine.transition_phase st_round Trpg.Engine_types.Resolution
    |> get_ok
  in
  let st_end =
    Trpg.Engine_state_machine.transition_phase st_resolution Trpg.Engine_types.Ended
    |> get_ok
  in
  Alcotest.(check string)
    "ended phase"
    "end"
    (Trpg.Engine_types.string_of_phase st_end.phase);
  match Trpg.Engine_state_machine.transition_phase st_briefing Trpg.Engine_types.Ended with
  | Ok _ -> Alcotest.fail "briefing->end direct transition should fail"
  | Error _ -> ()

let () =
  Alcotest.run "TRPG Engine State Machine"
    [
      ("phase", [ Alcotest.test_case "transition rules" `Quick test_phase_transitions ]);
      ("turn", [ Alcotest.test_case "round-robin + round increment" `Quick test_turn_rotation ]);
      ( "orchestration",
        [
          Alcotest.test_case
            "keeper DM + players multi-round sequence"
            `Quick
            test_keeper_dm_player_round_orchestration;
          Alcotest.test_case
            "human DM phase path"
            `Quick
            test_human_dm_phase_orchestration_path;
        ] );
      ("guard", [ Alcotest.test_case "empty turn order" `Quick test_empty_turn_order ]);
    ]
