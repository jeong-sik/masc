open Alcotest

module Tool_detail = Masc_tui_tool_detail

let marked =
  { Tool_detail.branch = "<br>"
  ; label = "<lab>"
  ; separator = "<sep>"
  ; key = "<key>"
  ; string_ = "<str>"
  ; number = "<num>"
  ; literal = "<lit>"
  ; punctuation = "<pun>"
  ; note = "<note>"
  ; reset = "<->"
  }

let holds needle haystack =
  let n = String.length needle and h = String.length haystack in
  let rec scan i = i + n <= h && (String.equal (String.sub haystack i n) needle || scan (i + 1)) in
  n = 0 || scan 0

let test_a_value_is_painted_after_it_is_made_safe () =
  (* The sweep that makes a value terminal-safe replaces control bytes with
     spaces, and an escape code is control bytes. Painting a sanitised string
     keeps the marker; sanitising a painted one would eat it. The value here
     carries a real escape, which must not survive as one. *)
  let rendered =
    Tool_detail.tree ~palette:marked
      [ { Tool_detail.fd_label = "state"
        ; fd_value = Tool_detail.Text "RET\027[31mURNED"
        ; fd_tone = "<tone>"
        } ]
  in
  match rendered with
  | [ row ] ->
    check bool "the field's own tone is applied" true (holds "<tone>" row);
    check bool "the value's escape did not survive" false
      (String.contains row '\027')
  | _ -> fail "expected one row"

let fold = { Tool_detail.fold_rows = 8; fold_note = Printf.sprintf "+%d more" }

let test_a_payload_that_does_not_parse_is_terminal_safe () =
  let escape = "\027[31m" in
  check bool "an escape does not survive a payload that is not JSON" false
    (holds escape (Tool_detail.structured ("RETURNED" ^ escape)));
  check bool "nor one in a bare scalar" false
    (holds escape (Tool_detail.structured ("\"x" ^ escape ^ "\"")));
  (* Making a payload safe replaces control bytes, and a newline is not one
     of them: the lines a producer wrote are still its own. *)
  check string "a payload keeps the lines it came with" "one\ntwo"
    (Tool_detail.structured "one\ntwo")
;;

let () =
  run
    "tui_tool_detail"
    [ ( "structured"
      , [] )
    ; ( "tree"
      , [] )
    ; ( "fold"
      , [] )
    ; ( "palette"
      , [ test_case "a value is painted after it is made safe" `Quick
            test_a_value_is_painted_after_it_is_made_safe
        ; test_case "a payload that does not parse is terminal safe" `Quick
            test_a_payload_that_does_not_parse_is_terminal_safe
        ] )
    ]
;;
