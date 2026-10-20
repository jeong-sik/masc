let ( let* ) = Result.bind
type t = {path:string;incarnation:string}
type acquisition = Missing | Acquired of int * int | Released
let socket_path t = t.path
let arguments t ~max_message_bytes = ["--socket";t.path;"--incarnation";t.incarnation;
  "--max-message-bytes";string_of_int max_message_bytes]
let protect run = try run () with
  | (Unix.Unix_error _|Sys_error _|Yojson.Json_error _) as exn -> Error (Printexc.to_string exn)
let sync directory =
  let fd=Unix.openfile directory [Unix.O_RDONLY;Unix.O_CLOEXEC] 0 in
  Fun.protect ~finally:(fun () -> Unix.close fd) (fun () -> Unix.fsync fd)
let leaf instance_id =
  match Uuidm.of_string instance_id with
  | Some uuid when Uuidm.to_string uuid=instance_id ->
    Ok ("mb-" ^ Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet (Uuidm.to_binary_string uuid))
  | None | Some _ -> Error "browser resource requires a canonical worker UUID"
let context ~instance_id = protect (fun () ->
  let* leaf=leaf instance_id in
  let root=Unix.realpath (Filename.get_temp_dir_name ()) in
  Ok (`Assoc ["kind",`String "browser_socket";"directory",`String (Filename.concat root leaf)]))
let context_path admission =
  let* context=Native_addon_lease.cleanup_context admission |> Result.map_error Native_addon_lease.error_to_string in
  match context with
  | None -> Ok None
  | Some (`Assoc fields) when List.sort String.compare (List.map fst fields)=["directory";"kind"] ->
    (match List.assoc_opt "kind" fields,List.assoc_opt "directory" fields with
     | Some (`String "browser_socket"),Some (`String root) ->
       let* expected=leaf (Native_addon_lease.instance_id admission) in
       if Filename.is_relative root || Filename.basename root<>expected
         || Unix.realpath (Filename.dirname root)<>Filename.dirname root then Error "invalid browser allocation path"
       else Ok (Some root)
     | _ -> Error "unknown native cleanup descriptor")
  | Some _ -> Error "invalid native cleanup descriptor"
let slot admission directory =
  let directory=Unix.realpath directory in
  if List.mem directory (Native_addon_lease.directories admission) then
    let info=Unix.lstat directory in
    if info.Unix.st_kind=Unix.S_DIR && info.st_uid=Unix.geteuid () && info.st_perm=0o700 then Ok directory
    else Error "browser claim slot is not private and host-owned"
  else Error "browser resource is outside its native claim"
let record admission directory = Filename.concat directory
  ("browser-" ^ Digestif.SHA256.(to_hex (digest_string (Native_addon_lease.instance_id admission))) ^ ".json")
let acquired_json admission root info = `Assoc ["state",`String "acquired";
  "incarnation",`String (Native_addon_lease.instance_id admission);"directory",`String root;
  "device",`Int info.Unix.st_dev;"inode",`Int info.Unix.st_ino]
let acquire ~admission ~directory = protect (fun () ->
  let* directory=slot admission directory in
  let* status=Native_addon_lease.status admission |> Result.map_error Native_addon_lease.error_to_string in
  let* ()=match status with
    | Native_addon_lease.Awaiting_exec -> Ok ()
    | Live _|Cleanup_pending _|Settled -> Error "browser resource requires an unstarted original admission" in
  let* root=context_path admission in
  let* root=Option.to_result ~none:"native reservation has no browser allocation intent" root in
  let file=record admission directory in
  let* ()=match Unix.lstat file with
    | _ -> Error "browser socket resource was already acquired"
    | exception Unix.Unix_error (Unix.ENOENT,_,_) -> Ok () in
  Unix.mkdir root 0o700;
  let info=Unix.lstat root in
  sync root;sync (Filename.dirname root);
  let* ()=Fs_compat.save_file_atomic_strict file (Yojson.Safe.to_string (acquired_json admission root info)) in
  Ok {path=Filename.concat root "s";incarnation=Native_addon_lease.instance_id admission})
let private_root root info = info.Unix.st_kind=Unix.S_DIR && info.st_uid=Unix.geteuid ()
  && info.st_perm=0o700 && Unix.realpath root=root
let cleanup ~admission ~directory = protect (fun () ->
  let* directory=slot admission directory in
  let* status=Native_addon_lease.status admission |> Result.map_error Native_addon_lease.error_to_string in
  let* ()=match status with
    | Native_addon_lease.Settled -> Ok ()
    | Awaiting_exec|Live _|Cleanup_pending _ -> Error "native browser resource cleanup is not settled" in
  let* root=context_path admission in
  match root with
  | None -> Ok ()
  | Some root ->
    let file=record admission directory in
    let* value=match Unix.lstat file with
      | info when info.Unix.st_kind=Unix.S_REG && info.st_uid=Unix.geteuid () && info.st_nlink=1 ->
        Fs_compat.load_owned_regular_file ~ownership_root:directory file
          |> Result.map_error Fs_compat.owned_regular_file_read_error_to_string
          |> Result.map (Option.map Yojson.Safe.from_string)
      | _ -> Error "browser socket record is not a host-owned regular file"
      | exception Unix.Unix_error (Unix.ENOENT,_,_) -> Ok None in
    let* identity=match value with
      | None -> Ok Missing
      | Some (`Assoc fields) when List.sort String.compare (List.map fst fields)=["state"]
          && List.assoc_opt "state" fields=Some (`String "released") -> Ok Released
      | Some (`Assoc fields) when List.sort String.compare (List.map fst fields)=
          ["device";"directory";"incarnation";"inode";"state"] ->
        (match List.assoc_opt "incarnation" fields,List.assoc_opt "directory" fields,
          List.assoc_opt "device" fields,List.assoc_opt "inode" fields,List.assoc_opt "state" fields with
         | Some (`String incarnation),Some (`String known),Some (`Int device),Some (`Int inode),Some (`String "acquired")
           when incarnation=Native_addon_lease.instance_id admission && root=known -> Ok (Acquired (device,inode))
         | _ -> Error "invalid browser socket resource identity")
      | Some _ -> Error "invalid browser socket resource record" in
    let* ()=match Unix.lstat root with
      | info when private_root root info ->
        let* ()=match identity with
          | Released -> Error "released browser socket directory reappeared"
          | Missing ->
            if Sys.readdir root=[||] then Ok ()
            else Error "unconfirmed browser acquisition contains resources"
          | Acquired (device,inode) ->
            if info.st_dev=device && info.st_ino=inode then Ok ()
            else Error "browser socket directory identity changed" in
        let* ()=match Sys.readdir root |> Array.to_list with
          | [] -> Ok ()
          | ["s"] -> let path=Filename.concat root "s" in
              if (Unix.lstat path).Unix.st_kind=Unix.S_SOCK then (Unix.unlink path;Ok ())
              else Error "browser socket directory contains a non-socket resource"
          | _::_ -> Error "browser socket directory contains unknown resources" in
        Unix.rmdir root;Ok ()
      | _ -> Error "browser socket directory identity changed"
      | exception Unix.Unix_error (Unix.ENOENT,_,_) -> Ok () in
    sync (Filename.dirname root);
    Fs_compat.save_file_atomic_strict file (Yojson.Safe.to_string (`Assoc ["state",`String "released"])))
