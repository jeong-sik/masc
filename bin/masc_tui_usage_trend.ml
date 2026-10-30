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

(* Five braille rows of line over the fixed 0-100% scale: twenty dot-levels.
   The rows set drawing resolution only; the full limit stays 100%, never
   the maximum of this account's reports. *)
let plot_height = 5

(* The Unicode Braille Patterns block's dot numbering: dx left to right, dy
   top to bottom, as in [Masc_tui_chart]. *)
let dot_mask ~dx ~dy =
  match dx, dy with
  | 0, 0 -> 0x01
  | 0, 1 -> 0x02
  | 0, 2 -> 0x04
  | 0, 3 -> 0x40
  | 1, 0 -> 0x08
  | 1, 1 -> 0x10
  | 1, 2 -> 0x20
  | 1, 3 -> 0x80
  | _ -> 0

(* A day that draws a point on the line: its share clipped to the scale for
   drawing, and whether it sits above the limit. *)
type plotted = {
  clipped : float;
  above : bool;
}

let point_of_sample = function
  | None -> None
  | Some { report = Reported_no_windows; _ } -> None
  | Some { report = Measured (_, None); _ } -> None
  | Some { report = Measured (_, Some share); _ } ->
      if Float.is_nan share then None
      else if Float.is_finite share then
        Some { clipped = Float.min 1.0 (Float.max 0.0 share); above = share > 1.0 }
      else if share > 0.0 then Some { clipped = 1.0; above = true }
      else Some { clipped = 0.0; above = false }

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
    let cells = days * step in
    let dot_rows = plot_height * 4 in
    let grid = Array.make_matrix plot_height cells 0 in
    (* A day's dot-column: the middle of its [step] cells. *)
    let dot_x day = (day * step * 2) + step in
    let dot_y clipped =
      int_of_float ((1.0 -. clipped) *. float_of_int (dot_rows - 1))
    in
    let set_dot x y =
      let cx = x / 2 and dx = x mod 2 and cy = y / 4 and dy = y mod 4 in
      if cx >= 0 && cx < cells && cy >= 0 && cy < plot_height then
        grid.(cy).(cx) <- grid.(cy).(cx) lor (dot_mask ~dx ~dy)
    in
    let points =
      List.mapi (fun day sample -> (day, point_of_sample sample)) row.samples
    in
    let plotted =
      List.filter_map
        (fun (day, point) ->
          Option.map (fun p -> (dot_x day, dot_y p.clipped)) point)
        points
    in
    (* Maximal runs of consecutive days; the line never crosses a gap. Two
       plotted days are consecutive exactly when their dot-columns are one
       day-slot apart. *)
    let runs =
      match plotted with
      | [] -> []
      | first :: rest ->
          let slot = step * 2 in
          let rec split current last runs = function
            | [] -> List.rev (List.rev current :: runs)
            | ((x, _) as point) :: tail ->
                if x - last = slot then split (point :: current) x runs tail
                else split [ point ] x (List.rev current :: runs) tail
          in
          split [ first ] (fst first) [] rest
    in
    (* One run is one unbroken line: each dot-column takes the interpolated
       height between its two days, filling down to the previous column so a
       steep move draws a solid stroke. *)
    let draw_run = function
      | [] -> ()
      | [ (x, y) ] -> set_dot x y
      | _ :: _ as run ->
          let prev_y = ref None in
          let stroke x y =
            let lo, hi =
              match !prev_y with None -> (y, y) | Some py -> (min py y, max py y)
            in
            prev_y := Some y;
            for yy = lo to hi do
              set_dot x yy
            done
          in
          let rec segments = function
            | (xa, ya) :: ((xb, yb) :: _ as tail) ->
                let span = xb - xa in
                for x = xa to xb do
                  let frac =
                    if span <= 0 then 0.0
                    else float_of_int (x - xa) /. float_of_int span
                  in
                  stroke x
                    (int_of_float
                       (float_of_int ya +. frac *. float_of_int (yb - ya)))
                done;
                segments tail
            | _ -> ()
          in
          segments run
    in
    List.iter draw_run runs;
    let above_cells =
      List.filter_map
        (fun (day, point) ->
          match point with
          | Some { above = true; _ } -> Some (dot_x day / 2)
          | Some { above = false; _ } | None -> None)
        points
    in
    let bands =
      List.init plot_height (fun index ->
          let band = plot_height - index - 1 in
          let buf = Buffer.create (cells * 3) in
          for cx = 0 to cells - 1 do
            if index = 0 && List.mem cx above_cells then Buffer.add_string buf "↑"
            else
              Buffer.add_string buf
                (Masc_tui_chart.braille_cell ~mask:grid.(index).(cx))
          done;
          Printf.sprintf "%3d%% │ %s" ((band + 1) * 100 / plot_height)
            (Buffer.contents buf))
    in
    let baseline = "  0% └ " ^ (List.map (function
      | None -> pad no_report_mark
      | Some {report = Measured (_, Some share); _} when share < 0.0 -> pad "↓"
      | Some {report = Measured (_, Some share); _} when share = 0.0 -> pad "0"
      | Some {report = Measured (_, None); _} -> pad "$"
      | Some {report = Reported_no_windows; _} -> pad empty_report_mark
      | Some {report = Measured (_, Some _); _} -> pad "─") row.samples |> String.concat "") in
    let first_day = utc_day trend.generated_at - days + 1 in
    let dates = List.init days (fun offset ->
      let day = Unix.gmtime (float_of_int (first_day + offset) *. seconds_per_day) in
      Printf.sprintf "%02d%s" day.Unix.tm_mday (String.make (max 0 (step - 2)) ' '))
      |> String.concat "" in
    bands @ [baseline; " UTC   " ^ dates]
