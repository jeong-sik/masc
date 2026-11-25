open Result.Syntax

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
  ; facts_by_hour : facts_at_hour list
  ; read_error : string option
  }

let empty = { last_success_at = None; facts_by_hour = []; read_error = None }

let kept : (string, t) Hashtbl.t = Hashtbl.create 16
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

(* Keep at most [trend_hours] points: the hours that end with the newest one. *)
let keep_newest_hours points =
  match List.rev points with
  | [] -> []
  | newest :: _ ->
    let first = hour newest.recorded_at - trend_hours + 1 in
    List.filter (fun point -> hour point.recorded_at >= first) points
;;

let is_librarian_cause = function
  | Librarian_log.Read _
  | Librarian_log.Make_room _
  | Librarian_log.Molt_and_synthesize _ -> true
  | Librarian_log.Direct _
  | Librarian_log.Adopt _
  | Librarian_log.Skip _
  | Librarian_log.Checkpoint _ -> false
;;

let read ~keepers_dir ~keeper_id =
  let log_path = Librarian_log_store.path_for_keepers_dir ~keepers_dir ~keeper_id in
  let previous () = Stdlib.Mutex.protect kept_mu (fun () -> Hashtbl.find_opt kept log_path) in
  let store value = Stdlib.Mutex.protect kept_mu (fun () -> Hashtbl.replace kept log_path value) in
  let clear () = Stdlib.Mutex.protect kept_mu (fun () -> Hashtbl.remove kept log_path) in
  Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
    match Unix.lstat log_path with
    | exception Unix.Unix_error (Unix.ENOENT, _, _) ->
      clear ();
      empty
    | exception Unix.Unix_error (err, _, _) ->
      let prior = Option.value ~default:empty (previous ()) in
      { prior with read_error = Some (Printf.sprintf "%s: %s" log_path (Unix.error_message err)) }
    | _ ->
      (match
         Librarian_log_store.fold log_path ~init:([], None)
           ~f:(fun (commits_rev, last_success_at) ({ line; _ } : Librarian_log_store.scanned) ->
             match line with
             | Ok (Librarian_log.Committed commit) ->
               let effects = Librarian_effects.ordinary_projection commit.effects in
               let delta =
                 List.length effects.added - List.length effects.removed
               in
               let last_success_at =
                 if is_librarian_cause commit.cause && Float.is_finite commit.at
                 then Some commit.at
                 else last_success_at
               in
               (commit.at, delta) :: commits_rev, last_success_at
             | Ok (Librarian_log.Started _) | Error _ -> commits_rev, last_success_at)
       with
       | Error err ->
         let prior = Option.value ~default:empty (previous ()) in
         { prior with read_error = Some (Private_jsonl_scan.error_to_string err) }
       | Ok ([], last_success_at) ->
         let outcome = { empty with last_success_at } in
         store outcome;
         outcome
       | Ok (commits_rev, last_success_at) ->
         let points_in_order =
           match Keeper_memory_os_current.read_for_keepers_dir ~keepers_dir ~keeper_id with
           | Ok (Some snap) ->
             let rec walk_back running acc = function
               | [] -> acc
               | (at, delta) :: older ->
                 let count_after = max 0 running in
                 walk_back (max 0 (running - delta)) ((at, count_after) :: acc) older
             in
             walk_back (List.length snap.facts) [] commits_rev
           | Ok None | Error _ ->
             let rec walk_forward running acc = function
               | [] -> List.rev acc
               | (at, delta) :: newer ->
                 let count_after = max 0 (running + delta) in
                 walk_forward count_after ((at, count_after) :: acc) newer
             in
             walk_forward 0 [] (List.rev commits_rev)
         in
         let facts_by_hour =
           List.fold_left
             (fun points (recorded_at, facts) ->
                if Float.is_finite recorded_at
                then keep_newest_hours (place { recorded_at; facts } points)
                else points)
             []
             points_in_order
         in
         let outcome = { last_success_at; facts_by_hour; read_error = None } in
         store outcome;
         outcome))
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
       (fun point ->
          `Assoc [ "recorded_at", `Float point.recorded_at; "facts", `Int point.facts ])
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
        Error
          (Printf.sprintf
             "recorded_at must be a finite number, got %s"
             (Yojson.Safe.to_string other))
    in
    (match facts with
     | `Int facts when facts >= 0 -> Ok { recorded_at; facts }
     | other ->
       Error
         (Printf.sprintf
            "facts must be a non-negative int, got %s"
            (Yojson.Safe.to_string other)))
  | other ->
    Error
      (Printf.sprintf
         "a point must hold exactly recorded_at and facts, got %s"
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
  | `List _ ->
    Error (Printf.sprintf "facts_by_hour holds more than %d points" trend_hours)
  | other ->
    Error
      (Printf.sprintf
         "facts_by_hour must be an array, got %s"
         (Yojson.Safe.to_string other))
;;
