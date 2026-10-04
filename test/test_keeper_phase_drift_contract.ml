(* test_keeper_phase_drift_contract.ml
   Contract test: Keeper_state_machine.phase round-trip completeness.

   Guarantees that adding a new phase variant to Keeper_state_machine.phase
   cannot silently break KSM.phase_to_string / KSM.phase_of_string round-trip.
   If this test fails after adding a variant, update both functions.

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

let all_phases_unique () =
  let strings = List.map KSM.phase_to_string KSM.all_phases in
  let unique = List.sort_uniq String.compare strings in
  List.length strings = List.length unique

let () =
  Alcotest.run "keeper_phase_drift_contract"
    [ ( "keeper_phase_roundtrip"
      , [ Alcotest.test_case "all_phases lists every variant" `Quick
            all_phases_lists_every_variant
        ; Alcotest.test_case "roundtrip: to_string -> of_string = id" `Quick roundtrip_every_phase
        ; Alcotest.test_case "all phase strings are unique" `Quick
          (fun () -> Alcotest.(check bool) "unique" true (all_phases_unique ()))
        ] )
    ]
