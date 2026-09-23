(* The Overview's Providers section. See the .mli for what it draws and what
   it refuses to guess. *)

module Tui_decode = Masc.Tui_decode
module Types = Masc_tui_types
open Masc_tui_ansi

type section = {
  title : string;
  lines : string list;
}

let cells_of = Masc_tui_message_layout.display_width

let pad_right text cells =
  let gap = cells - cells_of text in
  if gap > 0 then text ^ String.make gap ' ' else text

let pad_left text cells =
  let gap = cells - cells_of text in
  if gap > 0 then String.make gap ' ' ^ text else text

(* ---- meter ------------------------------------------------------------ *)

let eighths_per_cell = 8
let full_cell = "\xe2\x96\x88" (* U+2588 *)

(* A cell filled by 1..7 eighths, from the left: U+258F down to U+2589. *)
let partial_cell =
  [| ""
   ; "\xe2\x96\x8f"
   ; "\xe2\x96\x8e"
   ; "\xe2\x96\x8d"
   ; "\xe2\x96\x8c"
   ; "\xe2\x96\x8b"
   ; "\xe2\x96\x8a"
   ; "\xe2\x96\x89"
  |]

let meter_open = "\xe2\x96\x95" (* U+2595, right one-eighth block *)
let meter_close = "\xe2\x96\x8f" (* U+258F, left one-eighth block *)

let meter ~cells share =
  let cells = max 0 cells in
  let share =
    if Float.is_nan share then 0.0 else Float.min 1.0 (Float.max 0.0 share)
  in
  let filled =
    int_of_float
      (Float.round (share *. float_of_int (cells * eighths_per_cell)))
  in
  let whole = filled / eighths_per_cell in
  let part = filled mod eighths_per_cell in
  let buf = Buffer.create (cells * String.length full_cell) in
  for _ = 1 to whole do
    Buffer.add_string buf full_cell
  done;
  let drawn =
    if part > 0 then begin
      Buffer.add_string buf partial_cell.(part);
      whole + 1
    end
    else whole
  in
  for _ = drawn + 1 to cells do
    Buffer.add_char buf ' '
  done;
  Buffer.contents buf

(* ---- the provider's own values ---------------------------------------- *)

let percent_of_full = 100

(* Fraction and percent meet only here, to draw a meter. *)
let share_of_full = function
  | Tui_decode.Utilization_fraction value -> value
  | Tui_decode.Utilization_percent value ->
      float_of_int value /. float_of_int percent_of_full

(* The full value of the unit the provider reported in, not a threshold. *)
let at_or_past_full = function
  | Tui_decode.Utilization_fraction value -> value >= 1.0
  | Tui_decode.Utilization_percent value -> value >= percent_of_full

let value_text = function
  | Tui_decode.Utilization_fraction value -> Printf.sprintf "%g" value
  | Tui_decode.Utilization_percent value -> Printf.sprintf "%d%%" value

let minutes_per_hour = 60
let minutes_per_day = 24 * minutes_per_hour

(* The label only: a 300-minute window reads "5h" whatever the server called
   it, and two rows are never merged because their labels agree. *)
let minutes_label minutes =
  if minutes > 0 && minutes mod minutes_per_day = 0 then
    Printf.sprintf "%dd" (minutes / minutes_per_day)
  else if minutes > 0 && minutes mod minutes_per_hour = 0 then
    Printf.sprintf "%dh" (minutes / minutes_per_hour)
  else Printf.sprintf "%dm" minutes

let kind_label = function
  | Tui_decode.Window_five_hour -> "5h"
  | Tui_decode.Window_seven_day -> "7d"
  | Tui_decode.Window_duration_minutes minutes -> minutes_label minutes
  | Tui_decode.Window_provider_label label -> Terminal_text.single_line label

let window_label (window : Tui_decode.provider_usage_window) =
  match window.puw_limit_id with
  | None -> kind_label window.puw_kind
  | Some limit -> Terminal_text.single_line limit ^ " " ^ kind_label window.puw_kind

(* ---- time --------------------------------------------------------------- *)

let seconds_per_minute = 60
let seconds_per_hour = 60 * seconds_per_minute
let seconds_per_day = 24 * seconds_per_hour

let span_text seconds =
  let s = max 0 (int_of_float seconds) in
  if s < seconds_per_minute then Printf.sprintf "%ds" s
  else if s < seconds_per_hour then Printf.sprintf "%dm" (s / seconds_per_minute)
  else if s < seconds_per_day then
    Printf.sprintf "%dh%dm" (s / seconds_per_hour)
      (s mod seconds_per_hour / seconds_per_minute)
  else
    Printf.sprintf "%dd%dh" (s / seconds_per_day)
      (s mod seconds_per_day / seconds_per_hour)

(* The screen's clock is the terminal's zone, like every other row clock. A
   time on another day carries its date. *)
let clock_text ~now at =
  let tm = Unix.localtime at in
  let today = Unix.localtime now in
  if Int.equal tm.Unix.tm_year today.Unix.tm_year
     && Int.equal tm.Unix.tm_yday today.Unix.tm_yday
  then Printf.sprintf "%02d:%02d" tm.Unix.tm_hour tm.Unix.tm_min
  else
    Printf.sprintf "%02d-%02d %02d:%02d" (tm.Unix.tm_mon + 1) tm.Unix.tm_mday
      tm.Unix.tm_hour tm.Unix.tm_min

(* A reset time that has passed is said, not hidden and not drawn as an empty
   window: the server keeps the last report until a newer one arrives, so the
   meter still shows what the provider last said. *)
let reset_text ~now = function
  | None -> (Ansi.dim, "reset time not reported")
  | Some at when at <= now ->
      (Theme.warn (), "reset time passed \xc2\xb7 no newer report")
  | Some at ->
      ( ""
      , Printf.sprintf "\xe2\x86\xbb %s in %s" (clock_text ~now at)
          (span_text (at -. now)) )

let heard_text ~now observed_at =
  Printf.sprintf "heard %s ago" (span_text (now -. observed_at))

(* ---- accounts ----------------------------------------------------------- *)

let account_name (account : Tui_decode.provider_usage_account) =
  match account.pua_providers with
  | [] -> Terminal_text.single_line account.pua_scope
  | providers -> Terminal_text.single_line (String.concat "," providers)

(* The runtime catalogue's own [quota_exhausted], joined by quota scope. *)
let observed_exhausted ~runtimes scope =
  match (runtimes : Types.overview_quota_reading) with
  | Types.Quota_read options ->
      List.exists
        (fun (option : Tui_decode.runtime_option) ->
          option.ro_quota_exhausted
          && Option.equal String.equal option.ro_quota_scope (Some scope))
        options
  | Types.Quota_unread | Types.Quota_failed _ -> false

let exhausted_tag = "exhausted (observed)"

type row =
  | Window_row of {
      name : string;
      window : Tui_decode.provider_usage_window;
      heard : string option;
      tagged : bool;
    }
  | Silent_row of { name : string; tagged : bool }

let reported_rank (account : Tui_decode.provider_usage_account) =
  match account.pua_state with
  | Tui_decode.Account_reported _ -> 0
  | Tui_decode.Account_not_reported_since_start -> 1

let account_rows ~runtimes ~now (account : Tui_decode.provider_usage_account) =
  let name = account_name account in
  let tagged = observed_exhausted ~runtimes account.pua_scope in
  match account.pua_state with
  | Tui_decode.Account_not_reported_since_start -> [ Silent_row { name; tagged } ]
  | Tui_decode.Account_reported (first, rest) ->
      (* Windows of one report share its hearing time; a window heard at
         another time says its own. *)
      Window_row
        { name
        ; window = first
        ; heard = Some (heard_text ~now first.puw_observed_at)
        ; tagged
        }
      :: List.map
           (fun (window : Tui_decode.provider_usage_window) ->
             let heard =
               if Float.equal window.puw_observed_at first.puw_observed_at then
                 None
               else Some (heard_text ~now window.puw_observed_at)
             in
             Window_row { name = ""; window; heard; tagged = false })
           rest

let widest cells_of_row rows =
  List.fold_left (fun widest row -> max widest (cells_of_row row)) 0 rows

let tail_text ~heard ~tagged =
  match (heard, tagged) with
  | None, false -> ""
  | Some heard, false -> heard
  | None, true -> exhausted_tag
  | Some heard, true -> heard ^ "  " ^ exhausted_tag

let draw_rows ~now ~width rows =
  let name_w =
    widest (function Window_row { name; _ } | Silent_row { name; _ } -> cells_of name) rows
  in
  let window_cells f =
    widest (function Window_row { window; _ } -> cells_of (f window) | Silent_row _ -> 0) rows
  in
  let label_w = window_cells window_label in
  let value_w =
    window_cells (fun (window : Tui_decode.provider_usage_window) ->
        value_text window.puw_utilization)
  in
  let reset_w =
    window_cells (fun (window : Tui_decode.provider_usage_window) ->
        snd (reset_text ~now window.puw_resets_at))
  in
  let tail_w =
    widest
      (function
        | Window_row { heard; tagged; _ } -> cells_of (tail_text ~heard ~tagged)
        | Silent_row _ -> 0)
      rows
  in
  (* Leading space, name, gap, label, space, two meter edges, space, value,
     gap, reset, gap, tail: what is left is the meter's. *)
  let columns =
    1 + name_w + 2 + label_w + 1 + 2 + 1 + value_w + 2 + reset_w + 2 + tail_w
  in
  let meter_cells = max 1 (width - columns) in
  let tag_styled = Theme.bad () ^ exhausted_tag ^ Ansi.reset in
  List.map
    (function
      | Silent_row { name; tagged } ->
          Printf.sprintf " %s  %sno report since server start%s%s"
            (pad_right name name_w) Ansi.dim Ansi.reset
            (if tagged then "  " ^ tag_styled else "")
      | Window_row { name; window; heard; tagged } ->
          let full = at_or_past_full window.puw_utilization in
          let tone = if full then Theme.bad () else "" in
          let untone = if full then Ansi.reset else "" in
          let reset_tone, reset = reset_text ~now window.puw_resets_at in
          let heard_part =
            match heard with
            | None -> ""
            | Some heard -> Ansi.dim ^ heard ^ Ansi.reset
          in
          let tag_part =
            match (heard, tagged) with
            | _, false -> ""
            | None, true -> tag_styled
            | Some _, true -> "  " ^ tag_styled
          in
          Printf.sprintf " %s  %s %s%s%s%s %s%s  %s%s%s  %s%s"
            (pad_right name name_w)
            (pad_right (window_label window) label_w)
            tone meter_open
            (meter ~cells:meter_cells (share_of_full window.puw_utilization))
            meter_close
            (pad_left (value_text window.puw_utilization) value_w)
            untone reset_tone (pad_right reset reset_w)
            (if String.equal reset_tone "" then "" else Ansi.reset)
            heard_part tag_part)
    rows

let title_text ?note () =
  let head = Printf.sprintf " %sProviders%s" Ansi.bold Ansi.reset in
  match note with
  | None -> head
  | Some note -> Printf.sprintf "%s  %s%s%s" head Ansi.dim note Ansi.reset

let section ~(providers : Types.overview_providers_reading) ~runtimes ~now ~width =
  match providers with
  | Types.Providers_unread -> None
  | Types.Providers_failed reason ->
      Some
        { title = title_text ()
        ; lines =
            [ Printf.sprintf " %sproviders unavailable: %s%s" (Theme.warn ())
                (Terminal_text.single_line reason) Ansi.reset
            ]
        }
  | Types.Providers_read { Tui_decode.puws_since; puws_accounts } ->
      let ordered =
        List.stable_sort
          (fun a b ->
            match Int.compare (reported_rank a) (reported_rank b) with
            | 0 -> String.compare (account_name a) (account_name b)
            | order -> order)
          puws_accounts
      in
      let rows = List.concat_map (account_rows ~runtimes ~now) ordered in
      let body =
        match rows with
        | [] ->
            [ Printf.sprintf " %sno provider account in the runtime catalogue%s"
                Ansi.dim Ansi.reset
            ]
        | _ :: _ -> draw_rows ~now ~width rows
      in
      (* Without the runtime rows the exhausted tag cannot be drawn; the
         section says so instead of drawing every account untagged. *)
      let runtimes_note =
        match (runtimes : Types.overview_quota_reading) with
        | Types.Quota_failed reason ->
            [ Printf.sprintf " %sexhausted tags unread: %s%s" Ansi.dim
                (Terminal_text.single_line reason) Ansi.reset
            ]
        | Types.Quota_unread | Types.Quota_read _ -> []
      in
      Some
        { title =
            title_text
              ~note:
                (Printf.sprintf
                   "reported by the provider \xc2\xb7 since server start %s"
                   (clock_text ~now puws_since))
              ()
        ; lines = body @ runtimes_note
        }
