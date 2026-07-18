exception Storage_error of string

let error_detail = function
  | Storage_error detail -> detail
  | exn -> Printexc.to_string exn
;;

let protect operation =
  try Ok (operation ()) with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> Error (error_detail exn)
;;

let file_kind_label = function
  | `Not_found -> "missing"
  | `Directory -> "directory"
  | `Regular_file -> "regular_file"
  | `Symbolic_link -> "symbolic_link"
  | `Fifo -> "fifo"
  | `Socket -> "socket"
  | `Character_special -> "character_device"
  | `Block_device -> "block_device"
  | `Unknown -> "unknown"
;;

let fsync_directory dir =
  protect (fun () ->
    let path =
      match Eio.Path.native dir with
      | Some path -> path
      | None -> raise (Storage_error "directory has no native fsync representation")
    in
    let fd = Unix.openfile path [ Unix.O_RDONLY; Unix.O_CLOEXEC ] 0 in
    Fun.protect ~finally:(fun () -> Unix.close fd) (fun () -> Unix.fsync fd))
;;

let require_ok = function
  | Ok value -> value
  | Error detail -> raise (Storage_error detail)
;;

let open_verified_directory ~sw path =
  protect (fun () ->
    let dir = Eio.Path.open_dir ~sw path in
    (match Eio.Path.native dir with
     | None -> ()
     | Some native ->
       let stat = Unix.lstat native in
       if stat.Unix.st_kind <> Unix.S_DIR
       then raise (Storage_error (Printf.sprintf "directory changed identity: %s" native)));
    dir)
;;

let ensure_private_child ~sw parent leaf =
  protect (fun () ->
    let path = Eio.Path.(parent / leaf) in
    (match Eio.Path.kind ~follow:false path with
     | `Not_found ->
       Eio.Path.mkdir ~perm:0o700 path;
       require_ok (fsync_directory parent)
     | `Directory -> ()
     | kind ->
       raise
         (Storage_error
            (Printf.sprintf
               "refusing non-directory storage component %s (%s)"
               leaf
               (file_kind_label kind))));
    require_ok (open_verified_directory ~sw path))
;;

let create_private_child ~sw parent leaf =
  protect (fun () ->
    let path = Eio.Path.(parent / leaf) in
    (match Eio.Path.kind ~follow:false path with
     | `Not_found -> Eio.Path.mkdir ~perm:0o700 path
     | kind ->
       raise
         (Storage_error
            (Printf.sprintf
               "refusing existing fresh execution directory %s (%s)"
               leaf
               (file_kind_label kind))));
    require_ok (fsync_directory parent);
    require_ok (open_verified_directory ~sw path))
;;

let load_json ~max_bytes path =
  match Eio.Path.kind ~follow:false path with
  | `Not_found -> Ok None
  | `Regular_file ->
    protect (fun () ->
      (match Eio.Path.native path with
       | Some native ->
         let stat = Unix.lstat native in
         if stat.Unix.st_size > max_bytes
         then raise (Storage_error "recovery slot exceeds the maximum record size")
       | None -> ());
      Some (Eio.Path.load path |> Yojson.Safe.from_string))
  | kind ->
    Error
      (Printf.sprintf "refusing non-regular recovery slot (%s)" (file_kind_label kind))
;;

let persist_exclusive ~max_bytes ~parent ~path payload =
  let temp_leaf = Random_id.prefixed ~prefix:".slot-" ~bytes:16 ^ ".tmp" in
  let temp_path = Eio.Path.(parent / temp_leaf) in
  let cleanup_temp reason =
    match Eio.Path.native temp_path with
    | None ->
      Log.Misc.warn "OAS recovery slot %s temp has no native cleanup representation" reason
    | Some native ->
      (try
         Unix.unlink native;
         (match fsync_directory parent with
          | Ok () -> ()
          | Error detail ->
            Log.Misc.warn
              "OAS recovery slot %s temp unlink fsync failed: %s"
              reason
              detail)
       with
       | Unix.Unix_error (Unix.ENOENT, _, _) -> ()
       | cleanup_exn ->
         Log.Misc.warn
           "OAS recovery slot %s left a temp file: %s"
           reason
           (Printexc.to_string cleanup_exn))
  in
  if String.length payload > max_bytes
  then Error "recovery record exceeds the maximum durable record size"
  else
    try
      Eio.Switch.run
      @@ fun file_sw ->
      let file = Eio.Path.open_out ~sw:file_sw ~create:(`Exclusive 0o600) temp_path in
      Eio.Flow.copy_string payload file;
      Eio.File.sync file;
      let temp_native, path_native =
        match Eio.Path.native temp_path, Eio.Path.native path with
        | Some temp_native, Some path_native -> temp_native, path_native
        | _ ->
          raise
            (Storage_error "recovery slot has no native publication representation")
      in
      Unix.link temp_native path_native;
      (match fsync_directory parent with
       | Error _ as error ->
         cleanup_temp "publication failure";
         error
       | Ok () ->
         cleanup_temp "published";
         Ok ())
    with
    | Eio.Cancel.Cancelled _ as exn ->
      cleanup_temp "cancellation";
      raise exn
    | exn ->
      cleanup_temp "failure";
      Error (error_detail exn)
;;

let remove_file ~parent path =
  match protect (fun () -> Eio.Path.unlink path) with
  | Error _ as error -> error
  | Ok () -> fsync_directory parent
;;

let remove_empty_directory ~parent dir =
  protect (fun () ->
    let native =
      match Eio.Path.native dir with
      | Some native -> native
      | None ->
        raise
          (Storage_error "unused execution scope has no native cleanup representation")
    in
    Unix.rmdir native;
    require_ok (fsync_directory parent))
;;
