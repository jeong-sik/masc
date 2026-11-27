open Fs_compat_internal
open Fs_compat_base_io

(** Load entire file contents as string, or [None] when the file is
    absent at open. Once opened, the descriptor owns the read result: a
    later unlink cannot turn a read failure into absence. *)
let load_file_opt_unix ~before_read (path : string) : string option =
  match Unix.openfile path [ Unix.O_RDONLY; Unix.O_CLOEXEC ] 0 with
  | fd ->
    let ic =
      match Unix.in_channel_of_descr fd with
      | ic -> ic
      | exception exn ->
        let bt = Printexc.get_raw_backtrace () in
        (try Unix.close fd with Unix.Unix_error _ -> ());
        let exn = match exn with
          | Unix.Unix_error (error, _, _) ->
            Sys_error (Printf.sprintf "%s: %s" path (Unix.error_message error))
          | exn -> exn
        in
        Printexc.raise_with_backtrace exn bt
    in
    Some (read_channel_and_close ~before_read path ic)
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> None
  | exception Unix.Unix_error (error, _, _) ->
    raise (Sys_error (Printf.sprintf "%s: %s" path (Unix.error_message error)))
;;

let load_file_opt_with ~before_read path =
  let read () = load_file_opt_unix ~before_read path in
  with_fs_or_fallback ~path ~fallback:read (fun _fs ->
    on_systhread ~label:(labelled "fs-compat-load-file-opt" path) read)
;;

let load_file_opt path = load_file_opt_with ~before_read:ignore path
;;

module Optional_read_for_testing = struct
  let load_file_opt = load_file_opt_with
end
;;

type regular_file_read_error =
  | Not_a_regular_file of Unix.file_kind
  | Regular_file_unreadable of string

let regular_file_read_error_to_string = function
  | Not_a_regular_file kind ->
    Printf.sprintf "not a regular file (%s)" (Owned_directory_chain.file_kind_to_string kind)
  | Regular_file_unreadable detail -> detail
;;

(* A blocking open of a FIFO waits for a writer that may never come, so the
   open is nonblocking, and the kind is read from the descriptor that was
   opened: checking the path first would let the entry change before the
   open. A link to a regular file is followed. *)
let load_regular_file_opt_unix (path : string)
  : (string option, regular_file_read_error) result
  =
  let unreadable error = Error (Regular_file_unreadable (Unix.error_message error)) in
  match Unix.openfile path [ Unix.O_RDONLY; Unix.O_NONBLOCK; Unix.O_CLOEXEC ] 0 with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok None
  | exception Unix.Unix_error (error, _, _) -> unreadable error
  | fd ->
    let close_and result =
      (try Unix.close fd with
       | Unix.Unix_error _ -> ());
      result
    in
    (match Unix.fstat fd with
     | exception Unix.Unix_error (error, _, _) -> close_and (unreadable error)
     | { Unix.st_kind = Unix.S_REG; _ } ->
       (match Unix.in_channel_of_descr fd with
        | exception Unix.Unix_error (error, _, _) -> close_and (unreadable error)
        | ic ->
          (match read_channel_and_close ~before_read:ignore path ic with
           | content -> Ok (Some content)
           | exception Sys_error detail -> Error (Regular_file_unreadable detail)))
     | { Unix.st_kind =
           (Unix.S_DIR | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK) as
           kind
       ; _
       } -> close_and (Error (Not_a_regular_file kind)))
;;

let load_regular_file_opt path =
  let read () = load_regular_file_opt_unix path in
  with_fs_or_fallback ~path ~fallback:read (fun _fs ->
    on_systhread ~label:(labelled "fs-compat-load-regular-file-opt" path) read)
;;

let file_size (path : string) : int option =
  with_fs_or_fallback
    ~path
    ~fallback:(fun () ->
      try Some (Unix.stat path).st_size with
      | Unix.Unix_error _ -> None)
    (fun _fs ->
       try Some (Fs_compat_internal.Systhread_host.run ~label:(labelled "fs-compat-file-size" path) (fun () -> (Unix.stat path).st_size)) with
       | Unix.Unix_error _ -> None)
;;

external publish_paths_raw : bool -> string -> string -> unit = "caml_masc_publish_paths"

let publish_paths exchange left right =
  if String.contains left '\000' || String.contains right '\000' then
    invalid_arg "filesystem publication paths cannot contain NUL";
  publish_paths_raw exchange left right
let exchange_paths left right = publish_paths true left right
let rename_noreplace src dst = publish_paths false src dst

external clone_file_raw : string -> string -> unit = "caml_masc_clone_file"

let clone_file src dst =
  if String.contains src '\000' || String.contains dst '\000' then
    invalid_arg "clone paths cannot contain NUL";
  clone_file_raw src dst

let rename (src : string) (dst : string) : unit =
  with_fs_or_fallback
    ~path:src
    ~fallback:(fun () -> Stdlib.Sys.rename src dst)
    (fun fs -> Eio.Path.rename Eio.Path.(fs / src) Eio.Path.(fs / dst))
;;

(* Both runtime paths catch the missing-source case explicitly rather
   than substring-matching on the libc error text. Stdlib's [Sys.rename]
   raises [Sys_error] with a libc-translated, locale-sensitive message;
   matching "No such file" against it skips the Eio path where
   [Eio.Io (Eio.Fs.E (Eio.Fs.Not_found _))] is propagated instead (the
   [with_io] normalizer wraps it into a [Sys_error] whose body does not
   necessarily contain "No such file"). The result was a silent
   path-dependent classifier failure: callers using the substring guard
   only recognized the missing-source case under the Stdlib fallback. *)
let rename_if_exists ~src ~dst =
  with_fs_or_fallback
    ~path:src
    ~fallback:(fun () ->
      try
        Stdlib.Sys.rename src dst;
        true
      with
      | Sys_error _ when not (Stdlib.Sys.file_exists src) -> false)
    (fun fs ->
      try
        Eio.Path.rename Eio.Path.(fs / src) Eio.Path.(fs / dst);
        true
      with
      | Eio.Io (Eio.Fs.E (Eio.Fs.Not_found _), _) -> false)
;;

let unlink_if_exists path =
  test_exec_home_guard ~op:"unlink_if_exists" path;
  with_fs_or_fallback
    ~path
    ~fallback:(fun () ->
      try Unix.unlink path; true with
      | Unix.Unix_error (Unix.ENOENT, _, _) -> false
      | Unix.Unix_error (code, operation, argument) ->
        raise (Sys_error
          (Printf.sprintf "%s(%s): %s" operation argument (Unix.error_message code))))
    (fun fs ->
      try Eio.Path.unlink Eio.Path.(fs / path); true with
      | Eio.Io (Eio.Fs.E (Eio.Fs.Not_found _), _) -> false)
;;

let remove_tree_unix (path : string) : unit =
  let rec remove path =
    match Unix.lstat path with
    | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
    | exception Unix.Unix_error (Unix.ENOTDIR, _, _) -> ()
    | stat when stat.Unix.st_kind = Unix.S_DIR ->
      Sys.readdir path
      |> Array.iter (fun name -> remove (Filename.concat path name));
      Unix.rmdir path
    | _stat -> Sys.remove path
  in
  remove path
;;

let remove_tree (path : string) : unit =
  let normalized = String.trim path in
  if String.equal normalized "" || String.equal normalized "/" || String.equal normalized "."
  then invalid_arg (Printf.sprintf "Fs_compat.remove_tree refuses unsafe path %S" path);
  test_exec_home_guard ~op:"remove_tree" path;
  with_fs_or_fallback
    ~path
    ~fallback:(fun () -> remove_tree_unix path)
    (fun _fs -> Fs_compat_internal.Systhread_host.run ~label:(labelled "fs-compat-remove-tree" path) (fun () -> remove_tree_unix path))
;;

let subdirectory_names_unix dir =
  let is_directory path =
    match Unix.stat path with
    | { Unix.st_kind = Unix.S_DIR; _ } -> true
    | { Unix.st_kind =
          Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK
      ; _
      } -> false
    | exception Unix.Unix_error (Unix.ENOENT, _, _) -> false
  in
  let names =
    match Sys.readdir dir with
    | names -> Array.to_list names
    | exception Sys_error _ when not (is_directory dir) -> []
  in
  names
  |> List.filter (fun name -> is_directory (Filename.concat dir name))
  |> List.sort String.compare
;;

let subdirectory_names (dir : string) : string list =
  with_fs_or_fallback
    ~path:dir
    ~fallback:(fun () -> subdirectory_names_unix dir)
    (fun _fs ->
       Fs_compat_internal.Systhread_host.run
         ~label:(labelled "fs-compat-subdirectory-names" dir)
         (fun () -> subdirectory_names_unix dir))
;;

let realpath (path : string) : string =
  with_fs_or_fallback
    ~path
    ~fallback:(fun () -> Unix.realpath path)
    (fun _fs -> Fs_compat_internal.Systhread_host.run ~label:(labelled "fs-compat-realpath" path) (fun () -> Unix.realpath path))
;;

let realpath_lenient (path : string) : string =
  let rec collect_suffix p acc =
    let parent = Filename.dirname p in
    if parent = p
    then
      (* Reached filesystem root without a successful realpath. *)
      p, acc
    else (
      match
        try Some (realpath p) with
        | Unix.Unix_error _ -> None
      with
      | Some resolved -> resolved, acc
      | None -> collect_suffix parent (Filename.basename p :: acc))
  in
  let normalize_with_base resolved_base suffix_parts =
    let is_abs =
      String.length resolved_base > 0 && Char.equal resolved_base.[0] '/'
    in
    let base_rev =
      String.split_on_char '/' resolved_base
      |> List.filter (fun seg -> not (String.equal seg ""))
      |> List.rev
    in
    let base_len = List.length base_rev in
    let popped_into_base = ref false in
    let final_rev =
      List.fold_left
        (fun (stack, depth) seg ->
           match seg with
           | "" | "." -> stack, depth
           | ".." ->
             (match stack with
              | [] -> if is_abs then [], 0 else [ ".." ], 1
              | top :: rest when not (String.equal top "..") ->
                let next_depth = depth - 1 in
                if next_depth < base_len then popped_into_base := true;
                rest, next_depth
              | _ :: _ -> ".." :: stack, depth + 1)
           | _ -> seg :: stack, depth + 1)
        (base_rev, base_len)
        suffix_parts
      |> fst
    in
    let collapsed =
      match is_abs, List.rev final_rev with
      | true, [] -> "/"
      | true, segs -> "/" ^ String.concat "/" segs
      | false, [] -> "."
      | false, segs -> String.concat "/" segs
    in
    collapsed, !popped_into_base
  in
  try realpath path with
  | Unix.Unix_error _ ->
    (* Walk up the directory tree until we find an ancestor that exists and
       can be resolved via realpath, then collapse "."/".." segments so
       nonexistent suffixes cannot bypass prefix-based containment checks.
       If ".." climbed into [resolved_base], run one final realpath pass on
       the collapsed path to resolve symlinks in the new ancestor branch. *)
    let resolved_base, suffix_parts = collect_suffix path [] in
    let collapsed, popped_into_base = normalize_with_base resolved_base suffix_parts in
    if not popped_into_base
    then collapsed
    else (
      try realpath collapsed with
      | Unix.Unix_error _ ->
        let resolved_base2, suffix_parts2 = collect_suffix collapsed [] in
        List.fold_left Filename.concat resolved_base2 suffix_parts2)
;;

(** Create directory recursively if not exists.
    @raises Sys_error on all I/O failures. Eio.Io is normalized internally. *)
let mkdir_p (path : string) : unit =
  test_exec_home_guard ~op:"mkdir_p" path;
  with_fs_or_fallback
    ~path
    ~fallback:(fun () -> mkdir_p_unix path)
    (fun fs ->
       let eio_path = Eio.Path.(fs / path) in
       Eio.Path.mkdirs ~exists_ok:true ~perm:0o755 eio_path)
;;
