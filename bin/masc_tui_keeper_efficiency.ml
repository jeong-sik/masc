module Decode = Masc.Tui_decode_keeper_efficiency

type month_view = Decode.month_view

let month_of ~now = Keeper_efficiency.month_of_unix_time now
let path ~month = "/api/v1/keeper-efficiency?month=" ^ month
let timeout_sec = 120.0

let decode json =
  Result.map_error Decode.decode_error_to_string (Decode.of_json json)
;;

type tone =
  | Plain
  | Dim
  | Bad

let single_line = Masc.Tui_terminal_text.sanitize_terminal_text
let per_turn ~turns value = value /. float_of_int turns

let row_lines ~month (view : month_view) (row : Decode.keeper_month) =
  let fleet = view.fleet in
  let heading =
    Printf.sprintf "Efficiency %s (%d days, fleet %d turns)" month view.days_covered
      fleet.turns_total
  in
  if row.turns = 0
  then
    [ Plain, heading
    ; ( Dim
      , Printf.sprintf "no turn counted; %d tool calls, %d failed" row.calls row.failed )
    ]
  else
    let turns = row.turns in
    [ Plain, heading
    ; ( Plain
      , Printf.sprintf "%d turns · %.1f calls/turn (fleet %.1f) · %.1f tool s/turn (fleet %.1f)"
          turns
          (per_turn ~turns (float_of_int row.calls))
          fleet.calls_per_turn
          (per_turn ~turns (row.tool_ms /. 1000.))
          fleet.tool_s_per_turn )
    ; ( Plain
      , Printf.sprintf "%.0f output tokens/turn (fleet %.0f) · %d of %d calls failed"
          (per_turn ~turns (float_of_int row.output_tokens))
          fleet.output_tokens_per_turn
          row.failed
          row.calls )
    ]
;;

let view_lines ~month view ~keeper_name =
  match Decode.keeper_row view ~keeper:keeper_name with
  | Some row -> row_lines ~month view row
  | None ->
    [ Dim, Printf.sprintf "Efficiency %s: no turn of this Keeper in %d days" month view.days_covered ]
;;

let lines fetched ~keeper_name =
  match Masc_tui_fetched.current fetched with
  | None -> []
  | Some (month, observation) ->
    (match observation with
     | Masc_tui_fetched.Absent -> []
     | Masc_tui_fetched.Loading ->
       [ Dim, Printf.sprintf "Efficiency %s: reading; the first read of a month can take a minute" month ]
     | Masc_tui_fetched.Failed detail ->
       [ Bad, Printf.sprintf "Efficiency %s: not read: %s" month (single_line detail) ]
     | Masc_tui_fetched.Ready view -> view_lines ~month view ~keeper_name
     | Masc_tui_fetched.Stale (view, detail) ->
       view_lines ~month view ~keeper_name
       @ [ Dim, "the last refresh failed: " ^ single_line detail ])
;;
