module T = Masc_tui_types
module P = Masc_tui_async_protocol
module Owed_read = Masc_tui_owed_read
module Mono = Masc_tui_wake.Mono
module Fetched = Masc_tui_fetched
module Admission = Masc_tui_transport.Workspace_admission
module Owed_read_policy = Masc_tui_owed_surface_reads.Owed_read_policy
module Owed_runtime_tools_reads = Masc_tui_owed_surface_reads.Owed_runtime_tools_reads
module Keeper_story = Masc_tui_keeper_story
module Observer = Masc_tui_observer
module Tui_decode = Masc.Tui_decode

let keeper_schedules_on_screen (state : T.state) =
  match state.T.view with
  | T.Keepers T.Keeper_message -> state.T.msg_target_keeper_name
  | T.Keepers T.Keeper_detail -> (
      match state.T.detail_tab with
      | T.Detail_automation -> Option.map (fun (keeper : T.keeper) -> keeper.Tui_decode.k_name) (T.selected_keeper state)
      | T.Detail_info | T.Detail_items | T.Detail_sandbox | T.Detail_instructions | T.Detail_secrets
      | T.Detail_github | T.Detail_identity | T.Detail_channels | T.Detail_runs | T.Detail_terminal ->
          None)
  | T.Keepers T.Keeper_list -> (
      match state.T.keeper_story with
      | Some _ -> Option.map (fun (keeper : T.keeper) -> keeper.Tui_decode.k_name) (T.selected_keeper state)
      | None -> None)
  | T.Keepers (T.Keeper_logs | T.Keeper_calls | T.Keeper_runtime_pick)
  | T.Overview | T.Approvals | T.Acting | T.Metrics | T.Memory | T.Lanes | T.Clients | T.Board | T.Planning
  | T.Schedules | T.Verification | T.Harness | T.Fusion | T.Repositories | T.Code | T.Changes | T.Connectors
  | T.Runtime | T.Config | T.Resources | T.Tools | T.System_logs ->
      None

(* The Keeper whose newest turns the story page draws: the Keeper under the
   cursor while the Story window is open on that page. *)
let keeper_story_turns_on_screen (state : T.state) =
  match state.T.keeper_story with
  | Some Keeper_story.Story when state.T.view = T.Keepers T.Keeper_list ->
      keeper_schedules_on_screen state
  | Some
      ( Keeper_story.Story
      | Keeper_story.Schedule
      | Keeper_story.Memory
      | Keeper_story.World )
  | None -> None

(* One Keeper's schedules read again under the same rules as the fleet list,
   while the chat pane, the Automation tab or the Story window draws them:
   drawing a Keeper owes the read, and so do a change, a revalidation, a
   resumed authority and a failed read. *)
let owe_keeper_schedules_read (state : T.state) =
  Option.iter
    (fun keeper ->
      let read =
        match state.T.keeper_schedules_owed with
        | Some owed when String.equal owed.T.kso_keeper keeper -> owed.T.kso_read
        | Some _ | None -> Owed_read.settled
      in
      state.T.keeper_schedules_owed <-
        Some { T.kso_keeper = keeper; kso_read = Owed_read.changed read })
    (keeper_schedules_on_screen state)

(* A queue or reaction write owes a schedule list a read only where a drawn
   row reads that Keeper's queue (RFC-0480 §7: filter by the name first). *)
let owe_schedule_reads_for_queue_writes (state : T.state) ~keepers =
  (match state.T.view, state.T.schedules with
   | T.Schedules, Some snapshot when T.schedule_rows_read_queue_of ~keepers snapshot.T.scs_rows ->
       Owed_runtime_tools_reads.owe_schedules_read state
   | T.Schedules, (Some _ | None) | (T.Overview | T.Acting | T.Metrics | T.Memory | T.Lanes | T.Clients | T.Board
     | T.Approvals | T.Planning | T.Verification | T.Harness | T.Fusion | T.Repositories | T.Code | T.Changes | T.Connectors
     | T.Runtime | T.Config | T.Resources | T.Tools | T.System_logs | T.Keepers _), _ ->
       ());
  match keeper_schedules_on_screen state with
  | None -> ()
  | Some keeper ->
      let rows_read_the_queue =
        match state.T.keeper_schedules with
        | Some (listed, snapshot) when String.equal keeper listed ->
            T.schedule_rows_read_queue_of ~keepers snapshot.T.scs_rows
        (* The drawn Keeper's rows are not read yet; its own queue may be
           theirs. *)
        | Some _ | None -> List.mem keeper keepers
      in
      if rows_read_the_queue then owe_keeper_schedules_read state

(* A good answer that the pane did not take, or that is not the page it draws,
   read nothing for it: the record stays in flight, and the loop owes the read
   again as soon as none is on the wire. *)
let settle_keeper_schedules_read (state : T.state) ~keeper ~settles result =
  match state.T.keeper_schedules_owed with
  | Some owed when String.equal owed.T.kso_keeper keeper ->
      let read =
        match result with
        | Ok _ -> if settles then Owed_read.succeeded owed.T.kso_read else owed.T.kso_read
        | Error _ -> Owed_read_policy.failed_read owed.T.kso_read
      in
      state.T.keeper_schedules_owed <- Some { owed with kso_read = read }
  | Some _ | None -> ()

(* A read of this Keeper's schedules is on the wire and still the current
   one for its tab. *)
let keeper_schedules_reading (state : T.state) ~keeper_name =
  match state.T.keeper_schedules_pending with
  | Some (request, _, _) when String.equal request.T.drr_keeper keeper_name -> (
      match T.pending_detail_read state ~tab:T.Detail_automation ~keeper:keeper_name with
      | Some current -> current.T.drr_generation = request.T.drr_generation
      | None -> false)
  | Some _ | None -> false

(* The answer is the current read of its Keeper's schedules, not one a newer
   read replaced. *)
let keeper_schedules_answer_current (state : T.state) (request : T.keeper_schedule_page_request) =
  match T.pending_detail_read state ~tab:T.Detail_automation ~keeper:request.T.kspr_detail.T.drr_keeper with
  | Some current -> current.T.drr_generation = request.T.kspr_detail.T.drr_generation
  | None -> false

(* Runs on every loop iteration. The record follows the Keeper drawn: a
   Keeper no longer drawn drops it, and a Keeper newly drawn owes the read.
   A read already on the wire for it answers that, once its answer is the page
   the pane draws ([keeper_schedules_answer_settles]). *)
let launch_owed_keeper_schedules (state : T.state) ~mailbox =
  match keeper_schedules_on_screen state with
  | None -> state.T.keeper_schedules_owed <- None
  | Some keeper_name ->
      let reading = keeper_schedules_reading state ~keeper_name in
      let owed =
        match state.T.keeper_schedules_owed with
        | Some owed when String.equal owed.T.kso_keeper keeper_name -> owed
        | Some _ | None ->
            let read = Owed_read.changed Owed_read.settled in
            { T.kso_keeper = keeper_name;
              kso_read = (if reading then Owed_read.started read else read) }
      in
      let read =
        if reading then owed.T.kso_read else Owed_read.abandoned owed.T.kso_read
      in
      state.T.keeper_schedules_owed <- Some { owed with kso_read = read };
      (* The Story window follows the cursor, so it has one Keeper's page on
         the wire at a time: the Keeper the cursor has come to waits for the
         read in flight, and every Keeper the cursor passed meanwhile starts
         none. *)
      let window_waits =
        state.T.view = T.Keepers T.Keeper_list
        && List.exists
             (fun (request : T.detail_read_request) ->
                request.T.drr_tab = T.Detail_automation
                && not (String.equal request.T.drr_keeper keeper_name))
             state.T.detail_reads
      in
      if Owed_read.due ~now:(Mono.now ()) read
         && T.server_authority_ready state
         && not reading
         && not window_waits
      then begin
        Masc_tui_work_requests.Schedule_call_requests.launch_keeper_schedules_load state ~mailbox ~keeper_name;
        if keeper_schedules_reading state ~keeper_name then
          state.T.keeper_schedules_owed <-
            Some { owed with kso_read = Owed_read.started read }
      end

(* The story page's turns are read again after a push about the Keeper's
   turns, a revalidation, a resumed authority and a failed read. *)
let owe_keeper_story_turns_read (state : T.state) =
  state.T.keeper_story_turns_owed <- Owed_read.changed state.T.keeper_story_turns_owed

(* A push about turns owes the read only where the page draws that Keeper
   (RFC-0480 §7: filter by the name first). *)
let owe_keeper_story_turns_read_for (state : T.state) ~keepers =
  match keeper_story_turns_on_screen state with
  | Some keeper when List.mem keeper keepers -> owe_keeper_story_turns_read state
  | Some _ | None -> ()

(* Runs on every loop iteration. While the page is not drawn the read stays
   owed, so drawing it again reads it again: turns held from before the window
   closed are not the newest. One read is on the wire at a time: the Keeper the
   cursor has come to waits for the read in flight, and every Keeper the cursor
   passed meanwhile starts none. *)
let launch_owed_keeper_story_turns (state : T.state) ~mailbox =
  match keeper_story_turns_on_screen state with
  | None ->
      state.T.keeper_story_turns_owed <- Owed_read.changed Owed_read.settled
  | Some keeper_name ->
      let reading = Fetched.in_flight state.T.keeper_story_turns in
      let read =
        if reading then state.T.keeper_story_turns_owed
        else Owed_read.abandoned state.T.keeper_story_turns_owed
      in
      state.T.keeper_story_turns_owed <- read;
      let other_keeper_reading =
        reading && Fetched.current_key state.T.keeper_story_turns <> Some keeper_name
      in
      if not other_keeper_reading then
        Masc_tui_surface_requests.Memory_repository_requests.launch_keeper_story_turns_load state ~mailbox ~keeper_name
          ~refresh:(Owed_read.due ~now:(Mono.now ()) read)

(* One visible demand owns each shared source. A hidden preview cannot
   replace the canonical browser's fleet or Keeper target. *)
let launch_owed_memory (state : T.state) ~mailbox =
  let preview =
    if state.T.view = T.Keepers T.Keeper_list && state.T.keeper_story = Some Keeper_story.Memory
    then Option.map (fun (keeper : T.keeper) -> keeper.Tui_decode.k_name) (T.selected_keeper state)
    else None in
  let facts_key = match state.T.view, state.T.memory_page with
    | T.Memory, T.Memory_facts -> state.T.memory_facts_keeper
    | T.Memory, T.Memory_changes -> None
    | (T.Overview | T.Acting | T.Metrics | T.Keepers _ | T.Lanes | T.Clients | T.Board | T.Approvals | T.Planning
      | T.Schedules | T.Verification | T.Harness | T.Fusion | T.Repositories | T.Code | T.Changes | T.Connectors
      | T.Runtime | T.Config | T.Resources | T.Tools | T.System_logs), (T.Memory_facts | T.Memory_changes) -> preview in
  (match facts_key with
   | None -> state.T.memory_facts_owed <- Owed_read.changed Owed_read.settled
   | Some key ->
     let reading = Fetched.in_flight state.T.memory_facts in
     let owed = if reading then state.T.memory_facts_owed else Owed_read.abandoned state.T.memory_facts_owed in
     state.T.memory_facts_owed <- owed;
     if not (reading && Fetched.current_key state.T.memory_facts <> Some key)
        && (Fetched.current_key state.T.memory_facts <> Some key
            || Owed_read.due ~now:(Mono.now ()) owed) then
       if String.equal key "*" then Masc_tui_surface_requests.Memory_repository_requests.launch_all_memory_facts_load state ~mailbox
       else Masc_tui_surface_requests.Memory_repository_requests.launch_memory_facts_load state ~mailbox ~keeper_name:key);
  let activity_key = match state.T.view, state.T.memory_page, state.T.memory_facts_keeper with
    | T.Memory, T.Memory_changes, Some keeper when not (String.equal keeper "*") -> Some keeper
    | T.Memory, (T.Memory_facts | T.Memory_changes), (Some _ | None) -> None
    | (T.Overview | T.Acting | T.Metrics | T.Keepers _ | T.Lanes | T.Clients | T.Board | T.Approvals | T.Planning
      | T.Schedules | T.Verification | T.Harness | T.Fusion | T.Repositories | T.Code | T.Changes | T.Connectors
      | T.Runtime | T.Config | T.Resources | T.Tools | T.System_logs), (T.Memory_facts | T.Memory_changes), (Some _ | None) -> preview in
  match activity_key with
  | None -> state.T.memory_activity_owed <- Owed_read.changed Owed_read.settled
  | Some keeper_name ->
    let reading = Fetched.in_flight state.T.memory_activity in
    let owed = if reading then state.T.memory_activity_owed else Owed_read.abandoned state.T.memory_activity_owed in
    state.T.memory_activity_owed <- owed;
    if not (reading && Fetched.current_key state.T.memory_activity <> Some keeper_name) then
      Masc_tui_surface_requests.Memory_repository_requests.launch_memory_activity_read state ~mailbox ~keeper_name
        ~refresh:(Owed_read.due ~now:(Mono.now ()) owed)
        state.T.memory_activity owed
        ~set_source:(fun source -> state.T.memory_activity <- source)
        ~set_owed:(fun owed -> state.T.memory_activity_owed <- owed)
        ~deliver:(fun request result -> P.Keeper_memory_activity_loaded (request, result))
        (fun () -> Masc_tui_http.fetch_keeper_memory_activity ~host:Admission.server_peer_host ~port:state.T.port ~keeper_name)

(* The Keeper whose chat pane is open; its native tasks and child content are
   drawn beside the transcript. *)
let chat_keeper_on_screen (state : T.state) =
  match state.T.view with
  | T.Keepers T.Keeper_message -> state.T.msg_target_keeper_name
  | T.Keepers (T.Keeper_list | T.Keeper_detail | T.Keeper_logs | T.Keeper_calls | T.Keeper_runtime_pick)
  | T.Overview | T.Approvals | T.Acting | T.Metrics | T.Memory | T.Lanes | T.Clients | T.Board | T.Planning
  | T.Schedules | T.Verification | T.Harness | T.Fusion | T.Repositories | T.Code | T.Changes | T.Connectors
  | T.Runtime | T.Config | T.Resources | T.Tools | T.System_logs ->
      None

(* The chat pane's journals read when the pane opens on a Keeper, when the
   server announces a record in one, on a revalidation or a resumed
   authority, and again after a failed read (RFC-0480 §3.1). *)
let owe_chat_journal owed ~keeper =
  let read =
    match owed with
    | Some { T.cjo_keeper; cjo_read } when String.equal cjo_keeper keeper -> cjo_read
    | Some _ | None -> Owed_read.settled
  in
  Some { T.cjo_keeper = keeper; cjo_read = Owed_read.changed read }

let owe_chat_journal_read (state : T.state) ~keeper = function
  | Observer.Native_tasks_journal ->
      state.T.chat_native_tasks_owed <- owe_chat_journal state.T.chat_native_tasks_owed ~keeper
  | Observer.Child_content_journal ->
      state.T.chat_child_content_owed <- owe_chat_journal state.T.chat_child_content_owed ~keeper

let owe_chat_journal_reads (state : T.state) =
  Option.iter
    (fun keeper ->
      owe_chat_journal_read state ~keeper Observer.Native_tasks_journal;
      owe_chat_journal_read state ~keeper Observer.Child_content_journal)
    (chat_keeper_on_screen state)

let settle_chat_journal owed ~keeper ~succeeded =
  match owed with
  | Some ({ T.cjo_keeper; cjo_read } as owed) when String.equal cjo_keeper keeper ->
      Some
        { owed with
          cjo_read =
            (if succeeded then Owed_read.succeeded cjo_read else Owed_read_policy.failed_read cjo_read) }
  | Some _ | None -> owed

(* One journal's record follows the pane: a Keeper no longer shown drops it,
   and the pane opening on a Keeper owes the read, which a read already on
   the wire for it answers. A read on the wire is let finish first; one that
   will not deliver leaves the read owed. *)
let follow_chat_journal owed ~on_screen ~reading ~launch =
  match on_screen with
  | None -> None
  | Some keeper ->
      let busy = reading keeper in
      let owed =
        match owed with
        | Some ({ T.cjo_keeper; _ } as owed) when String.equal cjo_keeper keeper -> owed
        | Some _ | None ->
            let read = Owed_read.changed Owed_read.settled in
            { T.cjo_keeper = keeper;
              cjo_read = (if busy then Owed_read.started read else read) }
      in
      let read = if busy then owed.T.cjo_read else Owed_read.abandoned owed.T.cjo_read in
      if Owed_read.due ~now:(Mono.now ()) read && (not busy) && launch keeper
      then Some { owed with cjo_read = Owed_read.started read }
      else Some { owed with cjo_read = read }

(* Runs on every loop iteration. *)
let launch_owed_chat_journals (state : T.state) ~mailbox =
  let on_screen = chat_keeper_on_screen state in
  let ready = T.server_authority_ready state in
  let native_reading keeper_name = List.mem_assoc keeper_name state.T.msg_native_tasks_inflight in
  let child_reading keeper_name = List.mem_assoc keeper_name state.T.msg_child_content_inflight in
  state.T.chat_native_tasks_owed <-
    follow_chat_journal state.T.chat_native_tasks_owed ~on_screen ~reading:native_reading
      ~launch:(fun keeper_name ->
        ready
        && (Keeper_chat_reads.launch_keeper_native_tasks_load state ~mailbox ~keeper_name;
            native_reading keeper_name));
  state.T.chat_child_content_owed <-
    follow_chat_journal state.T.chat_child_content_owed ~on_screen ~reading:child_reading
      ~launch:(fun keeper_name ->
        ready
        && (Keeper_chat_reads.launch_keeper_child_content_load state ~mailbox ~keeper_name;
            child_reading keeper_name))
