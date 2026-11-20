let report_kept_back state ~request reason kept =
  let ko = state.Masc_tui_types.ui_language = Masc_tui_types.Lang_ko in
  Masc_tui_loader.report_action state "error"
    (Masc_tui_words.kept_back ~ko ~request (reason ~ko) kept)

let report_withdrawn state ~request refusal =
  report_kept_back state ~request
    (fun ~ko -> Masc_tui_types.workspace_refusal_reason ~ko refusal)
    Masc_tui_words.Nothing_kept

let said_read_result state ~request result =
  Result.map_error
    (Masc_tui_types.request_failure_text
       ~ko:(state.Masc_tui_types.ui_language = Masc_tui_types.Lang_ko)
       ~request)
    result

let workspace_response_refusal_text state ~request refusal =
  let ko = state.Masc_tui_types.ui_language = Masc_tui_types.Lang_ko in
  String.concat " · "
    [ Masc_tui_words.Kept_request.name ~ko request
      ^ (if ko then " 시도 후 결과 미적용" else " attempted; result not applied")
    ; Masc_tui_types.workspace_refusal_reason ~ko refusal
    ]

let request_failure_after_read state ~request = function
  | Masc_tui_types.Request_failed _ as failure -> failure
  | Masc_tui_types.Request_withdrawn refusal ->
      Masc_tui_types.Request_failed
        (workspace_response_refusal_text state ~request refusal)

let kept_back_until_reconnect ~ko ~request =
  Masc_tui_words.kept_back ~ko ~request
    (Masc_tui_words.workspace_identity_unconfirmed ~ko)
    Masc_tui_words.Nothing_kept
  ^ " · "
  ^ (if ko then "다시 연결한 뒤 다시 시도하세요" else "retry after reconnecting")
