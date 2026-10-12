open Alcotest

(* 2026-09-23T00:31:39Z, the instant the live screen below was drawn. *)
let now = 1790123499.

let text = Masc_tui_wire_age.text ~now

let test_a_fallback_neutralises_an_escape () =
  let drawn = text "\x1b[31mnot-a-time" in
  check bool
    (Printf.sprintf "%S carries no ESC byte" drawn)
    false
    (String.exists (fun c -> Char.code c = 0x1b) drawn)

let () =
  run "tui wire age"
    [ ( "how long ago a wire stamp was"
      , [ test_case "a fallback neutralises an escape" `Quick
            test_a_fallback_neutralises_an_escape
        ] )
    ]
