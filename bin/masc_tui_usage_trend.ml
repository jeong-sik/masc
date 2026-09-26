module Tui_decode = Masc.Tui_decode

type row = {
  scope_id : string;
  kind : string;
  limit_id : string option;
  marks : string;
  reported_days : int;
}

type t = {
  days : int;
  generated_at : float;
  unreadable_reports : int;
  rows : row list;
}

let no_report_mark = "\xc2\xb7"

let seconds_per_day = 86400.0

let utc_day at = int_of_float (floor (at /. seconds_per_day))

(* [Masc_tui_chart.sparkline] draws eight levels, 0 to 7. A share scaled to
   the top level and floored lands on the level its part of the window
   reaches; the chart's own table is the one glyph set. *)
let top_level = 7

let mark share =
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

let of_history ~share (history : Tui_decode.provider_usage_history) =
  let last_day = utc_day history.puh_generated_at in
  let first_day = last_day - history.puh_days + 1 in
  let by_key =
    List.fold_left
      (fun acc (point : Tui_decode.provider_usage_history_point) ->
        let key = (point.puhp_scope_id, point.puhp_kind, point.puhp_limit_id) in
        let day = utc_day point.puhp_observed_at in
        Key_map.update key
          (fun known ->
            let known = Option.value ~default:Day_map.empty known in
            if day >= first_day && day <= last_day then
              Some (Day_map.add day point.puhp_unit known)
            else Some known)
          acc)
      Key_map.empty history.puh_points
  in
  let rows =
    Key_map.bindings by_key
    |> List.map (fun ((scope_id, kind, limit_id), reported) ->
           let marks =
             List.init history.puh_days (fun offset ->
                 match Day_map.find_opt (first_day + offset) reported with
                 | None -> no_report_mark
                 | Some value -> mark (share value))
             |> String.concat ""
           in
           { scope_id; kind; limit_id; marks;
             reported_days = Day_map.cardinal reported })
  in
  { days = history.puh_days;
    generated_at = history.puh_generated_at;
    unreadable_reports = history.puh_unreadable_reports;
    rows }
