(** The Tools surface: what the selected Keeper's turn called, and what the
    process has registered. *)

open Masc_tui_types
open Tui_decode
open Masc_tui_ansi

(* The Skills list's name column is as wide as its longest name, between
   these two. The floor is the width the column always had. The cap keeps a
   row on an 80-column screen: 32 name cells and an instruction Skill's
   other fields (mark, execution, sizes) come to about 74 cells. A longer
   name is cut in the middle, so two names that share a head still differ
   on screen. *)
let skill_name_min_cells = 22
let skill_name_max_cells = 32

module Tool_tree = Masc_tui_tool_tree
module Tool_table = Masc_tui_tool_table
let json_assoc_member_opt = Masc_tui_json.member_opt

(* Every word this screen writes is a Masc_tui_say.t (RFC
   tui-one-screen-grammar section 7.1, layer 9), so a literal written in one
   language does not compile here. The language is chosen once, where the
   rows are cut to the frame's width ({!tools_display_lines}). *)
module Say = Masc_tui_say

let ( ++ ) = Say.( ++ )
let say_dot = Say.code " \xc2\xb7 "

(* Pads to [cells] display cells and never cuts, as Printf's "%-Ns" did for
   ASCII: a Korean word is counted in cells, not bytes. *)
let pad_cells cells text =
  text ^ String.make (max 0 (cells - Masc_tui_message_layout.display_width text)) ' '

let say_language (state : state) =
  match state.ui_language with
  | Lang_ko -> Say.Ko
  | Lang_en -> Say.En

let refusal_text ~request refusal =
  Say.of_ko_flag (fun ~ko -> workspace_refusal_text ~ko ~request refusal)

(* What a section of this screen hands the frame. A [Row] holds its words in
   both languages. A [Cursor] is a row of the entry the list keys act on --
   the Skill's own row and the rows that say why it was loaded: it draws as a
   [Row] in its own style, and {!tools_display} says which physical rows the
   entry takes, so the key handler brings it into view by those numbers
   rather than by looking for its colour. A [Timed] row draws as a [Row]
   whose time text reads differently from the instant it carries. It was
   built without noting that instant ({!Masc_tui_value.Redraw.deferred}):
   {!tools_display} hands it back with each physical row the text lands on,
   and the frame notes it only for a row it draws, so a row scrolled out of
   the window asks for no redraw. A [Laid_out] block is rows fitted to
   a width by a step that has to see the words first -- a boxed card wraps
   its rows, a table keeps its columns only if its header fits, a chart sizes
   its bars beside its names -- so how many rows it takes depends on the
   language, and it gets the language when the frame draws ({!draw}). A
   [Measurement_card] is laid out the same way, and {!tools_display} says
   which rows the selected Skill's measurement card takes. A [Cursor] handed
   to a [Laid_out] block is drawn but not counted, and a [Timed] row there
   is drawn without its instant; the Skill list and the Async request list
   are in none. A [List_entry] is the pieces of one entry of the list the
   move keys walk -- a Skill with its group heading and the rows that say
   why it was loaded, or one async request -- drawn as those pieces are:
   {!tools_display} counts the rows each entry takes, so the frame can page
   by the entries its window holds whole. *)
type piece =
  | Row of string * Say.t
  | Cursor of string * Say.t
  | Timed of string * Say.t * float
  | Laid_out of (Say.language -> (string * string) list)
  | Measurement_card of (Say.language -> (string * string) list)
  | List_entry of piece list

(* Which of {!tools_display}'s runs a drawn row belongs to: none, the
   [Cursor]'s entry, the measurement card, or a [Timed] text with when it
   reads differently. *)
type mark =
  | Unmarked
  | Entry
  | Card
  | Changes_at of float

let rows lines = List.map (fun (style, text) -> Row (style, text)) lines

(* Rows another module wrote in the screen's language: the task document
   reads [state.ui_language] itself. It moves to Masc_tui_say in its own
   layer; until then the frame takes its rows as they are. *)
let written_elsewhere lines = Laid_out (fun _ -> lines)

(* Each drawn row, paired with the run it belongs to. *)
let rec draw_marked language pieces =
  List.concat_map
    (function
      | Row (style, text) -> [ (style, Say.render language text), Unmarked ]
      | Cursor (style, text) -> [ (style, Say.render language text), Entry ]
      | Timed (style, text, at) -> [ (style, Say.render language text), Changes_at at ]
      | Laid_out lay -> List.map (fun row -> row, Unmarked) (lay language)
      | Measurement_card lay -> List.map (fun row -> row, Card) (lay language)
      | List_entry pieces -> draw_marked language pieces)
    pieces

let draw language pieces = List.map fst (draw_marked language pieces)

let skill_async_evidence_lines evidence =
  let view = Masc.Tui_skill_async_evidence.project evidence in
  let deliveries = view.result_deliveries in
  if List.is_empty deliveries && view.action_link_count = 0 then []
  else
    let delivery_lines =
      List.concat_map
        (fun (delivery : Masc.Keeper_skill_async_delivery.t) ->
          let presentation = match delivery.presentation with
            | Inline_result -> Say.both ~ko:"본문 결과" ~en:"inline result"
            | Manifest_reference -> Say.both ~ko:"manifest 참조" ~en:"manifest reference" in
          [ Ansi.dim,
            Say.code "       " ++ Say.both ~ko:"비동기 " ~en:"Async " ++ presentation
            ++ Say.code (Terminal_text.single_line (Printf.sprintf " received=%s runtime=%s at=%s"
                 (Ids.Turn_ref.to_string delivery.physical_turn_ref)
                 delivery.runtime_id delivery.observed_at))
          ; Ansi.dim, Say.code (Terminal_text.single_line (Printf.sprintf
              "         original=%s run=%s parent=%s request=%s bytes=%d sha256=%s"
              (Ids.Turn_ref.to_string delivery.original_turn_ref)
              (Masc.Keeper_tool_plan.Composition_run_id.to_string delivery.composition_run_id)
              delivery.logical_parent_tool_use_id delivery.request_id
              delivery.receipt.content_bytes delivery.receipt.content_sha256))
          ])
        deliveries
    in
    let action_lines =
      List.concat_map
        (fun (group : Masc.Tui_skill_async_evidence.action_group) ->
          let action = group.first in
          let style, occurrence = match action.occurrence with
            | Masc.Keeper_skill_async_action.Sdk_result { invocation; result } ->
              let style, outcome, bytes, sha256 = match result with
                | Handler_returned { bytes; sha256 } ->
                  Ansi.dim, Say.both ~ko:"SDK 반환" ~en:"SDK returned", bytes, sha256
                | Handler_errored { bytes; sha256; recoverable; error_class } ->
                  let error = match error_class with
                    | None -> "unclassified"
                    | Some Agent_core.Types.Transient -> "transient"
                    | Some Deterministic -> "deterministic"
                    | Some Unknown -> "unknown" in
                  Theme.bad (),
                  Say.both ~ko:"SDK 오류" ~en:"SDK errored"
                  ++ Say.code (Printf.sprintf " class=%s recoverable=%b" error recoverable),
                  bytes, sha256 in
              style, outcome ++ Say.code (Printf.sprintf " call=%s SDK-turn=%d bytes=%d sha256=%s"
                (Agent_core.Tool_contract.Invocation.tool_use_id invocation)
                (Agent_core.Tool_contract.Invocation.turn invocation) bytes sha256)
            | Native_started { official_turn; identity } ->
              let identity = match identity with
                | Runtime_native_tools.Call_id id -> "call=" ^ id
                | Provider_step { conversation_id; step_index } ->
                  Printf.sprintf "step=%s:%d" conversation_id step_index in
              Ansi.dim,
              Say.both ~ko:"Native 시작" ~en:"Native started"
              ++ Say.code (Printf.sprintf " official-turn=%d %s" official_turn identity)
          in
          (style,
           Say.code "       " ++ Say.as_received (Terminal_text.single_line action.tool_name)
           ++ say_dot ++ Say.map Terminal_text.single_line occurrence
           ++ say_dot ++ Say.code (Terminal_text.single_line (Printf.sprintf "received=%s runtime=%s"
                (Ids.Turn_ref.to_string action.physical_turn_ref) action.runtime_id)))
          :: List.map
               (fun (link : Masc.Keeper_skill_async_action.t) ->
                 Ansi.dim,
                 Say.code "         " ++ Say.both ~ko:"인과 연결" ~en:"causal"
                 ++ Say.code (Terminal_text.single_line (Printf.sprintf " handoff=%s at=%s"
                      link.delivery_sha256 link.observed_at)))
               (group.first :: group.additional_links))
        view.actions
    in
    (Ansi.dim,
     Say.per_language (function
       | Say.Ko -> Printf.sprintf "       비동기 결과: 전달 %d · 물리 동작 %d · 인과 연결 %d"
           (List.length deliveries) (List.length view.actions) view.action_link_count
       | Say.En -> Printf.sprintf "       Async results: %d handoffs · %d physical actions · %d causal links"
           (List.length deliveries) (List.length view.actions) view.action_link_count))
    :: delivery_lines @ action_lines

(* Newest events the Skill Timeline section draws. The full count still
   prints in the heading; the cap keeps one busy ledger from pushing the
   usage and catalog sections off the first screen. *)
let skill_timeline_display_cap = 15

(* Two deliberately separate readings: the selected Keeper's exact turn
   surface, then the process-wide registered catalog. A registered tool is not
   evidence that a Keeper can call it. *)
(* The rule that closes a domain heading. Fixed length rather than filling
   the row: box_line_styled pads, and a heading that shouted across the full
   width would outrank the surface header above it. *)
let tool_domain_rule_cells = 21

let tool_domain_rule =
  String.concat "" (List.init tool_domain_rule_cells (fun _ -> Ansi.box_h))

(* The activation ledger's own names for an origin and what it served. They
   are what the reader compares with the ledger, so they read the same in
   both languages. *)
let skill_instruction_origin_text = function
  | Masc.Keeper_skill_activation_ledger.Task_instruction { task_ids } ->
      Say.code "task_instruction tasks="
      ++ Say.as_received
           (Masc.Keeper_skill_activation_ledger.task_id_set_to_list task_ids
            |> List.map Keeper_id.Task_id.to_string
            |> String.concat ",")
  | Masc.Keeper_skill_activation_ledger.Session_instruction ->
      Say.code "session_instruction"

let skill_composition_origin_text ~tool_name = function
  | Masc.Keeper_skill_activation_ledger.Task_composition
      { task_ids } ->
      Say.code (Printf.sprintf "task_composition tasks=%s tool=%s"
        (Masc.Keeper_skill_activation_ledger.task_id_set_to_list task_ids
         |> List.map Keeper_id.Task_id.to_string
         |> String.concat ",")
        tool_name)
  | Masc.Keeper_skill_activation_ledger.Session_composition ->
      Say.code ("session_composition tool=" ^ tool_name)

let skill_served_content_text = function
  | Masc.Keeper_skill_activation_ledger.Skill_body { bytes; sha256 } ->
      Say.code (Printf.sprintf "body bytes=%d sha256=%s" bytes sha256)
  | Masc.Keeper_skill_activation_ledger.Skill_resource
      { relative_path; bytes; sha256 } ->
      Say.code (Printf.sprintf "resource=%s bytes=%d sha256=%s" relative_path bytes sha256)

let skill_invocation_text = function
  | Masc.Keeper_skill_activation_ledger.Instruction_invocation
      { origin; served_content } ->
    skill_instruction_origin_text origin, skill_served_content_text served_content
  | Masc.Keeper_skill_activation_ledger.Composition_invocation
      { origin; tool_name; _ }
  | Masc.Keeper_skill_activation_ledger.Nested_composition_invocation
      { origin; tool_name; scope = _ } ->
    ( skill_composition_origin_text ~tool_name origin
    , Say.both ~ko:"composition 호출" ~en:"composition invocation"
      ++ Say.code " tool=" ++ Say.as_received (Terminal_text.single_line tool_name) )

let skill_delivery_text ~has_action = function
  | None -> Say.both ~ko:"대기" ~en:"pending"
  | Some (delivery : Masc.Keeper_skill_activation_ledger.delivery) ->
      let kind, turn, proof =
        match delivery.boundary with
        | Masc.Keeper_skill_activation_ledger.Model_response { agent_core_turn } ->
          "provider_delivery", agent_core_turn, ""
        | Official_client_result_handoff { agent_core_turn } ->
          ( "official_client_result_handoff"
          , agent_core_turn
          , if has_action
            then " proof=complete_later_action"
            else " proof=incomplete_no_later_action" )
      in
      Say.code (Printf.sprintf
        "%s turn=%d runtime=%s bytes=%d sha256=%s at=%s%s"
        kind
        turn
        (Terminal_text.single_line delivery.runtime_id)
        delivery.content_bytes
        (Terminal_text.single_line delivery.content_sha256)
        delivery.delivered_at
        proof)

let skill_action_lines actions =
  List.map
    (fun (action : Masc.Keeper_skill_activation_ledger.action) ->
       let identity =
         match action.identity with
         | Masc.Keeper_skill_activation_ledger.Call_id call_id ->
           "call=" ^ call_id
         | Masc.Keeper_skill_activation_ledger.Provider_step
             { conversation_id; step_index } ->
           Printf.sprintf "step=%s:%d" conversation_id step_index
       in
       Ansi.dim,
       Say.code "       " ++ Say.both ~ko:"동작" ~en:"action"
       ++ Say.code (Printf.sprintf
         " turn=%d runtime=%s tool=%s %s at=%s"
         action.agent_core_turn
         (Terminal_text.single_line action.runtime_id)
         (Terminal_text.single_line (Masc.Tool_display.list_label action.tool_name))
         (Terminal_text.single_line identity)
         (Terminal_text.single_line action.observed_at)))
    actions

(* A request row reads its age, and the list scrolls: the age is built
   deferred, so only a row the window draws asks for the redraw on which its
   age reads differently ([Timed]). *)
let async_request_inventory_lines (state : state) =
  let errors = Option.to_list (Option.map (function
    | Request_failed detail -> Theme.bad (),
        Say.both ~ko:" Async broker · 재확인 실패 · 이전 목록 유지: "
          ~en:" Async broker · recheck failed · previous list kept: "
        ++ Say.as_received (Terminal_text.single_line detail)
    | Request_withdrawn refusal -> Theme.bad (),
        Say.code " " ++ refusal_text ~request:Kept_request.Async_requests_read refusal)
    state.tools_async_observation_error) in
  rows errors @ (match state.tools_async_observation with
  | None ->
    if errors=[] then rows [ Theme.warn (), Say.both ~ko:" Async broker · 미조회" ~en:" Async broker · not loaded" ]
    else []
  | Some (Async_unavailable { kind; reason }) ->
    rows [ Theme.bad (),
      Say.both ~ko:" Async broker · 영속 목록 조회 불가: " ~en:" Async broker · durable inventory unavailable: "
      ++ Say.as_received (Terminal_text.single_line kind)
      ++ Option.fold ~none:Say.empty
           ~some:(fun value -> Say.code ": " ++ Say.as_received (Terminal_text.single_line value)) reason ]
  | Some (Async_ready { summary; requests; recovery }) ->
    let summary_lines =
      [ Ansi.bold,
        Say.per_language (function
          | Say.Ko -> Printf.sprintf
              " Async broker · 진행 %d · runtime 소유 %d · 소유 확인 안 됨 %d · 기록 오류 %d"
              summary.ars_active summary.ars_runtime_owned
              summary.ars_ownership_unknown summary.ars_record_errors
          | Say.En -> Printf.sprintf
              " Async broker · active=%d · runtime-owned=%d · ownership-unconfirmed=%d · record-errors=%d"
              summary.ars_active summary.ars_runtime_owned
              summary.ars_ownership_unknown summary.ars_record_errors) ]
    in
    let now = Unix.gettimeofday () in
    let request_lines = List.map (fun request ->
      let tone, ownership = match request.ar_ownership with
        | Async_runtime_owned -> Theme.ok (), Say.both ~ko:"runtime 소유" ~en:"runtime owned"
        | Async_ownership_unknown ->
          Theme.warn (), Say.both ~ko:"디스크에만 있음 · 소유 확인 안 됨" ~en:"on disk only · ownership unconfirmed"
      in
      let status = match request.ar_phase with
        | Async_queued -> Say.both ~ko:"대기열" ~en:"queued"
        | Async_running -> Say.both ~ko:"실행 중" ~en:"running"
        | Async_cancelling -> Say.both ~ko:"취소 중" ~en:"cancelling"
      in
      let elapsed, changes_at =
        Masc_tui_value.Redraw.deferred (fun () ->
          match
            Masc_tui_message_layout.age_text ~now ~since:request.ar_submitted_at
          with
          | Some text -> Say.as_received text
          | None -> Say.code Masc_tui_theme.Glyph.no_value)
      in
      let selected = Option.exists (fun (target : Masc.Tui_decode_async_request.target) ->
        target.request_id=request.ar_request_id && target.submitted_by=request.ar_submitted_by
        && target.keeper_name=request.ar_keeper_name) state.tools_async_selection in
      let text =
        Say.code (if selected then " › " else "   ")
        ++ Say.concat ~sep:say_dot
             [ Say.as_received (Terminal_text.single_line request.ar_request_id);
               Say.as_received (Terminal_text.single_line request.ar_keeper_name);
               status; elapsed; ownership ]
      in
      let row_style = if selected then Theme.selection_style () else tone in
      List_entry
        [ (match changes_at with
           | Some at -> Timed (row_style, text, at)
           | None -> Row (row_style, text)) ]) requests
    in
    let recovery_lines = match recovery with
      | None ->
        [ Ansi.dim, Say.both ~ko:"   시작 복구: 이 process 에 보고 없음"
                      ~en:"   startup recovery: not reported to this process" ]
      | Some report ->
        [ Ansi.dim,
          Say.both ~ko:"   시작 복구: " ~en:"   startup recovery: "
          ++ Say.code (Printf.sprintf
            "lost=%d finalized=%d cleaned=%d unreadable=%d failed=%d staging=%d/%d/%d"
            report.arr_lost report.arr_finalized report.arr_cleaned
            report.arr_unreadable report.arr_failed report.arr_staging_inspected
            report.arr_staging_deleted report.arr_staging_preserved) ]
    in
    rows summary_lines @ request_lines @ rows recovery_lines)

let async_logical_lines value =
  let module Detail = Masc.Tui_decode_async_request in
  let safe value = Say.as_received (Terminal_text.single_line value) in
  match value with
  | Detail.Not_composition ->
    [Ansi.dim, Say.both ~ko:" 논리: Composition 원본 없음" ~en:" Logical: no original Composition"]
  | Original_run run ->
    [Theme.info (), Say.both ~ko:" 원본 run: " ~en:" Original run: " ++ safe run.run_id;
     Ansi.dim, Say.both ~ko:" 원본 Task: " ~en:" Original Task: "
       ++ Option.fold ~none:(Say.both ~ko:"없음(기록)" ~en:"none (recorded)") ~some:safe run.source_task_id;
     Ansi.dim, Say.both ~ko:" 현재 run owner: " ~en:" Current run owner: " ++ safe run.owner.request_id
       ++ say_dot ++ Say.per_language (function
            | Say.Ko -> Printf.sprintf "세대 %d" run.owner.generation
            | Say.En -> Printf.sprintf "generation %d" run.owner.generation);
     Ansi.dim, Say.both ~ko:" 논리 관측 시각: " ~en:" Logical observed at: "
       ++ Say.code (Printf.sprintf "%.3f" run.observed_at)
       ++ say_dot ++ Say.both ~ko:"저널 " ~en:"journal " ++ safe run.journal_version]
    @ (match run.resolution with
      | None ->
        [Theme.warn (), Say.both ~ko:" 논리: 명시적 종결 없음 · 실행 허가는 별도"
                          ~en:" Logical: no explicit resolution · permission to run is separate"]
      | Some resolution ->
        [Theme.warn (), Say.both ~ko:" 논리: 재개 종결 · " ~en:" Logical: resumption resolved · "
           ++ (match resolution.decision with
               | Detail.Rejected -> Say.both ~ko:"거절" ~en:"rejected"
               | Cancelled_continuation -> Say.both ~ko:"취소" ~en:"cancelled");
         Ansi.dim, Say.both ~ko:" 결정: " ~en:" Decided by: " ++ safe resolution.requested_by
           ++ say_dot ++ Say.code (Printf.sprintf "%.3f" resolution.resolved_at);
         Theme.info (), Say.both ~ko:" 사유: " ~en:" Reason: " ++ safe resolution.reason])

let async_request_detail_lines ~cols state target =
  let module Detail = Masc.Tui_decode_async_request in
  let view = Masc_tui_fetched.view_for ~equal:Detail.equal_target state.tools_async_detail ~key:target in
  let pending = Masc_tui_fetched.in_flight state.tools_async_detail in
  let safe value = Say.as_received (Terminal_text.single_line value) in
  let reading = match pending,view with
    | true,(Masc_tui_fetched.Ready _ | Stale _) ->
      [Ansi.dim, Say.both ~ko:" 재조회 중 · 이전 관측 유지" ~en:" Reading again · previous observation kept"]
    | true,(Absent | Loading | Failed _) ->
      [Ansi.dim, Say.both ~ko:" 원본 요청 조회 중" ~en:" Reading the original request"]
    | false,_ -> [] in
  let failures = match view with
    | Masc_tui_fetched.Absent -> [Ansi.dim, Say.both ~ko:" 미조회" ~en:" Not read"]
    | Loading -> []
    | Failed (Request_failed detail) ->
      [Theme.bad (), Say.both ~ko:" 조회 실패: " ~en:" Read failed: " ++ safe detail]
    | Failed (Request_withdrawn refusal) ->
      [Theme.bad (), Say.code " " ++ refusal_text ~request:Kept_request.Async_request_read refusal]
    | Stale (_,Request_failed detail) ->
      [Theme.warn (), Say.both ~ko:" 마지막 관측 · 재확인 실패: " ~en:" Last observation · recheck failed: "
         ++ safe detail]
    | Stale (_,Request_withdrawn refusal) ->
      [Theme.warn (), Say.both ~ko:" 마지막 관측 · " ~en:" Last observation · "
         ++ refusal_text ~request:Kept_request.Async_request_read refusal]
    | Ready _ -> [] in
  let snapshot = match Masc_tui_fetched.value view with
    | None -> []
    | Some Detail.Absent ->
      [Theme.warn (), Say.both ~ko:" 원본 요청 기록이 없습니다 · 재실행 허가가 아닙니다"
                        ~en:" No record of the original request · this is not permission to run again"]
    | Some (Observed snapshot) ->
      let phase = match snapshot.phase with
        | Detail.Queued -> Say.both ~ko:"대기열" ~en:"queued"
        | Running -> Say.both ~ko:"실행 중" ~en:"running"
        | Cancelling -> Say.both ~ko:"취소 중" ~en:"cancelling"
        | Waiting -> Say.both ~ko:"의존 대기 · worker 해제됨" ~en:"waiting for dependencies · worker released"
        | Lost -> Say.both ~ko:"잃음" ~en:"lost"
        | Cancelled -> Say.both ~ko:"취소됨" ~en:"cancelled"
        | Persistence_failed -> Say.both ~ko:"저장 실패" ~en:"persistence failed"
        | Done true -> Say.both ~ko:"끝남 (물리 성공)" ~en:"done (physical success)"
        | Done false -> Say.both ~ko:"오류 (물리 실패)" ~en:"error (physical failure)" in
      let physical = [Theme.info (), Say.both ~ko:" 물리 상태: " ~en:" Physical state: " ++ phase;
        Ansi.dim, Say.both ~ko:" 접수: " ~en:" Submitted: " ++ Say.code (Printf.sprintf "%.3f" snapshot.submitted_at)
          ++ say_dot ++ Say.both ~ko:"종료: " ~en:"Ended: "
          ++ Option.fold ~none:(Say.both ~ko:"미종료" ~en:"not ended")
               ~some:(fun at -> Say.code (Printf.sprintf "%.3f" at)) snapshot.completed_at] in
      let dependencies = List.map (fun dependency ->
        Ansi.dim, Say.both ~ko:" 의존: " ~en:" Depends on: "
          ++ Say.as_received (Terminal_text.single_line
               (Yojson.Safe.to_string (Masc.Keeper_composition_dependency.to_json dependency))))
        snapshot.dependencies in
      let logical = match snapshot.logical with
        | Detail.Confirmed value -> async_logical_lines value
        | Unavailable detail ->
          [Theme.bad (), Say.both ~ko:" 논리 상태 조회 불가: " ~en:" Logical state unavailable: " ++ safe detail]
          @ (match state.tools_async_last_logical with
            | Some (source,value) when Detail.equal_source source snapshot.source ->
              [Theme.warn (), Say.both ~ko:" 아래 논리는 마지막 관측이며 최신 확인이 아닙니다"
                                ~en:" The logical state below is the last observation, not a current check"]
              @ async_logical_lines value
            | Some _ | None ->
              [Ansi.dim, Say.both ~ko:" 확인된 이전 논리 관측 없음" ~en:" No earlier confirmed logical observation"]) in
      let nested = Masc_tui_nested_result.sections snapshot.nested
        |> List.concat_map (fun (heading,body) ->
          (Ansi.bold, Say.as_received (Terminal_text.single_line heading)) ::
          (Masc_tui_text_block.rows ~max_cells:(max 1 (Masc_tui_frame.inner_width ~cols)) body
           |> List.map (fun row -> Ansi.dim, Say.as_received row))) in
      physical @ Option.to_list (Option.map (fun notice -> Theme.warn (),
        Say.both ~ko:" 물리 사유: " ~en:" Physical reason: " ++ safe notice) snapshot.notice)
      @ dependencies @ logical @ nested in
  [Ansi.bold, Say.both ~ko:" 원본 비동기 요청  t:원본 Task  o:원본 ID 조회  r:재조회  Esc:목록"
                ~en:" Original async request  t:original Task  o:read original ID  r:read again  Esc:list"]
  @ reading @ failures @ snapshot

let async_source_task_lines ~cols state source =
  let width=max 1 (Masc_tui_frame.inner_width ~cols) in
  let ko = state.ui_language = Lang_ko in
  let body=Masc_tui_fetched.view_for ~equal:equal_tools_async_task_source state.tools_async_task_body ~key:source in
  let history=Masc_tui_fetched.view_for ~equal:equal_tools_async_task_source state.tools_async_task_history ~key:source in
  let pending = if Masc_tui_fetched.in_flight state.tools_async_task_body then
      [Ansi.dim, Say.both ~ko:" Task 본문 조회 중 · 기존 관측·실패 유지"
                   ~en:" Reading the Task body · earlier observation and failure kept"] else [] in
  let errors=match body with
    | Masc_tui_fetched.Absent -> [Ansi.dim, Say.both ~ko:" Task 본문 미조회" ~en:" Task body not read"]
    | Loading | Ready _ -> []
    | Failed (Request_failed detail) ->
      [Theme.bad (), Say.both ~ko:" Task 본문 조회 실패: " ~en:" Task body read failed: " ++ Say.as_received detail]
    | Failed (Request_withdrawn refusal) ->
      [Theme.bad (), Say.code " " ++ refusal_text ~request:Kept_request.Original_task_read refusal]
    | Stale (_,Request_failed detail) ->
      [Theme.warn (), Say.both ~ko:" Task 본문 재확인 실패 · 마지막 관측: "
                        ~en:" Task body recheck failed · last observation: " ++ Say.as_received detail]
    | Stale (_,Request_withdrawn refusal) ->
      [Theme.warn (), Say.code " " ++ refusal_text ~request:Kept_request.Original_task_read refusal
         ++ say_dot ++ Say.both ~ko:"마지막 관측" ~en:"last observation"] in
  let content=match Masc_tui_fetched.value body with
    | None -> []
    | Some (detail : Masc.Tui_decode_task_inspection.detail) ->
      let warnings=match detail.task.handoff_context with
        | None | Some (Masc_domain.Handoff_decoded _) -> []
        | Some (Handoff_unreadable {reason;raw=_}) ->
          [Theme.warn (), Say.both ~ko:" Task handoff 조회 불가: " ~en:" Task handoff unreadable: "
             ++ Say.as_received reason] in
      rows warnings
      @ [ written_elsewhere (task_document_lines state ~cols Masc_tui_task_document.Body
            |> List.map (fun line -> "",line)) ] in
  rows
  [Ansi.bold, Say.both ~ko:" 원본 Task · " ~en:" Original Task · " ++ Say.as_received source.ats_task_id
     ++ Say.both ~ko:"  r:재조회  Esc:원본 요청" ~en:"  r:reread  Esc:original request";
   Ansi.dim, Say.both ~ko:" 출처 run: " ~en:" Source run: " ++ Say.as_received source.ats_run_id
     ++ Say.both ~ko:" · 논리 관측 " ~en:" · logical observation "
     ++ Say.code (Printf.sprintf "%.3f" source.ats_observed_at)
     ++ (if source.ats_retained
         then Say.both ~ko:" · 이전 확인 관측에서 열림" ~en:" · opened from an earlier confirmed observation"
         else Say.empty)]
  @ rows (pending @ errors) @ content
  @ [ Row ("", Say.empty) ]
  @ [ written_elsewhere (Masc_tui_task_document.history_heading_rows ~ko ~width:(max 1 (width - 2))
     |> List.map (fun row -> "", row)) ]
  @ [ written_elsewhere (Masc_tui_task_document.history_status_lines ~ko ~width
       ~view:(observation_failure_said (history_failure_said ~ko
         ~request:Kept_request.Task_history_read) history)
       ~in_flight:(Masc_tui_fetched.in_flight state.tools_async_task_history)
       ~continuing:(Option.exists (fun request -> Option.is_some request.thr_page.hr_cursor)
         state.tools_async_task_history_request)
      |> List.concat_map (fun line ->
           Masc_tui_text_block.preformatted_rows ~max_cells:width line
           |> List.map (fun row -> "", row))) ]
  @ [ written_elsewhere (task_document_lines state ~cols Masc_tui_task_document.History
     |> List.map (fun line -> "",line)) ]

let async_request_observation_lines ~cols state =
  match state.tools_async_detail_open,state.tools_async_selection,state.tools_async_task_source with
  | true,Some _,Some source -> async_source_task_lines ~cols state source
  | true,Some target,None -> rows (async_request_detail_lines ~cols state target)
  | true,None,_ | false,_,_ -> async_request_inventory_lines state

(* The Tools sections, named where the reader is standing. Same shape as
   {!config_pane_strip}: a reader who has seen one has seen the other. *)
(* Revisions remain complete: the physical document wraps them at the
   viewport width, so operators can compare the actual identities. *)
(* The Skill discovery roots, in the order the catalog consults them.

   The pane named skills and never named where they were looked for, so
   "my Skill is not loaded" had no first question to ask. A root that is
   missing, refused, or read-only contributes nothing and only shows here:
   the editor's own sources endpoint filters to the read-write roots that
   resolved, because it is choosing somewhere to write. *)
let skill_access_short = function
  | "read-write" -> "rw"
  | "read-only" -> "ro"
  | other -> other
;;

(* The status marks of RFC tui-one-screen-grammar 7.2 in their 7.3 tones. A
   source that holds skills is settled. One that holds none, or is not there,
   is a value read as none (6.4). A path that is not a directory asks for a
   look, and a source that could not be read or whose path the config refused
   failed; the words say which. [!] and [✓] are not status marks. *)
let skill_source_status status = (Theme.status_tone status, Masc_tui_value.Mark.glyph status)

let skill_source_reading (observation : Masc.Tui_decode_tools.skill_source_observation) =
  match observation with
  | Masc.Tui_decode_tools.Skill_source_ready count ->
    let tone, mark =
      if count = 0 then (Theme.recede (), Masc_tui_theme.Glyph.no_value)
      else skill_source_status Masc_tui_value.Mark.Settled
    in
    ( tone
    , mark
    , Say.per_language (function
        | Say.Ko -> Printf.sprintf "Skill 디렉터리 %d개" count
        | Say.En -> Printf.sprintf "%d skill director%s" count (if count = 1 then "y" else "ies")) )
  | Masc.Tui_decode_tools.Skill_source_missing ->
    (Theme.recede (), Masc_tui_theme.Glyph.no_value, Say.both ~ko:"없음" ~en:"missing")
  | Masc.Tui_decode_tools.Skill_source_not_directory kind ->
    let tone, mark = skill_source_status Masc_tui_value.Mark.Caution in
    ( tone, mark
    , Say.both ~ko:"디렉터리가 아님 (" ~en:"not a directory (" ++ Say.as_received kind ++ Say.code ")" )
  | Masc.Tui_decode_tools.Skill_source_unavailable operation ->
    let tone, mark = skill_source_status Masc_tui_value.Mark.Failed in
    ( tone, mark
    , Say.both ~ko:"읽을 수 없음: " ~en:"unreadable at " ++ Say.as_received operation )
  | Masc.Tui_decode_tools.Skill_source_unresolved ->
    let tone, mark = skill_source_status Masc_tui_value.Mark.Failed in
    (tone, mark, Say.both ~ko:"설정이 경로를 거부함" ~en:"path refused by config")
;;

let skill_config_line (config : Masc.Tui_decode_tools.skill_catalog_config option) =
  match config with
  | None -> []
  | Some (Masc.Tui_decode_tools.Skill_config_configured { revision; resource_read_max_bytes })
    ->
    let cap =
      match resource_read_max_bytes with
      | None -> Say.both ~ko:"resource 읽기 한도 없음" ~en:"no resource read cap"
      | Some bytes ->
        Say.per_language (function
          | Say.Ko -> Printf.sprintf "resource 읽기 \xe2\x89\xa4 %d바이트" bytes
          | Say.En -> Printf.sprintf "resource read \xe2\x89\xa4 %d bytes" bytes)
    in
    [ ( Ansi.dim
      , Say.both ~ko:"   설정 " ~en:"   config "
        ++ Say.as_received (Terminal_text.single_line revision) ++ say_dot ++ cap )
    ]
  | Some (Masc.Tui_decode_tools.Skill_config_rejected { source_revision; diagnostics }) ->
    (* The catalog still stands on the defaults, so nothing else on the
       screen changes when the operator's section stops parsing. *)
    ( Theme.warn ()
    , Say.per_language (function
        | Say.Ko -> Printf.sprintf "   runtime.toml Skill 설정 거부됨 (rev %s) · 기본값 사용"
            (Terminal_text.single_line source_revision)
        | Say.En -> Printf.sprintf "   runtime.toml Skill config rejected (rev %s) · defaults in use"
            (Terminal_text.single_line source_revision)) )
    :: List.map
         (fun diagnostic ->
            (Theme.warn (), Say.code "     " ++ Say.as_received (Terminal_text.single_line diagnostic)))
         diagnostics
  | Some Masc.Tui_decode_tools.Skill_config_unreadable ->
    [ ( Theme.warn ()
      , Say.both ~ko:"   runtime.toml Skill 설정을 읽을 수 없음 · 기본값 사용"
          ~en:"   runtime.toml Skill config unreadable · defaults in use" )
    ]
;;

(* A composition skill's execution plan, as the batches it runs in.

   The flow arrives decoded in full -- every node, the tool it calls, the
   batch it sits in and how that batch runs -- and no renderer read any of
   it, so the pane could say a composition had been invoked twelve times
   without ever saying what it invokes.

   The batches are the ordering the server recorded. The usage card follows
   this summary with the complete node, batch and dependency records.

   Same arrow as the Goal stage rail and the Fusion topology row, so three
   surfaces spell a pipeline one way. *)
let skill_flow_line (flow : Masc.Tui_decode_tools.skill_flow) =
  let tool_of id =
    List.find_map
      (fun (node : Masc.Tui_decode_tools.skill_flow_node) ->
         if String.equal node.sfn_id id then Some node.sfn_tool_name else None)
      flow.sf_nodes
  in
  let batch (b : Masc.Tui_decode_tools.skill_flow_batch) =
    match List.filter_map tool_of b.sfb_node_ids with
    | [] -> None
    | tools ->
      Some
        (Printf.sprintf "%s %s"
           (Terminal_text.single_line b.sfb_execution_mode)
           (String.concat " \xc2\xb7 "
              (List.map Terminal_text.single_line tools)))
  in
  (* Execution modes and tool names as the server declared them. *)
  match List.filter_map batch flow.sf_batches with
  | [] -> None
  | parts -> Some (Say.as_received (String.concat "  \xe2\x94\x80\xe2\x96\xb6  " parts))
;;

(* Complete composition metadata, including nodes outside the recorded
   batches. The final physical-row projection keeps each value reachable. *)
let skill_flow_detail_lines (flow : Masc.Tui_decode_tools.skill_flow) =
  let safe value = Say.as_received (Terminal_text.single_line value) in
  let batches = List.map
    (fun (batch : Masc.Tui_decode_tools.skill_flow_batch) ->
      Ansi.dim,
      Say.per_language (function
        | Say.Ko -> Printf.sprintf "배치 %d · " batch.sfb_index
        | Say.En -> Printf.sprintf "Batch %d · " batch.sfb_index)
      ++ safe batch.sfb_execution_mode
      ++ Say.both ~ko:" · 노드: " ~en:" · nodes: "
      ++ safe (String.concat ", " batch.sfb_node_ids))
    flow.sf_batches in
  let nodes = List.concat_map
    (fun (node : Masc.Tui_decode_tools.skill_flow_node) ->
      (Ansi.dim,
       Say.both ~ko:"노드 " ~en:"Node " ++ safe node.sfn_id
       ++ Say.both ~ko:" · 도구: " ~en:" · tool: " ++ safe node.sfn_tool_name
       ++ Say.per_language (function
            | Say.Ko -> Printf.sprintf " · 배치: %d · 방식: " node.sfn_batch_index
            | Say.En -> Printf.sprintf " · batch: %d · mode: " node.sfn_batch_index)
       ++ safe node.sfn_execution_mode)
      :: (match node.sfn_dependencies with
          | [] -> [Ansi.dim, Say.both ~ko:"  의존: 없음" ~en:"  Dependencies: none"]
          | dependencies -> List.map
              (fun (dependency : Masc.Tui_decode_tools.skill_flow_dependency) ->
                Ansi.dim,
                Say.both ~ko:"  의존 " ~en:"  Dependency " ++ safe dependency.sfd_node_id
                ++ Say.both ~ko:" · 종류: " ~en:" · kind: " ++ safe dependency.sfd_kind) dependencies))
    flow.sf_nodes in
  batches @ nodes
;;

let skill_source_lines ~config ~(sources : Masc.Tui_decode_tools.skill_catalog_source list) =
  let ready =
    List.length
      (List.filter
         (fun (source : Masc.Tui_decode_tools.skill_catalog_source) ->
            match source.scso_observation with
            | Masc.Tui_decode_tools.Skill_source_ready count -> count > 0
            | Masc.Tui_decode_tools.Skill_source_missing
            | Masc.Tui_decode_tools.Skill_source_unresolved
            | Masc.Tui_decode_tools.Skill_source_not_directory _
            | Masc.Tui_decode_tools.Skill_source_unavailable _ -> false)
         sources)
  in
  let total = List.length sources in
  let heading =
    ( Ansi.bold
    , Say.per_language (function
        | Say.Ko -> Printf.sprintf " Skill 출처 · 루트 %d개 중 %d개에 Skill 있음" total ready
        | Say.En -> Printf.sprintf " Skill Sources · %d of %d root%s carrying skills"
            ready total (if total = 1 then "" else "s")) )
  in
  let source_rows =
    List.map
      (fun (source : Masc.Tui_decode_tools.skill_catalog_source) ->
         let tone, mark, reading = skill_source_reading source.scso_observation in
         let path =
           match source.scso_path with
           | Some path -> Say.as_received (Terminal_text.single_line path)
           | None -> Say.both ~ko:"(절대 경로라 공개 안 함)" ~en:"(absolute; path not published)"
         in
         ( tone
         , Say.code (Printf.sprintf "   %s " mark)
           ++ Say.as_received
                (pad_cells 16 (Terminal_text.single_line source.scso_id) ^ " "
                 ^ pad_cells 10 (Terminal_text.single_line source.scso_anchor) ^ " ")
           ++ Say.map (pad_cells 26) path
           ++ Say.code (Printf.sprintf " %-2s  " (skill_access_short source.scso_access))
           ++ reading ))
      sources
  in
  match sources with
  | [] -> []
  | _ -> (heading :: source_rows) @ skill_config_line config @ [ (Ansi.dim, Say.empty) ]
;;

(* The catalog's volume child shows what the next press sends, the server's
   last periodic inventory report, and the last operator-request answer. *)
let volume_tone = function
  | Masc_tui_volume_gc.Plain -> ""
  | Masc_tui_volume_gc.Dim -> Ansi.dim
  | Masc_tui_volume_gc.Bad -> Theme.bad ()

let volume_gc_lines (state : state) =
  let server_report =
    Option.map
      (fun (snapshot : Masc.Tui_decode_tools.tool_snapshot) ->
         Masc_tui_volume_gc.server_report_line
           ~timestamp:Terminal_text.short_timestamp_of_unix
           snapshot.Masc.Tui_decode_tools.ts_volume_gc_report)
      state.tools_inventory
  in
  List.map
    (fun (tone, text) -> Row (volume_tone tone, Say.code " " ++ text))
    (Masc_tui_volume_gc.lines ~server_report state.volume_gc)
;;

(* The storage pane: the host disk and the server's cleanup results from the
   inventory's envelope, then the server's periodic report on retired
   Keepers' volumes, which the catalog's volume child acts on. Before the
   first inventory reading there is nothing to draw but the frame's own
   "reading" line. *)
let storage_lines (state : state) =
  match state.tools_inventory with
  | None -> []
  | Some (snapshot : Masc.Tui_decode_tools.tool_snapshot) ->
    let timestamp = Terminal_text.short_timestamp_of_unix in
    let uptime =
      Option.bind state.server_identity (fun (identity : Masc.Tui_decode.server_identity) ->
        identity.sid_uptime)
    in
    let reading =
      List.map
        (fun (tone, text) ->
           let color =
             match tone with
             | Masc_tui_storage.Heading -> Ansi.bold
             | Masc_tui_storage.Plain -> ""
             | Masc_tui_storage.Dim -> Ansi.dim
             | Masc_tui_storage.Warn -> Theme.warn ()
             | Masc_tui_storage.Bad -> Theme.bad ()
           in
           color, Say.code " " ++ text)
        (Masc_tui_storage.lines ~timestamp ~uptime snapshot.ts_storage)
    in
    let tone, report =
      Masc_tui_volume_gc.server_report_line ~timestamp snapshot.ts_volume_gc_report
    in
    rows
      (reading
       @ [ Ansi.bold, Say.both ~ko:" 은퇴한 Keeper 의 볼륨" ~en:" Retired Keepers' volumes"
         ; volume_tone tone, Say.code "   " ++ report
         ; Ansi.dim,
           Say.both ~ko:"   회수: 전체 도구 탭  " ~en:"   Reclaim on All tools tab  "
           ++ Say.code Masc_tui_volume_gc.key
           ++ Say.both ~ko:":정리" ~en:":reclaim" ])
;;

(* Through [tab_strip], the one drawing every in-screen strip shares. This one
   was left out when the others moved: a bar between names, a space before the
   unmarked ones and the mark without the information colour, so the Tools
   row read "▸호출 범위 | 비동기 작업" under strips spelled two cells apart. *)
let tools_pane_strip ~cols (state : state) =
  let active_pane = match state.tools_pane with
    | Tools_catalog (Tools_catalog_volumes _) -> Tools_catalog Tools_catalog_list
    | (Tools_surface | Tools_async | Tools_activations | Tools_usage | Tools_storage
      | Tools_catalog Tools_catalog_list) as pane -> pane in
  let language = say_language state in
  tab_strip
    ~width:(tab_strip_width ~cols ~before:" " ~after:"")
    ~press:(fun pane text -> Masc_tui_press.(pressable (Press_tools_pane pane) text))
    (List.map
       (fun (pane, label) -> (Say.render language label, active_pane = pane, pane))
       [ (Masc_tui_types.Tools_surface, Say.both ~ko:"호출 범위" ~en:"Callable")
       ; (Masc_tui_types.Tools_async, Say.both ~ko:"비동기 작업" ~en:"Async work")
       ; (Masc_tui_types.Tools_activations, Say.both ~ko:"Skill 기록" ~en:"Skill log")
       ; (Masc_tui_types.Tools_usage, Say.both ~ko:"Skill 사용 집계" ~en:"Skill usage")
       ; (Masc_tui_types.Tools_catalog Tools_catalog_list, Say.both ~ko:"전체 도구" ~en:"All tools")
       ; (Masc_tui_types.Tools_storage, Say.both ~ko:"저장 공간" ~en:"Storage")
       ])
;;

let skill_usage_box ~cols rows =
  let width = Masc_tui_frame.inner_width ~cols in
  let content_width = max 1 (width - 4) in
  let border left right = Ansi.dim, left ^ draw_hline (max 0 (width - 2)) ^ right in
  let body =
    List.concat_map (fun (style, text) ->
      (if Masc_tui_message_layout.display_width text <= content_width then [text]
       else Masc_tui_message_layout.wrap_words ~max_cells:content_width text)
      |> List.map (fun line ->
        "",
        Ansi.dim ^ Ansi.box_v ^ Ansi.reset ^ " "
        ^ style ^ fit_width line content_width ^ Ansi.reset
        ^ " " ^ Ansi.dim ^ Ansi.box_v ^ Ansi.reset)) rows
  in
  if width < 5 then
    List.concat_map (fun (style, text) ->
      Masc_tui_message_layout.wrap_words ~max_cells:(max 1 width) text
      |> List.map (fun line -> style, line)) rows
  else
    border Ansi.box_tl Ansi.box_tr :: body
    @ [border Ansi.box_bl Ansi.box_br; Ansi.dim, ""]
;;

let skill_json_lines ~cols ~indent json =
  let width = max 1 (Masc_tui_frame.inner_width ~cols) in
  let lines = Yojson.Safe.pretty_to_string json
    |> String.split_on_char '\n'
    |> List.map Terminal_text.single_line in
  let widest = List.fold_left (fun widest line ->
    max widest (Masc_tui_message_layout.widest_grapheme_cells line)) 0 lines in
  let gutter = Masc_tui_message_layout.display_width
    (Masc_tui_markdown_theme.palette ~closing:Ansi.reset).code_gutter in
  let indent =
    if width < gutter + widest then 0
    else min indent (width - gutter - widest) in
  let indent = String.make indent ' ' in
  let body_width = max 1 (width - String.length indent) in
  let source = String.concat "\n" lines in
  Masc_tui_markdown_theme.code ~language:"json" ~width:body_width source
  |> List.map (fun line -> Ansi.reset, indent ^ line)

type 'row skill_json_projection =
  { json_source : Yojson.Safe.t
  ; json_cols : int
  ; json_palette_generation : int
  ; json_lines : 'row list
  }

let skill_schema_projection = ref None
let skill_settlements_projection = ref None
let skill_final_result_projection = ref None

let cached_skill_json projection ~cols ~render json =
  let generation = Masc_tui_terminal_palette.(snapshot_generation (snapshot ())) in
  match !projection with
  | Some cached when cached.json_source == json && cached.json_cols = cols
                     && cached.json_palette_generation = generation -> cached.json_lines
  | Some _ | None ->
      let lines = render json in
      projection := Some {json_source=json; json_cols=cols;
        json_palette_generation=generation; json_lines=lines};
      lines

(* A boxed card: the box wraps each row to its inside width. *)
let card ~cols pieces =
  Laid_out (fun language -> skill_usage_box ~cols (draw language pieces))

(* JSON as the ledger recorded it, laid out as a code block. *)
let json_rows lines = List.map (fun (style, text) -> style, Say.as_received text) lines

let skill_io_lines ~cols = function
  | Masc.Tui_decode_tools.Model_orchestrated ->
      [ Ansi.dim, Say.both ~ko:"     입력: 정확한 Skill 참조 / 고를 수 있는 resource 경로"
                    ~en:"     Input: exact Skill reference / optional resource path";
        Ansi.dim, Say.both ~ko:"     출력: 지침 본문이나 resource · 그다음 도구는 모델이 고름"
                    ~en:"     Output: instruction body or resource; subsequent tools are model-orchestrated";
        Ansi.dim, Say.both ~ko:"     평균 실행 시간: 지침 텍스트에는 없음"
                    ~en:"     Average execution: not applicable to instruction text" ]
  | Composition_io { input_schema; exports } ->
      (Ansi.bold, Say.both ~ko:"     선언한 입력 schema (필수 인자, 타입, enum)"
                    ~en:"     Declared input schema (required parameters, types and enums)")
      :: json_rows (cached_skill_json skill_schema_projection ~cols
           ~render:(skill_json_lines ~cols ~indent:7) input_schema)
      @ (match exports with
         | [] -> [Ansi.dim, Say.both ~ko:"     선언한 출력: 실행 결과 전체 (고른 export 없음)"
                              ~en:"     Declared output: complete execution result (no selected exports)"]
         | routes ->
           (Ansi.bold, Say.both ~ko:"     선언한 출력 경로" ~en:"     Declared output routes")
           :: List.map (fun route ->
             Ansi.dim,
             Say.code "       " ++ Say.as_received (Terminal_text.single_line route.Masc.Tui_decode_tools.sor_name)
             ++ Say.both ~ko:" ← 노드 " ~en:" ← node " ++ Say.as_received (Terminal_text.single_line route.sor_node_id)
             ++ Say.code " · JSON pointer "
             ++ (if route.sor_pointer = "" then Say.both ~ko:"(루트)" ~en:"(root)"
                 else Say.as_received (Terminal_text.single_line route.sor_pointer))) routes)
;;

let completed_word = Say.both ~ko:"완료" ~en:"completed"
let failed_word = Say.both ~ko:"실패" ~en:"failed"
let deferred_word = Say.both ~ko:"미룸" ~en:"deferred"

let skill_statistics_lines ~cols = function
  | None ->
    [Row (Ansi.dim, Say.both ~ko:"실행 시간 집계 없음 · 보고되지 않은 값은 0ms가 아닙니다"
                      ~en:"No run-time totals · an unreported total is not 0ms")]
  | Some stats ->
      let measured =
        [ completed_word, Theme.ok (), stats.Masc.Tui_decode_skill_evidence.scst_completed
        ; failed_word, Theme.bad (), stats.scst_failed ] in
      let milliseconds = function
        | None -> "—"
        | Some value -> Printf.sprintf "%.1fms" value in
      let duration (name, style, row) =
        [ style,
          name ++ Say.code (Printf.sprintf " · n=%d · " row.Masc.Tui_decode_skill_evidence.sds_samples)
          ++ Say.both ~ko:"평균 " ~en:"mean "
          ++ Say.code (Printf.sprintf "%s · P50 %s · P95 %s"
               (milliseconds row.sds_mean_ms) (milliseconds row.sds_p50_ms)
               (milliseconds row.sds_p95_ms))
        ; Ansi.dim,
          Say.per_language (function
            | Say.Ko -> Printf.sprintf "  최소 %s → 최대 %s"
                (milliseconds row.sds_min_ms) (milliseconds row.sds_max_ms)
            | Say.En -> Printf.sprintf "  min %s → max %s"
                (milliseconds row.sds_min_ms) (milliseconds row.sds_max_ms)) ] in
      let recorded_at value =
        try Say.as_received (Time_codec.rfc3339_of_unix value) with
        | Unix.Unix_error _ | Invalid_argument _ ->
          Say.per_language (function
            | Say.Ko -> Printf.sprintf "Unix 초 %.3f" value
            | Say.En -> Printf.sprintf "%.3f Unix seconds" value) in
      let window = match stats.scst_first_recorded_at, stats.scst_last_recorded_at with
        | Some first, Some last ->
          Say.both ~ko:"결과 기록 시각(UTC): " ~en:"Results recorded (UTC): "
          ++ recorded_at first ++ Say.code " → " ++ recorded_at last
        | _ ->
          (* The statistics came back without the window's ends: a value read
             but not reported, the 6.4 mark of RFC tui-one-screen-grammar. *)
          Say.both ~ko:"결과 기록 시각: " ~en:"Results recorded: "
          ++ Say.code (Masc_tui_value.Unknown.glyph Masc_tui_value.Unknown.Unreported) in
      let width = max 1 (Masc_tui_frame.inner_width ~cols - 4) in
      rows
        ([ Theme.info (),
           Say.per_language (function
             | Say.Ko -> Printf.sprintf "executor 실행 시간 · 보존된 원래 실행 %d건" stats.scst_records
             | Say.En -> Printf.sprintf "executor run time · %d original runs retained" stats.scst_records)
         ; Ansi.dim, Say.both ~ko:"동일 revision / 전체 Keepers · P50/P95: nearest rank"
                       ~en:"Same revision / all Keepers · P50/P95: nearest rank"
         ; Ansi.dim, window ]
         @ List.concat_map duration measured
         @ [ Ansi.bold, Say.both ~ko:"실행 결과 분포 · 분모는 보존된 원래 실행 수"
                          ~en:"Run results · out of the original runs retained" ])
      (* The bars are sized beside their names, so the chart is drawn once
         the language is chosen. *)
      @ [ Laid_out (fun language ->
            Masc_tui_chart.distribution_bars ~width
              [ { name = Say.render language completed_word
                ; count = stats.scst_completed.sds_samples; style = Masc_tui_theme.Ok }
              ; { name = Say.render language failed_word
                ; count = stats.scst_failed.sds_samples; style = Masc_tui_theme.Bad }
              ; { name = Say.render language deferred_word
                ; count = stats.scst_deferred; style = Masc_tui_theme.Warn } ]
            |> List.map (fun line -> "", line)) ]
      @ [ Row (Ansi.dim, Say.both ~ko:"deferred는 실행 시간에서 제외 · queue/의존 대기/model 시간은 별도"
                           ~en:"deferred is left out of run time · queue, dependency wait and model time are separate") ]
;;

let skill_settlement_lines_uncached ~cols composition =
  match json_assoc_member_opt "executor_settlements" composition with
  | Some (`List settlements) ->
      List.concat_map (fun node ->
        let field name = match json_assoc_member_opt name node with
          | Some (`String value) -> Say.as_received (Terminal_text.single_line value)
          | Some value -> Say.as_received (Terminal_text.single_line (Yojson.Safe.to_string value))
          | None -> Say.both ~ko:"알 수 없음" ~en:"unavailable" in
        let content label name = (Ansi.bold, Say.code "       " ++ label) ::
          (match json_assoc_member_opt name node with
           | Some value -> json_rows (skill_json_lines ~cols ~indent:9 value)
           | None -> [Ansi.dim, Say.both ~ko:"         없음" ~en:"         unavailable"]) in
        [Ansi.bold,
         Say.both ~ko:"     관측한 노드 " ~en:"     Observed node " ++ field "node_id"
         ++ say_dot ++ field "tool_name" ++ Say.code " · origin=" ++ field "execution_origin";
         Ansi.dim,
         Say.code "       output bytes=" ++ field "result_bytes"
         ++ Say.code " · truncated_to=" ++ field "truncated_to";
         Ansi.dim,
         Say.code "       execution=" ++ field "execution_id"
         ++ Say.code " · tool use=" ++ field "tool_use_id"]
        @ content (Say.both ~ko:"관측한 입력" ~en:"Observed input") "input"
        @ content (Say.both ~ko:"관측한 결과 (disposition, 걸린 시간, 출력)"
                     ~en:"Observed result (disposition, duration, output)") "result") settlements
  | Some _ | None -> []
;;

let skill_settlement_lines ~cols composition =
  cached_skill_json skill_settlements_projection ~cols
    ~render:(skill_settlement_lines_uncached ~cols) composition

let skill_run_history_lines state (evidence : Masc.Tui_decode_skill_evidence.skill_evidence) =
  match evidence.se_composition_runs with
  | None ->
    [Theme.warn (), Say.both ~ko:"     실행 기록 없음 · 저장 공백으로는 없었다고 할 수 없음"
                      ~en:"     Run history unavailable; storage gaps cannot establish absence"]
  | Some runs ->
    let selected_id = match evidence.se_composition_selection with
      | Latest_retained -> Option.map
          (fun (run : Masc.Keeper_skill_composition_evidence.run_summary) -> run.run_id)
          (List.nth_opt runs 0)
      | Exact_run run_id -> Some run_id in
    let index = Option.bind selected_id (fun run_id ->
      List.find_index (fun (run : Masc.Keeper_skill_composition_evidence.run_summary) ->
        Masc.Keeper_tool_plan.Composition_run_id.equal run_id run.run_id) runs) in
    let position =
      Printf.sprintf "%s/%d"
        (Option.fold ~none:"—" ~some:(fun index -> string_of_int (index + 1)) index) (List.length runs) in
    [Ansi.bold,
     Say.per_language (function
       | Say.Ko -> Printf.sprintf "     원래 실행: %s  [:이전  ]:다음  Enter:최신" position
       | Say.En -> Printf.sprintf "     Original runs: %s  [:older  ]:newer  Enter:latest" position);
     Ansi.dim, Say.both ~ko:"       실행마다 보존된 마지막 결과 · 앞선 전이는 바뀌었을 수 있음"
                 ~en:"       Each run's latest retained result; earlier transitions may be replaced"]
    @ (match evidence.se_composition_selection, index with
       | Exact_run run_id, None ->
         [Theme.warn (), Say.both ~ko:"       요청한 실행이 이 revision 의 보존 범위에 없음: "
                           ~en:"       Requested run absent in this revision's retained coverage: "
           ++ Say.as_received (Masc.Keeper_tool_plan.Composition_run_id.to_string run_id);
          Ansi.dim, Say.both ~ko:"       다른 실행으로 바꾸지 않음 · 통계는 보존된 실행 전체"
                      ~en:"       No other run substituted; statistics still cover all retained runs"]
       | Latest_retained, (None | Some _) | Exact_run _, Some _ -> [])
    @ List.filter_map (fun (label, delta) ->
        adjacent_skill_evidence_run state ~reference:evidence.se_reference
          ~selection:evidence.se_composition_selection ~runs:evidence.se_composition_runs ~delta
        |> Option.map (fun run_id ->
          Ansi.dim, Say.code "       " ++ label ++ Say.code ": "
                    ++ Say.as_received (Masc.Keeper_tool_plan.Composition_run_id.to_string run_id)))
        [Say.both ~ko:"이전" ~en:"older", 1; Say.both ~ko:"다음" ~en:"newer", -1]
;;

let request_selection_prefix = Say.both ~ko:"요청: " ~en:"Request: "

let skill_selection_prefix ~index ~count =
  Say.code (Printf.sprintf "Skill %d/%d: " (index + 1) count)

(* The selection row of the frame, drawn by the frame in the screen's
   language. *)
let tools_selection_line ~cols state =
  let language = say_language state in
  let text = match state.tools_skill_source_picker with
    | Some picker ->
      Say.both ~ko:"새 " ~en:"New "
      ++ Say.code (if picker.ssp_composition then "Composition" else "Instruction")
      ++ Say.both ~ko:" · 저장할 곳 고르기" ~en:" · choose a save location"
    | None when Option.is_some (tools_volume_gc_parent_scroll state.tools_pane) ->
      Say.both ~ko:"은퇴한 Keeper의 볼륨" ~en:"Retired Keeper volumes"
    | None when state.tools_pane = Tools_storage ->
      Say.both ~ko:"호스트 디스크와 Keeper 저장 공간 정리" ~en:"Host disk and Keeper storage cleanup"
    | None when state.tools_pane = Tools_async ->
      (match state.tools_async_selection with
       | None -> Say.both ~ko:"비동기 요청: 없음" ~en:"Async request: none"
       | Some target ->
         Say.map (Masc_tui_message_layout.fit_middle (Masc_tui_frame.inner_width ~cols))
           (request_selection_prefix ++ Say.as_received (Terminal_text.single_line target.request_id)))
    | None ->
      (match selected_tools_skill_profile state with
       | None -> Say.both ~ko:"Skill: 없음" ~en:"Skill: none"
       | Some profile ->
         let prefix =
           skill_selection_prefix ~index:state.tools_skill_cursor
             ~count:(List.length (tools_skill_profiles state))
         in
         prefix ++ Say.as_received (Masc_tui_message_layout.fit_middle
           (max 1 (Masc_tui_frame.inner_width ~cols
                   - Masc_tui_message_layout.display_width (Say.render language prefix)))
           (Terminal_text.single_line profile.esp_name)))
  in
  Say.render language text

(* The selection row above the document cuts the middle of a name that does
   not fit the row. The document names the selection again only then, so a
   name that fits is on screen once and a cut name can still be read whole.
   Whether it fits depends on the words, so it is decided when the language
   is chosen. *)
let named_again ~cols ~selection_row ~title =
  Laid_out (fun language ->
    if Masc_tui_message_layout.display_width (Say.render language selection_row)
       > Masc_tui_frame.inner_width ~cols
    then draw language [ title ] else [])

let request_selection_document ~cols (target : Masc.Tui_decode_async_request.target) =
  let request_id = Say.as_received (Terminal_text.single_line target.request_id) in
  [ named_again ~cols ~selection_row:(request_selection_prefix ++ request_id)
      ~title:(Row (Ansi.bold, Say.code " " ++ request_selection_prefix ++ request_id))
  ; Row (Ansi.dim,
         Say.both ~ko:" 원래 요청자: " ~en:" Requested by: "
         ++ Say.as_received (Terminal_text.single_line target.submitted_by)
         ++ Say.both ~ko:" · 대상 Keeper: " ~en:" · Keeper: "
         ++ Say.as_received (Terminal_text.single_line target.keeper_name)) ]

(* The Skill at [index] of [count]: its selection row counts its place, so
   whether the row fits depends on the place as well as on the name. *)
let skill_selection_document ~cols ~count index
    (profile : Masc.Tui_decode_tools.effective_skill_profile) =
  let reference = profile.esp_reference in
  let name = Say.as_received (Terminal_text.single_line profile.esp_name) in
  (* Where the Skill comes from is one fact in three parts, so it takes
     one row: the list below gets the two rows the parts used to take
     each. A row too long for the frame wraps rather than cutting an
     identity. *)
  let field label value = label ++ Say.code " " ++ Say.as_received value in
  [ named_again ~cols ~selection_row:(skill_selection_prefix ~index ~count ++ name)
      ~title:(Row (Ansi.bold, Say.both ~ko:"동작 대상 Skill: " ~en:"Action Skill: " ++ name))
  ; Row (Ansi.dim,
         Say.concat ~sep:say_dot
           [ field (Say.both ~ko:"출처" ~en:"Source") (Terminal_text.single_line
               (Skill_reference.identity_source_id_to_string reference.identity));
             field (Say.both ~ko:"패키지" ~en:"Package") (Terminal_text.single_line
               (Skill_reference.identity_package_id_to_string reference.identity));
             field (Say.both ~ko:"리비전" ~en:"Revision") (Masc_tui_value.Hash.short (Terminal_text.single_line
               (Skill_reference.content_revision_to_string reference.content_revision))) ]) ]

let tools_selection_document ~cols state =
  if state.tools_pane = Tools_async then
    Option.fold ~none:[] ~some:(request_selection_document ~cols) state.tools_async_selection
  else
    let profiles = tools_skill_profiles state in
    match List.nth_opt profiles state.tools_skill_cursor with
    | None -> []
    | Some profile ->
        skill_selection_document ~cols ~count:(List.length profiles) state.tools_skill_cursor
          profile

(* The loaded list the move keys walk on this pane, as it was read: the
   Skills of the Effective Keeper Surface, or the async requests while no
   request is open. A new read is a new list. *)
type selections =
  | Skill_selections of Masc.Tui_decode_tools.effective_skill_profile list
  | Request_selections of Tui_decode.async_request_row list

let selections (state : state) =
  match state.tools_pane with
  | Tools_surface -> (
      match state.tools_inventory with
      | Some
          { Masc.Tui_decode_tools.ts_effective =
              Some (Masc.Tui_decode_tools.Effective_surface_available { ets_skill_profiles; _ })
          ; _ } ->
          Some (Skill_selections ets_skill_profiles)
      | Some
          { Masc.Tui_decode_tools.ts_effective =
              None | Some (Masc.Tui_decode_tools.Effective_surface_unavailable _)
          ; _ }
      | None -> None)
  | Tools_async when not state.tools_async_detail_open -> (
      match state.tools_async_observation with
      | Some (Tui_decode.Async_ready { requests; _ }) -> Some (Request_selections requests)
      | Some (Tui_decode.Async_unavailable _) | None -> None)
  | Tools_async | Tools_activations | Tools_usage | Tools_storage | Tools_catalog _ -> None

let same_selections seen loaded =
  match seen, loaded with
  | Skill_selections seen, Skill_selections loaded -> seen == loaded
  | Request_selections seen, Request_selections loaded -> seen == loaded
  | Skill_selections _, Request_selections _ | Request_selections _, Skill_selections _ -> false

(* The document of every selection the list can land on, in the order the
   list draws them, from the state the list was read from. *)
let selection_documents ~cols state = function
  | Skill_selections _ ->
      let profiles = tools_skill_profiles state in
      List.mapi (skill_selection_document ~cols ~count:(List.length profiles)) profiles
  | Request_selections _ -> List.map (request_selection_document ~cols) (tools_async_targets state)

(* The rows the tallest of those documents takes, counted once for as long
   as the same list is loaded at the same width in the same language, as the
   Memory screen counts its tallest fact: wrapping every entry's document on
   each frame made a Skill key on 54 Skills about two fifths slower, and the
   cost grows with the list. *)
let tallest_selection_memo : (selections * int * Say.language * int) option Domain.DLS.key =
  Domain.DLS.new_key (fun () -> None)

let tallest_selection_rows ~cols ~language ~rows_of state loaded =
  match Domain.DLS.get tallest_selection_memo with
  | Some (seen, seen_cols, seen_language, tallest)
    when same_selections seen loaded && seen_cols = cols && seen_language = language -> tallest
  | Some _ | None ->
      let tallest =
        List.fold_left
          (fun tallest document -> max tallest (rows_of document))
          0 (selection_documents ~cols state loaded)
      in
      Domain.DLS.set tallest_selection_memo (Some (loaded, cols, language, tallest));
      tallest

(* The Effective Keeper Surface's diagnostics: what the runtime says about
   itself, the two digests and the byte budgets. [hash] draws a digest: its
   head on screen (RFC tui-one-screen-grammar, section 5.2), the whole value
   in a copy. An unavailable surface has none. *)
let effective_surface_diagnostics ~hash = function
  | Masc.Tui_decode_tools.Effective_surface_unavailable _ -> []
  | Masc.Tui_decode_tools.Effective_surface_available
      { ets_runtime_id; ets_official_client_kind; ets_native_posture;
        ets_skill_snapshot_revision; ets_skill_resource_read_max_bytes;
        ets_tool_surface_bytes; ets_skill_tool_surface_bytes;
        ets_skill_discovery_bytes; ets_skill_body_bytes; ets_tool_surface_sha256; _ } ->
      let byte_count = function
        | Some bytes -> Printf.sprintf "%dB" bytes
        | None -> "?"
      in
      [ Say.code (Printf.sprintf "runtime=%s  client=%s  native=%s"
          (Terminal_text.single_line ets_runtime_id)
          (Terminal_text.single_line ets_official_client_kind)
          (Option.value
             ~default:(Masc_tui_value.Unknown.glyph Masc_tui_value.Unknown.Unreported)
             ets_native_posture))
      ; Say.code "skill snapshot=" ++ Say.as_received (hash (Terminal_text.single_line ets_skill_snapshot_revision))
      ; (match ets_skill_resource_read_max_bytes with
         | Some max_bytes ->
           Say.per_language (function
             | Say.Ko -> Printf.sprintf "미룬 resource 한도 %d바이트" max_bytes
             | Say.En -> Printf.sprintf "deferred resource bound=%d bytes" max_bytes)
         | None -> Say.both ~ko:"미룬 resource 한도 없음" ~en:"deferred resource bound=not configured")
      ; Say.per_language (function
          | Say.Ko -> Printf.sprintf
              "Skill 맥락: profile 탐색 %dB · 미룬 본문 %s · skill 도구 schema %s / 전체 도구 %s"
              ets_skill_discovery_bytes (byte_count ets_skill_body_bytes)
              (byte_count ets_skill_tool_surface_bytes) (byte_count ets_tool_surface_bytes)
          | Say.En -> Printf.sprintf
              "Skill context: profile discovery=%dB · deferred bodies=%s · skill tool schema=%s/%s all tools"
              ets_skill_discovery_bytes (byte_count ets_skill_body_bytes)
              (byte_count ets_skill_tool_surface_bytes) (byte_count ets_tool_surface_bytes))
      ; Say.code "digest="
        ++ (match ets_tool_surface_sha256 with
            | None -> Say.both ~ko:"없음 (턴은 Agent Core 가 가짐)" ~en:"none (Agent Core owns the turn)"
            | Some value -> Say.as_received (hash (Terminal_text.single_line value))) ]

(* What Y copies, in the screen's language. *)
let tools_diagnostics_copy_text (state : state) =
  match state.tools_inventory with
  | None | Some { Masc.Tui_decode_tools.ts_effective = None; _ } -> None
  | Some { Masc.Tui_decode_tools.ts_effective = Some surface; _ } ->
      (match surface with
       | Masc.Tui_decode_tools.Effective_surface_unavailable _ -> None
       | Masc.Tui_decode_tools.Effective_surface_available { ets_keeper_name; _ } ->
           let field label value = label ++ Say.code ": " ++ Say.as_received (Terminal_text.single_line value) in
           let skill =
             match selected_tools_skill_profile state with
             | None -> []
             | Some profile ->
                 let reference = profile.esp_reference in
                 [ field (Say.code "Skill") profile.esp_name
                 ; field (Say.both ~ko:"출처" ~en:"Source")
                     (Skill_reference.identity_source_id_to_string reference.identity)
                 ; field (Say.both ~ko:"패키지" ~en:"Package")
                     (Skill_reference.identity_package_id_to_string reference.identity)
                 ; field (Say.both ~ko:"리비전" ~en:"Revision")
                     (Skill_reference.content_revision_to_string reference.content_revision) ]
           in
           Some
             (Say.render (say_language state)
                (Say.concat ~sep:(Say.code "\n")
                   (field (Say.code "Keeper") ets_keeper_name
                    :: effective_surface_diagnostics ~hash:Fun.id surface
                    @ skill))))

let skill_source_picker_prefix summary =
  [ Ansi.bold, Say.both ~ko:" 패키지 저장 출처 선택 (쓰기 가능)"
                 ~en:" Choose the writable source for this package"
  ; Ansi.dim, Say.both ~ko:" j/k·화살표:선택  Enter:편집  /:필터  Esc:취소"
                ~en:" j/k/arrows:select  Enter:edit  /:filter  Esc:cancel"
  ; Ansi.dim, Say.code " " ++ summary ]

let skill_source_picker_page state ~terminal_rows =
  max 1 (tools_content_rows state ~terminal_rows ~count:0
    - List.length (skill_source_picker_prefix Say.empty))

let surface_title = Say.both ~ko:" Keeper 호출 범위" ~en:" Effective Keeper Surface"

type cursor_rows = { first_row : int; last_row : int }

type display =
  { lines : (string * string) list
  ; cursor : cursor_rows option
  ; card : cursor_rows option
  ; row_changes : (int * float) list
  ; entries : (paged_list * cursor_rows list) option
  }

let tools_display ?(cols = 80) ?terminal_rows (state : state) : display =
  let language = say_language state in
  match state.tools_skill_source_picker with
  | Some picker ->
    let terminal_rows = match terminal_rows with Some rows -> rows | None -> fst (get_terminal_size ()) in
    let view = Masc_tui_pick_list.view ~page:(skill_source_picker_page state ~terminal_rows)
      ~window:Masc_tui_pick_list.Opens_at_cursor ~label:Fun.id picker.ssp_sources picker.ssp_list in
    (* The picker pages its own window to its cursor, so no Skill row is
       reported for the frame to scroll to, and it draws no time text. *)
    { lines =
        draw language (rows
          (skill_source_picker_prefix (Say.of_ko_flag (fun ~ko -> Masc_tui_pick_list.summary ~ko view))
           @ (if view.rows = [] then [Theme.warn (), Say.both ~ko:" 맞는 출처 없음" ~en:" No matching source"] else
               List.mapi (fun index source ->
                 let selected = view.selected_row = Some index in
                 (if selected then Theme.selection_style () else Ansi.dim),
                 Say.code (if selected then " › " else "   ")
                 ++ Say.as_received (Terminal_text.single_line source)) view.rows)))
    ; cursor = None
    ; card = None
    ; row_changes = []
    ; entries = None }
  | None ->
  let registered_tools =
    match state.tools_inventory with
    | None -> []
    | Some s -> s.Masc.Tui_decode_tools.ts_tools
  in
  let effective_lines =
    lazy begin
    match state.tools_inventory with
    (* Unread and failed are two answers. "not loaded" under the red
       "tool inventory load failed" row sent the reader to [r] for a read
       that had already been made and refused. *)
    | None ->
        rows
          [ ( (if Option.is_some (selected_tools_error state) then Theme.bad () else Theme.warn ())
            , surface_title ++ Say.code " "
              ++ Say.of_ko_flag (fun ~ko -> title_missing_reading ~ko ~error:(selected_tools_error state)) )
          ]
    | Some { Masc.Tui_decode_tools.ts_effective = None; _ } ->
        rows [ (Theme.warn ()), surface_title ++ Say.both ~ko:" · 고른 Keeper 없음" ~en:" · no Keeper selected" ]
    | Some
        { Masc.Tui_decode_tools.ts_effective =
            Some
              (Masc.Tui_decode_tools.Effective_surface_unavailable
                 { ets_keeper_name; ets_reason; ets_detail });
          _ } ->
        rows
          [ (Theme.bad ()),
            surface_title ++ Say.code " · " ++ Say.as_received (Terminal_text.single_line ets_keeper_name)
            ++ Say.both ~ko:" · 조회 불가 (" ~en:" · unavailable ("
            ++ Say.as_received (Terminal_text.single_line ets_reason) ++ Say.code ")";
            (Theme.bad ()), Say.code "   " ++ Say.as_received (Terminal_text.single_line ets_detail) ]
    | Some
        { Masc.Tui_decode_tools.ts_effective =
            Some
              (Masc.Tui_decode_tools.Effective_surface_available
                 { ets_keeper_name;
                   (* The fields bound to [_] are drawn under the diagnostics
                      heading, by [effective_surface_diagnostics]. *)
                   ets_runtime_id = _;
                   ets_official_client_kind = _;
                   ets_tool_delivery;
                   ets_native_posture = _;
                   ets_skill_snapshot_revision = _;
                   ets_skill_resource_read_max_bytes = _;
                   ets_skills_left_out;
                   ets_unavailable_skill_names;
                   ets_skill_profiles;
                   ets_tool_surface_bytes = _;
                   ets_skill_tool_surface_bytes = _;
                   ets_skill_discovery_bytes = _;
                   ets_skill_body_bytes = _;
                   ets_tools;
                   ets_tool_surface_sha256 = _;
                 } as surface);
          _ } ->
        let delivery_tone, delivery =
          match ets_tool_delivery with
          | Masc.Tui_decode_tools.Effective_tools_delivered ->
            Ansi.dim, Say.both ~ko:"지원" ~en:"delivered"
          | Masc.Tui_decode_tools.Effective_tools_suppressed_runtime_unsupported ->
            Theme.warn (), Say.both ~ko:"미지원으로 제외" ~en:"left out, the runtime does not support tools"
        in
        (* Folded under one heading by default (RFC tui-one-screen-grammar,
           section 5.1): these rows sat above the Skill list, two of them a
           64-character digest each. *)
        let diagnostics_lines =
          let folded = state.tools_diagnostics_folded in
          ( Ansi.dim,
            Say.code (Printf.sprintf "   %s " (if folded then "▸" else "▾"))
            ++ Say.both ~ko:"진단" ~en:"Diagnostics"
            ++ say_dot ++ Say.code (Masc_tui_keys.expand_turn_label ^ " ")
            ++ (if folded then Say.both ~ko:"펴기" ~en:"unfold" else Say.both ~ko:"접기" ~en:"fold")
            ++ say_dot ++ Say.code "Y " ++ Say.both ~ko:"전체 복사" ~en:"copy all" )
          :: (if folded then []
              else
                List.map (fun line -> Ansi.dim, Say.code "     " ++ line)
                  (effective_surface_diagnostics ~hash:Masc_tui_value.Hash.short surface))
        in
        let tool_lines =
          List.map
            (fun (tool : Masc.Tui_decode_tools.effective_tool) ->
               (* The source id, not the skill name: the name repeats what
                  the tool is already called (keeper_compose_work-intake ->
                  work-intake), while the id answers the question this
                  column asks -- which configured source this came from. It
                  is also short, so the column does not have to cut it. *)
               let kind = Masc.Tui_decode_tools.effective_tool_origin_kind tool.et_origin in
               let source =
                 match tool.et_origin with
                 | Masc.Tui_decode_tools.Composition_skill_origin
                     { skill_source_id = Some source_id } ->
                   kind ^ ":" ^ source_id
                 | Masc.Tui_decode_tools.Composition_skill_origin { skill_source_id = None }
                 | Masc.Tui_decode_tools.Descriptor_origin
                 | Masc.Tui_decode_tools.Instruction_skill_origin
                 | Masc.Tui_decode_tools.Composition_control_origin
                 | Masc.Tui_decode_tools.Unrecognised_origin _ -> kind
               in
               Ansi.dim,
               Tool_table.effective_tool_line
                 ~name:(Terminal_text.single_line (Masc.Tool_display.list_label tool.et_name))
                 ~origin:(Terminal_text.single_line source))
            ets_tools
        in
        let ets_skill_profiles = tools_skill_profiles state in
        let is_normal profile = match profile.Masc.Tui_decode_tools.esp_io with
          | Model_orchestrated -> true | Composition_io _ -> false in
        (* The name column is as wide as the longest name, up to a cap, so a
           long name such as [verify-before-claiming-done] no longer pushes
           its row's execution and sizes past every other row's. *)
        let skill_name_cells =
          List.fold_left
            (fun widest (profile : Masc.Tui_decode_tools.effective_skill_profile) ->
              max widest
                (Masc_tui_message_layout.display_width
                   (Terminal_text.single_line profile.esp_name)))
            skill_name_min_cells ets_skill_profiles
          |> min skill_name_max_cells
        in
        let skill_profile_lines =
          List.mapi
            (fun index (profile : Masc.Tui_decode_tools.effective_skill_profile) ->
               let instruction = is_normal profile in
               let execution =
                 match profile.esp_surface with
                 | Masc.Keeper_skill_observability.Instruction_skill ->
                   Say.both ~ko:"필요할 때" ~en:"on-demand"
                 | Masc.Keeper_skill_observability.Composition_skill
                     Masc.Keeper_tool_composition_catalog.Inline ->
                   Say.both ~ko:"동기 실행" ~en:"inline"
                 | Masc.Keeper_skill_observability.Composition_skill
                     Masc.Keeper_tool_composition_catalog.Async ->
                   Say.both ~ko:"비동기 실행" ~en:"async"
               in
               (* An instruction skill is text the model reads; it has no
                  flow, so its node, batch and parallel counts are zero on
                  every row. A composition's are the shape of its plan and
                  are drawn. *)
               let flow =
                 if instruction then ""
                 else
                   Printf.sprintf " nodes=%d batches=%d parallel=%d"
                     profile.esp_node_count
                     profile.esp_batch_count
                     profile.esp_max_parallelism
               in
               (* Why a skill is loaded is worth a row when something chose
                  it. Loaded because the catalog holds it is the default for
                  every skill here, and a row per skill saying so is the same
                  sentence down the pane. *)
               let chosen =
                 profile.esp_load_reasons
                 |> List.filter_map (function
                      | Masc.Tui_decode_tools.Skill_catalog_default -> None
                      | Masc.Tui_decode_tools.Skill_keeper_profile ->
                        Some (Say.both ~ko:"Keeper 프로필" ~en:"Keeper profile")
                      | Masc.Tui_decode_tools.Skill_task task_id ->
                        Some (Say.code "Task " ++ Say.as_received (Terminal_text.single_line task_id)))
               in
               let heading =
                 let first_in_group = index = 0 ||
                   (match List.nth_opt ets_skill_profiles (index - 1) with
                    | None -> true
                    | Some previous -> is_normal previous <> instruction) in
                 if not first_in_group then [] else
                   [Ansi.bold,
                    Say.code "   "
                    (* Headings follow the screen language and are not
                       written in capitals only (RFC tui-one-screen-grammar
                       section 5.1); Skill and Composition are product
                       nouns and stay as they are. *)
                    ++ (if instruction
                        then Say.both ~ko:"지침 Skill" ~en:"Normal Skills · instructions"
                        else Say.both ~ko:"Composition Skill · 실행 계획"
                            ~en:"Composition Skills · executable plans")
                    ++ Say.code (Printf.sprintf " (%d)"
                         (List.length (List.filter (fun value -> is_normal value = instruction) ets_skill_profiles)))] in
               let selected = index = state.tools_skill_cursor in
               let skill_row =
                 Say.code (Printf.sprintf " %s "
                   (if selected then Masc_tui_theme.Glyph.current_entry else " "))
                 ++ Say.as_received (Masc_tui_message_layout.fit_middle skill_name_cells
                      (Terminal_text.single_line profile.esp_name))
                 ++ Say.code " " ++ Say.map (pad_cells 11) execution
                 ++ Say.code (Printf.sprintf "%s discovery=%dB body=%dB"
                      flow profile.esp_discovery_bytes profile.esp_body_bytes)
               in
               (* The rows that say why the selected Skill was loaded are
                  its rows too, so following the cursor brings them in. *)
               let entry_rows lines =
                 if selected then List.map (fun (style, text) -> Cursor (style, text)) lines
                 else rows lines
               in
               List_entry
                 (rows heading
                  @ [ (if selected then Cursor (Theme.selection_style (), skill_row)
                       else Row (Ansi.dim, skill_row)) ]
                  @ entry_rows (match profile.esp_load_reasons, chosen with
                      | [], _ ->
                          [ ( Theme.warn ()
                            , Say.both ~ko:"     불러온 이유: 알 수 없음" ~en:"     why loaded: unattributed" ) ]
                      | _, [] -> []
                      | _, chosen ->
                          [ ( Ansi.dim
                            , Say.both ~ko:"     불러온 이유: " ~en:"     why loaded: "
                              ++ Say.concat ~sep:(Say.code " + ") chosen )
                          ])))
            ets_skill_profiles
        in
        let selected_skill_flow_lines =
          match List.nth_opt ets_skill_profiles state.tools_skill_cursor with
          | None -> []
          | Some { Masc.Tui_decode_tools.esp_flow = None; _ } ->
            [ Ansi.dim, Say.both ~ko:"     흐름: 지침 본문 온디맨드 로드 · 도구 모델 자율 선택"
                          ~en:"     Flow: instruction body loads on demand; the model orchestrates tools" ]
          | Some { Masc.Tui_decode_tools.esp_flow = Some flow; _ } ->
            (* Grouped under the batch that runs them, rather than listed
               flat with a batch=N to cross-reference. The batches are the
               order; the nodes are what is in each one. Two readings, and
               the old shape made the reader join them by hand.

               A tree, not a graph: the dependencies are already named on the
               node, and drawing edges between rows buys a picture at the
               price of a screen nobody can scan. *)
            let node_by_id id =
              List.find_opt
                (fun (node : Masc.Tui_decode_tools.skill_flow_node) ->
                   String.equal node.sfn_id id)
                flow.sf_nodes
            in
            let dependency_text (node : Masc.Tui_decode_tools.skill_flow_node) =
              match node.sfn_dependencies with
              | [] -> ""
              | values ->
                "  \xe2\x86\x90 "
                ^ (values
                   |> List.map (fun (dependency : Masc.Tui_decode_tools.skill_flow_dependency) ->
                        dependency.sfd_node_id ^ ":" ^ dependency.sfd_kind)
                   |> String.concat ", ")
            in
            let batch_count = List.length flow.sf_batches in
            let batch_lines =
              flow.sf_batches
              |> List.mapi (fun batch_position (batch : Masc.Tui_decode_tools.skill_flow_batch) ->
                let last_batch = batch_position = batch_count - 1 in
                let node_count = List.length batch.sfb_node_ids in
                batch.sfb_node_ids
                |> List.mapi (fun node_position node_id ->
                  let first_node = node_position = 0 in
                  let stem =
                    if first_node then
                      if last_batch then "\xe2\x94\x94" else "\xe2\x94\x9c"
                    else if last_batch then " "
                    else "\xe2\x94\x82"
                  in
                  let label =
                    if first_node then
                      Printf.sprintf "%d %s" batch.sfb_index
                        (Terminal_text.single_line batch.sfb_execution_mode)
                    else ""
                  in
                  let tool, dependencies =
                    match node_by_id node_id with
                    | None -> Say.both ~ko:"(노드에 없음)" ~en:"(not in nodes)", ""
                    | Some node ->
                      ( Say.as_received (Terminal_text.single_line node.sfn_tool_name)
                      , dependency_text node )
                  in
                  ( Ansi.dim
                  , Say.code (Printf.sprintf "     %s " stem)
                    ++ Say.as_received (Printf.sprintf "%-12s %-18s " label (Terminal_text.single_line node_id))
                    ++ tool ++ Say.as_received dependencies ))
                |> fun lines ->
                if node_count = 0 then
                  [ ( Ansi.dim
                    , Say.code (Printf.sprintf "     %s %d "
                        (if last_batch then "\xe2\x94\x94" else "\xe2\x94\x9c")
                        batch.sfb_index)
                      ++ Say.as_received (Terminal_text.single_line batch.sfb_execution_mode)
                      ++ Say.both ~ko:" (노드 없음)" ~en:" (no nodes)" )
                  ]
                else lines)
              |> List.concat
            in
            ( Ansi.bold
            , Say.per_language (function
                | Say.Ko -> Printf.sprintf "     선언한 그래프 · Ctrl-O:Pele · 배치 %d개 · 노드 %d개"
                    batch_count (List.length flow.sf_nodes)
                | Say.En -> Printf.sprintf "     Declared graph · Ctrl-O:Pele · %d batches · %d nodes"
                    batch_count (List.length flow.sf_nodes)) )
            :: batch_lines
        in
        let selected_skill_statistics_lines, selected_skill_evidence_lines =
          match List.nth_opt ets_skill_profiles state.tools_skill_cursor with
          | None -> [], []
          | Some profile ->
            let key =
              Skill_reference.to_yojson profile.esp_reference |> Yojson.Safe.to_string
            in
            let unavailable = Say.both ~ko:"알 수 없음" ~en:"unavailable" in
            (match state.tools_skill_evidence with
             | Some (observed_key, json) when String.equal key observed_key ->
              (match Masc.Tui_decode_skill_evidence.decode_skill_evidence json with
               | Error _ ->
                 rows [ Theme.bad (), Say.both ~ko:"실측 응답 형식 오류" ~en:"Measurement response is malformed" ],
                 [ Theme.bad (), Say.both ~ko:"     보존된 실측 응답 형식 오류"
                                   ~en:"     Retained evidence response is malformed" ]
               | Ok evidence ->
               let evidence_lines =
                 match evidence.Masc.Tui_decode_skill_evidence.se_status with
                 | Masc.Tui_decode_skill_evidence.Skill_evidence_not_observed_in_retained_coverage ->
                  [ Theme.warn (),
                    Say.both ~ko:"     보존된 실측: 보존 범위에 없음 (한 번도 없었다는 증거는 아님)"
                      ~en:"     Retained evidence: not found in retained coverage (not proof of never)"
                  ]
                 | Masc.Tui_decode_skill_evidence.Skill_evidence_observed ->
                  let activation_lines =
                    let items, tied =
                      match evidence.se_activation with
                      | None -> [], false
                      | Some (Masc.Tui_decode_skill_evidence.Skill_evidence_most_recent_observed item) ->
                        [ item ], false
                      | Some
                          (Masc.Tui_decode_skill_evidence.Skill_evidence_most_recent_observed_timestamp_tie
                             items) ->
                        items, true
                    in
                    List.concat_map
                      (fun item ->
                         let activation = item.Masc.Tui_decode_skill_evidence.sea_activation in
                         let string_field name =
                           match json_assoc_member_opt name activation with
                           | Some (`String value) -> value
                           | _ -> ""
                         in
                         let delivered =
                           match json_assoc_member_opt "delivery" activation with
                           | Some `Null | None -> Say.both ~ko:"호출됨" ~en:"invoked"
                           | Some _ ->
                             Say.code (Masc_tui_value.Mark.glyph Masc_tui_value.Mark.Settled ^ " ")
                             ++ Say.both ~ko:"전달됨" ~en:"delivered"
                         in
                         let action_count =
                           match json_assoc_member_opt "actions" activation with
                           | Some (`List values) -> List.length values
                           | Some _ | None -> 0
                         in
                         let keepers =
                           item.sea_owner_claims
                           |> List.map (fun claim -> claim.Masc.Tui_decode_skill_evidence.seo_keeper)
                           |> String.concat ","
                         in
                         [ Ansi.bold,
                           Say.both ~ko:"     마지막 독립 활성화: " ~en:"     Latest independent activation: "
                           ++ delivered
                           ++ Say.code (Printf.sprintf " · owner=%s(%s) · original-actions=%d · at=%s"
                                (Terminal_text.single_line item.sea_owner_status)
                                (Terminal_text.single_line keepers)
                                action_count
                                (Terminal_text.single_line (string_field "activated_at")))
                         ; Ansi.dim,
                           Say.both ~ko:"       추적 " ~en:"       trace "
                           ++ Say.as_received (Terminal_text.single_line item.sea_trace_id)
                           ++ Say.both ~ko:" · 도구 호출 " ~en:" · tool use "
                           ++ Say.as_received (Terminal_text.single_line (string_field "skill_tool_use_id"))
                           ++ (if tied then Say.both ~ko:" · 같은 시각 후보" ~en:" · equal-time candidate"
                               else Say.empty)
                         ; Ansi.dim,
                           Say.both ~ko:"       원본 " ~en:"       original "
                           ++ Say.code (Printf.sprintf "%s · runtime %s"
                                (Terminal_text.single_line (string_field "turn_ref"))
                                (Terminal_text.single_line (string_field "runtime_id")))
                         ] @ skill_async_evidence_lines item.sea_async_evidence)
                      items
                  in
                  let composition_lines =
                    match evidence.se_composition with
                    | Some (`Assoc _ as composition) ->
                      (match json_assoc_member_opt "result" composition with
                       | Some (`Assoc _ as result) ->
                         let string_field name =
                           match json_assoc_member_opt name composition with
                           | Some (`String value) -> Some (Terminal_text.single_line value)
                           | _ -> None
                         in
                         let or_no_value = function
                           | Some value -> Say.as_received value
                           | None -> Say.code Masc_tui_theme.Glyph.no_value
                         in
                         let or_unavailable = function
                           | Some value -> Say.as_received value
                           | None -> unavailable
                         in
                         let json_or_unavailable name =
                           match json_assoc_member_opt name composition with
                           | Some value -> Say.as_received (Yojson.Safe.to_string value)
                           | None -> unavailable
                         in
                         let duration =
                           match json_assoc_member_opt "duration_ms" result with
                           | Some (`Float value) -> Printf.sprintf "%.0fms" value
                           | Some (`Int value) -> Printf.sprintf "%dms" value
                           | Some _ | None -> Masc_tui_theme.Glyph.no_value
                         in
                         let success =
                           (* Status marks (7.2); deferred is under way, as on
                              the lane run detail. A disposition missing or
                              not taught to this build is unreported (6.4). *)
                           let marked status word =
                             Say.code (Masc_tui_value.Mark.glyph status ^ " ") ++ word in
                           match json_assoc_member_opt "disposition" result with
                           | Some (`String "completed") -> marked Masc_tui_value.Mark.Settled completed_word
                           | Some (`String "deferred") -> marked Masc_tui_value.Mark.Under_way deferred_word
                           | Some (`String "failed") -> marked Masc_tui_value.Mark.Failed failed_word
                           | Some _ | None ->
                             Say.code (Masc_tui_value.Unknown.glyph Masc_tui_value.Unknown.Unreported)
                         in
                         let settlement_count =
                           match
                             json_assoc_member_opt
                               "executor_settlements"
                               composition
                           with
                           | Some (`List values) -> List.length values
                           | Some _ | None -> 0
                         in
                         [ Ansi.bold,
                           Say.code "     Composition: " ++ success
                           ++ Say.code (Printf.sprintf " · %s · keeper=" duration)
                           ++ or_no_value (string_field "keeper")
                           ++ Say.code " · run=" ++ or_no_value (string_field "composition_run_id")
                           ++ Say.code (Printf.sprintf " · settlements=%d" settlement_count)
                         ; Ansi.dim,
                           Say.code "       recorded="
                           ++ (match json_assoc_member_opt "recorded_at" composition with
                               | Some (`Float value) ->
                                 (try Say.as_received (Time_codec.rfc3339_of_unix value) with
                                  | Unix.Unix_error _ | Invalid_argument _ ->
                                    Say.per_language (function
                                      | Say.Ko -> Printf.sprintf "Unix 초 %.3f" value
                                      | Say.En -> Printf.sprintf "%.3f Unix seconds" value))
                               | _ -> unavailable)
                           ++ say_dot ++ or_unavailable (string_field "composition_execution")
                           ++ Say.code " · request="
                           (* Inline evidence carries no request: the server
                              refuses one, and the execution kind is the cell
                              just before. *)
                           ++ Option.fold (string_field "request_id")
                                ~none:(Say.both ~ko:"없음" ~en:"none")
                                ~some:Say.as_received
                         ; Ansi.dim,
                           Say.code "       parent tool use="
                           ++ Say.as_received (Option.value ~default:"" (string_field "parent_tool_use_id"))
                           ++ Say.code " · turn=" ++ json_or_unavailable "parent_turn"
                           ++ Say.code " · planned index=" ++ json_or_unavailable "parent_planned_index"
                         ]
                         @ (match json_assoc_member_opt "disposition" result with
                            | Some (`String "failed") ->
                              let field name = match json_assoc_member_opt name result with
                                | Some (`String value) -> Say.as_received (Terminal_text.single_line value)
                                | _ -> unavailable in
                              [ Theme.bad (), Say.code "       " ++ field "message"
                              ; Ansi.dim, Say.code "       failure class=" ++ field "failure_class"
                                ++ Say.code " · effect evidence=" ++ field "effect_disposition" ]
                            | _ -> [])
                         @ (match json_assoc_member_opt "data" result with
                            | Some output ->
                              (Ansi.bold, Say.both ~ko:"       최종 결과 데이터" ~en:"       Final result data")
                              :: json_rows (cached_skill_json skill_final_result_projection ~cols
                                   ~render:(skill_json_lines ~cols ~indent:9) output)
                            | None -> [Ansi.dim, Say.both ~ko:"       출력 없음" ~en:"       no output"])
                       | Some _ | None ->
                         [ Theme.bad (), Say.both ~ko:"     Composition 실측 형식 오류"
                                           ~en:"     Composition evidence is malformed" ])
                    | None -> []
                    | Some _ ->
                      [ Theme.bad (), Say.both ~ko:"     Composition 실측 형식 오류"
                                        ~en:"     Composition evidence is malformed" ]
                  in
                  activation_lines @ composition_lines
               in
               let coverage_lines =
                 let coverage = evidence.Masc.Tui_decode_skill_evidence.se_coverage in
                 let composition_scope =
                   match coverage.sec_composition_scope with
                   | Masc.Tui_decode_skill_evidence.Skill_evidence_exact_reference_retained_runs ->
                     "retained_runs"
                   | Masc.Tui_decode_skill_evidence.Skill_evidence_composition_unavailable ->
                     "unavailable"
                 in
                 let unavailable =
                   List.map
                     Terminal_text.single_line
                     coverage.sec_composition_unavailable
                 in
                   [ Ansi.dim,
                     Say.both ~ko:"       범위" ~en:"       coverage"
                     ++ Say.code (Printf.sprintf
                       " retained_sessions=%d ledgers=%d activation=%s gaps=%d owner_gaps=%d exact_reference=%s runs_observed=%d"
                       coverage.sec_activation_sessions_inspected
                       coverage.sec_activation_ledgers_loaded
                       coverage.sec_activation_scope
                       coverage.sec_activation_gap_count
                       coverage.sec_activation_owner_gap_count
                       composition_scope
                       coverage.sec_composition_runs_observed)
                   ]
                   @
                   (match unavailable with
                    | [] -> []
                    | values ->
                      [ Theme.warn (),
                        Say.both ~ko:"       composition 조회 불가: " ~en:"       composition unavailable: "
                        ++ Say.as_received (String.concat " · " values)
                      ])
               in
               let statistics_lines = match profile.esp_io with
                 | Masc.Tui_decode_tools.Model_orchestrated -> []
                 | Composition_io _ -> skill_statistics_lines ~cols evidence.se_composition_statistics in
               statistics_lines, skill_run_history_lines state evidence @ evidence_lines
               @ Option.fold ~none:[] ~some:(skill_settlement_lines ~cols) evidence.se_composition
               @ coverage_lines)
             | Some _ | None ->
               rows [ Ansi.dim, Say.both ~ko:"Enter:선택 revision 실측 읽기  f:다음 Composition 실측"
                                  ~en:"Enter:load revision measurements  f:next Composition" ],
               [ Ansi.dim, Say.both ~ko:"     보존 실측  Enter:이 revision 불러오기"
                             ~en:"     Retained evidence  Enter:load this revision" ])
        in
        let performance_card =
          match selected_tools_skill_profile state with
          | None -> []
          | Some profile ->
            let card_body = match profile.esp_io with
              | Masc.Tui_decode_tools.Model_orchestrated ->
                  rows
                    (* f and the keys that walk the list are in section 5
                       of the frame, so the card names no key of its own. *)
                    [ Ansi.dim, Say.both ~ko:"지침 Skill · executor 실행 시간 없음"
                        ~en:"Normal Skill · instructions have no executor run time" ]
              | Composition_io _ -> selected_skill_statistics_lines in
            let pending = match state.tools_evidence_reference, state.tools_evidence_request with
              | Some reference, Some _ when Skill_reference.equal reference profile.esp_reference ->
                  [ Theme.info (), Say.both ~ko:"실측 조회 중 · 이전 관측 유지"
                                     ~en:"Reading measurements · earlier observation retained" ]
              | Some _, Some _ | Some _, None | None, Some _ | None, None -> [] in
            let card_pieces =
              rows
                ((Ansi.bold, Say.both ~ko:"Skill 실측 · " ~en:"Skill performance · "
                             ++ Say.as_received (Terminal_text.single_line profile.esp_name))
                 :: pending)
              @ card_body
            in
            [ Measurement_card (fun language -> skill_usage_box ~cols (draw language card_pieces)) ]
        in
        rows
          [ Ansi.bold,
            surface_title ++ Say.code " · " ++ Say.as_received (Terminal_text.single_line ets_keeper_name)
            ++ Say.code " ("
            ++ Say.per_language (function
                 | Say.Ko -> Printf.sprintf "도구 %d개" (List.length ets_tools)
                 | Say.En -> Masc_tui_message_layout.count_noun (List.length ets_tools) "tool")
            ++ Say.code ")" ]
        @ rows
            ([ delivery_tone, Say.both ~ko:"   Runtime 도구 전달: " ~en:"   Runtime tool delivery: " ++ delivery ]
             @ diagnostics_lines)
        (* The keys that move through this list are in section 5 of the
           frame, so the list carries no hint row of its own. *)
        @ skill_profile_lines
        (* The selected Skill's card stands under the list, with the rest of
           its detail. Above the list it took one row for an instruction
           Skill and about twelve for a Composition with loaded measurements,
           so each j moved every Skill row under it (RFC
           tui-one-screen-grammar section 8). *)
        @ performance_card
        @ rows
          ((match selected_tools_skill_profile state with
             | None -> [] | Some profile -> skill_io_lines ~cols profile.esp_io)
          @ selected_skill_flow_lines
          @ (match state.tools_evidence_reference, state.tools_evidence_request, selected_tools_skill_profile state with
             | Some reference, Some _, Some profile when Skill_reference.equal reference profile.esp_reference ->
                 [Ansi.dim,
                  Say.both ~ko:"     요청한 실행 불러오는 중: " ~en:"     Loading requested run "
                  ++ Option.fold ~none:(Say.both ~ko:"최신" ~en:"latest")
                       ~some:(fun run_id -> Say.as_received (Masc.Keeper_tool_plan.Composition_run_id.to_string run_id))
                       state.tools_evidence_run_id
                  ++ Say.both ~ko:" · 이전 관측 유지" ~en:" · previous observation retained"]
             | _ -> [])
          @ selected_skill_evidence_lines
          (* Said on this surface because this is the one that answers "what can
             this Keeper call". A document the catalog could not read is absent
             from that answer, and absence with nothing beside it reads as a
             skill nobody wrote rather than one that did not load. Drawn only
             when there is one, so a healthy workspace gains no row. *)
          @ (match ets_skills_left_out with
             | [] -> []
             | left_out ->
               ( (Theme.warn ()),
                 Say.per_language (function
                   | Say.Ko -> Printf.sprintf "   catalog 에서 빠진 Skill %d개" (List.length left_out)
                   | Say.En -> Printf.sprintf "   %d skill(s) left out of the catalog" (List.length left_out)) )
               :: List.map
                    (fun entry ->
                      (Theme.warn ()),
                      Say.code "     " ++ Say.as_received (Terminal_text.single_line entry))
                    left_out)
          (* A configured name the turn catalog does not hold is a different
             fact from a document that failed to read: the operator selected a
             Skill that is not there. The dashboard says it under "Unavailable
             Skills"; without these rows this screen answered "what can this
             Keeper call" while staying silent about a selection that did
             nothing. Drawn only when there is one. *)
          @ (match ets_unavailable_skill_names with
             | [] -> []
             | unavailable ->
               ( (Theme.warn ()),
                 Say.per_language (function
                   | Say.Ko -> Printf.sprintf "   턴 catalog 에 없는 설정 Skill 이름 %d개" (List.length unavailable)
                   | Say.En -> Printf.sprintf "   %d configured skill name(s) not in the turn catalog"
                       (List.length unavailable)) )
               :: List.map
                    (fun { Masc.Tui_decode_tools.csn_name; csn_reason } ->
                      (Theme.warn ()),
                      Say.code "     "
                      ++ Say.as_received (Terminal_text.single_line csn_name)
                      ++ say_dot
                      ++ Say.as_received (Terminal_text.single_line csn_reason))
                    unavailable)
          @ [ Ansi.bold, Tool_table.effective_tool_header ]
          @ tool_lines)
    end
  in
  let activation_reading_lines =
    lazy begin
    let log_title = Say.both ~ko:" Skill 기록" ~en:" Skill Activations" in
    let safe value = Say.as_received (Terminal_text.single_line value) in
    match state.tools_activations with
    | None ->
        (match state.tools_activations_error with
         | None -> [ Theme.warn (), log_title ++ Say.both ~ko:" · 미조회" ~en:" · not loaded" ]
         | Some _ ->
           [ Theme.warn (), log_title ++ Say.both ~ko:" · 조회 불가 (읽은 것 없음)" ~en:" · unavailable (no reading)" ])
    | Some Masc_tui_types.Activations_no_keeper ->
        [ Theme.warn (), log_title ++ Say.both ~ko:" · 고른 Keeper 없음" ~en:" · no Keeper selected" ]
    | Some
        (Masc_tui_types.Activations_read
           (Masc.Tui_decode_tools.Skill_activations_no_session
              { sap_keeper_name })) ->
        [ Theme.warn (),
          log_title ++ Say.code " · " ++ safe sap_keeper_name
          ++ Say.both ~ko:" · 세션 없음" ~en:" · no session" ]
    | Some
        (Masc_tui_types.Activations_read
           (Masc.Tui_decode_tools.Skill_activations_unavailable
              { sap_keeper_name; sap_reason; sap_detail })) ->
        [ Theme.bad (),
          log_title ++ Say.code " · " ++ safe sap_keeper_name
          ++ Say.both ~ko:" · 조회 불가 (" ~en:" · unavailable (" ++ safe sap_reason ++ Say.code ")";
          Theme.bad (), Say.code "   " ++ safe sap_detail ]
    | Some
        (Masc_tui_types.Activations_read
           (Masc.Tui_decode_tools.Skill_activations_available
              { sap_keeper_name
              ; sap_ledger
              })) ->
        let sap_activations =
          Masc.Keeper_skill_activation_ledger.activations sap_ledger
        in
        let summary =
          Masc.Keeper_skill_activation_ledger.summarize sap_ledger
        in
        let scoped_summaries =
          Masc.Keeper_skill_activation_ledger.summarize_by_scope sap_ledger
        in
        (* One kind's three counts after a label padded to [cells]. *)
        let counts_row ~cells kind invoked delivered handoffs actions =
          Say.map (pad_cells cells) kind ++ Say.code " "
          ++ Say.per_language (function
               | Say.Ko -> Printf.sprintf "호출 %d \xc2\xb7 전달 %d \xc2\xb7 넘김 %d \xc2\xb7 동작 %d"
                   invoked delivered handoffs actions
               | Say.En -> Printf.sprintf "triggered %d \xc2\xb7 delivered %d \xc2\xb7 handed off %d \xc2\xb7 actions %d"
                   invoked delivered handoffs actions)
        in
        let instruction_kind = Say.both ~ko:"지침" ~en:"instruction" in
        let composition_kind = Say.code "composition" in
        let served_row ~bodies ~resources =
          Say.per_language (function
            | Say.Ko -> Printf.sprintf "본문 %d개 \xc2\xb7 resource %d개 제공" bodies resources
            | Say.En -> Printf.sprintf "served %d bodies \xc2\xb7 %d resources" bodies resources)
        in
        let invalid_row count =
          Say.per_language (function
            | Say.Ko -> Printf.sprintf "잘못된 전이 %d개" count
            | Say.En -> Printf.sprintf "%d invalid transition(s)" count)
        in
        let scoped_lines =
          List.concat_map
            (fun (scoped : Masc.Keeper_skill_activation_ledger.scoped_summary) ->
               let scoped_summary = scoped.summary in
               let runtime_counts values =
                 match values with
                 | [] -> Say.both ~ko:"없음" ~en:"none"
                 | values ->
                   values
                   |> List.map
                        (fun (item : Masc.Keeper_skill_activation_ledger.runtime_count) ->
                           Printf.sprintf "%s:%d" item.runtime_id item.count)
                   |> String.concat ","
                   |> Say.as_received
               in
               (* The scope, in the parts a reader uses: which skill
                  revision, in which turn, on which runtime. The JSON
                  encoding of the same reference stood above these rows and
                  said each of them a second time, in braces. *)
               let name =
                 Terminal_text.single_line scoped.scope.reference.identity.name
               in
               let package =
                 Terminal_text.single_line
                   (Skill_reference.identity_package_id_to_string
                      scoped.scope.reference.identity)
               in
               [ Ansi.dim,
                 Say.code "   " ++ Say.as_received name
                 (* A skill is usually named after the package that holds
                    it, and "work-intake · work-intake" says it twice. *)
                 ++ (if String.equal name package then Say.empty
                     else say_dot ++ Say.as_received package)
                 ++ Say.code " \xc2\xb7 rev "
                 ++ safe (Skill_reference.content_revision_to_string
                            scoped.scope.reference.content_revision)
               ; Ansi.dim,
                 Say.both ~ko:"     턴 " ~en:"     turn "
                 ++ safe (Ids.Turn_ref.to_string scoped.scope.turn_ref)
                 ++ say_dot ++ safe scoped.scope.invocation_runtime_id
                 ++ Say.code " \xc2\xb7 snapshot "
                 ++ safe (Skill_catalog_snapshot.snapshot_revision_to_string
                            scoped.scope.snapshot_revision)
               ]
               (* What the scope amounts to: how many times it was
                  triggered, how many of those were delivered, and what the
                  model did after. Instruction and composition are two
                  columns of the same three counts rather than one row of
                  ten [key=value] pairs. Zero rows are left out: a
                  composition's counts on a scope that is an instruction are
                  four zeros saying nothing happened in a kind this scope is
                  not. *)
               @ List.filter_map
                   (fun (kind, invoked, delivered, handoffs, actions) ->
                     if invoked = 0 && delivered = 0 && handoffs = 0 && actions = 0
                     then None
                     else
                       Some
                         ( Ansi.dim
                         , Say.code "     " ++ counts_row ~cells:11 kind invoked delivered handoffs actions ))
                   [ ( instruction_kind
                     , scoped_summary.instruction_invocations
                     , scoped_summary.instruction_provider_deliveries
                     , scoped_summary.instruction_official_client_handoffs
                     , scoped_summary.instruction_actions_observed )
                   ; ( composition_kind
                     , scoped_summary.composition_invocations
                     , scoped_summary.composition_provider_deliveries
                     , scoped_summary.composition_official_client_handoffs
                     , scoped_summary.composition_actions_observed )
                   ]
               (* Bodies and resources are what a trigger served; invalid
                  transitions are the ledger refusing what it was told.
                  Both are zero on a healthy scope and are drawn only when
                  they are not. *)
               @ (if scoped_summary.skill_bodies_served = 0
                     && scoped_summary.skill_resources_served = 0
                  then []
                  else
                    [ ( Ansi.dim
                      , Say.code "     "
                        ++ served_row ~bodies:scoped_summary.skill_bodies_served
                             ~resources:scoped_summary.skill_resources_served )
                    ])
               @ (if scoped_summary.invalid_transitions = 0 then []
                  else
                    [ ( Theme.warn ()
                      , Say.code "     " ++ invalid_row scoped_summary.invalid_transitions )
                    ])
               @ (let runtimes =
                    List.filter
                      (fun (_, counts) -> counts <> [])
                      [ Say.both ~ko:"전달" ~en:"delivered", scoped.provider_delivery_runtime_counts
                      ; Say.both ~ko:"넘김" ~en:"handed off", scoped.official_client_handoff_runtime_counts
                      ; Say.both ~ko:"동작" ~en:"actions", scoped.action_runtime_counts
                      ]
                  in
                  match runtimes with
                  | [] -> []
                  | runtimes ->
                      [ ( Ansi.dim
                        , Say.both ~ko:"     runtime 별 \xc2\xb7 " ~en:"     runtimes \xc2\xb7 "
                          ++ Say.concat ~sep:say_dot
                               (List.map
                                  (fun (label, counts) -> label ++ Say.code " " ++ runtime_counts counts)
                                  runtimes) )
                      ]))
            scoped_summaries
        in
        let receipt_lines =
          List.concat_map
            (fun (activation : Masc.Keeper_skill_activation_ledger.activation) ->
               let origin, served = skill_invocation_text activation.invocation in
               (* The receipt in the ledger's own field names, which a reader
                  matches against the ledger file. *)
               [ Ansi.dim,
                 Say.both ~ko:"   시작" ~en:"   begin" ++ Say.code " id=" ++ safe activation.skill_tool_use_id
               ; Ansi.dim,
                 Say.code "   receipt_sha256="
                 ++ Say.as_received
                      (Masc.Keeper_skill_activation_ledger.receipt_projection_revision
                         sap_ledger
                         ~skill_tool_use_id:activation.skill_tool_use_id)
               ; Ansi.dim,
                 Say.both ~ko:"   정확한" ~en:"   exact" ++ Say.code " source_id="
                 ++ safe (Skill_reference.identity_source_id_to_string activation.identity)
               ; Ansi.dim,
                 Say.code "     package_id="
                 ++ safe (Skill_reference.identity_package_id_to_string activation.identity)
               ; Ansi.dim,
                 Say.code "     name=" ++ safe activation.identity.name
               ; Ansi.dim,
                 Say.code "     content_revision="
                 ++ safe (Skill_reference.content_revision_to_string activation.content_revision)
               ; Ansi.dim,
                 Say.both ~ko:"     호출" ~en:"     invoked"
                 ++ Say.code (Printf.sprintf
                   " turn=%d id=%s runtime=%s at=%s"
                   activation.agent_core_turn
                   (Terminal_text.single_line activation.skill_tool_use_id)
                   (Terminal_text.single_line activation.runtime_id)
                   (Terminal_text.single_line activation.activated_at))
               ; Ansi.dim,
                 Say.both ~ko:"       제공 " ~en:"       served " ++ Say.map Terminal_text.single_line served
               ; Ansi.dim,
                 Say.both ~ko:"       전달 " ~en:"       delivered "
                 ++ Say.map Terminal_text.single_line
                      (skill_delivery_text
                         ~has_action:(not (List.is_empty activation.actions))
                         activation.delivery)
               ; Ansi.dim,
                 Say.code (Printf.sprintf "       snapshot=%s keeper_turn=%s origin="
                   (Skill_catalog_snapshot.snapshot_revision_to_string
                      activation.snapshot_revision
                    |> Terminal_text.single_line)
                   (Ids.Turn_ref.to_string activation.turn_ref
                    |> Terminal_text.single_line))
                 ++ Say.map Terminal_text.single_line origin
               ]
               @ skill_action_lines activation.actions
               @ [ Ansi.dim,
                   Say.both ~ko:"       끝" ~en:"       end" ++ Say.code " id=" ++ safe activation.skill_tool_use_id
                 ])
            sap_activations
        in
        let timeline_lines =
          (* Newest-first event stream over the loaded ledger: one line per
             delivery or observed action, so "what just ran" reads top-down
             without walking per-activation receipts. Row clocks go through
             the shared [Terminal_text.clock_timestamp]: slicing HH:MM:SS
             out of the RFC 3339 string would draw a UTC clock under a
             header in the terminal's zone (nine hours apart in Seoul). *)
          let time_of ts = Terminal_text.clock_timestamp ts in
          let event_kind = Say.map (pad_cells 9) in
          let events =
            List.concat_map
              (fun (activation :
                     Masc.Keeper_skill_activation_ledger.activation) ->
                 let skill =
                  Terminal_text.single_line activation.identity.name
                 in
                 (match activation.delivery with
                  | Some delivery ->
                    [ ( delivery.delivered_at,
                        Say.code (Printf.sprintf "%-*s " Terminal_text.clock_timestamp_cells (time_of delivery.delivered_at))
                        ++ event_kind (Say.both ~ko:"전달" ~en:"delivery")
                        ++ Say.code
                             (Printf.sprintf
                                (* The same unit the Context inspector reads sizes
                                   in, an estimated token figure, beside the bytes
                                   it was read from: this screen has no turn
                                   record to take a scale from, and the timeline
                                   header says it reads at the fleet figure. *)
                                " %-20s \xe2\x89\x88%6s tok %9s turn#%d %s"
                                skill
                                (Masc_tui_context_inspector.format_tokens
                                   (Masc_tui_token_scale.estimate
                                      Masc_tui_token_scale.fleet
                                      delivery.content_bytes))
                                (Masc_tui_context_inspector.format_bytes
                                   delivery.content_bytes)
                                activation.agent_core_turn
                                (Terminal_text.single_line delivery.runtime_id)) ) ]
                  | None -> [])
                 @ List.map
                     (fun (act :
                             Masc.Keeper_skill_activation_ledger.action) ->
                        ( act.observed_at,
                          Say.code (Printf.sprintf "%-*s " Terminal_text.clock_timestamp_cells (time_of act.observed_at))
                          ++ event_kind (Say.both ~ko:"동작" ~en:"action")
                          ++ Say.code
                               (Printf.sprintf " %-20s turn#%d %s"
                                  (Terminal_text.single_line
                                     (Masc.Tool_display.list_label act.tool_name))
                                  act.agent_core_turn
                                  (Terminal_text.single_line act.runtime_id)) ))
                     activation.actions)
              sap_activations
            |> List.sort (fun (left, _) (right, _) ->
                   String.compare right left)
          in
          let total = List.length events in
          let capped =
            List.filteri (fun index _ -> index < skill_timeline_display_cap) events
          in
          [ Ansi.bold,
            Say.per_language (function
              | Say.Ko -> Printf.sprintf " Skill 타임라인 · 사건 %d개 (최신부터)" total
              | Say.En -> Printf.sprintf " Skill Timeline · %d event%s (newest first)"
                  total (if total = 1 then "" else "s"))
          (* Masc_tui_token_scale writes this note in English for every screen
             that estimates tokens; it moves with the Context inspector. *)
          ; Ansi.dim, Say.code "   " ++ Say.as_received (Masc_tui_token_scale.note Masc_tui_token_scale.fleet) ]
          @ List.map (fun (_, line) -> (Ansi.dim, Say.code "   " ++ line)) capped
        in
        [ Ansi.bold,
          Say.both ~ko:" Skill 사용 · " ~en:" Skill Use · " ++ safe sap_keeper_name
          ++ Say.per_language (function
               | Say.Ko -> Printf.sprintf " (영수증 %d개)" (List.length sap_activations)
               | Say.En -> Printf.sprintf " (%d receipts)" (List.length sap_activations))
        ; Ansi.dim,
          Say.code "   " ++ Say.map (pad_cells 13) (Say.both ~ko:"이 세션" ~en:"this session")
          ++ Say.code "\xc2\xb7 "
          ++ counts_row ~cells:11 instruction_kind
               summary.instruction_invocations
               summary.instruction_provider_deliveries
               summary.instruction_official_client_handoffs
               summary.instruction_actions_observed
        ; Ansi.dim,
          Say.code "                "
          ++ counts_row ~cells:11 composition_kind
               summary.composition_invocations
               summary.composition_provider_deliveries
               summary.composition_official_client_handoffs
               summary.composition_actions_observed
        ; Ansi.dim,
          Say.code "                "
          ++ served_row ~bodies:summary.skill_bodies_served ~resources:summary.skill_resources_served
        ; Ansi.dim,
          Say.code (Printf.sprintf "   session=%s  ledger=%s"
            (Masc.Keeper_skill_activation_ledger.session_id sap_ledger
             |> Keeper_id.Trace_id.to_string
             |> Terminal_text.single_line)
            (Masc.Keeper_skill_activation_ledger.revision sap_ledger
             |> Masc.Keeper_skill_activation_ledger.ledger_revision_to_string
             |> Terminal_text.single_line))
        ; Ansi.dim,
          Say.code "   workspace="
          ++ safe (Masc.Keeper_skill_activation_ledger.workspace_key sap_ledger)
        ]
        @ (if summary.invalid_transitions = 0 then []
           else
             [ ( Theme.warn ()
               , Say.code "                " ++ invalid_row summary.invalid_transitions )
             ])
        @ timeline_lines
        @ scoped_lines
        @ receipt_lines
    end
  in
  (* The Activations pane has its own read, so its failure is drawn here;
     [error_lines] below speaks for the tool inventory. *)
  let activation_lines =
    lazy begin
      rows
        ((match state.tools_activations_error with
          | None -> []
          | Some { taf_detail = Request_failed taf_detail; _ } ->
              [ Theme.bad (),
                Say.both ~ko:" Skill 기록 조회 실패: " ~en:" Skill activations read failed: "
                ++ Say.as_received (Terminal_text.single_line taf_detail) ]
          | Some { taf_detail = Request_withdrawn refusal; _ } ->
              [ Theme.bad (), Say.code " " ++ refusal_text ~request:Kept_request.Skill_activations_read refusal ])
         @ Lazy.force activation_reading_lines)
    end
  in
  let catalog_lines =
    lazy begin
    match state.tools_inventory with
    | None ->
        rows
          [ Theme.warn (),
            Say.both ~ko:" 전체 등록 도구 · 조회 자료 없음" ~en:" All registered tools · no inventory reading" ]
    | Some { Masc.Tui_decode_tools.ts_usage; _ } ->
    let registered_rows = Tool_tree.rows registered_tools in
    let surfaces_text (tool : Masc.Tui_decode_tools.tool_entry) =
      match tool.tl_surfaces with
      | [] -> Say.both ~ko:"없음" ~en:"none"
      | names -> Say.as_received (Terminal_text.single_line (String.concat ", " names))
    in
    (* The SURFACES column is as wide as its widest reading, so the layout is
       decided once the language is chosen. *)
    let catalog_rows language =
      let layout =
        Tool_table.catalog_layout ~language ~width:(Masc_tui_frame.inner_width ~cols)
          ~surfaces_cells:
            (List.fold_left
               (fun widest tool ->
                 max widest
                   (Masc_tui_message_layout.display_width (Say.render language (surfaces_text tool))))
               0 registered_tools)
      in
      (* A tool the server has no row for was not called; with no per-tool
         counts at all, nothing is known about any tool. *)
      let usage_of name =
        match ts_usage with
        | None -> Tool_table.Usage_unread
        | Some rows -> (
            match Masc.Tui_decode_tools.tool_usage_for rows ~name with
            | None -> Tool_table.Never_called
            | Some { Masc.Tui_decode_tools.tu_calls; tu_failures; tu_p95_ms; _ } ->
                Tool_table.Called
                  { calls = tu_calls; failures = tu_failures; p95_ms = tu_p95_ms })
      in
      let count = List.length registered_tools in
      [ Row (Ansi.bold,
             Say.per_language (function
               | Say.Ko -> Printf.sprintf " 전체 등록 도구 · %d개" count
               | Say.En -> Printf.sprintf " All registered tools · %s"
                   (Masc_tui_message_layout.count_noun count "tool")));
        Row (Ansi.dim, Tool_table.catalog_tool_header layout) ]
      @ List.map
          (function
            | Tool_tree.Domain { name; count } ->
                Row ( Ansi.bold,
                  Say.code " " ++ Say.as_received (Terminal_text.single_line name)
                  ++ Say.code (Printf.sprintf " (%d) %s" count tool_domain_rule) )
            | Tool_tree.Family { name; count } ->
                Row (Ansi.bold,
                  Say.code "    " ++ Say.as_received (Terminal_text.single_line name)
                  ++ Say.code (Printf.sprintf " (%d)" count))
            | Tool_tree.Tool tool ->
                (* The name is what an operator scans a hundred rows for, so it
                   keeps the terminal's own weight and the two columns that
                   answer about it are dimmed behind it. Dimming the whole row --
                   as this did -- left the headings above in bold and every tool
                   name on the screen as the faintest thing on it.

                   A tool on no surface is unreachable, and [Surfaces] is the
                   column that says so, so the warning starts there instead of
                   recolouring the name, which is not itself the problem. *)
                let metadata =
                  if tool.tl_surfaces = [] then (Theme.warn ()) else Ansi.dim
                in
                Row ( "",
                  Tool_table.catalog_tool_line layout ~metadata
                    ~name:(Terminal_text.single_line (Masc.Tool_display.list_label tool.tl_name))
                    ~direct:(if tool.tl_direct_call
                             then Say.both ~ko:"예" ~en:"yes" else Say.both ~ko:"아니오" ~en:"no")
                    ~usage:(usage_of tool.tl_name)
                    ~surfaces:(surfaces_text tool) ))
          registered_rows
    in
    [ Laid_out (fun language -> draw language (catalog_rows language)) ]
    end
  in
  let usage_matrix_lines =
    lazy begin
    let usage_title = Say.both ~ko:" Skill 사용 집계" ~en:" Skill Usage" in
    let error_lines =
      match state.skills_catalog_error with
      | None -> []
      | Some error ->
          [ Theme.bad (), Say.code " "
              ++ Say.of_ko_flag (fun ~ko -> Terminal_text.single_line
                   (request_failure_text ~ko ~request:Kept_request.Skill_catalog_read error)) ]
          @ (match state.skills_catalog with
             | None -> []
             | Some _ -> [ Theme.warn (), Say.both ~ko:" 이전 catalog 조회 결과 유지" ~en:" Previous catalog reading retained" ])
    in
    let reading_lines =
    match state.skills_catalog with
    | None ->
        rows
          [ Ansi.dim,
            usage_title
            ++ (match state.skills_catalog_error with
                | None -> Say.both ~ko:" · 작업 공간 catalog 조회 없음" ~en:" · no workspace catalog reading"
                | Some _ -> Say.both ~ko:" · 조회 불가 (catalog 조회 없음)" ~en:" · unavailable (no catalog reading)") ]
    | Some { Masc.Tui_decode_tools.sc_state; _ }
      when sc_state <> Masc.Tui_decode_tools.Skills_ready ->
        rows
          [ Ansi.dim,
            usage_title ++ Say.code " · catalog "
            ++ Say.as_received (Terminal_text.single_line
                 (Masc.Tui_decode_tools.skills_catalog_state_to_string sc_state)) ]
    | Some
        { Masc.Tui_decode_tools.sc_surfaces
        ; sc_rejections
        ; sc_shadows
        ; sc_sources
        ; sc_config
        ; _
        }
      ->
        (* Each Keeper's answer is its own read (RFC-0483). A failed read
           keeps the Keeper's last answer, so its counts stay in the totals. *)
        let answered_rows =
          List.concat_map
            (fun (keeper, reading) ->
               match Masc_tui_types.skill_usage_answer reading with
               | Some (Masc.Tui_decode_tools.Keeper_usage_ready rows) ->
                 List.map (fun row -> keeper, row) rows
               | Some
                   ( Masc.Tui_decode_tools.Keeper_usage_no_session
                   | Masc.Tui_decode_tools.Keeper_usage_unavailable _
                   | Masc.Tui_decode_tools.Keeper_usage_no_catalog )
               | None -> [])
            state.tools_keeper_usage
        in
        let names_surface (surface : Masc.Tui_decode_tools.skills_catalog_surface)
            ((_ : string), (row : Masc.Tui_decode_tools.keeper_skill_usage_row)) =
          Skill_reference.equal row.ksu_reference surface.scs_reference
        in
        (* One surface's usage: a row for each Keeper whose ledger used its
           exact revision, in Keeper name order. *)
        let usage_of surface = List.filter (names_surface surface) answered_rows in
        (* A Keeper answered against a catalog this reading does not hold, so
           its row names a revision outside it. Such a row is drawn on its
           own. *)
        let outside =
          List.filter
            (fun usage -> not (List.exists (fun surface -> names_surface surface usage) sc_surfaces))
            answered_rows
        in
        let used =
          List.filter_map
            (fun surface ->
               match usage_of surface with
               | [] -> None
               | usage -> Some (surface, usage))
            sc_surfaces
        in
        let total field usage =
          List.fold_left
            (fun sum (_, (row : Masc.Tui_decode_tools.keeper_skill_usage_row)) -> sum + field row)
            0 usage
        in
        let invocations usage =
          total (fun (row : Masc.Tui_decode_tools.keeper_skill_usage_row) -> row.ksu_invocations) usage
        in
        let deliveries usage =
          total (fun (row : Masc.Tui_decode_tools.keeper_skill_usage_row) -> row.ksu_deliveries) usage
        in
        let actions usage =
          total (fun (row : Masc.Tui_decode_tools.keeper_skill_usage_row) -> row.ksu_actions) usage
        in
        let surface_name (surface : Masc.Tui_decode_tools.skills_catalog_surface) =
          Skill_reference.(surface.scs_reference.identity.name)
        in
        let compare_surface ((a : Masc.Tui_decode_tools.skills_catalog_surface), a_usage)
            ((b : Masc.Tui_decode_tools.skills_catalog_surface), b_usage) =
          let count = Int.compare (invocations b_usage) (invocations a_usage) in
          if count <> 0 then count else
          let name = String.compare (surface_name a) (surface_name b) in
          if name <> 0 then name else String.compare a.scs_kind b.scs_kind
        in
        let used = List.stable_sort compare_surface used in
        let all_usage = List.concat_map snd used @ outside in
        let keepers = all_usage |> List.map fst |> List.sort_uniq String.compare |> List.length in
        (* Per Keeper: whether its answer is counted, whether it comes from an
           earlier read, and what the operator needs to know about it. A
           Keeper with no answer at all is not counted. *)
        let ledgers_read, earlier, excluded, notes =
          List.fold_left
            (fun (read, earlier, excluded, notes) (keeper, reading) ->
               let failure, answer =
                 match reading with
                 | Masc_tui_types.Skill_usage_read answer -> None, Some answer
                 | Masc_tui_types.Skill_usage_read_failed { last; detail } -> Some detail, last
               in
               let counted, left_out, answer_note =
                 match answer with
                 | Some
                     ( Masc.Tui_decode_tools.Keeper_usage_ready _
                     | Masc.Tui_decode_tools.Keeper_usage_no_catalog ) ->
                   true, false, None
                 | Some Masc.Tui_decode_tools.Keeper_usage_no_session -> false, false, None
                 | Some (Masc.Tui_decode_tools.Keeper_usage_unavailable { kua_reason; kua_detail }) ->
                   false, true, Some (Say.as_received (Printf.sprintf "%s (%s)" kua_reason kua_detail))
                 | None -> false, true, None
               in
               let keeper_text = Say.as_received keeper in
               let refusal refusal = refusal_text ~request:Kept_request.Skill_usage_read refusal in
               let earlier_answer note = Say.both ~ko:" · 이전 답: " ~en:"; earlier answer: " ++ note in
               let note =
                 match failure, answer_note with
                 | None, None -> None
                 | None, Some note ->
                   Some (Say.both ~ko:"조회 불가: " ~en:"Unavailable: " ++ keeper_text ++ Say.code ": " ++ note)
                 (* A read the workspace guard stopped is its kept-back
                    notice, named by the Keeper after it (RFC §2). *)
                 | Some (Request_withdrawn withdrawn), None ->
                   Some (refusal withdrawn ++ say_dot ++ keeper_text)
                 | Some (Request_withdrawn withdrawn), Some note ->
                   Some (refusal withdrawn ++ say_dot ++ keeper_text ++ earlier_answer note)
                 | Some (Request_failed detail), None when counted ->
                   Some (Say.both ~ko:"조회 실패 · 수는 이전 답에서: " ~en:"Read failed, counts from the earlier answer: "
                         ++ keeper_text ++ Say.code ": " ++ Say.as_received detail)
                 | Some (Request_failed detail), None ->
                   Some (Say.both ~ko:"조회 실패: " ~en:"Read failed: " ++ keeper_text ++ Say.code ": "
                         ++ Say.as_received detail)
                 | Some (Request_failed detail), Some note ->
                   Some (Say.both ~ko:"조회 실패: " ~en:"Read failed: " ++ keeper_text ++ Say.code ": "
                         ++ Say.as_received detail ++ earlier_answer note)
               in
               ( (if counted then read + 1 else read)
               , (if counted && Option.is_some failure then earlier + 1 else earlier)
               , (if left_out then excluded + 1 else excluded)
               , match note with
                 | None -> notes
                 | Some note -> note :: notes ))
            (0, 0, 0, []) state.tools_keeper_usage
        in
        let notes = List.rev notes in
        let counts_text ~invocations ~deliveries ~actions =
          Say.per_language (function
            | Say.Ko -> Printf.sprintf "호출 %d · 전달 %d · 동작 %d" invocations deliveries actions
            | Say.En -> Printf.sprintf "Triggered %d · Delivered %d · Actions %d" invocations deliveries actions)
        in
        let coverage_lines =
          match state.keepers, state.tools_keeper_usage with
          | [], [] ->
              if Masc_tui_types.roster_complete state
              then [ Ansi.dim, Say.both ~ko:"명단에 Keeper 없음." ~en:"No Keepers in the roster." ]
              else []
          | _ :: _, [] ->
            [ Theme.warn (), Say.both ~ko:"활성화 장부 범위: 아직 안 읽음 · 합계가 일부일 수 있음."
                               ~en:"Activation ledger coverage: not read yet; totals may be partial." ]
          | ([] | _ :: _), _ :: _ ->
              ( Ansi.dim,
                Say.per_language (function
                  | Say.Ko -> Printf.sprintf "읽은 활성화 장부 %d · 조회 불가 %d%s" ledgers_read excluded
                      (if earlier > 0 then Printf.sprintf " · 이전 조회에서 %d" earlier else "")
                  | Say.En -> Printf.sprintf "Activation ledgers loaded: %d; unavailable: %d%s" ledgers_read excluded
                      (if earlier > 0 then Printf.sprintf "; %d from an earlier read" earlier else "")) )
              :: (if excluded > 0
                  then [Theme.warn (), Say.both ~ko:"일부 합계: 조회 불가 장부는 빠짐."
                                         ~en:"Partial totals: unavailable ledgers are excluded."]
                  else [])
              @ (if earlier > 0
                 then [Theme.warn (), Say.both ~ko:"일부 합계는 이전 조회에서 옴."
                                        ~en:"Some totals come from an earlier read."]
                 else [])
        in
        (* The ledgers read are the roster's Keepers; a roster not read yet,
           or read with an error, may list only some of them. *)
        let roster_lines =
          match state.keepers_error, state.local_keepers with
          | Some detail, (Local_workspace_unread | Local_workspace_read | Local_workspace_failed _)
          | None, Local_workspace_failed detail ->
              [ Theme.warn (),
                Say.both ~ko:"Keeper 명단 조회 실패: " ~en:"Keeper roster read failed: "
                ++ Say.as_received (Terminal_text.single_line detail)
                ++ Say.both ~ko:" · 합계는 나열된 Keeper 만 셈." ~en:"; totals cover only the Keepers listed." ]
          | None, Local_workspace_unread ->
            [ Ansi.dim, Say.both ~ko:"Keeper 명단 아직 안 읽음." ~en:"Keeper roster not read yet." ]
          | None, Local_workspace_read -> []
        in
        let heading = card ~cols (rows
          ([ Ansi.bold,
             Say.per_language (function
               | Say.Ko -> Printf.sprintf "Skill 사용 집계 · catalog Skill %d개 중 %d개 관측"
                   (List.length sc_surfaces) (List.length used)
               | Say.En -> Printf.sprintf "Skill Usage · %d of %d catalog Skills observed"
                   (List.length used) (List.length sc_surfaces))
           ; Theme.info (),
             Say.per_language (function
               | Say.Ko -> Printf.sprintf "Keeper %d · " keepers
               | Say.En -> Printf.sprintf "Keepers %d · " keepers)
             ++ counts_text ~invocations:(invocations all_usage) ~deliveries:(deliveries all_usage)
                  ~actions:(actions all_usage)
           ; Ansi.dim, Say.both ~ko:"범위: 지금 Keeper 세션의 정확한 Skill revision · 전달에는 비동기 넘김 포함"
                         ~en:"Scope: exact Skill revisions in current Keeper sessions · deliveries include async handoffs"
           ; Ansi.dim, Say.both ~ko:"동작: Skill 호출마다 셈 · 호출 여럿이 도구 호출 하나를 나눌 수 있음"
                         ~en:"Actions: counted per Skill invocation; several invocations may share one tool call"
           ; Ansi.dim,
             Say.per_language (function
               | Say.Ko -> Printf.sprintf "보존된 호출이 없는 것 %d개 · 한 번도 안 썼다는 뜻은 아님."
                   (List.length sc_surfaces - List.length used)
               | Say.En -> Printf.sprintf "%d without retained invocation; this does not establish never used."
                   (List.length sc_surfaces - List.length used))
           ] @ coverage_lines @ roster_lines))
        in
        let surface_cards = List.map
          (fun ((surface : Masc.Tui_decode_tools.skills_catalog_surface), usage) ->
            let keeper_readings = usage
              |> List.map (fun (keeper, (row : Masc.Tui_decode_tools.keeper_skill_usage_row)) ->
                  let last_used = Terminal_text.single_line row.ksu_last_used_at in
                  let line = Tool_table.skill_usage_keeper_line
                    ~keeper:(Terminal_text.single_line keeper)
                    ~invocations:row.ksu_invocations ~deliveries:row.ksu_deliveries
                    ~actions:row.ksu_actions ~last_used in
                  (keeper, row), last_used, line)
            in
            (* The keepers are a table only when the header and every row fit
               the card, which depends on the words: decided once the language
               is chosen. *)
            let keeper_rows language =
              let fits line = Masc_tui_message_layout.display_width (Say.render language line)
                <= Masc_tui_frame.inner_width ~cols - 4 in
              let table_mode = fits Tool_table.skill_usage_keeper_header
                && List.for_all (fun (_, _, line) -> fits line) keeper_readings in
              (if table_mode then [Ansi.dim, Tool_table.skill_usage_keeper_header] else [])
              @ List.concat_map
                  (fun ((keeper, (row : Masc.Tui_decode_tools.keeper_skill_usage_row)), last_used, line) ->
                      if table_mode then [Ansi.dim, line]
                      else [ Ansi.bold, Say.as_received (Terminal_text.single_line keeper)
                           ; Ansi.dim, counts_text ~invocations:row.ksu_invocations
                                         ~deliveries:row.ksu_deliveries ~actions:row.ksu_actions
                           ; Ansi.dim, Say.both ~ko:"마지막 사용 " ~en:"Last used " ++ Say.as_received last_used ])
                  keeper_readings
            in
            let flow_rows = match surface.scs_flow with
              | None -> []
              | Some flow ->
                  (match skill_flow_line flow with
                   | None -> [] | Some line -> [Ansi.dim, line])
                  @ skill_flow_detail_lines flow in
            card ~cols
              (rows
                 [ Ansi.bold, Say.as_received (Terminal_text.single_line (surface_name surface))
                     ++ Say.code "  " ++ Say.as_received (Terminal_text.single_line surface.scs_kind)
                 ; Theme.info (), counts_text ~invocations:(invocations usage)
                     ~deliveries:(deliveries usage) ~actions:(actions usage)
                 ]
               @ [ Laid_out (fun language -> draw language (rows (keeper_rows language))) ]
               @ rows flow_rows)) used
        in
        let outside_rows =
          match outside with
          | [] -> []
          | _ :: _ ->
              [ card ~cols (rows
                ((( Ansi.bold,
                    Say.per_language (function
                      | Say.Ko -> Printf.sprintf "이 catalog 조회 밖의 사용 기록 · %d" (List.length outside)
                      | Say.En -> Printf.sprintf "Usage rows outside this catalog reading · %d" (List.length outside)) )
                  :: List.concat_map
                       (fun (keeper, (row : Masc.Tui_decode_tools.keeper_skill_usage_row)) ->
                          [ ( Ansi.bold,
                              Say.as_received (Terminal_text.single_line Skill_reference.(row.ksu_reference.identity.name))
                              ++ Say.code " · rev "
                              ++ Say.as_received (Terminal_text.single_line
                                   (Skill_reference.content_revision_to_string
                                      row.ksu_reference.content_revision)) )
                          ; ( Ansi.dim,
                              Say.as_received (Terminal_text.single_line keeper) ++ say_dot
                              ++ counts_text ~invocations:row.ksu_invocations ~deliveries:row.ksu_deliveries
                                   ~actions:row.ksu_actions
                              ++ say_dot ++ Say.both ~ko:"마지막 사용 " ~en:"Last used "
                              ++ Say.as_received (Terminal_text.single_line row.ksu_last_used_at) )
                          ])
                       outside))) ]
        in
        let unavailable_rows =
          List.map (fun note -> Theme.warn (), Say.code " " ++ Say.map Terminal_text.single_line note) notes
        in
        let rejection_rows =
          match sc_rejections with
          | [] -> []
          | rejections ->
            ( Ansi.bold,
              Say.per_language (function
                | Say.Ko -> Printf.sprintf " 거부된 Skill 출처 · %d" (List.length rejections)
                | Say.En -> Printf.sprintf " Rejected Skill Sources · %d" (List.length rejections)) )
            :: List.concat_map
                 (fun (rejection : Masc.Tui_decode_tools.skill_catalog_rejection) ->
                    let source =
                      Say.as_received (Terminal_text.single_line (rejection.scr_source_id ^ "/"))
                      ++ (match rejection.scr_package_id with
                          | Some package -> Say.as_received (Terminal_text.single_line package)
                          | None -> Say.both ~ko:"(잘못된 package)" ~en:"(invalid package)")
                    in
                    let revision =
                      match rejection.scr_content_revision with
                      | Some revision -> Say.as_received (Terminal_text.single_line revision)
                      | None -> Say.both ~ko:"알 수 없음" ~en:"unavailable"
                    in
                    (* The catalog's own diagnostic codes, which the reader
                       matches against the catalog's log. *)
                    let diagnostics =
                      match rejection.scr_reason with
                      | Masc.Tui_decode_tools.Skill_document_rejected diagnostics ->
                        List.map
                          (fun (diagnostic : Masc.Tui_decode_tools.skill_rejection_diagnostic) ->
                             ( Theme.warn (),
                               Say.code (Printf.sprintf "     %s: "
                                 (Masc.Tui_decode_tools.skill_diagnostic_code_to_string
                                    diagnostic.srd_diagnostic))
                               ++ Say.as_received (Terminal_text.single_line diagnostic.srd_message) ))
                          diagnostics
                      | Masc.Tui_decode_tools.Skill_document_unreadable ->
                        [ Theme.warn (), Say.code "     document_unreadable" ]
                      | Masc.Tui_decode_tools.Skill_exact_identity_duplicate ->
                        [ Theme.warn (), Say.code "     exact_identity_duplicate" ]
                      | Masc.Tui_decode_tools.Skill_invalid_package_id ->
                        [ Theme.warn (), Say.code "     invalid_package_id" ]
                    in
                    ( Theme.warn (), Say.code "   " ++ source ++ say_dot ++ revision )
                    :: diagnostics)
                 rejections
        in
        (* A Skill name two catalog entries declare. The first in catalog order
           wins (Skill_catalog_snapshot.effective_projection); the other is
           published but listed to no Keeper turn by that name, and this list
           is where an operator sees it. The name leads, the shadowed package
           follows it, and the winner stands on its own line so a narrow pane
           cuts neither package. *)
        let shadow_rows =
          let identity_text identity =
            Skill_reference.identity_source_id_to_string identity
            ^ "/"
            ^ Skill_reference.identity_package_id_to_string identity
          in
          match sc_shadows with
          | [] -> []
          | shadows ->
            ( Ansi.bold,
              Say.per_language (function
                | Say.Ko -> Printf.sprintf " 가려진 Skill · %d" (List.length shadows)
                | Say.En -> Printf.sprintf " Shadowed Skills · %d" (List.length shadows)) )
            :: List.concat_map
                 (fun (shadow : Masc.Tui_decode_tools.skill_catalog_shadow) ->
                    [ ( Theme.warn (),
                        Say.code "   "
                        ++ Say.as_received (Terminal_text.single_line shadow.scsh_shadowed.Skill_reference.name)
                        ++ say_dot
                        ++ Say.as_received (Terminal_text.single_line (identity_text shadow.scsh_shadowed)) )
                    ; ( Ansi.dim,
                        Say.both ~ko:"     가린 것: " ~en:"     shadowed by "
                        ++ Say.as_received (Terminal_text.single_line (identity_text shadow.scsh_winner)) )
                    ])
                 shadows
        in
        heading :: surface_cards @ outside_rows
        @ rows (unavailable_rows
                @ skill_source_lines ~config:sc_config ~sources:sc_sources
                @ rejection_rows @ shadow_rows)
    in
    rows error_lines @ reading_lines
    end
  in
  (* One section at a time. These used to be concatenated, and the first of
     them is one row per tool -- ninety-five of them on this workspace -- so
     the other four started past row 120 of a list a terminal shows twenty of.
     They were not missing; they were behind a section that never ends, with
     nothing saying so. *)
  let pane_lines =
    match state.tools_pane with
    | Masc_tui_types.Tools_surface -> Lazy.force effective_lines
    | Masc_tui_types.Tools_async -> async_request_observation_lines ~cols state
    | Masc_tui_types.Tools_activations -> Lazy.force activation_lines
    | Masc_tui_types.Tools_usage -> Lazy.force usage_matrix_lines
    | Masc_tui_types.Tools_catalog Tools_catalog_list -> Lazy.force catalog_lines
    | Masc_tui_types.Tools_catalog (Tools_catalog_volumes _) -> volume_gc_lines state
    | Masc_tui_types.Tools_storage -> storage_lines state
  in
  (* Each pane follows its own independent read. Retained rows are still
     useful during refresh; neither unread nor failed means a successful zero. *)
  let part, source, observed, error = match state.tools_pane with
    | Tools_surface | Tools_storage
    | Tools_catalog (Tools_catalog_list | Tools_catalog_volumes _) ->
        Tools_inventory_read, Say.both ~ko:"도구 목록" ~en:"tool inventory",
        Option.is_some state.tools_inventory, (selected_tools_error state)
    | Tools_activations ->
        Tools_activations_read, Say.both ~ko:"Skill 기록" ~en:"Skill activations",
        Option.is_some state.tools_activations,
        Option.map (fun failure -> failure.taf_detail) state.tools_activations_error
    | Tools_usage ->
        Tools_catalog_read, Say.both ~ko:"Skill catalog" ~en:"Skills catalog",
        Option.is_some state.skills_catalog, state.skills_catalog_error
    | Tools_async ->
        Tools_async_read, Say.both ~ko:"async broker" ~en:"async broker",
        Option.is_some state.tools_async_observation, state.tools_async_observation_error
  in
  (* The Usage pane draws the catalog and every Keeper's usage read. *)
  let reads_this_pane pending =
    match state.tools_pane with
    | Tools_usage ->
        (match pending with
         | Tools_catalog_read | Tools_usage_read _ -> true
         | Tools_inventory_read | Tools_activations_read | Tools_async_read -> false)
    | Tools_surface | Tools_async | Tools_activations | Tools_storage
    | Tools_catalog (Tools_catalog_list | Tools_catalog_volumes _) -> pending = part
  in
  let pending =
    if state.tools_pane = Tools_async then state.tools_async_observation_inflight
    else
      List.exists reads_this_pane state.tools_skill_pending
      || (match state.tools_read_inflight with
          | Some request
            when request.tri_generation = state.tools_request_generation
                 && Option.equal String.equal request.tri_keeper
                      (Option.map (fun (row : keeper) -> row.k_name) (selected_keeper state)) ->
              List.exists reads_this_pane request.tri_pending
          | Some _ | None -> false)
  in
  let reading_lines = if state.tools_pane=Tools_async && state.tools_async_detail_open then [] else match pending, observed, error with
    | true, _, Some _ ->
        [ Theme.warn (), Say.code " " ++ source
                         ++ Say.both ~ko:" 다시 읽는 중 · 앞선 실패 유지" ~en:" · retrying, previous failure retained" ]
    | true, true, None ->
        [ Ansi.dim, Say.code " " ++ source
                    ++ Say.both ~ko:" 새로 읽는 중 · 마지막 조회 유지" ~en:" · refreshing, last reading retained" ]
    | true, false, None ->
        [ Ansi.dim, Say.code " " ++ source ++ Say.both ~ko:" 읽는 중" ~en:" · reading" ]
    | false, true, Some _ ->
        [ Theme.warn (), Say.code " " ++ source
                         ++ Say.both ~ko:" 마지막 조회 유지 · r:새로 읽기" ~en:" · last reading retained · r:refresh" ]
    | false, false, None ->
        [ Ansi.dim, Say.code " " ++ source ++ Say.both ~ko:" 안 읽음 · r:새로 읽기" ~en:" not read · r:refresh" ]
    | false, true, None | false, false, Some _ -> []
  in
  let error_lines = match (selected_tools_error state) with
    | None -> []
    | Some (Request_failed detail) ->
      [Theme.bad (), Say.both ~ko:"도구 조회 실패: " ~en:"Tools read failed: "
                     ++ Say.as_received (Terminal_text.single_line detail)]
    | Some (Request_withdrawn refusal) ->
        [Theme.bad (), refusal_text ~request:Kept_request.Tool_inventory_read refusal]
  in
  let width = max 1 (Masc_tui_frame.inner_width ~cols) in
  (* The one place this screen's rows take a language. *)
  let wrap pieces = List.concat_map (fun ((style, text), mark) ->
       (* Fitted tables and usage cards already own their alignment. Only
          overlong rows need physical wrapping; never render metadata as
          Markdown or shorten its identities to fit the frame. Every row a
          wrapped marked row becomes keeps the mark, so its run is whole, and
          every row keeps the instant its time text changes at. *)
       if Masc_tui_message_layout.display_width text <= width then [ (style, text), mark ]
       else Masc_tui_message_layout.wrap_words ~max_cells:width text
            |> List.map (fun line -> (style, line), mark))
       (draw_marked language pieces) in
  let drafts = List.map (fun draft ->
      Theme.warn (),
      Say.both ~ko:" 게시 안 한 " ~en:" Unpublished "
      ++ Say.code (if draft.scd_composition then "Composition" else "Instruction")
      ++ Say.both ~ko:" 초안 보관 중: " ~en:" draft retained for "
      ++ Say.as_received (Terminal_text.single_line draft.scd_source_id)
      ++ say_dot ++ Say.code (if draft.scd_composition then "C" else "c")
      ++ Say.both ~ko:": 편집기에서 이어 쓰기" ~en:":resume in editor")
    (skill_create_drafts_for_current_workspace state) in
  let notices = rows (drafts @ reading_lines @ error_lines) in
  (* The selection's document stands above the list, so on a pane whose list
     the move keys walk it takes as many rows for every selection: as many as
     the tallest document among the loaded entries, a shorter one ending in
     blank rows (RFC tui-one-screen-grammar §8). Sized by the selected
     entry alone, the list moved a row with j and k wherever the next
     entry's source or requester wrapped differently, and a page counted in
     one frame was a row off in the frame the key landed in, so PgDn and
     PgUp pushed the entry read last off the window (§3.1). The document is
     an identity and is never cut, so no cap applies: it is as tall as it
     wraps. *)
  let selection_rows =
    let shown = wrap (tools_selection_document ~cols state) in
    match selections state with
    | None -> shown
    | Some loaded ->
        let tallest =
          max (List.length shown)
            (tallest_selection_rows ~cols ~language
               ~rows_of:(fun document -> List.length (wrap document)) state loaded)
        in
        shown @ List.init (tallest - List.length shown) (fun _ -> ("", ""), Unmarked)
  in
  (* Where each entry of the pane's list is in the page, in order, from the
     page wrapped one piece at a time, so no row is wrapped twice. *)
  let entry_spans ~above wrapped =
    List.fold_left
      (fun (row, spans) (piece, rows) ->
         let next = row + List.length rows in
         match piece with
         | List_entry _ -> next, { first_row = row; last_row = next - 1 } :: spans
         | Row _ | Cursor _ | Timed _ | Laid_out _ | Measurement_card _ -> next, spans)
      (above, []) wrapped
    |> snd |> List.rev
  in
  let marked, entry_rows =
    if Option.is_some (tools_volume_gc_parent_scroll state.tools_pane) then
      wrap (pane_lines @ rows (reading_lines @ error_lines)), []
    else if state.tools_pane = Tools_storage then
      (* No Skill is selected here, so the Skill heading stays out. *)
      wrap (rows (reading_lines @ error_lines) @ pane_lines), []
    else if state.tools_pane=Tools_async && state.tools_async_detail_open && Option.is_some state.tools_async_task_source then
      selection_rows @ wrap notices @ draw_marked language pane_lines, []
    else
      (* A row wraps by its own width alone, so a piece takes as many rows
         wrapped by itself as among the rows around it. *)
      let wrapped = List.map (fun piece -> piece, wrap [ piece ]) (notices @ pane_lines) in
      ( selection_rows @ List.concat_map snd wrapped
      , entry_spans ~above:(List.length selection_rows) wrapped )
  in
  let entries =
    let listed list = match entry_rows with [] -> None | spans -> Some (list, spans) in
    match state.tools_pane with
    | Tools_surface -> listed Skill_entries
    | Tools_async -> listed Async_request_entries
    | Tools_activations | Tools_usage | Tools_storage | Tools_catalog _ -> None
  in
  (* The first and the last row [in_run] picks. The [Cursor] pieces are the
     adjacent rows of one Skill and the card is one piece, so each run is
     whole. *)
  let span in_run =
    List.fold_left
      (fun (index, span) (_, mark) ->
         let span =
           match in_run mark, span with
           | false, _ -> span
           | true, None -> Some { first_row = index; last_row = index }
           | true, Some rows -> Some { rows with last_row = index }
         in
         index + 1, span)
      (0, None) marked
    |> snd
  in
  { lines = List.map fst marked
  ; cursor = span (function Entry -> true | Unmarked | Card | Changes_at _ -> false)
  ; card = span (function Card -> true | Unmarked | Entry | Changes_at _ -> false)
  ; row_changes =
      List.concat
        (List.mapi
           (fun index (_, mark) ->
             match mark with
             | Changes_at at -> [ (index, at) ]
             | Unmarked | Entry | Card -> [])
           marked)
  ; entries
  }
;;

let drawn_change display window =
  List.fold_left
    (fun earliest (index, at) ->
      match Masc_tui_rows.at window index, earliest with
      | None, _ -> earliest
      | Some _, None -> Some at
      | Some _, Some sooner -> Some (Float.min sooner at))
    None display.row_changes

let tools_display_lines ?cols ?terminal_rows state = (tools_display ?cols ?terminal_rows state).lines

(* A Skill or a request can wrap, so a page counts the entries the window
   holds whole wherever it stands, as the cursor counts entries. The first
   entry takes every row of the page above it too, since the window brings
   the top of the page in with it (Home); a page counted without them let
   PgUp onto the first entry push the entry read first off the window. *)
let drawn_page display ~rows =
  let heights = function
    | [] -> []
    | first :: rest ->
        (first.last_row + 1) :: List.map (fun entry -> entry.last_row - entry.first_row + 1) rest
  in
  Option.map
    (fun (list, spans) -> list, Masc_tui_scroll.items_always_shown ~heights:(heights spans) ~rows)
    display.entries

type landing = { entry : cursor_rows; lead : int }

(* Where the selected Skill is drawn on the Available pane: the rows its
   entry takes there, every row of it when it wraps ([cursor]), and the
   lines above it that belong with it. The group heading above it is not
   part of the entry, so the lead brings it in.

   The first Skill brings everything above it, so Home shows the top of the
   page. A Skill that opens its group brings the group heading, which the
   renderer draws above the first Skill of each kind. *)
let skill_landing (state : state) display =
  Option.map (fun entry ->
      let instruction (profile : Masc.Tui_decode_tools.effective_skill_profile) =
        match profile.esp_io with
        | Model_orchestrated -> true
        | Composition_io _ -> false
      in
      let profiles = tools_skill_profiles state in
      let cursor = state.tools_skill_cursor in
      let lead =
        if cursor <= 0 then entry.first_row
        else
          match List.nth_opt profiles (cursor - 1), List.nth_opt profiles cursor with
          | Some previous, Some selected
            when not (Bool.equal (instruction previous) (instruction selected)) -> 1
          | Some _, Some _ | Some _, None | None, Some _ | None, None -> 0
      in
      { entry; lead })
    display.cursor

(* Where the selected async request is drawn: the rows its entry takes in
   the page. The first request brings everything above it, as the first
   Skill does. *)
let request_landing (state : state) display =
  match display.entries, state.tools_async_selection with
  | Some (_, spans), Some selected ->
      Option.bind
        (List.find_index (Masc.Tui_decode_async_request.equal_target selected)
           (tools_async_targets state))
        (fun index ->
          Option.map
            (fun entry -> { entry; lead = (if index = 0 then entry.first_row else 0) })
            (List.nth_opt spans index))
  | Some _, None | None, (Some _ | None) -> None

(* The window over a landing, the way [row_list]'s [follow] works for a row
   cursor: the last line first, then the first with its lead, so a Skill or
   a request that wraps is on screen whole when it fits. *)
let follow landing ~height scroll =
  Masc_tui_scroll.ensure_visible_with_lead ~cursor:landing.entry.first_row ~lead:landing.lead
    ~height (Masc_tui_scroll.ensure_visible ~cursor:landing.entry.last_row ~height scroll)
