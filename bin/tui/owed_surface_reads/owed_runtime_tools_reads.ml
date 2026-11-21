module T = Masc_tui_types
module P = Masc_tui_async_protocol
module Owed_read = Masc_tui_owed_read
module Wake = Masc_tui_wake
module Mono = Masc_tui_wake.Mono
module Admission = Masc_tui_transport.Workspace_admission
module Tui_decode = Masc.Tui_decode
module Async_req = Masc.Tui_decode_async_request
module Mem_health = Masc.Tui_decode_memory_health

(* The engine graphs' own [/health] read. It asks which server answers, as
   the refresh's probe does, outside any workspace scope: [/health] reads no
   workspace data, and the answer goes to the graphs only. *)
let launch_engine_sample_read (state : T.state) ~mailbox =
  let host = Admission.server_peer_host and port = state.T.port in
  Masc_tui_async_read.launch
    ~deliver:(fun result ->
      Admission.enqueue mailbox
        (P.Engine_sample_read (Masc_tui_engine_samples.reading_of_server result)))
    (fun () ->
      Masc_tui_workspace_read.without_binding (fun () ->
        Masc_tui_workspace_precondition.without (fun () ->
          Masc_tui_loader.load_server_reading ~host ~port)))


(* Who uses the turns answer: the surfaces that draw a running turn (the
   Keepers list rows, a Keeper's chat, Metrics, the answering overlay), and
   chat input held for a Keeper's control token, which only a turns answer
   brings. *)
let keeper_turns_in_use (state : T.state) =
  state.T.answering_open
  || not (Masc_tui_keeper_chat_queue.is_empty state.T.msg_queued)
  || state.T.keeper_interactive_waiting <> []
  || state.T.keeper_chat_control_pending <> []
  || (match state.T.view with
      | T.Keepers (T.Keeper_list | T.Keeper_message) | T.Metrics -> true
      | T.Keepers (T.Keeper_detail | T.Keeper_logs | T.Keeper_calls | T.Keeper_runtime_pick)
      | T.Overview | T.Approvals | T.Acting | T.Memory | T.Lanes | T.Clients | T.Board | T.Planning
      | T.Schedules | T.Verification | T.Harness | T.Fusion | T.Repositories | T.Code | T.Changes
      | T.Connectors | T.Runtime | T.Config | T.Resources | T.Tools | T.System_logs ->
          false)

(* The waiting list is drawn by the Keepers list only: its rows and the
   Activity pane beside them. *)
let keeper_waiting_in_use (state : T.state) =
  match state.T.view with
  | T.Keepers T.Keeper_list -> true
  | T.Keepers (T.Keeper_message | T.Keeper_detail | T.Keeper_logs | T.Keeper_calls | T.Keeper_runtime_pick)
  | T.Overview | T.Approvals | T.Acting | T.Metrics | T.Memory | T.Lanes | T.Clients | T.Board | T.Planning
  | T.Schedules | T.Verification | T.Harness | T.Fusion | T.Repositories | T.Code | T.Changes | T.Connectors
  | T.Runtime | T.Config | T.Resources | T.Tools | T.System_logs ->
      false


(* Where a Keeper's running-turn preview is drawn: its own chat pane's
   activity line, the Keepers list's last activity, and the answering
   overlay. A preview change is read only while one of them is on screen. *)
let preview_on_screen (state : T.state) ~keeper_name =
  state.T.answering_open
  ||
  match state.T.view with
  | T.Keepers T.Keeper_list -> true
  | T.Keepers T.Keeper_message ->
      Option.equal String.equal state.T.msg_target_keeper_name (Some keeper_name)
  | T.Keepers (T.Keeper_detail | T.Keeper_logs | T.Keeper_calls | T.Keeper_runtime_pick)
  | T.Overview | T.Approvals | T.Acting | T.Metrics | T.Memory | T.Lanes | T.Clients | T.Board | T.Planning
  | T.Schedules | T.Verification | T.Harness | T.Fusion | T.Repositories | T.Code | T.Changes | T.Connectors
  | T.Runtime | T.Config | T.Resources | T.Tools | T.System_logs ->
      false


let tool_modes_on_screen (state : T.state) =
  match state.T.view with
  | T.Keepers _ -> true
  | T.Overview | T.Approvals | T.Acting | T.Metrics | T.Memory | T.Lanes | T.Clients | T.Board | T.Planning
  | T.Schedules | T.Verification | T.Harness | T.Fusion | T.Repositories | T.Code | T.Changes | T.Connectors
  | T.Runtime | T.Config | T.Resources | T.Tools | T.System_logs ->
      false

(* Runs on every loop iteration. A held-call read already in flight is let
   finish first; one that will not deliver leaves the listing owed again. *)

let verification_on_screen (state : T.state) =
  match state.T.view with
  | T.Verification -> true
  | T.Overview | T.Approvals | T.Acting | T.Metrics | T.Memory | T.Lanes | T.Clients | T.Board | T.Planning
  | T.Schedules | T.Harness | T.Fusion | T.Repositories | T.Code | T.Changes | T.Connectors | T.Runtime
  | T.Config | T.Resources | T.Tools | T.System_logs | T.Keepers _ ->
      false


let memory_health_on_screen (state : T.state) =
  match state.T.view with
  | T.Memory | T.Metrics | T.Keepers T.Keeper_list -> true
  | T.Overview | T.Approvals | T.Acting | T.Lanes | T.Clients | T.Board | T.Planning | T.Schedules
  | T.Verification | T.Harness | T.Repositories | T.Fusion | T.Code | T.Changes | T.Connectors | T.Runtime
  | T.Config | T.Resources | T.Tools | T.System_logs
  | T.Keepers
      ( T.Keeper_detail | T.Keeper_logs | T.Keeper_calls | T.Keeper_message
      | T.Keeper_runtime_pick ) ->
      false

(* Runs on every loop iteration. Off screen nothing is owed: arriving reads the
   fleet. One memory health read runs at a time. A fleet read that is owed goes
   first, and a failed read's wait holds the rows too. With nothing owed for the
   fleet, the rows pushes named are read one at a time. While a row of the held
   answer stands refused no row can be merged (the server counted that row and
   this build cannot), so the pushes owe the fleet instead. *)
let launch_owed_memory_health (state : T.state) ~mailbox =
  if not (memory_health_on_screen state) then begin
    state.T.memory_health_owed <- Owed_read.settled;
    state.T.memory_health_rows_owed <- []
  end
  else if not state.T.memory_health_inflight then begin
    let read = Owed_read.abandoned state.T.memory_health_owed in
    state.T.memory_health_owed <- read;
    match read, state.T.memory_health, state.T.memory_health_rows_owed with
    | (Owed_read.Owed _ | Owed_read.Waiting _ | Owed_read.Reading _), _, _ ->
        if Owed_read.due ~now:(Mono.now ()) read then
          Masc_tui_surface_requests.Memory_repository_requests.launch_memory_health_load state ~mailbox
    | Owed_read.Settled, Some held, _ :: _ ->
        (match held.Mem_health.mhs_refused_keepers with
         | [] -> Masc_tui_surface_requests.Memory_repository_requests.launch_owed_memory_health_row state ~mailbox
         | _ :: _ ->
             state.T.memory_health_rows_owed <- [];
             Owed_read_policy.owe_memory_health_read state)
    | Owed_read.Settled, Some _, [] -> ()
    | Owed_read.Settled, None, _ :: _ -> Owed_read_policy.owe_memory_health_read state
    | Owed_read.Settled, None, [] -> ()
  end

(* The world line reads on arrival, revalidation and World_memory changes.
   Success settles its debt; a change during the read owes one follow-up and
   a failure keeps the shared typed retry. Hidden views keep their debt. *)
let launch_owed_memory_world (state : T.state) ~mailbox =
  let visible = (state.T.view = T.Memory && Option.is_none state.T.memory_facts_keeper)
    || (state.T.view = T.Keepers T.Keeper_list
        && Masc_tui_keeper_list_model.has_world state.T.keeper_list_view) in
  if visible && T.server_authority_ready state then
    match Masc_tui_memory_world.start ~now:(Mono.now ()) state.T.memory_world with
    | None -> ()
    | Some (next, request) ->
        state.T.memory_world <- next;
        let host = Admission.server_peer_host and port = state.T.port in
        Admission.launch_json_read state ~mailbox
          ~boundary_error:(fun detail -> T.Request_failed detail)
          ~withdrawn:(fun refusal -> T.Request_withdrawn refusal)
          ~deliver:(fun result -> P.Memory_msg (P.Memory_world_loaded (request, result)))
          (fun () -> Masc_tui_loader.load_memory_world ~host ~port
            |> Result.map_error (fun detail -> T.Request_failed detail))

(* Runs on every loop iteration. The input pane reads when the selection moves
   to another Keeper, when a memory health answer owes it, and again after a
   failed read, which waits like any owed read (RFC-0480 §3.1). Off Memory
   nothing is owed: arriving reads the fleet, whose answer owes the pane. The
   facts browser covers the pane and keeps what it owes, so closing the
   browser reads a change that came meanwhile. *)
let launch_owed_memory_input (state : T.state) ~mailbox =
  if not (state.T.view = T.Memory) then
    state.T.memory_input_owed <- Owed_read.settled
  else begin
    let reading = Masc_tui_fetched.in_flight state.T.memory_input in
    let read =
      if reading then state.T.memory_input_owed
      else Owed_read.abandoned state.T.memory_input_owed
    in
    state.T.memory_input_owed <- read;
    Masc_tui_surface_requests.Memory_repository_requests.launch_memory_input_load state ~mailbox
      ~refresh:((not reading) && Owed_read.due ~now:(Mono.now ()) read)
  end

let harness_on_screen (state : T.state) =
  match state.T.view with
  | T.Harness -> true
  | T.Overview | T.Approvals | T.Acting | T.Metrics | T.Memory | T.Lanes | T.Clients | T.Board | T.Planning
  | T.Schedules | T.Verification | T.Repositories | T.Fusion | T.Code | T.Changes | T.Connectors | T.Runtime
  | T.Config | T.Resources | T.Tools | T.System_logs | T.Keepers _ ->
      false

(* Runs on every loop iteration. Off screen nothing is owed: arriving on the
   surface reads it. A read already in flight is let finish first. *)
(* A Keeper's login attempt read runs on every loop: the wait does not sit
   behind a surface, because the operator who consented may be standing in
   front of any tab. A Keeper nobody waits on owes nothing; a read in flight
   is let finish first. *)
let launch_owed_identity_logins (state : T.state) ~mailbox =
  let now = Unix.gettimeofday () in
  Masc_tui_types.owe_identity_deadline_reads state ~now;
  if T.server_authority_ready state then
    Masc_tui_types.identity_login_pending_keepers state ~now
    |> List.iter (fun keeper_name ->
         let ready = Masc_tui_types.identity_login_read_ready state ~now keeper_name in
         if ready then
           Masc_tui_types.update_identity_login_read state keeper_name
             Owed_read.abandoned;
         let read = Masc_tui_types.identity_login_read state keeper_name in
         if ready && Owed_read.due ~now:(Mono.now ()) read then begin
           Masc_tui_types.update_identity_login_read state keeper_name
             Owed_read.started;
           Masc_tui_identity_requests.launch_view state ~host:Admission.server_peer_host
             ~deliver:(Admission.workspace_enqueue state mailbox) keeper_name
         end)

(* The Clients roster's owed read lives in {!Masc_tui_types}: owe, begin,
   abandon and settle, with the settle decision testable without the event
   loop. *)

(* Runs on every loop iteration. Off the Clients surface nothing is owed:
   arriving reads it. A read in flight is let finish first; one whose
   generation was superseded returns abandoned. *)
let launch_owed_clients (state : T.state) ~mailbox =
  if state.T.view <> T.Clients then state.T.clients_owed <- Owed_read.settled
  else begin
    let reading = state.T.clients_surface_inflight in
    let read =
      if reading then state.T.clients_owed
      else Owed_read.abandoned state.T.clients_owed
    in
    state.T.clients_owed <- read;
    if Owed_read.due ~now:(Mono.now ()) read && not reading then
      Masc_tui_ops_requests.Overview_harness_requests.launch_clients_load state ~mailbox
  end

let launch_owed_harness (state : T.state) ~mailbox =
  if not (harness_on_screen state) then state.T.harness_owed <- Owed_read.settled
  else begin
    (match state.T.harness_stale_at with
     | Some stale_at
       when Wake.reached_wall Wake.Harness_stale
              ~now:(Unix.gettimeofday ()) ~at:stale_at ->
         state.T.harness_stale_at <- None;
         Owed_read_policy.owe_harness_read state
     | Some _ | None -> ());
    let reading = state.T.harness_inflight in
    let read =
      if reading then state.T.harness_owed
      else Owed_read.abandoned state.T.harness_owed
    in
    state.T.harness_owed <- read;
    if Owed_read.due ~now:(Mono.now ()) read && not reading then
      Masc_tui_ops_requests.Overview_harness_requests.launch_harness_load state ~mailbox
  end

(* Runs on every loop iteration. Off screen nothing is owed: arriving on the
   surface reads it. A read already in flight is let finish first. *)
let launch_owed_verification (state : T.state) ~mailbox =
  if not (verification_on_screen state) then
    state.T.verification_owed <- Owed_read.settled
  else begin
    let reading = state.T.verification_inflight in
    let read =
      if reading then state.T.verification_owed
      else Owed_read.abandoned state.T.verification_owed
    in
    state.T.verification_owed <- read;
    if Owed_read.due ~now:(Mono.now ()) read && not reading then
      Masc_tui_ops_requests.Verification_requests.launch_verification_load state ~mailbox
  end

(* Runs on every loop iteration. A turns read already in flight, whoever
   started it, is let finish first; a slot freed without an answer leaves the
   turns owed again. *)
let launch_owed_keeper_turns (state : T.state) ~mailbox =
  if List.exists (fun keeper_name -> preview_on_screen state ~keeper_name)
       state.T.keeper_previews_unread
  then Owed_read_policy.owe_keeper_turns_read state;
  let reading = state.T.keeper_turns_inflight in
  let read =
    if reading then state.T.keeper_turns_owed
    else Owed_read.abandoned state.T.keeper_turns_owed
  in
  state.T.keeper_turns_owed <- read;
  if Owed_read.due ~now:(Mono.now ()) read && not reading
     && keeper_turns_in_use state
  then Masc_tui_chat_dispatch.Chat_watching.launch_keeper_turns_load state ~mailbox

(* Runs on every loop iteration. A waiting read that failed is read again
   after a growing wait; one in flight is let finish first. *)
let launch_owed_keeper_waiting (state : T.state) ~mailbox =
  let reading = T.Keeper_waiting_read.in_flight state.T.keeper_waiting_read in
  let read =
    if reading then state.T.keeper_waiting_owed
    else Owed_read.abandoned state.T.keeper_waiting_owed
  in
  state.T.keeper_waiting_owed <- read;
  if Owed_read.due ~now:(Mono.now ()) read && not reading
     && keeper_waiting_in_use state then
    Masc_tui_chat_dispatch.Chat_watching.launch_keeper_waiting_load state ~mailbox

(* Runs on every loop iteration. The modes are not read while an operator's
   own mode press is in flight: the answer would be the stance from before
   it. An answer the listing refuses leaves the modes owed again. *)
let launch_owed_tool_modes (state : T.state) ~mailbox =
  if not (tool_modes_on_screen state) then
    state.T.tool_modes_owed <- Owed_read.settled
  else if
    Owed_read.due ~now:(Mono.now ()) state.T.tool_modes_owed
    && T.server_authority_ready state
    && not (Masc_tui_operator_projection.Flow.action_inflight state.T.approval_flow)
  then begin
    state.T.tool_modes_owed <- Owed_read.started state.T.tool_modes_owed;
    Masc_tui_work_requests.Approval_gate_requests.launch_keeper_tool_modes_load state ~mailbox
  end

let async_requests_on_screen (state : T.state) =
  match state.T.view with
  | T.Keepers T.Keeper_list | T.Tools -> true
  | T.Keepers (T.Keeper_detail | T.Keeper_logs | T.Keeper_calls | T.Keeper_message | T.Keeper_runtime_pick)
  | T.Overview | T.Approvals | T.Acting | T.Metrics | T.Memory | T.Lanes | T.Clients | T.Board | T.Planning
  | T.Schedules | T.Verification | T.Harness | T.Fusion | T.Repositories | T.Code | T.Changes | T.Connectors
  | T.Runtime | T.Config | T.Resources | T.System_logs ->
      false

(* Runs on every loop iteration. A read already in flight is let finish
   first; one that will not deliver leaves the requests owed again. *)
let launch_owed_async_requests (state : T.state) ~mailbox =
  if not (async_requests_on_screen state) then
    state.T.async_requests_owed <- Owed_read.settled
  else begin
    let reading = state.T.tools_async_observation_inflight in
    let read =
      if reading then state.T.async_requests_owed
      else Owed_read.abandoned state.T.async_requests_owed
    in
    state.T.async_requests_owed <- read;
    if Owed_read.due ~now:(Mono.now ()) read
       && T.server_authority_ready state
       && not reading
    then begin
      state.T.async_requests_owed <- Owed_read.started read;
      Masc_tui_work_requests.Tools_task_requests.launch_tools_async_observation_load state ~mailbox
    end
  end

(* The open async request detail reads again when its Keeper's requests or
   one of its execution journals change, on a revalidation, and after a
   failed read (RFC-0480 §3.4). *)
let owe_tools_async_detail_read (state : T.state) keeper =
  if Option.exists (fun (target : Async_req.target) ->
       String.equal target.Async_req.keeper_name keeper) state.T.tools_async_selection
  then state.T.tools_async_detail_owed <- Owed_read.changed state.T.tools_async_detail_owed

let owe_selected_tools_async_detail_read (state : T.state) =
  Option.iter (fun (target : Async_req.target) ->
      owe_tools_async_detail_read state target.Async_req.keeper_name)
    state.T.tools_async_selection

(* Runs on every loop iteration. Only an open request detail owes a read;
   opening it reads it. A detail left open under another view keeps what it
   owes, so a push that came meanwhile reads it on return. *)
let launch_owed_tools_async_detail (state : T.state) ~mailbox =
  if not (state.T.tools_async_detail_open && Option.is_none state.T.tools_async_task_source) then
    state.T.tools_async_detail_owed <- Owed_read.settled
  else if state.T.view = T.Tools && state.T.tools_pane = T.Tools_async then begin
    let reading = Option.is_some state.T.tools_async_detail_request in
    let read =
      if reading then state.T.tools_async_detail_owed
      else Owed_read.abandoned state.T.tools_async_detail_owed
    in
    state.T.tools_async_detail_owed <- read;
    if Owed_read.due ~now:(Mono.now ()) read && not reading then
      Masc_tui_work_requests.Tools_task_requests.launch_tools_async_detail state ~mailbox
  end

(* The open source Task's body reads again when the backlog changes, on a
   revalidation, and after a failed read (RFC-0480 §3.4). Its history reads
   its first page on opening and more on request; [r] reads it again. *)
let owe_tools_async_task_read (state : T.state) =
  state.T.tools_async_task_owed <- Owed_read.changed state.T.tools_async_task_owed

(* Runs on every loop iteration. Only an open source Task owes a read. A
   Task left open under another view keeps what it owes. *)
let launch_owed_tools_async_task ~terminal_size state ~mailbox =
  if not (state.T.tools_async_detail_open && Option.is_some state.T.tools_async_task_source) then
    state.T.tools_async_task_owed <- Owed_read.settled
  else if state.T.view = T.Tools && state.T.tools_pane = T.Tools_async then begin
    let reading = Option.is_some state.T.tools_async_task_body_request in
    let read =
      if reading then state.T.tools_async_task_owed
      else Owed_read.abandoned state.T.tools_async_task_owed
    in
    state.T.tools_async_task_owed <- read;
    if Owed_read.due ~now:(Mono.now ()) read && not reading then
      Masc_tui_work_requests.Tools_task_requests.launch_tools_async_task ~terminal_size state ~mailbox
  end

(* Runs on every loop iteration. The selected Keeper's inventory reads while
   any pane but Async is on screen, the skills catalog and each roster
   Keeper's Usage answer while the Usage pane is, the selected Keeper's
   activations while the Activations pane is, each when a push, an arrival
   or a failed read owes it. A part in flight is let finish first; one that
   will not deliver is owed again. What is owed off screen waits for its
   pane. *)
let launch_owed_tools (state : T.state) ~mailbox =
  let async_open =
    Option.is_some state.T.tools_async_task_source
    || (state.T.tools_pane = T.Tools_async && state.T.tools_async_detail_open)
  in
  if state.T.view = T.Tools && not async_open then begin
    let selected = Option.map (fun (row : T.keeper) -> row.Tui_decode.k_name) (T.selected_keeper state) in
    (* A part in flight for a Keeper no longer selected is not this
       Keeper's read. *)
    let pending part =
      match part with
      | T.Tools_catalog_read -> List.mem part state.T.tools_skill_pending
      | T.Tools_inventory_read | T.Tools_async_read ->
          (match state.T.tools_read_inflight with
           | Some request when Option.equal String.equal request.T.tri_keeper selected ->
               List.mem part request.T.tri_pending
           | Some _ | None -> false)
    in
    let now = Mono.now () in
    let due part owed set =
      let reading = pending part in
      let read = if reading then owed else Owed_read.abandoned owed in
      if read != owed then set read;
      Owed_read.due ~now read && not reading
    in
    (* Every pane but Async draws the selected Keeper's Skill heading from
       the inventory's skill profiles, and its Skill keys act on them. The
       inventory follows the selected Keeper however the selection moved,
       like the activations. A wait after another Keeper's failed read is
       not this Keeper's: the read is owed now, with no failures behind it. *)
    let inventory_parts () =
      (match state.T.tools_inventory_owed with
       | Owed_read.(Settled | Waiting _)
         when not (Option.equal String.equal state.T.tools_inventory_keeper selected) ->
           state.T.tools_inventory_owed <-
             Owed_read.changed Owed_read.settled
       | Owed_read.(Settled | Owed _ | Reading _ | Waiting _) -> ());
      if due T.Tools_inventory_read state.T.tools_inventory_owed
           (fun owed -> state.T.tools_inventory_owed <- owed)
      then [ T.Tools_inventory_read ]
      else []
    in
    let parts =
      match state.T.tools_pane with
      | T.Tools_usage ->
          inventory_parts ()
          @ (if due T.Tools_catalog_read state.T.tools_catalog_owed
                  (fun owed -> state.T.tools_catalog_owed <- owed)
             then [ T.Tools_catalog_read ]
             else [])
      | T.Tools_surface | T.Tools_storage
      | T.Tools_catalog (T.Tools_catalog_list | T.Tools_catalog_volumes _) -> inventory_parts ()
      | T.Tools_async -> []
    in
    match parts with
    | [] -> ()
    | _ :: _ -> Masc_tui_work_requests.Tools_task_requests.launch_tools_parts state ~mailbox parts
  end

(* The schedule list behind the agenda strip, drawn on every surface, and the
   Schedules page read again when the server says the schedules changed, on a
   revalidation or a resumed authority, and after a failed read
   (RFC-0480 §3.1). Entering Schedules and [r] read them directly. Each owes
   its own read: the two can be in flight at once, and one answering says
   nothing of the other. *)
let owe_schedules_read (state : T.state) =
  state.T.schedules_agenda_owed <- Owed_read.changed state.T.schedules_agenda_owed;
  state.T.schedules_page_owed <- Owed_read.changed state.T.schedules_page_owed

(* The agenda strip says its list may be behind until a read that began after
   this point answers: on a schedule change, on an observer reopen that did
   not resume cleanly, and after lost events. A read in flight is overtaken;
   its successor is the owed read, which bursts share. *)
let owe_agenda_revalidation (state : T.state) =
  state.T.schedules_agenda_freshness <- Masc_tui_agenda.Refresh_needed;
  owe_schedules_read state

let settled_schedule_read read = function
  | Ok _ -> Owed_read.succeeded read
  | Error _ -> Owed_read_policy.failed_read read

(* Runs on every loop iteration. A read already in flight is let finish
   first; one that will not deliver leaves its surface owed again. Off
   Schedules the page owes nothing: entering it reads the page. On the first
   page the page read carries the agenda, so it also waits for an agenda read
   in flight rather than overtake it. *)
let launch_owed_schedules (state : T.state) ~mailbox =
  let page_on_screen = state.T.view = T.Schedules in
  let page_reading = T.Snapshot_read.in_flight state.T.schedules_read in
  let page_carries_agenda = Option.is_none state.T.schedules_page.T.sp_cursor in
  state.T.schedules_agenda_owed <-
    (if T.Snapshot_read.in_flight state.T.schedules_agenda_read then state.T.schedules_agenda_owed
     else Owed_read.abandoned state.T.schedules_agenda_owed);
  state.T.schedules_page_owed <-
    (if not page_on_screen then Owed_read.settled
     else if page_reading then state.T.schedules_page_owed
     else Owed_read.abandoned state.T.schedules_page_owed);
  if T.server_authority_ready state then begin
    let now = Mono.now () in
    let intent = T.Snapshot_read.Refresh in
    if page_on_screen && not page_reading
       && not (page_carries_agenda && T.Snapshot_read.in_flight state.T.schedules_agenda_read)
       && Owed_read.due ~now state.T.schedules_page_owed
    then Masc_tui_work_requests.Schedule_call_requests.launch_schedules_load ~intent state ~mailbox;
    if not (T.Snapshot_read.in_flight state.T.schedules_agenda_read)
       && Owed_read.due ~now state.T.schedules_agenda_owed
    then Masc_tui_work_requests.Schedule_call_requests.launch_schedule_agenda_load ~intent state ~mailbox
  end
