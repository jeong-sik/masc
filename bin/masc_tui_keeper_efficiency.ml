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

let row_lines ~ko ~month (view : month_view) (row : Decode.keeper_month) =
  let fleet = view.fleet in
  let heading =
    Printf.sprintf
      (if ko then "%s 효율 (%d일, 전체 %d턴)" else "Efficiency %s (%d days, fleet %d turns)")
      month view.days_covered fleet.turns_total
  in
  if row.turns = 0
  then
    [ Plain, heading
    ; ( Dim
      , Printf.sprintf
          (if ko then "센 턴 없음 \xc2\xb7 도구 호출 %d회, 실패 %d회"
           else "no turn counted; %d tool calls, %d failed")
          row.calls row.failed )
    ]
  else
    let turns = row.turns in
    [ Plain, heading
    ; ( Plain
      , Printf.sprintf
          (if ko then "%d턴 · 턴당 호출 %.1f (전체 %.1f) · 턴당 도구 %.1f초 (전체 %.1f)"
           else "%d turns · %.1f calls/turn (fleet %.1f) · %.1f tool s/turn (fleet %.1f)")
          turns
          (per_turn ~turns (float_of_int row.calls))
          fleet.calls_per_turn
          (per_turn ~turns (row.tool_ms /. 1000.))
          fleet.tool_s_per_turn )
    ; ( Plain
      , Printf.sprintf
          (if ko then "턴당 출력 토큰 %.0f (전체 %.0f) · 실패 %d / 호출 %d"
           else "%.0f output tokens/turn (fleet %.0f) · %d of %d calls failed")
          (per_turn ~turns (float_of_int row.output_tokens))
          fleet.output_tokens_per_turn
          row.failed
          row.calls )
    ]
;;

let view_lines ~ko ~month view ~keeper_name =
  match Decode.keeper_row view ~keeper:keeper_name with
  | Some row -> row_lines ~ko ~month view row
  | None ->
    [ ( Dim
      , Printf.sprintf
          (if ko then "%s 효율: %d일 동안 이 Keeper 의 턴 없음"
           else "Efficiency %s: no turn of this Keeper in %d days")
          month view.days_covered )
    ]
;;

let lines ~ko fetched ~keeper_name =
  match Masc_tui_fetched.current fetched with
  | None -> []
  | Some (month, observation) ->
    (match observation with
     | Masc_tui_fetched.Absent -> []
     | Masc_tui_fetched.Loading ->
       [ ( Dim
         , Printf.sprintf
             (if ko then "%s 효율: 읽는 중 \xc2\xb7 그 달의 첫 읽기는 1분쯤 걸릴 수 있음"
              else "Efficiency %s: reading; the first read of a month can take a minute")
             month )
       ]
     | Masc_tui_fetched.Failed detail ->
       [ ( Bad
         , Printf.sprintf
             (if ko then "%s 효율: 읽지 못함: %s" else "Efficiency %s: not read: %s")
             month (single_line detail) )
       ]
     | Masc_tui_fetched.Ready view -> view_lines ~ko ~month view ~keeper_name
     | Masc_tui_fetched.Stale (view, detail) ->
       view_lines ~ko ~month view ~keeper_name
       @ [ Dim, (if ko then "마지막 갱신 실패: " else "the last refresh failed: ") ^ single_line detail ])
;;
