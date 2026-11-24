open Masc_tui_core
open Masc_tui_keymap
open Masc_tui_protocol
open Masc_tui_ui

module String_map = Map.Make (String)

let max_logs = 512
let max_activity = 256

type activity_kind =
  | Activity_tool_call
  | Activity_turn_complete
  | Activity_agent_core
  | Activity_stream_gap

type activity_row = {
  at_unix : float;
  kind : activity_kind;
  keeper : string option;
  summary : string;
  detail : string option;
}

type repo_activity = {
  repo_id : string;
  activity : Wire_infra.repository_activity Observed.t;
}

type activity_source_filter =
  | Source_all
  | Source_logs
  | Source_events

type timeline_entry =
  | Entry_log of Wire_infra.system_log_entry
  | Entry_event of activity_row
module String_set = Set.Make (String)

type code_right_mode =
  | Code_file
  | Code_search_results
  | Code_git_status
  | Code_git_branches
  | Code_git_worktrees
  | Code_git_blame
  | Code_git_log
  | Code_git_diff

type code_state = {
  scope : Wire_infra.workspace_scope;
  expanded_dirs : String_set.t;
  children_by_dir : Wire_infra.workspace_tree_node list String_map.t;
  tree_loaded : bool;
  tree_selected_index : int;
  tree_scroll_offset : int;
  right_mode : code_right_mode;
  active_file_path : string option;
  open_file :
    (Wire_infra.workspace_scope * string * Wire_infra.workspace_file_content)
    Observed.t;
  file_scroll_offset : int;
  pending_jump_line : (string * int) option;
  files_catalog :
    (Wire_infra.workspace_scope * Wire_infra.workspace_files_catalog) Observed.t;
  search_result :
    (Wire_infra.workspace_scope * Wire_infra.workspace_search_result) Observed.t;
  search_selected_index : int;
  git_status :
    (Wire_infra.workspace_scope * Wire_infra.git_status_snapshot) Observed.t;
  git_branches :
    (Wire_infra.workspace_scope * Wire_infra.git_branch_entry list) Observed.t;
  git_worktrees :
    (Wire_infra.workspace_scope * Wire_infra.git_worktree_entry list) Observed.t;
  git_blame :
    (Wire_infra.workspace_scope * string * Wire_infra.git_blame_entry list)
    Observed.t;
  git_log :
    (Wire_infra.workspace_scope * string * Wire_infra.git_log_commit list)
    Observed.t;
  git_diff :
    (Wire_infra.workspace_scope * string * Wire_infra.git_diff_snapshot)
    Observed.t;
  git_scroll_offset : int;
}

let empty_code_state =
  {
    scope = Wire_infra.Ws_project;
    expanded_dirs = String_set.singleton "";
    children_by_dir = String_map.empty;
    tree_loaded = false;
    tree_selected_index = 0;
    tree_scroll_offset = 0;
    right_mode = Code_file;
    active_file_path = None;
    open_file = Observed.absent;
    file_scroll_offset = 0;
    pending_jump_line = None;
    files_catalog = Observed.unreported;
    search_result = Observed.absent;
    search_selected_index = 0;
    git_status = Observed.unreported;
    git_branches = Observed.unreported;
    git_worktrees = Observed.unreported;
    git_blame = Observed.absent;
    git_log = Observed.absent;
    git_diff = Observed.absent;
    git_scroll_offset = 0;
  }

type t = {
  active_tab : Nav.infra_tab;
  sandboxes : Wire_infra.sandboxes_snapshot Observed.t;
  sandboxes_fallback_404 : bool;
  keeper_sandboxes : Wire_infra.keeper_sandbox_response Observed.t String_map.t;
  repositories : Wire_infra.repository list Observed.t;
  repo_activity : repo_activity option;
  logs : Wire_infra.system_log_entry list;
  logs_loaded : bool;
  activity_events_loaded : bool;
  activity_seen_seqs : String_set.t;
  activity_seen_entries : (string * float) list;
  last_log_seq : int option;
  stream_gap_count : int;
  log_level_filter : Wire_infra.log_level option;
  log_keeper_filter : string option;
  source_filter : activity_source_filter;
  activity_events : activity_row list;
  acting_rail_open : bool;
  acting_selected_index : int;
  runtime_trace : (string * Wire_infra.runtime_trace_snapshot) Observed.t;
  code : code_state;
  show_raw_json : bool;
  selected_index : int;
  scroll_offset : int;
  diff_scroll_offset : int;
  change_selected_index : int;
  change_scroll_offset : int;
  detail_scroll_offset : int;
  filter_query : string;
}

let empty =
  {
    active_tab = Nav.Infra_sandboxes;
    sandboxes = Observed.unreported;
    sandboxes_fallback_404 = false;
    keeper_sandboxes = String_map.empty;
    repositories = Observed.unreported;
    repo_activity = None;
    logs = [];
    logs_loaded = false;
    activity_events_loaded = false;
    activity_seen_seqs = String_set.empty;
    activity_seen_entries = [];
    last_log_seq = None;
    stream_gap_count = 0;
    log_level_filter = None;
    log_keeper_filter = None;
    source_filter = Source_all;
    activity_events = [];
    acting_rail_open = false;
    acting_selected_index = 0;
    runtime_trace = Observed.absent;
    code = empty_code_state;
    show_raw_json = false;
    selected_index = 0;
    scroll_offset = 0;
    diff_scroll_offset = 0;
    change_selected_index = 0;
    change_scroll_offset = 0;
    detail_scroll_offset = 0;
    filter_query = "";
  }

let contains_ci = Store_scroll.contains_ci
let clamp_index = Store_scroll.clamp_index

let set_tab active_tab t =
  {
    t with
    active_tab;
    selected_index = 0;
    scroll_offset = 0;
    diff_scroll_offset = 0;
    change_selected_index = 0;
    change_scroll_offset = 0;
    detail_scroll_offset = 0;
  }

let cycle_tab dir t =
  let next_tab =
    match dir with
    | Keymap.Next -> Nav.next_infra_tab t.active_tab
    | Keymap.Prev -> Nav.prev_infra_tab t.active_tab
  in
  set_tab next_tab t

let apply_sandboxes ~observed_at sandboxes t =
  {
    t with
    sandboxes = Observed.value ~observed_at sandboxes;
    sandboxes_fallback_404 = false;
  }

let empty_tool_metrics_24h : Wire_infra.tool_metrics_24h =
  {
    calls = 0;
    failures = 0;
    failure_unclassified = 0;
    p50_ms = Observed.unreported;
    p95_ms = Observed.unreported;
    max_ms = Observed.unreported;
    failure_classes =
      {
        dependency_unavailable = 0;
        runtime_failure = 0;
        policy_rejection = 0;
        workflow_rejection = 0;
        operator_cancelled = 0;
      };
  }

let apply_sandboxes_fallback ~observed_at ~wall_unix
    ~(keepers : Wire_fleet.keeper_summary list) ~sandbox_profiles
    ~tool_series_totals t =
  let running_tbl = Hashtbl.create 32 in
  List.iter
    (fun (k : Wire_fleet.keeper_summary) ->
      Hashtbl.replace running_tbl k.name (k.keepalive_running && not k.paused))
    keepers;
  let microvms = ref [] in
  let ssh_unbound = ref [] in
  let dockers = ref [] in
  List.iter
    (fun (keeper, prof) ->
      let is_running =
        Option.value ~default:false (Hashtbl.find_opt running_tbl keeper)
      in
      match prof with
      | Wire_fleet.Profile_microvm ->
          (* Without /api/v1/infra/sandboxes we have no live agent socket
             observation: NEVER report presence="running" or increment
             microvm_running while agent_socket is Socket_absent. *)
          let guest : Wire_infra.microvm_guest =
            {
              keeper;
              backend = "apple_container";
              guest_name = "masc-" ^ keeper;
              presence = "unobserved";
              agent_socket = Wire_infra.Socket_absent { path_basename = None };
              shim_parity = Wire_infra.Shim_undeclared;
              network_mode = Wire_infra.Net_inherit;
              cpus = Observed.unreported;
              memory_mib = Observed.unreported;
              volume = Wire_infra.Volume_declared ("masc-vol-" ^ keeper);
              metrics_24h = empty_tool_metrics_24h;
            }
          in
          microvms := guest :: !microvms
      | Wire_fleet.Profile_remote_ssh ->
          let row : Wire_infra.ssh_unbound_keeper =
            {
              keeper;
              backend = "remote_ssh";
              binding_state = (if is_running then "active" else "idle");
              remote_endpoint = None;
              metrics_24h = empty_tool_metrics_24h;
            }
          in
          ssh_unbound := row :: !ssh_unbound
      | Wire_fleet.Profile_docker ->
          let row : Wire_infra.docker_keeper =
            {
              keeper;
              backend = "docker";
              network_mode = Wire_infra.Net_none;
              metrics_24h = empty_tool_metrics_24h;
            }
          in
          dockers := row :: !dockers
      | Wire_fleet.Profile_other _ -> ())
    sandbox_profiles;
  let fleet_metrics_24h =
    match tool_series_totals with
    | None -> empty_tool_metrics_24h
    | Some (calls, failures, p95_opt) ->
        let p95_ms =
          match p95_opt with
          | Some v -> Observed.value ~observed_at v
          | None -> Observed.unreported
        in
        {
          empty_tool_metrics_24h with
          calls;
          failures;
          failure_unclassified = failures;
          p95_ms;
        }
  in
  let microvm_guests =
    List.sort
      (fun (a : Wire_infra.microvm_guest) b -> String.compare a.keeper b.keeper)
      !microvms
  in
  let ssh_unbound_keepers =
    List.sort
      (fun (a : Wire_infra.ssh_unbound_keeper) b ->
        String.compare a.keeper b.keeper)
      !ssh_unbound
  in
  let docker_keepers =
    List.sort
      (fun (a : Wire_infra.docker_keeper) b -> String.compare a.keeper b.keeper)
      !dockers
  in
  let snapshot : Wire_infra.sandboxes_snapshot =
    {
      probe_state = Wire_infra.Probe_stale wall_unix;
      microvm_declared = List.length microvm_guests;
      microvm_running = 0;
      microvm_sockets_present = 0;
      microvm_shim_mismatch = 0;
      ssh_pools_count = 0;
      ssh_keepers_count = List.length ssh_unbound_keepers;
      ssh_unbound_keepers_count = List.length ssh_unbound_keepers;
      ssh_active_sessions = Observed.unreported;
      ssh_max_sessions = 0;
      docker_keepers_count = List.length docker_keepers;
      microvm_guests;
      ssh_pools = [];
      ssh_unbound_keepers;
      docker_keepers;
      fleet_metrics_24h;
      volume_gc_report = None;
      host_storage = None;
      unobserved_reasons =
        [
          {
            scope = "infra_sandboxes";
            reason = "derived_from_gate_keepers_404_fallback";
          };
        ];
    }
  in
  {
    t with
    sandboxes = Observed.value ~observed_at snapshot;
    sandboxes_fallback_404 = true;
  }

let keeper_sandbox_for ~keeper t =
  match String_map.find_opt keeper t.keeper_sandboxes with
  | Some obs -> obs
  | None -> Observed.unreported

let set_keeper_sandbox ~keeper obs t =
  { t with keeper_sandboxes = String_map.add keeper obs t.keeper_sandboxes }

let apply_repositories ~observed_at repositories t =
  { t with repositories = Observed.value ~observed_at repositories }

let max_seq_of entries =
  List.fold_left
    (fun acc (e : Wire_infra.system_log_entry) ->
      match acc with None -> Some e.seq | Some s -> Some (max s e.seq))
    None entries

let apply_log_snapshot entries t =
  let sorted_desc =
    List.stable_sort
      (fun (a : Wire_infra.system_log_entry) (b : Wire_infra.system_log_entry) ->
        Int.compare b.seq a.seq)
      entries
  in
  let bounded = List.take max_logs sorted_desc in
  let last_log_seq =
    match max_seq_of bounded, t.last_log_seq with
    | Some a, Some b -> Some (max a b)
    | Some a, None -> Some a
    | None, b -> b
  in
  { t with logs = bounded; logs_loaded = true; last_log_seq }

let record_stream_gap dropped t =
  if dropped <= 0 then t
  else { t with stream_gap_count = t.stream_gap_count + dropped }

let log_level_rank = function
  | Wire_infra.Log_debug -> 0
  | Wire_infra.Log_info -> 1
  | Wire_infra.Log_warn -> 2
  | Wire_infra.Log_error -> 3

let visible_logs t =
  let q = String.trim t.filter_query in
  List.filter
    (fun (e : Wire_infra.system_log_entry) ->
      let level_ok =
        match t.log_level_filter with
        | None -> true
        | Some min_level -> log_level_rank e.level >= log_level_rank min_level
      in
      let keeper_ok =
        match t.log_keeper_filter with
        | None -> true
        | Some want -> (
            match e.keeper with
            | Some k -> String.equal k want
            | None -> false)
      in
      let query_ok =
        if String.equal q "" then true
        else
          contains_ci ~needle:q e.message
          || contains_ci ~needle:q e.module_name
          || contains_ci ~needle:q e.source
          ||
          match e.keeper with
          | Some k -> contains_ci ~needle:q k
          | None -> false
      in
      level_ok && keeper_ok && query_ok)
    t.logs

let activity_kind_str = function
  | Activity_tool_call -> "TOOL"
  | Activity_turn_complete -> "TURN"
  | Activity_agent_core -> "CORE"
  | Activity_stream_gap -> "GAP"

let visible_activity_events t =
  let q = String.trim t.filter_query in
  List.filter
    (fun (ev : activity_row) ->
      let keeper_ok =
        match t.log_keeper_filter with
        | None -> true
        | Some want -> (
            match ev.keeper with
            | Some k -> String.equal k want
            | None -> false)
      in
      let query_ok =
        if String.equal q "" then true
        else
          contains_ci ~needle:q ev.summary
          || contains_ci ~needle:q (activity_kind_str ev.kind)
          || (match ev.keeper with Some k -> contains_ci ~needle:q k | None -> false)
          ||
          match ev.detail with
          | Some d -> contains_ci ~needle:q d
          | None -> false
      in
      keeper_ok && query_ok)
    t.activity_events

let entry_timestamp_unix = function
  | Entry_log e -> (
      match Wire_common.parse_rfc3339_unix e.ts with
      | Ok ts when Float.is_finite ts -> ts
      | Ok _ | Error _ -> 0.0)
  | Entry_event ev ->
      if Float.is_finite ev.at_unix then ev.at_unix else 0.0

let visible_timeline t =
  match t.source_filter with
  | Source_logs -> List.map (fun e -> Entry_log e) (visible_logs t)
  | Source_events ->
      List.map (fun ev -> Entry_event ev) (visible_activity_events t)
  | Source_all ->
      let logs = List.map (fun e -> Entry_log e) (visible_logs t) in
      let events =
        List.map (fun ev -> Entry_event ev) (visible_activity_events t)
      in
      if events = [] then logs
      else if logs = [] then events
      else
        List.stable_sort
          (fun a b ->
            Float.compare (entry_timestamp_unix b) (entry_timestamp_unix a))
          (logs @ events)

let same_timeline_entry a b =
  match a, b with
  | Entry_log ea, Entry_log eb -> Int.equal ea.seq eb.seq
  | Entry_event eva, Entry_event evb ->
      Float.equal eva.at_unix evb.at_unix
      && String.equal eva.summary evb.summary
      && Option.equal String.equal eva.keeper evb.keeper
  | Entry_log _, Entry_event _ | Entry_event _, Entry_log _ -> false

(* Preserve the reader's selected entry when live SSE prepends new items while
   scrolled off the newest row (selected_index > 0). Index 0 stays pinned to
   the live tail head. *)
let anchor_timeline_selection ~prev_t next_t =
  if
    not
      (Nav.equal_infra_tab prev_t.active_tab Nav.Infra_activity_logs
      && prev_t.selected_index > 0)
  then next_t
  else
    let prev_vis = visible_timeline prev_t in
    let prev_idx = clamp_index (List.length prev_vis) prev_t.selected_index in
    match List.nth_opt prev_vis prev_idx with
    | None -> next_t
    | Some anchor ->
        let next_vis = visible_timeline next_t in
        let rec find i = function
          | [] -> None
          | x :: rest ->
              if same_timeline_entry anchor x then Some i else find (i + 1) rest
        in
        (match find 0 next_vis with
         | Some new_idx ->
             let shift = new_idx - prev_idx in
             let scroll_offset = max 0 (prev_t.scroll_offset + shift) in
             { next_t with selected_index = new_idx; scroll_offset }
         | None ->
             let clamped = clamp_index (List.length next_vis) prev_idx in
             { next_t with selected_index = clamped })

let append_log (entry : Wire_infra.system_log_entry) t =
  let exists =
    List.exists
      (fun (e : Wire_infra.system_log_entry) -> Int.equal e.seq entry.seq)
      t.logs
  in
  let logs =
    if exists then t.logs else List.take max_logs (entry :: t.logs)
  in
  let last_log_seq =
    match t.last_log_seq with
    | None -> Some entry.seq
    | Some prev -> Some (max prev entry.seq)
  in
  let next = { t with logs; logs_loaded = true; last_log_seq } in
  if exists then next else anchor_timeline_selection ~prev_t:t next

(* A reset frame replaces the list and the cursor. After a server restart the
   ring numbers from zero again, so keeping the old entries would drop every
   new line whose seq an old one already had, and keeping the old maximum
   would hand the next stream a cursor from the previous run. *)
let apply_log_frame ({ reset; entries } : Wire_infra.system_log_frame) t =
  if reset then
    let bounded =
      entries
      |> List.stable_sort
           (fun (a : Wire_infra.system_log_entry) (b : Wire_infra.system_log_entry) ->
             Int.compare b.seq a.seq)
      |> List.take max_logs
    in
    { t with logs = bounded; logs_loaded = true; last_log_seq = max_seq_of bounded }
  else List.fold_left (fun acc entry -> append_log entry acc) t (List.rev entries)

let push_activity row t =
  let next =
    {
      t with
      activity_events = List.take max_activity (row :: t.activity_events);
    }
  in
  anchor_timeline_selection ~prev_t:t next

let set_source_filter source_filter t =
  {
    t with
    source_filter;
    selected_index = 0;
    scroll_offset = 0;
    detail_scroll_offset = 0;
  }

let cycle_source_filter t =
  let next =
    match t.source_filter with
    | Source_all -> Source_logs
    | Source_logs -> Source_events
    | Source_events -> Source_all
  in
  set_source_filter next t

let set_log_level_filter log_level_filter t =
  {
    t with
    log_level_filter;
    selected_index = 0;
    scroll_offset = 0;
    detail_scroll_offset = 0;
  }

let cycle_log_level_filter t =
  let next =
    match t.log_level_filter with
    | None -> Some Wire_infra.Log_debug
    | Some Wire_infra.Log_debug -> Some Wire_infra.Log_info
    | Some Wire_infra.Log_info -> Some Wire_infra.Log_warn
    | Some Wire_infra.Log_warn -> Some Wire_infra.Log_error
    | Some Wire_infra.Log_error -> None
  in
  set_log_level_filter next t

let set_log_keeper_filter log_keeper_filter t =
  {
    t with
    log_keeper_filter;
    selected_index = 0;
    scroll_offset = 0;
    detail_scroll_offset = 0;
  }

let toggle_raw_json t = { t with show_raw_json = not t.show_raw_json }

let filtered_sandbox_keepers t =
  let q = String.trim t.filter_query in
  match Observed.to_option t.sandboxes with
  | None -> []
  | Some s ->
      let matches haystack =
        String.equal q "" || contains_ci ~needle:q haystack
      in
      let microvms =
        List.filter_map
          (fun (g : Wire_infra.microvm_guest) ->
            if matches (g.keeper ^ " " ^ g.guest_name ^ " " ^ g.backend) then
              Some g.keeper
            else None)
          s.microvm_guests
      in
      let ssh_bound =
        List.concat_map
          (fun (p : Wire_infra.ssh_pool) ->
            List.filter_map
              (fun (ks : Wire_infra.ssh_keeper_session) ->
                if matches (ks.keeper ^ " " ^ p.pool_name ^ " " ^ p.host ^ " ssh")
                then Some ks.keeper
                else None)
              p.keeper_sessions)
          s.ssh_pools
      in
      let ssh_unbound =
        List.filter_map
          (fun (u : Wire_infra.ssh_unbound_keeper) ->
            if matches (u.keeper ^ " " ^ u.backend ^ " ssh") then Some u.keeper
            else None)
          s.ssh_unbound_keepers
      in
      let docker =
        List.filter_map
          (fun (d : Wire_infra.docker_keeper) ->
            if matches (d.keeper ^ " " ^ d.backend ^ " docker") then
              Some d.keeper
            else None)
          s.docker_keepers
      in
      microvms @ ssh_bound @ ssh_unbound @ docker

let repo_matches_metadata ~needle (r : Wire_infra.repository) =
  contains_ci ~needle r.name
  || contains_ci ~needle r.url
  || contains_ci ~needle r.default_branch

let change_matches ~needle (fc : Wire_infra.file_change) =
  contains_ci ~needle fc.path || contains_ci ~needle fc.keeper

let loaded_activity_matches ~needle ~repo_id t =
  match t.repo_activity with
  | Some slot when String.equal slot.repo_id repo_id -> (
      match Observed.to_option slot.activity with
      | Some activity -> List.exists (change_matches ~needle) activity.changes
      | None -> false)
  | Some _ | None -> false

let filtered_repositories t =
  let all =
    match Observed.to_option t.repositories with Some rs -> rs | None -> []
  in
  let q = String.trim t.filter_query in
  if String.equal q "" then all
  else
    let by_repo =
      List.filter
        (fun (r : Wire_infra.repository) ->
          repo_matches_metadata ~needle:q r
          || List.exists (fun kp -> contains_ci ~needle:q kp) r.keepers)
        all
    in
    match by_repo with
    | _ :: _ -> by_repo
    | [] ->
        List.filter
          (fun (r : Wire_infra.repository) ->
            loaded_activity_matches ~needle:q ~repo_id:r.id t)
          all

let selected_sandbox_keeper t =
  let names = filtered_sandbox_keepers t in
  List.nth_opt names (clamp_index (List.length names) t.selected_index)

let selected_repository t =
  let repos = filtered_repositories t in
  List.nth_opt repos (clamp_index (List.length repos) t.selected_index)

(* The changes panel shows one repository's activity at a time: the slot
   names the repository it answers for, and a slot for any other repository
   is a wait for the selected one. *)
let waiting_activity = Observed.loading ~since_ns:Clock.Mono.zero

let activity_for ~repo_id t =
  match t.repo_activity with
  | Some slot when String.equal slot.repo_id repo_id -> slot.activity
  | Some _ | None -> waiting_activity

let is_selected_repository ~repo_id t =
  match selected_repository t with
  | Some r -> String.equal r.id repo_id
  | None -> false

let reset_change_cursor t =
  { t with change_selected_index = 0; change_scroll_offset = 0; diff_scroll_offset = 0 }

let request_repo_activity ~repo_id t =
  match t.repo_activity with
  | Some slot when String.equal slot.repo_id repo_id -> t
  | Some _ | None ->
      reset_change_cursor
        { t with repo_activity = Some { repo_id; activity = waiting_activity } }

let apply_repo_activity ~repo_id ~observed_at activity t =
  if is_selected_repository ~repo_id t then
    reset_change_cursor
      {
        t with
        repo_activity =
          Some { repo_id; activity = Observed.value ~observed_at activity };
      }
  else t

let fail_repo_activity ~repo_id fail t =
  if is_selected_repository ~repo_id t then
    {
      t with
      repo_activity =
        Some { repo_id; activity = fail (activity_for ~repo_id t) };
    }
  else t

let selected_repo_activity t =
  Option.map
    (fun (r : Wire_infra.repository) -> (r, activity_for ~repo_id:r.id t))
    (selected_repository t)

let repo_changes t =
  match selected_repo_activity t with
  | None -> []
  | Some (repo, activity_obs) -> (
      match Observed.to_option activity_obs with
      | None -> []
      | Some (activity : Wire_infra.repository_activity) ->
          let q = String.trim t.filter_query in
          if String.equal q "" || repo_matches_metadata ~needle:q repo then
            activity.changes
          else List.filter (change_matches ~needle:q) activity.changes)

let selected_change t =
  let changes = repo_changes t in
  List.nth_opt changes
    (clamp_index (List.length changes) t.change_selected_index)

let unnumbered rows =
  List.map (fun nrow -> { Diff.nrow; old_line = None; new_line = None }) rows

let change_preview_rows (fc : Wire_infra.file_change) =
  match fc.change with
  | Wire_infra.Change_edit { before; after; _ } -> (
      let rows = Diff.rows ~before ~after in
      match fc.line_evidence with
      | Some (Wire_infra.Edit_ranges (first :: _)) ->
          Diff.number ~old_start:first.old_range.start_line
            ~new_start:
              (Option.map
                 (fun (range : Wire_infra.line_range) -> range.start_line)
                 first.new_range)
            rows
      | Some
          ( Wire_infra.Edit_ranges []
          | Wire_infra.Edit_ranges_omitted
          | Wire_infra.Write_range _ )
      | None ->
          (* No recorded position: the rows carry no line numbers rather than
             numbers counted from an invented start. *)
          unnumbered rows)
  | Wire_infra.Change_write { content } ->
      Diff.number ~old_start:1 ~new_start:(Some 1)
        (Diff.rows ~before:"" ~after:content)
  | Wire_infra.Change_insert { line; text } ->
      Diff.number ~old_start:line ~new_start:(Some line)
        (Diff.rows ~before:"" ~after:text)
  | Wire_infra.Change_materialize _ -> []

let selected_timeline_entry t =
  let vis = visible_timeline t in
  List.nth_opt vis (clamp_index (List.length vis) t.selected_index)

let selected_log t =
  match selected_timeline_entry t with
  | Some (Entry_log e) -> Some e
  | Some (Entry_event _) | None -> None

let sandbox_inspector_event_count ~keeper t =
  let keeper_logs =
    List.filter
      (fun (e : Wire_infra.system_log_entry) ->
        match e.keeper with Some k -> String.equal k keeper | None -> false)
      t.logs
  in
  let display_logs =
    if keeper_logs <> [] then keeper_logs
    else
      List.filter
        (fun (e : Wire_infra.system_log_entry) ->
          contains_ci ~needle:"sandbox" e.source
          || contains_ci ~needle:"vm" e.module_name
          || contains_ci ~needle:"ssh" e.module_name)
        t.logs
  in
  let keeper_acts =
    List.filter
      (fun (ev : activity_row) ->
        match ev.keeper with Some k -> String.equal k keeper | None -> false)
      t.activity_events
  in
  List.length display_logs + List.length keeper_acts

let adjust_scroll = Store_scroll.adjust_scroll

let reset_detail_scroll t = { t with detail_scroll_offset = 0; diff_scroll_offset = 0 }

let move_selection ?(pane_index = 0) ?viewport_rows ?max_detail_scroll ~delta t =
  match t.active_tab with
  | Nav.Infra_sandboxes ->
      if pane_index = 1 then
        let max_scroll =
          match max_detail_scroll with
          | Some ms -> max 0 ms
          | None -> (
              match selected_sandbox_keeper t with
              | Some kp ->
                  let vis = max 1 (Option.value viewport_rows ~default:8) in
                  max 0 (sandbox_inspector_event_count ~keeper:kp t - vis)
              | None -> 0)
        in
        let detail_scroll_offset =
          Store_scroll.clamp_scroll ~max_scroll
            (t.detail_scroll_offset + delta)
        in
        { t with detail_scroll_offset }
      else
        let len = List.length (filtered_sandbox_keepers t) in
        let selected_index = clamp_index len (t.selected_index + delta) in
        let scroll_offset =
          adjust_scroll ?viewport_rows ~scroll:t.scroll_offset selected_index
        in
        let detail_scroll_offset =
          if Int.equal selected_index t.selected_index then
            t.detail_scroll_offset
          else 0
        in
        { t with selected_index; scroll_offset; detail_scroll_offset }
  | Nav.Infra_repos_changes -> (
      let has_changes = repo_changes t <> [] in
      let is_changes_pane = has_changes && pane_index = 1 in
      let is_diff_pane =
        if has_changes then pane_index = 2 else pane_index = 1
      in
      if is_diff_pane then
        let max_scroll =
          match max_detail_scroll with
          | Some ms -> max 0 ms
          | None -> (
              match selected_change t with
              | Some fc ->
                  let vis =
                    max 1
                      (Option.value viewport_rows
                         ~default:Store_scroll.default_viewport_rows)
                  in
                  max 0 (List.length (change_preview_rows fc) - vis)
              | None -> 0)
        in
        let diff_scroll_offset =
          Store_scroll.clamp_scroll ~max_scroll (t.diff_scroll_offset + delta)
        in
        { t with diff_scroll_offset }
      else if is_changes_pane then
        let len = List.length (repo_changes t) in
        let change_selected_index =
          clamp_index len (t.change_selected_index + delta)
        in
        let change_scroll_offset =
          adjust_scroll ?viewport_rows ~scroll:t.change_scroll_offset
            change_selected_index
        in
        let diff_scroll_offset =
          if Int.equal change_selected_index t.change_selected_index then
            t.diff_scroll_offset
          else 0
        in
        {
          t with
          change_selected_index;
          change_scroll_offset;
          diff_scroll_offset;
        }
      else
        let len = List.length (filtered_repositories t) in
        let selected_index = clamp_index len (t.selected_index + delta) in
        let scroll_offset =
          adjust_scroll ?viewport_rows ~scroll:t.scroll_offset selected_index
        in
        if Int.equal selected_index t.selected_index then
          { t with selected_index; scroll_offset }
        else
          {
            t with
            selected_index;
            scroll_offset;
            change_selected_index = 0;
            change_scroll_offset = 0;
            diff_scroll_offset = 0;
          })
  | Nav.Infra_code ->
      if pane_index = 1 then
        match t.code.right_mode with
        | Code_file ->
            let max_scroll =
              match max_detail_scroll with
              | Some ms -> max 0 ms
              | None -> (
                  match Observed.to_option t.code.open_file with
                  | Some (sc, _, fc)
                    when Wire_infra.equal_workspace_scope sc t.code.scope ->
                      let vis = max 1 (Option.value viewport_rows ~default:15) in
                      max 0
                        (List.length (String.split_on_char '\n' fc.content) - vis)
                  | Some _ | None -> 0)
            in
            let file_scroll_offset =
              Store_scroll.clamp_scroll ~max_scroll
                (t.code.file_scroll_offset + delta)
            in
            { t with code = { t.code with file_scroll_offset } }
        | Code_search_results ->
            let len =
              match Observed.to_option t.code.search_result with
              | Some (sc, sr)
                when Wire_infra.equal_workspace_scope sc t.code.scope ->
                  List.length sr.matches
              | Some _ | None -> 0
            in
            let search_selected_index =
              clamp_index len (t.code.search_selected_index + delta)
            in
            let git_scroll_offset =
              adjust_scroll ?viewport_rows ~scroll:t.code.git_scroll_offset
                search_selected_index
            in
            {
              t with
              code = { t.code with search_selected_index; git_scroll_offset };
            }
        | Code_git_status
        | Code_git_branches
        | Code_git_worktrees
        | Code_git_blame
        | Code_git_log
        | Code_git_diff ->
            let max_scroll =
              match max_detail_scroll with Some ms -> max 0 ms | None -> 0
            in
            let git_scroll_offset =
              Store_scroll.clamp_scroll ~max_scroll
                (t.code.git_scroll_offset + delta)
            in
            { t with code = { t.code with git_scroll_offset } }
      else
        let rec flatten_dir dir =
          match String_map.find_opt dir t.code.children_by_dir with
          | None -> []
          | Some nodes ->
              List.concat_map
                (fun (n : Wire_infra.workspace_tree_node) ->
                  if n.has_children && String_set.mem n.path t.code.expanded_dirs
                  then n :: flatten_dir n.path
                  else [ n ])
                nodes
        in
        let all_nodes = flatten_dir "" in
        let q = String.trim t.filter_query in
        let nodes =
          if String.equal q "" then all_nodes
          else
            List.filter
              (fun (n : Wire_infra.workspace_tree_node) ->
                contains_ci ~needle:q n.path || contains_ci ~needle:q n.label)
              all_nodes
        in
        let len = List.length nodes in
        let tree_selected_index =
          clamp_index len (t.code.tree_selected_index + delta)
        in
        let tree_scroll_offset =
          adjust_scroll ?viewport_rows ~scroll:t.code.tree_scroll_offset
            tree_selected_index
        in
        let active_file_path, git_scroll_offset =
          match t.code.right_mode with
          | Code_git_blame | Code_git_log | Code_git_diff -> (
              match List.nth_opt nodes tree_selected_index with
              | Some n when not n.has_children ->
                  let changed =
                    not
                      (Option.equal String.equal t.code.active_file_path
                         (Some n.path))
                  in
                  (Some n.path, if changed then 0 else t.code.git_scroll_offset)
              | Some _ | None ->
                  (t.code.active_file_path, t.code.git_scroll_offset))
          | Code_file
          | Code_search_results
          | Code_git_status
          | Code_git_branches
          | Code_git_worktrees ->
              (t.code.active_file_path, t.code.git_scroll_offset)
        in
        {
          t with
          code =
            {
              t.code with
              tree_selected_index;
              tree_scroll_offset;
              active_file_path;
              git_scroll_offset;
            };
        }
  | Nav.Infra_activity_logs ->
      if pane_index = 1 then
        let max_scroll =
          match max_detail_scroll with
          | Some ms -> max 0 ms
          | None -> (
              match selected_timeline_entry t with
              | Some (Entry_log e) ->
                  let vis = max 1 (Option.value viewport_rows ~default:8) in
                  let total =
                    List.length
                      (Json_tree.flatten ~max_depth:4 ~redact_secrets:true
                         e.details)
                  in
                  max 0 (total - vis)
              | Some (Entry_event ev) ->
                  let vis = max 1 (Option.value viewport_rows ~default:8) in
                  let detail_lines =
                    match ev.detail with
                    | Some d -> List.length (String.split_on_char '\n' d)
                    | None -> 0
                  in
                  max 0 (4 + detail_lines - vis)
              | None -> 0)
        in
        let detail_scroll_offset =
          Store_scroll.clamp_scroll ~max_scroll
            (t.detail_scroll_offset + delta)
        in
        { t with detail_scroll_offset }
      else
        let len = List.length (visible_timeline t) in
        let selected_index = clamp_index len (t.selected_index + delta) in
        let scroll_offset =
          adjust_scroll ?viewport_rows ~scroll:t.scroll_offset selected_index
        in
        let detail_scroll_offset =
          if Int.equal selected_index t.selected_index then
            t.detail_scroll_offset
          else 0
        in
        { t with selected_index; scroll_offset; detail_scroll_offset }

let set_filter filter_query t =
  {
    t with
    filter_query;
    selected_index = 0;
    scroll_offset = 0;
    diff_scroll_offset = 0;
    change_selected_index = 0;
    change_scroll_offset = 0;
    detail_scroll_offset = 0;
  }

let mark_stale_all t =
  {
    t with
    sandboxes = Observed.mark_stale t.sandboxes;
    keeper_sandboxes = String_map.map Observed.mark_stale t.keeper_sandboxes;
    repositories = Observed.mark_stale t.repositories;
    repo_activity =
      Option.map
        (fun slot -> { slot with activity = Observed.mark_stale slot.activity })
        t.repo_activity;
    runtime_trace = Observed.mark_stale t.runtime_trace;
    activity_seen_seqs = String_set.empty;
    activity_seen_entries = [];
    code =
      {
        t.code with
        open_file = Observed.mark_stale t.code.open_file;
        files_catalog = Observed.mark_stale t.code.files_catalog;
        search_result = Observed.mark_stale t.code.search_result;
        git_status = Observed.mark_stale t.code.git_status;
        git_branches = Observed.mark_stale t.code.git_branches;
        git_worktrees = Observed.mark_stale t.code.git_worktrees;
        git_blame = Observed.mark_stale t.code.git_blame;
        git_log = Observed.mark_stale t.code.git_log;
        git_diff = Observed.mark_stale t.code.git_diff;
      };
  }

let forget_log_cursor t =
  {
    t with
    last_log_seq = None;
    logs_loaded = false;
    activity_events_loaded = false;
    activity_seen_seqs = String_set.empty;
    activity_seen_entries = [];
  }

let activity_kind_rank = function
  | Activity_tool_call -> 0
  | Activity_turn_complete -> 1
  | Activity_agent_core -> 2
  | Activity_stream_gap -> 3

let equal_activity_row (a : activity_row) (b : activity_row) =
  Float.equal a.at_unix b.at_unix
  && Int.equal (activity_kind_rank a.kind) (activity_kind_rank b.kind)
  && Option.equal String.equal a.keeper b.keeper
  && String.equal a.summary b.summary
  && Option.equal String.equal a.detail b.detail

let activity_kind_of_wire kind =
  let k = String.lowercase_ascii kind in
  if String.starts_with ~prefix:"tool" k then Activity_tool_call
  else if String.starts_with ~prefix:"turn" k then Activity_turn_complete
  else Activity_agent_core

let apply_activity_events_backfill (items : Wire_infra.activity_event_item list) t =
  let sorted_items =
    List.sort
      (fun (a : Wire_infra.activity_event_item) b -> Int.compare b.seq a.seq)
      items
  in
  let _seen, rev_rows, rev_entries =
    List.fold_left
      (fun (seen_acc, rows_acc, entries_acc)
           (ev : Wire_infra.activity_event_item) ->
        let key = Int.to_string ev.seq in
        if String_set.mem key seen_acc then (seen_acc, rows_acc, entries_acc)
        else
          let summary =
            match ev.subject_id with
            | Some subj -> Printf.sprintf "%s (%s)" ev.kind subj
            | None -> ev.kind
          in
          let detail =
            match ev.payload with
            | `Null | `Assoc [] -> None
            | p -> Some (Yojson.Safe.pretty_to_string p)
          in
          let row =
            {
              at_unix = float_of_int ev.ts_ms /. 1000.0;
              kind = activity_kind_of_wire ev.kind;
              keeper = ev.actor_id;
              summary;
              detail;
            }
          in
          let seen_acc' = String_set.add key seen_acc in
          let entries_acc' = (key, row.at_unix) :: entries_acc in
          let rows_acc' =
            if List.exists (equal_activity_row row) t.activity_events then
              rows_acc
            else row :: rows_acc
          in
          (seen_acc', rows_acc', entries_acc'))
      (t.activity_seen_seqs, [], []) sorted_items
  in
  let new_rows = List.rev rev_rows in
  let new_entries = List.rev rev_entries in
  let rec take n acc = function
    | [] -> List.rev acc
    | _ when n <= 0 -> List.rev acc
    | x :: xs -> take (n - 1) (x :: acc) xs
  in
  let combined =
    let merged =
      List.stable_sort
        (fun a b -> Float.compare b.at_unix a.at_unix)
        (new_rows @ t.activity_events)
    in
    take max_activity [] merged
  in
  let min_retained_at =
    if List.length combined < max_activity then None
    else
      match List.rev combined with
      | oldest :: _ -> Some oldest.at_unix
      | [] -> None
  in
  let retained_entries =
    let sorted_entries =
      List.stable_sort
        (fun (_, a) (_, b) -> Float.compare b a)
        (new_entries @ t.activity_seen_entries)
    in
    let rec dedup_take n seen acc = function
      | [] -> List.rev acc
      | _ when n <= 0 -> List.rev acc
      | (k, ts) :: rest ->
          let in_window =
            match min_retained_at with
            | Some min_ts -> ts >= min_ts
            | None -> true
          in
          if (not in_window) || String_set.mem k seen then
            dedup_take n seen acc rest
          else dedup_take (n - 1) (String_set.add k seen) ((k, ts) :: acc) rest
    in
    dedup_take max_activity String_set.empty [] sorted_entries
  in
  let activity_seen_seqs =
    List.fold_left
      (fun acc (k, _) -> String_set.add k acc)
      String_set.empty retained_entries
  in
  {
    t with
    activity_events = combined;
    activity_events_loaded = true;
    activity_seen_seqs;
    activity_seen_entries = retained_entries;
  }

let toggle_acting_rail t =
  { t with acting_rail_open = not t.acting_rail_open; acting_selected_index = 0 }

let move_acting_selection ~count ~delta t =
  {
    t with
    acting_selected_index = clamp_index count (t.acting_selected_index + delta);
  }

let apply_runtime_trace ~observed_at ~keeper snap t =
  { t with runtime_trace = Observed.value ~observed_at (keeper, snap) }

let runtime_trace_for ~keeper t =
  match Observed.to_option t.runtime_trace with
  | Some (k, snap) when String.equal k keeper -> Some snap
  | Some _ | None -> None

let code_right_mode_rank = function
  | Code_file -> 0
  | Code_search_results -> 1
  | Code_git_status -> 2
  | Code_git_branches -> 3
  | Code_git_worktrees -> 4
  | Code_git_blame -> 5
  | Code_git_log -> 6
  | Code_git_diff -> 7

let equal_code_right_mode a b =
  Int.equal (code_right_mode_rank a) (code_right_mode_rank b)

let code_right_mode_label = function
  | Code_file -> Say.make ~ko:"파일" ~en:"File"
  | Code_search_results -> Say.make ~ko:"검색 결과" ~en:"Search"
  | Code_git_status -> Say.make ~ko:"Git 상태" ~en:"Git Status"
  | Code_git_branches -> Say.make ~ko:"브랜치" ~en:"Branches"
  | Code_git_worktrees -> Say.make ~ko:"워크트리" ~en:"Worktrees"
  | Code_git_blame -> Say.make ~ko:"Blame" ~en:"Blame"
  | Code_git_log -> Say.make ~ko:"Git 로그" ~en:"Git Log"
  | Code_git_diff -> Say.make ~ko:"Git Diff" ~en:"Git Diff"

let set_code_right_mode right_mode t =
  { t with code = { t.code with right_mode; git_scroll_offset = 0 } }

let cycle_code_git_mode t =
  let next =
    match t.code.right_mode with
    | Code_file | Code_search_results -> Code_git_status
    | Code_git_status -> Code_git_branches
    | Code_git_branches -> Code_git_worktrees
    | Code_git_worktrees -> Code_git_blame
    | Code_git_blame -> Code_git_log
    | Code_git_log -> Code_git_diff
    | Code_git_diff -> Code_file
  in
  set_code_right_mode next t

let set_code_scope scope t =
  if Wire_infra.equal_workspace_scope scope t.code.scope then t
  else { t with code = { empty_code_state with scope } }

let visible_code_tree_nodes t =
  let rec flatten_dir dir =
    match String_map.find_opt dir t.code.children_by_dir with
    | None -> []
    | Some nodes ->
        List.concat_map
          (fun (n : Wire_infra.workspace_tree_node) ->
            if n.has_children && String_set.mem n.path t.code.expanded_dirs then
              n :: flatten_dir n.path
            else [ n ])
          nodes
  in
  let all_nodes = flatten_dir "" in
  let q = String.trim t.filter_query in
  if String.equal q "" then all_nodes
  else
    List.filter
      (fun (n : Wire_infra.workspace_tree_node) ->
        contains_ci ~needle:q n.path || contains_ci ~needle:q n.label)
      all_nodes

let selected_code_tree_node t =
  let nodes = visible_code_tree_nodes t in
  List.nth_opt nodes (clamp_index (List.length nodes) t.code.tree_selected_index)

let toggle_code_dir dir t =
  let expanded_dirs =
    if String_set.mem dir t.code.expanded_dirs then
      String_set.remove dir t.code.expanded_dirs
    else String_set.add dir t.code.expanded_dirs
  in
  { t with code = { t.code with expanded_dirs } }

let apply_workspace_children ~scope ~dir nodes t =
  if not (Wire_infra.equal_workspace_scope scope t.code.scope) then t
  else
    let children_by_dir = String_map.add dir nodes t.code.children_by_dir in
    let tree_loaded = t.code.tree_loaded || String.equal dir "" in
    { t with code = { t.code with children_by_dir; tree_loaded } }

let apply_workspace_files ~observed_at ~scope catalog t =
  if not (Wire_infra.equal_workspace_scope scope t.code.scope) then t
  else
    {
      t with
      code =
        { t.code with files_catalog = Observed.value ~observed_at (scope, catalog) };
    }

let apply_workspace_search ~observed_at ~scope result t =
  if not (Wire_infra.equal_workspace_scope scope t.code.scope) then t
  else
    {
      t with
      code =
        {
          t.code with
          search_result = Observed.value ~observed_at (scope, result);
          search_selected_index = 0;
          right_mode = Code_search_results;
          git_scroll_offset = 0;
        };
    }

let set_code_active_file active_file_path t =
  {
    t with
    code = { t.code with active_file_path; pending_jump_line = None };
  }

let active_code_file_path t =
  match t.code.active_file_path with
  | Some p when not (String.equal (String.trim p) "") -> Some p
  | Some _ | None -> (
      match selected_code_tree_node t with
      | Some n when not n.has_children -> Some n.path
      | Some _ | None -> (
          match Observed.to_option t.code.open_file with
          | Some (sc, p, _) when Wire_infra.equal_workspace_scope sc t.code.scope
            ->
              Some p
          | Some _ | None -> None))

let path_matches_active_code ~path t =
  match active_code_file_path t with
  | Some exp -> String.equal exp path
  | None -> true

let apply_workspace_file ~observed_at ~scope ~path content t =
  if
    (not (Wire_infra.equal_workspace_scope scope t.code.scope))
    || not (path_matches_active_code ~path t)
  then t
  else
    let file_scroll_offset =
      match t.code.pending_jump_line with
      | Some (target_path, line) when String.equal target_path path ->
          let total_lines =
            List.length (String.split_on_char '\n' content.Wire_infra.content)
          in
          let max_offset = max 0 (total_lines - 1) in
          min max_offset (max 0 (line - 1))
      | Some _ | None -> 0
    in
    {
      t with
      code =
        {
          t.code with
          active_file_path = Some path;
          open_file = Observed.value ~observed_at (scope, path, content);
          file_scroll_offset;
          pending_jump_line = None;
        };
    }

let open_file_for_current t =
  match Observed.to_option t.code.open_file with
  | Some (sc, p, content)
    when Wire_infra.equal_workspace_scope sc t.code.scope
         && path_matches_active_code ~path:p t ->
      Some content
  | Some _ | None -> None

let apply_git_status ~observed_at ~scope snap t =
  if not (Wire_infra.equal_workspace_scope scope t.code.scope) then t
  else
    {
      t with
      code = { t.code with git_status = Observed.value ~observed_at (scope, snap) };
    }

let apply_git_branches ~observed_at ~scope branches t =
  if not (Wire_infra.equal_workspace_scope scope t.code.scope) then t
  else
    {
      t with
      code =
        { t.code with git_branches = Observed.value ~observed_at (scope, branches) };
    }

let apply_git_worktrees ~observed_at ~scope wts t =
  if not (Wire_infra.equal_workspace_scope scope t.code.scope) then t
  else
    {
      t with
      code =
        { t.code with git_worktrees = Observed.value ~observed_at (scope, wts) };
    }

let apply_git_blame ~observed_at ~scope ~path entries t =
  if
    (not (Wire_infra.equal_workspace_scope scope t.code.scope))
    || not (path_matches_active_code ~path t)
  then t
  else
    {
      t with
      code =
        {
          t.code with
          git_blame = Observed.value ~observed_at (scope, path, entries);
        };
    }

let apply_git_log ~observed_at ~scope ~path commits t =
  if
    (not (Wire_infra.equal_workspace_scope scope t.code.scope))
    || not (path_matches_active_code ~path t)
  then t
  else
    {
      t with
      code =
        { t.code with git_log = Observed.value ~observed_at (scope, path, commits) };
    }

let apply_git_diff ~observed_at ~scope ~path diff t =
  if
    (not (Wire_infra.equal_workspace_scope scope t.code.scope))
    || not (path_matches_active_code ~path t)
  then t
  else
    {
      t with
      code =
        { t.code with git_diff = Observed.value ~observed_at (scope, path, diff) };
    }

let find_log_by_seq seq t =
  List.find_opt (fun (e : Wire_infra.system_log_entry) -> Int.equal e.seq seq) t.logs
