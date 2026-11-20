(* What is checked is the decision a notation rests on, not the text a screen
   draws with it: which of today, this year and another year a moment falls
   in, how far the operator's zone stands from UTC across a year's end,
   where a count's separators go around a sign, and which numbers an English
   count names in the singular. *)

module Instant = Masc_tui_value.Instant
module Count = Masc_tui_value.Count
module Hash = Masc_tui_value.Hash
module Ongoing = Masc_tui_value.Ongoing
module Redraw = Masc_tui_value.Redraw
module Position = Masc_tui_value.Position
module Utc_day = Masc_tui_value.Utc_day
module Local_hour = Masc_tui_value.Local_hour

(* [Unix.tm] counts years from 1900. *)
let tm_year_origin = 1900

let day ~year ~yday ~hour ~minute =
  { Unix.tm_sec = 0
  ; tm_min = minute
  ; tm_hour = hour
  ; tm_mday = 1
  ; tm_mon = 0
  ; tm_year = year - tm_year_origin
  ; tm_wday = 0
  ; tm_yday = yday
  ; tm_isdst = false
  }

let distance =
  Alcotest.testable
    (fun ppf distance ->
      Format.pp_print_string ppf
        (match distance with
         | Instant.Same_day -> "Same_day"
         | Instant.Same_year -> "Same_year"
         | Instant.Other_year -> "Other_year"))
    ( = )

let november_11 = 314
let last_day_of_the_year = 364

let test_a_moment_earlier_today_is_the_same_day () =
  Alcotest.check distance "morning read in the evening" Instant.Same_day
    (Instant.distance
       ~now:(day ~year:2026 ~yday:november_11 ~hour:19 ~minute:39)
       (day ~year:2026 ~yday:november_11 ~hour:0 ~minute:1))

(* The last minute of yesterday is two minutes old and still another day: the
   clock alone would read as if it were tonight's 23:59, which has not come. *)
let test_midnight_ends_the_day () =
  Alcotest.check distance "23:59 read at 00:01" Instant.Same_year
    (Instant.distance
       ~now:(day ~year:2026 ~yday:november_11 ~hour:0 ~minute:1)
       (day ~year:2026 ~yday:(november_11 - 1) ~hour:23 ~minute:59))

(* The same day of the year, a year apart. A comparison that read the day
   alone would call it today and draw last year's moment as a bare clock. *)
let test_the_same_date_last_year_is_another_year () =
  Alcotest.check distance "one year back to the day" Instant.Other_year
    (Instant.distance
       ~now:(day ~year:2026 ~yday:november_11 ~hour:19 ~minute:39)
       (day ~year:2025 ~yday:november_11 ~hour:19 ~minute:39))

let test_new_year_ends_the_year () =
  Alcotest.check distance "December 31 read on January 1" Instant.Other_year
    (Instant.distance
       ~now:(day ~year:2027 ~yday:0 ~hour:0 ~minute:1)
       (day ~year:2026 ~yday:last_day_of_the_year ~hour:23 ~minute:59))

(* The decision a dated moment rests on, read on whole epochs in one fixed
   zone. 2026-11-18 20:29 UTC read at 2026-11-19 04:28 UTC is eight hours
   old and yesterday: the Features status line drew it as a bare 20:29:21. *)
let evening_before = 1_795_033_740.
let small_hours_after = 1_795_062_480.

let test_eight_hours_back_across_midnight_is_another_day () =
  Alcotest.check distance "20:29 yesterday read at 04:28" Instant.Same_year
    (Instant.day_of ~localtime:Unix.gmtime ~now:small_hours_after evening_before)

let test_an_hour_back_before_midnight_is_today () =
  Alcotest.check distance "19:29 read at 20:29" Instant.Same_day
    (Instant.day_of ~localtime:Unix.gmtime ~now:evening_before (evening_before -. 3600.))

(* Whether the moment carries a date is the value module's decision: today
   it is the clock and nothing else, another day it is that clock with the
   date in front. Checked against the module's own clock, not a wording. *)
let test_only_another_day_adds_a_date () =
  let clock at = Instant.clock_within_day Instant.To_minute (Unix.gmtime at) in
  let detail ~now at = Instant.detail_text ~localtime:Unix.gmtime Instant.To_minute ~now at in
  let today = evening_before -. 3600. in
  Alcotest.(check bool) "today: the clock alone" true
    (String.equal (detail ~now:evening_before today) (clock today));
  let yesterday = detail ~now:small_hours_after evening_before in
  Alcotest.(check bool) "yesterday: more than the clock" true
    (String.length yesterday > String.length (clock evening_before));
  Alcotest.(check bool) "yesterday: still ends on the clock" true
    (String.ends_with ~suffix:(clock evening_before) yesterday)

(* A UTC day is the server's bucket. 23:59 and 00:00 UTC are two days, and
   a moment's UTC day does not follow the operator's zone: the day is decided
   from the epoch, not from a local breakdown. *)
let test_a_utc_day_turns_at_utc_midnight () =
  let midnight = 1_763_510_400. (* 2025-11-19T00:00:00Z *) in
  let before = Utc_day.of_moment (midnight -. 1.) and after = Utc_day.of_moment midnight in
  Alcotest.(check int) "a second before midnight is the 18th" 18 (Utc_day.day_of_month before);
  Alcotest.(check int) "midnight starts the 19th" 19 (Utc_day.day_of_month after);
  Alcotest.(check int) "a whole day later is the next day" 20
    (Utc_day.day_of_month (Utc_day.of_moment (midnight +. 86_400.)))

(* Two breakdowns of the same wall-clock hour on either side of a
   daylight-saving change are two hours: the chat draws a heading between
   them. *)
let test_a_repeated_hour_is_another_hour () =
  let tm = Unix.gmtime 1_763_510_400. in
  let standard = Local_hour.of_tm { tm with Unix.tm_isdst = false }
  and daylight = Local_hour.of_tm { tm with Unix.tm_isdst = true } in
  Alcotest.(check bool) "the same breakdown is the same hour" true
    (Local_hour.equal standard (Local_hour.of_tm { tm with Unix.tm_isdst = false }));
  Alcotest.(check bool) "daylight time is another hour" false (Local_hour.equal standard daylight)

(* A ruler mark stands only where an hour starts. The test runs with no TZ,
   so the local zone is UTC and hours start on multiples of 3600 s. *)
let test_a_ruler_marks_only_the_start_of_an_hour () =
  let hour = 1_763_510_400. in
  Alcotest.(check bool) "an hour's start is marked" true
    (Option.is_some (Instant.axis_hour hour));
  Alcotest.(check bool) "half past is not" true (Option.is_none (Instant.axis_hour (hour +. 1800.)))

(* The day's start is a local midnight at or before the moment, on the same
   day. *)
let test_a_day_starts_at_its_midnight () =
  let at = 1_763_550_000. in
  match Instant.day_start at with
  | None -> Alcotest.fail "a representable moment has a day start"
  | Some start ->
      Alcotest.(check bool) "at or before the moment" true (start <= at);
      Alcotest.check distance "on the moment's day" Instant.Same_day
        (Instant.day_of ~now:at start);
      Alcotest.check distance "a second earlier is the day before" Instant.Same_year
        (Instant.day_of ~now:at (start -. 1.))

(* East of Greenwich the local day turns first. At 00:30 on January 1 in
   UTC+9 it is still December 31 in UTC, in another year with a larger day
   number: the clock fields alone would put the zone fifteen hours behind. *)
let test_the_offset_survives_new_year_east_of_utc () =
  Alcotest.(check int) "00:30 January 1 against 15:30 December 31" 540
    (Instant.offset_minutes
       ~utc:(day ~year:2026 ~yday:last_day_of_the_year ~hour:15 ~minute:30)
       ~local:(day ~year:2027 ~yday:0 ~hour:0 ~minute:30))

let test_the_offset_survives_new_year_west_of_utc () =
  Alcotest.(check int) "16:00 December 31 against 00:00 January 1" (-480)
    (Instant.offset_minutes
       ~utc:(day ~year:2027 ~yday:0 ~hour:0 ~minute:0)
       ~local:(day ~year:2026 ~yday:last_day_of_the_year ~hour:16 ~minute:0))

(* A zone behind UTC by hours and minutes: the sign belongs to the whole
   distance, not to the hour figure alone. *)
let test_a_zone_label_carries_one_sign () =
  List.iter
    (fun (offset_minutes, expected) ->
      Alcotest.(check string) (string_of_int offset_minutes) expected
        (Instant.zone_label ~offset_minutes))
    [ (0, "UTC"); (540, "UTC+9"); (-480, "UTC-8"); (330, "UTC+5:30"); (-210, "UTC-3:30") ]

(* Two of the three copies this function replaced counted the minus sign as a
   digit, which puts a separator straight after it. *)
let test_a_sign_is_not_a_digit () =
  List.iter
    (fun (value, expected) ->
      Alcotest.(check string) (string_of_int value) expected (Count.grouped value))
    [ (999, "999")
    ; (1000, "1,000")
    ; (-999, "-999")
    ; (-1000, "-1,000")
    ; (-123456, "-123,456")
    ]

(* English names one thing in the singular and every other number, zero
   included, in the plural, and the figure is grouped like any other. *)
let test_only_one_is_singular () =
  List.iter
    (fun (count, expected) ->
      Alcotest.(check string) (string_of_int count) expected
        (Count.reading ~ko:false Count.Entry count))
    [ (0, "0 entries"); (1, "1 entry"); (2, "2 entries"); (8347, "8,347 entries") ]

(* Which position a screen hands, and its numbers: a window that hides rows
   and none for one that shows them all, a list's selected row held inside
   the list, and a list read in part. The text zone 2 draws from them is not
   checked here (RFC tui-one-screen-grammar, section 10). *)
let window_numbers = function
  | Some (Position.Window { first; last; total }) -> Some (first, last, total)
  | Some (Position.Row _ | Position.Partial _) | None -> None

let test_a_window_is_handed_only_when_it_hides_rows () =
  let check label expected ~first ~shown ~total =
    Alcotest.(check (option (triple int int int))) label expected
      (window_numbers (Position.window ~first ~shown ~total))
  in
  check "every row shown hands nothing" None ~first:0 ~shown:10 ~total:10;
  check "a short reading hands nothing" None ~first:4 ~shown:10 ~total:3;
  check "an empty reading hands nothing" None ~first:0 ~shown:10 ~total:0;
  check "a middle window counts from one" (Some (6, 15, 30)) ~first:5 ~shown:10 ~total:30;
  check "a window near the end ends at the last row" (Some (26, 30, 30))
    ~first:25 ~shown:10 ~total:30;
  check "a window past the end is held at the last row" (Some (30, 30, 30))
    ~first:99 ~shown:10 ~total:30;
  check "a window above the top starts at the top" (Some (1, 10, 30))
    ~first:(-4) ~shown:10 ~total:30;
  check "a window with no rows shows none of them" (Some (0, 0, 3))
    ~first:0 ~shown:0 ~total:3

let test_a_list_names_its_selected_row () =
  Alcotest.(check bool) "the seventh of 29" true
    (match Position.row ~selected:(Some 6) ~total:29 with
     | Position.Row { at = 7; total = 29 } -> true
     | Position.Row _ | Position.Window _ | Position.Partial _ -> false);
  Alcotest.(check bool) "a list that fits still names its row" true
    (match Position.row ~selected:(Some 0) ~total:3 with
     | Position.Row { at = 1; total = 3 } -> true
     | Position.Row _ | Position.Window _ | Position.Partial _ -> false);
  Alcotest.(check bool) "nothing selected is row zero" true
    (match Position.row ~selected:None ~total:31 with
     | Position.Row { at = 0; total = 31 } -> true
     | Position.Row _ | Position.Window _ | Position.Partial _ -> false);
  Alcotest.(check bool) "a cursor past the end names the last row" true
    (match Position.row ~selected:(Some 40) ~total:29 with
     | Position.Row { at = 29; total = 29 } -> true
     | Position.Row _ | Position.Window _ | Position.Partial _ -> false);
  Alcotest.(check bool) "an empty list selects nothing" true
    (match Position.row ~selected:(Some 0) ~total:0 with
     | Position.Row { at = 0; total = 0 } -> true
     | Position.Row _ | Position.Window _ | Position.Partial _ -> false);
  Alcotest.(check bool) "a list read in part names the row among those read" true
    (match Position.partial ~selected:(Some 0) ~loaded:50 ~total:2000 with
     | Position.Partial { at = 1; loaded = 50; total = 2000 } -> true
     | Position.Row _ | Position.Window _ | Position.Partial _ -> false)

(* What a card cut off is a number of rows in the screen's language, grouped
   like any other count. *)
let test_cut_rows_are_counted_in_the_screens_language () =
  List.iter
    (fun (ko, rows, expected) ->
      Alcotest.(check string) expected expected (Count.more ~ko rows))
    [ (true, 3, "\xec\x99\xb8 3")
    ; (false, 3, "3 more")
    ; (true, 1234, "\xec\x99\xb8 1,234")
    ; (false, 1234, "1,234 more")
    ]

(* A digest is drawn by its head, so the shown text is the start a reader can
   find in the copied whole. A value shorter than the cut comes back whole
   instead of raising. *)
let test_a_hash_keeps_its_head () =
  let digest = "0b9c6e1f4a2d7c3e8f5a1b6c2d7e3f8a4b9c5d0e1f6a2b7c3d8e4f9a5b0c6d1e" in
  Alcotest.(check string) "a 64-character digest" (String.sub digest 0 12)
    (Hash.short digest);
  Alcotest.(check string) "a value shorter than the cut" "0b9c" (Hash.short "0b9c")


(* Every instant at which the [text] reading of a growing span differs from
   the reading just before it, sampled every quarter second from [first] up to
   [last]. *)
let reading_changes ?(text = Ongoing.text) ~first ~last () =
  let step = 0.25 in
  let rec walk at previous changes =
    if at > last then List.rev changes
    else
      let reading = text at in
      walk (at +. step) reading
        (if String.equal reading previous then changes else at :: changes)
  in
  walk first (text first) []

let seconds_per_minute = 60.
let seconds_per_day = 86_400.

(* RFC tui-one-screen-grammar §6.2 and §10: a length past a minute changes at
   most once a minute, so time alone redraws it at most once a minute. *)
let test_a_length_past_a_minute_changes_at_most_once_a_minute () =
  let changes = reading_changes ~first:seconds_per_minute ~last:(2. *. seconds_per_day) () in
  let rec gaps = function
    | a :: (b :: _ as rest) -> (b -. a) :: gaps rest
    | [ _ ] | [] -> []
  in
  Alcotest.(check bool) "the reading changes past a minute" true (List.length changes > 1);
  List.iter
    (fun gap ->
      Alcotest.(check bool) "two changes are at least a minute apart" true
        (gap >= seconds_per_minute))
    (gaps changes)

(* The same rule read the other way: a countdown ("in 3m", "8h13m 뒤") with
   more than a minute left changes at most once a minute while what is left
   shrinks (RFC tui-one-screen-grammar §6.2). *)
let test_a_countdown_past_a_minute_changes_at_most_once_a_minute () =
  let at = 1_000_000. and step = 0.25 in
  let rec walk now previous changes =
    if now > at -. seconds_per_minute then List.rev changes
    else
      let reading = Ongoing.text (at -. now) in
      walk (now +. step) reading
        (if String.equal reading previous then changes else now :: changes)
  in
  let first = at -. (2. *. seconds_per_day) in
  let changes = walk first (Ongoing.text (at -. first)) [] in
  let rec gaps = function
    | a :: (b :: _ as rest) -> (b -. a) :: gaps rest
    | [ _ ] | [] -> []
  in
  Alcotest.(check bool) "the reading changes while the moment comes" true
    (List.length changes > 1);
  List.iter
    (fun gap ->
      Alcotest.(check bool) "two changes are at least a minute apart" true
        (gap >= seconds_per_minute))
    (gaps changes)

(* [next_change] is the instant the reading next differs: a frame that waits
   for it is neither early (the same reading drawn again) nor late. *)
let test_next_change_is_the_first_instant_the_reading_differs () =
  List.iter
    (fun span ->
      match Ongoing.next_change span with
      | None -> Alcotest.fail "a readable span always changes again"
      | Some next ->
          Alcotest.(check bool) "it is later than the span" true (next > span);
          Alcotest.(check bool) "the reading differs from then" false
            (String.equal (Ongoing.text span) (Ongoing.text next));
          Alcotest.(check bool) "and not before" true
            (String.equal (Ongoing.text span) (Ongoing.text (next -. 0.001))))
    [ 0.; 0.4; 1.; 59.2; 60.; 61.; 125.3; 3599.9; 3600.; 7322.; 86_399.; 86_400.5;
      100. *. seconds_per_day; 123. *. seconds_per_day ]

(* A countdown reads the same until what is left drops below the reading's
   floor. *)
let test_a_countdown_changes_below_its_reading_floor () =
  List.iter
    (fun left ->
      let floor = Ongoing.reading_floor left in
      Alcotest.(check bool) "the floor reads the same" true
        (String.equal (Ongoing.text left) (Ongoing.text floor));
      Alcotest.(check bool) "just below it does not" false
        (String.equal (Ongoing.text left) (Ongoing.text (floor -. 0.001))))
    [ 1.5; 59.9; 60.; 125.3; 3600.; 7322.; 86_400.5; 101. *. seconds_per_day ]

(* The zone-1 clock next reads differently when the local minute turns. *)
let test_the_clock_changes_on_the_next_minute () =
  List.iter
    (fun now ->
      let next = Instant.next_minute ~now in
      Alcotest.(check bool) "within a minute" true (next > now && next -. now <= 60.);
      Alcotest.(check bool) "the same reading just before" true
        (String.equal (Instant.wall_clock ~now) (Instant.wall_clock ~now:(next -. 0.001)));
      Alcotest.(check bool) "another from then" false
        (String.equal (Instant.wall_clock ~now) (Instant.wall_clock ~now:next)))
    [ 1_794_050_000.; 1_794_050_059.9; 1_794_050_060.; 1_794_052_799.5 ]

(* What a frame notes is when its earliest time text changes. *)
let test_a_frame_notes_its_earliest_change () =
  Redraw.begin_frame ();
  Alcotest.(check (option (float 1e-9))) "a new frame notes nothing" None
    (Redraw.next_change ());
  (* 100.25s ago reads in minutes and next changes at the second minute;
     4.75s ago next changes at its fifth second. *)
  ignore (Ongoing.since ~now:1000.25 900.);
  ignore (Ongoing.since ~now:1000.25 995.5);
  Alcotest.(check (option (float 1e-9))) "the earliest of the two" (Some 1000.5)
    (Redraw.next_change ());
  let worker = Domain.spawn Redraw.next_change in
  Alcotest.(check (option (float 1e-9))) "another domain built no frame" None
    (Domain.join worker);
  Redraw.begin_frame ();
  ignore (Ongoing.until ~now:1000. 1000.5);
  Alcotest.(check (option (float 1e-9))) "a moment under a second away notes its arrival"
    (Some 1000.5) (Redraw.next_change ());
  Redraw.begin_frame ();
  ignore (Ongoing.until ~now:1000. 990.);
  Alcotest.(check (option (float 1e-9))) "a passed moment changes no more" None
    (Redraw.next_change ())

(* The narrow ladder ([45s], [3m], [1h], [2d]) is the same rule cut to one
   unit: past a minute it changes at most once a minute (RFC
   tui-one-screen-grammar §6.2, §10). *)
let test_a_narrow_length_past_a_minute_changes_at_most_once_a_minute () =
  let changes =
    reading_changes ~text:Ongoing.Narrow.text ~first:seconds_per_minute
      ~last:(2. *. seconds_per_day) ()
  in
  let rec gaps = function
    | a :: (b :: _ as rest) -> (b -. a) :: gaps rest
    | [ _ ] | [] -> []
  in
  Alcotest.(check bool) "the reading changes past a minute" true (List.length changes > 1);
  List.iter
    (fun gap ->
      Alcotest.(check bool) "two changes are at least a minute apart" true
        (gap >= seconds_per_minute))
    (gaps changes)

(* A frame waits for the narrow ladder's [next_change]; the cell reads the
   same until then and differs from then. *)
let test_a_narrow_next_change_is_the_first_instant_the_reading_differs () =
  List.iter
    (fun span ->
      match Ongoing.Narrow.next_change span with
      | None -> Alcotest.fail "a readable span always changes again"
      | Some next ->
          Alcotest.(check bool) "it is later than the span" true (next > span);
          Alcotest.(check bool) "the reading differs from then" false
            (String.equal (Ongoing.Narrow.text span) (Ongoing.Narrow.text next));
          Alcotest.(check bool) "and not before" true
            (String.equal (Ongoing.Narrow.text span) (Ongoing.Narrow.text (next -. 0.001))))
    [ 0.; 0.4; 59.2; 60.; 61.; 89.5; 3599.9; 3600.; 7322.; 86_399.; 86_400.5;
      123. *. seconds_per_day ];
  List.iter
    (fun left ->
      let floor = Ongoing.Narrow.reading_floor left in
      Alcotest.(check bool) "a countdown reads the same at its floor" true
        (String.equal (Ongoing.Narrow.text left) (Ongoing.Narrow.text floor));
      Alcotest.(check bool) "and differently just below it" false
        (String.equal (Ongoing.Narrow.text left) (Ongoing.Narrow.text (floor -. 0.001))))
    [ 1.5; 59.9; 60.; 125.3; 3600.; 7322.; 86_400.5 ]

(* A reading that lasts until an instant (a notice shown for twelve seconds,
   a clause added after two quiet seconds) notes that instant while it holds,
   and nothing once it has ended. *)
let test_a_reading_that_holds_notes_when_it_ends () =
  Redraw.begin_frame ();
  Alcotest.(check bool) "before the instant it holds" true
    (Redraw.holds ~now:1000. ~until:1012.);
  Alcotest.(check (option (float 1e-9))) "and the frame notes the instant" (Some 1012.)
    (Redraw.next_change ());
  Redraw.begin_frame ();
  Alcotest.(check bool) "on the instant it still holds" true
    (Redraw.holds ~now:1012. ~until:1012.);
  Redraw.begin_frame ();
  Alcotest.(check bool) "after the instant it has ended" false
    (Redraw.holds ~now:1012.5 ~until:1012.);
  Alcotest.(check (option (float 1e-9))) "and an ended reading notes nothing" None
    (Redraw.next_change ())

(* Text that is measured and not drawn asks for no redraw, and a measurement
   leaves what the frame noted before it in place. *)
let test_a_measurement_notes_nothing () =
  Redraw.begin_frame ();
  let width =
    Redraw.measuring (fun () -> String.length (Ongoing.since ~now:1000.25 995.5))
  in
  Alcotest.(check int) "the measurement returns its answer" 2 width;
  Alcotest.(check (option (float 1e-9))) "a frame that only measured notes nothing" None
    (Redraw.next_change ());
  ignore (Ongoing.since ~now:1000.25 900.);
  ignore (Redraw.measuring (fun () -> Ongoing.since ~now:1000.25 995.5));
  Alcotest.(check (option (float 1e-9))) "a drawn change survives a measurement"
    (Some 1020.) (Redraw.next_change ());
  (match Redraw.measuring (fun () -> ignore (Ongoing.since ~now:1000.25 995.5); raise Exit) with
   | () -> Alcotest.fail "the measurement raised"
   | exception Exit -> ());
  Alcotest.(check (option (float 1e-9))) "and a measurement that raises" (Some 1020.)
    (Redraw.next_change ())

(* RFC tui-one-screen-grammar §6.2: a set interval reads in at most two
   units and gives back the seconds it was set to; a day is [1d], never
   [24h]. *)
let test_a_set_interval_reads_its_exact_seconds () =
  List.iter
    (fun (seconds, expected) ->
      Alcotest.(check string) (Printf.sprintf "%d seconds" seconds) expected
        (Masc_tui_value.Interval.text seconds))
    [ 45, "45s"; 90, "1m30s"; 300, "5m"; 3600, "1h"; 5400, "1h30m"; 21600, "6h"
    ; 86400, "1d"; 93600, "1d02h"; 0, "0s" ]

(* A setting held in float seconds (a timeout, a cleanup interval) reads as
   the same ladder, rounded up so a sub-second setting is not [0s]; a value
   no int can hold falls to the ongoing ladder instead of an undefined
   conversion. *)
let test_a_float_setting_reads_its_whole_seconds () =
  List.iter
    (fun (seconds, expected) ->
      Alcotest.(check string) (Printf.sprintf "%g seconds" seconds) expected
        (Masc_tui_value.Interval.of_seconds seconds))
    [ 30., "30s"; 90., "1m30s"; 300., "5m"; 0.4, "1s"; 29.2, "30s"; 0., "0s"
    ; Float.nan, "0s"; Float.infinity, Masc_tui_value.Ongoing.text Float.infinity ]

(* Text built for a row that may be scrolled out of the window hands back
   when it reads differently instead of noting it, so only the caller that
   draws the row asks for a redraw. *)
let test_a_deferred_build_hands_its_change_back () =
  Redraw.begin_frame ();
  let text, change = Redraw.deferred (fun () -> Ongoing.since ~now:1000.25 995.5) in
  Alcotest.(check string) "the build returns its text"
    (Redraw.measuring (fun () -> Ongoing.since ~now:1000.25 995.5)) text;
  Alcotest.(check (option (float 1e-9))) "the frame notes nothing for it" None
    (Redraw.next_change ());
  Alcotest.(check (option (float 1e-9))) "the change is handed back" (Some 1000.5) change;
  ignore (Ongoing.since ~now:1000.25 900.);
  let _, change = Redraw.deferred (fun () -> Ongoing.since ~now:1000.25 995.5) in
  Alcotest.(check (option (float 1e-9))) "a later instant than the frame's own" (Some 1000.5) change;
  Alcotest.(check (option (float 1e-9))) "what the frame noted before stays" (Some 1020.)
    (Redraw.next_change ());
  let _, change = Redraw.deferred (fun () -> "no time text") in
  Alcotest.(check (option (float 1e-9))) "text without time hands back none" None change

let () =
  Alcotest.run "tui_value"
    [ ( "instant distance",
        [ Alcotest.test_case "earlier today" `Quick
            test_a_moment_earlier_today_is_the_same_day
        ; Alcotest.test_case "midnight ends the day" `Quick test_midnight_ends_the_day
        ; Alcotest.test_case "the same date last year" `Quick
            test_the_same_date_last_year_is_another_year
        ; Alcotest.test_case "new year ends the year" `Quick test_new_year_ends_the_year
        ; Alcotest.test_case "eight hours back across midnight" `Quick
            test_eight_hours_back_across_midnight_is_another_day
        ; Alcotest.test_case "an hour back before midnight" `Quick
            test_an_hour_back_before_midnight_is_today
        ; Alcotest.test_case "only another day adds a date" `Quick
            test_only_another_day_adds_a_date
        ; Alcotest.test_case "a UTC day turns at UTC midnight" `Quick
            test_a_utc_day_turns_at_utc_midnight
        ; Alcotest.test_case "a repeated hour is another hour" `Quick
            test_a_repeated_hour_is_another_hour
        ; Alcotest.test_case "a ruler marks only the start of an hour" `Quick
            test_a_ruler_marks_only_the_start_of_an_hour
        ; Alcotest.test_case "a day starts at its midnight" `Quick
            test_a_day_starts_at_its_midnight
        ] )
    ; ( "zone",
        [ Alcotest.test_case "offset across new year, east" `Quick
            test_the_offset_survives_new_year_east_of_utc
        ; Alcotest.test_case "offset across new year, west" `Quick
            test_the_offset_survives_new_year_west_of_utc
        ; Alcotest.test_case "a label carries one sign" `Quick
            test_a_zone_label_carries_one_sign
        ] )
    ; ( "count",
        [ Alcotest.test_case "a sign is not a digit" `Quick test_a_sign_is_not_a_digit
        ; Alcotest.test_case "only one is singular" `Quick test_only_one_is_singular
        ; Alcotest.test_case "cut rows are counted in the screen's language" `Quick
            test_cut_rows_are_counted_in_the_screens_language
        ] )
    ; ( "position",
        [ Alcotest.test_case "a window is handed only when it hides rows" `Quick
            test_a_window_is_handed_only_when_it_hides_rows
        ; Alcotest.test_case "a list names its selected row" `Quick
            test_a_list_names_its_selected_row
        ] )
    ; ( "hash",
        [ Alcotest.test_case "a hash keeps its head" `Quick test_a_hash_keeps_its_head ] )
    ; ( "interval",
        [ Alcotest.test_case "a set interval reads its exact seconds" `Quick
            test_a_set_interval_reads_its_exact_seconds
        ; Alcotest.test_case "a float setting reads its whole seconds" `Quick
            test_a_float_setting_reads_its_whole_seconds ] )
    ; ( "ongoing length",
        [ Alcotest.test_case "past a minute, at most once a minute" `Quick
            test_a_length_past_a_minute_changes_at_most_once_a_minute
        ; Alcotest.test_case "a countdown past a minute, at most once a minute" `Quick
            test_a_countdown_past_a_minute_changes_at_most_once_a_minute
        ; Alcotest.test_case "next change is when the reading differs" `Quick
            test_next_change_is_the_first_instant_the_reading_differs
        ; Alcotest.test_case "a countdown changes below its floor" `Quick
            test_a_countdown_changes_below_its_reading_floor
        ; Alcotest.test_case "the clock changes on the next minute" `Quick
            test_the_clock_changes_on_the_next_minute
        ; Alcotest.test_case "a frame notes its earliest change" `Quick
            test_a_frame_notes_its_earliest_change
        ; Alcotest.test_case "a narrow length past a minute, at most once a minute" `Quick
            test_a_narrow_length_past_a_minute_changes_at_most_once_a_minute
        ; Alcotest.test_case "a narrow next change is when the reading differs" `Quick
            test_a_narrow_next_change_is_the_first_instant_the_reading_differs
        ; Alcotest.test_case "a reading that holds notes when it ends" `Quick
            test_a_reading_that_holds_notes_when_it_ends
        ; Alcotest.test_case "a measurement notes nothing" `Quick
            test_a_measurement_notes_nothing
        ; Alcotest.test_case "a deferred build hands its change back" `Quick
            test_a_deferred_build_hands_its_change_back
        ] )
    ]
