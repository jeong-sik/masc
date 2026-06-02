open Alcotest

(** Tool_name no longer has a [Masc_keeper] branch. Keeper lifecycle/tool
    execution names are outside the public MASC tool-name sum, so old
    [masc_keeper_*] strings must fail closed instead of re-entering typed
    dispatch through a compatibility branch. *)

let removed_masc_keeper_names =
  [ "masc_keeper_clear"
  ; "masc_keeper_compact"
  ; "masc_keeper_create_from_persona"
  ; "masc_keeper_msg"
  ; "masc_keeper_msg_result"
  ; "masc_keeper_persona_audit"
  ; "masc_keeper_repair"
  ; "masc_keeper_sandbox_start"
  ; "masc_keeper_sandbox_status"
  ; "masc_keeper_sandbox_stop"
  ; "masc_keeper_status"
  ]

let test_removed_masc_keeper_names_fail_closed () =
  List.iter
    (fun name ->
      check (option string)
        (Printf.sprintf "%s no longer parses through Tool_name" name)
        None
        (Option.map Tool_name.to_string (Tool_name.of_string name)))
    removed_masc_keeper_names

let test_current_masc_name_still_round_trips () =
  match Tool_name.of_string "masc_status" with
  | Some tool ->
    check string "masc_status roundtrip" "masc_status" (Tool_name.to_string tool)
  | None -> failf "masc_status should still parse"

let () =
  Alcotest.run
    "Tool_name removed keeper closure"
    [ ( "removed-masc-keeper"
      , [ test_case "removed names fail closed" `Quick
            test_removed_masc_keeper_names_fail_closed
        ; test_case "current masc name roundtrips" `Quick
            test_current_masc_name_still_round_trips
        ] )
    ]
