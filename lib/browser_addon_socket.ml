let ( let* ) = Result.bind
type t = {path:string;incarnation:string;automation:bool;models:bool;stagehand:bool}
type acquisition = Missing | Acquired of int * int | Cleaning of int * int | Released
let socket_path t = t.path
let arguments t ~max_message_bytes = ["--socket";t.path;"--incarnation";t.incarnation;
  "--max-message-bytes";string_of_int max_message_bytes] @ (if t.automation then ["--automation"] else [])
  @ (if t.models then ["--models"] else []) @ (if t.stagehand then ["--stagehand"] else [])
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
let context ~instance_id ~automation ~stagehand ~models = protect (fun () ->
  let* leaf=leaf instance_id in
  let root=Unix.realpath (Filename.get_temp_dir_name ()) in
  Ok (`Assoc ["kind",`String "browser_socket";"directory",`String (Filename.concat root leaf);
    "stagehand",(match stagehand with None -> `Null | Some c -> Browser_addon_stagehand.configuration_to_json c);
    "models",(match models with None -> `Null | Some configuration -> Browser_addon_models.configuration_to_json configuration);
    "automation",(match automation with None -> `Null | Some configuration -> Browser_addon_automation.configuration_to_json configuration)]))
let context_path admission =
  let* context=Native_addon_lease.cleanup_context admission |> Result.map_error Native_addon_lease.error_to_string in
  match context with
  | None -> Ok None
  | Some (`Assoc fields) when List.sort String.compare (List.map fst fields)=["automation";"directory";"kind";"models";"stagehand"] ->
    (match List.assoc_opt "kind" fields,List.assoc_opt "directory" fields with
     | Some (`String "browser_socket"),Some (`String root) ->
       let* expected=leaf (Native_addon_lease.instance_id admission) in
       if Filename.is_relative root || Filename.basename root<>expected
         || Unix.realpath (Filename.dirname root)<>Filename.dirname root then Error "invalid browser allocation path"
       else
         let* automation=match List.assoc_opt "automation" fields with
           | Some `Null -> Ok None
           | Some value -> Browser_addon_automation.configuration_of_json value |> Result.map Option.some
           | None -> Error "missing automation descriptor" in
         let* models=match List.assoc_opt "models" fields with
           | Some `Null -> Ok None
           | Some value -> Browser_addon_models.configuration_of_json value |> Result.map Option.some
           | None -> Error "missing model broker descriptor" in
         let* stagehand=match List.assoc_opt "stagehand" fields with
           | Some `Null -> Ok None
           | Some value -> Browser_addon_stagehand.configuration_of_json value |> Result.map Option.some
           | None -> Error "missing Chrome descriptor" in
         Ok (Some (root,automation,models,stagehand))
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
let acquired_json admission root info ~state = `Assoc ["state",`String state;
  "incarnation",`String (Native_addon_lease.instance_id admission);"directory",`String root;
  "device",`Int info.Unix.st_dev;"inode",`Int info.Unix.st_ino]
let acquire ~admission ~directory = protect (fun () ->
  let* directory=slot admission directory in
  let* status=Native_addon_lease.status admission |> Result.map_error Native_addon_lease.error_to_string in
  let* ()=match status with
    | Native_addon_lease.Awaiting_exec -> Ok ()
    | Live _|Cleanup_pending _|Settled -> Error "browser resource requires an unstarted original admission" in
  let* root=context_path admission in
  let* root,automation,models,stagehand=Option.to_result ~none:"native reservation has no browser allocation intent" root in
  let file=record admission directory in
  let* ()=match Unix.lstat file with
    | _ -> Error "browser socket resource was already acquired"
    | exception Unix.Unix_error (Unix.ENOENT,_,_) -> Ok () in
  Unix.mkdir root 0o700;
  let info=Unix.lstat root in
  sync root;sync (Filename.dirname root);
  let* ()=Fs_compat.save_file_atomic_strict file (Yojson.Safe.to_string (acquired_json admission root info ~state:"acquired")) in
  let* ()=match automation with
    | None -> Ok ()
    | Some configuration -> Fs_compat.save_file_atomic_strict (Filename.concat root "automation.json")
        (Yojson.Safe.to_string (Browser_addon_automation.configuration_to_json configuration)) in
  let* ()=match models with
    | None -> Ok ()
    | Some configuration -> Fs_compat.save_file_atomic_strict (Filename.concat root "models.json")
        (Yojson.Safe.to_string (Browser_addon_models.configuration_to_json configuration)) in
  let* ()=match stagehand with
    | None -> Ok ()
    | Some c -> Fs_compat.save_file_atomic_strict (Filename.concat root "stagehand.json")
        (Yojson.Safe.to_string (Browser_addon_stagehand.configuration_to_json c)) in
  Ok {path=Filename.concat root "s";incarnation=Native_addon_lease.instance_id admission;
    automation=Option.is_some automation;models=Option.is_some models;stagehand=Option.is_some stagehand})
let private_root root info = info.Unix.st_kind=Unix.S_DIR && info.st_uid=Unix.geteuid ()
  && info.st_perm=0o700 && Unix.realpath root=root
(* Only empty directory trees may be removed. Files, links and uncertain
   acquisitions are retained for the original incarnation; never recursive rm. *)
let rec empty_tree path =
  match Unix.lstat path with
  | info when info.Unix.st_kind=Unix.S_DIR && info.st_uid=Unix.geteuid () ->
      let* ()=Array.fold_left (fun acc name -> let* ()=acc in empty_tree (Filename.concat path name)) (Ok ()) (Sys.readdir path) in
      Unix.rmdir path;Ok ()
  | _ -> Error "owned browser still has profile or download contents"
  | exception Unix.Unix_error (Unix.ENOENT,_,_) -> Ok ()
let cleanup_contents ~admission ~root ~automation ~models ~stagehand ~confirmed ~confirm =
  let read name =
    let* text=Fs_compat.load_owned_regular_file ~ownership_root:root (Filename.concat root name)
      |> Result.map_error Fs_compat.owned_regular_file_read_error_to_string in
    let* text=Option.to_result ~none:("missing " ^ name) text in
    Ok (Yojson.Safe.from_string text) in
  let names=Sys.readdir root |> Array.to_list in
  let* ()=match models with
    | None -> if List.mem "models.json" names then Error "undeclared browser model configuration" else Ok ()
    | Some configuration ->
        if confirmed && not (List.mem "models.json" names) then Ok () else
        let* value=read "models.json" in
        let* actual=Browser_addon_models.configuration_of_json value in
        if Browser_addon_models.configuration_to_json actual=Browser_addon_models.configuration_to_json configuration
        then Ok () else Error "browser model configuration changed" in
  let names=List.filter (fun name -> name<>"models.json") names in
  let* ()=match stagehand with
    | None -> if List.exists (fun name -> List.mem name ["stagehand.json";"chromium.log";"chromium-profiles"]) names
        then Error "undeclared Chrome resources" else Ok ()
    | Some configuration ->
      let* ()=if confirmed && not (List.mem "stagehand.json" names) then Ok () else
        let* value=read "stagehand.json" in
        let* actual=Browser_addon_stagehand.configuration_of_json value in
        if Browser_addon_stagehand.configuration_to_json actual=Browser_addon_stagehand.configuration_to_json configuration
        then Ok () else Error "Chrome configuration changed" in
      Browser_addon_stagehand.cleanup configuration ~incarnation:(Native_addon_lease.instance_id admission) ~directory:root in
  let names=List.filter (fun name -> not (List.mem name ["stagehand.json";"chromium.log";"chromium-profiles"])) names in
  let* ()=match automation with
    | None -> if List.for_all ((=) "s") names then Ok () else Error "browser socket directory contains unknown resources"
    | Some configuration ->
      let* ()=if List.for_all (fun name -> List.mem name ["s";"automation.json";"automation-closed.json";"webdriver.log";"profiles";"downloads"]) names
        then Ok () else Error "owned browser directory contains unknown resources" in
      let* ()=if confirmed then Ok () else (
      let* spec=read "automation.json" in
      let* actual=Browser_addon_automation.configuration_of_json spec in
      let* ()=if actual=configuration then Ok () else Error "owned browser configuration changed" in
      let* receipt=read "automation-closed.json" in
      if receipt=`Assoc ["incarnation",`String (Native_addon_lease.instance_id admission)] then Ok ()
        else Error "owned browser cleanup is unconfirmed") in
      let* ()=empty_tree (Filename.concat root "profiles") in
      empty_tree (Filename.concat root "downloads") in
  let* ()=confirm () in
  List.fold_left (fun acc name -> let* ()=acc in
    let path=Filename.concat root name in
    match (Unix.lstat path).Unix.st_kind with
    | Unix.S_SOCK when name="s" -> Unix.unlink path;Ok ()
    | Unix.S_REG when List.mem name ["automation.json";"automation-closed.json";"webdriver.log";"models.json";"stagehand.json";"chromium.log"] ->
        let info=Unix.lstat path in
        if info.st_uid=Unix.geteuid () && info.st_nlink=1 then (Unix.unlink path;Ok ())
        else Error "owned browser file identity is unknown"
    | Unix.S_DIR|Unix.S_REG|Unix.S_LNK|Unix.S_CHR|Unix.S_BLK|Unix.S_FIFO|Unix.S_SOCK ->
        Error "browser directory contains an unexpected resource") (Ok ())
    (Sys.readdir root |> Array.to_list)
let cleanup ~admission ~directory = protect (fun () ->
  let* directory=slot admission directory in
  let* status=Native_addon_lease.status admission |> Result.map_error Native_addon_lease.error_to_string in
  let* ()=match status with
    | Native_addon_lease.Settled -> Ok ()
    | Awaiting_exec|Live _|Cleanup_pending _ -> Error "native browser resource cleanup is not settled" in
  let* root=context_path admission in
  match root with
  | None -> Ok ()
  | Some (root,automation,models,stagehand) ->
    let* ()=match stagehand with None -> Ok () | Some c ->
      Browser_addon_stagehand.settle c ~incarnation:(Native_addon_lease.instance_id admission) ~directory:root in
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
         | Some (`String incarnation),Some (`String known),Some (`Int device),Some (`Int inode),Some (`String state)
           when incarnation=Native_addon_lease.instance_id admission && root=known ->
             (match state with "acquired" -> Ok (Acquired (device,inode))
              | "cleaning" -> Ok (Cleaning (device,inode))
              | _ -> Error "invalid browser allocation state")
         | _ -> Error "invalid browser socket resource identity")
      | Some _ -> Error "invalid browser socket resource record" in
    let* ()=match Unix.lstat root with
      | info when private_root root info ->
        let* ()=match identity with
          | Released -> Error "released browser socket directory reappeared"
          | Missing ->
            if Sys.readdir root=[||] then Ok ()
            else Error "unconfirmed browser acquisition contains resources"
          | Acquired (device,inode)|Cleaning (device,inode) ->
            if info.st_dev=device && info.st_ino=inode then Ok ()
            else Error "browser socket directory identity changed" in
        let confirmed=match identity with Cleaning _ -> true | Missing|Acquired _|Released -> false in
        let confirm ()=if confirmed then Ok () else
          Fs_compat.save_file_atomic_strict file
            (Yojson.Safe.to_string (acquired_json admission root info ~state:"cleaning")) in
        let automation=match identity with Missing -> None | Acquired _|Cleaning _|Released -> automation in
        let models=match identity with Missing -> None | Acquired _|Cleaning _|Released -> models in
        let stagehand=match identity with Missing -> None | Acquired _|Cleaning _|Released -> stagehand in
        let* ()=cleanup_contents ~admission ~root ~automation ~models ~stagehand ~confirmed ~confirm in
        Unix.rmdir root;Ok ()
      | _ -> Error "browser socket directory identity changed"
      | exception Unix.Unix_error (Unix.ENOENT,_,_) ->
        (match identity,Option.is_some automation || Option.is_some stagehand with
         | Acquired _,true -> Error "owned browser allocation vanished without confirmed cleanup"
         | (Missing|Cleaning _|Released),_ | Acquired _,false -> Ok ()) in
    sync (Filename.dirname root);
    Fs_compat.save_file_atomic_strict file (Yojson.Safe.to_string (`Assoc ["state",`String "released"])))
