(* The Usage surface's Plan usage section. See the .mli for what it draws and
   what it refuses to guess. *)

module Tui_decode = Masc.Tui_decode
module Types = Masc_tui_types
open Masc_tui_ansi

type section = {
  title : string;
  lines : string list;
}

let cells_of = Masc_tui_message_layout.display_width

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
  let valid_share = Float.is_finite share && share >= 0.0 && share <= 1.0 in
  let share =
    if not (Float.is_finite share) then 0.0 else Float.min 1.0 (Float.max 0.0 share)
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
    Buffer.add_string buf (if valid_share then "░" else " ")
  done;
  Buffer.contents buf

(* ---- the provider's own values ---------------------------------------- *)

let percent_of_full = 100

(* Fraction and percent meet only here, to draw a meter. *)
let share_of_full = function
  | Masc.Tui_decode_usage.Utilization_fraction value -> Some value
  | Masc.Tui_decode_usage.Utilization_percent value ->
      Some (float_of_int value /. float_of_int percent_of_full)
  | Masc.Tui_decode_usage.Utilization_usd { used; limit = Some limit } -> Some (used /. limit)
  | Masc.Tui_decode_usage.Utilization_usd { limit = None; _ } -> None

(* The full value of the unit the provider reported in, not a threshold. *)
let at_or_past_full = function
  | Masc.Tui_decode_usage.Utilization_fraction value -> Float.is_finite value && value >= 1.0
  | Masc.Tui_decode_usage.Utilization_percent value -> value >= percent_of_full
  | Masc.Tui_decode_usage.Utilization_usd { used; limit = Some limit } -> used >= limit
  | Masc.Tui_decode_usage.Utilization_usd { limit = None; _ } -> false

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
  | Masc.Tui_decode_usage.Utilization_fraction value when Float.is_finite value ->
      Printf.sprintf "%d%%" (percent_of_fraction value)
  | Masc.Tui_decode_usage.Utilization_fraction value ->
      (* Not a number to convert: shown as it came. *)
      Printf.sprintf "%g" value
  | Masc.Tui_decode_usage.Utilization_percent value -> Printf.sprintf "%d%%" value
  | Masc.Tui_decode_usage.Utilization_usd { used; limit = Some limit } ->
      Printf.sprintf "$%.4f / $%.4f" used limit
  | Masc.Tui_decode_usage.Utilization_usd { used; limit = None } -> Printf.sprintf "$%.4f" used

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
  | Masc.Tui_decode_usage.Window_five_hour -> "5h"
  | Masc.Tui_decode_usage.Window_seven_day -> "7d"
  | Masc.Tui_decode_usage.Window_duration_minutes minutes -> minutes_label minutes
  | Masc.Tui_decode_usage.Window_provider_label label -> Terminal_text.single_line label

let window_label (window : Masc.Tui_decode_usage.provider_usage_window) =
  match window.puw_limit_id with
  | None -> kind_label window.puw_kind
  | Some limit -> Terminal_text.single_line limit ^ " " ^ kind_label window.puw_kind

(* ---- time --------------------------------------------------------------- *)

(* The screen's one ladder, so a countdown here reads like every other span
   on the Overview. *)
let span_text = Masc_tui_message_layout.span_text

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
   meter still shows what the provider last said. The short form keeps the
   countdown and drops the clock, for a row that has no room for both. *)
type reset_words = {
  reset_tone : string option;
  reset_full : string;
  reset_short : string;
}

let reset_words ~now = function
  | None -> { reset_tone = None; reset_full = "no reset"; reset_short = "no reset" }
  | Some at when at <= now ->
      { reset_tone = Some (Theme.warn ())
      ; reset_full = "reset time passed \xc2\xb7 no newer report"
      ; reset_short = "reset passed"
      }
  | Some at ->
      { reset_tone = None
      ; reset_full =
          Printf.sprintf "resets %s (%s)" (clock_text ~now at) (span_text (at -. now))
      ; reset_short = Printf.sprintf "resets in %s" (span_text (at -. now))
      }

(* A clock that moved backwards says nothing rather than a negative age. *)
let heard_text ~now observed_at =
  Option.map
    (fun age -> Printf.sprintf "reported %s ago" age)
    (Masc_tui_message_layout.age_text ~now ~since:observed_at)

(* ---- accounts ----------------------------------------------------------- *)

(* The server names the scope's id on the row, the same id its history
   points carry; hashing it again here would be a second definition that
   could drift from the first. *)
let scope_id (account : Masc.Tui_decode_usage.provider_usage_account) =
  account.pua_scope_id

(* The id's leading cells, enough to tell scopes apart on one screen. *)
let scope_id_cells = 8

let scope_name (account : Masc.Tui_decode_usage.provider_usage_account) =
  let id = scope_id account in
  let id =
    Terminal_text.single_line
      (String.sub id 0 (min scope_id_cells (String.length id)))
  in
  match account.pua_providers with
  | [] -> "scope " ^ id
  | providers ->
      Terminal_text.single_line
        (String.concat ", "
           (List.map
              (fun (provider : Masc.Tui_decode_usage.provider_usage_provider) ->
                provider.pup_display_name)
              providers))
      ^ " · " ^ id

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

(* ---- what can be used now ----------------------------------------------- *)

(* A limit that spending it refuses model calls on. A limit the server could
   not classify counts here too: nothing says it does not gate. *)
let gates_model_calls = function
  | Masc.Tui_decode_usage.Role_gates_model_calls
  | Masc.Tui_decode_usage.Role_unclassified_limit -> true
  | Masc.Tui_decode_usage.Role_counts_other_use -> false

(* The one decision behind the header's "At limit (reported)" count and the
   Unusable section: the provider's own report is at its full value, on a
   window that gates model calls. *)
let window_at_limit (window : Masc.Tui_decode_usage.provider_usage_window) =
  gates_model_calls window.puw_role && at_or_past_full window.puw_utilization

let observed_blocked = function
  | Observed_exhausted _ -> true
  | Not_observed_exhausted -> false

(* A window cannot be used now when its report is at its limit, or when the
   runtime catalogue observed the whole account exhausted and the window
   gates model calls. *)
let blocks_use_now ~observed window =
  window_at_limit window
  ||
  match observed with
  | Observed_exhausted _ -> gates_model_calls window.Masc.Tui_decode_usage.puw_role
  | Not_observed_exhausted -> false

type plan_section =
  | Unusable_now
  | Usable
  | No_report

(* The catalogue's observation is a fact about the account, not about one
   window, so only the Unusable_now entry draws it. An account split across
   sections would otherwise say it twice. *)
let drawn_observation section observed =
  match section with
  | Unusable_now -> observed
  | Usable | No_report -> Not_observed_exhausted

(* Draw order of the sections. *)
let all_sections = [ Unusable_now; Usable; No_report ]

let section_rank = function
  | Unusable_now -> 0
  | Usable -> 1
  | No_report -> 2

type plan_entry = {
  pe_account : Masc.Tui_decode_usage.provider_usage_account;
  pe_observed : observed;
  pe_windows : Masc.Tui_decode_usage.provider_usage_window list;
      (** The account's windows that belong to this section, drawn first to
          last. Empty for an account with no window to show. *)
}

type plan_group = {
  pg_section : plan_section;
  pg_entries : plan_entry list;
}

(* How long until a window opens again. A window with no reset time is the
   longest wait there is. *)
type reset_wait =
  | Waits_for of float
  | No_reset_stated

let wait_of ~now = function
  | None -> No_reset_stated
  | Some at -> Waits_for (at -. now)

let longest_wait_first left right =
  match (left, right) with
  | No_reset_stated, No_reset_stated -> 0
  | No_reset_stated, Waits_for _ -> -1
  | Waits_for _, No_reset_stated -> 1
  | Waits_for l, Waits_for r -> Float.compare r l

let longer_wait left right =
  if longest_wait_first left right <= 0 then left else right

(* How much of a window is used, for ordering. A window that gates nothing,
   an amount with no cap and a value that is not a number press on nothing. *)
type pressure =
  | Used_share of float
  | Unmeasured

let pressure_of (window : Masc.Tui_decode_usage.provider_usage_window) =
  if not (gates_model_calls window.puw_role) then Unmeasured
  else
    match share_of_full window.puw_utilization with
    | Some share when Float.is_finite share -> Used_share share
    | Some _ | None -> Unmeasured

let most_pressed_first left right =
  match (left, right) with
  | Used_share l, Used_share r -> Float.compare r l
  | Used_share _, Unmeasured -> -1
  | Unmeasured, Used_share _ -> 1
  | Unmeasured, Unmeasured -> 0

let window_wait ~now (window : Masc.Tui_decode_usage.provider_usage_window) =
  wait_of ~now window.puw_resets_at

let observed_wait ~now = function
  | Observed_exhausted at -> wait_of ~now at
  | Not_observed_exhausted -> No_reset_stated

(* [List.stable_sort] keeps the server's order for windows that tie. *)
let sort_windows_by compare_key windows =
  List.stable_sort (fun left right -> compare_key left right) windows

let entry_wait ~now entry =
  match entry.pe_windows with
  | [] -> observed_wait ~now entry.pe_observed
  | first :: rest ->
      List.fold_left
        (fun longest window -> longer_wait longest (window_wait ~now window))
        (window_wait ~now first) rest

let entry_pressure entry =
  match entry.pe_windows with
  | [] -> Unmeasured
  | first :: rest ->
      List.fold_left
        (fun worst window ->
          let pressure = pressure_of window in
          if most_pressed_first pressure worst < 0 then pressure else worst)
        (pressure_of first) rest

(* One account becomes one entry per section it has a window in. An account
   observed exhausted always has an entry in Unusable_now, even with no
   window to show, so its catalogue state is drawn. *)
let entries_of ~now (observed, (account : Masc.Tui_decode_usage.provider_usage_account)) =
  let entry windows =
    { pe_account = account; pe_observed = observed; pe_windows = windows }
  in
  match account.pua_state with
  | Masc.Tui_decode_usage.Account_not_reported_since_start
  | Masc.Tui_decode_usage.Account_reported_no_windows _ ->
      [ ((if observed_blocked observed then Unusable_now else No_report), entry []) ]
  | Masc.Tui_decode_usage.Account_reported (first, rest) ->
      let blocked, open_ =
        List.partition (blocks_use_now ~observed) (first :: rest)
      in
      let blocked =
        sort_windows_by
          (fun left right ->
            longest_wait_first (window_wait ~now left) (window_wait ~now right))
          blocked
      in
      let open_ =
        sort_windows_by
          (fun left right -> most_pressed_first (pressure_of left) (pressure_of right))
          open_
      in
      (match (blocked, observed_blocked observed) with
       | [], false -> []
       | [], true | _ :: _, true | _ :: _, false -> [ (Unusable_now, entry blocked) ])
      @ (match open_ with [] -> [] | _ :: _ -> [ (Usable, entry open_) ])

let compare_entries ~now section left right =
  let primary =
    match section with
    | Unusable_now -> longest_wait_first (entry_wait ~now left) (entry_wait ~now right)
    | Usable -> most_pressed_first (entry_pressure left) (entry_pressure right)
    | No_report -> 0
  in
  match primary with
  | 0 -> String.compare (scope_name left.pe_account) (scope_name right.pe_account)
  | order -> order

(* Unusable windows first, then the rest with the least left first, then
   accounts that have not reported. Ties go by account name. *)
let plan ~now ~runtimes accounts =
  let placed =
    List.concat_map
      (fun (account : Masc.Tui_decode_usage.provider_usage_account) ->
        entries_of ~now (observed_exhaustion ~runtimes account.pua_scope, account))
      accounts
  in
  List.filter_map
    (fun section ->
      let entries =
        List.filter_map
          (fun (placed_in, entry) ->
            if Int.equal (section_rank placed_in) (section_rank section) then Some entry
            else None)
          placed
      in
      match entries with
      | [] -> None
      | _ :: _ ->
          Some
            { pg_section = section
            ; pg_entries = List.stable_sort (compare_entries ~now section) entries
            })
    all_sections

(* The account's email, read from its client's login file, for each provider
   billed to it. Two providers on one scope normally name one account; if they
   name two, both are drawn, since that is what the login files say. *)
let account_email ~account_emails (account : Masc.Tui_decode_usage.provider_usage_account) =
  match (account_emails : Types.overview_account_emails_reading) with
  | Types.Account_emails_read { emails; unreadable_rows = _ } ->
      let found =
        List.filter_map
          (fun (provider : Masc.Tui_decode_usage.provider_usage_provider) ->
            List.assoc_opt provider.pup_id emails)
          account.pua_providers
      in
      (match List.sort_uniq String.compare found with
       | [] -> None
       | distinct -> Some (Terminal_text.single_line (String.concat ", " distinct)))
  | Types.Account_emails_unread | Types.Account_emails_failed _ -> None

(* ---- one line per window ------------------------------------------------ *)

let indent = " "
let indent_cells = 1

(* "100%" is the widest reading a gauge normally shows. *)
let percent_cells = 4

(* A bar wider than this adds ink, not resolution: the percent beside it
   prints whole numbers. A narrow screen shrinks it down to the minimum. *)
let bar_cells_default = 12
let bar_cells_min = 6

(* Cells the open and close marks of a bar take. *)
let bar_frame_cells = 2

(* The name and label columns hold their longest entry, up to a cap, and
   give way on a narrow screen. The name takes at most one over this many
   cells of the row; the label takes what is left after the name, the
   narrowest bar and the widest amount-and-countdown. *)
let name_cells_cap = 28
let name_cells_min = 8
let name_width_divisor = 3
let label_cells_cap = 24
let label_cells_min = 6

let detail_gap = "   "
let detail_separator = " \xc2\xb7 "

let usd_decimals = 2

(* Whole amounts read as "$100", others with cents. *)
let usd_text value =
  if Float.is_finite value && Float.equal (Float.round value) value then
    Printf.sprintf "$%.0f" value
  else Printf.sprintf "$%.*f" usd_decimals value

let money_text = function
  | Masc.Tui_decode_usage.Utilization_usd { used; limit = Some limit } ->
      Some (usd_text used ^ "/" ^ usd_text limit)
  | Masc.Tui_decode_usage.Utilization_usd { used; limit = None } ->
      Some ("spent " ^ usd_text used)
  | Masc.Tui_decode_usage.Utilization_fraction _
  | Masc.Tui_decode_usage.Utilization_percent _ -> None

(* A window that gates model calls says nothing more; the others say what
   they are, since their tone alone does not. *)
let role_tag = function
  | Masc.Tui_decode_usage.Role_gates_model_calls -> None
  | Masc.Tui_decode_usage.Role_counts_other_use -> Some "other use"
  | Masc.Tui_decode_usage.Role_unclassified_limit -> Some "unclassified"

(* A window that counts something a model call does not need never alarms:
   it being full refuses no model call. A limit the server could not classify
   is drawn like one that gates, since nothing says it does not. *)
let window_tone (window : Masc.Tui_decode_usage.provider_usage_window) =
  if not (gates_model_calls window.puw_role) then Some Ansi.dim
  else if at_or_past_full window.puw_utilization then Some (Theme.bad ())
  else None

(* When the account's newest report was heard. *)
let newest_report (account : Masc.Tui_decode_usage.provider_usage_account) =
  match account.pua_state with
  | Masc.Tui_decode_usage.Account_reported (first, rest) ->
      Some
        (List.fold_left
           (fun newest (window : Masc.Tui_decode_usage.provider_usage_window) ->
             Float.max newest window.puw_observed_at)
           first.puw_observed_at rest)
  | Masc.Tui_decode_usage.Account_not_reported_since_start
  | Masc.Tui_decode_usage.Account_reported_no_windows _ -> None

type window_line = {
  label : string;
  share : float option;  (** [None]: an amount with no cap has no bar. *)
  percent : string;
  detail : string;  (** Amount, reset with its clock, then notes. *)
  detail_short : string;  (** The same with the countdown only. *)
  detail_base : string;
      (** Amount and countdown, no notes: what the bar's width leaves room
          for. A note that does not fit wraps to its own line. *)
  tone : string option;
  detail_tone : string option;
}

(* A window heard at a different time than its account's newest report says
   so; otherwise the time is left out. *)
let window_line ~now ~newest (window : Masc.Tui_decode_usage.provider_usage_window) =
  let utilization = window.puw_utilization in
  let share = share_of_full utilization in
  let percent =
    match share with
    | Some share -> utilization_text (Masc.Tui_decode_usage.Utilization_fraction share)
    | None -> ""
  in
  let reset = reset_words ~now window.puw_resets_at in
  let heard =
    match newest with
    | Some newest when not (Float.equal newest window.puw_observed_at) ->
        heard_text ~now window.puw_observed_at
    | Some _ | None -> None
  in
  let amount = money_text utilization in
  let detail_with reset_part notes =
    String.concat detail_separator
      (List.filter_map Fun.id ([ amount; Some reset_part ] @ notes))
  in
  let notes = [ heard; role_tag window.puw_role ] in
  let tone = window_tone window in
  { label = window_label window
  ; share
  ; percent
  ; detail = detail_with reset.reset_full notes
  ; detail_short = detail_with reset.reset_short notes
  ; detail_base = detail_with reset.reset_short []
  ; tone
  ; detail_tone = (match reset.reset_tone with Some _ -> reset.reset_tone | None -> tone)
  }

type entry_body =
  | Window_lines of window_line list
  | State_text of string
      (** An account with no window to show says why. *)

type drawn_entry = {
  de_name : string;
  de_body : entry_body;
  de_tag : string option;
      (** The catalogue's observed exhaustion, in the Unusable section only. *)
  de_email : string option;
      (** Drawn once per account, with its first entry. *)
}

let state_text ~now (account : Masc.Tui_decode_usage.provider_usage_account) =
  match account.pua_state with
  | Masc.Tui_decode_usage.Account_not_reported_since_start ->
      "No usage report since server start"
  | Masc.Tui_decode_usage.Account_reported_no_windows { observed_at; source } ->
      "Provider reported no usage windows \xc2\xb7 Last report "
      ^ clock_text ~now observed_at ^ " \xc2\xb7 " ^ Terminal_text.single_line source
  | Masc.Tui_decode_usage.Account_reported _ -> "No reported window gates model calls"

let drawn_groups ~now ~account_emails groups =
  let _, drawn =
    List.fold_left
      (fun (seen, drawn) { pg_section; pg_entries } ->
        let seen, entries =
          List.fold_left
            (fun (seen, entries) entry ->
              let id = scope_id entry.pe_account in
              let first_time = not (List.mem id seen) in
              let newest = newest_report entry.pe_account in
              let body =
                match entry.pe_windows with
                | [] -> State_text (state_text ~now entry.pe_account)
                | _ :: _ as windows ->
                    Window_lines (List.map (window_line ~now ~newest) windows)
              in
              let tag =
                exhausted_tag ~now (drawn_observation pg_section entry.pe_observed)
              in
              let email =
                if first_time then account_email ~account_emails entry.pe_account
                else None
              in
              ( id :: seen
              , { de_name = scope_name entry.pe_account
                ; de_body = body
                ; de_tag = tag
                ; de_email = email
                }
                :: entries ))
            (seen, []) pg_entries
        in
        (seen, (pg_section, List.rev entries) :: drawn))
      ([], []) groups
  in
  List.rev drawn

let section_title = function
  | Unusable_now -> "Unusable now"
  | Usable -> "Usable"
  | No_report -> "No report"

let section_tone = function
  | Unusable_now -> Theme.bad ()
  | Usable -> Theme.info ()
  | No_report -> Theme.recede ()

let pad_left text cells =
  let gap = cells - cells_of text in
  if gap > 0 then String.make gap ' ' ^ text else text

let rstrip_spaces text =
  let stop = ref (String.length text) in
  while !stop > 0 && Char.equal text.[!stop - 1] ' ' do
    decr stop
  done;
  String.sub text 0 !stop

let style tone text =
  match tone with None -> text | Some tone -> tone ^ text ^ Ansi.reset

(* Every line is cut to the screen: a column that cannot shrink further loses
   its tail rather than the row's edge. *)
let clip width line =
  if cells_of line <= width then line else Masc_tui_message_layout.fit_width line width

(* The column widths one drawing of entries settles on at a width. The name
   column holds its longest name up to a cap, the label column what is left,
   and the bar keeps its default width and shrinks, down to its minimum, until
   the widest amount-and-countdown fits beside it. A row whose detail is still
   too wide drops the reset clock; one that is wider still moves its detail to
   a row of its own. *)
type layout = {
  width : int;
  name_cells : int;
  label_cells : int;
  bar_cells : int;
  blank_name : string;
  continuation : string;
  continuation_cells : int;
}

(* [show_names] is [false] where the entry's name is already drawn, as a
   card's title: the name column is then empty and its width goes to the
   rest of the row. *)
let layout_for ~show_names ~width entries =
  let budget = max 1 (width - indent_cells) in
  let widest cells_of_item items = List.fold_left (fun w item -> max w (cells_of_item item)) 0 items in
  let window_lines =
    List.concat_map
      (fun entry ->
        match entry.de_body with Window_lines lines -> lines | State_text _ -> [])
      entries
  in
  let name_cells =
    if not show_names then 0
    else
      min
        (widest (fun entry -> cells_of entry.de_name) entries)
        (min name_cells_cap (max name_cells_min (budget / name_width_divisor)))
  in
  let barred_lines =
    List.filter
      (fun line -> match line.share with Some _ -> true | None -> false)
      window_lines
  in
  let widest_base = widest (fun line -> cells_of line.detail_base) barred_lines in
  let gauge_cells_min = bar_cells_min + bar_frame_cells + 1 + percent_cells in
  let label_room =
    budget - name_cells - 1 - 1 - gauge_cells_min - cells_of detail_gap - widest_base
  in
  let label_cells =
    min
      (widest (fun line -> cells_of line.label) window_lines)
      (min label_cells_cap (max label_cells_min label_room))
  in
  let head_cells_without_bar =
    name_cells + 1 + label_cells + 1 + bar_frame_cells + 1 + percent_cells
  in
  let detail_room = budget - head_cells_without_bar - cells_of detail_gap in
  let bar_cells = max bar_cells_min (min bar_cells_default (detail_room - widest_base)) in
  let blank_name = String.make name_cells ' ' in
  { width
  ; name_cells
  ; label_cells
  ; bar_cells
  ; blank_name
  ; continuation = indent ^ blank_name ^ " "
  ; continuation_cells = max 1 (budget - name_cells - 1)
  }

(* One entry's rows, at the columns [layout] settled on. *)
let draw_entry layout tone entry =
  let module Text = Masc_tui_message_layout in
  let name_cell tone name =
    Ansi.bold ^ tone ^ Text.fit_middle layout.name_cells name ^ Ansi.reset
  in
  let window_row tone ~first line =
    let name = match first with Some name -> name_cell tone name | None -> layout.blank_name in
    let label = Text.fit_middle layout.label_cells line.label in
    let gauge_width = layout.bar_cells + bar_frame_cells + 1 + percent_cells in
    let gauge =
      match line.share with
      | Some share ->
          meter_open ^ meter ~cells:layout.bar_cells share ^ meter_close ^ " "
          ^ pad_left line.percent percent_cells
      | None -> String.make gauge_width ' '
    in
    (* A row with no bar has an empty gauge. When the detail does not fit
       after that empty space, it moves left into it before it wraps. *)
    let bodies =
      match line.share with
      | Some _ -> [ (label ^ " " ^ gauge, detail_gap) ]
      | None -> [ (label ^ " " ^ gauge, detail_gap); (label, " ") ]
    in
    let head body = indent ^ name ^ " " ^ style line.tone body in
    let placements =
      List.concat_map
        (fun (body, gap) ->
          List.map (fun detail -> (body, gap, detail)) [ line.detail; line.detail_short ])
        bodies
    in
    let fits (body, gap, detail) =
      cells_of (head body) + cells_of gap + cells_of detail <= layout.width
    in
    match List.find_opt fits placements with
    | Some (body, gap, detail) -> [ head body ^ gap ^ style line.detail_tone detail ]
    | None ->
        head (rstrip_spaces (label ^ " " ^ gauge))
        :: List.map
             (fun wrapped -> layout.continuation ^ style line.detail_tone wrapped)
             (Text.wrap_words ~max_cells:layout.continuation_cells line.detail)
  in
  let note_lines ?tone text =
    List.map
      (fun wrapped -> layout.continuation ^ style tone wrapped)
      (Text.wrap_words ~max_cells:layout.continuation_cells text)
  in
  let rows =
    match entry.de_body with
    | Window_lines lines ->
        List.concat
          (List.mapi
             (fun index line ->
               window_row tone ~first:(if index = 0 then Some entry.de_name else None) line)
             lines)
    | State_text text ->
        (match Text.wrap_words ~max_cells:layout.continuation_cells text with
         | [] -> [ indent ^ name_cell tone entry.de_name ]
         | first :: rest ->
             (indent ^ name_cell tone entry.de_name ^ " " ^ first)
             :: List.map (fun wrapped -> layout.continuation ^ wrapped) rest)
  in
  rows
  @ (match entry.de_tag with
     | None -> []
     | Some tag -> note_lines ~tone:(Theme.bad ()) ("Catalogue \xc2\xb7 " ^ tag))
  @ (match entry.de_email with
     | None -> []
     | Some email -> note_lines ~tone:(Theme.recede ()) email)

let group_heading section entries =
  " " ^ Ansi.bold ^ section_tone section
  ^ Printf.sprintf "%s (%d)" (section_title section) (List.length entries)
  ^ Ansi.reset

let hidden_unusable_heading section entries =
  group_heading section entries
  ^ Theme.recede () ^ " \xc2\xb7 hidden \xc2\xb7 x:show" ^ Ansi.reset

(* One empty line between blocks so each reads as a unit. *)
let rec separated = function
  | [] -> []
  | [ block ] -> block
  | block :: rest -> block @ ("" :: separated rest)

let draw_groups ~show_unusable ~width groups =
  let entries = List.concat_map snd groups in
  let layout = layout_for ~show_names:true ~width entries in
  let draw_group (section, entries) =
    match section with
    | Unusable_now when not show_unusable -> [ hidden_unusable_heading section entries ]
    | Unusable_now | Usable | No_report ->
        group_heading section entries
        :: separated (List.map (draw_entry layout (section_tone section)) entries)
  in
  List.map (clip width) (separated (List.map draw_group groups))

(* ---- cards: one box per account ----------------------------------------- *)

(* Two columns of cards, so a card is at least this wide. A window's label,
   bar, percent and reset countdown take about this many cells at the default
   bar width; a card a little narrower still reads, with the longest countdown
   moved to a row of its own. *)
let card_columns = 2
let card_gap = 2
let card_min_width = 52
let card_row_gap = 1

let cards_fit ~width =
  Masc_tui_card.columns_that_fit ~inner_width:(max 0 (width - indent_cells))
    ~gap:card_gap ~min_card_width:card_min_width ~max_columns:card_columns
  >= card_columns

let rec pairs = function
  | [] -> []
  | [ only ] -> [ [ only ] ]
  | first :: second :: rest -> [ first; second ] :: pairs rest

(* An account's windows as a card titled with its name. The name column is
   empty inside the card: the title already says it. *)
let account_card ~tone entry =
  { Masc_tui_card.title = entry.de_name
  ; body =
      (fun ~cells ->
        draw_entry (layout_for ~show_names:false ~width:cells [ entry ]) tone entry)
  }

(* Each pair of accounts is one row of cards that end on the same line; a lone
   last account leaves its neighbour's place empty rather than stretching
   across the screen. *)
let draw_card_rows ~width ~tone entries =
  let style =
    { Masc_tui_card.edge = Theme.recede ()
    ; title_style = Ansi.bold ^ tone
    ; reset = Ansi.reset
    }
  in
  let inner_width = max 0 (width - indent_cells) in
  let row pair =
    let cards = List.map (account_card ~tone) pair in
    let columns =
      match cards with
      | [ only ] -> [ [ only ]; [] ]
      | _ :: _ :: _ | [] -> List.map (fun card -> [ card ]) cards
    in
    match
      Masc_tui_card.grid ~style ~inner_width ~gap:card_gap ~row_gap:card_row_gap
        ~max_rows:max_int columns
    with
    | Some rows -> List.map (fun line -> indent ^ line) rows
    | None -> []
  in
  separated (List.map row (pairs entries))

let draw_cards ~show_unusable ~width groups =
  let draw_group (section, entries) =
    match section with
    | Unusable_now when not show_unusable -> [ hidden_unusable_heading section entries ]
    | Unusable_now | Usable | No_report ->
        group_heading section entries
        :: draw_card_rows ~width ~tone:(section_tone section) entries
  in
  List.map (clip width) (separated (List.map draw_group groups))

type blocked_count =
  | Blocked_unknown
  | Blocked_accounts of int

type counts = {
  accounts : int;
  reporting : int;
  at_limit : int;
  blocked : blocked_count;
}

(* The header's four numbers. [at_limit] counts accounts, by the same
   {!window_at_limit} that puts a window in Unusable_now. *)
let counts ~runtimes (accounts : Masc.Tui_decode_usage.provider_usage_account list) =
  let count keep = List.length (List.filter keep accounts) in
  { accounts = List.length accounts
  ; reporting =
      count (fun account ->
          match account.pua_state with
          | Masc.Tui_decode_usage.Account_reported _
          | Masc.Tui_decode_usage.Account_reported_no_windows _ -> true
          | Masc.Tui_decode_usage.Account_not_reported_since_start -> false)
  ; at_limit =
      count (fun account ->
          match account.pua_state with
          | Masc.Tui_decode_usage.Account_reported (first, rest) ->
              List.exists window_at_limit (first :: rest)
          | Masc.Tui_decode_usage.Account_not_reported_since_start
          | Masc.Tui_decode_usage.Account_reported_no_windows _ -> false)
  ; blocked =
      (match (runtimes : Types.overview_quota_reading) with
       | Types.Quota_read _ ->
           Blocked_accounts
             (count (fun account ->
                  observed_blocked (observed_exhaustion ~runtimes account.pua_scope)))
       | Types.Quota_unread | Types.Quota_failed _ -> Blocked_unknown)
  }

let title_text () = Printf.sprintf " %sPlan usage%s" Ansi.bold Ansi.reset

let section_with ~draw ~(providers : Types.overview_providers_reading) ~runtimes
    ~account_emails ~now ~width =
  match providers with
  | Types.Providers_unread -> None
  | Types.Providers_failed reason ->
      Some
        { title = title_text ()
        ; lines =
            [ Printf.sprintf " %susage data unavailable: %s%s" (Theme.warn ())
                (Terminal_text.single_line reason) Ansi.reset
            ]
        }
  | Types.Providers_read { Masc.Tui_decode_usage.puws_since = _; puws_accounts } ->
      let rows =
        draw (drawn_groups ~now ~account_emails (plan ~now ~runtimes puws_accounts))
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
      (* Without the account email reading the rows are drawn with no email.
         The section says why rather than implying the accounts have none. *)
      let emails_note =
        match (account_emails : Types.overview_account_emails_reading) with
        | Types.Account_emails_failed reason ->
            [ Printf.sprintf " %saccount emails unread: %s%s" Ansi.dim
                (Terminal_text.single_line reason) Ansi.reset
            ]
        | Types.Account_emails_read { unreadable_rows; _ } when unreadable_rows > 0 ->
            [ Printf.sprintf " %saccount emails: %d rows this build cannot read%s" Ansi.dim
                unreadable_rows Ansi.reset
            ]
        | Types.Account_emails_unread | Types.Account_emails_read _ -> []
      in
      let counts = counts ~runtimes puws_accounts in
      let blocked =
        match counts.blocked with
        | Blocked_unknown -> "unknown"
        | Blocked_accounts count -> string_of_int count
      in
      let summary =
        [ Printf.sprintf "Accounts %d \xc2\xb7 Reporting %d \xc2\xb7 At limit (reported) %d \xc2\xb7 Blocked (observed) %s"
            counts.accounts counts.reporting counts.at_limit blocked
        ; "Bar: share used at the last report \xc2\xb7 dim row: does not block model calls \xc2\xb7 v: Trend graphs" ]
        |> List.concat_map (Masc_tui_message_layout.wrap_words ~max_cells:width) in
      let notes = runtimes_note @ emails_note in
      match rows with
      | [] ->
          Some
            { title = title_text ()
            ; lines = summary @ [ " no usage data" ] @ notes
            }
      | _ :: _ ->
          Some
            { title = title_text ()
            ; lines = summary @ ("" :: rows) @ notes
            }

let section ~providers ~runtimes ~account_emails ~now ~show_unusable ~width =
  section_with ~draw:(draw_groups ~show_unusable ~width) ~providers ~runtimes
    ~account_emails ~now ~width

let section_cards ~providers ~runtimes ~account_emails ~now ~show_unusable ~width =
  let draw =
    if cards_fit ~width then draw_cards ~show_unusable ~width
    else draw_groups ~show_unusable ~width
  in
  section_with ~draw ~providers ~runtimes ~account_emails ~now ~width
