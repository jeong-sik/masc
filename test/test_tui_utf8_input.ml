(** Assembling a character whose bytes do not all arrive at once.

    The behaviour worth pinning is the resume. A terminal sends the bytes of
    one character together most of the time, so the path that matters is the
    one taken when it does not: the character straddles a read boundary, or an
    input method re-sends a syllable mid-composition. Before this, the head was
    discarded and its tail stayed in the stream to be read as continuation
    bytes that begin nothing — one dropped Hangul syllable arrived as three
    unrecognised keys.

    The stream here can be made to stop wherever a test wants, which is what a
    real terminal does at a moment nobody controls. *)

open Alcotest
module U = Masc_tui_utf8_input

(* A byte source that hands over [available] bytes and then reports empty,
   the way a read that timed out does. Later bytes stay behind and a second
   pass can be given a source that carries them. *)
let source ?limit bytes =
  let position = ref 0 in
  let stop = Option.value limit ~default:(String.length bytes) in
  fun () ->
    if !position >= stop then None
    else begin
      let byte = bytes.[!position] in
      incr position;
      Some byte
    end
;;

let hangul = "한" (* three bytes *)
let leading text = String.make 1 text.[0]

(* The leading byte travels as [prefix], so the stream starts after it — the
   same split the reader makes when it dispatches on the first byte it saw. *)
let after_leading ?limit text = source ?limit (String.sub text 1 (String.length text - 1))

let test_a_whole_character_completes () =
  match
    U.read_scalar ~prefix:(leading hangul) ~expected_length:3
      ~next_byte:(after_leading hangul)
  with
  | U.Complete scalar -> check string "the character" hangul scalar
  | U.Incomplete head -> failf "incomplete with %d byte(s)" (String.length head)
  | U.Malformed _ -> fail "a well-formed character was rejected"
;;

let test_a_stream_that_stops_early_keeps_the_head () =
  (* One continuation byte arrives, then nothing. The character is not lost;
     it is not finished. *)
  match
    U.read_scalar ~prefix:(leading hangul) ~expected_length:3
      ~next_byte:(after_leading ~limit:1 hangul)
  with
  | U.Incomplete head ->
    check int "two bytes are held" 2 (String.length head);
    check string "and they are the ones that arrived" (String.sub hangul 0 2) head
  | U.Complete _ -> fail "completed from a stream that had no more bytes"
  | U.Malformed _ -> fail "a stalled stream was read as a decoding failure"
;;

let test_resuming_finishes_the_character () =
  (* The claim this module exists for: what the first pass held, the second
     pass finishes, and the result is the character that was typed. *)
  let head =
    match
      U.read_scalar ~prefix:(leading hangul) ~expected_length:3
        ~next_byte:(fun () -> None)
    with
    | U.Incomplete head -> head
    | U.Complete _ | U.Malformed _ -> fail "expected a held head"
  in
  let tail = String.sub hangul (String.length head) (3 - String.length head) in
  match
    U.read_scalar ~prefix:head ~expected_length:3 ~next_byte:(source tail)
  with
  | U.Complete scalar -> check string "resumed to the same character" hangul scalar
  | U.Incomplete _ -> fail "the resume did not finish a complete tail"
  | U.Malformed _ -> fail "the resume rejected its own head"
;;

let test_a_head_alone_is_held_not_dropped () =
  match
    U.read_scalar ~prefix:(leading hangul) ~expected_length:3
      ~next_byte:(fun () -> None)
  with
  | U.Incomplete head -> check int "the leading byte survives" 1 (String.length head)
  | U.Complete _ | U.Malformed _ -> fail "the leading byte was discarded"
;;

let test_a_byte_that_cannot_belong_is_pushed_back () =
  (* An ASCII byte where a continuation belongs is a real failure, and that
     byte is the next keystroke — it has to go back, or it is eaten. *)
  match
    U.read_scalar ~prefix:(leading hangul) ~expected_length:3
      ~next_byte:(source "A")
  with
  | U.Malformed { pushback = Some byte } -> check char "the intruder" 'A' byte
  | U.Malformed { pushback = None } -> fail "the byte was consumed with nothing to return"
  | U.Complete _ | U.Incomplete _ -> fail "an ASCII byte was accepted as a continuation"
;;

let test_an_invalid_sequence_has_nothing_to_push_back () =
  (* Bytes that are continuations but do not form a scalar: every byte read
     belonged to the attempt, so there is none to give back. *)
  match
    U.read_scalar ~prefix:"\xed" ~expected_length:3 ~next_byte:(source "\xa0\x80")
  with
  | U.Malformed { pushback = None } -> ()
  | U.Malformed { pushback = Some _ } -> fail "a consumed byte was offered back"
  | U.Complete _ -> fail "a surrogate was accepted as valid UTF-8"
  | U.Incomplete _ -> fail "a full sequence was reported incomplete"
;;

let test_continuation_recognises_its_range () =
  check bool "0x80 is one" true (U.is_continuation '\x80');
  check bool "0xBF is one" true (U.is_continuation '\xBF');
  check bool "an ASCII letter is not" false (U.is_continuation 'A');
  check bool "a leading byte is not" false (U.is_continuation '\xEC')
;;

let () =
  run
    "tui_utf8_input"
    [ ( "assembly"
      , [ test_case "a whole character completes" `Quick test_a_whole_character_completes
        ; test_case "a stream that stops early keeps the head" `Quick
            test_a_stream_that_stops_early_keeps_the_head
        ; test_case "resuming finishes the character" `Quick
            test_resuming_finishes_the_character
        ; test_case "a head alone is held, not dropped" `Quick
            test_a_head_alone_is_held_not_dropped
        ] )
    ; ( "failure"
      , [ test_case "a byte that cannot belong is pushed back" `Quick
            test_a_byte_that_cannot_belong_is_pushed_back
        ; test_case "an invalid sequence has nothing to push back" `Quick
            test_an_invalid_sequence_has_nothing_to_push_back
        ; test_case "continuation recognises its range" `Quick
            test_continuation_recognises_its_range
        ] )
    ]
;;
