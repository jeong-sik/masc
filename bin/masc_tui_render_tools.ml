(** The Tools surface: what the selected Keeper's turn called, and what the
    process has registered. *)

open Masc_tui_types
open Tui_decode
open Masc_tui_ansi

module Tool_tree = Masc_tui_tool_tree
module Tool_table = Masc_tui_tool_table
let json_assoc_member_opt = Masc_tui_json.member_opt

let skill_async_evidence_lines evidence =
  let view = Masc.Tui_skill_async_evidence.project evidence in
  let deliveries = view.result_deliveries in
  if List.is_empty deliveries && view.action_link_count = 0 then []
  else
    let delivery_lines =
      List.concat_map
        (fun (delivery : Masc.Keeper_skill_async_delivery.t) ->
          let presentation = match delivery.presentation with
            | Inline_result -> "inline result"
            | Manifest_reference -> "manifest reference" in
          [ Ansi.dim, Terminal_text.single_line (Printf.sprintf
              "       Async %s received=%s runtime=%s at=%s"
              presentation (Ids.Turn_ref.to_string delivery.physical_turn_ref)
              delivery.runtime_id delivery.observed_at)
          ; Ansi.dim, Terminal_text.single_line (Printf.sprintf
              "         original=%s run=%s parent=%s request=%s bytes=%d sha256=%s"
              (Ids.Turn_ref.to_string delivery.original_turn_ref)
              (Masc.Keeper_tool_plan.Composition_run_id.to_string delivery.composition_run_id)
              delivery.logical_parent_tool_use_id delivery.request_id
              delivery.receipt.content_bytes delivery.receipt.content_sha256)
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
                | Handler_returned { bytes; sha256 } -> Ansi.dim, "SDK returned", bytes, sha256
                | Handler_errored { bytes; sha256; recoverable; error_class } ->
                  let error = match error_class with
                    | None -> "unclassified"
                    | Some Agent_core.Types.Transient -> "transient"
                    | Some Deterministic -> "deterministic"
                    | Some Unknown -> "unknown" in
                  Theme.bad (), Printf.sprintf "SDK errored class=%s recoverable=%b" error recoverable,
                  bytes, sha256 in
              style, Printf.sprintf "%s call=%s SDK-turn=%d bytes=%d sha256=%s"
                outcome (Agent_core.Tool_contract.Invocation.tool_use_id invocation)
                (Agent_core.Tool_contract.Invocation.turn invocation) bytes sha256
            | Native_started { official_turn; identity } ->
              let identity = match identity with
                | Runtime_native_tools.Call_id id -> "call=" ^ id
                | Provider_step { conversation_id; step_index } ->
                  Printf.sprintf "step=%s:%d" conversation_id step_index in
              Ansi.dim, Printf.sprintf "Native started official-turn=%d %s" official_turn identity
          in
          (style, Terminal_text.single_line (Printf.sprintf
             "       %s · %s · received=%s runtime=%s" action.tool_name occurrence
             (Ids.Turn_ref.to_string action.physical_turn_ref) action.runtime_id))
          :: List.map
               (fun (link : Masc.Keeper_skill_async_action.t) ->
                 Ansi.dim, Terminal_text.single_line (Printf.sprintf
                   "         causal handoff=%s at=%s" link.delivery_sha256 link.observed_at))
               (group.first :: group.additional_links))
        view.actions
    in
    (Ansi.dim, Printf.sprintf "       Async results: %d handoffs · %d physical actions · %d causal links"
       (List.length deliveries) (List.length view.actions) view.action_link_count)
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

let skill_instruction_origin_text = function
  | Masc.Keeper_skill_activation_ledger.Task_instruction { task_ids } ->
      "task_instruction tasks="
      ^ (Masc.Keeper_skill_activation_ledger.task_id_set_to_list task_ids
         |> List.map Keeper_id.Task_id.to_string
         |> String.concat ",")
  | Masc.Keeper_skill_activation_ledger.Session_instruction ->
      "session_instruction"

let skill_composition_origin_text ~tool_name = function
  | Masc.Keeper_skill_activation_ledger.Task_composition
      { task_ids } ->
      Printf.sprintf "task_composition tasks=%s tool=%s"
        (Masc.Keeper_skill_activation_ledger.task_id_set_to_list task_ids
         |> List.map Keeper_id.Task_id.to_string
         |> String.concat ",")
        tool_name
  | Masc.Keeper_skill_activation_ledger.Session_composition ->
      "session_composition tool=" ^ tool_name

let skill_served_content_text = function
  | Masc.Keeper_skill_activation_ledger.Skill_body { bytes; sha256 } ->
      Printf.sprintf "body bytes=%d sha256=%s" bytes sha256
  | Masc.Keeper_skill_activation_ledger.Skill_resource
      { relative_path; bytes; sha256 } ->
      Printf.sprintf "resource=%s bytes=%d sha256=%s" relative_path bytes sha256

let skill_invocation_text = function
  | Masc.Keeper_skill_activation_ledger.Instruction_invocation
      { origin; served_content } ->
    skill_instruction_origin_text origin, skill_served_content_text served_content
  | Masc.Keeper_skill_activation_ledger.Composition_invocation
      { origin; tool_name; _ }
  | Masc.Keeper_skill_activation_ledger.Nested_composition_invocation
      { origin; tool_name; scope = _ } ->
    ( skill_composition_origin_text ~tool_name origin
    , "composition invocation tool=" ^ tool_name )

let skill_delivery_text ~has_action = function
  | None -> "pending"
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
      Printf.sprintf
        "%s turn=%d runtime=%s bytes=%d sha256=%s at=%s%s"
        kind
        turn
        (Terminal_text.single_line delivery.runtime_id)
        delivery.content_bytes
        (Terminal_text.single_line delivery.content_sha256)
        delivery.delivered_at
        proof

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
       Printf.sprintf
         "       action turn=%d runtime=%s tool=%s %s at=%s"
         action.agent_core_turn
         (Terminal_text.single_line action.runtime_id)
         (Terminal_text.single_line (Masc.Tool_display.list_label action.tool_name))
         (Terminal_text.single_line identity)
         (Terminal_text.single_line action.observed_at))
    actions

let async_request_inventory_lines (state : state) =
  let errors = Option.to_list (Option.map (fun detail -> Theme.bad (),
    " Async broker — 재확인 실패 · 이전 목록 유지: " ^ Terminal_text.single_line detail)
    state.tools_async_observation_error) in
  errors @ (match state.tools_async_observation with
  | None -> if errors=[] then [ Theme.warn (), " Async broker — not loaded" ] else []
  | Some (Async_unavailable { kind; reason }) ->
    [ Theme.bad (), " Async broker — durable inventory unavailable: "
        ^ Terminal_text.single_line kind
        ^ Option.fold ~none:"" ~some:(fun value -> ": " ^ Terminal_text.single_line value) reason ]
  | Some (Async_ready { summary; requests; recovery }) ->
    let summary_lines =
      [ Ansi.bold,
        Printf.sprintf
          " Async broker — active=%d · runtime-owned=%d · ownership-unknown=%d · record-errors=%d"
          summary.ars_active summary.ars_runtime_owned
          summary.ars_ownership_unknown summary.ars_record_errors ]
    in
    let now = Unix.gettimeofday () in
    let request_lines = List.map (fun request ->
      let tone, ownership = match request.ar_ownership with
        | Async_runtime_owned -> Theme.ok (), "runtime_owned"
        | Async_ownership_unknown -> Theme.warn (), "disk_only_ownership_unknown"
      in
      let status = match request.ar_phase with
        | Async_queued -> "queued"
        | Async_running -> "running"
        | Async_cancelling -> "cancelling"
      in
      let elapsed =
        match
          Masc_tui_message_layout.elapsed_text (now -. request.ar_submitted_at)
        with
        | Some text -> text
        | None -> Masc_tui_theme.Glyph.no_value
      in
      let selected = Option.exists (fun (target : Masc.Tui_decode_async_request.target) ->
        target.request_id=request.ar_request_id && target.submitted_by=request.ar_submitted_by
        && target.keeper_name=request.ar_keeper_name) state.tools_async_selection in
      tone, Printf.sprintf " %s %s · %s · %s · %s · %s"
        (if selected then "›" else " ")
        (Terminal_text.single_line request.ar_request_id)
        (Terminal_text.single_line request.ar_keeper_name)
        status elapsed ownership) requests
    in
    let recovery_lines = match recovery with
      | None -> [ Ansi.dim, "   startup recovery: not observed by this process" ]
      | Some report ->
        [ Ansi.dim,
          Printf.sprintf
            "   startup recovery: lost=%d finalized=%d cleaned=%d unreadable=%d failed=%d staging=%d/%d/%d"
            report.arr_lost report.arr_finalized report.arr_cleaned
            report.arr_unreadable report.arr_failed report.arr_staging_inspected
            report.arr_staging_deleted report.arr_staging_preserved ]
    in
    summary_lines @ request_lines @ recovery_lines)

let async_logical_lines value =
  let module Detail = Masc.Tui_decode_async_request in
  let safe = Terminal_text.single_line in
  match value with
  | Detail.Not_composition -> [Ansi.dim," 논리: Composition 원본 없음"]
  | Original_run run ->
    [Theme.info ()," 원본 run: " ^ safe run.run_id;
     Ansi.dim," 원본 Task: " ^ Option.fold ~none:"없음(기록)" ~some:safe run.source_task_id;
     Ansi.dim,Printf.sprintf " 현재 run owner: %s · generation %d" (safe run.owner.request_id) run.owner.generation;
     Ansi.dim,Printf.sprintf " 논리 관측 시각: %.3f · journal %s" run.observed_at (safe run.journal_version)]
    @ (match run.resolution with
      | None -> [Theme.warn ()," 논리: 명시적 종결 없음 · 실행 허가는 별도"]
      | Some resolution ->
        [Theme.warn ()," 논리: 재개 종결 — " ^ (match resolution.decision with
            | Detail.Rejected -> "거절" | Cancelled_continuation -> "취소");
         Ansi.dim,Printf.sprintf " 결정: %s · %.3f" (safe resolution.requested_by) resolution.resolved_at;
         Theme.info ()," 사유: " ^ safe resolution.reason])

let async_request_detail_lines ~cols state target =
  let module Detail = Masc.Tui_decode_async_request in
  let view = Masc_tui_fetched.view_for ~equal:Detail.equal_target state.tools_async_detail ~key:target in
  let pending = Masc_tui_fetched.in_flight state.tools_async_detail in
  let reading = match pending,view with
    | true,(Masc_tui_fetched.Ready _ | Stale _) -> [Ansi.dim," 재조회 중 · 이전 관측 유지"]
    | true,(Absent | Loading | Failed _) -> [Ansi.dim," 원본 요청 조회 중"]
    | false,_ -> [] in
  let failures = match view with
    | Masc_tui_fetched.Absent -> [Ansi.dim," 미조회"]
    | Loading -> []
    | Failed detail -> [Theme.bad ()," 조회 실패: " ^ Terminal_text.single_line detail]
    | Stale (_,detail) -> [Theme.warn ()," 마지막 관측 · 재확인 실패: " ^ Terminal_text.single_line detail]
    | Ready _ -> [] in
  let snapshot = match Masc_tui_fetched.value view with
    | None -> []
    | Some Detail.Absent -> [Theme.warn ()," 원본 요청이 관측되지 않습니다 · 재실행 허가가 아닙니다"]
    | Some (Observed snapshot) ->
      let phase = match snapshot.phase with
        | Detail.Queued -> "queued" | Running -> "running" | Cancelling -> "cancelling"
        | Waiting -> "waiting_for_dependencies · worker 해제됨"
        | Lost -> "lost" | Cancelled -> "cancelled" | Persistence_failed -> "persistence_failed"
        | Done true -> "done (물리 성공)" | Done false -> "error (물리 실패)" in
      let physical = [Theme.info ()," 물리 상태: " ^ phase;
        Ansi.dim,Printf.sprintf " 접수: %.3f · 종료: %s" snapshot.submitted_at
          (Option.fold ~none:"미종료" ~some:(Printf.sprintf "%.3f") snapshot.completed_at)] in
      let dependencies = List.map (fun dependency ->
        Ansi.dim," 의존: " ^ Terminal_text.single_line
          (Yojson.Safe.to_string (Masc.Keeper_composition_dependency.to_json dependency))) snapshot.dependencies in
      let logical = match snapshot.logical with
        | Detail.Confirmed value -> async_logical_lines value
        | Unavailable detail ->
          [Theme.bad ()," 논리 상태 조회 불가: " ^ Terminal_text.single_line detail]
          @ (match state.tools_async_last_logical with
            | Some (source,value) when Detail.equal_source source snapshot.source ->
              [Theme.warn ()," 아래 논리는 마지막 관측이며 최신 확인이 아닙니다"] @ async_logical_lines value
            | Some _ | None -> [Ansi.dim," 확인된 이전 논리 관측 없음"]) in
      let nested = Masc_tui_nested_result.sections snapshot.nested
        |> List.concat_map (fun (heading,body) ->
          (Ansi.bold,Terminal_text.single_line heading) ::
          (Masc_tui_text_block.rows ~max_cells:(max 1 (Masc_tui_frame.inner_width ~cols)) body
           |> List.map (fun row -> Ansi.dim,row))) in
      physical @ Option.to_list (Option.map (fun notice -> Theme.warn (),
        " 물리 사유: " ^ Terminal_text.single_line notice) snapshot.notice) @ dependencies @ logical @ nested in
  [Ansi.bold," 원본 비동기 요청 · t:원본 Task · o:원본 ID 조회 · r:재조회 · Esc:목록"] @ reading @ failures @ snapshot

let async_source_task_lines ~cols state source =
  let width=max 1 (Masc_tui_frame.inner_width ~cols) in
  let text tone value = Masc_tui_text_block.rows ~max_cells:width value |> List.map (fun row -> tone,row) in
  let body=Masc_tui_fetched.view_for ~equal:equal_tools_async_task_source state.tools_async_task_body ~key:source in
  let history=Masc_tui_fetched.view_for ~equal:equal_tools_async_task_source state.tools_async_task_history ~key:source in
  let pending = if Masc_tui_fetched.in_flight state.tools_async_task_body then
      text Ansi.dim " Task 본문 조회 중 · 기존 관측·실패 유지" else [] in
  let errors=match body with
    | Masc_tui_fetched.Absent -> text Ansi.dim " Task 본문 미조회"
    | Loading | Ready _ -> []
    | Failed detail -> text (Theme.bad ()) (" Task 본문 조회 실패: " ^ detail)
    | Stale (_,detail) -> text (Theme.warn ()) (" Task 본문 재확인 실패 · 마지막 관측: " ^ detail) in
  let content=match Masc_tui_fetched.value body with
    | None -> []
    | Some (detail : Masc.Tui_decode_task_inspection.detail) ->
      let warnings=List.concat_map (fun (name,outcome) -> match outcome with
        | Masc_domain.Field_absent | Field_decoded -> []
        | Field_unreadable reason -> text (Theme.warn ()) (" Task " ^ name ^ " 조회 불가: " ^ reason))
        ["handoff",detail.diagnostics.handoff_context_outcome] in
      warnings @ (task_document_lines state ~cols Masc_tui_task_document.Body
        |> List.map (fun line -> "",line)) in
  text Ansi.bold (" 원본 Task · " ^ source.ats_task_id ^ " · r:본문·이력 재조회 · Esc:원본 요청")
  @ text Ansi.dim (Printf.sprintf " 출처 run: %s · 논리 관측 %.3f%s" source.ats_run_id source.ats_observed_at
      (if source.ats_retained then " · 이전 확인 관측에서 열림" else ""))
  @ pending @ errors @ content
  @ [ "", "" ]
  @ (Masc_tui_task_document.history_heading_rows ~ko:(state.ui_language = Lang_ko) ~width:(max 1 (width - 2))
     |> List.map (fun row -> "", row))
  @ (Masc_tui_task_document.history_status_lines ~ko:(state.ui_language = Lang_ko) ~width ~view:history
       ~in_flight:(Masc_tui_fetched.in_flight state.tools_async_task_history)
       ~continuing:(Option.exists (fun request -> Option.is_some request.thr_page.hr_cursor)
         state.tools_async_task_history_request)
      |> List.concat_map (fun line ->
           Masc_tui_text_block.preformatted_rows ~max_cells:width line
           |> List.map (fun row -> "", row)))
  @ (task_document_lines state ~cols Masc_tui_task_document.History
     |> List.map (fun line -> "",line))

let async_request_observation_lines ~cols state =
  match state.tools_async_detail_open,state.tools_async_selection,state.tools_async_task_source with
  | true,Some _,Some source -> async_source_task_lines ~cols state source
  | true,Some target,None -> async_request_detail_lines ~cols state target
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

let skill_source_reading (observation : Masc.Tui_decode_tools.skill_source_observation) =
  match observation with
  | Masc.Tui_decode_tools.Skill_source_ready count ->
    ( (if count = 0 then Ansi.dim else Theme.ok ())
    , (if count = 0 then "\xc2\xb7" else "\xe2\x9c\x93")
    , Printf.sprintf "%d skill director%s" count
        (if count = 1 then "y" else "ies") )
  | Masc.Tui_decode_tools.Skill_source_missing -> (Ansi.dim, "\xc2\xb7", "missing")
  | Masc.Tui_decode_tools.Skill_source_not_directory kind ->
    (Theme.warn (), "!", "not a directory (" ^ kind ^ ")")
  | Masc.Tui_decode_tools.Skill_source_unavailable operation ->
    (Theme.warn (), "!", "unreadable at " ^ operation)
  | Masc.Tui_decode_tools.Skill_source_unresolved ->
    (Theme.warn (), "!", "path refused by config")
;;

let skill_config_line (config : Masc.Tui_decode_tools.skill_catalog_config option) =
  match config with
  | None -> []
  | Some (Masc.Tui_decode_tools.Skill_config_configured { revision; resource_read_max_bytes })
    ->
    let cap =
      match resource_read_max_bytes with
      | None -> "no resource read cap"
      | Some bytes -> Printf.sprintf "resource read \xe2\x89\xa4 %d bytes" bytes
    in
    [ ( Ansi.dim
      , Printf.sprintf "   config %s \xc2\xb7 %s"
          (Terminal_text.single_line revision)
          cap )
    ]
  | Some (Masc.Tui_decode_tools.Skill_config_rejected { source_revision; diagnostics }) ->
    (* The catalog still stands on the defaults, so nothing else on the
       screen changes when the operator's section stops parsing. *)
    ( Theme.warn ()
    , Printf.sprintf "   runtime.toml Skill config rejected (rev %s) \xe2\x80\x94 defaults in use"
        (Terminal_text.single_line source_revision) )
    :: List.map
         (fun diagnostic ->
            (Theme.warn (), "     " ^ Terminal_text.single_line diagnostic))
         diagnostics
  | Some Masc.Tui_decode_tools.Skill_config_unreadable ->
    [ ( Theme.warn ()
      , "   runtime.toml Skill config unreadable \xe2\x80\x94 defaults in use" )
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
  match List.filter_map batch flow.sf_batches with
  | [] -> None
  | parts -> Some (String.concat "  \xe2\x94\x80\xe2\x96\xb6  " parts)
;;

(* Complete composition metadata, including nodes outside the recorded
   batches. The final physical-row projection keeps each value reachable. *)
let skill_flow_detail_lines (flow : Masc.Tui_decode_tools.skill_flow) =
  let batches = List.map
    (fun (batch : Masc.Tui_decode_tools.skill_flow_batch) ->
      Ansi.dim, Printf.sprintf "Batch %d · %s · nodes: %s"
        batch.sfb_index
        (Terminal_text.single_line batch.sfb_execution_mode)
        (String.concat ", " (List.map Terminal_text.single_line batch.sfb_node_ids)))
    flow.sf_batches in
  let nodes = List.concat_map
    (fun (node : Masc.Tui_decode_tools.skill_flow_node) ->
      (Ansi.dim, Printf.sprintf "Node %s · tool: %s · batch: %d · mode: %s"
        (Terminal_text.single_line node.sfn_id)
        (Terminal_text.single_line node.sfn_tool_name) node.sfn_batch_index
        (Terminal_text.single_line node.sfn_execution_mode))
      :: (match node.sfn_dependencies with
          | [] -> [Ansi.dim, "  Dependencies: none"]
          | dependencies -> List.map
              (fun (dependency : Masc.Tui_decode_tools.skill_flow_dependency) ->
                Ansi.dim, Printf.sprintf "  Dependency %s · kind: %s"
                  (Terminal_text.single_line dependency.sfd_node_id)
                  (Terminal_text.single_line dependency.sfd_kind)) dependencies))
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
  let heading =
    ( Ansi.bold
    , Printf.sprintf " Skill Sources \xe2\x80\x94 %d of %d root%s carrying skills"
        ready (List.length sources)
        (if List.length sources = 1 then "" else "s") )
  in
  let rows =
    List.map
      (fun (source : Masc.Tui_decode_tools.skill_catalog_source) ->
         let tone, mark, reading = skill_source_reading source.scso_observation in
         let path =
           match source.scso_path with
           | Some path -> Terminal_text.single_line path
           | None -> "(absolute; path not published)"
         in
         ( tone
         , Printf.sprintf "   %s %-16s %-10s %-26s %-2s  %s" mark
             (Terminal_text.single_line source.scso_id)
             (Terminal_text.single_line source.scso_anchor)
             path
             (skill_access_short source.scso_access)
             reading ))
      sources
  in
  match sources with
  | [] -> []
  | _ -> (heading :: rows) @ skill_config_line config @ [ (Ansi.dim, "") ]
;;
;;

(* The catalog's volume child shows what the next press sends, the server's
   last periodic inventory report, and the last operator-request answer. *)
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
    (fun (tone, text) ->
       let color =
         match tone with
         | Masc_tui_volume_gc.Plain -> ""
         | Masc_tui_volume_gc.Dim -> Ansi.dim
         | Masc_tui_volume_gc.Bad -> Theme.bad ()
       in
       color, " " ^ text)
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
           color, " " ^ text)
        (Masc_tui_storage.lines ~timestamp ~uptime snapshot.ts_storage)
    in
    let volumes =
      let tone, text =
        Masc_tui_volume_gc.server_report_line ~timestamp snapshot.ts_volume_gc_report
      in
      let color =
        match tone with
        | Masc_tui_volume_gc.Plain -> ""
        | Masc_tui_volume_gc.Dim -> Ansi.dim
        | Masc_tui_volume_gc.Bad -> Theme.bad ()
      in
      [ Ansi.bold, " 은퇴한 Keeper 의 볼륨"
      ; color, "   " ^ text
      ; Ansi.dim, "   회수는 전체 도구 탭에서 " ^ Masc_tui_volume_gc.key ^ " 로 합니다."
      ]
    in
    reading @ volumes
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
  tab_strip
    ~width:(tab_strip_width ~cols ~before:" " ~after:"")
    ~press:(fun pane text -> Masc_tui_press.(pressable (Press_tools_pane pane) text))
    (List.map
       (fun (pane, label) -> (label, active_pane = pane, pane))
       [ (Masc_tui_types.Tools_surface, "호출 범위")
       ; (Masc_tui_types.Tools_async, "비동기 작업")
       ; (Masc_tui_types.Tools_activations, "Skill 기록")
       ; (Masc_tui_types.Tools_usage, "Skill 사용 집계")
       ; (Masc_tui_types.Tools_catalog Tools_catalog_list, "전체 도구")
       ; (Masc_tui_types.Tools_storage, "저장 공간")
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

type skill_json_projection =
  { json_source : Yojson.Safe.t
  ; json_cols : int
  ; json_palette_generation : int
  ; json_lines : (string * string) list
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

let skill_io_lines ~cols = function
  | Masc.Tui_decode_tools.Model_orchestrated ->
      [ Ansi.dim, "     Input: exact Skill reference / optional resource path";
        Ansi.dim, "     Output: instruction body or resource; subsequent tools are model-orchestrated";
        Ansi.dim, "     Average execution: not applicable to instruction text" ]
  | Composition_io { input_schema; exports } ->
      (Ansi.bold, "     Declared input schema (required parameters, types and enums)")
      :: cached_skill_json skill_schema_projection ~cols
           ~render:(skill_json_lines ~cols ~indent:7) input_schema
      @ (match exports with
         | [] -> [Ansi.dim, "     Declared output: complete execution result (no selected exports)"]
         | routes -> (Ansi.bold, "     Declared output routes") :: List.map (fun route ->
             Ansi.dim, Printf.sprintf "       %s ← node %s · JSON pointer %s"
               (Terminal_text.single_line route.Masc.Tui_decode_tools.sor_name)
               (Terminal_text.single_line route.sor_node_id)
               (if route.sor_pointer = "" then "(root)" else Terminal_text.single_line route.sor_pointer)) routes)
;;

let skill_statistics_lines ~cols = function
  | None -> [Ansi.dim, "실행 시간 집계 없음 · 미관측은 0ms가 아닙니다"]
  | Some stats ->
      let rows =
        [ "completed", Theme.ok (), stats.Masc.Tui_decode_skill_evidence.scst_completed
        ; "failed", Theme.bad (), stats.scst_failed ] in
      let milliseconds = function
        | None -> "—"
        | Some value -> Printf.sprintf "%.1fms" value in
      let duration (name, style, row) =
        [ style, Printf.sprintf "%s · n=%d · 평균 %s · P50 %s · P95 %s"
            name row.Masc.Tui_decode_skill_evidence.sds_samples
            (milliseconds row.sds_mean_ms) (milliseconds row.sds_p50_ms)
            (milliseconds row.sds_p95_ms)
        ; Ansi.dim, Printf.sprintf "  최소 %s → 최대 %s"
            (milliseconds row.sds_min_ms) (milliseconds row.sds_max_ms) ] in
      let recorded_at value =
        try Time_codec.rfc3339_of_unix value with
        | Unix.Unix_error _ | Invalid_argument _ -> Printf.sprintf "%.3f Unix seconds" value in
      let window = match stats.scst_first_recorded_at, stats.scst_last_recorded_at with
        | Some first, Some last ->
          "결과 기록 시각(UTC): " ^ recorded_at first
          ^ " → " ^ recorded_at last
        | _ -> "결과 기록 시각: 미관측" in
      [ Theme.info (), Printf.sprintf "executor 실행 시간 · 보존된 원래 실행 %d건" stats.scst_records
      ; Ansi.dim, "동일 revision / 전체 Keepers · P50/P95: nearest rank"
      ; Ansi.dim, window ]
      @ List.concat_map duration rows
      @ [ Ansi.bold, "실행 결과 분포 · 분모는 보존된 원래 실행 수" ]
      @ (Masc_tui_chart.distribution_bars
           ~width:(max 1 (Masc_tui_frame.inner_width ~cols - 4))
           [ { name = "completed"; count = stats.scst_completed.sds_samples; style = Masc_tui_theme.Ok }
           ; { name = "failed"; count = stats.scst_failed.sds_samples; style = Masc_tui_theme.Bad }
           ; { name = "deferred"; count = stats.scst_deferred; style = Masc_tui_theme.Warn } ]
         |> List.map (fun line -> "", line))
      @ [ Ansi.dim, "deferred는 실행 시간에서 제외 · queue/의존 대기/model 시간은 별도" ]
;;

let skill_settlement_lines_uncached ~cols composition =
  match json_assoc_member_opt "executor_settlements" composition with
  | Some (`List settlements) ->
      List.concat_map (fun node ->
        let field name = match json_assoc_member_opt name node with
          | Some (`String value) -> value
          | Some value -> Yojson.Safe.to_string value
          | None -> "unavailable" in
        let content label name = (Ansi.bold, "       " ^ label) ::
          (match json_assoc_member_opt name node with
           | Some value -> skill_json_lines ~cols ~indent:9 value
           | None -> [Ansi.dim, "         unavailable"]) in
        [Ansi.bold, Printf.sprintf "     Observed node %s · %s · origin=%s"
           (Terminal_text.single_line (field "node_id")) (Terminal_text.single_line (field "tool_name"))
           (Terminal_text.single_line (field "execution_origin"));
         Ansi.dim, Printf.sprintf "       output bytes=%s · truncated_to=%s"
           (Terminal_text.single_line (field "result_bytes")) (Terminal_text.single_line (field "truncated_to"));
         Ansi.dim, "       execution=" ^ Terminal_text.single_line (field "execution_id")
           ^ " · tool use=" ^ Terminal_text.single_line (field "tool_use_id")]
        @ content "Observed input" "input"
        @ content "Observed result (disposition, duration, output)" "result") settlements
  | Some _ | None -> []
;;

let skill_settlement_lines ~cols composition =
  cached_skill_json skill_settlements_projection ~cols
    ~render:(skill_settlement_lines_uncached ~cols) composition

let skill_run_history_lines state (evidence : Masc.Tui_decode_skill_evidence.skill_evidence) =
  match evidence.se_composition_runs with
  | None -> [Theme.warn (), "     Run history unavailable; storage gaps cannot establish absence"]
  | Some runs ->
    let selected_id = match evidence.se_composition_selection with
      | Latest_retained -> Option.map
          (fun (run : Masc.Keeper_skill_composition_evidence.run_summary) -> run.run_id)
          (List.nth_opt runs 0)
      | Exact_run run_id -> Some run_id in
    let index = Option.bind selected_id (fun run_id ->
      List.find_index (fun (run : Masc.Keeper_skill_composition_evidence.run_summary) ->
        Masc.Keeper_tool_plan.Composition_run_id.equal run_id run.run_id) runs) in
    [Ansi.bold, Printf.sprintf "     Original runs: %s/%d · [: older · ]: newer · Enter: latest"
       (Option.fold ~none:"—" ~some:(fun index -> string_of_int (index + 1)) index) (List.length runs);
     Ansi.dim, "       Each run's latest retained result; earlier transitions may be replaced"]
    @ (match evidence.se_composition_selection, index with
       | Exact_run run_id, None ->
         [Theme.warn (), "       Requested run absent in this revision's retained coverage: "
           ^ Masc.Keeper_tool_plan.Composition_run_id.to_string run_id;
          Ansi.dim, "       No other run substituted; statistics still cover all retained runs"]
       | Latest_retained, (None | Some _) | Exact_run _, Some _ -> [])
    @ List.filter_map (fun (label, delta) ->
        adjacent_skill_evidence_run state ~reference:evidence.se_reference
          ~selection:evidence.se_composition_selection ~runs:evidence.se_composition_runs ~delta
        |> Option.map (fun run_id ->
          Ansi.dim, "       " ^ label ^ ": " ^ Masc.Keeper_tool_plan.Composition_run_id.to_string run_id))
        ["older", 1; "newer", -1]
;;

let request_selection_prefix = "Request: "

let skill_selection_prefix state =
  Printf.sprintf "Skill %d/%d: " (state.tools_skill_cursor + 1)
    (List.length (tools_skill_profiles state))

let tools_selection_line ~cols state =
  match state.tools_skill_source_picker with
  | Some picker -> Printf.sprintf "New %s · choose a save location"
      (if picker.ssp_composition then "Composition" else "Instruction")
  | None when Option.is_some (tools_volume_gc_parent_scroll state.tools_pane) ->
      ui_text state ~ko:"은퇴한 Keeper의 볼륨" ~en:"Retired Keeper volumes"
  | None when state.tools_pane = Tools_storage ->
      ui_text state ~ko:"호스트 디스크와 Keeper 저장 공간 정리" ~en:"Host disk and Keeper storage cleanup"
  | None ->
  if state.tools_pane=Tools_async then
    (match state.tools_async_selection with
     | None -> "Async request: none"
     | Some target -> Masc_tui_message_layout.fit_middle
         (Masc_tui_frame.inner_width ~cols)
         (request_selection_prefix ^ Terminal_text.single_line target.request_id))
  else
  let text = match selected_tools_skill_profile state with
    | None -> "Skill: none"
    | Some profile ->
        let prefix = skill_selection_prefix state in
        prefix ^ Masc_tui_message_layout.fit_middle
          (max 1 (Masc_tui_frame.inner_width ~cols
                  - Masc_tui_message_layout.display_width prefix))
          (Terminal_text.single_line profile.esp_name)
  in
  text

(* The selection row above the document cuts the middle of a name that does
   not fit the row. The document names the selection again only then, so a
   name that fits is on screen once and a cut name can still be read whole. *)
let tools_selection_document ~cols state =
  let named_again ~selection_row ~title =
    if Masc_tui_message_layout.display_width selection_row
       > Masc_tui_frame.inner_width ~cols
    then [title] else [] in
  if state.tools_pane=Tools_async then
    (match state.tools_async_selection with
     | None -> []
     | Some target ->
         let request_id = Terminal_text.single_line target.request_id in
         named_again ~selection_row:(request_selection_prefix ^ request_id)
           ~title:(Ansi.bold, " 요청: " ^ request_id)
         @ [Ansi.dim," 원래 요청자: " ^ Terminal_text.single_line target.submitted_by
              ^ " · 대상 Keeper: " ^ Terminal_text.single_line target.keeper_name])
  else
  match selected_tools_skill_profile state with
  | None -> []
  | Some profile ->
      let reference = profile.esp_reference in
      let name = Terminal_text.single_line profile.esp_name in
      named_again ~selection_row:(skill_selection_prefix state ^ name)
        ~title:(Ansi.bold, "Action Skill: " ^ name)
      @ [ Ansi.dim, "Source: " ^ Terminal_text.single_line
            (Skill_reference.identity_source_id_to_string reference.identity)
        ; Ansi.dim, "Package: " ^ Terminal_text.single_line
            (Skill_reference.identity_package_id_to_string reference.identity)
        ; Ansi.dim, "Revision: " ^ Masc_tui_value.Hash.short (Terminal_text.single_line
            (Skill_reference.content_revision_to_string reference.content_revision))
        ]

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
      [ Printf.sprintf "runtime=%s  client=%s  native=%s"
          (Terminal_text.single_line ets_runtime_id)
          (Terminal_text.single_line ets_official_client_kind)
          (Option.value ~default:"n/a" ets_native_posture)
      ; "skill snapshot=" ^ hash (Terminal_text.single_line ets_skill_snapshot_revision)
      ; "deferred resource bound="
        ^ (match ets_skill_resource_read_max_bytes with
           | Some max_bytes -> Printf.sprintf "%d bytes" max_bytes
           | None -> "not configured")
      ; Printf.sprintf
          "Skill context: profile discovery=%dB · deferred bodies=%s · skill tool schema=%s/%s all tools"
          ets_skill_discovery_bytes
          (byte_count ets_skill_body_bytes)
          (byte_count ets_skill_tool_surface_bytes)
          (byte_count ets_tool_surface_bytes)
      ; "digest="
        ^ (match ets_tool_surface_sha256 with
           | None -> "n/a (Agent Core owns the turn)"
           | Some value -> hash (Terminal_text.single_line value)) ]

let tools_diagnostics_copy_text (state : state) =
  match state.tools_inventory with
  | None | Some { Masc.Tui_decode_tools.ts_effective = None; _ } -> None
  | Some { Masc.Tui_decode_tools.ts_effective = Some surface; _ } ->
      (match surface with
       | Masc.Tui_decode_tools.Effective_surface_unavailable _ -> None
       | Masc.Tui_decode_tools.Effective_surface_available { ets_keeper_name; _ } ->
           let skill =
             match selected_tools_skill_profile state with
             | None -> []
             | Some profile ->
                 let reference = profile.esp_reference in
                 [ "Skill: " ^ Terminal_text.single_line profile.esp_name
                 ; "Source: " ^ Terminal_text.single_line
                     (Skill_reference.identity_source_id_to_string reference.identity)
                 ; "Package: " ^ Terminal_text.single_line
                     (Skill_reference.identity_package_id_to_string reference.identity)
                 ; "Revision: " ^ Terminal_text.single_line
                     (Skill_reference.content_revision_to_string reference.content_revision) ]
           in
           Some
             (String.concat "\n"
                (("Keeper: " ^ Terminal_text.single_line ets_keeper_name)
                 :: effective_surface_diagnostics ~hash:Fun.id surface
                 @ skill)))

let skill_source_picker_prefix summary =
  [ Ansi.bold, " Choose the writable source for this package"
  ; Ansi.dim, " j/k or arrows: select · Enter: edit · /:filter · Esc:cancel"
  ; Ansi.dim, " " ^ Terminal_text.single_line summary ]

let skill_source_picker_page state ~terminal_rows =
  max 1 (tools_content_rows state ~terminal_rows ~count:0
    - List.length (skill_source_picker_prefix ""))

let tools_display_lines ?(cols = 80) ?terminal_rows (state : state) =
  match state.tools_skill_source_picker with
  | Some picker ->
    let terminal_rows = match terminal_rows with Some rows -> rows | None -> fst (get_terminal_size ()) in
    let view = Masc_tui_pick_list.view ~page:(skill_source_picker_page state ~terminal_rows)
      ~window:Masc_tui_pick_list.Opens_at_cursor ~label:Fun.id picker.ssp_sources picker.ssp_list in
    skill_source_picker_prefix (Masc_tui_pick_list.summary ~ko:(state.ui_language = Lang_ko) view)
    @ (if view.rows = [] then [Theme.warn (), " No matching source"] else
        List.mapi (fun index source ->
          (if view.selected_row = Some index then Theme.selection else Ansi.dim),
          " " ^ Terminal_text.single_line source) view.rows)
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
        [ ( (if Option.is_some (selected_tools_error state) then Theme.bad () else Theme.warn ())
          , " Effective Keeper Surface " ^ title_missing_reading ~ko:(state.ui_language = Lang_ko)
                ~error:(selected_tools_error state) )
        ]
    | Some { Masc.Tui_decode_tools.ts_effective = None; _ } ->
        [ (Theme.warn ()), " Effective Keeper Surface — no Keeper selected" ]
    | Some
        { Masc.Tui_decode_tools.ts_effective =
            Some
              (Masc.Tui_decode_tools.Effective_surface_unavailable
                 { ets_keeper_name; ets_reason; ets_detail });
          _ } ->
        [ (Theme.bad ()),
          Printf.sprintf " Effective Keeper Surface — %s — unavailable (%s)"
            (Terminal_text.single_line ets_keeper_name)
            (Terminal_text.single_line ets_reason);
          (Theme.bad ()), "   " ^ Terminal_text.single_line ets_detail ]
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
          | Masc.Tui_decode_tools.Effective_tools_delivered -> Ansi.dim, "지원"
          | Masc.Tui_decode_tools.Effective_tools_suppressed_runtime_unsupported ->
            Theme.warn (), "미지원으로 제외"
        in
        (* Folded under one heading by default (RFC tui-one-screen-grammar,
           section 5.1): these rows sat above the Skill list, two of them a
           64-character digest each. *)
        let diagnostics_lines =
          let folded = state.tools_diagnostics_folded in
          ( Ansi.dim,
            Printf.sprintf "   %s %s · %s %s · Y %s"
              (if folded then "▸" else "▾")
              (ui_text state ~ko:"진단" ~en:"Diagnostics")
              Masc_tui_keys.expand_turn_label
              (if folded then ui_text state ~ko:"펴기" ~en:"unfold"
               else ui_text state ~ko:"접기" ~en:"fold")
              (ui_text state ~ko:"전체 복사" ~en:"copy all") )
          :: (if folded then []
              else
                List.map (fun line -> Ansi.dim, "     " ^ line)
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
        let skill_profile_lines =
          List.mapi
            (fun index (profile : Masc.Tui_decode_tools.effective_skill_profile) ->
               let instruction = is_normal profile in
               let execution =
                 if instruction then "on-demand" else profile.esp_execution
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
                      | Masc.Tui_decode_tools.Skill_keeper_profile -> Some "Keeper profile"
                      | Masc.Tui_decode_tools.Skill_task task_id -> Some ("Task " ^ task_id))
               in
               let heading =
                 let first_in_group = index = 0 ||
                   (match List.nth_opt ets_skill_profiles (index - 1) with
                    | None -> true
                    | Some previous -> is_normal previous <> instruction) in
                 if not first_in_group then [] else
                   [Ansi.bold, Printf.sprintf "   %s (%d)"
                     (if instruction then "Normal Skills · instructions" else "Composition Skills · executable plans")
                     (List.length (List.filter (fun value -> is_normal value = instruction) ets_skill_profiles))] in
               heading @ [ ( (if index = state.tools_skill_cursor
                  then Theme.selection
                  else Ansi.dim)
               , Printf.sprintf " %s %-22s %-11s%s discovery=%dB body=%dB"
                   (if index = state.tools_skill_cursor then Masc_tui_theme.Glyph.current_entry else " ")
                   (Terminal_text.single_line profile.esp_name)
                   (Terminal_text.single_line execution)
                   flow
                   profile.esp_discovery_bytes
                   profile.esp_body_bytes ) ]
               @ (match profile.esp_load_reasons, chosen with
                   | [], _ ->
                       [ ( Theme.warn ()
                         , "     why loaded: unattributed" ) ]
                   | _, [] -> []
                   | _, chosen ->
                       [ ( Ansi.dim
                         , "     why loaded: "
                           ^ Terminal_text.single_line (String.concat " + " chosen) )
                       ]))
            ets_skill_profiles
          |> List.concat
        in
        let selected_skill_flow_lines =
          match List.nth_opt ets_skill_profiles state.tools_skill_cursor with
          | None -> []
          | Some { Masc.Tui_decode_tools.esp_flow = None; _ } ->
            [ Ansi.dim, "     Flow: instruction body loads on demand; the model orchestrates tools" ]
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
                    | None -> "(not in nodes)", ""
                    | Some node ->
                      ( Terminal_text.single_line node.sfn_tool_name
                      , dependency_text node )
                  in
                  ( Ansi.dim
                  , Printf.sprintf "     %s %-12s %-18s %s%s" stem label
                      (Terminal_text.single_line node_id) tool dependencies ))
                |> fun lines ->
                if node_count = 0 then
                  [ ( Ansi.dim
                    , Printf.sprintf "     %s %d %s (no nodes)"
                        (if last_batch then "\xe2\x94\x94" else "\xe2\x94\x9c")
                        batch.sfb_index
                        (Terminal_text.single_line batch.sfb_execution_mode) )
                  ]
                else lines)
              |> List.concat
            in
            ( Ansi.bold
            , Printf.sprintf "     Declared graph · Ctrl-O:Pele · %d batches · %d nodes" batch_count
                (List.length flow.sf_nodes) )
            :: batch_lines
        in
        let selected_skill_statistics_lines, selected_skill_evidence_lines =
          match List.nth_opt ets_skill_profiles state.tools_skill_cursor with
          | None -> [], []
          | Some profile ->
            let key =
              Skill_reference.to_yojson profile.esp_reference |> Yojson.Safe.to_string
            in
            (match state.tools_skill_evidence with
             | Some (observed_key, json) when String.equal key observed_key ->
              (match Masc.Tui_decode_skill_evidence.decode_skill_evidence json with
               | Error _ ->
                 [ Theme.bad (), "실측 응답 형식 오류" ],
                 [ Theme.bad (), "     Retained evidence response is malformed" ]
               | Ok evidence ->
               let evidence_lines =
                 match evidence.Masc.Tui_decode_skill_evidence.se_status with
                 | Masc.Tui_decode_skill_evidence.Skill_evidence_not_observed_in_retained_coverage ->
                  [ Theme.warn (),
                    "     Retained evidence: not found in retained coverage (not proof of never)"
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
                           | Some `Null | None -> "invoked"
                           | Some _ -> "✓ delivered"
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
                           Printf.sprintf
                             "     Latest independent activation: %s · owner=%s(%s) · original-actions=%d · at=%s"
                             delivered
                             (Terminal_text.single_line item.sea_owner_status)
                             (Terminal_text.single_line keepers)
                             action_count
                             (Terminal_text.single_line (string_field "activated_at"))
                         ; Ansi.dim,
                           Printf.sprintf
                             "       trace %s · tool use %s%s"
                             (Terminal_text.single_line item.sea_trace_id)
                             (Terminal_text.single_line
                                (string_field "skill_tool_use_id"))
                             (if tied then " · equal-time candidate" else "")
                         ; Ansi.dim,
                           Printf.sprintf "       original %s · runtime %s"
                             (Terminal_text.single_line (string_field "turn_ref"))
                             (Terminal_text.single_line (string_field "runtime_id"))
                         ] @ skill_async_evidence_lines item.sea_async_evidence)
                      items
                  in
                  let composition_lines =
                    match evidence.se_composition with
                    | Some (`Assoc _ as composition) ->
                      (match json_assoc_member_opt "result" composition with
                       | Some (`Assoc _ as result) ->
                         let string_field name fallback =
                           match json_assoc_member_opt name composition with
                           | Some (`String value) -> value
                           | _ -> fallback
                         in
                         let duration =
                           match json_assoc_member_opt "duration_ms" result with
                           | Some (`Float value) -> Printf.sprintf "%.0fms" value
                           | Some (`Int value) -> Printf.sprintf "%dms" value
                           | Some _ | None -> Masc_tui_theme.Glyph.no_value
                         in
                         let success =
                           match json_assoc_member_opt "disposition" result with
                           | Some (`String "completed") -> "✓ completed"
                           | Some (`String "deferred") -> "◌ deferred"
                           | Some (`String "failed") -> "✗ failed"
                           | Some _ | None -> "unknown"
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
                           Printf.sprintf
                             "     Composition: %s · %s · keeper=%s · run=%s · settlements=%d"
                             success
                             duration
                             (Terminal_text.single_line
                                (string_field "keeper" Masc_tui_theme.Glyph.no_value))
                             (Terminal_text.single_line
                                (string_field "composition_run_id" Masc_tui_theme.Glyph.no_value))
                             settlement_count
                         ; Ansi.dim, Printf.sprintf "       recorded=%s · %s · request=%s"
                             (match json_assoc_member_opt "recorded_at" composition with
                              | Some (`Float value) ->
                                (try Time_codec.rfc3339_of_unix value with
                                 | Unix.Unix_error _ | Invalid_argument _ -> Printf.sprintf "%.3f Unix seconds" value)
                              | _ -> "unavailable")
                             (string_field "composition_execution" "unavailable")
                             (Terminal_text.single_line (string_field "request_id" "inline"))
                         ; Ansi.dim, Printf.sprintf "       parent tool use=%s · turn=%s · planned index=%s"
                             (Terminal_text.single_line (string_field "parent_tool_use_id" ""))
                             (match json_assoc_member_opt "parent_turn" composition with Some value -> Yojson.Safe.to_string value | None -> "unavailable")
                             (match json_assoc_member_opt "parent_planned_index" composition with Some value -> Yojson.Safe.to_string value | None -> "unavailable")
                         ]
                         @ (match json_assoc_member_opt "disposition" result with
                            | Some (`String "failed") ->
                              let field name = match json_assoc_member_opt name result with
                                | Some (`String value) -> Terminal_text.single_line value
                                | _ -> "unavailable" in
                              [ Theme.bad (), "       " ^ field "message"
                              ; Ansi.dim, "       failure class=" ^ field "failure_class"
                                ^ " · effect evidence=" ^ field "effect_disposition" ]
                            | _ -> [])
                         @ (match json_assoc_member_opt "data" result with
                            | Some output ->
                              (Ansi.bold, "       Final result data")
                              :: cached_skill_json skill_final_result_projection ~cols
                                   ~render:(skill_json_lines ~cols ~indent:9) output
                            | None -> [Ansi.dim, "       no output"])
                       | Some _ | None ->
                         [ Theme.bad (), "     Composition evidence is malformed" ])
                    | None -> []
                    | Some _ -> [ Theme.bad (), "     Composition evidence is malformed" ]
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
                     Printf.sprintf
                       "       coverage retained_sessions=%d ledgers=%d activation=%s gaps=%d owner_gaps=%d exact_reference=%s runs_observed=%d"
                       coverage.sec_activation_sessions_inspected
                       coverage.sec_activation_ledgers_loaded
                       coverage.sec_activation_scope
                       coverage.sec_activation_gap_count
                       coverage.sec_activation_owner_gap_count
                       composition_scope
                       coverage.sec_composition_runs_observed
                   ]
                   @
                   (match unavailable with
                    | [] -> []
                    | values ->
                      [ Theme.warn (),
                        "       composition unavailable: " ^ String.concat " · " values
                      ])
               in
               let statistics_lines = match profile.esp_io with
                 | Masc.Tui_decode_tools.Model_orchestrated -> []
                 | Composition_io _ -> skill_statistics_lines ~cols evidence.se_composition_statistics in
               statistics_lines, skill_run_history_lines state evidence @ evidence_lines
               @ Option.fold ~none:[] ~some:(skill_settlement_lines ~cols) evidence.se_composition
               @ coverage_lines)
             | Some _ | None ->
               [ Ansi.dim, "Enter: 선택 revision 실측 불러오기 · f: 다음 Composition 실측" ],
               [ Ansi.dim, "     Retained evidence: Enter to load this exact revision" ])
        in
        let performance_card =
          match selected_tools_skill_profile state with
          | None -> []
          | Some profile ->
            let rows = match profile.esp_io with
              | Masc.Tui_decode_tools.Model_orchestrated ->
                  [ Ansi.dim, "Normal Skill · 지침 텍스트에는 executor 실행 시간이 없습니다"
                  ; Theme.info (), "f: Composition 선택 + 실측 불러오기 · J/K: Skill 선택" ]
              | Composition_io _ -> selected_skill_statistics_lines in
            let pending = match state.tools_evidence_reference, state.tools_evidence_request with
              | Some reference, Some _ when Skill_reference.equal reference profile.esp_reference ->
                  [ Theme.info (), "실측 조회 중 · 이전 관측이 있으면 함께 표시합니다" ]
              | Some _, Some _ | Some _, None | None, Some _ | None, None -> [] in
            skill_usage_box ~cols
              ((Ansi.bold, "SKILL PERFORMANCE · " ^ Terminal_text.single_line profile.esp_name)
               :: pending @ rows)
        in
        [ Ansi.bold,
          Printf.sprintf " Effective Keeper Surface — %s (%s)"
            (Terminal_text.single_line ets_keeper_name)
            (Masc_tui_message_layout.count_noun (List.length ets_tools) "tool") ]
        @ performance_card
        @ [ delivery_tone, "   Runtime 도구 전달: " ^ delivery ]
        @ diagnostics_lines
        @ [ Ansi.bold,
            "   Skills — J/K select · Enter latest · [/] runs · Ctrl-O graph · e edit · c/C create" ]
        @ skill_profile_lines
        @ (match selected_tools_skill_profile state with
           | None -> [] | Some profile -> skill_io_lines ~cols profile.esp_io)
        @ selected_skill_flow_lines
        @ (match state.tools_evidence_reference, state.tools_evidence_request, selected_tools_skill_profile state with
           | Some reference, Some _, Some profile when Skill_reference.equal reference profile.esp_reference ->
               [Ansi.dim, "     Loading requested run "
                 ^ Option.fold ~none:"latest" ~some:Masc.Keeper_tool_plan.Composition_run_id.to_string state.tools_evidence_run_id
                 ^ " · previous observation retained"]
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
               Printf.sprintf "   %d skill(s) left out of the catalog"
                 (List.length left_out) )
             :: List.map
                  (fun entry ->
                    (Theme.warn ()),
                    "     " ^ Terminal_text.single_line entry)
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
               Printf.sprintf "   %d configured skill name(s) not in the turn catalog"
                 (List.length unavailable) )
             :: List.map
                  (fun { Masc.Tui_decode_tools.csn_name; csn_reason } ->
                    (Theme.warn ()),
                    "     "
                    ^ Terminal_text.single_line csn_name
                    ^ " \xc2\xb7 "
                    ^ Terminal_text.single_line csn_reason)
                  unavailable)
        @ [ Ansi.bold, Tool_table.effective_tool_header ]
        @ tool_lines
    end
  in
  let activation_reading_lines =
    lazy begin
    match state.tools_activations with
    | None ->
        (match state.tools_activations_error with
         | None -> [ Theme.warn (), " Skill Activations — not loaded" ]
         | Some _ -> [ Theme.warn (), " Skill Activations — unavailable (no reading)" ])
    | Some Masc_tui_types.Activations_no_keeper ->
        [ Theme.warn (), " Skill Activations — no Keeper selected" ]
    | Some
        (Masc_tui_types.Activations_read
           (Masc.Tui_decode_tools.Skill_activations_no_session
              { sap_keeper_name })) ->
        [ Theme.warn (),
          Printf.sprintf " Skill Activations — %s — no session"
            (Terminal_text.single_line sap_keeper_name) ]
    | Some
        (Masc_tui_types.Activations_read
           (Masc.Tui_decode_tools.Skill_activations_unavailable
              { sap_keeper_name; sap_reason; sap_detail })) ->
        [ Theme.bad (),
          Printf.sprintf " Skill Activations — %s — unavailable (%s)"
            (Terminal_text.single_line sap_keeper_name)
            (Terminal_text.single_line sap_reason);
          Theme.bad (), "   " ^ Terminal_text.single_line sap_detail ]
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
        let scoped_lines =
          List.concat_map
            (fun (scoped : Masc.Keeper_skill_activation_ledger.scoped_summary) ->
               let scoped_summary = scoped.summary in
               let runtime_counts values =
                 match values with
                 | [] -> "none"
                 | values ->
                   values
                   |> List.map
                        (fun (item : Masc.Keeper_skill_activation_ledger.runtime_count) ->
                           Printf.sprintf "%s:%d" item.runtime_id item.count)
                   |> String.concat ","
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
                 Printf.sprintf "   %s%s \xc2\xb7 rev %s" name
                   (* A skill is usually named after the package that holds
                      it, and "work-intake · work-intake" says it twice. *)
                   (if String.equal name package then ""
                    else " \xc2\xb7 " ^ package)
                   (Skill_reference.content_revision_to_string
                      scoped.scope.reference.content_revision
                    |> Terminal_text.single_line)
               ; Ansi.dim,
                 Printf.sprintf "     turn %s \xc2\xb7 %s \xc2\xb7 snapshot %s"
                   (Ids.Turn_ref.to_string scoped.scope.turn_ref
                    |> Terminal_text.single_line)
                   (Terminal_text.single_line
                      scoped.scope.invocation_runtime_id)
                   (Skill_catalog_snapshot.snapshot_revision_to_string
                      scoped.scope.snapshot_revision
                    |> Terminal_text.single_line)
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
                         , Printf.sprintf
                             "     %-11s triggered %d \xc2\xb7 delivered %d \xc2\xb7 handed off %d \xc2\xb7 actions %d"
                             kind invoked delivered handoffs actions ))
                   [ ( "instruction"
                     , scoped_summary.instruction_invocations
                     , scoped_summary.instruction_provider_deliveries
                     , scoped_summary.instruction_official_client_handoffs
                     , scoped_summary.instruction_actions_observed )
                   ; ( "composition"
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
                      , Printf.sprintf "     served %d bodies \xc2\xb7 %d resources"
                          scoped_summary.skill_bodies_served
                          scoped_summary.skill_resources_served )
                    ])
               @ (if scoped_summary.invalid_transitions = 0 then []
                  else
                    [ ( Theme.warn ()
                      , Printf.sprintf "     %d invalid transition(s)"
                          scoped_summary.invalid_transitions )
                    ])
               @ (let runtimes =
                    List.filter
                      (fun (_, counts) -> counts <> [])
                      [ "delivered", scoped.provider_delivery_runtime_counts
                      ; "handed off", scoped.official_client_handoff_runtime_counts
                      ; "actions", scoped.action_runtime_counts
                      ]
                  in
                  match runtimes with
                  | [] -> []
                  | runtimes ->
                      [ ( Ansi.dim
                        , "     runtimes \xc2\xb7 "
                          ^ String.concat " \xc2\xb7 "
                              (List.map
                                 (fun (label, counts) ->
                                   label ^ " " ^ runtime_counts counts)
                                 runtimes) )
                      ]))
            scoped_summaries
        in
        let receipt_lines =
          List.concat_map
            (fun (activation : Masc.Keeper_skill_activation_ledger.activation) ->
               let origin, served = skill_invocation_text activation.invocation in
               [ Ansi.dim,
                 "   begin id="
                 ^ Terminal_text.single_line activation.skill_tool_use_id
               ; Ansi.dim,
                 "   receipt_sha256="
                 ^ Masc.Keeper_skill_activation_ledger.receipt_projection_revision
                     sap_ledger
                     ~skill_tool_use_id:activation.skill_tool_use_id
               ; Ansi.dim,
                 "   exact source_id="
                 ^ (activation.identity
                    |> Skill_reference.identity_source_id_to_string
                    |> Terminal_text.single_line)
               ; Ansi.dim,
                 "     package_id="
                 ^ (activation.identity
                    |> Skill_reference.identity_package_id_to_string
                    |> Terminal_text.single_line)
               ; Ansi.dim,
                 "     name="
                 ^ Terminal_text.single_line activation.identity.name
               ; Ansi.dim,
                 "     content_revision="
                 ^ (activation.content_revision
                    |> Skill_reference.content_revision_to_string
                    |> Terminal_text.single_line)
               ; Ansi.dim,
                 Printf.sprintf
                   "     invoked turn=%d id=%s runtime=%s at=%s"
                   activation.agent_core_turn
                   (Terminal_text.single_line activation.skill_tool_use_id)
                   (Terminal_text.single_line activation.runtime_id)
                   (Terminal_text.single_line activation.activated_at)
               ; Ansi.dim,
                 "       served "
                 ^ Terminal_text.single_line served
               ; Ansi.dim,
                 "       delivered "
                 ^ (skill_delivery_text
                      ~has_action:(not (List.is_empty activation.actions))
                      activation.delivery
                    |> Terminal_text.single_line)
               ; Ansi.dim,
                 Printf.sprintf "       snapshot=%s keeper_turn=%s origin=%s"
                   (Skill_catalog_snapshot.snapshot_revision_to_string
                      activation.snapshot_revision
                    |> Terminal_text.single_line)
                   (Ids.Turn_ref.to_string activation.turn_ref
                    |> Terminal_text.single_line)
                   (Terminal_text.single_line origin)
               ]
               @ skill_action_lines activation.actions
               @ [ Ansi.dim,
                   "       end id="
                   ^ Terminal_text.single_line activation.skill_tool_use_id
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
                        Printf.sprintf
                          (* The same unit the Context inspector reads sizes
                             in, an estimated token figure, beside the bytes
                             it was read from: this screen has no turn
                             record to take a scale from, and the timeline
                             header says it reads at the fleet figure. *)
                          "%-8s delivery  %-20s \xe2\x89\x88%6s tok %9s turn#%d %s"
                          (time_of delivery.delivered_at)
                          skill
                          (Masc_tui_context_inspector.format_tokens
                             (Masc_tui_token_scale.estimate
                                Masc_tui_token_scale.fleet
                                delivery.content_bytes))
                          (Masc_tui_context_inspector.format_bytes
                             delivery.content_bytes)
                          activation.agent_core_turn
                          (Terminal_text.single_line delivery.runtime_id) ) ]
                  | None -> [])
                 @ List.map
                     (fun (act :
                             Masc.Keeper_skill_activation_ledger.action) ->
                        ( act.observed_at,
                          Printf.sprintf "%-8s action    %-20s turn#%d %s"
                            (time_of act.observed_at)
                            (Terminal_text.single_line
                               (Masc.Tool_display.list_label act.tool_name))
                            act.agent_core_turn
                            (Terminal_text.single_line act.runtime_id) ))
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
            Printf.sprintf " Skill Timeline — %d event%s (newest first)"
              total
              (if total = 1 then "" else "s")
          ; Ansi.dim, "   " ^ Masc_tui_token_scale.note Masc_tui_token_scale.fleet ]
          @ List.map (fun (_, line) -> (Ansi.dim, "   " ^ line)) capped
        in
        [ Ansi.bold,
          Printf.sprintf " Skill Use — %s (%d receipts)"
            (Terminal_text.single_line sap_keeper_name)
            (List.length sap_activations)
        ; Ansi.dim,
          Printf.sprintf
            "   this session \xc2\xb7 %-11s triggered %d \xc2\xb7 delivered %d \xc2\xb7 handed off %d \xc2\xb7 actions %d"
            "instruction"
            summary.instruction_invocations
            summary.instruction_provider_deliveries
            summary.instruction_official_client_handoffs
            summary.instruction_actions_observed
        ; Ansi.dim,
          Printf.sprintf
            "                %-11s triggered %d \xc2\xb7 delivered %d \xc2\xb7 handed off %d \xc2\xb7 actions %d"
            "composition"
            summary.composition_invocations
            summary.composition_provider_deliveries
            summary.composition_official_client_handoffs
            summary.composition_actions_observed
        ; Ansi.dim,
          Printf.sprintf "                served %d bodies \xc2\xb7 %d resources"
            summary.skill_bodies_served
            summary.skill_resources_served
        ; Ansi.dim,
          Printf.sprintf "   session=%s  ledger=%s"
            (Masc.Keeper_skill_activation_ledger.session_id sap_ledger
             |> Keeper_id.Trace_id.to_string
             |> Terminal_text.single_line)
            (Masc.Keeper_skill_activation_ledger.revision sap_ledger
             |> Masc.Keeper_skill_activation_ledger.ledger_revision_to_string
             |> Terminal_text.single_line)
        ; Ansi.dim,
          "   workspace="
          ^ (Masc.Keeper_skill_activation_ledger.workspace_key sap_ledger
             |> Terminal_text.single_line)
        ]
        @ (if summary.invalid_transitions = 0 then []
           else
             [ ( Theme.warn ()
               , Printf.sprintf "                %d invalid transition(s)"
                   summary.invalid_transitions )
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
      (match state.tools_activations_error with
       | None -> []
       | Some { taf_detail; _ } ->
           [ Theme.bad (), " Skill activations read failed: " ^ Terminal_text.single_line taf_detail ])
      @ Lazy.force activation_reading_lines
    end
  in
  let catalog_lines =
    lazy begin
    match state.tools_inventory with
    | None ->
        [ Theme.warn (),
          ui_text state
            ~ko:" 전체 등록 도구 — 조회 자료 없음"
            ~en:" All registered tools — no inventory reading" ]
    | Some { Masc.Tui_decode_tools.ts_usage; _ } ->
    let registered_rows = Tool_tree.rows registered_tools in
    let surfaces_text (tool : Masc.Tui_decode_tools.tool_entry) =
      Terminal_text.single_line
        (match tool.tl_surfaces with
         | [] -> "none"
         | names -> String.concat ", " names)
    in
    let layout =
      Tool_table.catalog_layout ~width:(Masc_tui_frame.inner_width ~cols)
        ~surfaces_cells:
          (List.fold_left
             (fun widest tool ->
               max widest
                 (Masc_tui_message_layout.display_width (surfaces_text tool)))
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
    let heading =
      let count = List.length registered_tools in
      [ Ansi.bold,
        ui_text state
          ~ko:(Printf.sprintf " 전체 등록 도구 — %d개" count)
          ~en:(Printf.sprintf " All registered tools — %s"
                 (Masc_tui_message_layout.count_noun count "tool"));
        Ansi.dim, Tool_table.catalog_tool_header layout ]
    in
    heading
    @ List.map
        (function
          | Tool_tree.Domain { name; count } ->
              ( Ansi.bold,
                Printf.sprintf " %s (%d) %s"
                  (Terminal_text.single_line name) count tool_domain_rule )
          | Tool_tree.Family { name; count } ->
              Ansi.bold,
              Printf.sprintf "    %s (%d)" (Terminal_text.single_line name) count
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
              ( "",
                Tool_table.catalog_tool_line layout ~metadata
                  ~name:(Terminal_text.single_line (Masc.Tool_display.list_label tool.tl_name))
                  ~direct:(if tool.tl_direct_call then "yes" else "no")
                  ~usage:(usage_of tool.tl_name)
                  ~surfaces:(surfaces_text tool) ))
        registered_rows
    end
  in
  let usage_matrix_lines =
    lazy begin
    let error_lines =
      match state.skills_catalog_error with
      | None -> []
      | Some error ->
          [ Theme.bad (), " " ^ Terminal_text.single_line error ]
          @ (match state.skills_catalog with
             | None -> []
             | Some _ -> [ Theme.warn (), " Previous catalog reading retained" ])
    in
    let reading_lines =
    match state.skills_catalog with
    | None ->
        [ Ansi.dim,
          (match state.skills_catalog_error with
           | None -> " Skill Usage — no workspace catalog reading"
           | Some _ -> " Skill Usage — unavailable (no catalog reading)") ]
    | Some { Masc.Tui_decode_tools.sc_state; _ }
      when sc_state <> Masc.Tui_decode_tools.Skills_ready ->
        [ Ansi.dim,
          Printf.sprintf " Skill Usage — catalog %s"
            (Terminal_text.single_line
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
                   false, true, Some (Printf.sprintf "%s (%s)" kua_reason kua_detail)
                 | None -> false, true, None
               in
               let note =
                 match failure, answer_note with
                 | None, None -> None
                 | None, Some note -> Some (Printf.sprintf "Unavailable: %s: %s" keeper note)
                 | Some detail, None when counted ->
                   Some (Printf.sprintf "Read failed, counts from the earlier answer: %s: %s" keeper detail)
                 | Some detail, None -> Some (Printf.sprintf "Read failed: %s: %s" keeper detail)
                 | Some detail, Some note ->
                   Some (Printf.sprintf "Read failed: %s: %s; earlier answer: %s" keeper detail note)
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
        let coverage_lines =
          match state.keepers, state.tools_keeper_usage with
          | [], [] ->
              if Masc_tui_types.roster_complete state
              then [ Ansi.dim, "No Keepers in the roster." ]
              else []
          | _ :: _, [] -> [ Theme.warn (), "Activation ledger coverage: not read yet; totals may be partial." ]
          | ([] | _ :: _), _ :: _ ->
              ( Ansi.dim,
                Printf.sprintf "Activation ledgers loaded: %d; unavailable: %d%s"
                  ledgers_read excluded
                  (if earlier > 0 then Printf.sprintf "; %d from an earlier read" earlier else "") )
              :: (if excluded > 0
                  then [Theme.warn (), "Partial totals: unavailable ledgers are excluded."]
                  else [])
              @ (if earlier > 0
                 then [Theme.warn (), "Some totals come from an earlier read."]
                 else [])
        in
        (* The ledgers read are the roster's Keepers; a roster not read yet,
           or read with an error, may list only some of them. *)
        let roster_lines =
          match state.keepers_error, state.local_keepers with
          | Some detail, (Local_workspace_unread | Local_workspace_read | Local_workspace_failed _)
          | None, Local_workspace_failed detail ->
              [ Theme.warn (),
                "Keeper roster read failed: " ^ Terminal_text.single_line detail
                ^ "; totals cover only the Keepers listed." ]
          | None, Local_workspace_unread -> [ Ansi.dim, "Keeper roster not read yet." ]
          | None, Local_workspace_read -> []
        in
        let heading = skill_usage_box ~cols
          ([ Ansi.bold,
             Printf.sprintf "Skill Usage — %d of %d catalog Skills observed"
               (List.length used) (List.length sc_surfaces)
           ; Theme.info (), Printf.sprintf "Keepers %d · TRIGGERED %d · DELIVERED %d · ACTIONS %d"
               keepers (invocations all_usage) (deliveries all_usage) (actions all_usage)
           ; Ansi.dim, "Scope: exact Skill revisions in current Keeper sessions · deliveries include async handoffs"
           ; Ansi.dim, "ACTIONS: counted per Skill invocation; several invocations may share one tool call"
           ; Ansi.dim, Printf.sprintf "%d without retained invocation; this does not establish never used."
               (List.length sc_surfaces - List.length used)
           ] @ coverage_lines @ roster_lines)
        in
        let rows = List.concat_map
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
            let fits line = Masc_tui_message_layout.display_width line
              <= Masc_tui_frame.inner_width ~cols - 4 in
            let table_mode = fits Tool_table.skill_usage_keeper_header
              && List.for_all (fun (_, _, line) -> fits line) keeper_readings in
            let keeper_rows = List.concat_map
              (fun ((keeper, (row : Masc.Tui_decode_tools.keeper_skill_usage_row)), last_used, line) ->
                  if table_mode then [Ansi.dim, line]
                  else [ Ansi.bold, Terminal_text.single_line keeper
                       ; Ansi.dim, Printf.sprintf "TRIGGERED %d · DELIVERED %d · ACTIONS %d"
                           row.ksu_invocations row.ksu_deliveries row.ksu_actions
                       ; Ansi.dim, "LAST USED " ^ last_used ]) keeper_readings
            in
            let flow_rows = match surface.scs_flow with
              | None -> []
              | Some flow ->
                  (match skill_flow_line flow with
                   | None -> [] | Some line -> [Ansi.dim, line])
                  @ skill_flow_detail_lines flow in
            skill_usage_box ~cols
              ([ Ansi.bold, Terminal_text.single_line (surface_name surface) ^ "  "
                   ^ Terminal_text.single_line surface.scs_kind
               ; Theme.info (), Printf.sprintf "TRIGGERED %d · DELIVERED %d · ACTIONS %d"
                   (invocations usage) (deliveries usage) (actions usage)
               ]
               @ (if table_mode
                  then [Ansi.dim, Tool_table.skill_usage_keeper_header] else [])
               @ keeper_rows @ flow_rows)) used
        in
        let outside_rows =
          match outside with
          | [] -> []
          | _ :: _ ->
              skill_usage_box ~cols
                (( Ansi.bold,
                   Printf.sprintf "Usage rows outside this catalog reading — %d" (List.length outside) )
                 :: List.concat_map
                      (fun (keeper, (row : Masc.Tui_decode_tools.keeper_skill_usage_row)) ->
                         [ ( Ansi.bold,
                             Terminal_text.single_line Skill_reference.(row.ksu_reference.identity.name)
                             ^ " · rev "
                             ^ Terminal_text.single_line
                                 (Skill_reference.content_revision_to_string
                                    row.ksu_reference.content_revision) )
                         ; ( Ansi.dim,
                             Printf.sprintf "%s · TRIGGERED %d · DELIVERED %d · ACTIONS %d · LAST USED %s"
                               (Terminal_text.single_line keeper) row.ksu_invocations row.ksu_deliveries
                               row.ksu_actions (Terminal_text.single_line row.ksu_last_used_at) )
                         ])
                      outside)
        in
        let unavailable_rows =
          List.map (fun note -> Theme.warn (), " " ^ Terminal_text.single_line note) notes
        in
        let rejection_rows =
          match sc_rejections with
          | [] -> []
          | rejections ->
            ( Ansi.bold,
              Printf.sprintf " Rejected Skill Sources — %d" (List.length rejections) )
            :: List.concat_map
                 (fun (rejection : Masc.Tui_decode_tools.skill_catalog_rejection) ->
                    let source =
                      rejection.scr_source_id
                      ^ "/"
                      ^ Option.value
                          ~default:"(invalid package)"
                          rejection.scr_package_id
                    in
                    let revision =
                      rejection.scr_content_revision
                      |> Option.map Terminal_text.single_line
                      |> Option.value ~default:"unavailable"
                    in
                    let diagnostics =
                      match rejection.scr_reason with
                      | Masc.Tui_decode_tools.Skill_document_rejected diagnostics ->
                        List.map
                          (fun (diagnostic : Masc.Tui_decode_tools.skill_rejection_diagnostic) ->
                             ( Theme.warn (),
                               Printf.sprintf
                                 "     %s: %s"
                                 (Masc.Tui_decode_tools.skill_diagnostic_code_to_string
                                    diagnostic.srd_diagnostic)
                                 (Terminal_text.single_line diagnostic.srd_message) ))
                          diagnostics
                      | Masc.Tui_decode_tools.Skill_document_unreadable ->
                        [ Theme.warn (), "     document_unreadable" ]
                      | Masc.Tui_decode_tools.Skill_exact_identity_duplicate ->
                        [ Theme.warn (), "     exact_identity_duplicate" ]
                      | Masc.Tui_decode_tools.Skill_invalid_package_id ->
                        [ Theme.warn (), "     invalid_package_id" ]
                    in
                    ( Theme.warn (),
                      Printf.sprintf
                        "   %s · %s"
                        (Terminal_text.single_line source)
                        (Terminal_text.single_line revision) )
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
              Printf.sprintf " Shadowed Skills — %d" (List.length shadows) )
            :: List.concat_map
                 (fun (shadow : Masc.Tui_decode_tools.skill_catalog_shadow) ->
                    [ ( Theme.warn (),
                        Printf.sprintf
                          "   %s \xc2\xb7 %s"
                          (Terminal_text.single_line
                             shadow.scsh_shadowed.Skill_reference.name)
                          (Terminal_text.single_line (identity_text shadow.scsh_shadowed)) )
                    ; ( Ansi.dim,
                        "     shadowed by "
                        ^ Terminal_text.single_line (identity_text shadow.scsh_winner) )
                    ])
                 shadows
        in
        heading @ rows @ outside_rows @ unavailable_rows
        @ skill_source_lines ~config:sc_config ~sources:sc_sources
        @ rejection_rows @ shadow_rows
    in
    error_lines @ reading_lines
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
        Tools_inventory_read, "tool inventory", Option.is_some state.tools_inventory,
        (selected_tools_error state)
    | Tools_activations ->
        Tools_activations_read, "Skill activations", Option.is_some state.tools_activations,
        Option.map (fun failure -> failure.taf_detail) state.tools_activations_error
    | Tools_usage ->
        Tools_catalog_read, "Skills catalog", Option.is_some state.skills_catalog,
        state.skills_catalog_error
    | Tools_async ->
        Tools_async_read, "async broker", Option.is_some state.tools_async_observation,
        state.tools_async_observation_error
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
        [ Theme.warn (), " Retrying " ^ source ^ " — previous failure retained" ]
    | true, true, None ->
        [ Ansi.dim, " Refreshing " ^ source ^ " — last reading retained" ]
    | true, false, None ->
        [ Ansi.dim, " Reading " ^ source ^ "…" ]
    | false, true, Some _ ->
        [ Theme.warn (), " Last " ^ source ^ " reading retained · r:refresh" ]
    | false, false, None ->
        [ Ansi.dim, " " ^ source ^ " not read · r:refresh" ]
    | false, true, None | false, false, Some _ -> []
  in
  let error_lines = match (selected_tools_error state) with
    | None -> []
    | Some detail -> [Theme.bad (), "Tools read failed: " ^ Terminal_text.single_line detail]
  in
  let width = max 1 (Masc_tui_frame.inner_width ~cols) in
  let wrap lines = List.concat_map (fun (style, text) ->
       (* Fitted tables and usage cards already own their alignment. Only
          overlong rows need physical wrapping; never render metadata as
          Markdown or shorten its identities to fit the frame. *)
       if Masc_tui_message_layout.display_width text <= width then [style, text]
       else Masc_tui_message_layout.wrap_words ~max_cells:width text
            |> List.map (fun line -> style, line)) lines in
  let drafts = List.map (fun draft -> Theme.warn (), Terminal_text.single_line
    (Printf.sprintf " Unpublished %s draft retained for %s · %s:resume in editor"
      (if draft.scd_composition then "Composition" else "Instruction") draft.scd_source_id
      (if draft.scd_composition then "C" else "c"))) (skill_create_drafts_for_current_workspace state) in
  let prefix=tools_selection_document ~cols state @ drafts @ reading_lines @ error_lines in
  if Option.is_some (tools_volume_gc_parent_scroll state.tools_pane) then
    wrap (pane_lines @ reading_lines @ error_lines)
  else if state.tools_pane = Tools_storage then
    (* No Skill is selected here, so the Skill heading stays out. *)
    wrap (reading_lines @ error_lines @ pane_lines)
  else if state.tools_pane=Tools_async && state.tools_async_detail_open && Option.is_some state.tools_async_task_source then
    wrap prefix @ pane_lines
  else wrap (prefix @ pane_lines)
;;
