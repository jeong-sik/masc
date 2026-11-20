(* The decisions the Overview's operator-action card rests on: which section
   a wire name stands for, and that a name this build does not know is kept
   as received instead of being taken for a known one. The labels are an
   exhaustive match the compiler checks; the words are not tested. *)

module Section = Masc_tui_health_section

(* The four the QA sweep saw drawn as wire identifiers, and the three the
   card already named. *)
let reported_on_the_overview =
  [ "keeper_fleet_safety"
  ; "keeper_reaction_ledger"
  ; "keeper_event_queue"
  ; "keeper_waiting_inventory"
  ; "keeper_memory_execution"
  ; "skill_catalog"
  ; "keeper_config_schema"
  ]

(* Every section the server's health rollup reads a status from
   (lib/server/server_health_rollup.ml), and the two it rolls up apart. *)
let rolled_up =
  reported_on_the_overview
  @ [ "fd_observation"; "fd_accountant"; "provider_connection_cache"; "disk_observation"
    ; "keeper_identity_drift"; "keeper_memory_attention"; "publication_recovery_activation"
    ; "keeper_owner"; "keeper_board_event_collection"; "keeper_hitl_gate"; "typesafeai"
    ; "keeper_terminal_effect_policy"; "keeper_observability_artifacts"
    ; "tla_source_observation"; "auxiliary_startup"; "paused_keepers"
    ; "runtime_startup_degradation" ]

let test_every_rolled_up_name_is_a_section () =
  List.iter
    (fun name ->
      match Section.of_wire name with
      | Ok section ->
          Alcotest.(check string) (name ^ " round-trips") name (Section.wire_name section)
      | Error _ -> Alcotest.failf "%s is not decoded to a section" name)
    rolled_up

(* The defect the decoder exists for: a known section drawn as the wire
   identifier it arrived as. A label is checked only against that identifier,
   in both languages, never against a wording. *)
let test_no_known_section_is_labelled_with_its_wire_name () =
  List.iter
    (fun name ->
      match Section.of_wire name with
      | Ok section ->
          List.iter
            (fun ko ->
              Alcotest.(check bool)
                (Printf.sprintf "%s (ko=%b) is not drawn as received" name ko)
                false
                (String.equal (Section.label ~ko section) (Section.wire_name section)))
            [ true; false ]
      | Error _ -> Alcotest.failf "%s is not decoded to a section" name)
    rolled_up

let test_an_unknown_name_is_kept_as_received () =
  let received = "keeper_new_section_from_a_later_server" in
  Alcotest.(check bool) "unknown names are not taken for a known section" true
    (match Section.of_wire received with
     | Error kept -> String.equal kept received
     | Ok _ -> false)

let test_korean_labels_translate_sections () =
  List.iter
    (fun section ->
      Alcotest.(check bool)
        (Printf.sprintf "%s has distinct Korean label" (Section.wire_name section))
        true
        (not (String.equal (Section.label ~ko:true section) (Section.label ~ko:false section))))
    Section.
      [ Fd_observation; Fd_accountant; Provider_connection_cache; Disk_observation
      ; Keeper_fleet_safety; Keeper_identity_drift; Keeper_memory_attention
      ; Publication_recovery_activation; Keeper_reaction_ledger; Keeper_owner
      ; Keeper_board_event_collection; Keeper_hitl_gate
      ; Keeper_terminal_effect_policy; Keeper_observability_artifacts
      ; Tla_source_observation; Auxiliary_startup; Paused_keepers
      ; Runtime_startup_degradation ]

let () =
  Alcotest.run "tui_health_section"
    [ ( "decode"
      , [ Alcotest.test_case "every rolled-up name is a section" `Quick
            test_every_rolled_up_name_is_a_section
        ; Alcotest.test_case "no known section is labelled with its wire name" `Quick
            test_no_known_section_is_labelled_with_its_wire_name
        ; Alcotest.test_case "an unknown name is kept as received" `Quick
            test_an_unknown_name_is_kept_as_received
        ; Alcotest.test_case "Korean labels translate overview health sections" `Quick
            test_korean_labels_translate_sections
        ] )
    ]
