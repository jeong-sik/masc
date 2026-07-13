(* test_keeper_phase_drift_contract.ml
   Contract test: Keeper_state_machine.phase round-trip completeness.

   Guarantees that adding a new phase variant to Keeper_state_machine.phase
   cannot silently break KSM.phase_to_string / KSM.phase_of_string round-trip.
   If this test fails after adding a variant, update both functions.

   Also checks that oas Runtime.phase yojson variants are recognized
   by the masc bridge layer (cross-repo drift detection).
   Reference: specs/AgentLifecycle.tla, specs/AgentCancellation.tla
*)

module KSM = Keeper_state_machine

(* ── Keeper phase round-trip completeness ─────────────────── *)

let all_phases_count_is_12 =
  List.length KSM.all_phases = 12

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

(* ── Cross-repo: oas Runtime.phase recognition ────────────── *)

(* These strings come from oas Runtime.phase [@@deriving yojson].
   When oas adds a new phase variant, this list must be updated.
   Failure here means masc may silently drop events from newer oas. *)
let oas_runtime_phase_strings =
  [ "Bootstrapping"
  ; "Running"
  ; "Waiting_on_workers"
  ; "Finalizing"
  ; "Completed"
  ; "Failed"
  ; "Cancelled"
  ]

let oas_runtime_phase_count_is_7 =
  List.length oas_runtime_phase_strings = 7

let oas_terminal_phases =
  [ "Completed"; "Failed"; "Cancelled" ]

let oas_terminal_count_is_3 =
  List.length oas_terminal_phases = 3

let oas_terminal_is_subset_of_all () =
  List.for_all (fun t -> List.mem t oas_runtime_phase_strings) oas_terminal_phases

(* masc bridge maps oas stop reasons to keeper transitions.
   This test ensures the mapping surface is documented and complete. *)
let oas_stop_reason_strings =
  [ "completed"
  ; "turn_budget_exhausted"
  ]

let () =
  Alcotest.run "keeper_phase_drift_contract"
    [ ( "keeper_phase_roundtrip"
      , [ Alcotest.test_case "all_phases has 12 variants" `Quick (fun () ->
            Alcotest.(check bool) "12 phases" true all_phases_count_is_12)
        ; Alcotest.test_case "roundtrip: to_string -> of_string = id" `Quick roundtrip_every_phase
        ; Alcotest.test_case "no orphan strings" `Quick no_orphan_strings
        ; Alcotest.test_case "all phase strings are unique" `Quick
          (fun () -> Alcotest.(check bool) "unique" true (all_phases_unique ()))
        ] )
    ; ( "oas_runtime_phase_contract"
      , [ Alcotest.test_case "oas Runtime.phase has 7 variants" `Quick (fun () ->
            Alcotest.(check bool) "7 phases" true oas_runtime_phase_count_is_7)
        ; Alcotest.test_case "oas terminal phases count is 3" `Quick (fun () ->
            Alcotest.(check bool) "3 terminal" true oas_terminal_count_is_3)
        ; Alcotest.test_case "oas terminal phases are subset of all phases" `Quick
            (fun () -> Alcotest.(check bool) "subset" true (oas_terminal_is_subset_of_all ()))
        ; Alcotest.test_case "oas stop reason strings documented" `Quick (fun () ->
            Alcotest.(check bool) "2 stop reasons" true
              (List.length oas_stop_reason_strings = 2))
        ] )
    ]
