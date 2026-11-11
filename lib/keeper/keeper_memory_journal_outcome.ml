open Result.Syntax

module Current = Keeper_memory_os_current
module Current_types = Keeper_memory_os_current_types

type facts_at_hour =
  { recorded_at : float
  ; facts : int
  }

let trend_hours = 168
let seconds_per_hour = 3600.

(* The clock hour a time falls in, counted from the epoch. *)
let hour time = Float.to_int (Float.floor (time /. seconds_per_hour))

type t =
  { last_success_at : float option
  ; last_failure : Current_types.librarian_failure_kind option
  ; facts_by_hour : facts_at_hour list
  ; read_error : Dated_jsonl.read_error option
  }

let empty =
  { last_success_at = None; last_failure = None; facts_by_hour = []; read_error = None }

type kept =
  { cursor : Dated_jsonl.append_cursor
  ; outcome : t
  }

let kept : (string, kept) Hashtbl.t = Hashtbl.create 16
let kept_mu = Stdlib.Mutex.create ()

(* Points stay oldest first, one per hour. A line from a clock that stepped
   back goes to its own hour's place. *)
let rec place point = function
  | [] -> [ point ]
  | held :: later ->
    let order = Int.compare (hour point.recorded_at) (hour held.recorded_at) in
    if order < 0
    then point :: held :: later
    else if order = 0
    then point :: later
    else held :: place point later
;;

(* A journal of any age keeps at most [trend_hours] points: the hours that end
   with its newest one. *)
let keep_newest_hours points =
  match List.rev points with
  | [] -> []
  | newest :: _ ->
    let first = hour newest.recorded_at - trend_hours + 1 in
    List.filter (fun point -> hour point.recorded_at >= first) points
;;

(* A line whose time is not a finite number has no hour to stand in. *)
let after_commit ~recorded_at (change : Current_types.change) points =
  if Float.is_finite recorded_at
  then
    keep_newest_hours
      (place { recorded_at; facts = change.retained + List.length change.added } points)
  else points
;;

let step outcome = function
  | Dated_jsonl.Malformed_json _ -> outcome
  | Dated_jsonl.Parsed json ->
    (match Keeper_memory_os_journal_codec.journal_entry_of_json json with
     | Ok (Current_types.Journal_committed { recorded_at; source; change; _ }) ->
       let facts_by_hour = after_commit ~recorded_at change outcome.facts_by_hour in
       (match source.kind with
        | Current_types.Librarian ->
          { outcome with last_success_at = Some recorded_at; last_failure = None; facts_by_hour }
        | Current_types.(Explicit_write | Explicit_retract) -> { outcome with facts_by_hour })
     | Ok (Current_types.Journal_failed { kind; _ }) -> { outcome with last_failure = Some kind }
     | Ok (Current_types.Journal_quarantined _)
     | Error _ -> outcome)
;;

let fold path ~cursor ~init =
  Dated_jsonl.fold_file_appended_complete_entries_result path ~cursor ~init ~f:step
;;

let read ~keepers_dir ~keeper_id =
  let path = Current.journal_path_for_keepers_dir ~keepers_dir ~keeper_id in
  let previous = Stdlib.Mutex.protect kept_mu (fun () -> Hashtbl.find_opt kept path) in
  let store value = Stdlib.Mutex.protect kept_mu (fun () -> Hashtbl.replace kept path value) in
  let unavailable error =
    let outcome = match previous with Some { outcome; _ } -> outcome | None -> empty in
    { outcome with read_error = Some error }
  in
  let from_start () =
    match fold path ~cursor:None ~init:empty with
    | Ok (Dated_jsonl.Appended (outcome, cursor)) ->
      store { cursor; outcome };
      Ok outcome
    (* Only a passed cursor can be invalidated. *)
    | Ok Dated_jsonl.Cursor_invalidated ->
      Error
        (Dated_jsonl.Io_error
           { operation = Dated_jsonl.Read_file
           ; path
           ; detail = "journal cursor was invalidated on its initial read"
           })
    | Error error -> Error error
  in
  let present =
    match Unix.lstat path with
    | _ -> Ok true
    | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok false
    | exception Unix.Unix_error (error, _, _) ->
      Error
        (Dated_jsonl.Io_error
           { operation = Dated_jsonl.Inspect; path; detail = Unix.error_message error })
  in
  match present with
  | Error error -> unavailable error
  | Ok false ->
    Stdlib.Mutex.protect kept_mu (fun () -> Hashtbl.remove kept path);
    empty
  | Ok true ->
    let read =
      match previous with
      | None -> from_start ()
      | Some { cursor; outcome } ->
        (match fold path ~cursor:(Some cursor) ~init:outcome with
         | Ok (Dated_jsonl.Appended (outcome, cursor)) ->
           store { cursor; outcome };
           Ok outcome
         | Ok Dated_jsonl.Cursor_invalidated -> from_start ()
         | Error error -> Error error)
    in
    (match read with
     | Ok outcome -> outcome
     | Error error -> unavailable error)
;;

let within ~now points =
  let last = hour now in
  let first = last - trend_hours + 1 in
  List.filter
    (fun point ->
       let at = hour point.recorded_at in
       at >= first && at <= last)
    points
;;

let facts_by_hour_to_json points =
  `List
    (List.map
       (fun point -> `Assoc [ "recorded_at", `Float point.recorded_at; "facts", `Int point.facts ])
       points)
;;

let point_of_json = function
  | `Assoc [ ("recorded_at", recorded_at); ("facts", facts) ]
  | `Assoc [ ("facts", facts); ("recorded_at", recorded_at) ] ->
    let* recorded_at =
      match recorded_at with
      | `Float time when Float.is_finite time -> Ok time
      | `Int time -> Ok (Float.of_int time)
      | other ->
        Error (Printf.sprintf "recorded_at must be a finite number, got %s" (Yojson.Safe.to_string other))
    in
    (match facts with
     | `Int facts when facts >= 0 -> Ok { recorded_at; facts }
     | other ->
       Error (Printf.sprintf "facts must be a non-negative int, got %s" (Yojson.Safe.to_string other)))
  | other ->
    Error
      (Printf.sprintf "a point must hold exactly recorded_at and facts, got %s"
         (Yojson.Safe.to_string other))
;;

let facts_by_hour_of_json = function
  | `List items when List.compare_length_with items trend_hours <= 0 ->
    let rec decode index points = function
      | [] -> Ok (List.rev points)
      | item :: rest ->
        (match point_of_json item with
         | Ok point -> decode (index + 1) (point :: points) rest
         | Error detail -> Error (Printf.sprintf "facts_by_hour[%d]: %s" index detail))
    in
    let* points = decode 0 [] items in
    let rec ascending = function
      | earlier :: (later :: _ as rest) ->
        hour earlier.recorded_at < hour later.recorded_at && ascending rest
      | [ _ ] | [] -> true
    in
    if ascending points
    then Ok points
    else Error "facts_by_hour points must stand in later clock hours, one per hour"
  | `List _ -> Error (Printf.sprintf "facts_by_hour holds more than %d points" trend_hours)
  | other ->
    Error (Printf.sprintf "facts_by_hour must be an array, got %s" (Yojson.Safe.to_string other))
;;
