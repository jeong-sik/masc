(* The Librarian's read position (RFC librarian-lifecycle §4.6). See the
   interface for the contract. *)

module W = Keeper_memory_os_types

open Result.Syntax
let path_for_keepers_dir ~keepers_dir ~keeper_id =
  Filename.concat (Filename.concat keepers_dir keeper_id) "librarian-progress.json"
;;

type position =
  { trace_id : string
  ; end_atom : int
  ; last_atom_digest : string
  }

type t =
  { position : position
  ; boundary_lines_seen : int
  }

let field_trace_id = "trace_id"
let field_end_atom = "end_atom"
let field_last_atom_digest = "last_atom_digest"
let field_boundary_lines_seen = "boundary_lines_seen"

let fields =
  [ field_trace_id; field_end_atom; field_last_atom_digest; field_boundary_lines_seen ]
;;

let non_blank s = not (String.equal (String.trim s) "")

(* Shared by the decoder and [write], so a file this module wrote is a file
   this module reads back. *)
let validate (progress : t) =
  let { trace_id; end_atom; last_atom_digest } = progress.position in
  let* () =
    if non_blank trace_id
    then Ok ()
    else W.wire_fail [ W.Wire_field field_trace_id ] W.Blank_string
  in
  let* () =
    if end_atom >= 1
    then Ok ()
    else W.wire_fail [ W.Wire_field field_end_atom ] W.Not_positive
  in
  let* () =
    if non_blank last_atom_digest
    then Ok ()
    else W.wire_fail [ W.Wire_field field_last_atom_digest ] W.Blank_string
  in
  if progress.boundary_lines_seen >= 0
  then Ok progress
  else W.wire_fail [ W.Wire_field field_boundary_lines_seen ] W.Negative
;;

let to_json (progress : t) : Yojson.Safe.t =
  `Assoc
    [ field_trace_id, `String progress.position.trace_id
    ; field_end_atom, `Int progress.position.end_atom
    ; field_last_atom_digest, `String progress.position.last_atom_digest
    ; field_boundary_lines_seen, `Int progress.boundary_lines_seen
    ]
;;

let of_json (json : Yojson.Safe.t) =
  match json with
  | `Assoc assoc ->
    let* () = W.exact_field_names_result fields assoc in
    let* trace_id = W.wire_string_field field_trace_id assoc in
    let* end_atom = W.wire_int_field field_end_atom assoc in
    let* last_atom_digest = W.wire_string_field field_last_atom_digest assoc in
    let* boundary_lines_seen = W.wire_int_field field_boundary_lines_seen assoc in
    validate
      { position = { trace_id; end_atom; last_atom_digest }; boundary_lines_seen }
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
    W.wire_here W.Expected_object
;;

type read_error = Keeper_librarian_progress_file.read_error
type write_error = Keeper_librarian_progress_file.write_error

let subject = "librarian progress"
let read_error_to_string = Keeper_librarian_progress_file.read_error_to_string ~subject
let write_error_to_string = Keeper_librarian_progress_file.write_error_to_string ~subject

let read ~keepers_dir ~keeper_id =
  Keeper_librarian_progress_file.read
    ~path:(path_for_keepers_dir ~keepers_dir ~keeper_id)
    ~of_json
;;

let commit_observer = ref (fun ~keepers_dir:_ ~keeper_id:_ -> ())
let install_commit_observer observer =
  let previous = !commit_observer in
  commit_observer := observer;
  fun () -> commit_observer := previous

let write ~keepers_dir ~keeper_id progress =
  match
    Keeper_librarian_progress_file.write
      ~path:(path_for_keepers_dir ~keepers_dir ~keeper_id)
      ~validate
      ~to_json
      progress
  with
  | Ok () ->
    !commit_observer ~keepers_dir ~keeper_id;
    Keeper_memory_health_input.written ~keepers_dir ~keeper_id;
    Ok ()
  | Error _ as error -> error
;;
