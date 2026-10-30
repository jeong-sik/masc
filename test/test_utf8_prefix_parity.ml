(** [Agent_core_strings.utf8_prefix] and [String_util.utf8_prefix] cut the same
    way. agent_core cannot import the coordinator's [String_util], so the rule
    exists twice; this keeps the two from drifting apart. *)

let cut_equal ~label s max_bytes =
  Alcotest.(check string)
    (Printf.sprintf "%s: max_bytes=%d on %S" label max_bytes s)
    (String_util.utf8_prefix ~max_bytes s)
    (Agent_core_strings.utf8_prefix ~max_bytes s)

let every_cut ~label s =
  for max_bytes = -1 to String.length s + 1 do
    cut_equal ~label s max_bytes
  done

let test_valid_text () =
  List.iter
    (fun s -> every_cut ~label:"valid" s)
    [ ""
    ; "ascii only"
    ; "한글 미리보기가 글자 중간에서 잘리지 않아야 해요"
    ; "mixed 한글 and ascii 😀 emoji"
    ; "\xc3\xa9t\xc3\xa9"
    ]

(* Bytes that are not UTF-8: a lone continuation, a lead with no tail, a
   truncated sequence at the end, 0xff. *)
let test_invalid_bytes () =
  List.iter
    (fun s -> every_cut ~label:"invalid" s)
    [ "\x80\x80\x80"
    ; "a\x80b"
    ; "\xe2\x82"
    ; "abc\xe2\x82"
    ; "\xff\xfe\xfd"
    ; "한\xe2\x82글"
    ]

(* Random strings drawn from the byte classes that make the walk differ:
   ASCII, continuation bytes, 2/3/4-byte leads. A fixed seed keeps a failure
   reproducible. *)
let test_random_bytes () =
  let state = Random.State.make [| 44179 |] in
  let alphabet = "a b\x80\xbf\xc3\xe2\xf0\x9f\x98\xea\xb0\x80\xff" in
  for _ = 1 to 300 do
    let length = Random.State.int state 24 in
    let s =
      String.init length (fun _ ->
        alphabet.[Random.State.int state (String.length alphabet)])
    in
    every_cut ~label:"random" s
  done

let () =
  Alcotest.run
    "utf8_prefix_parity"
    [ ( "parity"
      , [ Alcotest.test_case "valid text" `Quick test_valid_text
        ; Alcotest.test_case "invalid bytes" `Quick test_invalid_bytes
        ; Alcotest.test_case "random bytes" `Quick test_random_bytes
        ] )
    ]
;;
