type day =
  { date : string
  ; starts_at : float
  }

let seconds_per_day = 86_400.0

(* Unix time has no leap seconds, so a UTC day starts on a multiple of
   [seconds_per_day]; [Float.rem] is exact, and so is the subtraction. *)
let day_of ts =
  let starts_at = ts -. Float.rem ts seconds_per_day in
  { date = Log.format_utc_date_of starts_at; starts_at }
;;

let days_between ~since ~until =
  if since > until
  then []
  else (
    let last = day_of until in
    let rec from (day : day) acc =
      if day.starts_at > last.starts_at
      then List.rev acc
      else from (day_of (day.starts_at +. seconds_per_day)) (day :: acc)
    in
    from (day_of since) [])
;;

type 'a file =
  { path : string
  ; day : day
  ; cursor : Dated_jsonl.append_cursor
  ; value : 'a
  }

(* Oldest day first; a day's files in the order the store lists them. *)
type 'a t = 'a file list

let empty = []

(* [Cursor_invalidated] answers only a cursor that was passed, so the read
   from the start below cannot be invalidated again. *)
let read_file ~init ~f ~(previous : 'a file option) path =
  let read cursor value =
    Dated_jsonl.fold_file_appended_entries_result path ~cursor ~init:value ~f
  in
  let from_start () =
    match read None init with
    | Error _ as error -> error
    | Ok (Dated_jsonl.Appended (value, cursor)) -> Ok (cursor, value)
    | Ok Dated_jsonl.Cursor_invalidated ->
      Error
        (Dated_jsonl.Io_error
           { operation = Dated_jsonl.Read_file
           ; path
           ; detail = "a read from the start was refused as a moved cursor"
           })
  in
  match previous with
  | None -> from_start ()
  | Some file ->
    (match read (Some file.cursor) file.value with
     | Error _ as error -> error
     | Ok (Dated_jsonl.Appended (value, cursor)) -> Ok (cursor, value)
     | Ok Dated_jsonl.Cursor_invalidated -> from_start ())
;;

let refresh store ~days ~init ~f kept =
  let previous path = List.find_opt (fun (file : _ file) -> String.equal file.path path) kept in
  let rec over_files (day : day) acc = function
    | [] -> Ok acc
    | path :: rest ->
      (match read_file ~init ~f ~previous:(previous path) path with
       | Error _ as error -> error
       | Ok (cursor, value) -> over_files day ({ path; day; cursor; value } :: acc) rest)
  in
  let rec over_days acc = function
    | [] -> Ok (List.rev acc)
    | (day : day) :: rest ->
      (match Dated_jsonl.range_day_file_paths_result store ~since:day.date ~until:day.date with
       | Error _ as error -> error
       | Ok paths ->
         (match over_files day acc paths with
          | Error _ as error -> error
          | Ok acc -> over_days acc rest))
  in
  over_days [] days
;;

let fold kept ~init ~f =
  List.fold_left (fun acc (file : _ file) -> f acc file.day file.value) init kept
;;
