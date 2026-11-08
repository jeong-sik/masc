type outcome =
  | Turn_ok
  | Turn_rested
  | Turn_failed

let outcome_to_string = function
  | Turn_ok -> "ok"
  | Turn_rested -> "rested"
  | Turn_failed -> "failed"

let outcome_of_string = function
  | "ok" -> Some Turn_ok
  | "rested" -> Some Turn_rested
  | "failed" -> Some Turn_failed
  | _ -> None
;;

type sample =
  { at : float
  ; outcome : outcome
  }

type pulse =
  { samples : sample list
  ; truncated : bool
  }

let max_samples_per_keeper = 24

module Key = struct
  type t = string * string

  let compare (b1, k1) (b2, k2) =
    let c = String.compare b1 b2 in
    if c <> 0 then c else String.compare k1 k2
  ;;
end

module KeyMap = Map.Make (Key)

let state : pulse KeyMap.t Atomic.t = Atomic.make KeyMap.empty

let rec take n = function
  | [] -> []
  | _ when n <= 0 -> []
  | x :: xs -> x :: take (n - 1) xs
;;

let record ~base_path ~keeper_name ~at outcome =
  let key = base_path, keeper_name in
  let new_sample = { at; outcome } in
  let rec loop () =
    let current = Atomic.get state in
    let next_val =
      match KeyMap.find_opt key current with
      | None -> { samples = [ new_sample ]; truncated = false }
      | Some existing ->
        let combined = new_sample :: existing.samples in
        if List.length combined > max_samples_per_keeper
        then { samples = take max_samples_per_keeper combined; truncated = true }
        else { samples = combined; truncated = existing.truncated }
    in
    let next = KeyMap.add key next_val current in
    if Atomic.compare_and_set state current next then () else loop ()
  in
  loop ()
;;

let get ~base_path ~keeper_name =
  KeyMap.find_opt (base_path, keeper_name) (Atomic.get state)
;;

let seed ?(override = false) ~base_path ~keeper_name ~samples ~truncated () =
  let key = base_path, keeper_name in
  let rec loop () =
    let current = Atomic.get state in
    match KeyMap.find_opt key current with
    | Some _ when not override -> ()
    | _ ->
      let is_truncated = truncated || List.length samples > max_samples_per_keeper in
      let bounded_samples =
        if List.length samples > max_samples_per_keeper
        then take max_samples_per_keeper samples
        else samples
      in
      let next =
        KeyMap.add key { samples = bounded_samples; truncated = is_truncated } current
      in
      if Atomic.compare_and_set state current next then () else loop ()
  in
  loop ()
;;

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

(* [Error] is a log that exists but could not be read. A missing log and a log
   with no turns in the window are [Ok] with no samples: the keeper has no turns
   to show. An unreadable log says nothing about its turns, so the caller must
   not turn it into an empty pulse. *)
let read_tail_window_samples ~now ~window_seconds path =
  if not (Fs_compat.file_exists path)
  then Ok ([], false)
  else (
    match
      Keeper_memory.read_file_tail_lines_with_completion
        path
        ~max_bytes:1048576
        ~max_lines:1000
    with
    | Error exn_class ->
      Keeper_memory.record_memory_recall_read_error
        ~site:"keeper_turn_pulse_seed"
        path
        exn_class;
      Error exn_class
    | Ok (lines, completion) ->
      let window_start = now -. window_seconds in
      let reversed_lines = List.rev lines in
      let rec collect acc truncated_by_bytes = function
        | [] -> List.rev acc, truncated_by_bytes
        | line :: rest ->
          (match sample_of_decision_line line with
           | Some s when s.at >= window_start ->
             collect (s :: acc) truncated_by_bytes rest
           | Some _ ->
             (* Reached an entry older than the window *)
             List.rev acc, false
           | None -> collect acc truncated_by_bytes rest)
      in
      let truncated_input =
        match completion with
        | Keeper_memory.Partial_last_line -> true
        | Keeper_memory.Complete -> false
      in
      Ok (collect [] truncated_input reversed_lines))
;;

let seed_from_decision_log ?(now = Time_compat.now ()) ~config ~keeper_name () =
  let base_path = config.Workspace.base_path in
  let primary_path = Keeper_types_support.keeper_decision_log_path config keeper_name in
  let rotated_path = primary_path ^ ".1" in
  let window_seconds = 12.0 *. 3600.0 in
  let primary = read_tail_window_samples ~now ~window_seconds primary_path in
  let rotated = read_tail_window_samples ~now ~window_seconds rotated_path in
  match primary, rotated with
  | Ok (primary_samples, primary_trunc), Ok (rotated_samples, rotated_trunc) ->
    (* [read_tail_window_samples] returns samples newest-to-oldest within each
       log file. Since primary contains turns newer than rotated (.1), prepending
       primary to rotated yields global newest-to-oldest order. *)
    let combined_samples = primary_samples @ rotated_samples in
    let file_truncated = primary_trunc || rotated_trunc in
    let is_truncated =
      file_truncated || List.length combined_samples > max_samples_per_keeper
    in
    let bounded =
      if List.length combined_samples > max_samples_per_keeper
      then take max_samples_per_keeper combined_samples
      else combined_samples
    in
    seed ~base_path ~keeper_name ~samples:bounded ~truncated:is_truncated ()
  | Error _, Ok _ | Ok _, Error _ | Error _, Error _ ->
    (* Either log is unreadable, so the window is not known. The pulse stays
       unseeded and [get] keeps returning [None]. *)
    ()
;;

let seed_all_from_decision_logs ?(now = Time_compat.now ()) ~config () =
  match Keeper_meta_store.keeper_names_result config with
  | Ok names ->
    List.iter (fun keeper_name -> seed_from_decision_log ~now ~config ~keeper_name ()) names
  | Error _ -> ()
;;

let reset_for_tests () = Atomic.set state KeyMap.empty
