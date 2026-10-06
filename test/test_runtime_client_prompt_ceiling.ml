open Alcotest
module Ceiling = Runtime_client_prompt_ceiling

let test_antigravity_follows_a_small_window () =
  check int "131,072 tokens allow twice that many bytes" 262_144
    (Ceiling.antigravity_start_prompt_bytes ~max_context:131_072)
;;

let test_antigravity_stops_at_the_proven_size () =
  check int "a 1,048,576-token window is cut to the measured success point"
    Ceiling.antigravity_proven_start_prompt_bytes
    (Ceiling.antigravity_start_prompt_bytes ~max_context:1_048_576);
  check int "so is a window far beyond it"
    Ceiling.antigravity_proven_start_prompt_bytes
    (Ceiling.antigravity_start_prompt_bytes ~max_context:Int.max_int)
;;

let test_antigravity_ceiling_never_exceeds_the_window () =
  List.iter
    (fun max_context ->
       let bytes = Ceiling.antigravity_start_prompt_bytes ~max_context in
       check bool
         (Printf.sprintf "window %d" max_context)
         true
         (bytes <= max_context * Ceiling.bytes_per_window_token))
    [ 1; 4_096; 131_072; 1_048_576 ]
;;

let () =
  run
    "runtime_client_prompt_ceiling"
    [ ( "antigravity"
      , [ test_case "follows a small window" `Quick test_antigravity_follows_a_small_window
        ; test_case "stops at the proven size" `Quick test_antigravity_stops_at_the_proven_size
        ; test_case "never exceeds the window" `Quick
            test_antigravity_ceiling_never_exceeds_the_window
        ] )
    ]
;;
