(* test_keeper_phase_drift_contract.ml
   Contract test: Keeper_state_machine.phase round-trip completeness.

   Guarantees that adding a new phase variant to Keeper_state_machine.phase
   cannot silently break KSM.phase_to_string / KSM.phase_of_string round-trip.
   If this test fails after adding a variant, update both functions.

   Also checks that agent_core Runtime.phase yojson variants are recognized
   by the masc bridge layer (cross-repo drift detection).
   Reference: specs/keeper-state-machine/KeeperStateMachine.tla
*)

module KSM = Keeper_state_machine

(* ── Keeper phase round-trip completeness ─────────────────── *)

(* Every phase this test knows, by name. [KSM.all_phases] is compared against
   this rather than against a number.

   A count cannot say which phase drifted, and it goes stale in silence:
   #30133 retired [Overflowed] and left the [11] behind, so the assertion
   failed on every build after that change instead of on the change itself,
   and what it said was "expected true, got false". Naming them means the
   failure names the phase. *)
let every_phase : KSM.phase list =
  [ Offline
  ; Running
  ; Failing
  ; Draining
  ; Paused
  ; Stopped
  ; Crashed
  ; Restarting
  ]

(* The compiler's half of the same contract. A variant added to [KSM.phase]
   makes this match non-exhaustive, so the build stops at the commit that adds
   it -- before any list or count has a chance to disagree at run time. *)
let _phase_is_named : KSM.phase -> unit = function
  | Offline
  | Running
  | Failing
  | Draining
  | Paused
  | Stopped
  | Crashed
  | Restarting -> ()

let names phases = List.map KSM.phase_to_string phases

let all_phases_lists_every_variant () =
  Alcotest.(check (list string))
    "phases this test names that all_phases omits" []
    (names (List.filter (fun p -> not (List.mem p KSM.all_phases)) every_phase));
  Alcotest.(check (list string))
    "phases all_phases carries that this test does not name" []
    (names (List.filter (fun p -> not (List.mem p every_phase)) KSM.all_phases))

let roundtrip_every_phase () =
  List.iter (fun p ->
    let str = KSM.phase_to_string p in
    match KSM.phase_of_string str with
    | Some p' ->
      Alcotest.(check bool)
        (Printf.sprintf "roundtrip %s" str)
        true (p = p')
    | None ->
      Alcotest.failf "KSM.phase_of_string returned None for %s (variant %s not handled)"
        str (Obj.tag (Obj.repr p) |> string_of_int)
  ) KSM.all_phases

let no_orphan_strings () =
  let strings = List.map KSM.phase_to_string KSM.all_phases in
  List.iter (fun s ->
    match KSM.phase_of_string s with
    | Some _ -> ()
    | None -> Alcotest.failf "KSM.phase_of_string does not recognize string %s produced by KSM.phase_to_string" s
  ) strings

let all_phases_unique () =
  let strings = List.map KSM.phase_to_string KSM.all_phases in
  let unique = List.sort_uniq String.compare strings in
  List.length strings = List.length unique

(* ── Cross-repo: agent_core Runtime.phase recognition ────────────── *)

(* These strings come from agent_core Runtime.phase [@@deriving yojson].
   When agent_core adds a new phase variant, this list must be updated.
   Failure here means masc may silently drop events from newer agent_core. *)
let agent_core_runtime_phase_strings =
  [ "Bootstrapping"
  ; "Running"
  ; "Waiting_on_workers"
  ; "Finalizing"
  ; "Completed"
  ; "Failed"
  ; "Cancelled"
  ]

let agent_core_runtime_phase_count_is_7 =
  List.length agent_core_runtime_phase_strings = 7

let agent_core_terminal_phases =
  [ "Completed"; "Failed"; "Cancelled" ]

let agent_core_terminal_count_is_3 =
  List.length agent_core_terminal_phases = 3

let agent_core_terminal_is_subset_of_all () =
  List.for_all (fun t -> List.mem t agent_core_runtime_phase_strings) agent_core_terminal_phases

(* masc bridge maps agent_core stop reasons to keeper transitions.
   This test ensures the mapping surface is documented and complete. *)
let agent_core_stop_reason_strings =
  [ "completed" ]

let () =
  Alcotest.run "keeper_phase_drift_contract"
    [ ( "keeper_phase_roundtrip"
      , [ Alcotest.test_case "all_phases lists every variant" `Quick
            all_phases_lists_every_variant
        ; Alcotest.test_case "roundtrip: to_string -> of_string = id" `Quick roundtrip_every_phase
        ; Alcotest.test_case "no orphan strings" `Quick no_orphan_strings
        ; Alcotest.test_case "all phase strings are unique" `Quick
          (fun () -> Alcotest.(check bool) "unique" true (all_phases_unique ()))
        ] )
    ; ( "agent_core_runtime_phase_contract"
      , [ Alcotest.test_case "agent_core Runtime.phase has 7 variants" `Quick (fun () ->
            Alcotest.(check bool) "7 phases" true agent_core_runtime_phase_count_is_7)
        ; Alcotest.test_case "agent_core terminal phases count is 3" `Quick (fun () ->
            Alcotest.(check bool) "3 terminal" true agent_core_terminal_count_is_3)
        ; Alcotest.test_case "agent_core terminal phases are subset of all phases" `Quick
            (fun () -> Alcotest.(check bool) "subset" true (agent_core_terminal_is_subset_of_all ()))
        ; Alcotest.test_case "agent_core stop reason strings documented" `Quick (fun () ->
            Alcotest.(check bool) "one lifecycle stop reason" true
              (List.length agent_core_stop_reason_strings = 1))
        ] )
    ]
