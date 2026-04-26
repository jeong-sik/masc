open Alcotest
open Masc_mcp

let test_known_sidecars_have_dirs () =
  List.iter
    (fun name ->
       match Doctor_dispatch.sidecar_dir name with
       | Some _ -> ()
       | None -> failf "known sidecar %S has no directory mapping" name)
    Doctor_dispatch.known_sidecars
;;

let test_unknown_sidecar_returns_none () =
  (check (option string)) "unknown" None (Doctor_dispatch.sidecar_dir "xyz");
  (check (option string)) "empty" None (Doctor_dispatch.sidecar_dir "")
;;

let test_discord_mapping () =
  (check (option string))
    "discord"
    (Some "sidecars/discord-bot")
    (Doctor_dispatch.sidecar_dir "discord")
;;

let test_cli_mapping () =
  (check (option string))
    "cli"
    (Some "sidecars/cli-connector")
    (Doctor_dispatch.sidecar_dir "cli")
;;

let test_known_summary_lists_all () =
  let parts = String.split_on_char '|' Doctor_dispatch.known_summary in
  (check int)
    "summary length matches known_sidecars"
    (List.length Doctor_dispatch.known_sidecars)
    (List.length parts);
  List.iter
    (fun name -> if not (List.mem name parts) then failf "known_summary missing %S" name)
    Doctor_dispatch.known_sidecars
;;

let test_aggregate_empty_is_zero () =
  (check int) "empty" 0 (Doctor_dispatch.aggregate_exit_code [])
;;

let test_aggregate_all_ok () =
  (check int) "all ok" 0 (Doctor_dispatch.aggregate_exit_code [ 0; 0; 0 ])
;;

let test_aggregate_warn_wins_over_ok () =
  (check int) "warn dominates ok" 1 (Doctor_dispatch.aggregate_exit_code [ 0; 1; 0 ])
;;

let test_aggregate_error_wins_over_warn () =
  (check int) "error dominates warn" 2 (Doctor_dispatch.aggregate_exit_code [ 1; 2; 1 ])
;;

let test_aggregate_unknown_treated_as_error () =
  (check int) "signal/junk → error" 2 (Doctor_dispatch.aggregate_exit_code [ 0; 137 ])
;;

let () =
  run
    "doctor_dispatch"
    [ ( "mapping"
      , [ test_case "all known sidecars resolve" `Quick test_known_sidecars_have_dirs
        ; test_case
            "unknown sidecar returns None"
            `Quick
            test_unknown_sidecar_returns_none
        ; test_case "discord maps to discord-bot" `Quick test_discord_mapping
        ; test_case "cli maps to cli-connector" `Quick test_cli_mapping
        ] )
    ; ( "summary"
      , [ test_case "known_summary lists all names" `Quick test_known_summary_lists_all ]
      )
    ; ( "aggregate_exit_code"
      , [ test_case "empty → 0" `Quick test_aggregate_empty_is_zero
        ; test_case "all ok → 0" `Quick test_aggregate_all_ok
        ; test_case "warn > ok" `Quick test_aggregate_warn_wins_over_ok
        ; test_case "error > warn" `Quick test_aggregate_error_wins_over_warn
        ; test_case "unknown rc → error" `Quick test_aggregate_unknown_treated_as_error
        ] )
    ]
;;
