(* SMF bytes -> the info the pane shows: format, tracks, tempo map, time
   signatures, duration. Fixtures are assembled in-test, byte by byte; no
   .mid files. Each failure is checked as its constructor, not the sentence
   shown for it. *)

module Midi = Masc_tui_midi

let failure : Midi.failure Alcotest.testable =
  Alcotest.testable
    (fun ppf failure -> Format.pp_print_string ppf (Midi.failure_text failure))
    ( = )

let u16 n = String.init 2 (fun i -> Char.chr ((n lsr (8 * (1 - i))) land 0xFF))

let u24 n = String.init 3 (fun i -> Char.chr ((n lsr (8 * (2 - i))) land 0xFF))

let u32 n = String.init 4 (fun i -> Char.chr ((n lsr (8 * (3 - i))) land 0xFF))

let chunk tag body = tag ^ u32 (String.length body) ^ body

let varlen n =
  let rec loop n groups =
    let groups = (n land 0x7F) :: groups in
    if n < 0x80 then groups else loop (n lsr 7) groups
  in
  let groups = loop n [] in
  let len = List.length groups in
  let out = Bytes.create len in
  List.iteri
    (fun i group ->
       Bytes.set out i (Char.chr (group lor (if i = len - 1 then 0 else 0x80))))
    groups;
  Bytes.unsafe_to_string out

let meta event_type data =
  "\xFF" ^ String.make 1 (Char.chr event_type) ^ varlen (String.length data)
  ^ data

let at delta event = varlen delta ^ event

let tempo microseconds = meta 0x51 (u24 microseconds)

(* The SMF byte stores the denominator as a power of two: 4/4 is written
   04 02. The helper takes the human values and encodes. *)
let time_signature numerator denominator =
  let rec power_of_two exponent value =
    if value = denominator then exponent
    else if value > denominator then invalid_arg "not a power of two"
    else power_of_two (exponent + 1) (value * 2)
  in
  meta 0x58
    (String.init 4 (fun i ->
         Char.chr [| numerator; power_of_two 0 1; 24; 8 |].(i)))

let track_name name = meta 0x03 name
let eot = at 0 (meta 0x2F "")

let note_on delta note velocity =
  at delta
    ("\x90" ^ String.make 1 (Char.chr note) ^ String.make 1 (Char.chr velocity))

let program_change delta program =
  at delta ("\xC0" ^ String.make 1 (Char.chr program))

let smf format division tracks =
  chunk "MThd" (u16 format ^ u16 (List.length tracks) ^ u16 division)
  ^ String.concat "" (List.map (chunk "MTrk") tracks)

let read_info source =
  match Midi.read source with
  | Ok info -> info
  | Error failure -> Alcotest.fail (Midi.failure_text failure)

let check_failure label source expected =
  match Midi.read source with
  | Ok _ -> Alcotest.failf "%s: read as a midi file" label
  | Error actual -> Alcotest.(check failure) label expected actual

let test_minimal_type0 () =
  let track =
    at 0 (tempo 500000)
    ^ at 0 (time_signature 4 4)
    ^ note_on 0 60 100
    ^ note_on 480 60 0
    ^ eot
  in
  let info = read_info (smf 0 480 [ track ]) in
  Alcotest.(check int) "format" 0 info.format;
  Alcotest.(check int) "one track" 1 info.track_count;
  Alcotest.(check int) "ppq" 480 info.division_ppq;
  Alcotest.(check (option int)) "initial bpm" (Some 120) info.initial_bpm;
  Alcotest.(check (list (pair int int))) "the tempo map" [ (0, 120) ]
    info.tempo_changes;
  Alcotest.(check (list (triple int int int))) "the time signatures"
    [ (0, 4, 4) ] info.time_signatures;
  (* The wire stores the denominator as a power of two: a 6/8 file writes
     dd = 3, and the reader gives the human denominator back. *)
  let six_eight =
    read_info
      (smf 0 480
         [ at 0 (tempo 500000)
           ^ at 0 (time_signature 6 8)
           ^ note_on 0 60 100
           ^ note_on 480 60 0
           ^ eot
         ])
  in
  Alcotest.(check (list (triple int int int))) "6/8 decodes its denominator"
    [ (0, 6, 8) ] six_eight.time_signatures;
  Alcotest.(check (option (float 0.0001))) "duration" (Some 0.5)
    info.duration_sec;
  Alcotest.(check (list (option string))) "no track names" [ None ]
    info.track_names;
  Alcotest.(check string) "summary" "1 track · 120 BPM · 4/4 · 0:01"
    (Midi.summary info)

let test_tempo_change_mid_song () =
  let track =
    at 0 (tempo 500000)
    ^ note_on 0 60 100
    ^ note_on 480 60 0
    ^ at 0 (tempo 250000)
    ^ note_on 0 62 100
    ^ note_on 480 62 0
    ^ eot
  in
  let info = read_info (smf 0 480 [ track ]) in
  Alcotest.(check (list (pair int int))) "the map holds both"
    [ (0, 120); (480, 240) ] info.tempo_changes;
  Alcotest.(check (option (float 0.0001))) "duration follows the map"
    (Some 0.75) info.duration_sec

let test_fractional_bpm_duration_keeps_microseconds () =
  let track =
    at 0 (tempo 478469)
    ^ note_on 0 60 100
    ^ note_on 480 60 0
    ^ eot
  in
  let info = read_info (smf 0 480 [ track ]) in
  Alcotest.(check (option int)) "display bpm rounds down to integer" (Some 125)
    info.initial_bpm;
  Alcotest.(check (option (float 0.00001)))
    "duration uses exact microseconds (0.478469s, not 0.48s from 125 BPM)"
    (Some 0.478469) info.duration_sec

(* The 0x90 applies to the bytes after it until another status byte: the
   second tempo's tick says whether the stream was counted right. *)
let test_running_status_keeps_the_count () =
  let track =
    at 0 (tempo 500000)
    ^ note_on 0 60 100
    ^ varlen 240 ^ "\x3E\x40"
    ^ at 0 (tempo 250000)
    ^ varlen 240 ^ "\x40\x00"
    ^ eot
  in
  let info = read_info (smf 0 480 [ track ]) in
  Alcotest.(check (list (pair int int))) "the second tempo lands on its tick"
    [ (0, 120); (240, 240) ] info.tempo_changes;
  Alcotest.(check (option (float 0.0001))) "duration across the change"
    (Some 0.375) info.duration_sec

let test_program_change_is_one_data_byte () =
  let track =
    at 0 (tempo 500000)
    ^ program_change 0 25
    ^ note_on 0 60 100
    ^ note_on 240 60 0
    ^ eot
  in
  let info = read_info (smf 0 480 [ track ]) in
  Alcotest.(check (option (float 0.0001))) "one data byte, not two"
    (Some 0.25) info.duration_sec

let test_no_tempo_events () =
  let track = note_on 0 60 100 ^ note_on 480 60 0 ^ eot in
  let info = read_info (smf 1 480 [ track; eot ]) in
  Alcotest.(check (option int)) "no initial bpm" None info.initial_bpm;
  Alcotest.(check (option (float 0.0001))) "no duration" None info.duration_sec;
  Alcotest.(check string) "summary names only the tracks" "2 tracks"
    (Midi.summary info)

let test_track_names () =
  let first = at 0 (track_name "a") ^ at 0 (tempo 500000) ^ eot in
  let second = at 0 (track_name "b") ^ eot in
  let info = read_info (smf 1 480 [ first; second ]) in
  Alcotest.(check int) "two tracks" 2 info.track_count;
  Alcotest.(check (list (option string))) "the names in track order"
    [ Some "a"; Some "b" ] info.track_names

let test_smpte_division_fails () =
  check_failure "SMPTE time is not PPQ" (smf 0 0xE250 [ eot ])
    Unsupported_division;
  check_failure "zero division is not PPQ" (smf 0 0 [ eot ])
    Unsupported_division

let test_format_3_fails () =
  check_failure "only formats 0 to 2" (smf 3 480 [ eot ]) (Unsupported_format 3)

let test_garbage_fails () =
  check_failure "no header chunk" "hello" Not_midi;
  check_failure "empty" "" Truncated

let () =
  Alcotest.run "tui-midi"
    [ ( "info"
      , [ Alcotest.test_case "a minimal type 0 file" `Quick test_minimal_type0
        ; Alcotest.test_case "a tempo change mid song" `Quick
            test_tempo_change_mid_song
        ; Alcotest.test_case "fractional bpm duration keeps microseconds" `Quick
            test_fractional_bpm_duration_keeps_microseconds
        ; Alcotest.test_case "running status keeps the count" `Quick
            test_running_status_keeps_the_count
        ; Alcotest.test_case "a program change is one data byte" `Quick
            test_program_change_is_one_data_byte
        ; Alcotest.test_case "no tempo events" `Quick test_no_tempo_events
        ; Alcotest.test_case "track names in order" `Quick test_track_names
        ] )
    ; ( "failures"
      , [ Alcotest.test_case "SMPTE division fails" `Quick
            test_smpte_division_fails
        ; Alcotest.test_case "format 3 fails" `Quick test_format_3_fails
        ; Alcotest.test_case "garbage fails" `Quick test_garbage_fails
        ] )
    ]
