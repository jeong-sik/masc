(* A new question rings a desktop banner through OSC 9, and a BEL ends that
   sequence. The asker's name comes from the server, so these cases hold the
   banner text to what the framing needs of it: no byte the terminal would read
   as the end of the sequence or as a command. *)

module Ask = Masc_tui_ask_projection

let keeper name : Masc.Tui_decode_asks.ask_key =
  { ak_asker = Ask_keeper name; ak_id = "a1" }

let installation title : Masc.Tui_decode_asks.ask_key =
  { ak_asker = Ask_installation { ai_declaration_id = "decl-1"; ai_title = title }
  ; ak_id = "r1"
  }

(* Valid UTF-8 with no scalar a terminal acts on: C0, DEL and C1 are out. *)
let is_inert text =
  let rec scan offset =
    offset >= String.length text
    ||
    let decoded = String.get_utf_8_uchar text offset in
    let code = Uchar.to_int (Uchar.utf_decode_uchar decoded) in
    ((code >= 0x20 && code < 0x7f) || code > 0x9f)
    && scan (offset + Uchar.utf_decode_length decoded)
  in
  String.is_valid_utf_8 text && scan 0

(* Every single byte, and every pair of the bytes a terminal reads as a
   sequence end or a command introducer, as the asker's name. *)
let hostile_names =
  let singles = List.init 256 (fun byte -> String.make 1 (Char.chr byte)) in
  let introducers = [ "\000"; "\007"; "\027"; "\\"; "]"; "["; "\xc2\x9c"; "\x9c"; "x" ] in
  let pairs =
    List.concat_map
      (fun first -> List.map (fun second -> first ^ second) introducers)
      introducers
  in
  [ "x\007\027[2J"; "x\027\\\027]0;title\007"; "x\ny\r"; "x\127y" ] @ singles @ pairs

let check_inert label asked =
  Alcotest.(check bool) label true (is_inert (Ask.arrival_notification asked))

let test_a_name_cannot_end_the_sequence_or_run_a_command () =
  List.iter
    (fun name ->
      check_inert (Printf.sprintf "a Keeper named %S" name) [ keeper name ];
      check_inert (Printf.sprintf "an installation named %S" name) [ installation name ])
    hostile_names

(* The hostile name at each position of a list of two and of three askers. *)
let lists_holding name =
  let plain = keeper "imp" in
  [ [ keeper name; plain ]
  ; [ plain; installation name ]
  ; [ installation name; plain; plain ]
  ; [ plain; keeper name; plain ]
  ; [ plain; plain; installation name ]
  ]

let test_several_questions_carry_no_raw_name () =
  List.iter
    (fun name ->
      List.iteri
        (fun position asked ->
          check_inert (Printf.sprintf "list %d holding %S" position name) asked)
        (lists_holding name))
    hostile_names

let () =
  Alcotest.run "tui_ask_arrival_notification"
    [ ( "banner text"
      , [ Alcotest.test_case "a name cannot end the sequence or run a command" `Quick
            test_a_name_cannot_end_the_sequence_or_run_a_command
        ; Alcotest.test_case "several questions carry no raw name" `Quick
            test_several_questions_carry_no_raw_name
        ] )
    ]
