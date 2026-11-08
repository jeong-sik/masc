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

let within_window ~newest_slot slots =
  List.filter (fun slot -> slot.starts_at >= newest_slot - window_seconds) slots
;;

let add_to_pulse pulse ~at outcome =
  let starts_at = slot_start at in
  let slots = add_turn starts_at outcome pulse.slots in
  let newest_slot =
    match slots with
    | newest :: _ -> newest.starts_at
    | [] -> starts_at
  in
  { pulse with slots = within_window ~newest_slot slots }
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

let sample_of_decision_line line =
  match Yojson.Safe.from_string line with
  | exception _ -> None
  | json ->
    (match Json_util.get_string json "event" with
     | Some "turn" ->
       let ts_opt =
         match Yojson.Safe.Util.member "ts_unix" json with
         | `Float f when Float.is_finite f -> Some f
         | `Int i -> Some (Float.of_int i)
         | _ -> None
       in
       let outcome_opt =
         match Json_util.get_string json "outcome" with
         | Some out_str ->
           (match Keeper_decision_outcome.of_string out_str with
            | Some (Success | Checkpoint | Input_required) -> Some Turn_ok
            | Some Failed -> Some Turn_failed
            | None -> None)
         | None -> None
       in
       (match ts_opt, outcome_opt with
        | Some at, Some outcome -> Some { at; outcome }
        | _ -> None)
     | _ -> None)
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
      (** A turn older than the window was read; newest first. *)
  | Starts_inside_window of
      { samples : sample list  (** Newest first. *)
      ; whole_file : bool  (** The read reached the start of the file. *)
      }

(* [Error] is a log that exists but could not be read. It says nothing about
   its turns, so the caller must not turn it into an empty pulse. *)
let read_tail ~window_start path =
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
    | Ok (lines, _completion) ->
      let whole_file () =
        List.length lines < seed_tail_max_lines
        &&
        match Fs_compat.file_size path with
        | Some size -> size <= seed_tail_max_bytes
        | None -> false
      in
      (* [lines] runs oldest to newest; walk it newest first. *)
      let rec collect acc = function
        | [] -> Starts_inside_window { samples = List.rev acc; whole_file = whole_file () }
        | line :: rest ->
          (match sample_of_decision_line line with
           | Some s when s.at >= window_start -> collect (s :: acc) rest
           | Some _ -> Reaches_window_start (List.rev acc)
           | None -> collect acc rest)
      in
      Ok (collect [] (List.rev lines)))
;;

(* Samples are newest first, so the last one is the oldest. *)
let oldest_or ~now samples =
  match List.rev samples with
  | oldest :: _ -> oldest.at
  | [] -> now
;;

let pulse_of_samples ~known_since samples =
  List.fold_left
    (fun pulse sample -> add_to_pulse pulse ~at:sample.at sample.outcome)
    { known_since; slots = [] }
    (List.rev samples)
;;

let seed_from_decision_log ?(now = Time_compat.now ()) ~config ~keeper_name () =
  let base_path = config.Workspace.base_path in
  let primary_path = Keeper_types_support.keeper_decision_log_path config keeper_name in
  let rotated_path = primary_path ^ ".1" in
  let window_start = now -. float_of_int window_seconds in
  let seeded =
    match read_tail ~window_start primary_path with
    | Error _ -> None
    | Ok Log_absent -> Some (window_start, [])
    | Ok (Reaches_window_start samples) -> Some (window_start, samples)
    | Ok (Starts_inside_window { samples; whole_file = false }) ->
      Some (oldest_or ~now samples, samples)
    | Ok (Starts_inside_window { samples = primary; whole_file = true }) ->
      (match read_tail ~window_start rotated_path with
       | Error _ -> None
       | Ok Log_absent -> Some (window_start, primary)
       | Ok (Reaches_window_start rotated) -> Some (window_start, primary @ rotated)
       | Ok (Starts_inside_window { samples = rotated; _ }) ->
         (* Rotation dropped whatever came before the rotated log. *)
         let samples = primary @ rotated in
         Some (oldest_or ~now samples, samples))
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
