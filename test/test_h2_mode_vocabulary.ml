(** [MASC_USE_H2] carries a closed vocabulary. *)

open Alcotest

module T = Env_config.Transport

let mode s = T.h2_mode_to_string (T.h2_mode_of_string s)

let accepted_spellings () =
  List.iter
    (fun (raw, expected) -> check string raw expected (mode raw))
    [ "auto", "auto"
    ; "h1_only", "h1_only"
    ; "h2_only", "h2_only"
    ; "0", "h1_only"
    ; "1", "h2_only"
    ]
;;

let invalid_values_are_rejected () =
  List.iter
    (fun raw ->
       check_raises
         ("reject " ^ raw)
         (Env_config_core.Config_error
            (Printf.sprintf
               "malformed env MASC_USE_H2=%S (expected auto|0|h1_only|1|h2_only)"
               raw))
         (fun () -> ignore (T.h2_mode_of_string raw)))
    [ "h2c"
    ; "prior_knowledge"
    ; "h2"
    ; ""
    ; "yes"
    ; "H1"
    ; "true"
    ; "false"
    ; "  H2_Only  "
    ]
;;

let with_env name value_opt f =
  let previous = Sys.getenv_opt name in
  Fun.protect
    ~finally:(fun () ->
      match previous with
      | Some value -> Unix.putenv name value
      | None -> Unix.unsetenv name)
    (fun () ->
      (match value_opt with
       | Some value -> Unix.putenv name value
       | None -> Unix.unsetenv name);
      f ())
;;

let actual_env_admission_is_fail_closed () =
  with_env "MASC_USE_H2" None (fun () ->
    check string "absent defaults" "auto" (T.use_h2 () |> T.h2_mode_to_string));
  List.iter
    (fun raw ->
       with_env "MASC_USE_H2" (Some raw) (fun () ->
         check_raises
           ("env rejects " ^ raw)
           (Env_config_core.Config_error
              (Printf.sprintf
                 "malformed env MASC_USE_H2=%S (expected auto|0|h1_only|1|h2_only)"
                 raw))
           (fun () -> ignore (T.use_h2 ()))))
    [ ""; "h2c" ]
;;

let () =
  run
    "h2_mode_vocabulary"
    [ ( "vocabulary"
      , [ test_case "accepted spellings map as documented" `Quick accepted_spellings
        ; test_case "invalid values are rejected" `Quick invalid_values_are_rejected
        ; test_case "actual env admission is fail closed" `Quick
            actual_env_admission_is_fail_closed
        ] )
    ]
;;
