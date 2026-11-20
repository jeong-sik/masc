open Result.Syntax

module Turn_store = Keeper_turn_log_store
module Commit_store = Librarian_log_store
module Scan = Private_jsonl_scan

type error =
  | Listing_failed of
      { path : string
      ; detail : string
      }
  | Turn_log_unreadable of
      { keeper : string
      ; detail : string
      }
  | Line_undecodable of
      { keeper : string
      ; offset : int
      }

let error_to_string = function
  | Listing_failed { path; detail } -> Printf.sprintf "%s could not be listed: %s" path detail
  | Turn_log_unreadable { keeper; detail } ->
    Printf.sprintf "the turn log of %s could not be read: %s" keeper detail
  | Line_undecodable { keeper; offset } ->
    Printf.sprintf "the turn log of %s has a line at byte %d that does not decode" keeper offset
;;

type root =
  { session : string
  ; bundle : Agent_core.Checkpoint_objects.digest
  }

(* The entries of [turns_dir] that are directories, links to one included: a
   turn log left out here would lose its roots, so links are followed. An
   absent [turns_dir], or an entry whose link leads nowhere, has none. *)
let keeper_dirs turns_dir =
  let kind path =
    match Unix.stat path with
    | { Unix.st_kind; _ } -> Ok (Some st_kind)
    | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok None
    | exception Unix.Unix_error (code, _, _) ->
      Error (Listing_failed { path; detail = Unix.error_message code })
  in
  let* dir = kind turns_dir in
  match dir with
  | None | Some (Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK) ->
    Ok []
  | Some Unix.S_DIR ->
    (match Sys.readdir turns_dir with
     | exception Sys_error detail -> Error (Listing_failed { path = turns_dir; detail })
     | names ->
       Array.sort String.compare names;
       List.fold_left
         (fun acc name ->
            let* found = acc in
            let* entry = kind (Filename.concat turns_dir name) in
            match entry with
            | Some Unix.S_DIR -> Ok (name :: found)
            | None
            | Some (Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK) ->
              Ok found)
         (Ok [])
         (Array.to_list names)
       |> Result.map List.rev)
;;

let slice_roots ~session (slices : Keeper_turn_log.slice list) =
  List.map (fun (slice : Keeper_turn_log.slice) -> { session; bundle = slice.Keeper_turn_log.bundle }) slices
;;

let step ~keeper roots (scanned : Turn_store.scanned) =
  match scanned.line with
  | Error (_ : Turn_store.undecodable) ->
    Scan.Stop (Line_undecodable { keeper; offset = scanned.at })
  | Ok (Keeper_turn_log.Closed { after; unattributed; own; turn = _; at = _; outcome = _ }) ->
    Scan.Continue (slice_roots ~session:after.Keeper_turn_log.trace (unattributed @ own) @ roots)
  | Ok (Keeper_turn_log.Reset { before; closed_before; at = _; cause = _; after = _ }) ->
    Scan.Continue (slice_roots ~session:before.Keeper_turn_log.trace closed_before @ roots)
  | Ok (Keeper_turn_log.Log_started _ | Keeper_turn_log.Opened _) -> Scan.Continue roots
;;

type counted =
  | Counted of root list
  | Not_a_line_start

let lines_from ~keeper ~turns_path ~from =
  match Turn_store.fold_from turns_path ~from ~init:[] ~f:(step ~keeper) with
  | Ok (Scan.Reached_end roots) -> Ok (Counted roots)
  | Ok (Scan.Stopped error) -> Error error
  | Error (Scan.Not_a_row_start { from = (_ : int); length = (_ : int) }) -> Ok Not_a_line_start
  | Error (Scan.Scan_failed error) ->
    Error (Turn_log_unreadable { keeper; detail = Scan.error_to_string error })
;;

(* Where the writer reads next in this turn log, when its commit log tail
   names this log. *)
let first_unread ~memory_dir ~keeper (start : Turn_store.start) =
  let in_this_log turn_log turn_log_offset =
    if Keeper_turn_log.Log_id.equal turn_log start.id then Some turn_log_offset else None
  in
  match
    Commit_store.read_tail (Commit_store.path_for_keepers_dir ~keepers_dir:memory_dir ~keeper_id:keeper)
  with
  | Ok (Commit_store.Written { last = Librarian_log.Started { turn_log; turn_log_offset; _ }; _ }) ->
    in_this_log turn_log turn_log_offset
  | Ok
      (Commit_store.Written
         { last = Librarian_log.Committed { Librarian_log.turn_log; turn_log_offset; _ }; _ }) ->
    in_this_log turn_log turn_log_offset
  | Ok Commit_store.Nothing_written | Error (_ : Commit_store.read_error) -> None
;;

let keeper_roots ~turns_dir ~memory_dir keeper =
  let turns_path = Turn_store.path_for_keepers_dir ~keepers_dir:turns_dir ~keeper_id:keeper in
  match Turn_store.read_start turns_path with
  | Error error ->
    Error (Turn_log_unreadable { keeper; detail = Turn_store.read_error_to_string error })
  | Ok None -> Ok []
  | Ok (Some start) ->
    let every_line () =
      match lines_from ~keeper ~turns_path ~from:0 with
      | Ok (Counted roots) -> Ok roots
      | Ok Not_a_line_start ->
        Error (Turn_log_unreadable { keeper; detail = "no line starts at its first byte" })
      | Error error -> Error error
    in
    (match first_unread ~memory_dir ~keeper start with
     | None -> every_line ()
     | Some from ->
       (match lines_from ~keeper ~turns_path ~from with
        | Ok (Counted roots) -> Ok roots
        | Ok Not_a_line_start -> every_line ()
        | Error error -> Error error))
;;

let read ~turns_dir ~memory_dir =
  let* keepers = keeper_dirs turns_dir in
  List.fold_left
    (fun acc keeper ->
       let* found = acc in
       let* own = keeper_roots ~turns_dir ~memory_dir keeper in
       Ok (own @ found))
    (Ok [])
    keepers
;;
