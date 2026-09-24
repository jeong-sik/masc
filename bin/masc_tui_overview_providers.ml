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
  (* Floor, so only a share at or past full fills the last eighth; a share
     above zero that floors to nothing still draws the thinnest glyph. *)
  let filled =
    match
      int_of_float (Float.floor (share *. float_of_int (cells * eighths_per_cell)))
    with
    | 0 when share > 0.0 && cells > 0 -> 1
    | filled -> filled
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

(* Twelve significant digits cut binary noise such as 0.29 *. 100. =
   28.999999999999996 before the floor, and still keep 0.9999 below 100. *)
let percent_digits = 12

(* One unit on screen, so two accounts read side by side. A fraction becomes
   a whole percent, floored like the meter: 0.9999 reads 99%, never 100%. The
   decoded value is unchanged. *)
let percent_of_fraction value =
  let hundredths =
    float_of_string (Printf.sprintf "%.*g" percent_digits (value *. float_of_int percent_of_full))
  in
  int_of_float (Float.floor hundredths)

let utilization_text = function
  | Tui_decode.Utilization_fraction value when Float.is_finite value ->
      Printf.sprintf "%d%%" (percent_of_fraction value)
  | Tui_decode.Utilization_fraction value ->
      (* Not a number to convert: shown as it came. *)
      Printf.sprintf "%g" value
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
  | None -> (Some Ansi.dim, "reset time not reported")
  | Some at when at <= now ->
      (Some (Theme.warn ()), "reset time passed \xc2\xb7 no newer report")
  | Some at ->
      ( None
      , Printf.sprintf "\xe2\x86\xbb %s in %s" (clock_text ~now at)
          (span_text (at -. now)) )

let heard_text ~now observed_at =
  Printf.sprintf "heard %s ago" (span_text (now -. observed_at))

(* ---- accounts ----------------------------------------------------------- *)

let account_name (account : Tui_decode.provider_usage_account) =
  let id =
    Digest.to_hex (Digest.string account.pua_scope)
    |> fun hex -> String.sub hex 0 8
  in
  match account.pua_providers with
  | [] -> "account " ^ id
  | providers -> Terminal_text.single_line (String.concat "," providers) ^ " · " ^ id

(* The runtime catalogue's own [quota_exhausted], joined by quota scope,
   with the reopen time the catalogue states for it. That time is the
   catalogue's, not the provider's window reset, and is drawn apart from it. *)
type observed =
  | Not_observed_exhausted
  | Observed_exhausted of float option
      (** The latest [quota_resets_at] among the scope's exhausted runtimes;
          [None] when none of them states one. *)

let later left right =
  match (left, right) with
  | Some l, Some r -> Some (Float.max l r)
  | Some at, None | None, Some at -> Some at
  | None, None -> None

let observed_exhaustion ~runtimes scope =
  match (runtimes : Types.overview_quota_reading) with
  | Types.Quota_read options ->
      List.fold_left
        (fun observed (option : Tui_decode.runtime_option) ->
          if
            option.ro_quota_exhausted
            && Option.equal String.equal option.ro_quota_scope (Some scope)
          then
            match observed with
            | Not_observed_exhausted -> Observed_exhausted option.ro_quota_resets_at
            | Observed_exhausted at ->
                Observed_exhausted (later at option.ro_quota_resets_at)
          else observed)
        Not_observed_exhausted options
  | Types.Quota_unread | Types.Quota_failed _ -> Not_observed_exhausted

let exhausted_tag ~now = function
  | Not_observed_exhausted -> None
  | Observed_exhausted None ->
      Some "exhausted (observed) \xc2\xb7 catalogue reopen time not stated"
  | Observed_exhausted (Some at) when at <= now ->
      Some "exhausted (observed) \xc2\xb7 catalogue reopen time passed"
  | Observed_exhausted (Some at) ->
      Some
        (Printf.sprintf "exhausted (observed) \xc2\xb7 catalogue reopens %s in %s"
           (clock_text ~now at) (span_text (at -. now)))

type row =
  | Window_row of {
      name : string;
      window : Tui_decode.provider_usage_window;
      heard : string option;
      tag : string option;
    }
  | Silent_row of { name : string; tag : string option }

(* Exhausted accounts first: a short budget cuts the section from the bottom,
   and the rows it keeps should be the ones that explain a stuck Keeper. Then
   accounts that reported, then the silent ones. *)
let account_rank observed (account : Tui_decode.provider_usage_account) =
  match (observed, account.pua_state) with
  | Observed_exhausted _, _ -> 0
  | Not_observed_exhausted, Tui_decode.Account_reported _ -> 1
  | Not_observed_exhausted, Tui_decode.Account_not_reported_since_start -> 2

let account_rows ~now (observed, (account : Tui_decode.provider_usage_account)) =
  let name = account_name account in
  let tag = exhausted_tag ~now observed in
  match account.pua_state with
  | Tui_decode.Account_not_reported_since_start -> [ Silent_row { name; tag } ]
  | Tui_decode.Account_reported (first, rest) ->
      (* Windows of one report share its hearing time; a window heard at
         another time says its own. *)
      Window_row
        { name
        ; window = first
        ; heard = Some (heard_text ~now first.puw_observed_at)
        ; tag
        }
      :: List.map
           (fun (window : Tui_decode.provider_usage_window) ->
             let heard =
               if Float.equal window.puw_observed_at first.puw_observed_at then
                 None
               else Some (heard_text ~now window.puw_observed_at)
             in
             Window_row { name = ""; window; heard; tag = None })
           rest

let widest cells_of_row rows =
  List.fold_left (fun widest row -> max widest (cells_of_row row)) 0 rows

(* Columns left to right by what a narrow row can least afford to lose: the
   box cuts a row from the right, so the observed exhaustion tag sits beside
   the value, and the hearing age, the least of them, comes last. *)
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
        utilization_text window.puw_utilization)
  in
  let reset_w =
    window_cells (fun (window : Tui_decode.provider_usage_window) ->
        snd (reset_text ~now window.puw_resets_at))
  in
  let gap = "  " in
  let tag_cells = function
    | None -> 0
    | Some tag -> cells_of gap + cells_of tag
  in
  let tag_w =
    widest
      (function Window_row { tag; _ } | Silent_row { tag; _ } -> tag_cells tag)
      rows
  in
  let heard_w =
    widest
      (function
        | Window_row { heard = Some heard; _ } -> cells_of gap + cells_of heard
        | Window_row { heard = None; _ } | Silent_row _ -> 0)
      rows
  in
  (* Every cell of a window row but the meter: leading space, name, gap,
     label, space, the meter's two edges, space, value, tag, gap, reset,
     heard. *)
  let columns =
    1 + name_w + cells_of gap + label_w + 1 + cells_of meter_open
    + cells_of meter_close + 1 + value_w + tag_w + cells_of gap + reset_w
    + heard_w
  in
  let meter_cells = max 1 (width - columns) in
  let tag_part = function
    | None -> ""
    | Some tag -> gap ^ Theme.bad () ^ tag ^ Ansi.reset
  in
  let styled style text =
    match style with
    | None -> text
    | Some style -> style ^ text ^ Ansi.reset
  in
  List.map
    (function
      | Silent_row { name; tag } ->
          " " ^ pad_right name name_w ^ gap
          ^ styled (Some Ansi.dim) "no report since server start"
          ^ tag_part tag
      | Window_row { name; window; heard; tag } ->
          let tone =
            if at_or_past_full window.puw_utilization then Some (Theme.bad ())
            else None
          in
          let reset_tone, reset = reset_text ~now window.puw_resets_at in
          let heard_part =
            match heard with
            | None -> ""
            | Some heard -> gap ^ styled (Some Ansi.dim) heard
          in
          let tag_pad = String.make (tag_w - tag_cells tag) ' ' in
          " " ^ pad_right name name_w ^ gap
          ^ pad_right (window_label window) label_w
          ^ " "
          ^ styled tone
              (meter_open
              ^ meter ~cells:meter_cells (share_of_full window.puw_utilization)
              ^ meter_close ^ " "
              ^ pad_left (utilization_text window.puw_utilization) value_w)
          ^ tag_part tag ^ tag_pad ^ gap
          ^ styled reset_tone (pad_right reset reset_w)
          ^ heard_part)
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
        List.map
          (fun (account : Tui_decode.provider_usage_account) ->
            (observed_exhaustion ~runtimes account.pua_scope, account))
          puws_accounts
        |> List.stable_sort (fun (oa, a) (ob, b) ->
               match Int.compare (account_rank oa a) (account_rank ob b) with
               | 0 -> String.compare (account_name a) (account_name b)
               | order -> order)
      in
      let rows = List.concat_map (account_rows ~now) ordered in
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
      (* A catalogue with no runtime has no provider account: an empty mixer
         has no strip, and the section takes no row from the tasks. *)
      match rows with
      | [] -> None
      | _ :: _ ->
      Some
        { title =
            title_text
              ~note:
                (Printf.sprintf
                   "reported by the provider \xc2\xb7 since server start %s"
                   (clock_text ~now puws_since))
              ()
        ; lines = draw_rows ~now ~width rows @ runtimes_note
        }
