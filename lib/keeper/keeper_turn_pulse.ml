type outcome =
  | Turn_ok
  | Turn_rested
  | Turn_failed

type cause =
  | Scheduled
  | Reacted
  | Chat
  | Own

type tally =
  { ok : int
  ; rested : int
  ; failed : int
  }

type causes =
  { scheduled : int
  ; reacted : int
  ; chat : int
  ; own : int
  ; unknown : int
  }

type slot =
  { starts_at : int
  ; tally : tally
  ; causes : causes
  }

type pulse =
  { known_since : float
  ; slots : slot list
  }

let slot_seconds = 1800
let window_seconds = 86400
let slot_start at = int_of_float (Float.floor (at /. float_of_int slot_seconds)) * slot_seconds
let empty_tally = { ok = 0; rested = 0; failed = 0 }
let empty_causes = { scheduled = 0; reacted = 0; chat = 0; own = 0; unknown = 0 }

let count tally = function
  | Turn_ok -> { tally with ok = tally.ok + 1 }
  | Turn_rested -> { tally with rested = tally.rested + 1 }
  | Turn_failed -> { tally with failed = tally.failed + 1 }
;;

(* A missing cause remains unknown during live acquisition and restart. *)
let count_cause causes = function
  | Some Scheduled -> { causes with scheduled = causes.scheduled + 1 }
  | Some Reacted -> { causes with reacted = causes.reacted + 1 }
  | Some Chat -> { causes with chat = causes.chat + 1 }
  | Some Own -> { causes with own = causes.own + 1 }
  | None -> { causes with unknown = causes.unknown + 1 }
;;

let first_turn starts_at ~cause outcome =
  { starts_at
  ; tally = count empty_tally outcome
  ; causes = count_cause empty_causes cause
  }
;;

(* [slots] is newest first. A turn usually lands in the newest slot; a turn
   from another domain may end a little earlier than the last one recorded, so
   it is inserted where its slot belongs. *)
let rec add_turn starts_at ~cause outcome = function
  | [] -> [ first_turn starts_at ~cause outcome ]
  | slot :: older when slot.starts_at = starts_at ->
    { slot with
      tally = count slot.tally outcome
    ; causes = count_cause slot.causes cause
    }
    :: older
  | slot :: _ as slots when slot.starts_at < starts_at ->
    first_turn starts_at ~cause outcome :: slots
  | slot :: older -> slot :: add_turn starts_at ~cause outcome older
;;

(* Pruning forgets the turns before [horizon], so [known_since] moves up to
   it: a reader drawing further back sees unknown hours, not quiet ones. *)
let add_to_pulse pulse ~at ~cause outcome =
  let starts_at = slot_start at in
  let slots = add_turn starts_at ~cause outcome pulse.slots in
  let newest_slot =
    match slots with
    | newest :: _ -> newest.starts_at
    | [] -> starts_at
  in
  let horizon = newest_slot - window_seconds in
  { known_since = Float.max pulse.known_since (float_of_int horizon)
  ; slots = List.filter (fun slot -> slot.starts_at >= horizon) slots
  }
;;

module Key = struct
  type t = string * string

  let compare (b1, k1) (b2, k2) =
    let c = String.compare b1 b2 in
    if c <> 0 then c else String.compare k1 k2
  ;;
end

module KeyMap = Map.Make (Key)

let state : pulse KeyMap.t Atomic.t = Atomic.make KeyMap.empty

let cause_of_channel channel ~schedule_due =
  match channel with
  | Keeper_world_observation.Reactive -> Reacted
  | Keeper_world_observation.Scheduled_autonomous -> if schedule_due then Scheduled else Own
;;

let cause_of_decision (decision : Keeper_world_observation.keeper_cycle_decision) =
  match decision.verdict with
  | Skip _ -> None
  | Run { reasons = first, rest } ->
    let schedule_due = List.mem Keeper_world_observation.Scheduled_automation_due (first :: rest) in
    Some (cause_of_channel decision.channel ~schedule_due)
;;

let logged_schedule : Keeper_turn_log.stimulus -> bool = function
  | Schedule _ -> true
  | Board _ | Board_routing_pending _ | Board_attention _ | Bootstrap | Tool_result _
  | Fusion _ | Connector _ | Hitl _ | Ask _ | Completion_rejected _ | Completion_approved _
  | Task_cancelled _ | Workspace_message _ | Delegate _ | Composition _ | Owned_job _ -> false
;;

let record ~base_path ~keeper_name ~at ?cause outcome =
  let key = base_path, keeper_name in
  let rec loop () =
    let current = Atomic.get state in
    let existing =
      match KeyMap.find_opt key current with
      | Some pulse -> pulse
      | None -> { known_since = at; slots = [] }
    in
    let next = KeyMap.add key (add_to_pulse existing ~at ~cause outcome) current in
    if Atomic.compare_and_set state current next then () else loop ()
  in
  loop ()
;;

let get ~base_path ~keeper_name = KeyMap.find_opt (base_path, keeper_name) (Atomic.get state)

let turns_in_window ~now (pulse : pulse) =
  let current_slot = slot_start now in
  let slots_per_window = window_seconds / slot_seconds in
  let window_start = current_slot - ((slots_per_window - 1) * slot_seconds) in
  List.fold_left
    (fun total (slot : slot) ->
      if slot.starts_at >= window_start && slot.starts_at <= current_slot
      then total + slot.tally.ok + slot.tally.failed
      else total)
    0
    pulse.slots
;;

let slot_to_json { starts_at; tally = { ok; rested; failed }; causes } =
  let { scheduled; reacted; chat; own; unknown } = causes in
  `Assoc
    [ "starts_at", `Int starts_at
    ; "ok", `Int ok
    ; "rested", `Int rested
    ; "failed", `Int failed
    ; "scheduled", `Int scheduled
    ; "reacted", `Int reacted
    ; "chat", `Int chat
    ; "own", `Int own
    ; "unknown", `Int unknown
    ]
;;

let recent_turns_json ~base_path ~keeper_name =
  match get ~base_path ~keeper_name with
  | None -> `Null
  | Some pulse ->
    `Assoc
      [ "known_since", `Float pulse.known_since
      ; "slots", `List (List.map slot_to_json pulse.slots)
      ]
;;

let seed ~base_path ~keeper_name pulse =
  let key = base_path, keeper_name in
  let rec loop () =
    let current = Atomic.get state in
    match KeyMap.find_opt key current with
    | Some _ -> ()
    | None ->
      let next = KeyMap.add key pulse current in
      if Atomic.compare_and_set state current next then () else loop ()
  in
  loop ()
;;

type sample =
  { at : float
  ; outcome : outcome
  ; cause : cause option
  }

(* Every decision row carries [ts_unix]. A row of any event shows the log was
   being written at that time. *)
let row_time json =
  match Yojson.Safe.Util.member "ts_unix" json with
  | `Float f when Float.is_finite f -> Some f
  | `Int i -> Some (Float.of_int i)
  | _ -> None
;;

(* The turn ref the turn log keys an [Opened] line by: the decision row's
   session trace and its absolute turn number. *)
let turn_ref_of_row json =
  match Json_util.get_string json "trace_id", Yojson.Safe.Util.member "turn_id" json with
  | Some trace_id, `Int absolute_turn ->
    Some (Ids.Turn_ref.to_string (Ids.Turn_ref.make ~trace_id ~absolute_turn))
  | Some _, _ | None, _ -> None
;;

(* Both lanes write an [event = "turn"] row and both record into the live
   pulse, so both seed it. [cause] is [None] for a row that names no lane,
   which is read past, and [Some None] for a turn whose retained records
   cannot name its cause, which counts as unknown. *)
let sample_of_row ~schedule_of_turn json =
  let autonomous_cause () =
    let open Keeper_world_observation in
    match Option.bind (Json_util.get_string json "channel") channel_of_string with
    | None -> None
    | Some Reactive -> Some Reacted
    | Some Scheduled_autonomous ->
      (match Yojson.Safe.Util.member "wake_reasons" json with
       | `List (_ :: _ as reasons) when List.for_all (function `String _ -> true | _ -> false) reasons ->
         let due = Keeper_world_observation_turn_types.turn_reason_to_string Scheduled_automation_due in
         Some (cause_of_channel Scheduled_autonomous ~schedule_due:(List.mem (`String due) reasons))
       | `Null ->
         (* Earlier rows kept the observation and a separate turn receipt. *)
         let observation = Yojson.Safe.Util.member "observation" json in
         let due_ready = match observation with
           | `Assoc _ -> Json_util.get_int observation "scheduled_automation_due_ready_count"
           | _ -> None in
         (match due_ready with
          | Some count when count > 0 -> Some Scheduled
          | _ -> Option.bind (turn_ref_of_row json) schedule_of_turn
                 |> Option.map (fun due -> cause_of_channel Scheduled_autonomous ~schedule_due:due))
       | _ -> None)
  in
  let cause =
    match Option.bind (Json_util.get_string json "execution_path")
            Keeper_unified_metrics_decision.execution_path_of_string with
    | Some Direct_turn -> Some (Some Chat)
    | Some Autonomous_cycle -> Some (autonomous_cause ())
    | None -> None
  in
  let outcome =
    match Json_util.get_string json "outcome" with
    | Some label ->
      (match Keeper_decision_outcome.of_string label with
       | Some (Success | Checkpoint | Input_required) -> Some Turn_ok
       | Some Failed -> Some Turn_failed
       | None -> None)
    | None -> None
  in
  match Json_util.get_string json "event", row_time json, outcome, cause with
  | Some "turn", Some at, Some outcome, Some cause -> Some { at; outcome; cause }
  | _ -> None
;;

(* The tail a seed reads from each log. Measured 2026-11-09 on the live
   workspace, a day of the busiest keeper's log took 2,715 lines and 2.3 MB, so
   these reach back a day with room; a log longer than this is read to here and
   [known_since] says where the read stopped. *)
let seed_tail_max_bytes = 4 * 1024 * 1024
let seed_tail_max_lines = 10_000

type tail_reading =
  | Log_absent
  | Reaches_window_start of sample list
      (** A row older than the window was read; samples newest first. *)
  | Starts_inside_window of
      { samples : sample list  (** Newest first. *)
      ; oldest_row : float option  (** The oldest row read, of any event. *)
      ; whole_file : bool  (** The read reached the start of the file. *)
      }

let earliest a b =
  match a, b with
  | Some x, Some y -> Some (Float.min x y)
  | (Some _ as x), None | None, (Some _ as x) -> x
  | None, None -> None
;;

(* [Error] is a log that exists but could not be read. It says nothing about
   its turns, so the caller must not turn it into an empty pulse. A row stamped
   after [now] is dropped: its slot would lie past every hour the TUI draws and
   would prune the day behind it. *)
let read_tail ~schedule_of_turn ~now ~window_start path =
  if not (Fs_compat.file_exists path)
  then Ok Log_absent
  else (
    match
      Keeper_memory_recall.read_file_tail_lines_with_completion
        path
        ~max_bytes:seed_tail_max_bytes
        ~max_lines:seed_tail_max_lines
    with
    | Error exn_class ->
      Keeper_memory_recall.record_memory_recall_read_error
        ~site:"keeper_turn_pulse_seed"
        path
        exn_class;
      Error exn_class
    | Ok { lines; completion = _; from_file_start } ->
      (* [lines] runs oldest to newest; walk it newest first. *)
      let rec collect samples oldest_row = function
        | [] ->
          Starts_inside_window
            { samples = List.rev samples; oldest_row; whole_file = from_file_start }
        | line :: rest ->
          (match Yojson.Safe.from_string line with
           | exception _ -> collect samples oldest_row rest
           | json ->
             (match row_time json with
              | None -> collect samples oldest_row rest
              | Some at when at > now -> collect samples oldest_row rest
              | Some at when at < window_start -> Reaches_window_start (List.rev samples)
              | Some at ->
                let samples =
                  match sample_of_row ~schedule_of_turn json with
                  | Some sample -> sample :: samples
                  | None -> samples
                in
                collect samples (earliest oldest_row (Some at)) rest))
      in
      Ok (collect [] None (List.rev lines)))
;;

let pulse_of_samples ~known_since samples =
  List.fold_left
    (fun pulse sample -> add_to_pulse pulse ~at:sample.at ~cause:sample.cause sample.outcome)
    { known_since; slots = [] }
    (List.rev samples)
;;

(* The turn log only grows, so the seed reads its tail as it reads a decision
   log's. Measured 2026-11-23 on the live workspace, the busiest keeper's turn
   log took 1.56 MB for its last 48 hours, so the decision log's bounds reach
   back past the window a turn can have opened in. *)
let turn_log_tail_max_bytes = seed_tail_max_bytes
let turn_log_tail_max_lines = seed_tail_max_lines

(* Schedule inputs of turns the turn log opened since a window before
   [window_start], keyed by turn ref: a turn that ended inside the window may
   have opened before it. A turn opened before the tail read, or a log that
   cannot be read, gives no schedule input evidence. *)
let logged_schedules ~config ~keeper_name ~window_start =
  let path =
    Keeper_turn_log_store.path_for_keepers_dir
      ~keepers_dir:(Workspace.keepers_runtime_dir config)
      ~keeper_id:keeper_name
  in
  let opened_since = window_start -. float_of_int window_seconds in
  let schedules = Hashtbl.create 256 in
  let add line =
    match Yojson.Safe.from_string line with
    | exception Yojson.Json_error _ -> ()
    | json ->
      (match Keeper_turn_log_codec.of_json json with
       | Ok (Keeper_turn_log.Opened { at; turn_ref; stimuli; _ }) when at >= opened_since ->
         Hashtbl.replace
           schedules
           (Ids.Turn_ref.to_string turn_ref)
           (List.exists logged_schedule stimuli)
       | Ok
           ( Keeper_turn_log.Opened _
           | Keeper_turn_log.Log_started _
           | Keeper_turn_log.Closed _
           | Keeper_turn_log.Reset _ )
       | Error _ -> ())
  in
  if Fs_compat.file_exists path
  then (
    match
      Keeper_memory_recall.read_file_tail_lines_with_completion
        path
        ~max_bytes:turn_log_tail_max_bytes
        ~max_lines:turn_log_tail_max_lines
    with
    | Ok { lines; completion = _; from_file_start = _ } -> List.iter add lines
    | Error exn_class ->
      Keeper_memory_recall.record_memory_recall_read_error
        ~site:"keeper_turn_pulse_seed_turn_log"
        path
        exn_class;
      Log.Keeper.warn
        ~keeper_name
        "turn pulse seed could not read the turn log, so scheduled-channel rows can lack schedule evidence");
  schedules
;;

(* The logs hold every turn since the oldest row read, so the pulse is known
   from there; a row older than the window makes it the window start. With no
   row read it is known from [now], when the server starts recording. *)
let read_seed ~now ~config ~keeper_name =
  let primary_path = Keeper_types_support.keeper_decision_log_path config keeper_name in
  let window_start = now -. float_of_int window_seconds in
  (* The turn log is read only for a scheduled decision that needs input evidence. *)
  let schedules = lazy (logged_schedules ~config ~keeper_name ~window_start) in
  let schedule_of_turn turn_ref = Hashtbl.find_opt (Lazy.force schedules) turn_ref in
  let read path = read_tail ~schedule_of_turn ~now ~window_start path in
  let known_from oldest_row = Option.value oldest_row ~default:now in
  (* [newer] were read from the primary log, which begins where the rotated log
     ends. A rotated log read whole may still follow a [.2] or a deleted log,
     so its first row is as far back as the seed knows. *)
  let with_rotated ~newer ~newer_oldest =
    match read (primary_path ^ ".1") with
    | Error _ -> None
    | Ok Log_absent -> Some (known_from newer_oldest, newer)
    | Ok (Reaches_window_start older) -> Some (window_start, newer @ older)
    | Ok (Starts_inside_window { samples = older; oldest_row; whole_file = _ }) ->
      Some (known_from (earliest oldest_row newer_oldest), newer @ older)
  in
  match read primary_path with
  | Error _ -> None
  | Ok Log_absent -> with_rotated ~newer:[] ~newer_oldest:None
  | Ok (Reaches_window_start samples) -> Some (window_start, samples)
  | Ok (Starts_inside_window { samples; oldest_row; whole_file = false }) ->
    Some (known_from oldest_row, samples)
  | Ok (Starts_inside_window { samples; oldest_row; whole_file = true }) ->
    with_rotated ~newer:samples ~newer_oldest:oldest_row
;;

let seed_from_decision_log ?(now = Time_compat.now ()) ~config ~keeper_name () =
  let base_path = config.Workspace.base_path in
  match get ~base_path ~keeper_name with
  | Some _ -> ()
  | None ->
    (match read_seed ~now ~config ~keeper_name with
     | Some (known_since, samples) ->
       seed ~base_path ~keeper_name (pulse_of_samples ~known_since samples)
     | None -> ())
;;

let seed_all_from_decision_logs ?(now = Time_compat.now ()) ~config () =
  match Keeper_meta_store.keeper_names_result config with
  | Ok names ->
    List.iter (fun keeper_name -> seed_from_decision_log ~now ~config ~keeper_name ()) names
  | Error _ -> ()
;;

let reset_for_tests () = Atomic.set state KeyMap.empty
