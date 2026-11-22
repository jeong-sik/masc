module Turn_log = Keeper_turn_log
module Writer = Keeper_turn_log_writer
module Recorder = Keeper_turn_log_recorder

type closing_save =
  | Saved
  | Stale
  | Failed

type t =
  { place : Recorder.place
  ; turn_ref : Ids.Turn_ref.t
  ; admitted : Writer.admitted
  ; closing_save : closing_save option Atomic.t
  }

let note_closing_save turn outcome = Atomic.set turn.closing_save (Some outcome)

type exit =
  | Returned_ok
  | Returned_error
  | Raised
  | Cancelled

let ending exit closing_save : Writer.ending =
  match exit, closing_save with
  | Cancelled, (None | Some (Saved | Stale | Failed)) -> Cancelled
  | (Returned_ok | Returned_error | Raised), Some Failed -> Save_failed
  | (Returned_ok | Returned_error | Raised), Some Stale -> Stale_save
  | Returned_ok, (None | Some Saved) -> Completed
  | (Returned_error | Raised), (None | Some Saved) -> Errored
;;

(* The same two values the Librarian question shows for a Goal. *)
let goal_shown ~goal_id (goal : Goal_store.goal) : Turn_log.goal_shown =
  { goal = goal_id
  ; shown =
      Yojson.Safe.to_string
        (`Assoc
            [ "phase", Goal_phase.to_yojson goal.phase
            ; "criterion", Goal_store.criterion_to_yojson (Goal_store.criterion_of_goal goal)
            ])
  }
;;

let task_evidence ~config : (Keeper_id.Task_id.t option, string) result -> Turn_log.task_evidence =
  function
  | Error (_ : string) -> Task_source_unavailable
  | Ok None -> No_task
  | Ok (Some task_id) ->
    let goals =
      let open Result.Syntax in
      let* links = Workspace_goal_index.read_goal_task_links_authoritative_r config in
      let task_goal_map =
        Workspace_goal_index.build_task_goal_map ~goal_task_links:links ()
      in
      let ids =
        Workspace_goal_index.goals_for_task_in_map
          task_goal_map
          ~task_id:(Keeper_id.Task_id.to_string task_id)
      in
      if ids = []
      then Ok []
      else
        let* goals_by_id =
          Goal_store.load_goals_by_id_result config
          |> Result.map_error Goal_store.unavailable_to_string
        in
        let rec resolve acc = function
          | [] -> Ok (List.rev acc)
          | goal_id :: rest ->
            (match Goal_store.Goal_id_map.find_opt goal_id goals_by_id with
             | None -> Error ("linked Goal is missing: " ^ goal_id)
             | Some goal -> resolve (goal_shown ~goal_id goal :: acc) rest)
        in
        resolve [] ids
    in
    Task { task = task_id; goals = Result.to_option goals }
;;

let board_item ~post (signal : Keeper_event_queue.board_stimulus) : Turn_log.board_item =
  let event : Turn_log.board_event =
    match signal.kind with
    | Post_created -> Post_created
    | Post_updated { content_updated_at = (_ : float) } -> Post_updated
    | Comment_added { comment_id; parent_id = (_ : string option) } ->
      Comment_added { comment = comment_id }
    | Reaction_changed { user_id; _ } -> Reaction_changed { by = user_id }
    | Vote_cast { voter; _ } -> Vote_cast { by = voter }
  in
  { post; author = signal.author; event }
;;

let completion_judge : Masc_domain.completion_authority -> Turn_log.completion_judge = function
  | Human_operator { operator_id } -> Human_operator { operator = operator_id }
  | System_llm_agent { agent_run_id } -> System_agent { run = agent_run_id }
;;

(* Ids and names only. What an entry says stays in the store its id points
   at, and the answer or the reason an entry carries is in the turn's own
   messages once the turn has read it. *)
let stimulus (queued : Keeper_event_queue.stimulus) : Turn_log.stimulus =
  match queued.payload with
  | Board_signal signal -> Board (board_item ~post:queued.post_id signal)
  | Board_routing_pending signal ->
    Board_routing_pending (board_item ~post:queued.post_id signal)
  | Board_attention { candidate_id; signal } ->
    Board_attention { candidate = candidate_id; item = board_item ~post:queued.post_id signal }
  | Bootstrap -> Bootstrap
  | Tool_result_ready receipt -> Tool_result { receipt }
  | Fusion_completed { run_id; _ } -> Fusion { run = run_id }
  | Schedule_due { schedule_id; occurrence_id; _ } ->
    Schedule { schedule = schedule_id; occurrence = occurrence_id }
  | Connector_attention { event_id; channel = (_ : Keeper_continuation_channel.t) } ->
    Connector { attention = event_id }
  | Hitl_resolved { approval_id; _ } -> Hitl { approval = approval_id }
  | Ask_answered { ask_id; channel = (_ : Keeper_continuation_channel.t) } -> Ask { ask = ask_id }
  | Completion_authority_rejected { car_task_id; car_verification_id; car_authority; _ } ->
    Completion_rejected
      { task = car_task_id
      ; verification = car_verification_id
      ; judge = completion_judge car_authority
      }
  | Task_outcome { to_task_id; to_verification_id; to_authority; _ } ->
    Completion_approved
      { task = to_task_id
      ; verification = to_verification_id
      ; judge = completion_judge to_authority
      }
  | Task_cancelled { tc_task_id; tc_cancelled_by; tc_reason = (_ : string option) } ->
    Task_cancelled { task = tc_task_id; by = tc_cancelled_by }
  | Workspace_message { wmsg_request_id; wmsg_from } ->
    Workspace_message { request = wmsg_request_id; from = wmsg_from }
  | Delegate_completed { dc_operation_id; dc_keeper; _ } ->
    Delegate { operation = dc_operation_id; keeper = dc_keeper }
  | Composition_completed { cc_request_id; cc_tool; _ } ->
    Composition { request = cc_request_id; tool = cc_tool }
  | Owned_job_completed { oj_job_id; _ } ->
    Owned_job { job = Keeper_owned_job_identity.Job_id.to_string oj_job_id }
;;

type site =
  | Admission
  | End

let site_label = function
  | Admission -> "admission"
  | End -> "end"
;;

let not_written ~(place : Recorder.place) ~turn_ref site detail =
  Log.Keeper.error
    ~keeper_name:place.keeper_name
    "turn log line not written at %s turn=%d: %s"
    (site_label site)
    (Ids.Turn_ref.absolute_turn turn_ref)
    detail;
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string TurnLogAppendFailures)
    ~labels:[ "keeper", place.keeper_name; "site", site_label site ]
    ()
;;

let record place event =
  Recorder.record ~at:(Time_compat.now ()) ~new_log_id:(Turn_log.Log_id.fresh ()) place event
;;

(* A cancellation before the turn started is the turn's own and leaves. Any
   other failure is the log's: the turn starts without its line. *)
let admit ~place ~turn_ref ~runtime ~task ~stimuli =
  let admitted =
    match record place (Writer.Admit { turn_ref; runtime; task; stimuli }) with
    | Ok (Recorder.Appended _ | Nothing_to_append) as answer -> Recorder.admitted answer
    | Error error as answer ->
      not_written ~place ~turn_ref Admission (Recorder.not_recorded_to_string error);
      Recorder.admitted answer
    | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
    | exception exn ->
      not_written ~place ~turn_ref Admission (Printexc.to_string exn);
      Writer.Not_recorded
  in
  { place; turn_ref; admitted; closing_save = Atomic.make None }
;;

(* Protected: a cancelled fiber cannot do file I/O, and the turn's end is
   written all the same. No exception leaves, a cancellation included: under
   the protection one can only come from inside the write, and the fiber's
   own cancellation is raised again by whatever the caller does next. *)
let finish turn exit =
  Eio.Cancel.protect
  @@ fun () ->
  match turn.admitted with
  (* Its admission is not in the log, so neither is its end. What it closed
     is named by the next unit. *)
  | Writer.Not_recorded -> ()
  | Recorded { opened = (_ : int) } as admitted ->
    let ending = ending exit (Atomic.get turn.closing_save) in
    let not_written = not_written ~place:turn.place ~turn_ref:turn.turn_ref End in
    (match record turn.place (Writer.Finish { admitted; ending }) with
     | Ok (Recorder.Appended _) -> ()
     (* The log no longer shows this turn open: its file was replaced under
        the turn. What the turn closed is named by the next unit, without the
        turn's Task. *)
     | Ok Recorder.Nothing_to_append -> not_written "the turn is not the open one in the log"
     | Error error -> not_written (Recorder.not_recorded_to_string error)
     | exception exn -> not_written (Printexc.to_string exn))
;;

let exit_of_exception = function
  | Eio.Cancel.Cancelled _ -> Cancelled
  | exn -> if Keeper_registry_types.is_operator_interrupt exn then Cancelled else Raised
;;

let around ~place ~turn_ref ~runtime ~task ~stimuli ~succeeded body =
  let turn = admit ~place ~turn_ref ~runtime ~task ~stimuli in
  match body turn with
  | answer ->
    finish turn (if succeeded answer then Returned_ok else Returned_error);
    answer
  | exception exn ->
    let backtrace = Printexc.get_raw_backtrace () in
    finish turn (exit_of_exception exn);
    Printexc.raise_with_backtrace exn backtrace
;;
