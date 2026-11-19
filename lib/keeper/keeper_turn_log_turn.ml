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

(* The same two values today's Librarian question shows for a Goal. *)
let goal_shown (goal : Keeper_turn_task_context.goal) : Turn_log.goal_shown =
  { goal = goal.goal_id
  ; shown =
      Yojson.Safe.to_string
        (`Assoc
            [ "phase", Goal_phase.to_yojson goal.phase
            ; "criterion", Goal_store.criterion_to_yojson goal.criterion
            ])
  }
;;

let task_evidence : Keeper_turn_task_context.t -> Turn_log.task_evidence = function
  | No_task -> No_task
  (* [Admission_not_recorded] is what an old boundary line decodes to. A
     context captured for a turn is never that; either way the Task is not
     known. *)
  | Admission_not_recorded | Task_source_unavailable (_ : string) -> Task_source_unavailable
  | Task { task_id; goals = Ok goals } ->
    Task { task = task_id; goals = Some (List.map goal_shown goals) }
  | Task { task_id; goals = Error (_ : Keeper_turn_task_context.source_error) } ->
    Task { task = task_id; goals = None }
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
let admit ~place ~turn_ref ~runtime ~task =
  let admitted =
    match record place (Writer.Admit { turn_ref; runtime; task }) with
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

let around ~place ~turn_ref ~runtime ~task ~succeeded body =
  let turn = admit ~place ~turn_ref ~runtime ~task in
  match body turn with
  | answer ->
    finish turn (if succeeded answer then Returned_ok else Returned_error);
    answer
  | exception exn ->
    let backtrace = Printexc.get_raw_backtrace () in
    finish turn (exit_of_exception exn);
    Printexc.raise_with_backtrace exn backtrace
;;
