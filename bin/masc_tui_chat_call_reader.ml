module Fetched = Masc_tui_fetched
module Reading = Masc_tui_detail_reading
type choice = { execution_id : string; tool : string; args : string; subject : string option }
type request = string Fetched.request
type failure = Read_failed of string | Read_kept_back of string
let path ~keeper ~execution_id =
  Printf.sprintf "/api/v1/keepers/%s/tool-calls?execution_id=%s"
    (Uri.pct_encode ~component:`Generic keeper) (Uri.pct_encode ~component:`Generic execution_id)
type t = {
  ko : bool;
  choices : choice list;
  cursor : int;
  choosing : bool;
  fetched : (string, Masc.Tui_decode.keeper_call, failure) Fetched.source;
  document : Reading.t;
}
let say ~ko korean english = if ko then korean else english
let section heading body = { Reading.heading; body }
let selection_document ~ko choices cursor =
  let sections = match List.nth_opt choices cursor with
    | None ->
        [section (say ~ko "확인 불가" "Unavailable")
           (say ~ko "이 대화에 기록된 원본 실행 ID가 없습니다." "No original execution ID is recorded in this conversation.")]
    | Some choice ->
        [section
           (Printf.sprintf
              (if ko then "호출 %d / %d · %s" else "Call %d of %d · %s")
              (cursor+1) (List.length choices) choice.tool)
           choice.execution_id;
         section (say ~ko "원본 입력" "Original input") choice.args]
        @ (match choice.subject with
           | None -> []
           | Some subject -> [section (say ~ko "원본 대상" "Original target") subject]) in
  Reading.create ~ko
    ~title:(say ~ko "원본 호출 · j/k 선택 · Enter 읽기 · Esc 뒤로"
              "Original calls · j/k choose · Enter read · Esc back")
    sections
let create ?(ko = false) choices =
  (* Preserve the first original occurrence; repeated delivery is not a new call. *)
  let module Ids = Set.Make(String) in
  let _,choices = List.fold_left (fun (seen,kept) choice ->
    if Ids.mem choice.execution_id seen then seen,kept
    else Ids.add choice.execution_id seen, choice::kept) (Ids.empty,[]) choices in
  let choices=List.rev choices in
  { ko; choices; cursor=0; choosing=true; fetched=Fetched.initial;
    document=selection_document ~ko choices 0 }
type action = Close | Choose of int | Open | Retry | Move of Reading.movement | Ignore
let action ~key t =
  match key with
  | "esc" -> Close
  | "j" | "down" when t.choosing -> Choose 1
  | "k" | "up" when t.choosing -> Choose (-1)
  | "\r" | "\n" | "enter" when t.choosing -> Open
  | "r" when not t.choosing -> Retry
  | "pagedown" -> Move Reading.Page_down
  | "pageup" -> Move Reading.Page_up
  | "home" | "g" -> Move Reading.First
  | "end" | "G" -> Move Reading.Last
  | "j" | "down" | "wheel-down" when not t.choosing -> Move (Reading.By 1)
  | "k" | "up" | "wheel-up" when not t.choosing -> Move (Reading.By (-1))
  | _ -> Ignore
let choices t = t.choices
let selected t = List.nth_opt t.choices t.cursor
let choosing t = t.choosing
let choose delta t =
  let cursor = max 0 (min (List.length t.choices - 1) (t.cursor + delta)) in
  {t with cursor; document=selection_document ~ko:t.ko t.choices cursor}
let select_execution execution_id t =
  Option.map (fun cursor -> {t with cursor; document=selection_document ~ko:t.ko t.choices cursor})
    (List.find_index (fun choice -> String.equal choice.execution_id execution_id) t.choices)
let observation t = match selected t with
  | None -> Fetched.Absent
  | Some choice -> Fetched.view_for ~equal:String.equal t.fetched ~key:choice.execution_id
let original_failure ~ko = function
  | Masc.Tui_decode.Original_failed detail -> Some detail
  | Original_pending ->
      Some (say ~ko "해당 턴의 원본 추적이 아직 게시되지 않았습니다"
              "The enclosing turn's original trace is not published yet")
  | Original_unavailable reason -> Some reason
  | Original_not_read | Original_body _ -> None
let output_sections ~ko (call:Masc.Tui_decode.keeper_call) =
  let preview () = [section (say ~ko "기록된 출력 미리보기" "Recorded output preview")
    (match call.kc_output with
     | Some output -> output
     | None -> say ~ko "기록된 출력이 없습니다." "No output was recorded.")] in
  let output = match call.kc_original with
    | Original_body body ->
      let printed = match Masc_tui_execute_result.of_result body.content with
        | None -> []
        | Some result ->
            [section (say ~ko "명령 결과" "Command outcome") (Masc_tui_execute_result.status_text result)]
            @ (match result.output with
               | None -> []
               | Some (Masc_tui_execute_result.Printed text) ->
                   [section (say ~ko "출력 내용" "Printed output") text]
               | Some (Stored reference) ->
                   [section (say ~ko "저장된 출력" "Stored output") (Masc_tui_execute_result.stored_text reference)]) in
      printed @ [section (say ~ko "보존된 원본 결과" "Retained original result") body.content;
        section (say ~ko "원본 출처" "Original source")
          (Printf.sprintf
             (if ko then "투영 %s바이트 · 기록 %s바이트 · sha256 %s"
              else "%s projected bytes · %s recorded bytes · sha256 %s")
             (Masc_tui_value.Count.grouped (String.length body.content))
             (Masc_tui_value.Count.grouped body.recorded_bytes) body.sha256)]
    | Original_not_read -> preview ()
    | (Original_pending | Original_unavailable _ | Original_failed _) as source ->
        preview () @ (match original_failure ~ko source with
          | None -> [] | Some reason -> [section (say ~ko "원본 출처 확인 불가" "Original source not available") reason]) in
  output @ (match call.kc_truncated_to with None -> [] | Some bytes ->
    [section (say ~ko "원장 미리보기 제한" "Ledger preview limit")
       (Printf.sprintf
          (if ko then "원장 미리보기는 %s바이트로 잘려 있으며, 원본 출처는 별도로 읽습니다."
           else "The ledger preview declares truncation to %s bytes; the original source is read separately.")
          (Masc_tui_value.Count.grouped bytes))])
let result_document t =
  let ko = t.ko in
  match selected t with
  | None ->
      Reading.create ~ko ~title:(say ~ko "원본 호출" "Original calls")
        [section (say ~ko "확인 불가" "Unavailable")
           (say ~ko "이 대화에 기록된 원본 실행 ID가 없습니다." "No original execution ID is recorded in this conversation.")]
  | Some choice ->
    let state = observation t in
    let observation = match state with
      | Fetched.Absent ->
          [section (say ~ko "미조회" "Not read")
             (say ~ko "이 원본 호출을 열어 내용을 읽으세요." "Open this original call to read it.")]
      | Loading ->
          [section (say ~ko "불러오는 중" "Reading")
             (say ~ko "선택한 원본 실행 기록을 읽고 있습니다." "Reading the selected original execution.")]
      | Failed (Read_failed reason) -> [section (say ~ko "읽기 실패" "Read failed") reason]
      | Failed (Read_kept_back notice) -> [section (say ~ko "미조회" "Not read") notice]
      | Ready call | Stale (call, _) ->
          [section (say ~ko "도구" "Tool") call.Masc.Tui_decode.kc_tool;
           section (say ~ko "입력" "Input") call.kc_input;
           ] @ output_sections ~ko call
          @ (match state with
             | Stale (_,Read_failed reason) ->
                 [section (say ~ko "새로고침 실패 · 이전 결과 유지" "Refresh failed · retained reading") reason]
             | Stale (_,Read_kept_back notice) ->
                 [section (say ~ko "이전 결과 유지" "Retained reading") notice]
             | Absent | Loading | Failed _ | Ready _ -> []) in
    let pending = if Fetched.in_flight t.fetched then
      [section (say ~ko "조회 진행 중" "Read pending")
         (say ~ko "원본 실행 기록을 읽고 있습니다. 유지된 결과와 오류는 아래에 남아 있습니다."
            "Reading this original execution; any retained result and failure remain below.")]
      else [] in
    Reading.replace
      ~title:(say ~ko "원본 호출 · j/k 스크롤 · r 재시도 · Esc 목록"
                "Original call · j/k scroll · r retry · Esc calls")
      (section (say ~ko "실행" "Execution") choice.execution_id :: pending @ observation) t.document
let start t = match selected t with
  | None -> {t with document=result_document t}, None
  | Some choice ->
      match Fetched.refresh ~equal:String.equal t.fetched ~key:choice.execution_id with
      | Fetched.Already_loading -> t,None
      | Started (fetched,request) ->
          let document =
            if t.choosing then
              Reading.create_observation ~title:(say ~ko:t.ko "원본 호출" "Original call") []
            else t.document in
          let t={t with choosing=false;fetched;document} in
          {t with document=result_document t},Some request
let complete t request result =
  let ko = t.ko in
  let result = Result.bind result (fun call ->
    if Option.equal String.equal call.Masc.Tui_decode.kc_execution_id
         (Some (Fetched.request_key request)) then Ok call
    else Error (say ~ko "원본 실행 ID가 일치하지 않습니다" "Original execution identity mismatch")) in
  let result = Result.bind result (fun call ->
    match original_failure ~ko call.Masc.Tui_decode.kc_original, observation t with
    | Some reason, (Fetched.Ready previous | Stale (previous,_)) ->
        (match previous.Masc.Tui_decode.kc_original with
         | Original_body previous ->
           (match call.kc_original with
            | Original_body current
              when not (String.equal previous.source_id current.source_id
                        && String.equal previous.sha256 current.sha256) -> Ok call
            | Original_body _ | Original_not_read | Original_pending
            | Original_unavailable _ | Original_failed _ -> Error reason)
         | Original_not_read | Original_pending | Original_unavailable _ | Original_failed _ -> Ok call)
    | (None | Some _), (Fetched.Absent | Loading | Failed _ | Ready _ | Stale _) -> Ok call) in
  let result = Result.map_error (fun reason -> Read_failed reason) result in
  if not (Fetched.is_current ~equal:String.equal t.fetched request) then t
  else let t={t with fetched=Fetched.complete ~equal:String.equal t.fetched request result} in
    {t with document=result_document t}
let withdraw t request notice =
  if not (Fetched.is_current ~equal:String.equal t.fetched request) then t
  else let t={t with fetched=Fetched.complete ~equal:String.equal t.fetched request
      (Error (Read_kept_back notice))} in
    {t with document=result_document t}
let back t =
  let t={t with choosing=true;
    fetched=Fetched.cancel_pending
      ~reason:(Read_failed (say ~ko:t.ko "읽기 창 닫힘" "Reader closed")) t.fetched} in
  {t with document=selection_document ~ko:t.ko t.choices t.cursor}
let set_language ~ko t =
  if t.ko = ko then t
  else
    let t = {t with ko} in
    let document =
      if t.choosing then selection_document ~ko t.choices t.cursor
      else result_document t
    in
    {t with document}
let document t = t.document
let move ~count ~height movement t =
  {t with document=Reading.move ~count ~height movement t.document}
let pending t = Fetched.in_flight t.fetched
let search_key ~width ~height ~key t=
  Option.map (fun document -> {t with document}) (Reading.search_key ~width ~height ~key t.document)
let search_insert ~width ~height ~text t=
  {t with document=Reading.search_insert ~width ~height ~text t.document}
