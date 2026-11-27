type io = { run : 'a. (unit -> 'a) -> 'a }
let inline = { run = (fun f -> f ()) }
type t = { fd : Unix.file_descr; mutable active : bool; io : io; path : string }

external open_root : string -> Unix.file_descr = "caml_masc_owned_directory_root"
external open_child : Unix.file_descr -> string -> Unix.file_descr
  = "caml_masc_owned_directory_open"
external directory_names : Unix.file_descr -> string list
  = "caml_masc_owned_directory_names"
external remove_regular : Unix.file_descr -> string -> float option -> bool
  = "caml_masc_retention_remove_regular"
external unlink_entry_at : Unix.file_descr -> string -> bool
  = "caml_masc_retention_unlink_entry"
external remove_empty_checked : Unix.file_descr -> string -> bool
  = "caml_masc_retention_remove_empty_checked"
external remove_empty : Unix.file_descr -> string -> unit
  = "caml_masc_retention_remove_empty"

let descriptor directory =
  if not directory.active then invalid_arg "expired retention directory";
  directory.fd

let leaf name =
  if name = "" || name = "." || name = ".."
     || String.contains name '/' || String.contains name '\000'
  then invalid_arg "retention directory requires one child name"

let scope io path fd f =
  let directory = { fd; active = true; io; path } in
  let close () = directory.active <- false; Unix.close fd in
  match f directory with
  | result -> close (); result
  | exception exn ->
    let bt = Printexc.get_raw_backtrace () in
    (* A release error must not erase callback cancellation. A normal-return
       close error stays an original I/O exception for the owning observer. *)
    (try close () with
     | (Sys_error _ | Unix.Unix_error _) as cleanup ->
       (try Printf.eprintf
              "[retention] close(%S) after %s failed: %s\n%!"
              path (Printexc.to_string exn) (Printexc.to_string cleanup)
        with Sys_error _ | Unix.Unix_error _ -> ()));
    Printexc.raise_with_backtrace exn bt

let with_child directory name f =
  leaf name;
  match directory.io.run (fun () -> open_child (descriptor directory) name) with
  | fd -> Some (scope directory.io (Filename.concat directory.path name) fd f)
  | exception Unix.Unix_error ((Unix.ENOENT | Unix.ENOTDIR | Unix.ELOOP), _, _) -> None

let with_root ?(io = inline) path f =
  if Filename.is_relative path || String.contains path '\000'
  then invalid_arg "retention root requires an absolute physical path";
  let components = String.split_on_char '/' path |> List.filter (fun s -> s <> "") in
  List.iter leaf components;
  let rec walk directory = function
    | [] -> Some (f directory)
    | name :: rest ->
      (match directory.io.run (fun () -> open_child (descriptor directory) name) with
       | fd -> scope directory.io (Filename.concat directory.path name) fd
           (fun child -> walk child rest)
       | exception Unix.Unix_error (Unix.ENOENT, _, _) -> None)
  in
  scope io "/" (io.run (fun () -> open_root "/"))
    (fun directory -> walk directory components)

let names directory =
  directory.io.run (fun () -> directory_names (descriptor directory))
  |> List.filter (fun name -> name <> "." && name <> "..")

let fold_children directory ~init ~f =
  List.fold_left (fun acc name ->
    match with_child directory name (f acc name) with
    | None -> acc
    | Some result -> result) init (names directory)

let rec descend directory components f =
  match components with
  | [] -> f directory
  | name :: rest ->
    (match with_child directory name (fun child -> descend child rest f) with
     | None -> 0
     | Some result -> result)

(* Cap each [io.run] batch so large flat directories (tens of thousands of
   files) amortize cross-domain systhread dispatch without monopolizing a
   worker thread or delaying cancellation checks between chunks. *)
let batch_size = 256

let rec take_chunk n acc xs =
  if n <= 0
  then List.rev acc, xs
  else
    match xs with
    | [] -> List.rev acc, []
    | x :: rest -> take_chunk (n - 1) (x :: acc) rest

let log_remove_regular_error directory operation name error =
  (* A rejected leaf stays for the next pass. Its failure must not prevent
     unrelated stores from applying their own retention policy. This path
     is a diagnostic label only; authority remains the held descriptor. *)
  let diagnostic_path =
    if name = "" then directory.path else Filename.concat directory.path name
  in
  try
    Stdlib.Printf.eprintf "[retention] %s(%S): %s; keeping entry for next pass\n%!"
      operation diagnostic_path (Unix.error_message error)
  with Sys_error _ | Unix.Unix_error _ -> ()

let remove_regular_file ?older_than directory name =
  leaf name;
  match directory.io.run (fun () -> remove_regular (descriptor directory) name older_than) with
  | removed -> removed
  | exception Unix.Unix_error (error, operation, _) ->
    log_remove_regular_error directory operation name error;
    false

let remove_regular_files ?older_than directory names =
  List.iter leaf names;
  ignore (descriptor directory : Unix.file_descr);
  let rec loop total = function
    | [] -> total
    | remaining ->
      let chunk, rest = take_chunk batch_size [] remaining in
      let removed, warnings =
        match
          directory.io.run (fun () ->
            let fd = descriptor directory in
            let rec run_chunk count warnings = function
              | [] -> count, List.rev warnings
              | name :: tail ->
                (match remove_regular fd name older_than with
                 | true -> run_chunk (count + 1) warnings tail
                 | false -> run_chunk count warnings tail
                 | exception Unix.Unix_error (error, operation, _) ->
                   run_chunk count ((operation, name, error) :: warnings) tail)
            in
            run_chunk 0 [] chunk)
        with
        | result -> result
        | exception Unix.Unix_error (error, operation, param) ->
          0, [ (operation, param, error) ]
      in
      List.iter
        (fun (operation, name, error) ->
           log_remove_regular_error directory operation name error)
        warnings;
      loop (total + removed) rest
  in
  loop 0 names

let unlink_entry directory name =
  leaf name;
  directory.io.run (fun () -> unlink_entry_at (descriptor directory) name)

let remove_empty_child_checked directory name =
  leaf name;
  directory.io.run (fun () -> remove_empty_checked (descriptor directory) name)

let remove_empty_child directory name =
  leaf name;
  directory.io.run (fun () -> remove_empty (descriptor directory) name)

let remove_empty_children directory names =
  List.iter leaf names;
  ignore (descriptor directory : Unix.file_descr);
  let rec loop = function
    | [] -> ()
    | remaining ->
      let chunk, rest = take_chunk batch_size [] remaining in
      directory.io.run (fun () ->
        let fd = descriptor directory in
        List.iter (remove_empty fd) chunk);
      loop rest
  in
  loop names
