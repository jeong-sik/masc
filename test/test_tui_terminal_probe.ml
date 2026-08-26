open Alcotest

let osc_bell body = "\x1b]" ^ body ^ "\x07"
let osc_st body = "\x1b]" ^ body ^ "\x1b\\"

let graphics_reply status =
  Printf.sprintf "\x1b_Gi=%d;%s\x1b\\" Masc_tui_graphics.query_id status
;;

let foreground = osc_bell "10;rgb:12/ab/00"
let background = osc_st "11;rgb:ffff/8080/0000"
let graphics_ok = graphics_reply "OK"

let palette result =
  match result.Masc_tui_terminal_probe.palette with
  | Some palette -> palette
  | None -> fail "expected a complete terminal palette"
;;

let check_rgb label expected color =
  let actual =
    ( Masc_tui_terminal_palette.red color
    , Masc_tui_terminal_palette.green color
    , Masc_tui_terminal_palette.blue color )
  in
  check (triple int int int) label expected actual
;;

let test_query_can_skip_only_palette () =
  check string "graphics remains under NO_COLOR" Masc_tui_graphics.query
    (Masc_tui_terminal_probe.query ~palette:false);
  check string "one combined query"
    (Masc_tui_terminal_palette.query ^ Masc_tui_graphics.query)
    (Masc_tui_terminal_probe.query ~palette:true)
;;

let test_palette_requires_both_slots () =
  let result =
    Masc_tui_terminal_probe.decode ~palette_requested:true
      (foreground ^ graphics_ok)
  in
  check bool "one slot is unknown" true (Option.is_none result.palette);
  let result =
    Masc_tui_terminal_probe.decode ~palette_requested:true
      (foreground ^ background ^ graphics_ok)
  in
  let palette = palette result in
  check_rgb "two-digit foreground" (0x12, 0xab, 0x00)
    (Masc_tui_terminal_palette.foreground palette);
  check_rgb "four-digit background" (255, 128, 0)
    (Masc_tui_terminal_palette.background palette)
;;

let test_malformed_palette_stays_unknown_and_is_not_input () =
  let malformed = osc_bell "10;rgb:f_/00/00" in
  let result =
    Masc_tui_terminal_probe.decode ~palette_requested:true
      ("before" ^ malformed ^ background ^ graphics_ok ^ "after")
  in
  check bool "malformed slot keeps the palette unknown" true
    (Option.is_none result.palette);
  check string "a recognized malformed reply is consumed" "beforeafter"
    result.replay
;;

let test_rgba_requires_and_ignores_a_valid_alpha () =
  let foreground = osc_bell "10;rgba:0101/0202/0303/ffff" in
  let result =
    Masc_tui_terminal_probe.decode ~palette_requested:true
      (foreground ^ background ^ graphics_ok)
  in
  check_rgb "rgba components" (1, 2, 3)
    (Masc_tui_terminal_palette.foreground (palette result));
  let missing_alpha = osc_bell "10;rgba:0101/0202/0303" in
  let result =
    Masc_tui_terminal_probe.decode ~palette_requested:true
      (missing_alpha ^ background ^ graphics_ok)
  in
  check bool "rgba without alpha is malformed" true
    (Option.is_none result.palette)
;;

let test_ascii_utf8_and_escape_bytes_replay_exactly () =
  let input_before = "a한\x1b" in
  let input_between = "\x1b[Aβ" in
  let input_after = "z" in
  let raw =
    input_before ^ foreground ^ input_between ^ graphics_ok ^ background
    ^ input_after
  in
  let result =
    Masc_tui_terminal_probe.decode ~palette_requested:true raw
  in
  check string "byte-for-byte replay"
    (input_before ^ input_between ^ input_after)
    result.replay
;;

let test_bracketed_paste_is_opaque () =
  let paste =
    "\x1b[200~pasted " ^ foreground ^ " and " ^ graphics_ok
    ^ " bytes\x1b[201~"
  in
  let result =
    Masc_tui_terminal_probe.decode ~palette_requested:true
      (foreground ^ "before" ^ paste ^ background ^ graphics_ok ^ "after")
  in
  check string "terminal-looking paste bytes survive"
    ("before" ^ paste ^ "after")
    result.replay;
  ignore (palette result)
;;

(* DECSET 996 asks and 2031 reports again on a theme switch, both replying as
   [CSI ? 997 ; n n]. A multiplexer passes these through where it answers no
   OSC colour query, so this is the only thing that ever arrives there. *)
let theme_mode_reply parameter = Printf.sprintf "\x1b[?997;%dn" parameter

let mode_to_string = function
  | Masc_tui_terminal_palette.Dark -> "dark"
  | Masc_tui_terminal_palette.Light -> "light"
;;

let theme_mode result =
  match result.Masc_tui_terminal_probe.theme_mode with
  | None -> "none"
  | Some mode -> mode_to_string mode
;;

let test_a_theme_mode_reply_is_read_and_not_typed () =
  let result =
    Masc_tui_terminal_probe.decode ~palette_requested:true
      ("a" ^ theme_mode_reply 1 ^ "b")
  in
  check string "the page is read" "dark" (theme_mode result);
  check string "the reply never reaches the composer" "ab" result.replay;
  let light =
    Masc_tui_terminal_probe.decode ~palette_requested:true
      (theme_mode_reply 2)
  in
  check string "light too" "light" (theme_mode light);
  (* A parameter this does not know is not a dark page. *)
  let unknown =
    Masc_tui_terminal_probe.decode ~palette_requested:true
      (theme_mode_reply 9)
  in
  check string "an unknown parameter says nothing" "none" (theme_mode unknown)
;;

(* Every other private-parameter sequence is the reader's, and holding one
   while it might have been the reply must not eat it. *)
let test_other_private_sequences_replay_whole () =
  List.iter
    (fun sequence ->
      let result =
        Masc_tui_terminal_probe.decode ~palette_requested:true
          ("x" ^ sequence ^ "y")
      in
      check string
        (Printf.sprintf "%S survives" sequence)
        ("x" ^ sequence ^ "y")
        result.replay;
      check string "and says nothing about the page" "none" (theme_mode result))
    [ "\x1b[?1h"          (* an application-cursor-keys set *)
    ; "\x1b[?2004l"       (* bracketed paste off *)
    ; "\x1b[?997;1m"      (* right parameters, wrong final byte *)
    ; "\x1b[?6n"          (* a cursor position request *)
    ]
;;

(* A sequence that never ends is the reader's input too. *)
let test_an_unfinished_private_sequence_is_not_swallowed () =
  let result =
    Masc_tui_terminal_probe.decode ~palette_requested:true "before\x1b[?997;1"
  in
  check string "the unfinished bytes come back" "before\x1b[?997;1"
    result.replay;
  check string "and no page was read" "none" (theme_mode result)
;;

(* Paste keeps the first claim on every byte it wants, even when what is
   pasted looks exactly like the reply. *)
let test_a_pasted_theme_reply_stays_pasted_text () =
  let paste = "\x1b[200~" ^ theme_mode_reply 2 ^ "\x1b[201~" in
  let result =
    Masc_tui_terminal_probe.decode ~palette_requested:true
      ("before" ^ paste ^ "after")
  in
  check string "pasted bytes survive" ("before" ^ paste ^ "after")
    result.replay;
  check string "and are not read as the page" "none" (theme_mode result)
;;

let test_unknown_and_incomplete_sequences_replay () =
  let unknown_osc = osc_bell "99;not-ours" in
  let unknown_apc = "\x1b_Gi=7;OK\x1b\\" in
  let incomplete = "\x1b]10;rgb:ff/ff/ff" in
  let input = unknown_osc ^ unknown_apc ^ incomplete in
  let result =
    Masc_tui_terminal_probe.decode ~palette_requested:true input
  in
  check string "nothing unrecognized is consumed" input result.replay
;;

let test_no_color_does_not_claim_osc_replies () =
  let result =
    Masc_tui_terminal_probe.decode ~palette_requested:false
      (foreground ^ graphics_ok)
  in
  check bool "no palette" true (Option.is_none result.palette);
  check string "unrequested OSC bytes replay" foreground result.replay;
  match result.graphics with
  | Some Masc_tui_graphics.Supported -> ()
  | Some (Masc_tui_graphics.Refused reason) ->
    failf "graphics unexpectedly refused: %s" reason
  | None -> fail "graphics answer was not decoded"
;;

let test_stream_finishes_only_after_every_answer () =
  let decoder = Masc_tui_terminal_probe.create ~palette_requested:true in
  String.iter (Masc_tui_terminal_probe.feed decoder) foreground;
  String.iter (Masc_tui_terminal_probe.feed decoder) graphics_ok;
  check bool "background still missing" false
    (Masc_tui_terminal_probe.complete decoder);
  String.iter (Masc_tui_terminal_probe.feed decoder) background;
  check bool "all requested answers arrived" true
    (Masc_tui_terminal_probe.complete decoder);
  let result = Masc_tui_terminal_probe.finish decoder in
  check string "responses are not replayed" "" result.replay;
  ignore (palette result)
;;

let test_partial_osc_continues_in_the_normal_reader () =
  let decoder = Masc_tui_terminal_probe.create ~palette_requested:true in
  let foreground_prefix = "\x1b]10;rgb:12/ab" in
  String.iter (Masc_tui_terminal_probe.feed decoder)
    ("before" ^ graphics_ok ^ foreground_prefix);
  let at_deadline = Masc_tui_terminal_probe.snapshot decoder in
  check bool "startup keeps an incomplete palette unknown" true
    (Option.is_none at_deadline.palette);
  check string "only decided input is replayable at the deadline" "before"
    at_deadline.replay;

  let unknown_osc = osc_bell "99;normal-input" in
  let pasted =
    "\x1b[200~paste " ^ background ^ " is input\x1b[201~"
  in
  let terminal_suffix =
    "/00\x1b\\" ^ unknown_osc ^ pasted ^ background ^ "after"
  in
  let terminal_position = ref 0 in
  let next_raw () =
    if !terminal_position >= String.length terminal_suffix then None
    else begin
      let byte = terminal_suffix.[!terminal_position] in
      incr terminal_position;
      Some byte
    end
  in
  let replay = Buffer.create 64 in
  let rec read_normally () =
    match Masc_tui_terminal_probe.next decoder ~next_raw with
    | None -> ()
    | Some byte ->
      Buffer.add_char replay byte;
      read_normally ()
  in
  read_normally ();
  check string "handoff removes only completed queried replies"
    ("before" ^ unknown_osc ^ pasted ^ "after")
    (Buffer.contents replay);
  check bool "the late suffix completes the decoder" true
    (Masc_tui_terminal_probe.complete decoder)
;;

let test_graphics_refusal_is_a_complete_answer () =
  let decoder = Masc_tui_terminal_probe.create ~palette_requested:false in
  String.iter (Masc_tui_terminal_probe.feed decoder)
    (graphics_reply "ENOTSUPPORTED");
  check bool "refusal ends the wait" true
    (Masc_tui_terminal_probe.complete decoder);
  match (Masc_tui_terminal_probe.finish decoder).graphics with
  | Some (Masc_tui_graphics.Refused "ENOTSUPPORTED") -> ()
  | Some Masc_tui_graphics.Supported -> fail "refusal became support"
  | Some (Masc_tui_graphics.Refused reason) ->
    failf "wrong refusal reason: %S" reason
  | None -> fail "refusal was dropped"
;;

let test_process_palette_preserves_none () =
  Masc_tui_terminal_palette.set_current None;
  let unknown_snapshot = Masc_tui_terminal_palette.snapshot () in
  check bool "unknown remains None" true
    (Option.is_none (Masc_tui_terminal_palette.current ()));
  check bool "snapshot preserves unknown" true
    (Option.is_none
       (Masc_tui_terminal_palette.snapshot_palette unknown_snapshot));
  let known =
    Masc_tui_terminal_probe.decode ~palette_requested:true
      (foreground ^ background ^ graphics_ok)
    |> palette
  in
  Masc_tui_terminal_palette.set_current (Some known);
  let known_snapshot = Masc_tui_terminal_palette.snapshot () in
  check bool "the same authority is readable" true
    (Option.is_some (Masc_tui_terminal_palette.current ()));
  check int "generation advances with the atomic write"
    (Masc_tui_terminal_palette.snapshot_generation unknown_snapshot + 1)
    (Masc_tui_terminal_palette.snapshot_generation known_snapshot);
  check bool "a captured snapshot cannot tear after a later write" true
    (Option.is_none
       (Masc_tui_terminal_palette.snapshot_palette unknown_snapshot));
  check bool "the new snapshot carries the new palette" true
    (Option.is_some
       (Masc_tui_terminal_palette.snapshot_palette known_snapshot));
  Masc_tui_terminal_palette.set_current None
;;

let test_byte_cap_is_fixed () =
  check int "64 KiB" (64 * 1024) Masc_tui_terminal_probe.max_bytes
;;

let () =
  run "tui_terminal_probe"
    [ ( "query"
      , [ test_case "NO_COLOR skips only palette" `Quick
            test_query_can_skip_only_palette
        ; test_case "the byte cap is fixed" `Quick test_byte_cap_is_fixed
        ] )
    ; ( "palette"
      , [ test_case "both slots are required" `Quick
            test_palette_requires_both_slots
        ; test_case "malformed stays unknown" `Quick
            test_malformed_palette_stays_unknown_and_is_not_input
        ; test_case "rgba validates alpha" `Quick
            test_rgba_requires_and_ignores_a_valid_alpha
        ; test_case "process authority preserves None" `Quick
            test_process_palette_preserves_none
        ] )
    ; ( "theme mode"
      , [ test_case "a reply is read and not typed" `Quick
            test_a_theme_mode_reply_is_read_and_not_typed
        ; test_case "other private sequences replay whole" `Quick
            test_other_private_sequences_replay_whole
        ; test_case "an unfinished one is not swallowed" `Quick
            test_an_unfinished_private_sequence_is_not_swallowed
        ; test_case "a pasted reply stays pasted text" `Quick
            test_a_pasted_theme_reply_stays_pasted_text
        ] )
    ; ( "replay"
      , [ test_case "ASCII UTF-8 and ESC replay exactly" `Quick
            test_ascii_utf8_and_escape_bytes_replay_exactly
        ; test_case "bracketed paste is opaque" `Quick
            test_bracketed_paste_is_opaque
        ; test_case "unknown and incomplete sequences replay" `Quick
            test_unknown_and_incomplete_sequences_replay
        ; test_case "NO_COLOR does not claim OSC" `Quick
            test_no_color_does_not_claim_osc_replies
        ] )
    ; ( "stream"
      , [ test_case "every requested answer completes" `Quick
            test_stream_finishes_only_after_every_answer
        ; test_case "partial OSC continues after startup" `Quick
            test_partial_osc_continues_in_the_normal_reader
        ; test_case "graphics refusal completes" `Quick
            test_graphics_refusal_is_a_complete_answer
        ] )
    ]
;;
