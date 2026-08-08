(** [MASC_USE_H2] carries a closed vocabulary.

    An unrecognized value used to become [Unknown_h2_mode raw]: the server ran
    it as Auto without reporting anything, and h2_mode_to_string handed the raw
    text back out, so it reached the dashboard as http2.listener_mode. The
    panel computes multiplex_ready as [listener_mode <> "h1_only"], so a typo
    was published as a mode and read as multiplexing-ready. *)

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
    ; "false", "h1_only"
    ; "1", "h2_only"
    ; "true", "h2_only"
    ; "  H2_Only  ", "h2_only"
    ]
;;

(* The output vocabulary is what the dashboard receives, so it must stay
   closed whatever the operator typed. *)
let unknown_input_stays_in_vocabulary () =
  List.iter
    (fun raw ->
       let out = mode raw in
       check
         bool
         ("in vocabulary: " ^ raw)
         true
         (List.mem out [ "auto"; "h1_only"; "h2_only" ]))
    [ "h2c"; "prior_knowledge"; "h2"; ""; "yes"; "H1" ]
;;

(* Auto is the documented fallback, and h1_only is what multiplex_ready keys
   on — a typo must not land there by accident. *)
let unknown_reads_as_auto () =
  check string "typo" "auto" (mode "h2c");
  check string "empty" "auto" (mode "")
;;

let () =
  run
    "h2_mode_vocabulary"
    [ ( "vocabulary"
      , [ test_case "accepted spellings map as documented" `Quick accepted_spellings
        ; test_case "unknown input stays in vocabulary" `Quick unknown_input_stays_in_vocabulary
        ; test_case "unknown input reads as auto" `Quick unknown_reads_as_auto
        ] )
    ]
;;
