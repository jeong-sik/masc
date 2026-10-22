let ( let* ) = Result.bind
module Requirement = Resource_requirement
type t = {path:string;incarnation:string;automation:bool;models:bool;stagehand:bool;live_bidi:bool;device:int;inode:int}
type acquisition = Missing | Acquired of int * int | Cleaning of int * int | Retained of int * int | Released
type settlement = Allocation_released | Allocation_retained
let socket_path t = t.path
let arguments t ~max_message_bytes = ["--socket";t.path;"--incarnation";t.incarnation;
  "--max-message-bytes";string_of_int max_message_bytes] @ (if t.automation then ["--automation"] else [])
  @ (if t.models then ["--models"] else []) @ (if t.stagehand then ["--stagehand"] else [])
  @ (if t.live_bidi then ["--live-bidi"] else [])
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
let context ~instance_id ~automation ~stagehand ~live_bidi ~models = protect (fun () ->
  let* leaf=leaf instance_id in
  let root=Unix.realpath (Filename.get_temp_dir_name ()) in
  Ok (`Assoc ["kind",`String "browser_socket";"directory",`String (Filename.concat root leaf);
    "stagehand",(match stagehand with None -> `Null | Some c -> Browser_addon_stagehand.configuration_to_json c);
    "live_bidi",(match live_bidi with None -> `Null | Some c -> Browser_addon_live_bidi.configuration_to_json c);
    "models",(match models with None -> `Null | Some configuration -> Browser_addon_models.configuration_to_json configuration);
    "automation",(match automation with None -> `Null | Some configuration -> Browser_addon_automation.configuration_to_json configuration)]))
let cleanup_descriptor_label = "native cleanup descriptor"
let cleanup_descriptor_keys = ["automation";"directory";"kind";"live_bidi";"models";"stagehand"]
let context_of_json ~instance_id = function
  | None -> Ok None
  | Some (`Assoc fields) when List.sort String.compare (List.map fst fields)=cleanup_descriptor_keys ->
    (match List.assoc "kind" fields,List.assoc "directory" fields with
     | `String "browser_socket",`String root ->
       let* expected=leaf instance_id in
       if Filename.is_relative root || Filename.basename root<>expected
         || Unix.realpath (Filename.dirname root)<>Filename.dirname root then
         Error (Printf.sprintf "browser allocation directory %s must be an absolute path named %s under its own canonical parent"
           root expected)
       else
         let optional decode name=match List.assoc name fields with
           | `Null -> Ok None
           | value -> decode value |> Result.map Option.some in
         let* automation=optional Browser_addon_automation.configuration_of_json "automation" in
         let* models=optional Browser_addon_models.configuration_of_json "models" in
         let* stagehand=optional Browser_addon_stagehand.configuration_of_json "stagehand" in
         let* live_bidi=optional Browser_addon_live_bidi.configuration_of_json "live_bidi" in
         Ok (Some (root,automation,models,stagehand,live_bidi))
     | kind,directory ->
       Error (Printf.sprintf "%s must have kind \"browser_socket\" and a string directory; it has kind %s and directory %s"
         cleanup_descriptor_label (Yojson.Safe.to_string kind) (Yojson.Safe.to_string directory)))
  | Some (`Assoc fields) ->
    Error (Requirement.keys ~label:cleanup_descriptor_label ~found:(List.map fst fields) ~required:cleanup_descriptor_keys)
  | Some value ->
    Error (Printf.sprintf "%s must be a JSON object; it is %s" cleanup_descriptor_label (Yojson.Safe.to_string value))
let context_path admission =
  let* context=Native_addon_lease.cleanup_context admission |> Result.map_error Native_addon_lease.error_to_string in
  context_of_json ~instance_id:(Native_addon_lease.instance_id admission) context
let slot admission directory =
  let directory=Unix.realpath directory in
  if List.mem directory (Native_addon_lease.directories admission) then
    let* _=Requirement.lstat ~label:"browser claim slot" Requirement.private_directory directory in
    Ok directory
  else Error (Printf.sprintf "browser claim slot %s must be one of its native claim's directories %s"
    directory (String.concat ", " (Native_addon_lease.directories admission)))
let record_of_instance instance_id directory = Filename.concat directory
  ("browser-" ^ Digestif.SHA256.(to_hex (digest_string instance_id)) ^ ".json")
let record admission directory = record_of_instance (Native_addon_lease.instance_id admission) directory
let allocation_json admission root ~device ~inode ~state = `Assoc ["state",`String state;
  "incarnation",`String (Native_addon_lease.instance_id admission);"directory",`String root;
  "device",`Int device;"inode",`Int inode]
let acquired_json admission root info ~state =
  allocation_json admission root ~device:info.Unix.st_dev ~inode:info.Unix.st_ino ~state
let acquire ~admission ~directory = protect (fun () ->
  let* directory=slot admission directory in
  let* status=Native_addon_lease.status admission |> Result.map_error Native_addon_lease.error_to_string in
  let* ()=match status with
    | Native_addon_lease.Awaiting_exec -> Ok ()
    | Live _|Cleanup_pending _|Settled -> Error "browser resource requires an unstarted original admission" in
  let* root=context_path admission in
  let* root,automation,models,stagehand,live_bidi=Option.to_result ~none:"native reservation has no browser allocation intent" root in
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
  let* ()=match live_bidi with
    | None -> Ok ()
    | Some c -> Fs_compat.save_file_atomic_strict (Filename.concat root "live-bidi.json")
        (Yojson.Safe.to_string (Browser_addon_live_bidi.configuration_to_json c)) in
  Ok {path=Filename.concat root "s";incarnation=Native_addon_lease.instance_id admission;
    automation=Option.is_some automation;models=Option.is_some models;stagehand=Option.is_some stagehand;
    live_bidi=Option.is_some live_bidi;
    device=info.st_dev;inode=info.st_ino})
let with_download_snapshot t (descriptor:Browser_addon_downloads.descriptor) consume = protect (fun () ->
  let allocation=Filename.dirname t.path in
  let root=Filename.concat allocation "download-snapshots" in
  let directory ~label path ~device ~inode =
    let* info=Requirement.lstat ~label Requirement.private_directory path in
    let observed=Requirement.identity info in
    let* ()=if observed.Requirement.device=device && observed.inode=inode then Ok ()
      else Error (Requirement.replaced ~label ~path ~expected:{Requirement.device;inode} ~observed) in
    Requirement.canonical ~label path in
  let roots () =
    let* ()=directory ~label:"browser allocation directory" allocation ~device:t.device ~inode:t.inode in
    directory ~label:"browser download snapshot directory" root
      ~device:descriptor.root_device ~inode:descriptor.root_inode in
  let* path=Browser_addon_downloads.snapshot_path ~directory:allocation ~snapshot_id:descriptor.snapshot_id in
  let valid label info = Browser_addon_downloads.snapshot_matches ~label ~path descriptor info in
  let* ()=roots () in
  let* ()=valid "download snapshot" (Unix.lstat path) in
  let source=Unix.openfile path [Unix.O_RDONLY;Unix.O_NONBLOCK;Unix.O_CLOEXEC] 0 in
  Fun.protect ~finally:(fun () -> Unix.close source) (fun () ->
    let* ()=valid "opened download snapshot" (Unix.fstat source) in
    let* ()=roots () in
    let* value=consume source in
    let* ()=roots () in
    let* ()=valid "opened download snapshot after import" (Unix.fstat source) in
    let* ()=valid "download snapshot after import" (Unix.lstat path) in
    Ok value))
let socket_directory_label = "browser socket directory"
let private_root root info =
  let* ()=Requirement.check ~label:socket_directory_label Requirement.private_directory ~path:root info in
  Requirement.canonical ~label:socket_directory_label root
let socket_record = {Requirement.kind=Unix.S_REG;owner=Effective_user;mode=Any_mode;links=Exactly_one}
let owned_directory = {Requirement.kind=Unix.S_DIR;owner=Effective_user;mode=Any_mode;links=Any_count}
(* Only empty directory trees may be removed. Files, links and uncertain
   acquisitions are retained for the original incarnation; never recursive rm. *)
let rec empty_tree path =
  match Unix.lstat path with
  | info ->
      let* ()=Requirement.check ~label:"owned browser profile or download entry" owned_directory ~path info in
      let* ()=Array.fold_left (fun acc name -> let* ()=acc in empty_tree (Filename.concat path name)) (Ok ()) (Sys.readdir path) in
      Unix.rmdir path;Ok ()
  | exception Unix.Unix_error (Unix.ENOENT,_,_) -> Ok ()
let cleanup_contents ~admission ~root ~automation ~models ~stagehand ~live_bidi ~confirmed ~confirm =
  let read name =
    let* text=Fs_compat.load_owned_regular_file ~ownership_root:root (Filename.concat root name)
      |> Result.map_error Fs_compat.owned_regular_file_read_error_to_string in
    let* text=Option.to_result ~none:("missing " ^ name) text in
    Ok (Yojson.Safe.from_string text) in
  let* ()=empty_tree (Filename.concat root "uploads") in
  let* ()=empty_tree (Filename.concat root "download-snapshots") in
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
  let* ()=match live_bidi with
    | None -> if List.exists (fun name -> List.mem name ["live-bidi.json";"live-firefox.log"]) names
        then Error "undeclared live BiDi resources" else Ok ()
    | Some configuration ->
      let* ()=if confirmed && not (List.mem "live-bidi.json" names) then Ok () else
        let* value=read "live-bidi.json" in
        let* actual=Browser_addon_live_bidi.configuration_of_json value in
        if Browser_addon_live_bidi.configuration_to_json actual=Browser_addon_live_bidi.configuration_to_json configuration
        then Ok () else Error "live BiDi configuration changed" in
      Browser_addon_live_bidi.cleanup configuration ~incarnation:(Native_addon_lease.instance_id admission) ~directory:root in
  let names=List.filter (fun name -> not (List.mem name ["live-bidi.json";"live-firefox.log"])) names in
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
    let info=Unix.lstat path in
    match info.Unix.st_kind with
    | Unix.S_SOCK when name="s" -> Unix.unlink path;Ok ()
    | Unix.S_REG when List.mem name ["automation.json";"automation-closed.json";"webdriver.log";"models.json";"stagehand.json";"chromium.log";"live-bidi.json";"live-firefox.log"] ->
        let* ()=Requirement.check ~label:"owned browser file" socket_record ~path info in
        Unix.unlink path;Ok ()
    | Unix.S_DIR|Unix.S_REG|Unix.S_LNK|Unix.S_CHR|Unix.S_BLK|Unix.S_FIFO|Unix.S_SOCK as kind ->
        Error (Printf.sprintf "browser socket directory entry %s is an unexpected %s"
          path (Requirement.kind_name kind))) (Ok ())
    (Sys.readdir root |> Array.to_list)
let socket_record_keys = ["device";"directory";"incarnation";"inode";"state"]
(* The socket acquisition record [cleanup] reads in the installation slot. *)
let acquisition ~instance_id ~root ~file ~directory =
  let* value=match Unix.lstat file with
    | info ->
      let* ()=Requirement.check ~label:"browser socket record" socket_record ~path:file info in
      Fs_compat.load_owned_regular_file ~ownership_root:directory file
        |> Result.map_error Fs_compat.owned_regular_file_read_error_to_string
        |> Result.map (Option.map Yojson.Safe.from_string)
    | exception Unix.Unix_error (Unix.ENOENT,_,_) -> Ok None in
  match value with
  | None -> Ok Missing
  | Some (`Assoc fields) when List.sort String.compare (List.map fst fields)=["state"]
      && List.assoc_opt "state" fields=Some (`String "released") -> Ok Released
  | Some (`Assoc fields) when List.sort String.compare (List.map fst fields)=socket_record_keys ->
    let refuse name requirement found = Error (Printf.sprintf "browser socket record %s field %s must be %s; it is %s"
      file name requirement (Yojson.Safe.to_string found)) in
    let text name=match List.assoc name fields with
      | `String value -> Ok value
      | found -> refuse name "a string" found in
    let number name=match List.assoc name fields with
      | `Int value -> Ok value
      | found -> refuse name "an integer" found in
    let* incarnation=text "incarnation" in
    let* known=text "directory" in
    let* device=number "device" in
    let* inode=number "inode" in
    let* state=text "state" in
    if incarnation<>instance_id then refuse "incarnation" (Printf.sprintf "%S" instance_id) (`String incarnation)
    else if root<>known then refuse "directory" (Printf.sprintf "%S" root) (`String known)
    else (match state with
      | "acquired" -> Ok (Acquired (device,inode))
      | "cleaning" -> Ok (Cleaning (device,inode))
      | "retained" -> Ok (Retained (device,inode))
      | other -> refuse "state" "\"acquired\", \"cleaning\" or \"retained\"" (`String other))
  | Some value -> Error (Printf.sprintf
      "browser socket record %s must be {\"state\":\"released\"} or an object with exactly the keys %s; it is %s"
      file (String.concat ", " socket_record_keys) (Yojson.Safe.to_string value))
let check_retained ~instance_id ~slot context = protect (fun () ->
  let* root=context_of_json ~instance_id context in
  match root with
  | None -> Ok ()
  | Some (root,_automation,_models,stagehand,live_bidi) ->
    let* ()=match stagehand with None -> Ok () | Some c ->
      Browser_addon_stagehand.check_retained_child c ~incarnation:instance_id ~directory:root in
    let* ()=match live_bidi with None -> Ok () | Some c ->
      Browser_addon_live_bidi.check_retained_child c ~incarnation:instance_id ~directory:root in
    let file=record_of_instance instance_id slot in
    let* (_ : acquisition)=acquisition ~instance_id ~root ~file ~directory:slot
      |> Result.map_error (fun detail -> file ^ ": " ^ detail) in
    Ok ())
let cleanup ~admission ~directory = protect (fun () ->
  let* directory=slot admission directory in
  let* status=Native_addon_lease.status admission |> Result.map_error Native_addon_lease.error_to_string in
  let* ()=match status with
    | Native_addon_lease.Settled -> Ok ()
    | Awaiting_exec|Live _|Cleanup_pending _ -> Error "native browser resource cleanup is not settled" in
  let* root=context_path admission in
  match root with
  | None -> Ok Allocation_released
  | Some (root,automation,models,stagehand,live_bidi) ->
    let* ()=match stagehand with None -> Ok () | Some c ->
      Browser_addon_stagehand.settle c ~incarnation:(Native_addon_lease.instance_id admission) ~directory:root in
    let* ()=match live_bidi with None -> Ok () | Some c ->
      Browser_addon_live_bidi.settle c ~incarnation:(Native_addon_lease.instance_id admission) ~directory:root in
    let file=record admission directory in
    let* identity=acquisition ~instance_id:(Native_addon_lease.instance_id admission) ~root ~file ~directory in
    (* The operator took a retained allocation over. Its contents are not read,
       removed or released here. *)
    match identity with Retained _ -> Ok Allocation_retained | Missing|Acquired _|Cleaning _|Released ->
    let* ()=match Unix.lstat root with
      | info ->
        let* ()=private_root root info in
        let* ()=match identity with
          | Released -> Error "released browser socket directory reappeared"
          | Retained _ -> Error "retained browser allocation reached release"
          | Missing ->
            if Sys.readdir root=[||] then Ok ()
            else Error "unconfirmed browser acquisition contains resources"
          | Acquired (device,inode)|Cleaning (device,inode) ->
            if info.st_dev=device && info.st_ino=inode then Ok ()
            else Error (Requirement.replaced ~label:socket_directory_label ~path:root
              ~expected:{Requirement.device;inode} ~observed:(Requirement.identity info)) in
        let confirmed=match identity with Cleaning _ -> true | Missing|Acquired _|Retained _|Released -> false in
        let confirm ()=if confirmed then Ok () else
          Fs_compat.save_file_atomic_strict file
            (Yojson.Safe.to_string (acquired_json admission root info ~state:"cleaning")) in
        let automation=match identity with Missing -> None | Acquired _|Cleaning _|Retained _|Released -> automation in
        let models=match identity with Missing -> None | Acquired _|Cleaning _|Retained _|Released -> models in
        let stagehand=match identity with Missing -> None | Acquired _|Cleaning _|Retained _|Released -> stagehand in
        let live_bidi=match identity with Missing -> None | Acquired _|Cleaning _|Retained _|Released -> live_bidi in
        let* ()=cleanup_contents ~admission ~root ~automation ~models ~stagehand ~live_bidi ~confirmed ~confirm in
        Unix.rmdir root;Ok ()
      | exception Unix.Unix_error (Unix.ENOENT,_,_) ->
        (match identity,Option.is_some automation || Option.is_some stagehand || Option.is_some live_bidi with
         | Acquired _,true -> Error "owned browser allocation vanished without confirmed cleanup"
         | (Missing|Cleaning _|Retained _|Released),_ | Acquired _,false -> Ok ()) in
    sync (Filename.dirname root);
    let* ()=Fs_compat.save_file_atomic_strict file (Yojson.Safe.to_string (`Assoc ["state",`String "released"])) in
    Ok Allocation_released)
let retain ~admission ~directory = protect (fun () ->
  let* directory=slot admission directory in
  let* status=Native_addon_lease.status admission |> Result.map_error Native_addon_lease.error_to_string in
  let* ()=match status with
    | Native_addon_lease.Settled -> Ok ()
    | Awaiting_exec|Live _|Cleanup_pending _ -> Error "native browser resource cleanup is not settled" in
  let* root=context_path admission in
  match root with
  | None -> Ok Allocation_released
  | Some (root,_automation,_models,stagehand,live_bidi) ->
    let incarnation=Native_addon_lease.instance_id admission in
    let* ()=match stagehand with None -> Ok () | Some c ->
      Browser_addon_stagehand.check_settled c ~incarnation ~directory:root in
    let* ()=match live_bidi with None -> Ok () | Some c ->
      Browser_addon_live_bidi.check_settled c ~incarnation ~directory:root in
    let file=record admission directory in
    let* identity=acquisition ~instance_id:incarnation ~root ~file ~directory in
    let retained ~device ~inode =
      let* ()=Fs_compat.save_file_atomic_strict file
        (Yojson.Safe.to_string (allocation_json admission root ~device ~inode ~state:"retained")) in
      Ok Allocation_retained in
    match identity,Unix.lstat root with
    | Released,_ -> Ok Allocation_released
    | Retained _,_ -> Ok Allocation_retained
    | (Acquired (device,inode)|Cleaning (device,inode)),info ->
        let* ()=private_root root info in
        if info.st_dev=device && info.st_ino=inode then retained ~device ~inode
        else Error (Requirement.replaced ~label:socket_directory_label ~path:root
          ~expected:{Requirement.device;inode} ~observed:(Requirement.identity info))
    | Missing,info ->
        let* ()=private_root root info in
        retained ~device:info.st_dev ~inode:info.st_ino
    | exception Unix.Unix_error (Unix.ENOENT,_,_) ->
        (match identity with
         | Acquired (device,inode)|Cleaning (device,inode) -> retained ~device ~inode
         | Retained _ -> Ok Allocation_retained
         | Missing|Released -> Ok Allocation_released))
