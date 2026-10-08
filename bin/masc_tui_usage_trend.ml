type day_report = Measured of Masc.Tui_decode_usage.provider_usage_utilization * float option | Reported_no_windows

type sample = { observed_at : float; report : day_report }

type row = {
  scope_id : string;
  kind : string;
  limit_id : string option;
  marks : string;
  samples : sample option list;
  reported_days : int;
}

type t = {
  days : int;
  generated_at : float;
  unreadable_reports : int;
  rows : row list;
}

let no_report_mark = "\xc2\xb7"
let empty_report_mark = "\xe2\x97\x8b"

let seconds_per_day = 86400.0

let utc_day at = int_of_float (floor (at /. seconds_per_day))

(* [Masc_tui_chart.sparkline] draws eight levels, 0 to 7. A share scaled to
   the top level and floored lands on the level its part of the window
   reaches; the chart's own table is the one glyph set. *)
let top_level = 7

let mark share =
  if share < 0.0 then "↓" else if share > 1.0 then "↑" else
  if share = 0.0 then "0" else
  let clamped = Float.min 1.0 (Float.max 0.0 share) in
  Masc_tui_chart.sparkline ~min:0 ~max:top_level
    [ int_of_float (floor (clamped *. float_of_int top_level)) ]

module Key = struct
  type t = string * string * string option

  let compare (scope_l, kind_l, limit_l) (scope_r, kind_r, limit_r) =
    match String.compare scope_l scope_r with
    | 0 -> (
        match String.compare kind_l kind_r with
        | 0 -> Option.compare String.compare limit_l limit_r
        | order -> order)
    | order -> order
end

module Key_map = Map.Make (Key)
module Day_map = Map.Make (Int)

let of_history ~share (history : Masc.Tui_decode_usage.provider_usage_history) =
  let last_day = utc_day history.puh_generated_at in
  let first_day = last_day - history.puh_days + 1 in
  let by_key =
    List.fold_left
      (fun acc (point : Masc.Tui_decode_usage.provider_usage_history_point) ->
        let key = (point.puhp_scope_id, point.puhp_kind, point.puhp_limit_id) in
        let day = utc_day point.puhp_observed_at in
        Key_map.update key
          (fun known ->
            let known = Option.value ~default:Day_map.empty known in
            if day >= first_day && day <= last_day then
              Some (Day_map.add day { observed_at = point.puhp_observed_at; report = Measured (point.puhp_unit, share point.puhp_unit) } known)
            else Some known)
          acc)
      Key_map.empty history.puh_points
  in
  let by_key = List.fold_left (fun rows (report : Masc.Tui_decode_usage.provider_usage_empty_report) ->
    let day = utc_day report.puhe_observed_at in
    if day < first_day || day > last_day then rows else
    let matching = Key_map.exists (fun (scope, _, _) _ -> scope = report.puhe_scope_id) rows in
    let rows = if matching then rows
      else Key_map.add (report.puhe_scope_id, "account report", None) Day_map.empty rows in
    Key_map.mapi (fun (scope, _, _) days ->
      if scope <> report.puhe_scope_id || Day_map.mem day days then days
      else Day_map.add day { observed_at = report.puhe_observed_at; report = Reported_no_windows } days) rows)
      by_key history.puh_reported_no_windows in
  let rows =
    Key_map.bindings by_key
    |> List.map (fun ((scope_id, kind, limit_id), reported) ->
           let samples = List.init history.puh_days (fun offset ->
             Day_map.find_opt (first_day + offset) reported) in
           let marks = List.map (function
             | None -> no_report_mark
             | Some { report = Reported_no_windows; _ } -> empty_report_mark
             | Some { report = Measured (_, None); _ } -> "$"
             | Some { report = Measured (_, Some share); _ } -> mark share) samples |> String.concat "" in
           { scope_id; kind; limit_id; marks; samples;
             reported_days = Day_map.cardinal reported })
  in
  { days = history.puh_days;
    generated_at = history.puh_generated_at;
    unreadable_reports = history.puh_unreadable_reports;
    rows }

let latest row = List.find_map Fun.id (List.rev row.samples)

(* Four rows and eight glyph heights per cell set drawing resolution only;
   the full limit stays 100%, never the maximum of this account's reports. *)
let plot ~width trend row =
  let axis_cells = 7 in
  let days = List.length row.samples in
  if width <= 0 then []
  else if days = 0 || width < axis_cells + (days * 2) then
    let marks = List.map (function
      | None -> no_report_mark
      | Some {report = Measured (_, Some share); _} when share < 0.0 -> "↓"
      | Some {report = Measured (_, Some share); _} when share = 0.0 -> "0"
      | Some {report = Measured (_, Some share); _} when share > 1.0 -> "↑"
      | Some {report = Measured (_, Some share); _} -> mark share
      | Some {report = Measured (_, None); _} -> "$"
      | Some {report = Reported_no_windows; _} -> empty_report_mark) row.samples |> String.concat "" in
    Masc_tui_message_layout.wrap_words ~max_cells:width (marks ^ " (daily levels; · no report)")
  else
    let step = min 4 ((width - axis_cells) / days) in
    let pad text = text ^ String.make (max 0 (step - 1)) ' ' in
    let height = 4 in
    let bands = List.init height (fun index ->
      let band = height - index - 1 in
      let cells = List.map (function
        | None -> pad " "
        | Some {report = Measured (_, None) | Reported_no_windows; _} -> pad " "
        | Some {report = Measured (_, Some original_share); _} ->
          let share = Float.max 0.0 (Float.min 1.0 original_share) in
          let part = Float.max 0.0 (Float.min 1.0 (share *. float_of_int height -. float_of_int band)) in
          let glyph = if original_share > 1.0 && band = height - 1 then "↑"
            else if part <= 0.0 then " "
            else Masc_tui_chart.sparkline ~min:0 ~max:7
              [max 0 (min 7 (int_of_float (floor (part *. 8.0)) - 1))] in
          pad glyph) row.samples |> String.concat "" in
      Printf.sprintf "%3d%% │ %s" ((band + 1) * 100 / height) cells) in
    let baseline = "  0% └ " ^ (List.map (function
      | None -> pad no_report_mark
      | Some {report = Measured (_, Some share); _} when share < 0.0 -> pad "↓"
      | Some {report = Measured (_, Some share); _} when share = 0.0 -> pad "0"
      | Some {report = Measured (_, None); _} -> pad "$"
      | Some {report = Reported_no_windows; _} -> pad empty_report_mark
      | Some _ -> pad "─") row.samples |> String.concat "") in
    let first_day = utc_day trend.generated_at - days + 1 in
    let dates = List.init days (fun offset ->
      let day = Unix.gmtime (float_of_int (first_day + offset) *. seconds_per_day) in
      Printf.sprintf "%02d%s" day.Unix.tm_mday (String.make (max 0 (step - 2)) ' '))
      |> String.concat "" in
    bands @ [baseline; " UTC   " ^ dates]
