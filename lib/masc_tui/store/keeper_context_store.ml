open Masc_tui_core
open Masc_tui_protocol

module String_map = Map.Make (String)

type context_subtab =
  | Ctx_composition
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

type keeper_state = {
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
  tool_result_auth_denied : bool;
  metrics : Wire_keeper_context.keeper_metrics_snapshot Observed.t;
  sandbox_logs : Wire_keeper_context.keeper_sandbox_logs Observed.t;
  logs_subview : logs_subview;
  logs_scroll_offset : int;
  oauth_attached : Wire_keeper_context.oauth_attached_tools_snapshot Observed.t;
  oauth_auth_denied : bool;
  oauth_pending_login : Wire_keeper_context.oauth_login_result option;
  oauth_attempt_status : Wire_keeper_context.oauth_attempt_status option;
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
    tool_result_auth_denied = false;
    metrics = Observed.unreported;
    sandbox_logs = Observed.unreported;
    logs_subview = Logs_metrics;
    logs_scroll_offset = 0;
    oauth_attached = Observed.unreported;
    oauth_auth_denied = false;
    oauth_pending_login = None;
    oauth_attempt_status = None;
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

let subtab_rank = function
  | Ctx_composition -> 0
  | Ctx_exact_input -> 1
  | Ctx_input_map -> 2
  | Ctx_response -> 3

let equal_context_subtab a b = Int.equal (subtab_rank a) (subtab_rank b)

let all_context_subtabs =
  [ Ctx_composition; Ctx_exact_input; Ctx_input_map; Ctx_response ]

let context_subtab_label = function
  | Ctx_composition -> Say.make ~ko:"구성 · 예측" ~en:"Composition"
  | Ctx_exact_input -> Say.make ~ko:"원문 입력 · 캐시" ~en:"Exact Input"
  | Ctx_input_map -> Say.make ~ko:"입력 증명표" ~en:"Input Map"
  | Ctx_response -> Say.make ~ko:"응답 · 도구" ~en:"Response"

let next_context_subtab = function
  | Ctx_composition -> Ctx_exact_input
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

let selected_tool_call ks =
  match Observed.to_option ks.tool_calls with
  | None -> None
  | Some page ->
      let idx =
        Store_scroll.clamp_index (List.length page.entries) ks.selected_call_idx
      in
      List.nth_opt page.entries idx

let tool_result_for_selected_call ks =
  match selected_tool_call ks, Observed.to_option ks.tool_result with
  | Some { execution_id = Some eid; _ }, Some (stored_eid, res)
    when String.equal eid stored_eid ->
      Some res
  | _ -> None

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

let mark_tool_result_denied ~at ~keeper ?execution_id ~reason t =
  update_keeper ~keeper
    (fun ks ->
      let matches =
        match (execution_id, selected_tool_call ks) with
        | Some eid, Some { execution_id = Some cur; _ } -> String.equal cur eid
        | _ -> true
      in
      if not matches then ks
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

let apply_tool_result ~observed_at ~keeper ~execution_id resp t =
  update_keeper ~keeper
    (fun ks ->
      let matches =
        match selected_tool_call ks with
        | Some { execution_id = Some cur; _ } -> String.equal cur execution_id
        | _ -> true
      in
      if not matches then ks
      else
        {
          ks with
          tool_result = Observed.value ~observed_at (execution_id, resp);
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
            tool_stats = Observed.mark_stale ks.tool_stats;
            tool_calls = Observed.mark_stale ks.tool_calls;
            tool_calls_auth_denied = false;
            tool_result = Observed.mark_stale ks.tool_result;
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
  update_keeper ~keeper (fun ks -> { ks with oauth_pending_login = res }) t

let set_oauth_attempt_status ~keeper status t =
  update_keeper ~keeper (fun ks -> { ks with oauth_attempt_status = status }) t

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

let clear_running_github_logins t =
  {
    t with
    by_keeper =
      String_map.map
        (fun ks ->
          if ks.github_login.running then
            { ks with github_login = { ks.github_login with running = false } }
          else ks)
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
