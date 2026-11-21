module T = Masc_tui_types
module P = Masc_tui_async_protocol
module Owed_read = Masc_tui_owed_read
module Mono = Masc_tui_wake.Mono
module Admission = Masc_tui_transport.Workspace_admission
module Event_streams = Masc_tui_transport.Event_streams

let board_post_on_screen (state : T.state) =
  if state.T.view = T.Board then
    match state.T.board_mode with
    | T.Board_read post_id -> Some post_id
    | T.Board_compose -> state.T.board_compose_reply_to
    | T.Board_list -> None
  else None

let settle_board_post_owed (state : T.state) ~post_id transition =
  match state.T.board_post_owed with
  | Some owed when String.equal owed.T.bpo_post post_id ->
      state.T.board_post_owed <- Some { owed with bpo_read = transition owed.T.bpo_read }
  | Some _ | None -> ()

(* Runs on every loop iteration. A read already in flight for the post is let
   finish first. A post no longer open drops its record: opening it again
   reads it. *)
let launch_owed_board_post (state : T.state) ~mailbox =
  match state.T.board_post_owed with
  | None -> ()
  | Some owed
    when not (Option.equal String.equal (board_post_on_screen state) (Some owed.T.bpo_post)) ->
      state.T.board_post_owed <- None
  | Some owed ->
      let post_id = owed.T.bpo_post in
      let reading = Masc_tui_board_detail.reading state.T.board_detail ~post_id in
      (* A read the detail retired (a mode swap, leaving and reopening) never
         completes, so its record is owed again. *)
      let read =
        if reading then owed.T.bpo_read else Owed_read.abandoned owed.T.bpo_read
      in
      state.T.board_post_owed <- Some { owed with bpo_read = read };
      if Owed_read.due ~now:(Mono.now ()) read
         && T.server_authority_ready state
         && not reading
      then begin
        state.T.board_post_owed <-
          Some { owed with bpo_read = Owed_read.started read };
        Masc_tui_board_requests.start_board_post_refresh state ~host:Admission.server_peer_host
          ~port:state.T.port ~post_id
          ~launch:(Admission.launch_guarded_request state ~mailbox
            ~boundary_error:(fun detail -> T.Request_failed detail)
            ~withdrawn:(fun refusal -> T.Request_withdrawn refusal))
      end

let owe_board_post_read (state : T.state) ~mailbox ~post_id =
  let owed =
    match state.T.board_post_owed with
    | Some owed when String.equal owed.T.bpo_post post_id -> owed
    | Some _ | None -> { T.bpo_post = post_id; bpo_read = Owed_read.settled }
  in
  state.T.board_post_owed <-
    Some { owed with bpo_read = Owed_read.changed owed.T.bpo_read };
  launch_owed_board_post state ~mailbox

(* The Board list and hearth census read again when [notifications/board]
   arrives while the Board is on screen, and after a failed read
   (RFC-0480 §3.1). The read on entering the Board and a revalidation ride the
   surface refresh. *)
let owe_board_list_read (state : T.state) =
  state.T.board_list_owed <- Owed_read.changed state.T.board_list_owed

(* A surface dataset read can end without its answer being applied: a newer
   refresh ticket supersedes it, the workspace is not this checkout's, or the
   bundle carries no answer. Such a read waits like a failed one, so a cause
   that repeats does not read back to back. *)
let unanswered_read owed =
  Owed_read.failed ~retry_s:Event_streams.stream_reconnect_s
    ~max_retry_s:Owed_read_policy.keeper_execute_stream_max_reconnect_s ~now:(Mono.now ()) owed

(* The Planning screen's Goals and their tree read again when
   [goal_projection_changed] or [Backlog] arrives while Planning is
   on screen, and after a failed read (RFC-0480 §3.1). The read on entering
   Planning and a revalidation ride the surface refresh. *)
let owe_planning_reads (state : T.state) =
  state.T.planning_owed <- Owed_read.changed state.T.planning_owed;
  state.T.overview_goals_owed <- Owed_read.changed state.T.overview_goals_owed

(* Every read that asks for the Board list or a Planning dataset starts its
   debt, whatever started it: a read on entering the surface or a
   revalidation that is superseded before it answers leaves the dataset owed,
   and [launch_owed_board_list] or [launch_owed_planning] reads it again. *)
let note_owed_surface_reads_started (state : T.state) (needs : Masc_tui_types.surface_needs) =
  if needs.T.needs_board then
    state.T.board_list_owed <- Owed_read.started state.T.board_list_owed;
  if needs.T.needs_planning then
    state.T.planning_owed <- Owed_read.started state.T.planning_owed;
  if needs.T.needs_overview_goals then
    state.T.overview_goals_owed <- Owed_read.started state.T.overview_goals_owed

(* Any surface bundle that reads a pushed source, full or scoped, is the read
   its owed change waits on. *)
let note_pushed_reads_started (state : T.state) (needs : Masc_tui_types.surface_needs) =
  let wanted = T.Surface_read_order.sources needs in
  List.iter
    (fun source ->
      if List.mem source wanted then
        Owed_read_policy.set_pushed_read state source (Owed_read.started (Owed_read_policy.pushed_read state source)))
    Masc_tui_types.pushed_sources

(* The questions a Keeper or an installation puts to the operator read again
   when their log changes, on a resumed authority, and after a failed read
   (RFC-0480 §3.1). Every full refresh reads them too. *)
let owe_asks_read (state : T.state) = state.T.asks_owed <- Owed_read.changed state.T.asks_owed

(* The confirmations waiting for an operator read again under the same rules:
   a change or a passed deadline, a resumed authority, a failed read. *)
let owe_pending_confirms_read (state : T.state) =
  state.T.pending_confirms_owed <- Owed_read.changed state.T.pending_confirms_owed

let launch_asks_read (state : T.state) ~mailbox =
  match state.T.server_identity with
  | None -> false
  | Some expected_workspace ->
    (match Masc_tui_types.begin_asks_read state with
     | None -> false
     | Some asks_request ->
       let enqueue_async = Admission.workspace_enqueue state in
       let host = Admission.server_peer_host and port = state.T.port in
       (* The guard's refusal stays [Request_withdrawn]: that read was not sent
          and is no failed read (RFC §2). *)
       Admission.launch_async_read_with state ~mailbox
         ~boundary_error:(fun detail -> T.Request_failed detail)
         ~withdrawn:(fun refusal -> T.Request_withdrawn refusal)
         ~deliver:(fun asks_result ->
           enqueue_async mailbox (P.Ask_msg (P.Asks_reloaded { asks_request; asks_result })))
         (fun () ->
           Masc_tui_http.fetch_asks ~expected_workspace ~host ~port ()
           |> Result.map_error (fun detail -> T.Request_failed detail));
       true)

(* Runs on every loop iteration. A read already in flight, the refresh's or
   this one's, is let finish first; one that will not deliver leaves the
   questions owed again. While an answer is being sent no read starts: the
   answer reads the questions again itself. *)
let launch_owed_asks (state : T.state) ~mailbox =
  let reading = T.Snapshot_read.in_flight state.T.asks_read in
  let read =
    if reading then state.T.asks_owed else Owed_read.abandoned state.T.asks_owed
  in
  state.T.asks_owed <- read;
  if Owed_read.due ~now:(Mono.now ()) read
     && T.server_authority_ready state
     && not reading
     && launch_asks_read state ~mailbox
  then state.T.asks_owed <- Owed_read.started read

(* The Gate snapshot reads again when the queue, the standing rules or a Gate
   mode change, on a revalidation or a resumed authority, and after a failed
   read (RFC-0480 §3.1). Entering a surface and [r] read it directly. *)
let owe_gate_snapshot_read (state : T.state) =
  state.T.gate_snapshot_owed <- Owed_read.changed state.T.gate_snapshot_owed

let fail_gate_snapshot_read (state : T.state) =
  state.T.gate_snapshot_owed <- Owed_read_policy.failed_read state.T.gate_snapshot_owed

(* Runs on every loop iteration. A Gate read already in flight is let
   finish first; one that will not deliver leaves the snapshot owed again. *)
let launch_owed_gate_snapshot (state : T.state) ~mailbox =
  let reading = T.Snapshot_read.in_flight state.T.gate_snapshot_read in
  let read =
    if reading then state.T.gate_snapshot_owed
    else Owed_read.abandoned state.T.gate_snapshot_owed
  in
  state.T.gate_snapshot_owed <- read;
  if Owed_read.due ~now:(Mono.now ()) read
     && T.server_authority_ready state
     && not reading
  then Masc_tui_work_requests.Approval_gate_requests.launch_gate_snapshot_load state ~mailbox

let held_calls_on_screen (state : T.state) =
  match state.T.view with
  | T.Overview | T.Approvals -> true
  | T.Acting | T.Metrics | T.Memory | T.Lanes | T.Clients | T.Board | T.Planning | T.Schedules | T.Verification
  | T.Harness | T.Fusion | T.Repositories | T.Code | T.Changes | T.Connectors | T.Runtime | T.Config
  | T.Resources | T.Tools | T.System_logs | T.Keepers _ ->
      false

let launch_owed_held_calls (state : T.state) ~mailbox =
  if not (held_calls_on_screen state) then
    state.T.held_calls_owed <- Owed_read.settled
  else begin
    let reading = T.Snapshot_read.in_flight state.T.keeper_tool_approvals_read in
    let read =
      if reading then state.T.held_calls_owed
      else Owed_read.abandoned state.T.held_calls_owed
    in
    state.T.held_calls_owed <- read;
    if Owed_read.due ~now:(Mono.now ()) read
       && T.server_authority_ready state
       && not reading
    then Masc_tui_work_requests.Approval_gate_requests.launch_keeper_tool_approvals_load state ~mailbox
  end

let repositories_on_screen (state : T.state) =
  match state.T.view with
  | T.Repositories -> true
  | T.Overview | T.Approvals | T.Acting | T.Metrics | T.Memory | T.Lanes | T.Clients | T.Board | T.Planning
  | T.Schedules | T.Verification | T.Harness | T.Fusion | T.Code | T.Changes | T.Connectors | T.Runtime
  | T.Config | T.Resources | T.Tools | T.System_logs | T.Keepers _ ->
      false

(* The Connectors list, outside the Browser Lane, and a Keeper's channels tab
   draw the connectors. *)
let connectors_on_screen (state : T.state) =
  match state.T.view with
  | T.Connectors -> Option.is_none (T.browser_lane_on_screen state)
  | T.Keepers T.Keeper_detail -> state.T.detail_tab = T.Detail_channels
  | T.Keepers (T.Keeper_list | T.Keeper_logs | T.Keeper_calls | T.Keeper_message | T.Keeper_runtime_pick)
  | T.Overview | T.Approvals | T.Acting | T.Metrics | T.Memory | T.Lanes | T.Clients | T.Board | T.Planning
  | T.Schedules | T.Verification | T.Harness | T.Fusion | T.Code | T.Changes | T.Repositories | T.Runtime
  | T.Config | T.Resources | T.Tools | T.System_logs ->
      false

(* Runs on every loop iteration. Off screen nothing is owed: arriving on the
   surface reads it. A read already in flight is let finish first. *)
let launch_owed_connectors (state : T.state) ~mailbox =
  if not (connectors_on_screen state) then
    state.T.connectors_owed <- Owed_read.settled
  else begin
    let reading =
      T.Connector_read.reading_for ~authority:state.T.detail_read_authority state.T.connectors_read
    in
    let read =
      if reading then state.T.connectors_owed
      else Owed_read.abandoned state.T.connectors_owed
    in
    state.T.connectors_owed <- read;
    if Owed_read.due ~now:(Mono.now ()) read && not reading then
      Masc_tui_surface_requests.Connector_volume_requests.launch_connectors_load state ~mailbox
  end

(* Runs on every loop iteration. Off the panes that draw runtime.toml a change
   stays owed, so a pane reached without [launch_surface_reads] still reads
   it: the Config strip moves between panes inside one view, and Lanes [e]
   opens Config_runtime itself. A read already in flight is let finish
   first. *)
let launch_owed_overview (state : T.state) ~mailbox =
  let read =
    if state.T.overview_inflight then state.T.overview_owed
    else Owed_read.abandoned state.T.overview_owed
  in
  state.T.overview_owed <- read;
  if Owed_read.due ~now:(Mono.now ()) read && not state.T.overview_inflight then
    Masc_tui_ops_requests.Overview_harness_requests.launch_overview_load state ~mailbox

let launch_owed_runtime_surface (state : T.state) ~mailbox =
  if state.T.view <> T.Runtime then state.T.runtime_surface_owed <- Owed_read.settled
  else begin
    let reading = Option.is_some state.T.runtime_surface_inflight in
    let read =
      if reading then state.T.runtime_surface_owed
      else Owed_read.abandoned state.T.runtime_surface_owed
    in
    state.T.runtime_surface_owed <- read;
    if Owed_read.due ~now:(Mono.now ()) read && not reading then
      Masc_tui_surface_requests.Memory_repository_requests.launch_runtime_surface_load state ~mailbox ~force:false
  end

let launch_owed_runtime_config (state : T.state) ~mailbox =
  let reading =
    match state.T.runtime_config_read with
    | `Loading _ -> true
    | `Idle -> false
  in
  let read =
    if reading then state.T.runtime_config_owed
    else Owed_read.abandoned state.T.runtime_config_owed
  in
  state.T.runtime_config_owed <- read;
  if Owed_read_policy.runtime_config_on_screen state
     && Owed_read.due ~now:(Mono.now ()) read
     && not reading
  then Masc_tui_surface_requests.Runtime_config_requests.launch_runtime_config_load state ~mailbox

(* Runs on every loop iteration. Off screen nothing is owed: arriving on the
   surface reads it. A read already in flight is let finish first. *)
let launch_owed_repositories (state : T.state) ~mailbox =
  if not (repositories_on_screen state) then
    state.T.repositories_owed <- Owed_read.settled
  else begin
    let reading = state.T.repositories_inflight in
    let read =
      if reading then state.T.repositories_owed
      else Owed_read.abandoned state.T.repositories_owed
    in
    state.T.repositories_owed <- read;
    if Owed_read.due ~now:(Mono.now ()) read && not reading then
      Masc_tui_surface_requests.Memory_repository_requests.launch_repositories_load state ~mailbox
  end
