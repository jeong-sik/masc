type outcome =
  | Turn_ok
  | Turn_rested
  | Turn_failed

type tally =
  { ok : int
  ; rested : int
  ; failed : int
  }

type slot =
  { starts_at : int
  ; tally : tally
  }

type pulse =
  { known_since : float
  ; slots : slot list
  }

let slot_seconds = 1800
let window_seconds = 86400
let slot_start at = int_of_float (Float.floor (at /. float_of_int slot_seconds)) * slot_seconds
let empty_tally = { ok = 0; rested = 0; failed = 0 }

let count tally = function
  | Turn_ok -> { tally with ok = tally.ok + 1 }
  | Turn_rested -> { tally with rested = tally.rested + 1 }
  | Turn_failed -> { tally with failed = tally.failed + 1 }
;;

(* [slots] is newest first. A turn usually lands in the newest slot; a turn
   from another domain may end a little earlier than the last one recorded, so
   it is inserted where its slot belongs. *)
let rec add_turn starts_at outcome = function
  | [] -> [ { starts_at; tally = count empty_tally outcome } ]
  | slot :: older when slot.starts_at = starts_at ->
    { slot with tally = count slot.tally outcome } :: older
  | slot :: _ as slots when slot.starts_at < starts_at ->
    { starts_at; tally = count empty_tally outcome } :: slots
  | slot :: older -> slot :: add_turn starts_at outcome older
;;

(* Pruning forgets the turns before [horizon], so [known_since] moves up to
   it: a reader drawing further back sees unknown hours, not quiet ones. *)
let add_to_pulse pulse ~at outcome =
  let starts_at = slot_start at in
  let slots = add_turn starts_at outcome pulse.slots in
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

let record ~base_path ~keeper_name ~at outcome =
  let key = base_path, keeper_name in
  let rec loop () =
    let current = Atomic.get state in
    let existing =
      match KeyMap.find_opt key current with
      | Some pulse -> pulse
      | None -> { known_since = at; slots = [] }
    in
    let next = KeyMap.add key (add_to_pulse existing ~at outcome) current in
    if Atomic.compare_and_set state current next then () else loop ()
  in
  loop ()
;;

let get ~base_path ~keeper_name = KeyMap.find_opt (base_path, keeper_name) (Atomic.get state)

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
  }

(* Every decision row carries [ts_unix]. A row of any event shows the log was
   being written at that time. *)
let row_time json =
  match Yojson.Safe.Util.member "ts_unix" json with
  | `Float f when Float.is_finite f -> Some f
  | `Int i -> Some (Float.of_int i)
  | _ -> None
;;

(* Chat turns write the same [event = "turn"] row; only the autonomous cycle
   records into the live pulse, so only its rows seed it (#49984). *)
let sample_of_row json =
  let autonomous =
    match Json_util.get_string json "execution_path" with
    | Some label ->
      (match Keeper_unified_metrics_decision.execution_path_of_string label with
       | Some Autonomous_cycle -> true
       | Some Direct_turn | None -> false)
    | None -> false
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
  match Json_util.get_string json "event", row_time json, outcome with
  | Some "turn", Some at, Some outcome when autonomous -> Some { at; outcome }
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
let read_tail ~now ~window_start path =
  if not (Fs_compat.file_exists path)
  then Ok Log_absent
  else (
    match
      Keeper_memory.read_file_tail_lines_with_completion
        path
        ~max_bytes:seed_tail_max_bytes
        ~max_lines:seed_tail_max_lines
    with
    | Error exn_class ->
      Keeper_memory.record_memory_recall_read_error
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
                  match sample_of_row json with
                  | Some sample -> sample :: samples
                  | None -> samples
                in
                collect samples (earliest oldest_row (Some at)) rest))
      in
      Ok (collect [] None (List.rev lines)))
;;

let pulse_of_samples ~known_since samples =
  List.fold_left
    (fun pulse sample -> add_to_pulse pulse ~at:sample.at sample.outcome)
    { known_since; slots = [] }
    (List.rev samples)
;;

(* The logs hold every turn since the oldest row read, so the pulse is known
   from there; a row older than the window makes it the window start. With no
   row read it is known from [now], when the server starts recording. *)
let seed_from_decision_log ?(now = Time_compat.now ()) ~config ~keeper_name () =
  let base_path = config.Workspace.base_path in
  let primary_path = Keeper_types_support.keeper_decision_log_path config keeper_name in
  let window_start = now -. float_of_int window_seconds in
  let read path = read_tail ~now ~window_start path in
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
  let seeded =
    match read primary_path with
    | Error _ -> None
    | Ok Log_absent -> with_rotated ~newer:[] ~newer_oldest:None
    | Ok (Reaches_window_start samples) -> Some (window_start, samples)
    | Ok (Starts_inside_window { samples; oldest_row; whole_file = false }) ->
      Some (known_from oldest_row, samples)
    | Ok (Starts_inside_window { samples; oldest_row; whole_file = true }) ->
      with_rotated ~newer:samples ~newer_oldest:oldest_row
  in
  match seeded with
  | Some (known_since, samples) ->
    seed ~base_path ~keeper_name (pulse_of_samples ~known_since samples)
  | None -> ()
;;

let seed_all_from_decision_logs ?(now = Time_compat.now ()) ~config () =
  match Keeper_meta_store.keeper_names_result config with
  | Ok names ->
    List.iter (fun keeper_name -> seed_from_decision_log ~now ~config ~keeper_name ()) names
  | Error _ -> ()
;;

let reset_for_tests () = Atomic.set state KeyMap.empty
