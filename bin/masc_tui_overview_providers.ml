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

let pad_right text cells =
  let gap = cells - cells_of text in
  if gap > 0 then text ^ String.make gap ' ' else text

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
  | Masc.Tui_decode_usage.Utilization_fraction value -> value
  | Masc.Tui_decode_usage.Utilization_percent value ->
      float_of_int value /. float_of_int percent_of_full

(* The full value of the unit the provider reported in, not a threshold. *)
let at_or_past_full = function
  | Masc.Tui_decode_usage.Utilization_fraction value -> value >= 1.0
  | Masc.Tui_decode_usage.Utilization_percent value -> value >= percent_of_full

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
   meter still shows what the provider last said. *)
let reset_text ~now = function
  | None -> (Some Ansi.dim, Masc_tui_theme.Glyph.no_value)
  | Some at when at <= now ->
      (Some (Theme.warn ()), "reset time passed \xc2\xb7 no newer report")
  | Some at ->
      ( None
      , Printf.sprintf "\xe2\x86\xbb %s in %s" (clock_text ~now at)
          (span_text (at -. now)) )

(* A clock that moved backwards says nothing rather than a negative age. *)
let heard_text ~now observed_at =
  Option.map
    (fun age -> Printf.sprintf "heard %s ago" age)
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

(* The first window opens its account card; subsequent windows share it. *)
type name_cell =
  | Account_name of string
  | No_name

type row =
  | Window_row of {
      name : name_cell;
      window : Masc.Tui_decode_usage.provider_usage_window;
      heard : string option;
      tag : string option;
    }
  | Silent_row of { name : string; tag : string }
      (** An account with no report since the server started, drawn only
          because the runtime catalogue observed its quota exhausted: that
          tag explains a stuck Keeper. *)
  | Email_row of string
      (** Account identity metadata, separate from window measurements. *)

(* Exhausted accounts first: a short budget cuts the section from the bottom,
   and the rows it keeps should be the ones that explain a stuck Keeper. Then
   accounts that reported, then the silent ones. *)
let account_rank observed (account : Masc.Tui_decode_usage.provider_usage_account) =
  match (observed, account.pua_state) with
  | Observed_exhausted _, _ -> 0
  | Not_observed_exhausted, Masc.Tui_decode_usage.Account_reported _ -> 1
  | Not_observed_exhausted, Masc.Tui_decode_usage.Account_not_reported_since_start -> 2

(* An account that has not reported since the server started and has no
   observed exhaustion draws nothing. Its row said only "no usage data" beside
   a generic setup name, which told the operator neither which account it was
   nor anything about it. *)
let account_rows ~now (observed, (account : Masc.Tui_decode_usage.provider_usage_account)) =
  let name = scope_name account in
  let tag = exhausted_tag ~now observed in
  match account.pua_state, tag with
  | Masc.Tui_decode_usage.Account_not_reported_since_start, None -> []
  | Masc.Tui_decode_usage.Account_not_reported_since_start, Some tag -> [ Silent_row { name; tag } ]
  | Masc.Tui_decode_usage.Account_reported (first, rest), (None | Some _) ->
      (* Windows of one report share its hearing time; a window heard at
         another time says its own. *)
      Window_row
        { name = Account_name name
        ; window = first
        ; heard = heard_text ~now first.puw_observed_at
        ; tag
        }
      :: List.map
           (fun (window : Masc.Tui_decode_usage.provider_usage_window) ->
             let heard =
               if Float.equal window.puw_observed_at first.puw_observed_at then
                 None
               else heard_text ~now window.puw_observed_at
             in
             Window_row { name = No_name; window; heard; tag = None })
           rest

let place_email email rows =
  match email with None -> rows | Some email -> rows @ [ Email_row email ]

(* The value column prints whole percents; past this many cells (192
   eighths) a wider meter adds ink, not resolution. *)
let meter_max_cells = 24

(* A meter narrower than ten cells gives the label its own row. *)
let meter_min_cells = 10

(* A window that counts something a model call does not need never alarms:
   it being full refuses no model call. A limit the server could not classify
   is drawn like one that gates, since nothing says it does not. *)
let window_tone (window : Masc.Tui_decode_usage.provider_usage_window) =
  match window.puw_role with
  | Masc.Tui_decode_usage.Role_counts_other_use -> Some Ansi.dim
  | Masc.Tui_decode_usage.Role_gates_model_calls | Masc.Tui_decode_usage.Role_unclassified_limit ->
      if at_or_past_full window.puw_utilization then Some (Theme.bad ())
      else None

let role_text = function
  | Masc.Tui_decode_usage.Role_gates_model_calls -> "Model call limit"
  | Masc.Tui_decode_usage.Role_counts_other_use -> "Other use · does not block model calls"
  | Masc.Tui_decode_usage.Role_unclassified_limit -> "Unclassified limit"

(* An account owns its heading and metadata. A long catalogue explanation
   never consumes the meter columns of every other account. *)
let draw_rows ~now ~width rows =
  let module Text = Masc_tui_message_layout in
  let groups =
    List.fold_left
      (fun groups row ->
        match row, groups with
        | Window_row { name = Account_name name; _ }, _
        | Silent_row { name; _ }, _ -> (name, [ row ]) :: groups
        | (Window_row { name = No_name; _ } | Email_row _), (name, held) :: rest ->
            (name, row :: held) :: rest
        | (Window_row { name = No_name; _ } | Email_row _), [] ->
            [ ("Usage", [ row ]) ])
      [] rows
    |> List.rev
    |> List.map (fun (name, held) -> name, List.rev held)
  in
  let gutter = 2 in
  (* Each side keeps enough cells for a 20-cell label and a useful meter. *)
  let minimum_card_cells = 64 in
  let paired = width >= 2 * minimum_card_cells + gutter in
  let card_width = if paired then (min width 180 - gutter) / 2 else width in
  let inner = max 1 (card_width - 4) in
  let quiet = Theme.recede () in
  let style tone text = match tone with
    | None -> text | Some tone -> tone ^ text ^ Ansi.reset
  in
  let wrap ?tone text =
    Text.wrap_words ~max_cells:inner text |> List.map (style tone)
  in
  let window_lines window heard =
    let label = window_label window in
    let value = "Used " ^ utilization_text window.Masc.Tui_decode_usage.puw_utilization in
    let label_cells = min 20 (max 6 (inner / 3)) in
    let value_cells = Text.display_width value in
    let room = inner - label_cells - value_cells - 4 in
    let meter_cells = max 1 (min meter_max_cells room) in
    let gauge = meter_open ^ meter ~cells:meter_cells (share_of_full window.puw_utilization)
                ^ meter_close ^ " " ^ value in
    let first =
      if room >= meter_min_cells && Text.display_width label <= label_cells then
        [ pad_right label label_cells ^ " " ^ style (window_tone window) gauge ]
      else wrap label @ wrap ?tone:(window_tone window) gauge
    in
    let reset_tone, reset = reset_text ~now window.puw_resets_at in
    let report = match window.puw_resets_at with
      | Some at when at <= now ->
          " · Last report " ^ clock_text ~now window.puw_observed_at
      | None | Some _ -> ""
    in
    let metadata = "Reset " ^ reset ^ report
      ^ (match heard with None -> "" | Some heard -> " · " ^ heard) in
    first @ wrap (role_text window.puw_role) @ wrap ?tone:reset_tone metadata
  in
  let render (name, held) =
    let blocked = List.exists (function
      | Window_row { tag = Some _; _ } | Silent_row _ -> true
      | Window_row { tag = None; _ } | Email_row _ -> false) held in
    let color = if blocked then Theme.bad () else Theme.info () in
    let body = List.concat_map (function
      | Email_row email -> wrap ~tone:quiet email
      | Silent_row { tag; _ } -> wrap "no usage data" @ wrap ~tone:(Theme.bad ()) ("Catalogue · " ^ tag)
      | Window_row { window; heard; tag; _ } ->
          window_lines window heard
          @ (match tag with None -> [] | Some tag -> wrap ~tone:(Theme.bad ()) ("Catalogue · " ^ tag))) held in
    let title = Text.fit_middle (max 1 (card_width - 4)) name in
    let top = color ^ Ansi.box_tl ^ " " ^ Ansi.bold ^ title ^ Ansi.reset ^ color
      ^ " " ^ draw_hline (max 0 (card_width - Text.display_width title - 4)) ^ Ansi.box_tr ^ Ansi.reset in
    let line content = quiet ^ Ansi.box_v ^ Ansi.reset ^ " "
      ^ Text.fit_width content inner ^ Ansi.reset ^ " " ^ quiet ^ Ansi.box_v ^ Ansi.reset in
    let bottom = quiet ^ Ansi.box_bl ^ draw_hline (max 0 (card_width - 2)) ^ Ansi.box_br ^ Ansi.reset in
    top :: List.map line body @ [ bottom ]
  in
  let rec arrange = function
    | [] -> []
    | left :: right :: rest when paired ->
        let left = render left and right = render right in
        let height = max (List.length left) (List.length right) in
        let row lines index = match List.nth_opt lines index with
          | Some line -> Text.fit_width line card_width
          | None -> String.make card_width ' ' in
        List.init height (fun i -> row left i ^ String.make gutter ' ' ^ row right i)
        @ [ "" ] @ arrange rest
    | card :: rest -> render card @ [ "" ] @ arrange rest
  in
  arrange groups

let title_text () = Printf.sprintf " %sPlan usage%s" Ansi.bold Ansi.reset

let section ~(providers : Types.overview_providers_reading) ~runtimes ~account_emails ~now
    ~width =
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
      let ordered =
        List.map
          (fun (account : Masc.Tui_decode_usage.provider_usage_account) ->
            (observed_exhaustion ~runtimes account.pua_scope, account))
          puws_accounts
        |> List.stable_sort (fun (oa, a) (ob, b) ->
               match Int.compare (account_rank oa a) (account_rank ob b) with
               | 0 -> String.compare (scope_name a) (scope_name b)
               | order -> order)
      in
      let accounts =
        List.filter_map
          (fun ((_, account) as entry) ->
            match account_rows ~now entry with
            | [] -> None
            | rows -> Some (account, rows))
          ordered
      in
      let rows =
        List.concat_map
          (fun (account, rows) ->
            place_email (account_email ~account_emails account) rows)
          accounts
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
      let notes = runtimes_note @ emails_note in
      match rows with
      | [] ->
          Some
            { title = title_text ()
            ; lines = [ " no usage data" ]
            }
      | _ :: _ ->
          Some
            { title = title_text ()
            ; lines = draw_rows ~now ~width rows @ notes
            }
