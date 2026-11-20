module Decode = Masc.Tui_decode_keeper_efficiency
module Theme = Masc_tui_ansi.Theme
module Ansi = Masc_tui_ansi.Ansi

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

let wrap_style style text =
  if String.equal style "" then text else style ^ text ^ Ansi.reset
;;

let mini_bar ~series ~value ~reference =
  let ceiling = Float.max value reference in
  let scaled =
    if not (Float.is_finite value) || value <= 0. || not (Float.is_finite ceiling) || ceiling <= 0.
    then 0
    else max 1 (min 1000 (Float.to_int (Float.round (value /. ceiling *. 1000.))))
  in
  let scale = Masc_tui_chart.Series { paint = Theme.paint (); series } in
  Masc_tui_chart.meter_bar ~width:8 ~value:scaled ~max_value:1000 ~scale
    ~track_style:(Theme.recede ()) ~reset:Ansi.reset ()
;;

let row_lines ~ko ~month (view : month_view) (row : Decode.keeper_month) =
  let fleet = view.fleet in
  let recede = wrap_style (Theme.recede ()) in
  let heading =
    wrap_style Ansi.bold
      (Printf.sprintf
         (if ko then "%s 효율 (%d일, 전체 %s턴)" else "Efficiency %s (%d days, fleet %s turns)")
         month view.days_covered (Masc_tui_value.Count.grouped fleet.turns_total))
  in
  if row.turns = 0
  then
    [ Plain, heading
    ; ( Dim
      , Printf.sprintf
          (if ko then "센 턴 없음 \xc2\xb7 도구 호출 %s회, 실패 %s회"
           else "no turn counted; %s tool calls, %s failed")
          (Masc_tui_value.Count.grouped row.calls) (Masc_tui_value.Count.grouped row.failed) )
    ]
  else
    let turns = row.turns in
    let calls_pt = per_turn ~turns (float_of_int row.calls) in
    let tool_s_pt = per_turn ~turns (row.tool_ms /. 1000.) in
    let out_tok_pt = per_turn ~turns (float_of_int row.output_tokens) in
    let calls_bar = mini_bar ~series:Masc_tui_theme.Calls ~value:calls_pt ~reference:fleet.calls_per_turn in
    let tool_bar = mini_bar ~series:Masc_tui_theme.Latency ~value:tool_s_pt ~reference:fleet.tool_s_per_turn in
    let tok_bar = mini_bar ~series:Masc_tui_theme.Usage ~value:out_tok_pt ~reference:fleet.output_tokens_per_turn in
    let fail_style =
      if row.failed > 0 && row.failed = row.calls then Theme.bad ()
      else if row.failed > 0 then Theme.warn ()
      else Theme.recede ()
    in
    let fail_text =
      wrap_style fail_style
        (if ko then Printf.sprintf "실패 %s / 호출 %s" (Masc_tui_value.Count.grouped row.failed) (Masc_tui_value.Count.grouped row.calls)
         else Printf.sprintf "%s of %s calls failed" (Masc_tui_value.Count.grouped row.failed) (Masc_tui_value.Count.grouped row.calls))
    in
    let sep = recede " · " in
    [ Plain, heading
    ; ( Plain
      , if ko then
          Printf.sprintf "%s턴%s턴당 호출 %.1f %s %s%s턴당 도구 %.1f초 %s %s"
            (Masc_tui_value.Count.grouped turns) sep calls_pt calls_bar
            (recede (Printf.sprintf "(전체 %.1f)" fleet.calls_per_turn))
            sep tool_s_pt tool_bar
            (recede (Printf.sprintf "(전체 %.1f)" fleet.tool_s_per_turn))
        else
          Printf.sprintf "%s turns%s%.1f calls/turn %s %s%s%.1f tool s/turn %s %s"
            (Masc_tui_value.Count.grouped turns) sep calls_pt calls_bar
            (recede (Printf.sprintf "(fleet %.1f)" fleet.calls_per_turn))
            sep tool_s_pt tool_bar
            (recede (Printf.sprintf "(fleet %.1f)" fleet.tool_s_per_turn)) )
    ; ( Plain
      , if ko then
          Printf.sprintf "턴당 출력 토큰 %.0f %s %s%s%s"
            out_tok_pt tok_bar
            (recede (Printf.sprintf "(전체 %.0f)" fleet.output_tokens_per_turn))
            sep fail_text
        else
          Printf.sprintf "%.0f output tokens/turn %s %s%s%s"
            out_tok_pt tok_bar
            (recede (Printf.sprintf "(fleet %.0f)" fleet.output_tokens_per_turn))
            sep fail_text )
    ]
;;

let view_lines ~ko ~month view ~keeper_name =
  match Decode.keeper_row view ~keeper:keeper_name with
  | Some row -> row_lines ~ko ~month view row
  | None ->
    [ ( Dim
      , Printf.sprintf
          (if ko then "%s 효율: %d일 동안 이 키퍼의 턴 없음"
           else "Efficiency %s: no turn of this Keeper in %d days")
          month view.days_covered )
    ]
;;

type failure = Read_failed of string | Read_kept_back of string

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
     | Masc_tui_fetched.Failed (Read_failed detail) ->
       [ ( Bad
         , Printf.sprintf
             (if ko then "%s 효율 읽기 실패 \xc2\xb7 %s"
              else "Efficiency %s read failed \xc2\xb7 %s")
             month (single_line detail) )
       ]
     | Masc_tui_fetched.Failed (Read_kept_back notice) -> [ Bad, single_line notice ]
     | Masc_tui_fetched.Ready view -> view_lines ~ko ~month view ~keeper_name
     | Masc_tui_fetched.Stale (view, Read_failed detail) ->
       view_lines ~ko ~month view ~keeper_name
       @ [ Dim, (if ko then "마지막 갱신 실패: " else "the last refresh failed: ") ^ single_line detail ]
     | Masc_tui_fetched.Stale (view, Read_kept_back notice) ->
       view_lines ~ko ~month view ~keeper_name @ [ Dim, single_line notice ])
;;
