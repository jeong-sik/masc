open Result.Syntax
module Requirement = Resource_requirement
(* The one browser source an allocation's worker serves, with the browser it
   starts. Ego's settings ride the worker's arguments, and an external host
   worker starts no browser. *)
type source =
  | Automation of Browser_addon_automation.configuration
  | Stagehand of Browser_addon_stagehand.configuration
  | Owned_firefox of Browser_addon_live_bidi.configuration
  | Ego
  | External_host
let source_backend = function
  | Automation _ -> Browser_lane.Backend.Automation
  | Stagehand _ -> Browser_lane.Backend.Stagehand
  | Owned_firefox _ -> Browser_lane.Backend.Owned_firefox
  | Ego -> Browser_lane.Backend.Ego
  | External_host -> Browser_lane.Backend.External_host
type t = {path:string;incarnation:string;backend:Browser_lane.Backend.t;models:bool;device:int;inode:int}
type acquisition = Missing | Acquired of int * int | Cleaning of int * int | Retained of int * int | Released
type settlement = Allocation_released | Allocation_retained
type cleanup_result =
  | Cleanup_released
  | Cleanup_kept of { directory : string; files : int }
  | Cleanup_retained
let socket_path t = t.path
let arguments t ~max_message_bytes = ["--socket";t.path;"--incarnation";t.incarnation;
  "--max-message-bytes";string_of_int max_message_bytes;"--backend";Browser_lane.Backend.to_wire t.backend]
  @ (if t.models then ["--models"] else [])
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
let source_to_json source =
  let backend=Browser_lane.Backend.to_wire (source_backend source) in
  `Assoc (("backend",`String backend) :: match source with
    | Automation c -> ["configuration",Browser_addon_automation.configuration_to_json c]
    | Stagehand c -> ["configuration",Browser_addon_stagehand.configuration_to_json c]
    | Owned_firefox c -> ["configuration",Browser_addon_live_bidi.configuration_to_json c]
    | Ego | External_host -> [])
let source_of_json = function
  | `Assoc fields ->
    let configuration decode = match List.sort String.compare (List.map fst fields) with
      | ["backend";"configuration"] -> decode (List.assoc "configuration" fields)
      | keys -> Error ("browser source descriptor keys must be backend and configuration; they are "
          ^ String.concat ", " keys) in
    let alone source = match List.map fst fields with
      | ["backend"] -> Ok source
      | keys -> Error ("browser source descriptor of a source without a browser has only backend; it has "
          ^ String.concat ", " keys) in
    (match List.assoc_opt "backend" fields with
     | Some (`String wire) ->
       (match Browser_lane.Backend.of_wire wire with
        | Some Browser_lane.Backend.Automation ->
          let* c=configuration Browser_addon_automation.configuration_of_json in Ok (Automation c)
        | Some Browser_lane.Backend.Stagehand ->
          let* c=configuration Browser_addon_stagehand.configuration_of_json in Ok (Stagehand c)
        | Some Browser_lane.Backend.Owned_firefox ->
          let* c=configuration Browser_addon_live_bidi.configuration_of_json in Ok (Owned_firefox c)
        | Some Browser_lane.Backend.Ego -> alone Ego
        | Some Browser_lane.Backend.External_host -> alone External_host
        | None -> Error ("browser source descriptor backend must be one of " ^ Browser_lane.Backend.expected))
     | Some found -> Error ("browser source descriptor backend must be a string; it is " ^ Yojson.Safe.to_string found)
     | None -> Error "browser source descriptor has no backend")
  | value -> Error ("browser source descriptor must be an object; it is " ^ Yojson.Safe.to_string value)
let context ~instance_id ~source ~models = protect (fun () ->
  let* leaf=leaf instance_id in
  let root=Unix.realpath (Filename.get_temp_dir_name ()) in
  Ok (`Assoc ["kind",`String "browser_socket";"directory",`String (Filename.concat root leaf);
    "source",source_to_json source;
    "models",(match models with None -> `Null | Some configuration -> Browser_addon_models.configuration_to_json configuration)]))
let cleanup_descriptor_label = "native cleanup descriptor"
let cleanup_descriptor_keys = ["directory";"kind";"models";"source"]
let context_envelope_of_json ~instance_id = function
  | None -> Ok None
  | Some (`Assoc fields) when List.sort String.compare (List.map fst fields)=cleanup_descriptor_keys ->
    (match List.assoc "kind" fields,List.assoc "directory" fields with
     | `String "browser_socket",`String root ->
       let* expected=leaf instance_id in
       if Filename.is_relative root || Filename.basename root<>expected
         || Unix.realpath (Filename.dirname root)<>Filename.dirname root then
         Error (Printf.sprintf "browser allocation directory %s must be an absolute path named %s under its own canonical parent"
           root expected)
       else Ok (Some (root,fields))
     | kind,directory ->
       Error (Printf.sprintf "%s must have kind \"browser_socket\" and a string directory; it has kind %s and directory %s"
         cleanup_descriptor_label (Yojson.Safe.to_string kind) (Yojson.Safe.to_string directory)))
  | Some (`Assoc fields) ->
    Error (Requirement.keys ~label:cleanup_descriptor_label ~found:(List.map fst fields) ~required:cleanup_descriptor_keys)
  | Some value ->
    Error (Printf.sprintf "%s must be a JSON object; it is %s" cleanup_descriptor_label (Yojson.Safe.to_string value))
let optional_configuration decode fields name = match List.assoc name fields with
  | `Null -> Ok None
  | value -> decode value |> Result.map Option.some
let decode_source fields = source_of_json (List.assoc "source" fields)
(* Only the source's name, without its configuration: a handoff reads no
   automation or model payload. *)
let decode_backend fields = match List.assoc "source" fields with
  | `Assoc source ->
    (match List.assoc_opt "backend" source with
     | Some (`String wire) ->
       Option.to_result ~none:("browser source descriptor backend must be one of " ^ Browser_lane.Backend.expected)
         (Browser_lane.Backend.of_wire wire)
     | Some found -> Error ("browser source descriptor backend must be a string; it is " ^ Yojson.Safe.to_string found)
     | None -> Error "browser source descriptor has no backend")
  | value -> Error ("browser source descriptor must be an object; it is " ^ Yojson.Safe.to_string value)
let decode_context (root,fields) =
  let* source=decode_source fields in
  let* models=optional_configuration Browser_addon_models.configuration_of_json fields "models" in
  Ok (root,source,models)
let context_envelope admission =
  let* context=Native_addon_lease.cleanup_context admission |> Result.map_error Native_addon_lease.error_to_string in
  context_envelope_of_json ~instance_id:(Native_addon_lease.instance_id admission) context
let context_path admission =
  let* envelope=context_envelope admission in
  match envelope with None -> Ok None | Some envelope -> Result.map Option.some (decode_context envelope)
let slot admission directory =
  let directory=Unix.realpath directory in
  if List.mem directory (Native_addon_lease.directories admission) then
    let* _=Requirement.lstat ~label:"browser claim slot" Requirement.private_directory directory in
    Ok directory
  else Error (Printf.sprintf "browser claim slot %s must be one of its native claim's directories %s"
    directory (String.concat ", " (Native_addon_lease.directories admission)))
let record_of_instance instance_id directory = Filename.concat directory
  ("browser-" ^ Agent_core_sha256.(to_hex (digest_string instance_id)) ^ ".json")
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
  let* root,source,models=Option.to_result ~none:"native reservation has no browser allocation intent" root in
  let file=record admission directory in
  let* ()=match Unix.lstat file with
    | _ -> Error "browser socket resource was already acquired"
    | exception Unix.Unix_error (Unix.ENOENT,_,_) -> Ok () in
  Unix.mkdir root 0o700;
  let info=Unix.lstat root in
  sync root;sync (Filename.dirname root);
  let* ()=Fs_compat.save_file_atomic_strict file (Yojson.Safe.to_string (acquired_json admission root info ~state:"acquired")) in
  let* ()=match source with
    | Automation configuration -> Fs_compat.save_file_atomic_strict (Filename.concat root "automation.json")
        (Yojson.Safe.to_string (Browser_addon_automation.configuration_to_json configuration))
    | Stagehand c -> Fs_compat.save_file_atomic_strict (Filename.concat root "stagehand.json")
        (Yojson.Safe.to_string (Browser_addon_stagehand.configuration_to_json c))
    | Owned_firefox c -> Fs_compat.save_file_atomic_strict (Filename.concat root "live-bidi.json")
        (Yojson.Safe.to_string (Browser_addon_live_bidi.configuration_to_json c))
    | Ego | External_host -> Ok () in
  let* ()=match models with
    | None -> Ok ()
    | Some configuration -> Fs_compat.save_file_atomic_strict (Filename.concat root "models.json")
        (Yojson.Safe.to_string (Browser_addon_models.configuration_to_json configuration)) in
  Ok {path=Filename.concat root "s";incarnation=Native_addon_lease.instance_id admission;
    backend=source_backend source;models=Option.is_some models;
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
(* Only empty download trees may be removed; never recursive rm. Files the
   browser left for the Keeper were moved out before this runs. *)
let rec empty_tree path =
  match Unix.lstat path with
  | info ->
      let* ()=Requirement.check ~label:"owned browser download entry" owned_directory ~path info in
      let* ()=Array.fold_left (fun acc name -> let* ()=acc in empty_tree (Filename.concat path name)) (Ok ()) (Sys.readdir path) in
      Unix.rmdir path;Ok ()
  | exception Unix.Unix_error (Unix.ENOENT,_,_) -> Ok ()
(* Where a browser puts what it leaves for the Keeper rather than for itself:
   the files it downloaded, their host snapshots, and the files it was handed
   to upload. *)
let keeper_file_trees = ["uploads";"download-snapshots";"downloads"]
(* The regular files of this user under [path], in directories of this user.
   A link or any other kind is no Keeper's file, and refuses the count. *)
let rec keeper_files path =
  match Unix.lstat path with
  | exception Unix.Unix_error (Unix.ENOENT,_,_) -> Ok 0
  | info ->
    match info.Unix.st_kind with
    | Unix.S_DIR ->
      let* ()=Requirement.check ~label:"owned browser download entry" owned_directory ~path info in
      Array.fold_left (fun acc name ->
          let* count=acc in
          let* more=keeper_files (Filename.concat path name) in
          Ok (count+more))
        (Ok 0) (Sys.readdir path)
    | Unix.S_REG ->
      let* ()=Requirement.check ~label:"browser download file" socket_record ~path info in
      Ok 1
    | Unix.S_LNK|Unix.S_CHR|Unix.S_BLK|Unix.S_FIFO|Unix.S_SOCK as kind ->
      Error (Printf.sprintf "browser download entry %s is an unexpected %s"
        path (Requirement.kind_name kind))
let keeper_file_count root =
  List.fold_left (fun acc tree ->
      let* count=acc in
      let* more=keeper_files (Filename.concat root tree) in
      Ok (count+more))
    (Ok 0) keeper_file_trees
(* A directory of this user that no group or other user can reach. *)
let kept_directory = {Requirement.kind=Unix.S_DIR;owner=Effective_user;mode=Clear 0o077;links=Any_count}
(* [path] as a [kept_directory], made 0700 if absent; a new entry is synced
   into its parent. *)
let kept_directory_at ~label path =
  let made=match Unix.mkdir path 0o700 with
    | () -> true
    | exception Unix.Unix_error (Unix.EEXIST,_,_) -> false in
  if made then sync (Filename.dirname path);
  Requirement.lstat ~label kept_directory path
(* Runs what follows a move of Keeper files out of an allocation; its failure
   names [into], so the unconfirmed cleanup says where they went. *)
let after_move ~into run =
  protect run |> Result.map_error (fun detail ->
    Printf.sprintf "%s; some or all Keeper files of this allocation were already moved to %s" detail into)
(* Moves each Keeper file tree of [root] into [into] by rename, so every byte
   is kept and nothing is copied or deleted. A kept root on another device
   than the allocation refuses before [into] is made, and a tree already at
   the destination refuses before any tree moves. A rename that fails anyway,
   as across a bind mount, leaves an empty [into]. *)
let move_keeper_files ~kept_root ~into ~root (allocation : Unix.stats) =
  let* kept=kept_directory_at ~label:"kept browser files root" kept_root in
  let* ()=if kept.Unix.st_dev=allocation.Unix.st_dev then Ok ()
    else Error (Printf.sprintf "kept browser files root %s is on another device than %s" kept_root root) in
  let* _=kept_directory_at ~label:"kept browser files" into in
  let trees=List.filter (fun tree -> match Unix.lstat (Filename.concat root tree) with
      | _ -> true
      | exception Unix.Unix_error (Unix.ENOENT,_,_) -> false) keeper_file_trees in
  let* ()=List.fold_left (fun acc tree ->
      let* ()=acc in
      let target=Filename.concat into tree in
      match Unix.lstat target with
      | _ -> Error (Printf.sprintf "kept browser files already hold %s" target)
      | exception Unix.Unix_error (Unix.ENOENT,_,_) -> Ok ())
    (Ok ()) trees in
  let move tree=Unix.rename (Filename.concat root tree) (Filename.concat into tree) in
  match trees with
  | [] -> Ok ()
  | first :: rest ->
    move first;
    after_move ~into (fun () -> List.iter move rest;sync into;sync root;Ok ())
(* What an allocation of [source] may hold besides its socket: the files and
   folders its browser writes. [None] is an allocation whose acquisition was
   never confirmed, which may hold only its socket. *)
let cleanup_contents ~admission ~root ~source ~models ~confirmed ~confirm =
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
  let only allowed what = if List.for_all (fun name -> List.mem name ("s" :: allowed)) names then Ok ()
    else Error (what ^ " allocation contains unknown resources") in
  let* ()=match source with
    | None -> only [] "browser socket"
    | Some (Automation configuration) ->
      let* ()=only ["automation.json";"webdriver.log";"downloads"] "owned browser" in
      let* ()=if confirmed then Ok () else (
        let* spec=read "automation.json" in
        let* actual=Browser_addon_automation.configuration_of_json spec in
        if actual=configuration then Ok () else Error "owned browser configuration changed") in
      empty_tree (Filename.concat root "downloads")
    | Some (Stagehand configuration) ->
      let* ()=only ["stagehand.json";"chromium.log";"chromium-profiles"] "Chrome" in
      let* ()=if confirmed && not (List.mem "stagehand.json" names) then Ok () else
        let* value=read "stagehand.json" in
        let* actual=Browser_addon_stagehand.configuration_of_json value in
        if Browser_addon_stagehand.configuration_to_json actual=Browser_addon_stagehand.configuration_to_json configuration
        then Ok () else Error "Chrome configuration changed" in
      Browser_addon_stagehand.cleanup configuration ~incarnation:(Native_addon_lease.instance_id admission) ~directory:root
    | Some (Owned_firefox configuration) ->
      let* ()=only ["live-bidi.json";"live-firefox.log"] "live BiDi" in
      let* ()=if confirmed && not (List.mem "live-bidi.json" names) then Ok () else
        let* value=read "live-bidi.json" in
        let* actual=Browser_addon_live_bidi.configuration_of_json value in
        if Browser_addon_live_bidi.configuration_to_json actual=Browser_addon_live_bidi.configuration_to_json configuration
        then Ok () else Error "live BiDi configuration changed" in
      Browser_addon_live_bidi.cleanup configuration ~incarnation:(Native_addon_lease.instance_id admission) ~directory:root
    (* Ego's downloads land in this allocation; its browser is ego lite's own. *)
    | Some Ego ->
      let* ()=only ["downloads"] "ego" in
      empty_tree (Filename.concat root "downloads")
    | Some External_host -> only [] "external host" in
  let* ()=confirm () in
  List.fold_left (fun acc name -> let* ()=acc in
    let path=Filename.concat root name in
    let info=Unix.lstat path in
    match info.Unix.st_kind with
    | Unix.S_SOCK when name="s" -> Unix.unlink path;Ok ()
    | Unix.S_REG when List.mem name ["automation.json";"webdriver.log";"models.json";"stagehand.json";"chromium.log";"live-bidi.json";"live-firefox.log"] ->
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
    else let* ()=match root with
      | None -> Error "browser allocation record has no original allocation descriptor"
      | Some root when root=known -> Ok ()
      | Some root -> refuse "directory" (Printf.sprintf "%S" root) (`String known) in
    (match state with
      | "acquired" -> Ok (Acquired (device,inode))
      | "cleaning" -> Ok (Cleaning (device,inode))
      | "retained" -> Ok (Retained (device,inode))
      | other -> refuse "state" "\"acquired\", \"cleaning\" or \"retained\"" (`String other))
  | Some value -> Error (Printf.sprintf
      "browser socket record %s must be {\"state\":\"released\"} or an object with exactly the keys %s; it is %s"
      file (String.concat ", " socket_record_keys) (Yojson.Safe.to_string value))
let no_allocation ~instance_id ~directory =
  let* identity=acquisition ~instance_id ~root:None ~file:(record_of_instance instance_id directory) ~directory in
  match identity with
  | Missing|Released -> Ok ()
  | Acquired _|Cleaning _|Retained _ -> Error "browser allocation record has no original allocation descriptor"
let released_directory_absent root = match Unix.lstat root with
  | _ -> Error "released browser socket directory reappeared"
  | exception Unix.Unix_error (Unix.ENOENT,_,_) -> Ok ()
let check_retained ~instance_id ~slot context = protect (fun () ->
  let* envelope=context_envelope_of_json ~instance_id context in
  match envelope with
  | None -> no_allocation ~instance_id ~directory:slot
  | Some (root,fields) ->
    let file=record_of_instance instance_id slot in
    let* identity=acquisition ~instance_id ~root:(Some root) ~file ~directory:slot
      |> Result.map_error (fun detail -> file ^ ": " ^ detail) in
    match identity with
    | Retained _ -> Ok ()
    | Released -> released_directory_absent root
    | Missing|Acquired _|Cleaning _ ->
    let* _,source,_models=decode_context (root,fields) in
    match source with
    | Stagehand c -> Browser_addon_stagehand.check_retained_child c ~incarnation:instance_id ~directory:root
    | Owned_firefox c -> Browser_addon_live_bidi.check_retained_child c ~incarnation:instance_id ~directory:root
    | Automation _ | Ego | External_host -> Ok ())
let cleanup ~admission ~directory ~kept_root = protect (fun () ->
  let* directory=slot admission directory in
  let* status=Native_addon_lease.status admission |> Result.map_error Native_addon_lease.error_to_string in
  let* ()=match status with
    | Native_addon_lease.Settled -> Ok ()
    | Awaiting_exec|Live _|Cleanup_pending _ -> Error "native browser resource cleanup is not settled" in
  let instance_id=Native_addon_lease.instance_id admission in
  let* envelope=context_envelope admission in
  match envelope with
  | None -> let* ()=no_allocation ~instance_id ~directory in Ok Cleanup_released
  | Some (root,fields) ->
    let file=record admission directory in
    let* identity=acquisition ~instance_id ~root:(Some root) ~file ~directory in
    (* Retain transferred the whole allocation, including its backend payloads.
       Only the original envelope and host record still belong to this check. *)
    match identity with
    | Retained _ -> Ok Cleanup_retained
    | Released -> let* ()=released_directory_absent root in Ok Cleanup_released
    | Missing|Acquired _|Cleaning _ ->
    let* _,source,models=decode_context (root,fields) in
    let* ()=match source with
      | Stagehand c -> Browser_addon_stagehand.settle c ~incarnation:(Native_addon_lease.instance_id admission) ~directory:root
      | Owned_firefox c -> Browser_addon_live_bidi.settle c ~incarnation:(Native_addon_lease.instance_id admission) ~directory:root
      | Automation _ | Ego | External_host -> Ok () in
    let release ()=
      sync (Filename.dirname root);
      Fs_compat.save_file_atomic_strict file (Yojson.Safe.to_string (`Assoc ["state",`String "released"])) in
    match Unix.lstat root with
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
        (* The worker's group and child claims settled and the directory is
           the one acquired. Files the browser left for the Keeper move out
           whole to [kept_root], named for this instance, and the release
           goes on without them. *)
        let into=Filename.concat kept_root instance_id in
        let* moved=match identity with
          | Acquired _|Cleaning _ ->
            let* files=keeper_file_count root in
            if files=0 then Ok None
            else let* ()=move_keeper_files ~kept_root ~into ~root info in Ok (Some files)
          | Missing|Retained _|Released -> Ok None in
        let confirmed=match identity with Cleaning _ -> true | Missing|Acquired _|Retained _|Released -> false in
        let confirm ()=if confirmed then Ok () else
          Fs_compat.save_file_atomic_strict file
            (Yojson.Safe.to_string (acquired_json admission root info ~state:"cleaning")) in
        let source=match identity with Missing -> None | Acquired _|Cleaning _|Retained _|Released -> Some source in
        let models=match identity with Missing -> None | Acquired _|Cleaning _|Retained _|Released -> models in
        let finish ()=
          let* ()=cleanup_contents ~admission ~root ~source ~models ~confirmed ~confirm in
          Unix.rmdir root;release () in
        (match moved with
         | None -> let* ()=finish () in Ok Cleanup_released
         | Some files -> let* ()=after_move ~into finish in Ok (Cleanup_kept {directory=into;files}))
      | exception Unix.Unix_error (Unix.ENOENT,_,_) ->
        (* A source that starts a browser keeps its resources in the
           allocation; one acquired and gone was never confirmed released. *)
        let starts_browser=match source with
          | Automation _ | Stagehand _ | Owned_firefox _ -> true | Ego | External_host -> false in
        (match identity,starts_browser with
         | Acquired _,true -> Error "owned browser allocation vanished without confirmed cleanup"
         | (Missing|Cleaning _|Retained _|Released),_ | Acquired _,false ->
           let* ()=release () in Ok Cleanup_released))
type retain_error = Retain_refused of string | Retained_record_unconfirmed of string
(* What [retain] decided before writing anything. *)
type retain_plan =
  | Already of settlement
  | Write_retained of { file : string; root : string; device : int; inode : int }
let retain_with ~(save:string -> string -> (unit, Fs_compat.atomic_replace_failure) result) ~admission ~directory =
  let plan = protect (fun () ->
    let* directory=slot admission directory in
    let* status=Native_addon_lease.status admission |> Result.map_error Native_addon_lease.error_to_string in
    let* ()=match status with
      | Native_addon_lease.Settled -> Ok ()
      | Awaiting_exec|Live _|Cleanup_pending _ -> Error "native browser resource cleanup is not settled" in
    let incarnation=Native_addon_lease.instance_id admission in
    let* envelope=context_envelope admission in
    match envelope with
    | None -> let* ()=no_allocation ~instance_id:incarnation ~directory in Ok (Already Allocation_released)
    | Some (root,fields) ->
      let file=record admission directory in
      let* identity=acquisition ~instance_id:incarnation ~root:(Some root) ~file ~directory in
      match identity with
      | Retained _ -> Ok (Already Allocation_retained)
      | Released -> let* ()=released_directory_absent root in Ok (Already Allocation_released)
      | Missing|Acquired _|Cleaning _ ->
      (* Without any acquisition or handoff record, only the full current
         descriptor can justify reporting an absent allocation as released. *)
      let* ()=match identity with
        | Missing -> let* _=decode_context (root,fields) in Ok ()
        | Acquired _|Cleaning _|Retained _|Released -> Ok () in
      (* Only a source with a child claim is decoded, to confirm that claim
         settled. *)
      let* backend=decode_backend fields in
      let* ()=match backend with
        | Browser_lane.Backend.(Automation|Ego|External_host) -> Ok ()
        | Browser_lane.Backend.(Stagehand|Owned_firefox) ->
          let* source=decode_source fields in
          (match source with
           | Stagehand c -> Browser_addon_stagehand.check_settled c ~incarnation ~directory:root
           | Owned_firefox c -> Browser_addon_live_bidi.check_settled c ~incarnation ~directory:root
           | Automation _ | Ego | External_host ->
             Error "browser source descriptor names one backend and decodes as another") in
      let retained ~device ~inode = Ok (Write_retained {file;root;device;inode}) in
      match identity,Unix.lstat root with
      | Released,_ -> Ok (Already Allocation_released)
      | Retained _,_ -> Ok (Already Allocation_retained)
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
           | Retained _ -> Ok (Already Allocation_retained)
           | Missing|Released -> Ok (Already Allocation_released))) in
  match plan with
  | Error detail -> Error (Retain_refused detail)
  | Ok (Already settlement) -> Ok settlement
  | Ok (Write_retained {file;root;device;inode}) ->
    (* A failure after the rename leaves the record replaced; only a failure
       before it says nothing changed. *)
    match save file (Yojson.Safe.to_string (allocation_json admission root ~device ~inode ~state:"retained")) with
    | Ok () -> Ok Allocation_retained
    | Error ({stage=Fs_compat.Before_rename;_} as failure) ->
        Error (Retain_refused ("the retained record was not written: " ^ Fs_compat.atomic_replace_failure_to_string failure))
    | Error ({stage=Fs_compat.After_rename;_} as failure) ->
        Error (Retained_record_unconfirmed (Fs_compat.atomic_replace_failure_to_string failure))
    | exception ((Unix.Unix_error _|Sys_error _) as exn) -> Error (Retained_record_unconfirmed (Printexc.to_string exn))
let retain ~admission ~directory = retain_with ~save:Fs_compat.save_file_atomic_strict_staged ~admission ~directory
module For_testing = struct
  let retain = retain_with
end
