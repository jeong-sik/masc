module B = Browser_lane
module W = Browser_addon_wire
let ( let* ) = Result.bind
type error = Identity_changed | Unconfirmed of string
let protect run = try run () with
  | (Unix.Unix_error _|Sys_error _|Yojson.Json_error _) as exn ->
      Error (Unconfirmed (Printexc.to_string exn))
let sync directory =
  let fd=Unix.openfile directory [Unix.O_RDONLY;Unix.O_CLOEXEC] 0 in
  Fun.protect ~finally:(fun () -> Unix.close fd) (fun () -> Unix.fsync fd)
let canonical_root root =
  if Filename.is_relative root then Error (Unconfirmed "browser registration root must be absolute")
  else Ok (Filename.concat (Unix.realpath (Filename.dirname root)) (Filename.basename root))
let private_directory path info =
  if info.Unix.st_kind=Unix.S_DIR && info.st_uid=Unix.geteuid () && info.st_perm=0o700
      && Unix.realpath path=path then Ok ()
  else Error (Unconfirmed "browser registration directory is not private and host-owned")
let inspect path = match Unix.lstat path with
  | info -> let* ()=private_directory path info in Ok true
  | exception Unix.Unix_error (Unix.ENOENT,_,_) -> Ok false
let leaf root client = Filename.concat root (B.client_id_to_string client.B.client_id)
let file directory = Filename.concat directory "owner.json"
let canonical_instance raw = B.client_id_of_string raw |> Result.map (fun _ -> raw)
  |> Result.map_error (fun detail -> Unconfirmed detail)
let decode json = match json with
  | `Assoc fields when List.sort String.compare (List.map fst fields)=["client";"instance_id"] ->
      let* instance=match List.assoc "instance_id" fields with
        | `String value -> canonical_instance value
        | _ -> Error (Unconfirmed "invalid browser registration worker") in
      let* client=W.client_of_json (List.assoc "client" fields)
        |> Result.map_error (fun detail -> Unconfirmed detail) in
      Ok (instance,client)
  | _ -> Error (Unconfirmed "invalid browser registration record")
let read ~root ~client directory =
  let path=file directory in
  let* ()=match Unix.lstat path with
    | info when info.Unix.st_kind=Unix.S_REG && info.st_uid=Unix.geteuid ()
        && info.st_nlink=1 && info.st_perm=0o600 -> Ok ()
    | _ -> Error (Unconfirmed "browser registration record is not private and host-owned")
    | exception Unix.Unix_error (Unix.ENOENT,_,_) ->
        Error (Unconfirmed "browser client reservation has no completed owner record") in
  let* bytes=Fs_compat.load_owned_regular_file ~ownership_root:root path
    |> Result.map_error (fun error -> Unconfirmed (Fs_compat.owned_regular_file_read_error_to_string error)) in
  let* bytes=Option.to_result ~none:(Unconfirmed "browser registration disappeared") bytes in
  let* instance,recorded=decode (Yojson.Safe.from_string bytes) in
  let* ()=if recorded=client then Ok () else Error Identity_changed in
  (* Another reader may observe the atomic rename before its writer's fsync.
     Confirm the file and complete reservation chain before forwarding a poll. *)
  let* ()=Fs_compat.sync_file_and_parent_strict path |> Result.map_error (fun detail -> Unconfirmed detail) in
  sync root;sync (Filename.dirname root);
  Ok instance
let find ~root ~client = protect (fun () ->
  let* root=canonical_root root in
  let* exists=inspect root in
  if not exists then Ok None else
  let directory=leaf root client in
  let* exists=inspect directory in
  if not exists then Ok None else read ~root ~client directory |> Result.map Option.some)
let claim ~root ~client ~instance_id = protect (fun () ->
  let* instance_id=canonical_instance instance_id in
  let* _=W.client_of_json (W.client_to_json client) |> Result.map_error (fun detail -> Unconfirmed detail) in
  let* root=canonical_root root in
  (try Unix.mkdir root 0o700 with Unix.Unix_error (Unix.EEXIST,_,_) -> ());
  let* _=inspect root in
  let directory=leaf root client in
  let created=try Unix.mkdir directory 0o700;true with Unix.Unix_error (Unix.EEXIST,_,_) -> false in
  let* _=inspect directory in
  let* ()=if not created then Ok () else (
    sync directory;sync root;sync (Filename.dirname root);
    let record=`Assoc ["instance_id",`String instance_id;"client",W.client_to_json client] in
    Fs_compat.write_file_atomic_strict_staged (file directory) ~write:(fun channel ->
      Unix.fchmod (Unix.descr_of_out_channel channel) 0o600;
      output_string channel (Yojson.Safe.to_string record))
      |> Result.map_error (fun failure -> Unconfirmed (Fs_compat.atomic_replace_failure_to_string failure))) in
  read ~root ~client directory)
