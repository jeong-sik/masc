type error =
  | Durable_source_read_failed of
      { path : string
      ; reason : string
      }
  | Symlink_encountered of { path : string }

let error_to_string = function
  | Durable_source_read_failed { path; reason } ->
    Printf.sprintf "durable source read failed path=%s: %s" path reason
  | Symlink_encountered { path } ->
    Printf.sprintf
      "refusing to report unreferenced past an unresolved symlink at %s"
      path
;;

(* Kept in sync by hand with Tool_blob_maintenance.durable_consumer_basenames
   (lib/tool_blob_store/tool_blob_maintenance.ml); that list is not exported,
   so this is a deliberate, documented duplication rather than a dependency. *)
let durable_consumer_basenames =
  [ "gate"; "keepers"; "keeper_chat"; "messages"; "tool_calls"; "traces"; "wire-capture" ]
;;

exception Found
exception Error_exn of error

let unix_reason fn arg code = Printf.sprintf "%s(%s): %s" fn arg (Unix.error_message code)

let contains_substring ~needle haystack =
  let nlen = String.length needle in
  let hlen = String.length haystack in
  if nlen = 0 || nlen > hlen then false
  else begin
    let rec loop i =
      if i > hlen - nlen then false
      else if String.equal (String.sub haystack i nlen) needle then true
      else loop (i + 1)
    in
    loop 0
  end
;;

let read_whole_file path =
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () ->
      let len = in_channel_length ic in
      really_input_string ic len)
;;

(* A regular file is read and checked; a directory is recursed into. A
   symlink is never followed (it could point outside the scanned tree), and
   it is never silently skipped either (see .mli): this predicate protects a
   handle by answering [true], and a symlink is a place this scan cannot
   verify, so it must not fall through as "no reference here". A device,
   socket or fifo is not a place a handle mention could live and is skipped
   without raising: unlike a symlink it names no other content to miss. *)
let rec walk_tree ~handle path =
  match Unix.lstat path with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
  | exception Unix.Unix_error (err, fn, arg) ->
    raise (Error_exn (Durable_source_read_failed { path; reason = unix_reason fn arg err }))
  | stat ->
    (match stat.Unix.st_kind with
     | Unix.S_REG ->
       (match read_whole_file path with
        | content -> if contains_substring ~needle:handle content then raise Found
        | exception Sys_error reason -> raise (Error_exn (Durable_source_read_failed { path; reason })))
     | Unix.S_DIR ->
       (match Sys.readdir path with
        | exception Sys_error reason -> raise (Error_exn (Durable_source_read_failed { path; reason }))
        | entries -> Array.iter (fun name -> walk_tree ~handle (Filename.concat path name)) entries)
     | Unix.S_LNK -> raise (Error_exn (Symlink_encountered { path }))
     | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK -> ())
;;

(* Only the direct children of [root] can be named [exclude_suffix]-excluded:
   that is where a vision store's own [<keeper>.vision] directory sits as a
   sibling of the keeper's own state directory under [masc_dir/keepers]. *)
let walk_root ~handle ~exclude_suffix root =
  match Unix.lstat root with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
  | exception Unix.Unix_error (err, fn, arg) ->
    raise (Error_exn (Durable_source_read_failed { path = root; reason = unix_reason fn arg err }))
  | stat ->
    (match stat.Unix.st_kind with
     | Unix.S_DIR ->
       (match Sys.readdir root with
        | exception Sys_error reason -> raise (Error_exn (Durable_source_read_failed { path = root; reason }))
        | entries ->
          Array.iter
            (fun name ->
              match exclude_suffix with
              | Some suffix when Filename.check_suffix name suffix -> ()
              | Some _ | None -> walk_tree ~handle (Filename.concat root name))
            entries)
     | Unix.S_REG -> walk_tree ~handle root
     | Unix.S_LNK -> raise (Error_exn (Symlink_encountered { path = root }))
     | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK -> ())
;;

let is_referenced ~masc_dir ~handle =
  try
    List.iter
      (fun basename ->
        let root = Filename.concat masc_dir basename in
        let exclude_suffix = if String.equal basename "keepers" then Some ".vision" else None in
        walk_root ~handle ~exclude_suffix root)
      durable_consumer_basenames;
    Ok false
  with
  | Found -> Ok true
  | Error_exn e -> Error e
;;
