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

type t = {
  active_tab : Nav.infra_tab;
  sandboxes : Wire_infra.sandboxes_snapshot Observed.t;
  sandboxes_fallback_404 : bool;
  keeper_sandboxes : Wire_infra.keeper_sandbox_response Observed.t String_map.t;
  repositories : Wire_infra.repository list Observed.t;
  repo_activity : repo_activity option;
  logs : Wire_infra.system_log_entry list;
  logs_loaded : bool;
  last_log_seq : int option;
  stream_gap_count : int;
  log_level_filter : Wire_infra.log_level option;
  log_keeper_filter : string option;
  source_filter : activity_source_filter;
  activity_events : activity_row list;
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
    last_log_seq = None;
    stream_gap_count = 0;
    log_level_filter = None;
    log_keeper_filter = None;
    source_filter = Source_all;
    activity_events = [];
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

let forget_log_cursor t = { t with last_log_seq = None }

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
  { t with logs; logs_loaded = true; last_log_seq }

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
  {
    t with
    activity_events = List.take max_activity (row :: t.activity_events);
  }

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
    | None -> Some Wire_infra.Log_info
    | Some Wire_infra.Log_debug -> Some Wire_infra.Log_info
    | Some Wire_infra.Log_info -> Some Wire_infra.Log_warn
    | Some Wire_infra.Log_warn -> Some Wire_infra.Log_error
    | Some Wire_infra.Log_error -> None
  in
  set_log_level_filter next t

let set_log_keeper_filter log_keeper_filter t =
  { t with log_keeper_filter; selected_index = 0; scroll_offset = 0 }

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

let filtered_repositories t =
  let all =
    match Observed.to_option t.repositories with Some rs -> rs | None -> []
  in
  let q = String.trim t.filter_query in
  if String.equal q "" then all
  else
    List.filter
      (fun (r : Wire_infra.repository) ->
        contains_ci ~needle:q r.name
        || contains_ci ~needle:q r.url
        || contains_ci ~needle:q r.default_branch
        || List.exists (fun kp -> contains_ci ~needle:q kp) r.keepers)
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
  match
    Option.bind (selected_repo_activity t) (fun (_, activity) ->
        Observed.to_option activity)
  with
  | None -> []
  | Some (activity : Wire_infra.repository_activity) ->
      let q = String.trim t.filter_query in
      if String.equal q "" then activity.changes
      else
        List.filter
          (fun (fc : Wire_infra.file_change) ->
            contains_ci ~needle:q fc.path || contains_ci ~needle:q fc.keeper)
          activity.changes

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
      match pane_index with
      | 1 ->
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
      | 2 ->
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
      | _ ->
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
  }
