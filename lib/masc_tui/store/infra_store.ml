open Masc_tui_core
open Masc_tui_keymap
open Masc_tui_protocol

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
    filter_query = "";
  }

let contains_ci ~needle haystack =
  let n_len = String.length needle in
  if n_len = 0 then true
  else
    let h_len = String.length haystack in
    if n_len > h_len then false
    else
      let n_low = String.lowercase_ascii needle in
      let h_low = String.lowercase_ascii haystack in
      let limit = h_len - n_len in
      let rec scan i =
        if i > limit then false
        else if String.equal (String.sub h_low i n_len) n_low then true
        else scan (i + 1)
      in
      scan 0

let clamp_index len idx =
  if len <= 0 then 0
  else if idx < 0 then 0
  else if idx >= len then len - 1
  else idx

let set_tab active_tab t =
  { t with active_tab; selected_index = 0; scroll_offset = 0 }

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

let apply_file_changes ~observed_at file_changes t =
  { t with file_changes = Observed.value ~observed_at file_changes }

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

let sandbox_keeper_names t =
  match Observed.to_option t.sandboxes with
  | None -> []
  | Some s ->
      let microvms =
        List.map (fun (g : Wire_infra.microvm_guest) -> g.keeper) s.microvm_guests
      in
      let ssh_bound =
        List.concat_map
          (fun (p : Wire_infra.ssh_pool) ->
            List.map
              (fun (ks : Wire_infra.ssh_keeper_session) -> ks.keeper)
              p.keeper_sessions)
          s.ssh_pools
      in
      let ssh_unbound =
        List.map
          (fun (u : Wire_infra.ssh_unbound_keeper) -> u.keeper)
          s.ssh_unbound_keepers
      in
      let docker =
        List.map (fun (d : Wire_infra.docker_keeper) -> d.keeper) s.docker_keepers
      in
      microvms @ ssh_bound @ ssh_unbound @ docker

let selected_sandbox_keeper t =
  let names = sandbox_keeper_names t in
  List.nth_opt names (clamp_index (List.length names) t.selected_index)

let selected_repository t =
  match Observed.to_option t.repositories with
  | None -> None
  | Some repos ->
      List.nth_opt repos (clamp_index (List.length repos) t.selected_index)

let selected_log t =
  let vis = visible_logs t in
  List.nth_opt vis (clamp_index (List.length vis) t.selected_index)

let active_list_len t =
  match t.active_tab with
  | Nav.Infra_sandboxes -> List.length (sandbox_keeper_names t)
  | Nav.Infra_repos_changes -> (
      match Observed.to_option t.repositories with
      | Some rs -> List.length rs
      | None -> 0)
  | Nav.Infra_activity_logs -> List.length (visible_logs t)

let move_selection ~delta t =
  let len = active_list_len t in
  let selected_index = clamp_index len (t.selected_index + delta) in
  let scroll_offset =
    if selected_index < t.scroll_offset then selected_index
    else t.scroll_offset
  in
  { t with selected_index; scroll_offset }

let set_filter filter_query t =
  { t with filter_query; selected_index = 0; scroll_offset = 0 }

let mark_stale_all t =
  {
    t with
    sandboxes = Observed.mark_stale t.sandboxes;
    keeper_sandbox = Observed.mark_stale t.keeper_sandbox;
    repositories = Observed.mark_stale t.repositories;
    file_changes = Observed.mark_stale t.file_changes;
  }
