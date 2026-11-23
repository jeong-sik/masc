open Masc_tui_core
open Masc_tui_keymap
open Masc_tui_protocol
open Masc_tui_ui

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

type t = {
  active_tab : Nav.infra_tab;
  sandboxes : Wire_infra.sandboxes_snapshot Observed.t;
  sandboxes_fallback_404 : bool;
  keeper_sandbox : Wire_infra.keeper_sandbox_response Observed.t;
  repositories : Wire_infra.repository list Observed.t;
  file_changes : Wire_infra.file_change list Observed.t;
  file_changes_keeper : string option;
  requested_file_changes_keeper : string option;
  logs : Wire_infra.system_log_entry list;
  logs_loaded : bool;
  last_log_seq : int option;
  stream_gap_count : int;
  log_level_filter : Wire_infra.log_level option;
  log_keeper_filter : string option;
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
    keeper_sandbox = Observed.absent;
    repositories = Observed.unreported;
    file_changes = Observed.unreported;
    file_changes_keeper = None;
    requested_file_changes_keeper = None;
    logs = [];
    logs_loaded = false;
    last_log_seq = None;
    stream_gap_count = 0;
    log_level_filter = None;
    log_keeper_filter = None;
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

let apply_keeper_sandbox ~observed_at keeper_sandbox t =
  { t with keeper_sandbox = Observed.value ~observed_at keeper_sandbox }

let apply_repositories ~observed_at repositories t =
  { t with repositories = Observed.value ~observed_at repositories }

let apply_file_changes ?keeper ~observed_at file_changes t =
  let file_changes_keeper =
    match keeper with
    | Some k -> Some k
    | None -> (
        match file_changes with
        | (fc : Wire_infra.file_change) :: _ -> fc.keeper
        | [] -> t.file_changes_keeper)
  in
  {
    t with
    file_changes = Observed.value ~observed_at file_changes;
    file_changes_keeper;
    requested_file_changes_keeper = None;
    change_selected_index = 0;
    change_scroll_offset = 0;
    diff_scroll_offset = 0;
  }

let clear_file_changes t =
  {
    t with
    file_changes = Observed.unreported;
    file_changes_keeper = None;
    requested_file_changes_keeper = None;
    change_selected_index = 0;
    change_scroll_offset = 0;
    diff_scroll_offset = 0;
  }

let mark_file_changes_requested ~keeper t =
  { t with requested_file_changes_keeper = Some keeper }

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

let set_log_level_filter log_level_filter t =
  { t with log_level_filter; selected_index = 0; scroll_offset = 0 }

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

let filtered_file_changes t =
  let all =
    match Observed.to_option t.file_changes with Some xs -> xs | None -> []
  in
  let q = String.trim t.filter_query in
  if String.equal q "" then all
  else
    List.filter
      (fun (fc : Wire_infra.file_change) ->
        contains_ci ~needle:q fc.path
        ||
        match fc.keeper with
        | Some kp -> contains_ci ~needle:q kp
        | None -> false)
      all

let selected_sandbox_keeper t =
  let names = filtered_sandbox_keepers t in
  List.nth_opt names (clamp_index (List.length names) t.selected_index)

let selected_repository t =
  let repos = filtered_repositories t in
  List.nth_opt repos (clamp_index (List.length repos) t.selected_index)

let repo_scoped_file_changes t =
  let all_changes = filtered_file_changes t in
  match selected_repository t with
  | Some r -> (
      if r.keepers = [] then []
      else
        match t.file_changes_keeper with
        | Some k when List.exists (String.equal k) r.keepers -> all_changes
        | Some _ | None -> [])
  | None -> all_changes

let selected_file_change t =
  let changes = filtered_file_changes t in
  List.nth_opt changes (clamp_index (List.length changes) t.change_selected_index)

let selected_repo_file_change t =
  let changes = repo_scoped_file_changes t in
  List.nth_opt changes
    (clamp_index (List.length changes) t.change_selected_index)

let selected_log t =
  let vis = visible_logs t in
  List.nth_opt vis (clamp_index (List.length vis) t.selected_index)

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
                match selected_repo_file_change t with
                | Some fc -> (
                    match fc.diff_preview with
                    | Some dp when not (String.equal dp "") ->
                        let vis =
                          max 1
                            (Option.value viewport_rows
                               ~default:Store_scroll.default_viewport_rows)
                        in
                        max 0 (List.length (Diff.parse_unified dp) - vis)
                    | Some _ | None -> 0)
                | None -> 0)
          in
          let diff_scroll_offset =
            Store_scroll.clamp_scroll ~max_scroll (t.diff_scroll_offset + delta)
          in
          { t with diff_scroll_offset }
      | 2 ->
          let len = List.length (repo_scoped_file_changes t) in
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
              match selected_log t with
              | Some e ->
                  let vis = max 1 (Option.value viewport_rows ~default:8) in
                  let total =
                    List.length
                      (Json_tree.flatten ~max_depth:4 ~redact_secrets:true
                         e.details)
                  in
                  max 0 (total - vis)
              | None -> 0)
        in
        let detail_scroll_offset =
          Store_scroll.clamp_scroll ~max_scroll
            (t.detail_scroll_offset + delta)
        in
        { t with detail_scroll_offset }
      else
        let len = List.length (visible_logs t) in
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
    keeper_sandbox = Observed.mark_stale t.keeper_sandbox;
    repositories = Observed.mark_stale t.repositories;
    file_changes = Observed.mark_stale t.file_changes;
  }
