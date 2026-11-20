module String_map = Map.Make (String)
module String_set = Set.Make (String)
module Store = Keeper_turn_log_store

type error =
  | Listing_failed of
      { path : string
      ; detail : string
      }
  | Turn_log_unreadable of
      { path : string
      ; detail : string
      }
  | Line_undecodable of
      { path : string
      ; offset : int
      }

let error_to_string = function
  | Listing_failed { path; detail } -> Printf.sprintf "%s could not be listed: %s" path detail
  | Turn_log_unreadable { path; detail } -> Printf.sprintf "turn log %s could not be read: %s" path detail
  | Line_undecodable { path; offset } ->
    Printf.sprintf "turn log %s holds a line at offset %d that does not decode" path offset
;;

type found = String_set.t String_map.t

let add_slices found ~(through : Keeper_turn_log.mark) slices =
  List.fold_left
    (fun found ({ bundle; skip = (_ : int); take = (_ : int) } : Keeper_turn_log.slice) ->
       let held = Option.value ~default:String_set.empty (String_map.find_opt through.trace found) in
       String_map.add through.trace (String_set.add (bundle :> string) held) found)
    found
    slices
;;

let on_line ~path found (scanned : Store.scanned) : (found, error) Private_jsonl_scan.step =
  match scanned.line with
  | Error (Not_json | Malformed (_ : Keeper_memory_os_types.wire_error)) ->
    Stop (Line_undecodable { path; offset = scanned.at })
  | Ok (Closed { after; unattributed; own; turn = (_ : int); at = (_ : float); outcome = (_ : Keeper_turn_log.outcome) })
    -> Continue (add_slices (add_slices found ~through:after unattributed) ~through:after own)
  | Ok (Reset { before; closed_before; at = (_ : float); cause = (_ : Keeper_turn_log.reset_cause); after = (_ : Keeper_turn_log.mark) })
    -> Continue (add_slices found ~through:before closed_before)
  | Ok (Log_started _ | Opened _) -> Continue found
;;

(* An offset that starts no line of the file is not where reading stands in
   it, so the file is read from its first line. *)
let rec scan ~path ~from found =
  match Store.fold_from path ~from ~init:found ~f:(on_line ~path) with
  | Ok (Reached_end found) -> Ok found
  | Ok (Stopped error) -> Error error
  | Error (Not_a_row_start { from = (_ : int); length = (_ : int) }) when from > 0 -> scan ~path ~from:0 found
  | Error (Not_a_row_start { from = (_ : int); length }) ->
    Error (Turn_log_unreadable { path; detail = Printf.sprintf "no line starts the file of %d bytes" length })
  | Error (Scan_failed error) ->
    Error (Turn_log_unreadable { path; detail = Private_jsonl_scan.error_to_string error })
;;

(* Where the writer's commit log says reading stands in the file whose first
   line is [start]. Any other answer is the file's first line. *)
let saved_offset ~memory_log_path (start : Store.start) =
  match Librarian_log_store.read_tail memory_log_path with
  | Ok
      (Written
         { last =
             ( Committed { turn_log; turn_log_offset; _ }
             | Started { turn_log; turn_log_offset; _ } )
         ; rows_end = (_ : int)
         ; last_at = (_ : int)
         }) ->
    if Keeper_turn_log.Log_id.equal turn_log start.id then turn_log_offset else 0
  | Ok Nothing_written
  | Error
      ( Read_failed { path = (_ : string); detail = (_ : string) }
      | Tail_undecodable _ | Moved_while_reading ) -> 0
;;

let keeper_bundles ~turns_path ~memory_log_path found =
  match Store.read_start turns_path with
  | Ok None -> Ok found
  | Ok (Some start) -> scan ~path:turns_path ~from:(saved_offset ~memory_log_path start) found
  | Error Log_start_missing -> scan ~path:turns_path ~from:0 found
  | Error (Row_undecodable { offset; reason = (_ : Store.undecodable) }) ->
    Error (Line_undecodable { path = turns_path; offset })
  | Error (Read_failed { path; detail }) -> Error (Turn_log_unreadable { path; detail })
  | Error Moved_while_reading ->
    Error (Turn_log_unreadable { path = turns_path; detail = "the file changed while it was read" })
;;

(* The entries of [turns_dir] that are directories, a link to one included:
   the Keepers' runtime directories. Other entries are a Keeper's files. *)
let keeper_ids turns_dir =
  match Sys.readdir turns_dir with
  | exception Sys_error detail ->
    if Sys.file_exists turns_dir then Error (Listing_failed { path = turns_dir; detail }) else Ok []
  | names ->
    Array.sort String.compare names;
    Array.to_list names
    |> List.fold_left
         (fun acc name ->
            Result.bind acc (fun ids ->
              let entry = Filename.concat turns_dir name in
              match Unix.stat entry with
              | { Unix.st_kind = S_DIR; _ } -> Ok (name :: ids)
              | { Unix.st_kind = S_REG | S_CHR | S_BLK | S_LNK | S_FIFO | S_SOCK; _ } -> Ok ids
              | exception Unix.Unix_error (Unix.ENOENT, (_ : string), (_ : string)) -> Ok ids
              | exception Unix.Unix_error (code, (_ : string), (_ : string)) ->
                Error (Listing_failed { path = entry; detail = Unix.error_message code })))
         (Ok [])
    |> Result.map List.rev
;;

let read ~turns_dir ~memory_dir =
  Result.bind (keeper_ids turns_dir) (fun ids ->
    List.fold_left
      (fun acc keeper_id ->
         Result.bind acc (fun found ->
           keeper_bundles
             ~turns_path:(Store.path_for_keepers_dir ~keepers_dir:turns_dir ~keeper_id)
             ~memory_log_path:(Librarian_log_store.path_for_keepers_dir ~keepers_dir:memory_dir ~keeper_id)
             found))
      (Ok String_map.empty)
      ids)
;;
