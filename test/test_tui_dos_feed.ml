(** The DOS spectator's reading of the frame answer (#38424): a whole frame,
    an unchanged frame that reuses the held pixels, and the answers that
    cannot be read, which are errors rather than an empty machine. *)

open Alcotest
module Feed = Masc_tui_dos_feed
module Types = Masc_tui_types

let width = 4
let height = 2
let rgb = String.make (width * height * 3) '\042'

let answer ?(incarnation = "inc-1") ?(steps = 10) ?(controller = `String "keeper-a")
    pixels =
  `Assoc
    ([ ("loaded", `Bool true)
     ; ("incarnation", `String incarnation)
     ; ("steps", `Int steps)
     ; ("program", `String "SAN3.EXE")
     ; ("controller", controller)
     ; ("video_mode", `Int 18)
     ; ("width", `Int width)
     ; ("height", `Int height)
     ]
    @ pixels)
;;

let inline = [ ("pixels", `String "inline"); ("rgb_base64", `String (Base64.encode_string rgb)) ]
let unchanged = [ ("pixels", `String "unchanged") ]

let require = function Ok v -> v | Error e -> fail e
let loaded = function Some f -> f | None -> fail "no frame"
let is_error = function Error _ -> true | Ok _ -> false

let test_a_whole_frame_decodes () =
  let f = Feed.decode ~held:None (answer inline) |> require |> loaded in
  check string "pixels" rgb f.dos_rgb;
  check int "steps" 10 f.dos_steps;
  check (option string) "controller" (Some "keeper-a") f.dos_controller;
  check (option string) "program" (Some "SAN3.EXE") f.dos_program;
  let free = Feed.decode ~held:None (answer ~controller:`Null inline) |> require |> loaded in
  check (option string) "a free controller" None free.dos_controller
;;

let test_no_machine_is_none () =
  check bool "loaded:false is no frame" true
    (Feed.decode ~held:None (`Assoc [ ("loaded", `Bool false) ]) = Ok None)
;;

let test_unchanged_reuses_the_held_pixels () =
  let held = Feed.decode ~held:None (answer inline) |> require |> loaded in
  let again =
    Feed.decode ~held:(Some held) (answer ~controller:(`String "keeper-b") unchanged)
    |> require |> loaded
  in
  check bool "the same pixel bytes" true (again.dos_rgb == held.dos_rgb);
  check (option string) "fresh metadata" (Some "keeper-b") again.dos_controller
;;

let test_unchanged_for_another_frame_is_an_error () =
  let held = Feed.decode ~held:None (answer inline) |> require |> loaded in
  check bool "nothing held" true (is_error (Feed.decode ~held:None (answer unchanged)));
  check bool "another step" true
    (is_error (Feed.decode ~held:(Some held) (answer ~steps:11 unchanged)));
  check bool "another incarnation" true
    (is_error (Feed.decode ~held:(Some held) (answer ~incarnation:"inc-2" unchanged)))
;;

let test_unreadable_answers_are_errors () =
  let short = [ ("pixels", `String "inline"); ("rgb_base64", `String (Base64.encode_string "abc")) ] in
  check bool "short pixels" true (is_error (Feed.decode ~held:None (answer short)));
  check bool "unknown pixels kind" true
    (is_error (Feed.decode ~held:None (answer [ ("pixels", `String "delta") ])));
  check bool "not an object" true (is_error (Feed.decode ~held:None (`List [])));
  check bool "no loaded field" true (is_error (Feed.decode ~held:None (`Assoc [])))
;;

let test_the_query_names_the_held_frame () =
  check (list (pair string string)) "nothing held asks for the whole frame" []
    (Feed.known_query None);
  let held = Feed.decode ~held:None (answer inline) |> require |> loaded in
  check (list (pair string string)) "a held frame is named"
    [ ("incarnation", "inc-1"); ("steps", "10") ]
    (Feed.known_query (Some held))
;;

let () =
  run "masc_tui_dos_feed"
    [ ( "decode"
      , [ test_case "a whole frame decodes" `Quick test_a_whole_frame_decodes
        ; test_case "no machine is None" `Quick test_no_machine_is_none
        ; test_case "unchanged reuses the held pixels" `Quick
            test_unchanged_reuses_the_held_pixels
        ; test_case "unchanged for another frame is an error" `Quick
            test_unchanged_for_another_frame_is_an_error
        ; test_case "unreadable answers are errors" `Quick test_unreadable_answers_are_errors
        ; test_case "the query names the held frame" `Quick test_the_query_names_the_held_frame
        ] )
    ]
;;
