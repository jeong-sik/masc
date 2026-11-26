open Masc_tui_core
open Masc_tui_protocol

module String_map = Map.Make (String)
module String_set = Set.Make (String)

type tool_result_fetch_params = {
  offset : int;
  max_bytes : int;
  source_id : string option;
}

type tool_result_page_error =
  | Page_continuation_failed of { reason : string; retryable : bool }
  | Page_source_changed of string

let tool_result_page_size = 16384
let max_tool_result_cache = 32

let is_binary_encoding enc =
  String.equal (String.lowercase_ascii (String.trim enc)) "base64"

type trace_section =
  | Trace_context
  | Trace_tool_calls
  | Trace_metrics_logs
  | Trace_runtime

type context_subtab =
  | Ctx_composition
  | Ctx_flow
  | Ctx_exact_input
  | Ctx_input_map
  | Ctx_response

type logs_subview =
  | Logs_metrics
  | Logs_sandbox

type github_login_session = {
  running : bool;
  device_url : string option;
  device_code : string option;
  output_lines : string list;
  error : string option;
}

let empty_github_login =
  {
    running = false;
    device_url = None;
    device_code = None;
    output_lines = [];
    error = None;
  }

type operator_note_writes =
  | No_note_writes
  | One_note_write
  | Overlapping_note_writes of int

type note_write_settlement = Isolated_note_write | Await_note_writes | Reread_note

type keeper_state = {
  trace_section : trace_section;
  runtime_trace_scroll_offset : int;
  turn_records : Wire_keeper_context.turn_records_page Observed.t;
  selected_turn_idx : int;
  subtab : context_subtab;
  provider_input : (string * Wire_keeper_context.provider_input_manifest) Observed.t;
  provider_input_auth_denied : bool;
  absent_provider_input_ref : string option;
  selected_part_idx : int;
  part_content :
    (string * int * Wire_keeper_context.provider_input_part_content) Observed.t;
  cache_outcome : (string * Keeper_cache_outcome_reading.reading) Observed.t;
  absent_cache_outcome_ref : string option;
  next_request : Wire_keeper_context.next_request_forecast Observed.t;
  next_request_absent : bool;
  turn_transcript : (string * Wire_keeper_context.turn_transcript) Observed.t;
  absent_transcript_ref : string option;
  call_evidence : (string * Wire_keeper_context.tool_call_entry list) Observed.t;
  call_evidence_auth_denied : bool;
  absent_call_evidence_ref : string option;
  turn_flow : (string * Wire_keeper_context.turn_flow) Observed.t;
  absent_turn_flow_ref : string option;
  checkpoints : Wire_keeper_context.keeper_checkpoints_inventory Observed.t;
  checkpoints_auth_denied : bool;
  checkpoints_absent : bool;
  last_purge_preview : Wire_keeper_context.checkpoint_purge_result option;
  operator_note : Wire_keeper_context.keeper_operator_note Observed.t;
  operator_note_absent : bool;
  operator_note_read_after : Clock.Mono.t;
  operator_note_writes : operator_note_writes;
  scroll_offset : int;
  tool_stats : Wire_keeper_context.keeper_tool_stats Observed.t;
  tool_stats_absent : bool;
  tool_calls : Wire_keeper_context.keeper_tool_calls_page Observed.t;
  tool_calls_auth_denied : bool;
  tool_calls_absent : bool;
  selected_call_idx : int;
  call_scroll_offset : int;
  call_detail_scroll_offset : int;
  tool_result : (string * Wire_keeper_context.tool_result_response) Observed.t;
  tool_results : Wire_keeper_context.tool_result_response Observed.t String_map.t;
  tool_result_cache_order : string list;
  tool_result_inflight : String_set.t;
  tool_result_page_errors : tool_result_page_error String_map.t;
  tool_result_auth_denied : bool;
  metrics : Wire_keeper_context.keeper_metrics_snapshot Observed.t;
  sandbox_logs : Wire_keeper_context.keeper_sandbox_logs Observed.t;
  logs_subview : logs_subview;
  logs_scroll_offset : int;
  oauth_attached : Wire_keeper_context.oauth_attached_tools_snapshot Observed.t;
  oauth_auth_denied : bool;
  oauth_pending_login : Wire_keeper_context.oauth_login_result option;
  oauth_attempt_status : Wire_keeper_context.oauth_attempt_status option;
  oauth_last_poll_ns : int64 option;
  oauth_poll_started_ns : int64 option;
  oauth_poll_consecutive_errors : int;
  github_identity : Wire_keeper_context.github_identity_observation Observed.t;
  github_auth_denied : bool;
  github_login : github_login_session;
  identity_selected_idx : int;
  identity_scroll_offset : int;
}

type t = {
  by_keeper : keeper_state String_map.t;
  oauth_providers : Wire_keeper_context.oauth_providers_snapshot Observed.t;
}

let empty_keeper_state =
  {
    trace_section = Trace_context;
    runtime_trace_scroll_offset = 0;
    turn_records = Observed.unreported;
    selected_turn_idx = 0;
    subtab = Ctx_composition;
    provider_input = Observed.unreported;
    provider_input_auth_denied = false;
    absent_provider_input_ref = None;
    selected_part_idx = 0;
    part_content = Observed.unreported;
    cache_outcome = Observed.unreported;
    absent_cache_outcome_ref = None;
    next_request = Observed.unreported;
    next_request_absent = false;
    turn_transcript = Observed.unreported;
    absent_transcript_ref = None;
    call_evidence = Observed.unreported;
    call_evidence_auth_denied = false;
    absent_call_evidence_ref = None;
    turn_flow = Observed.unreported;
    absent_turn_flow_ref = None;
    checkpoints = Observed.unreported;
    checkpoints_auth_denied = false;
    checkpoints_absent = false;
    last_purge_preview = None;
    operator_note = Observed.unreported;
    operator_note_absent = false;
    operator_note_read_after = Clock.Mono.zero;
    operator_note_writes = No_note_writes;
    scroll_offset = 0;
    tool_stats = Observed.unreported;
    tool_stats_absent = false;
    tool_calls = Observed.unreported;
    tool_calls_auth_denied = false;
    tool_calls_absent = false;
    selected_call_idx = 0;
    call_scroll_offset = 0;
    call_detail_scroll_offset = 0;
    tool_result = Observed.unreported;
    tool_results = String_map.empty;
    tool_result_cache_order = [];
    tool_result_inflight = String_set.empty;
    tool_result_page_errors = String_map.empty;
    tool_result_auth_denied = false;
    metrics = Observed.unreported;
    sandbox_logs = Observed.unreported;
    logs_subview = Logs_metrics;
    logs_scroll_offset = 0;
    oauth_attached = Observed.unreported;
    oauth_auth_denied = false;
    oauth_pending_login = None;
    oauth_attempt_status = None;
    oauth_last_poll_ns = None;
    oauth_poll_started_ns = None;
    oauth_poll_consecutive_errors = 0;
    github_identity = Observed.unreported;
    github_auth_denied = false;
    github_login = empty_github_login;
    identity_selected_idx = 0;
    identity_scroll_offset = 0;
  }

let empty =
  { by_keeper = String_map.empty; oauth_providers = Observed.unreported }

let get_keeper ~keeper t =
  match String_map.find_opt keeper t.by_keeper with
  | Some ks -> ks
  | None -> empty_keeper_state

let update_keeper ~keeper f t =
  let cur = get_keeper ~keeper t in
  { t with by_keeper = String_map.add keeper (f cur) t.by_keeper }

let trace_section_rank = function
  | Trace_context -> 0
  | Trace_tool_calls -> 1
  | Trace_metrics_logs -> 2
  | Trace_runtime -> 3

let equal_trace_section a b =
  Int.equal (trace_section_rank a) (trace_section_rank b)

let all_trace_sections =
  [ Trace_context; Trace_tool_calls; Trace_metrics_logs; Trace_runtime ]

let trace_section_label = function
  | Trace_context -> Say.make ~ko:"컨텍스트 · 턴" ~en:"Context"
  | Trace_tool_calls -> Say.make ~ko:"도구 호출" ~en:"Tools"
  | Trace_metrics_logs -> Say.make ~ko:"로그 · 지표" ~en:"Logs"
  | Trace_runtime -> Say.make ~ko:"런타임" ~en:"Runtime"

let next_trace_section = function
  | Trace_context -> Trace_tool_calls
  | Trace_tool_calls -> Trace_metrics_logs
  | Trace_metrics_logs -> Trace_runtime
  | Trace_runtime -> Trace_context

let prev_trace_section = function
  | Trace_context -> Trace_runtime
  | Trace_tool_calls -> Trace_context
  | Trace_metrics_logs -> Trace_tool_calls
  | Trace_runtime -> Trace_metrics_logs

let set_trace_section ~keeper trace_section t =
  update_keeper ~keeper
    (fun ks ->
      if equal_trace_section ks.trace_section trace_section then ks
      else { ks with trace_section; runtime_trace_scroll_offset = 0 })
    t

let cycle_trace_section ~keeper ~delta t =
  update_keeper ~keeper
    (fun ks ->
      let trace_section =
        if delta < 0 then prev_trace_section ks.trace_section
        else next_trace_section ks.trace_section
      in
      { ks with trace_section; runtime_trace_scroll_offset = 0 })
    t

let move_runtime_trace_scroll ~keeper ?(max_scroll = 0) ~delta t =
  update_keeper ~keeper
    (fun ks ->
      let runtime_trace_scroll_offset =
        Store_scroll.clamp_scroll ~max_scroll:(max 0 max_scroll)
          (ks.runtime_trace_scroll_offset + delta)
      in
      { ks with runtime_trace_scroll_offset })
    t

let subtab_rank = function
  | Ctx_composition -> 0
  | Ctx_flow -> 1
  | Ctx_exact_input -> 2
  | Ctx_input_map -> 3
  | Ctx_response -> 4

let equal_context_subtab a b = Int.equal (subtab_rank a) (subtab_rank b)

let all_context_subtabs =
  [ Ctx_composition; Ctx_flow; Ctx_exact_input; Ctx_input_map; Ctx_response ]

let context_subtab_label = function
  | Ctx_composition -> Say.make ~ko:"구성 · 예측" ~en:"Composition"
  | Ctx_flow -> Say.make ~ko:"흐름 · 제어" ~en:"Flow & Control"
  | Ctx_exact_input -> Say.make ~ko:"원문 입력 · 캐시" ~en:"Exact Input"
  | Ctx_input_map -> Say.make ~ko:"입력 증명표" ~en:"Input Map"
  | Ctx_response -> Say.make ~ko:"응답 · 도구" ~en:"Response"

let next_context_subtab = function
  | Ctx_composition -> Ctx_flow
  | Ctx_flow -> Ctx_exact_input
  | Ctx_exact_input -> Ctx_input_map
  | Ctx_input_map -> Ctx_response
  | Ctx_response -> Ctx_composition

let selected_turn_entry ks =
  match Observed.to_option ks.turn_records with
  | None -> None
  | Some page ->
      let idx =
        Store_scroll.clamp_index (List.length page.entries) ks.selected_turn_idx
      in
      List.nth_opt page.entries idx

let selected_turn_ref ks =
  Option.map
    (fun (e : Wire_keeper_context.turn_record_entry) ->
      Ids.Turn_ref.to_string e.record.turn_ref)
    (selected_turn_entry ks)

let provider_input_for_selected_turn ks =
  match selected_turn_ref ks, Observed.to_option ks.provider_input with
  | Some tr, Some (stored_tr, mf) when String.equal tr stored_tr -> Some mf
  | _ -> None

let selected_provider_part ks =
  match provider_input_for_selected_turn ks with
  | None -> None
  | Some mf ->
      let idx =
        Store_scroll.clamp_index (List.length mf.parts) ks.selected_part_idx
      in
      List.nth_opt mf.parts idx

let part_content_for_selected ks =
  match
    selected_turn_ref ks,
    selected_provider_part ks,
    Observed.to_option ks.part_content
  with
  | Some tr, Some part, Some (stored_tr, stored_idx, content)
    when String.equal tr stored_tr && Int.equal part.part_index stored_idx ->
      Some content
  | _ -> None

let cache_outcome_for_selected_turn ks =
  match selected_turn_ref ks, Observed.to_option ks.cache_outcome with
  | Some tr, Some (stored_tr, reading) when String.equal tr stored_tr ->
      Some reading
  | _ -> None

let transcript_for_selected_turn ks =
  match selected_turn_ref ks, Observed.to_option ks.turn_transcript with
  | Some tr, Some (stored_tr, trs) when String.equal tr stored_tr -> Some trs
  | _ -> None

let call_evidence_for_selected_turn ks =
  match selected_turn_ref ks, Observed.to_option ks.call_evidence with
  | Some tr, Some (stored_tr, rows) when String.equal tr stored_tr -> Some rows
  | _ -> None

let turn_flow_for_selected_turn ks =
  match selected_turn_ref ks, Observed.to_option ks.turn_flow with
  | Some tr, Some (stored_tr, flow) when String.equal tr stored_tr -> Some flow
  | _ -> None

let selected_tool_call ks =
  match Observed.to_option ks.tool_calls with
  | None -> None
  | Some page ->
      let idx =
        Store_scroll.clamp_index (List.length page.entries) ks.selected_call_idx
      in
      List.nth_opt page.entries idx

let is_tool_result_inflight ~execution_id ks =
  String_set.mem execution_id ks.tool_result_inflight

let tool_result_page_error ~execution_id ks =
  String_map.find_opt execution_id ks.tool_result_page_errors

let tool_result_for_execution ~execution_id ks =
  match String_map.find_opt execution_id ks.tool_results with
  | Some obs -> obs
  | None -> (
      if String_set.mem execution_id ks.tool_result_inflight then
        Observed.loading ~since_ns:Clock.Mono.zero
      else
        match ks.tool_result with
        | Observed.Value { data = stored_eid, res; observed_at; stale }
          when String.equal stored_eid execution_id ->
            Observed.Value { data = res; observed_at; stale }
        | Observed.Value _
        | Observed.Loading _
        | Observed.Absent
        | Observed.Unreported
        | Observed.Failed _ ->
            Observed.unreported)

let tool_result_for_selected_call ks =
  match selected_tool_call ks with
  | Some { execution_id = Some eid; _ } ->
      Observed.to_option (tool_result_for_execution ~execution_id:eid ks)
  | Some { execution_id = None; _ } | None -> None

let next_tool_result_params ?(allow_non_retryable = false) ~allow_next_page
    ~refetch_when_eof ~execution_id ks =
  if is_tool_result_inflight ~execution_id ks then None
  else
    let page0 =
      Some { offset = 0; max_bytes = tool_result_page_size; source_id = None }
    in
    let page_err = tool_result_page_error ~execution_id ks in
    match page_err with
    | Some (Page_source_changed _) -> page0
    | Some (Page_continuation_failed _) | None -> (
        let cached_opt =
          match String_map.find_opt execution_id ks.tool_results with
          | Some obs -> Some obs
          | None -> (
              match ks.tool_result with
              | Observed.Value { data = stored_eid, res; observed_at; stale }
                when String.equal stored_eid execution_id ->
                  Some (Observed.Value { data = res; observed_at; stale })
              | Observed.Value _
              | Observed.Loading _
              | Observed.Absent
              | Observed.Unreported
              | Observed.Failed _ ->
                  None)
        in
        let can_retry_page_err =
          match page_err with
          | None -> true
          | Some (Page_continuation_failed { retryable; _ }) ->
              retryable || allow_non_retryable
          | Some (Page_source_changed _) -> true
        in
        match cached_opt with
        | Some
            (Observed.Value
               {
                 data = Wire_keeper_context.Tool_result_page p;
                 stale = false;
                 _;
               }) ->
            if is_binary_encoding p.encoding then None
            else if not p.eof then
              if allow_next_page && can_retry_page_err then
                Some
                  {
                    offset = p.next_offset;
                    max_bytes = tool_result_page_size;
                    source_id = Some p.source_id;
                  }
              else None
            else if refetch_when_eof && can_retry_page_err then page0
            else None
        | Some
            (Observed.Value
               {
                 data = Wire_keeper_context.Tool_result_unavailable _;
                 stale = false;
                 _;
               })
        | Some Observed.Absent ->
            if refetch_when_eof then page0 else None
        | Some (Observed.Failed { retryable = false; _ }) ->
            if refetch_when_eof || allow_non_retryable then page0 else None
        | Some
            (Observed.Value
               {
                 data =
                   ( Wire_keeper_context.Tool_result_page _
                   | Wire_keeper_context.Tool_result_pending
                   | Wire_keeper_context.Tool_result_unavailable _ );
                 stale = true;
                 _;
               }) ->
            if can_retry_page_err then page0 else None
        | None
        | Some Observed.Unreported
        | Some (Observed.Loading _)
        | Some
            (Observed.Value
               {
                 data = Wire_keeper_context.Tool_result_pending;
                 stale = false;
                 _;
               })
        | Some (Observed.Failed { retryable = true; _ }) ->
            page0)

let cycle_subtab ~keeper t =
  update_keeper ~keeper
    (fun ks -> { ks with subtab = next_context_subtab ks.subtab; scroll_offset = 0 })
    t

let set_subtab ~keeper subtab t =
  update_keeper ~keeper (fun ks -> { ks with subtab; scroll_offset = 0 }) t

let step_turn ~keeper ~delta t =
  update_keeper ~keeper
    (fun ks ->
      let total =
        match Observed.to_option ks.turn_records with
        | Some page -> List.length page.entries
        | None -> 0
      in
      let next_idx = Store_scroll.clamp_index total (ks.selected_turn_idx + delta) in
      if Int.equal next_idx ks.selected_turn_idx then ks
      else
        {
          ks with
          selected_turn_idx = next_idx;
          selected_part_idx = 0;
          scroll_offset = 0;
        })
    t

let move_scroll ~keeper ?max_scroll ~delta t =
  update_keeper ~keeper
    (fun ks ->
      let next = max 0 (ks.scroll_offset + delta) in
      let clamped =
        match max_scroll with Some m -> min (max 0 m) next | None -> next
      in
      { ks with scroll_offset = clamped })
    t

let move_part_selection ~keeper ~delta t =
  update_keeper ~keeper
    (fun ks ->
      let total =
        match provider_input_for_selected_turn ks with
        | Some mf -> List.length mf.parts
        | None -> 0
      in
      let next_idx = Store_scroll.clamp_index total (ks.selected_part_idx + delta) in
      let scroll_offset =
        if Int.equal next_idx ks.selected_part_idx then ks.scroll_offset else 0
      in
      { ks with selected_part_idx = next_idx; scroll_offset })
    t

let move_call_selection ~keeper ?(viewport_rows = 12) ~delta t =
  update_keeper ~keeper
    (fun ks ->
      let total =
        match Observed.to_option ks.tool_calls with
        | Some p -> List.length p.entries
        | None -> 0
      in
      let selected_call_idx =
        Store_scroll.clamp_index total (ks.selected_call_idx + delta)
      in
      let call_scroll_offset =
        Store_scroll.adjust_scroll ~viewport_rows ~scroll:ks.call_scroll_offset
          selected_call_idx
      in
      let call_detail_scroll_offset =
        if Int.equal selected_call_idx ks.selected_call_idx then
          ks.call_detail_scroll_offset
        else 0
      in
      { ks with selected_call_idx; call_scroll_offset; call_detail_scroll_offset })
    t

let move_call_detail_scroll ~keeper ?max_scroll ~delta t =
  update_keeper ~keeper
    (fun ks ->
      let next = max 0 (ks.call_detail_scroll_offset + delta) in
      let clamped =
        match max_scroll with Some m -> min (max 0 m) next | None -> next
      in
      { ks with call_detail_scroll_offset = clamped })
    t

let apply_turn_records ~observed_at ~keeper
    (page : Wire_keeper_context.turn_records_page) t =
  update_keeper ~keeper
    (fun ks ->
      let selected_turn_idx =
        Store_scroll.clamp_index
          (List.length page.Wire_keeper_context.entries)
          ks.selected_turn_idx
      in
      {
        ks with
        turn_records = Observed.value ~observed_at page;
        selected_turn_idx;
      })
    t

let apply_provider_input ~observed_at ~keeper ~turn_ref
    (mf : Wire_keeper_context.provider_input_manifest) t =
  update_keeper ~keeper
    (fun ks ->
      let matches =
        match selected_turn_ref ks with
        | Some cur -> String.equal cur turn_ref
        | None -> true
      in
      if not matches then ks
      else
        let selected_part_idx =
          Store_scroll.clamp_index (List.length mf.parts) ks.selected_part_idx
        in
        {
          ks with
          provider_input = Observed.value ~observed_at (turn_ref, mf);
          provider_input_auth_denied = false;
          absent_provider_input_ref = None;
          selected_part_idx;
        })
    t

let mark_provider_input_denied ~at ~keeper ?turn_ref ~reason t =
  update_keeper ~keeper
    (fun ks ->
      let matches =
        match (turn_ref, selected_turn_ref ks) with
        | Some tr, Some cur -> String.equal cur tr
        | None, _ | Some _, None -> true
      in
      if not matches then ks
      else
        {
          ks with
          provider_input = Observed.failed ~reason ~retryable:false ~at;
          provider_input_auth_denied = true;
        })
    t

let mark_provider_input_part_denied ~at ~keeper ~turn_ref ~index ~reason t =
  update_keeper ~keeper
    (fun ks ->
      let ref_matches =
        match selected_turn_ref ks with
        | Some cur -> String.equal cur turn_ref
        | None -> true
      in
      let idx_matches =
        match selected_provider_part ks with
        | Some part -> Int.equal part.part_index index
        | None -> true
      in
      if not (ref_matches && idx_matches) then ks
      else
        {
          ks with
          part_content = Observed.failed ~reason ~retryable:false ~at;
        })
    t

let mark_turn_records_failed ~at ~keeper ~reason ~retryable t =
  update_keeper ~keeper
    (fun ks ->
      { ks with turn_records = Observed.failed ~reason ~retryable ~at })
    t

let mark_provider_input_absent ~keeper ~turn_ref t =
  update_keeper ~keeper
    (fun ks ->
      let matches =
        match selected_turn_ref ks with
        | Some cur -> String.equal cur turn_ref
        | None -> true
      in
      if not matches then ks
      else
        {
          ks with
          provider_input = Observed.absent;
          absent_provider_input_ref = Some turn_ref;
        })
    t

let mark_cache_outcome_absent ~keeper ~turn_ref t =
  update_keeper ~keeper
    (fun ks ->
      let matches =
        match selected_turn_ref ks with
        | Some cur -> String.equal cur turn_ref
        | None -> true
      in
      if not matches then ks
      else
        {
          ks with
          cache_outcome = Observed.absent;
          absent_cache_outcome_ref = Some turn_ref;
        })
    t

let mark_turn_transcript_absent ~keeper ~turn_ref t =
  update_keeper ~keeper
    (fun ks ->
      let matches =
        match selected_turn_ref ks with
        | Some cur -> String.equal cur turn_ref
        | None -> true
      in
      if not matches then ks
      else
        {
          ks with
          turn_transcript = Observed.absent;
          absent_transcript_ref = Some turn_ref;
        })
    t

let mark_call_evidence_absent ~keeper ~turn_ref t =
  update_keeper ~keeper
    (fun ks ->
      let matches =
        match selected_turn_ref ks with
        | Some cur -> String.equal cur turn_ref
        | None -> true
      in
      if not matches then ks
      else
        {
          ks with
          call_evidence = Observed.absent;
          absent_call_evidence_ref = Some turn_ref;
        })
    t

let mark_next_request_absent ~keeper t =
  update_keeper ~keeper
    (fun ks -> { ks with next_request = Observed.absent; next_request_absent = true })
    t

let mark_tool_calls_absent ~keeper t =
  update_keeper ~keeper
    (fun ks -> { ks with tool_calls = Observed.absent; tool_calls_absent = true })
    t

let mark_tool_stats_absent ~keeper t =
  update_keeper ~keeper
    (fun ks -> { ks with tool_stats = Observed.absent; tool_stats_absent = true })
    t

let put_tool_result_cache ~execution_id obs ks =
  let order =
    execution_id
    :: List.filter (fun id -> not (String.equal id execution_id))
         ks.tool_result_cache_order
  in
  let rec split n kept dropped = function
    | [] -> (List.rev kept, dropped)
    | x :: xs when n > 0 -> split (n - 1) (x :: kept) dropped xs
    | x :: xs -> split 0 kept (x :: dropped) xs
  in
  let kept_order, evicted = split max_tool_result_cache [] [] order in
  let map0 = String_map.add execution_id obs ks.tool_results in
  let tool_results =
    List.fold_left (fun acc eid -> String_map.remove eid acc) map0 evicted
  in
  let tool_result_page_errors =
    let err0 = String_map.remove execution_id ks.tool_result_page_errors in
    List.fold_left (fun acc eid -> String_map.remove eid acc) err0 evicted
  in
  {
    ks with
    tool_results;
    tool_result_cache_order = kept_order;
    tool_result_inflight = String_set.remove execution_id ks.tool_result_inflight;
    tool_result_page_errors;
  }

(* Route-level authorization gate: [lib/server/server_dashboard_http_keeper_get_route.ml]
   maps [Tool_result -> Some Masc_domain.CanAdmin]. A 401/403 on [/tool-result]
   is therefore a keeper-wide [CanAdmin] denial rather than a per-execution
   restriction, so marking [tool_result_auth_denied = true] on any execution
   prevents doomed repeat 403s across the keeper's hydration batch. *)
let mark_tool_result_denied ~at ~keeper ?execution_id ~reason t =
  update_keeper ~keeper
    (fun ks ->
      let ks =
        match execution_id with
        | Some eid ->
            put_tool_result_cache ~execution_id:eid
              (Observed.failed ~reason ~retryable:false ~at) ks
        | None -> ks
      in
      let matches =
        match (execution_id, selected_tool_call ks) with
        | Some eid, Some { execution_id = Some cur; _ } -> String.equal cur eid
        | _ -> true
      in
      if not matches then { ks with tool_result_auth_denied = true }
      else
        {
          ks with
          tool_result = Observed.failed ~reason ~retryable:false ~at;
          tool_result_auth_denied = true;
        })
    t

let apply_provider_input_part ~observed_at ~keeper ~turn_ref ~index content t =
  update_keeper ~keeper
    (fun ks ->
      let ref_matches =
        match selected_turn_ref ks with
        | Some cur -> String.equal cur turn_ref
        | None -> true
      in
      let idx_matches =
        match selected_provider_part ks with
        | Some part -> Int.equal part.part_index index
        | None -> true
      in
      if not (ref_matches && idx_matches) then ks
      else
        {
          ks with
          part_content = Observed.value ~observed_at (turn_ref, index, content);
        })
    t

let apply_cache_outcome ~observed_at ~keeper ~turn_ref reading t =
  update_keeper ~keeper
    (fun ks ->
      let matches =
        match selected_turn_ref ks with
        | Some cur -> String.equal cur turn_ref
        | None -> true
      in
      if not matches then ks
      else
        {
          ks with
          cache_outcome = Observed.value ~observed_at (turn_ref, reading);
          absent_cache_outcome_ref = None;
        })
    t

let apply_next_request ~observed_at ~keeper forecast t =
  update_keeper ~keeper
    (fun ks ->
      {
        ks with
        next_request = Observed.value ~observed_at forecast;
        next_request_absent = false;
      })
    t

let apply_turn_transcript ~observed_at ~keeper ~turn_ref trs t =
  update_keeper ~keeper
    (fun ks ->
      let matches =
        match selected_turn_ref ks with
        | Some cur -> String.equal cur turn_ref
        | None -> true
      in
      if not matches then ks
      else
        {
          ks with
          turn_transcript = Observed.value ~observed_at (turn_ref, trs);
          absent_transcript_ref = None;
        })
    t

let apply_call_evidence ~observed_at ~keeper ~turn_ref rows t =
  update_keeper ~keeper
    (fun ks ->
      let matches =
        match selected_turn_ref ks with
        | Some cur -> String.equal cur turn_ref
        | None -> true
      in
      if not matches then ks
      else
        {
          ks with
          call_evidence = Observed.value ~observed_at (turn_ref, rows);
          call_evidence_auth_denied = false;
          absent_call_evidence_ref = None;
        })
    t

let mark_call_evidence_denied ~at ~keeper ?turn_ref ~reason t =
  update_keeper ~keeper
    (fun ks ->
      let matches =
        match (turn_ref, selected_turn_ref ks) with
        | Some tr, Some cur -> String.equal cur tr
        | None, _ | Some _, None -> true
      in
      if not matches then ks
      else
        {
          ks with
          call_evidence = Observed.failed ~reason ~retryable:false ~at;
          call_evidence_auth_denied = true;
        })
    t

let apply_tool_stats ~observed_at ~keeper stats t =
  update_keeper ~keeper
    (fun ks ->
      {
        ks with
        tool_stats = Observed.value ~observed_at stats;
        tool_stats_absent = false;
      })
    t

let apply_tool_calls ~observed_at ~keeper page t =
  update_keeper ~keeper
    (fun ks ->
      let selected_call_idx =
        Store_scroll.clamp_index
          (List.length page.Wire_keeper_context.entries)
          ks.selected_call_idx
      in
      {
        ks with
        tool_calls = Observed.value ~observed_at page;
        tool_calls_auth_denied = false;
        tool_calls_absent = false;
        selected_call_idx;
      })
    t

let mark_tool_calls_denied ~at ~keeper ~reason t =
  update_keeper ~keeper
    (fun ks ->
      {
        ks with
        tool_calls = Observed.failed ~reason ~retryable:false ~at;
        tool_calls_auth_denied = true;
      })
    t

let mark_tool_result_inflight ~keeper ~execution_id t =
  update_keeper ~keeper
    (fun ks ->
      {
        ks with
        tool_result_inflight =
          String_set.add execution_id ks.tool_result_inflight;
      })
    t

let binary_page_marker ~recorded_bytes ~total_bytes =
  let bytes = Int.max recorded_bytes total_bytes in
  Printf.sprintf "[binary/base64 · %dB]" bytes

let has_loaded_tool_result_page ~execution_id ks =
  match String_map.find_opt execution_id ks.tool_results with
  | Some
      (Observed.Value { data = Wire_keeper_context.Tool_result_page _; _ }) ->
      true
  | Some
      ( Observed.Value
          {
            data =
              ( Wire_keeper_context.Tool_result_pending
              | Wire_keeper_context.Tool_result_unavailable _ );
            _;
          }
      | Observed.Loading _
      | Observed.Absent
      | Observed.Unreported
      | Observed.Failed _ ) ->
      false
  | None -> (
      match ks.tool_result with
      | Observed.Value { data = stored_eid, res; _ } -> (
          match res with
          | Wire_keeper_context.Tool_result_page _ ->
              String.equal stored_eid execution_id
          | Wire_keeper_context.Tool_result_pending
          | Wire_keeper_context.Tool_result_unavailable _ ->
              false)
      | Observed.Loading _
      | Observed.Absent
      | Observed.Unreported
      | Observed.Failed _ ->
          false)

let mark_tool_result_absent ~keeper ~execution_id t =
  update_keeper ~keeper
    (fun ks ->
      if has_loaded_tool_result_page ~execution_id ks then
        {
          ks with
          tool_result_inflight =
            String_set.remove execution_id ks.tool_result_inflight;
          tool_result_page_errors =
            String_map.add execution_id
              (Page_continuation_failed
                 { reason = "404 Not Found"; retryable = false })
              ks.tool_result_page_errors;
        }
      else
        let ks = put_tool_result_cache ~execution_id Observed.absent ks in
        let clear_legacy =
          match ks.tool_result with
          | Observed.Value { data = stored_eid, _; _ } ->
              String.equal stored_eid execution_id
          | Observed.Loading _ | Observed.Absent | Observed.Unreported
          | Observed.Failed _ -> (
              match selected_tool_call ks with
              | Some { execution_id = Some cur; _ } ->
                  String.equal cur execution_id
              | Some { execution_id = None; _ } | None -> false)
        in
        if clear_legacy then { ks with tool_result = Observed.absent } else ks)
    t

let store_initial_tool_result_failure ~at ~execution_id ~reason ~retryable ks =
  let ks =
    put_tool_result_cache ~execution_id
      (Observed.failed ~reason ~retryable ~at)
      ks
  in
  let matches =
    (match ks.tool_result with
    | Observed.Value { data = stored_eid, _; _ } ->
        String.equal stored_eid execution_id
    | Observed.Loading _ | Observed.Absent | Observed.Unreported
    | Observed.Failed _ ->
        false)
    ||
    match selected_tool_call ks with
    | Some { execution_id = Some cur; _ } -> String.equal cur execution_id
    | Some { execution_id = None; _ } | None -> true
  in
  if matches then
    { ks with tool_result = Observed.failed ~reason ~retryable ~at }
  else ks

let mark_tool_result_failed ~at ~keeper ~execution_id ~reason ~retryable t =
  update_keeper ~keeper
    (fun ks ->
      if has_loaded_tool_result_page ~execution_id ks then
        {
          ks with
          tool_result_inflight =
            String_set.remove execution_id ks.tool_result_inflight;
          tool_result_page_errors =
            String_map.add execution_id
              (Page_continuation_failed { reason; retryable })
              ks.tool_result_page_errors;
        }
      else
        store_initial_tool_result_failure ~at ~execution_id ~reason ~retryable
          ks)
    t

let mark_tool_result_conflict ~at ~keeper ~execution_id ~reason t =
  update_keeper ~keeper
    (fun ks ->
      if has_loaded_tool_result_page ~execution_id ks then
        {
          ks with
          tool_result_inflight =
            String_set.remove execution_id ks.tool_result_inflight;
          tool_result_page_errors =
            String_map.add execution_id (Page_source_changed reason)
              ks.tool_result_page_errors;
        }
      else
        store_initial_tool_result_failure ~at ~execution_id ~reason
          ~retryable:true ks)
    t

let apply_tool_result ~observed_at ~keeper ~execution_id resp t =
  update_keeper ~keeper
    (fun ks ->
      let prev_opt =
        match String_map.find_opt execution_id ks.tool_results with
        | Some obs -> Observed.to_option obs
        | None -> (
            match Observed.to_option ks.tool_result with
            | Some (eid, prev) when String.equal eid execution_id -> Some prev
            | Some _ | None -> None)
      in
      let merged_opt =
        match (resp, prev_opt) with
        | ( Wire_keeper_context.Tool_result_page page
          , ( Some (Wire_keeper_context.Tool_result_page _)
            | Some Wire_keeper_context.Tool_result_pending
            | Some (Wire_keeper_context.Tool_result_unavailable _)
            | None ) )
          when page.offset = 0 ->
            if is_binary_encoding page.encoding then
              Some
                (Wire_keeper_context.Tool_result_page
                   {
                     page with
                     content =
                       binary_page_marker ~recorded_bytes:page.recorded_bytes
                         ~total_bytes:page.total_bytes;
                     eof = page.eof;
                     next_offset = page.next_offset;
                     encoding = "base64";
                   })
            else
              Some
                (Wire_keeper_context.Tool_result_page
                   {
                     page with
                     eof = page.eof || page.next_offset <= page.offset;
                   })
        | ( Wire_keeper_context.Tool_result_page page
          , Some (Wire_keeper_context.Tool_result_page prev) )
          when page.offset > 0
               && Int.equal page.offset prev.next_offset
               && String.equal page.source_id prev.source_id ->
            if is_binary_encoding page.encoding then
              if is_binary_encoding prev.encoding then
                Some (Wire_keeper_context.Tool_result_page prev)
              else
                Some
                  (Wire_keeper_context.Tool_result_page
                     {
                       page with
                       offset = prev.offset;
                       content =
                         prev.content ^ "\n\n"
                         ^ binary_page_marker ~recorded_bytes:page.recorded_bytes
                             ~total_bytes:page.total_bytes;
                       next_offset = Int.max prev.next_offset page.next_offset;
                       total_bytes = Int.max prev.total_bytes page.total_bytes;
                       recorded_bytes =
                         Int.max prev.recorded_bytes page.recorded_bytes;
                       eof = page.eof;
                       encoding = "base64";
                       is_error = prev.is_error || page.is_error;
                     })
            else if page.next_offset > prev.next_offset then
              Some
                (Wire_keeper_context.Tool_result_page
                   {
                     page with
                     offset = prev.offset;
                     content = prev.content ^ page.content;
                     next_offset = page.next_offset;
                     total_bytes = Int.max prev.total_bytes page.total_bytes;
                     recorded_bytes =
                       Int.max prev.recorded_bytes page.recorded_bytes;
                     eof = page.eof;
                     is_error = prev.is_error || page.is_error;
                   })
            else if page.eof && Int.equal page.next_offset prev.next_offset then
              Some
                (Wire_keeper_context.Tool_result_page
                   {
                     prev with
                     total_bytes = Int.max prev.total_bytes page.total_bytes;
                     recorded_bytes =
                       Int.max prev.recorded_bytes page.recorded_bytes;
                     eof = true;
                     is_error = prev.is_error || page.is_error;
                   })
            else
              (* Zero-progress or regressed next_offset: keep accumulated page without duplicating. *)
              Some (Wire_keeper_context.Tool_result_page prev)
        | ( Wire_keeper_context.Tool_result_page _
          , ( Some (Wire_keeper_context.Tool_result_page _)
            | Some Wire_keeper_context.Tool_result_pending
            | Some (Wire_keeper_context.Tool_result_unavailable _)
            | None ) ) ->
            (* Orphan or mismatched offset > 0 slice: never store headless bytes. *)
            None
        | ( ( Wire_keeper_context.Tool_result_pending
            | Wire_keeper_context.Tool_result_unavailable _ )
          , ( Some (Wire_keeper_context.Tool_result_page _)
            | Some Wire_keeper_context.Tool_result_pending
            | Some (Wire_keeper_context.Tool_result_unavailable _)
            | None ) ) ->
            Some resp
      in
      match merged_opt with
      | None ->
          {
            ks with
            tool_result_inflight =
              String_set.remove execution_id ks.tool_result_inflight;
          }
      | Some merged_resp ->
          let ks =
            put_tool_result_cache ~execution_id
              (Observed.value ~observed_at merged_resp)
              ks
          in
          let matches =
            match selected_tool_call ks with
            | Some { execution_id = Some cur; _ } -> String.equal cur execution_id
            | Some { execution_id = None; _ } | None -> true
          in
          if not matches then { ks with tool_result_auth_denied = false }
          else
            {
              ks with
              tool_result = Observed.value ~observed_at (execution_id, merged_resp);
              tool_result_auth_denied = false;
            })
    t

let mark_stale_all t =
  {
    by_keeper =
      String_map.map
        (fun ks ->
          {
            ks with
            turn_records = Observed.mark_stale ks.turn_records;
            provider_input = Observed.mark_stale ks.provider_input;
            provider_input_auth_denied = false;
            part_content = Observed.mark_stale ks.part_content;
            cache_outcome = Observed.mark_stale ks.cache_outcome;
            next_request = Observed.mark_stale ks.next_request;
            turn_transcript = Observed.mark_stale ks.turn_transcript;
            call_evidence = Observed.mark_stale ks.call_evidence;
            call_evidence_auth_denied = false;
            turn_flow = Observed.mark_stale ks.turn_flow;
            absent_turn_flow_ref = None;
            checkpoints = Observed.mark_stale ks.checkpoints;
            checkpoints_auth_denied = false;
            checkpoints_absent = false;
            operator_note = Observed.mark_stale ks.operator_note;
            operator_note_absent = false;
            tool_stats = Observed.mark_stale ks.tool_stats;
            tool_calls = Observed.mark_stale ks.tool_calls;
            tool_calls_auth_denied = false;
            tool_result = Observed.mark_stale ks.tool_result;
            tool_results = String_map.map Observed.mark_stale ks.tool_results;
            tool_result_inflight = String_set.empty;
            tool_result_page_errors = String_map.empty;
            tool_result_auth_denied = false;
            metrics = Observed.mark_stale ks.metrics;
            sandbox_logs = Observed.mark_stale ks.sandbox_logs;
            oauth_attached = Observed.mark_stale ks.oauth_attached;
            oauth_auth_denied = false;
            github_identity = Observed.mark_stale ks.github_identity;
            github_auth_denied = false;
          })
        t.by_keeper;
    oauth_providers = Observed.mark_stale t.oauth_providers;
  }

let mark_keeper_context_stale ~keeper t =
  update_keeper ~keeper
    (fun ks ->
      {
        ks with
        turn_records = Observed.mark_stale ks.turn_records;
        next_request = Observed.mark_stale ks.next_request;
        next_request_absent = false;
        turn_flow = Observed.mark_stale ks.turn_flow;
        absent_turn_flow_ref = None;
        checkpoints =
          (if ks.checkpoints_auth_denied then ks.checkpoints
           else Observed.mark_stale ks.checkpoints);
        checkpoints_absent = false;
        operator_note = Observed.mark_stale ks.operator_note;
        operator_note_absent = false;
        tool_stats = Observed.mark_stale ks.tool_stats;
        tool_calls = Observed.mark_stale ks.tool_calls;
      })
    t

let mark_keeper_tool_calls_stale ~keeper t =
  update_keeper ~keeper
    (fun ks ->
      {
        ks with
        tool_stats = Observed.mark_stale ks.tool_stats;
        tool_calls = Observed.mark_stale ks.tool_calls;
        call_evidence = Observed.mark_stale ks.call_evidence;
      })
    t

let apply_turn_flow ~observed_at ~keeper ~turn_ref flow t =
  update_keeper ~keeper
    (fun ks ->
      let matches =
        match selected_turn_ref ks with
        | Some cur -> String.equal cur turn_ref
        | None -> true
      in
      if not matches then ks
      else
        {
          ks with
          turn_flow = Observed.value ~observed_at (turn_ref, flow);
          absent_turn_flow_ref = None;
        })
    t

let mark_turn_flow_absent ~keeper ~turn_ref t =
  update_keeper ~keeper
    (fun ks ->
      let matches =
        match selected_turn_ref ks with
        | Some cur -> String.equal cur turn_ref
        | None -> true
      in
      if not matches then ks
      else
        {
          ks with
          turn_flow = Observed.absent;
          absent_turn_flow_ref = Some turn_ref;
        })
    t

let mark_turn_flow_failed ~at ~keeper ~turn_ref ~reason ~retryable t =
  update_keeper ~keeper
    (fun ks ->
      let matches =
        match selected_turn_ref ks with
        | Some cur -> String.equal cur turn_ref
        | None -> true
      in
      if not matches then ks
      else
        {
          ks with
          turn_flow = Observed.failed ~reason ~retryable ~at;
        })
    t

let apply_checkpoints ~observed_at ~keeper inv t =
  update_keeper ~keeper
    (fun ks ->
      {
        ks with
        checkpoints = Observed.value ~observed_at inv;
        checkpoints_auth_denied = false;
        checkpoints_absent = false;
      })
    t

let mark_checkpoints_denied ~at ~keeper ~reason t =
  update_keeper ~keeper
    (fun ks ->
      {
        ks with
        checkpoints = Observed.failed ~reason ~retryable:false ~at;
        checkpoints_auth_denied = true;
        checkpoints_absent = false;
      })
    t

let mark_checkpoints_absent ~keeper t =
  update_keeper ~keeper
    (fun ks ->
      {
        ks with
        checkpoints = Observed.absent;
        checkpoints_absent = true;
      })
    t

let mark_checkpoints_failed ~at ~keeper ~reason ~retryable t =
  update_keeper ~keeper
    (fun ks ->
      { ks with checkpoints = Observed.failed ~reason ~retryable ~at })
    t

let flow_estimated_rows ks =
  let turn_rows =
    match selected_turn_entry ks with
    | None -> 1
    | Some entry ->
        let r = entry.record in
        let base_rows = 4 in
        let flow_rows =
          match turn_flow_for_selected_turn ks with
          | None -> 1
          | Some flow ->
              let intake_n =
                match flow.intake with
                | Wire_keeper_context.Intake_observed { sources; _ } ->
                    let shown = Int.min 8 (List.length sources) in
                    1 + shown + if List.length sources > 8 then 1 else 0
                | Wire_keeper_context.Intake_not_recorded _
                | Wire_keeper_context.Intake_unavailable _
                | Wire_keeper_context.Intake_ambiguous _ ->
                    1
              in
              let outcomes_n =
                match flow.outcomes with
                | Wire_keeper_context.Outcomes_observed { sources; _ } ->
                    let shown = Int.min 6 (List.length sources) in
                    1 + shown + if List.length sources > 6 then 1 else 0
                | Wire_keeper_context.Outcomes_unavailable _ -> 1
              in
              let ev_n =
                if flow.events = [] then 0
                else
                  let shown = Int.min 16 (List.length flow.events) in
                  1 + shown + if List.length flow.events > 16 then 1 else 0
              in
              intake_n + outcomes_n + ev_n
        in
        let obs_rows =
          if r.request_observations = [] then 0
          else 1 + List.length r.request_observations
        in
        let call_rows =
          match call_evidence_for_selected_turn ks with
          | Some calls when calls <> [] ->
              let shown = Int.min 16 (List.length calls) in
              1 + shown + if List.length calls > 16 then 1 else 0
          | Some _ | None -> 0
        in
        let diff_rows =
          match entry.diff_vs_prev with
          | Some d
            when d.added <> [] || d.removed <> [] || d.changed <> [] ->
              1 + List.length d.added + List.length d.removed
              + List.length d.changed
          | Some _ | None -> 0
        in
        base_rows + flow_rows + obs_rows + call_rows + diff_rows
  in
  let mos_rows =
    match Observed.to_option ks.turn_records with
    | Some { memory_os = Some mo; _ } ->
        let shown = Int.min 5 (List.length mo.facts) in
        2 + List.length mo.read_errors + shown
        + if List.length mo.facts > 5 then 1 else 0
    | Some { memory_os = None; _ } | None -> 0
  in
  let ckpt_rows =
    let inv_n =
      match ks.checkpoints with
      | Observed.Value { data = inv; _ } ->
          let shown_h = Int.min 4 (List.length inv.history) in
          let shown_e = Int.min 3 (List.length inv.history_errors) in
          1 + shown_h
          + (if List.length inv.history > 4 then 1 else 0)
          + shown_e
          + if List.length inv.history_errors > 3 then 1 else 0
      | Observed.Loading _ | Observed.Failed _ | Observed.Absent
      | Observed.Unreported ->
          1
    in
    let purge_n = match ks.last_purge_preview with Some _ -> 1 | None -> 0 in
    let note_n = 1 in
    let ctl_strip_n = 1 in
    1 + inv_n + purge_n + note_n + ctl_strip_n
  in
  turn_rows + mos_rows + ckpt_rows

let apply_purge_result ~observed_at ~keeper (res : Wire_keeper_context.checkpoint_purge_result) t =
  update_keeper ~keeper
    (fun ks ->
      let checkpoints =
        match res.inventory with
        | Some inv -> Observed.value ~observed_at inv
        | None -> ks.checkpoints
      in
      { ks with checkpoints; last_purge_preview = Some res })
    t

let last_operator_note = function
  | Observed.Value _ as note -> Observed.mark_stale note
  | Observed.Absent | Observed.Unreported | Observed.Failed _ | Observed.Loading _ ->
      Observed.unreported

let start_operator_note_write ~keeper t =
  update_keeper ~keeper
    (fun ks ->
      let operator_note_writes =
        match ks.operator_note_writes with
        | No_note_writes -> One_note_write
        | One_note_write -> Overlapping_note_writes 2
        | Overlapping_note_writes pending -> Overlapping_note_writes (pending + 1)
      in
      let operator_note = last_operator_note ks.operator_note in
      { ks with operator_note_writes; operator_note; operator_note_absent = false })
    t

(* With overlapping writes, the order of HTTP receipts does not establish which
   note the server stored last. The last receipt releases one fresh read. *)
let settle_operator_note_write ~now ~keeper t =
  let ks = get_keeper ~keeper t in
  let operator_note_writes, settlement =
    match ks.operator_note_writes with
    | One_note_write -> No_note_writes, Isolated_note_write
    | No_note_writes | Overlapping_note_writes 1 -> No_note_writes, Reread_note
    | Overlapping_note_writes pending -> Overlapping_note_writes (pending - 1), Await_note_writes
  in
  let operator_note =
    match settlement, ks.operator_note with
    | (Isolated_note_write | Await_note_writes), note -> note
    | Reread_note, (Observed.Value _ as note) -> Observed.mark_stale note
    | Reread_note, (Observed.Absent | Observed.Unreported | Observed.Failed _ | Observed.Loading _) ->
        Observed.loading ~since_ns:now
  in
  let operator_note_read_after = Clock.Mono.max ks.operator_note_read_after now in
  let t =
    update_keeper ~keeper
      (fun ks ->
        { ks with operator_note_writes; operator_note_read_after; operator_note;
                  operator_note_absent = ks.operator_note_absent && settlement = Isolated_note_write })
      t
  in
  t, settlement

let apply_operator_note ~observed_at ~requested_at ~keeper note t =
  update_keeper ~keeper
    (fun ks ->
      {
        ks with
        operator_note = Observed.value ~observed_at note;
        operator_note_absent = false;
        operator_note_read_after = Clock.Mono.max ks.operator_note_read_after requested_at;
      })
    t

let mark_operator_note_absent ~requested_at ~keeper t =
  update_keeper ~keeper
    (fun ks ->
      {
        ks with
        operator_note = Observed.absent;
        operator_note_absent = true;
        operator_note_read_after = Clock.Mono.max ks.operator_note_read_after requested_at;
      })
    t

let mark_operator_note_failed ~at ~requested_at ~keeper ~reason ~retryable t =
  update_keeper ~keeper
    (fun ks ->
      { ks with operator_note = Observed.fetch_failed ~reason ~retryable ~at ks.operator_note;
                operator_note_absent = false;
                operator_note_read_after = Clock.Mono.max ks.operator_note_read_after requested_at })
    t

let equal_logs_subview a b =
  match a, b with
  | Logs_metrics, Logs_metrics | Logs_sandbox, Logs_sandbox -> true
  | Logs_metrics, Logs_sandbox | Logs_sandbox, Logs_metrics -> false

let toggle_logs_subview ~keeper t =
  update_keeper ~keeper
    (fun ks ->
      let logs_subview =
        match ks.logs_subview with
        | Logs_metrics -> Logs_sandbox
        | Logs_sandbox -> Logs_metrics
      in
      { ks with logs_subview; logs_scroll_offset = 0 })
    t

let move_logs_scroll ~keeper ?(max_scroll = 0) ~delta t =
  update_keeper ~keeper
    (fun ks ->
      let logs_scroll_offset =
        Store_scroll.clamp_scroll ~max_scroll:(max 0 max_scroll)
          (ks.logs_scroll_offset + delta)
      in
      { ks with logs_scroll_offset })
    t

let apply_metrics ~observed_at ~keeper snap t =
  update_keeper ~keeper
    (fun ks -> { ks with metrics = Observed.value ~observed_at snap })
    t

let mark_metrics_failed ~at ~keeper ~reason ~retryable t =
  update_keeper ~keeper
    (fun ks -> { ks with metrics = Observed.failed ~reason ~retryable ~at })
    t

let apply_sandbox_logs ~observed_at ~keeper logs t =
  update_keeper ~keeper
    (fun ks -> { ks with sandbox_logs = Observed.value ~observed_at logs })
    t

let mark_sandbox_logs_failed ~at ~keeper ~reason ~retryable t =
  update_keeper ~keeper
    (fun ks -> { ks with sandbox_logs = Observed.failed ~reason ~retryable ~at })
    t

let apply_oauth_providers ~observed_at snap t =
  { t with oauth_providers = Observed.value ~observed_at snap }

let apply_oauth_attached_tools ~observed_at ~keeper snap t =
  update_keeper ~keeper
    (fun ks ->
      {
        ks with
        oauth_attached = Observed.value ~observed_at snap;
        oauth_auth_denied = false;
      })
    t

let mark_oauth_denied ~at ~keeper ~reason t =
  update_keeper ~keeper
    (fun ks ->
      {
        ks with
        oauth_attached = Observed.failed ~reason ~retryable:false ~at;
        oauth_auth_denied = true;
      })
    t

let set_oauth_pending_login ~keeper res t =
  update_keeper ~keeper
    (fun ks ->
      {
        ks with
        oauth_pending_login = res;
        oauth_attempt_status =
          (match res with Some _ -> None | None -> ks.oauth_attempt_status);
        oauth_last_poll_ns = None;
        oauth_poll_started_ns = None;
        oauth_poll_consecutive_errors = 0;
      })
    t

let set_oauth_attempt_status ~keeper status t =
  update_keeper ~keeper
    (fun ks ->
      {
        ks with
        oauth_attempt_status = status;
        oauth_poll_consecutive_errors = 0;
      })
    t

let is_oauth_attempt_settled kind =
  match Wire_keeper_context.classify_oauth_attempt_kind kind with
  | Wire_keeper_context.Oauth_completed
  | Wire_keeper_context.Oauth_settled_other ->
      true
  | Wire_keeper_context.Oauth_active | Wire_keeper_context.Oauth_other _ ->
      false

let oauth_poll_interval_ns = 2_000_000_000L
let oauth_poll_max_window_ns = 600_000_000_000L
let oauth_poll_max_consecutive_errors = 5

let mark_oauth_polled ~now ~keeper t =
  let now_ns = Clock.Mono.to_ns now in
  update_keeper ~keeper
    (fun ks ->
      {
        ks with
        oauth_last_poll_ns = Some now_ns;
        oauth_poll_started_ns =
          (match ks.oauth_poll_started_ns with
          | Some _ as started -> started
          | None -> Some now_ns);
      })
    t

let record_oauth_poll_error ~keeper t =
  update_keeper ~keeper
    (fun ks ->
      {
        ks with
        oauth_poll_consecutive_errors = ks.oauth_poll_consecutive_errors + 1;
      })
    t

let is_oauth_exchange_pollable ~now_ns ?wall_unix (ks : keeper_state)
    (expires_at : float option) =
  let settled =
    match ks.oauth_attempt_status with
    | Some st -> is_oauth_attempt_settled st.kind
    | None -> false
  in
  let errors_exhausted =
    ks.oauth_poll_consecutive_errors >= oauth_poll_max_consecutive_errors
  in
  let window_exceeded =
    match ks.oauth_poll_started_ns with
    | Some started -> Int64.sub now_ns started >= oauth_poll_max_window_ns
    | None -> false
  in
  let wall_expired =
    match (expires_at, wall_unix) with
    | Some exp, Some w when Float.is_finite exp && Float.is_finite w && w > 0.0
      ->
        w >= exp
    | (Some _ | None), (Some _ | None) -> false
  in
  let confirmed_active =
    match ks.oauth_attempt_status with
    | Some st -> (
        match Wire_keeper_context.classify_oauth_attempt_kind st.kind with
        | Wire_keeper_context.Oauth_active ->
            ks.oauth_poll_consecutive_errors = 0
        | Wire_keeper_context.Oauth_completed
        | Wire_keeper_context.Oauth_settled_other
        | Wire_keeper_context.Oauth_other _ ->
            false)
    | None -> false
  in
  (* An admitted callback can publish after the consent deadline. A healthy
     status read keeps following the server to its terminal receipt. *)
  (not settled) && (not errors_exhausted)
  && (confirmed_active || (not window_exceeded && not wall_expired))

let pending_oauth_polls ~now ?wall_unix t =
  let now_ns = Clock.Mono.to_ns now in
  String_map.fold
    (fun keeper (ks : keeper_state) acc ->
      match ks.oauth_pending_login with
      | Some (Wire_keeper_context.Oauth_login_exchange ex) ->
          let due =
            match ks.oauth_last_poll_ns with
            | None -> true
            | Some prev -> Int64.sub now_ns prev >= oauth_poll_interval_ns
          in
          if
            due
            && is_oauth_exchange_pollable ~now_ns ?wall_unix ks ex.expires_at
          then (keeper, ex.provider, ex.attempt_id) :: acc
          else acc
      | Some (Wire_keeper_context.Oauth_login_direct _) | None -> acc)
    t.by_keeper []
  |> List.rev

let next_oauth_poll_deadline_ns ~now_ns ?wall_unix t =
  String_map.fold
    (fun _keeper (ks : keeper_state) acc ->
      match ks.oauth_pending_login with
      | Some (Wire_keeper_context.Oauth_login_exchange ex) ->
          if not (is_oauth_exchange_pollable ~now_ns ?wall_unix ks ex.expires_at)
          then acc
          else
            let due_ns =
              match ks.oauth_last_poll_ns with
              | None -> now_ns
              | Some prev -> Int64.add prev oauth_poll_interval_ns
            in
            Some
              (match acc with
              | None -> due_ns
              | Some cur -> if Int64.compare due_ns cur < 0 then due_ns else cur)
      | Some (Wire_keeper_context.Oauth_login_direct _) | None -> acc)
    t.by_keeper None

let apply_github_identity ~observed_at ~keeper obs t =
  update_keeper ~keeper
    (fun ks ->
      {
        ks with
        github_identity = Observed.value ~observed_at obs;
        github_auth_denied = false;
      })
    t

let mark_github_denied ~at ~keeper ~reason t =
  update_keeper ~keeper
    (fun ks ->
      {
        ks with
        github_identity = Observed.failed ~reason ~retryable:false ~at;
        github_auth_denied = true;
      })
    t

let extract_device_url text =
  let tokens = String.split_on_char ' ' text in
  List.find_opt
    (fun tok ->
      String.starts_with ~prefix:"https://" tok
      || String.starts_with ~prefix:"http://" tok)
    tokens
  |> Option.map (fun s ->
         String.trim
           (String.map (function '\r' | '\n' -> ' ' | c -> c) s))

let is_device_code_token tok =
  let s =
    String.trim (String.map (function '\r' | '\n' | '.' | ',' -> ' ' | c -> c) tok)
  in
  String.length s = 9 && Char.equal s.[4] '-'
  &&
  let is_alnum c = (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') in
  is_alnum s.[0] && is_alnum s.[1] && is_alnum s.[2] && is_alnum s.[3]
  && is_alnum s.[5] && is_alnum s.[6] && is_alnum s.[7] && is_alnum s.[8]

let extract_device_code text =
  let normalized =
    String.map (function '\n' | '\r' | '\t' | ':' -> ' ' | c -> c) text
  in
  let tokens = String.split_on_char ' ' normalized in
  List.find_opt is_device_code_token tokens |> Option.map String.trim

let start_github_login ~keeper t =
  update_keeper ~keeper
    (fun ks ->
      {
        ks with
        github_login = { empty_github_login with running = true };
      })
    t

let append_github_login_output ~keeper ~line t =
  update_keeper ~keeper
    (fun ks ->
      let gl = ks.github_login in
      let device_url =
        match gl.device_url with
        | Some _ as u -> u
        | None -> extract_device_url line
      in
      let device_code =
        match gl.device_code with
        | Some _ as c -> c
        | None -> extract_device_code line
      in
      let trimmed = String.trim line in
      let lines =
        if String.equal trimmed "" then gl.output_lines
        else
          let next = gl.output_lines @ [ trimmed ] in
          if List.length next > 20 then List.tl next else next
      in
      {
        ks with
        github_login =
          { gl with device_url; device_code; output_lines = lines };
      })
    t

let finish_github_login ~keeper ~error t =
  update_keeper ~keeper
    (fun ks ->
      {
        ks with
        github_login = { ks.github_login with running = false; error };
      })
    t

let clear_epoch_logins t =
  {
    t with
    by_keeper =
      String_map.map
        (fun ks ->
          { ks with
            oauth_pending_login = None;
            oauth_attempt_status = None;
            oauth_last_poll_ns = None;
            oauth_poll_started_ns = None;
            oauth_poll_consecutive_errors = 0;
            github_login = { ks.github_login with running = false };
            tool_result_inflight = String_set.empty;
            operator_note = last_operator_note ks.operator_note;
            operator_note_absent = false;
            operator_note_writes = No_note_writes;
            operator_note_read_after = Clock.Mono.zero })
        t.by_keeper;
  }

let move_identity_selection ~keeper ~count ~delta t =
  update_keeper ~keeper
    (fun ks ->
      let identity_selected_idx =
        Store_scroll.clamp_index count (ks.identity_selected_idx + delta)
      in
      { ks with identity_selected_idx })
    t

let move_identity_scroll ~keeper ?(max_scroll = 0) ~delta t =
  update_keeper ~keeper
    (fun ks ->
      let identity_scroll_offset =
        Store_scroll.clamp_scroll ~max_scroll:(max 0 max_scroll)
          (ks.identity_scroll_offset + delta)
      in
      { ks with identity_scroll_offset })
    t
