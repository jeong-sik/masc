(* The Librarian's position among official-client turns (RFC
   librarian-lifecycle §10-3). See the interface for the contract. *)

module W = Keeper_memory_os_types

open Result.Syntax

let path_for_keepers_dir ~keepers_dir ~keeper_id =
  Filename.concat (Filename.concat keepers_dir keeper_id) "librarian-official-progress.json"
;;

type t = { boundary_line : int }

let field_boundary_line = "boundary_line"
let fields = [ field_boundary_line ]

(* Shared by the decoder and [write], so a file this module wrote is a file
   this module reads back. *)
let validate (progress : t) =
  if progress.boundary_line >= 1
  then Ok progress
  else W.wire_fail [ W.Wire_field field_boundary_line ] W.Not_positive
;;

let to_json (progress : t) : Yojson.Safe.t =
  `Assoc [ field_boundary_line, `Int progress.boundary_line ]
;;

let of_json (json : Yojson.Safe.t) =
  match json with
  | `Assoc assoc ->
    let* () = W.exact_field_names_result fields assoc in
    let* boundary_line = W.wire_int_field field_boundary_line assoc in
    validate { boundary_line }
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
    W.wire_here W.Expected_object
;;

type read_error = Keeper_librarian_progress_file.read_error
type write_error = Keeper_librarian_progress_file.write_error

let subject = "librarian official progress"
let read_error_to_string = Keeper_librarian_progress_file.read_error_to_string ~subject
let write_error_to_string = Keeper_librarian_progress_file.write_error_to_string ~subject

let read ~keepers_dir ~keeper_id =
  Keeper_librarian_progress_file.read
    ~path:(path_for_keepers_dir ~keepers_dir ~keeper_id)
    ~of_json
;;

let write ~keepers_dir ~keeper_id progress =
  Keeper_librarian_progress_file.write
    ~path:(path_for_keepers_dir ~keepers_dir ~keeper_id)
    ~validate
    ~to_json
    progress
;;
