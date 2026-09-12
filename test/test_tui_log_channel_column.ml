open Alcotest
module Layout = Masc_tui_observation_layout
module Decode = Masc.Tui_decode

(* The CHANNEL column of a keeper's log. Two of the three channels carry the
   same word as the kind they belong to, so the column mostly repeated KIND --
   sixteen of sixteen rows in a live keeper's log read "hb hb" or "turn turn".
   It now draws only the channel that says something KIND does not, which is
   the scheduled-autonomous one. *)

let entry ?(kind = Decode.Log_turn) ?(channel = Decode.Log_channel_turn) () =
  { Decode.le_kind = kind
  ; le_ts = "2026-09-12T04:31:23Z"
  ; le_channel = channel
  ; le_message_count = Some 4466
  ; le_input_tokens = None
  ; le_output_tokens = None
  ; le_latency_ms = None
  ; le_cost_usd = None
  ; le_work_kind = None
  ; le_tools_used = []
  }

let row e = Layout.plain_log_row ~time:"04:31:23" e

let contains needle text =
  let n = String.length needle in
  let rec seek i =
    i + n <= String.length text
    && (String.equal (String.sub text i n) needle || seek (i + 1))
  in
  seek 0

(* "hb" appears once as the kind; a repeated channel would make it twice. *)
let occurrences needle text =
  let n = String.length needle in
  let rec count i acc =
    if i + n > String.length text then acc
    else if String.equal (String.sub text i n) needle then count (i + 1) (acc + 1)
    else count (i + 1) acc
  in
  count 0 0

let test_a_heartbeat_says_hb_once () =
  let drawn =
    row (entry ~kind:Decode.Log_heartbeat ~channel:Decode.Log_channel_heartbeat ())
  in
  check int "hb is the kind, and nothing else" 1 (occurrences "hb" drawn)

let test_a_turn_says_turn_once () =
  let drawn = row (entry ()) in
  check int "turn is the kind, and nothing else" 1 (occurrences "turn" drawn)

let test_a_scheduled_turn_keeps_its_channel () =
  let drawn =
    row
      (entry ~kind:Decode.Log_turn
         ~channel:Decode.Log_channel_scheduled_autonomous ())
  in
  check bool "the kind is still there" true (contains "turn" drawn);
  check bool "and the channel that disagrees with it" true
    (contains "sched" drawn)

(* A channel crossed with a kind it does not belong to is still drawn: the
   disagreement is the fact worth seeing, whichever pair it is. *)
let test_a_mismatched_pair_is_drawn () =
  let drawn =
    row (entry ~kind:Decode.Log_heartbeat ~channel:Decode.Log_channel_turn ())
  in
  check bool "the kind" true (contains "hb" drawn);
  check bool "and the channel" true (contains "turn" drawn)

let () =
  run "tui log channel column"
    [ ( "only the difference"
      , [ test_case "a heartbeat says hb once" `Quick
            test_a_heartbeat_says_hb_once
        ; test_case "a turn says turn once" `Quick test_a_turn_says_turn_once
        ; test_case "a scheduled turn keeps its channel" `Quick
            test_a_scheduled_turn_keeps_its_channel
        ; test_case "a mismatched pair is drawn" `Quick
            test_a_mismatched_pair_is_drawn
        ] )
    ]
