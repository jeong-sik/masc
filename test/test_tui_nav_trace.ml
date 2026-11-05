(* The navigation trace (RFC-0485) keeps what a key is and drops what a person
   typed. These cases hold that to the decoder the TUI really reads keys with
   and to the footer text the trace asks what a screen announces, so the
   spellings the trace compares cannot drift apart without a case failing. *)

module Trace = Masc_tui_nav_trace
module Presenter = Masc_tui_frame_presenter
module Decoder = Masc_tui_input_decoder

(* The keys the decoder delivers for these bytes, the way the TUI feeds them. *)
let keys_of bytes =
  let decoder = Decoder.create () in
  let fed =
    List.concat_map (Decoder.feed decoder)
      (List.init (String.length bytes) (String.get bytes))
  in
  List.filter_map
    (function
      | Decoder.Key name -> Some name
      | Decoder.Paste _ | Decoder.Mouse_wheel _ | Decoder.Mouse_left_press _
      | Decoder.Mouse_left_drag _ | Decoder.Mouse_left_release _ | Decoder.Reply _ ->
        None)
    (fed @ Decoder.idle decoder)

let unchanged = Presenter.Unchanged
let presented = Presenter.Presented Presenter.Whole_screen

(* What the trace says of one key pressed on a screen whose frame stayed. *)
let key_of_press ~advertised raw =
  match
    Trace.observe ~previous_surface:(Some "changes") ~surface:"changes"
      ~key:(Some raw) ~result:unchanged ~advertised
  with
  | [ Trace.Key_unchanged { surface = "changes"; key } ] -> key
  | [ Trace.Key_unchanged _ ] | [ Trace.Surface_opened _ ] | [] | _ :: _ :: _ ->
    Alcotest.fail (Printf.sprintf "no single key event for %S" raw)

(* A line that is not one JSON object, or has no key word, fails the case by
   the exception the accessor raises. *)
let parsed line = Yojson.Safe.Util.to_assoc (Yojson.Safe.from_string line)
let key_field line = Yojson.Safe.Util.to_string (List.assoc "key" (parsed line))

let test_a_surface_event_marks_each_change () =
  let surfaces = [ "keepers"; "changes"; "dashboard" ] in
  List.iter
    (fun previous ->
      List.iter
        (fun surface ->
          List.iter
            (fun result ->
              let events =
                Trace.observe ~previous_surface:previous ~surface ~key:None ~result
                  ~advertised:[]
              in
              let expected =
                if previous = Some surface
                then []
                else [ Trace.Surface_opened { from = previous; to_ = surface } ]
              in
              Alcotest.(check bool)
                (Printf.sprintf "from %s to %s" (Option.value previous ~default:"-") surface)
                true (events = expected))
            [ unchanged; presented ])
        surfaces)
    [ None; Some "keepers"; Some "changes" ]

let test_a_key_is_reported_only_when_nothing_was_presented () =
  let observed result key =
    Trace.observe ~previous_surface:(Some "changes") ~surface:"changes" ~key ~result
      ~advertised:[ "Left" ]
  in
  Alcotest.(check bool) "frame stayed" true
    (observed unchanged (Some "left")
     = [ Trace.Key_unchanged
           { surface = "changes"; key = Trace.Named { name = "left"; advertised = true } }
       ]);
  Alcotest.(check bool) "whole screen drawn" true (observed presented (Some "left") = []);
  Alcotest.(check bool) "rows drawn" true
    (observed (Presenter.Presented (Presenter.Rows [ 1; 2 ])) (Some "left") = []);
  Alcotest.(check bool) "no key" true (observed unchanged None = [])

(* The decoder delivers typed text one character at a time, so a word-shaped
   key string is a name. Hold the trace to that: no character it delivers
   comes out as a name. *)
let test_typed_text_is_never_a_name () =
  let texts =
    List.init 95 (fun offset -> String.make 1 (Char.chr (0x20 + offset)))
    @ [ "\xed\x95\x9c"; "\xc3\xa9"; "\xf0\x9f\x98\x80" ]
  in
  List.iter
    (fun text ->
      match keys_of text with
      | [ raw ] ->
        (match key_of_press ~advertised:[] raw with
         | Trace.Other_char -> ()
         | Trace.Named _ | Trace.Advertised_char _ ->
           Alcotest.fail (Printf.sprintf "typed %S became more than a character" text))
      | [] | _ :: _ -> Alcotest.fail (Printf.sprintf "typed %S is not one key" text))
    texts

(* The footer's spelling of a key and the name the decoder gives it. *)
let footer_spellings =
  [ "Left", "\027[D"
  ; "Right", "\027[C"
  ; "Up", "\027[A"
  ; "Down", "\027[B"
  ; "Home", "\027[H"
  ; "End", "\027[F"
  ; "PgUp", "\027[5~"
  ; "PgDn", "\027[6~"
  ; "Tab", "\t"
  ; "Enter", "\r"
  ; "Esc", "\027"
  ; "Shift-Tab", "\027[Z"
  ; "Backspace", "\127"
  ; "Ctrl-W", "\023"
  ; "Ctrl-L", "\012"
  ; "Ctrl-]", "\029"
  ; "Ctrl-^", "\030"
  ]

let named ~advertised raw =
  match key_of_press ~advertised raw with
  | Trace.Named { name; advertised } -> Some (name, advertised)
  | Trace.Advertised_char _ | Trace.Other_char -> None

let test_the_footer_and_the_decoder_name_one_key_alike () =
  List.iter
    (fun (atom, bytes) ->
      let hints = Printf.sprintf "j/k:move  %s:act  q:quit" atom in
      let advertised = Masc_tui_footer.advertised_key_atoms hints in
      Alcotest.(check bool)
        (Printf.sprintf "%s is read out of the hints" atom)
        true (List.mem atom advertised);
      match keys_of bytes with
      | [ raw ] ->
        (match named ~advertised raw, named ~advertised:[] raw with
         | Some (name, true), Some (same, false) ->
           Alcotest.(check string) (atom ^ " keeps one name") name same
         | (Some _ | None), (Some _ | None) ->
           Alcotest.fail (atom ^ " is not a named key announced by its footer"))
      | [] | _ :: _ -> Alcotest.fail (atom ^ " is not one decoder key"))
    footer_spellings

let test_a_character_is_kept_only_as_the_footer_spells_it () =
  let advertised = Masc_tui_footer.advertised_key_atoms "j/k:move  [ / ]:ask  G:end" in
  List.iter
    (fun (typed, expected) ->
      Alcotest.(check bool)
        (Printf.sprintf "%S" typed) true
        (key_of_press ~advertised typed = expected))
    [ "j", Trace.Advertised_char "j"
    ; "[", Trace.Advertised_char "["
    ; "G", Trace.Advertised_char "G"
    ; "g", Trace.Other_char
    ; "x", Trace.Other_char
    ; "\xed\x95\x9c", Trace.Other_char
    ]

(* Every byte, and a few strings no key carries, as the key: whatever the line
   holds for it is the word "char", a spelling the footer announced, or a word
   in the decoder's shape. *)
let test_no_typed_text_reaches_the_line () =
  let advertised = [ "j"; "k"; "Enter" ] in
  let is_word_shape word =
    String.length word >= 2
    && String.for_all (function 'a' .. 'z' | '0' .. '9' | '-' -> true | _ -> false) word
  in
  let raws =
    List.init 256 (fun byte -> String.make 1 (Char.chr byte))
    @ [ "hello world"; "pa$$word"; "\xed\x95\x9c\xea\xb8\x80"; "\xff\xfe"; "x\027[2J" ]
  in
  List.iter
    (fun raw ->
      let line =
        Trace.to_json_line ~at:0.
          (Trace.Key_unchanged
             { surface = "changes"; key = key_of_press ~advertised raw })
      in
      let word = key_field line in
      Alcotest.(check bool)
        (Printf.sprintf "key %S written as %S" raw word)
        true
        (String.equal word "char" || List.mem word advertised || is_word_shape word))
    raws

let test_each_event_is_one_json_object () =
  let fields_of event = List.map fst (parsed (Trace.to_json_line ~at:1.5 event)) in
  Alcotest.(check (list string)) "first frame" [ "t"; "kind"; "from"; "to" ]
    (fields_of (Trace.Surface_opened { from = None; to_ = "keepers" }));
  Alcotest.(check (list string)) "a change" [ "t"; "kind"; "from"; "to" ]
    (fields_of (Trace.Surface_opened { from = Some "keepers"; to_ = "changes" }));
  List.iter
    (fun key ->
      Alcotest.(check (list string)) "a key" [ "t"; "kind"; "surface"; "key"; "advertised" ]
        (fields_of (Trace.Key_unchanged { surface = "changes"; key })))
    [ Trace.Named { name = "left"; advertised = true }
    ; Trace.Advertised_char "j"
    ; Trace.Other_char
    ];
  let line = Trace.to_json_line ~at:1.5 (Trace.Surface_opened { from = None; to_ = "keepers" }) in
  Alcotest.(check bool) "no line break" false (String.contains line '\n');
  Alcotest.(check bool) "first frame has no origin" true
    (List.assoc_opt "from" (parsed line) = Some `Null)

let () =
  Alcotest.run "tui_nav_trace"
    [ ( "events"
      , [ Alcotest.test_case "a surface event marks each change" `Quick
            test_a_surface_event_marks_each_change
        ; Alcotest.test_case "a key is reported only when nothing was presented" `Quick
            test_a_key_is_reported_only_when_nothing_was_presented
        ] )
    ; ( "keys"
      , [ Alcotest.test_case "typed text is never a name" `Quick test_typed_text_is_never_a_name
        ; Alcotest.test_case "the footer and the decoder name one key alike" `Quick
            test_the_footer_and_the_decoder_name_one_key_alike
        ; Alcotest.test_case "a character is kept only as the footer spells it" `Quick
            test_a_character_is_kept_only_as_the_footer_spells_it
        ; Alcotest.test_case "no typed text reaches the line" `Quick
            test_no_typed_text_reaches_the_line
        ] )
    ; ( "lines"
      , [ Alcotest.test_case "each event is one json object" `Quick
            test_each_event_is_one_json_object
        ] )
    ]
