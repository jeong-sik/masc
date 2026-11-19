let decision_window_bytes = 40_000
let decision_window_lines = 20

(* A row of at most this many bytes, newline counted, is the newest row a
   read finds after it was appended. The reader takes the file's last
   [decision_window_bytes] bytes and, when they do not start at the file's
   start, drops their first piece, up to the first newline. The row is the
   file's last line. When it is not also the first, the byte before it is
   the newline that ends the line before. With the row one byte shorter than
   the window, that newline is the window's first byte: the dropped piece
   ends there and is not the row. A row as long as the window then starts at
   the window's first byte, and the reader drops it as the piece the window
   may have cut. A row that is the file's only line is found whatever its
   length; the bound does not look at what the file held. *)
let decision_row_bytes_followed = decision_window_bytes - 1

type decision_line =
  | Decision_row of Yojson.Safe.t
  | Not_json of string
  | Not_an_object

let decision_line line =
  match Yojson.Safe.from_string line with
  | `Assoc _ as json -> Decision_row json
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> Not_an_object
  | exception Yojson.Json_error detail -> Not_json detail

(* One cell for each decision record, under the name the file system gives
   the file. A record's writers and readers each make their path from the
   workspace and the Keeper's name, and the cell is asked for every time: no
   one holds it. *)
let cells : Yojson.Safe.t option Fact_cell.t File_system_named.t =
  File_system_named.create Fact_cell.make

let absolute path =
  if Filename.is_relative path
  then Filename.concat (Config_dir_resolver.current_working_dir ()) path
  else path

let newest_decision ~path ~read =
  if Fact_cell.kept_in_this_process ()
  then (
    let resolved = File_system_named.resolve cells (absolute path) in
    Fact_cell.fill resolved.File_system_named.entry ~read)
  else (
    match read () with
    | Ok row -> Fact_cell.Read_not_kept row
    | Error error -> Fact_cell.Read_failed error)

type appended =
  | To_the_file_there
  | After_a_rotation

(* The value after [row] was appended, whatever it was before: the row is the
   record's last line. [None] when the row is not one a read is sure to
   answer with. *)
let decision_after row =
  if String.length row + 1 > decision_row_bytes_followed
  then None
  else (
    match decision_line row with
    | Decision_row json -> Some (Some json)
    | Not_json _ | Not_an_object -> None)

let appending_decision ~path ~row append =
  let spelling = absolute path in
  let resolved = File_system_named.resolve cells spelling in
  let cell = resolved.File_system_named.entry in
  let seen = Fact_cell.see cell in
  (* The file may by now be another cell's: it did not exist and another
     spelling made it first, or it was renamed away and made again. The row
     then went by that cell unseen. *)
  let cell_the_file_has_now () = File_system_named.another_entry_now cells resolved spelling in
  match append () with
  | exception exn ->
    let backtrace = Printexc.get_raw_backtrace () in
    (* Whether the file was rotated before the failure is not known. *)
    File_system_named.removed cells;
    Fact_cell.forget cell;
    Option.iter Fact_cell.forget (cell_the_file_has_now ());
    Printexc.raise_with_backtrace exn backtrace
  | appended ->
    (match appended with
     | After_a_rotation -> File_system_named.removed cells
     | To_the_file_there -> ());
    Fact_cell.settle cell seen ~step:(fun _ -> decision_after row);
    (match cell_the_file_has_now () with
     | None -> ()
     | Some now ->
       Fact_cell.forget now;
       Fact_cell.forget cell)

let decision_records_removed () =
  File_system_named.removed cells;
  List.iter Fact_cell.forget (File_system_named.entries cells)
