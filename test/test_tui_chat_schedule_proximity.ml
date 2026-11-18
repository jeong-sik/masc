(* A chat schedule row changes band as the clock runs, with no new data: Later
   becomes Today at the start of the due day, both become Soon an hour before
   the due moment, and Soon becomes Elapsed at it. The band is the decision
   the row's words and colour are drawn from; what is checked here is the band
   and the instant the frame notes for its end (RFC tui-one-screen-grammar §8),
   not the words. *)

open Alcotest
module Types = Masc_tui_types
module Redraw = Masc_tui_value.Redraw

let band_label = function
  | Types.Schedule_elapsed -> "elapsed"
  | Types.Schedule_soon -> "soon"
  | Types.Schedule_today -> "today"
  | Types.Schedule_later -> "later"
  | Types.Schedule_unknown -> "unknown"
  | Types.Schedule_pending -> "pending"
  | Types.Schedule_running -> "running"
  | Types.Schedule_failed -> "failed"
  | Types.Schedule_settled -> "settled"

(* A local wall-clock hour on the day [days] after the day of [base]. *)
let local ~base ~days hour =
  let day = Unix.localtime base in
  fst
    (Unix.mktime
       { day with Unix.tm_mday = day.Unix.tm_mday + days; tm_hour = hour; tm_min = 0; tm_sec = 0 })

let base = 1_794_050_000.

let check_band label ~now ~due ~band ~noted =
  Redraw.begin_frame ();
  check string (label ^ ": band") band (band_label (Types.chat_schedule_proximity ~now due));
  check (option (float 1e-6)) (label ^ ": the frame notes the end of the band") noted
    (Redraw.next_change ())

let test_each_band_notes_when_it_ends () =
  let morning = local ~base ~days:0 8 in
  check_band "no due time" ~now:morning ~due:None ~band:"unknown" ~noted:None;
  check_band "a passed due time" ~now:morning ~due:(Some (morning -. 60.)) ~band:"elapsed"
    ~noted:None;
  check_band "within the hour" ~now:morning ~due:(Some (morning +. 600.)) ~band:"soon"
    ~noted:(Some (morning +. 600.));
  let evening = local ~base ~days:0 20 in
  check_band "later today" ~now:morning ~due:(Some evening) ~band:"today"
    ~noted:(Some (evening -. Types.chat_schedule_soon_band_s));
  let tomorrow_evening = local ~base ~days:1 20 in
  check_band "another day" ~now:morning ~due:(Some tomorrow_evening) ~band:"later"
    ~noted:(Some (local ~base ~days:1 0))

let () =
  run "tui chat schedule proximity"
    [ ( "bands"
      , [ test_case "each band notes when it ends" `Quick test_each_band_notes_when_it_ends ] )
    ]
