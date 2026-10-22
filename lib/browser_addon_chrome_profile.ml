module Requirement = Resource_requirement
type identity = Requirement.identity = { device:int; inode:int }
type persistent = { path:string; root:identity; slot:identity; gate:identity;
  lease:identity; anchor:identity }
type t = Private | Persistent of persistent
let ( let* ) = Result.bind
let path p = p.path
let claim_directory p = Filename.concat p.path ".masc-browser-profile-claim"
let anchor_path path = Filename.concat path ".masc-browser-profile.json"
let protect work = try work () with
  | (Unix.Unix_error _ | Sys_error _ | Yojson.Json_error _) as exn ->
    Error (Printexc.to_string exn)
let identity (info:Unix.stats) = {device=info.st_dev;inode=info.st_ino}
let absolute path = path<>"" && not (Filename.is_relative path) && not (String.contains path '\000')
let profile_label = "Chrome profile"
let slot_label = "Chrome profile claim directory"
let gate_label = "Chrome profile claim gate"
let lease_label = "Chrome profile claim lease"
let anchor_label = "Chrome profile anchor"
let owned ~label ~directory path =
  let* info=Requirement.lstat ~label
    (if directory then Requirement.private_directory else Requirement.private_file) path in
  Ok (identity info)
let id_json id = `Assoc ["device",`Int id.device;"inode",`Int id.inode]
let to_json = function
  | Private -> `Assoc ["kind",`String "private"]
  | Persistent p -> `Assoc ["kind",`String "persistent";"path",`String p.path;
      "root",id_json p.root;"slot",id_json p.slot;"gate",id_json p.gate;
      "lease",id_json p.lease;"anchor",id_json p.anchor]
let of_json = function
  | `Assoc ["kind",`String "private"] -> Ok Private
  | `Assoc fields when List.sort String.compare (List.map fst fields)=
      ["anchor";"gate";"kind";"lease";"path";"root";"slot"] ->
    let* ()=if List.assoc "kind" fields=`String "persistent" then Ok ()
      else Error "unknown Chrome profile lifetime" in
    let* path=match List.assoc "path" fields with
      | `String path when absolute path -> Ok path | _ -> Error "invalid persistent Chrome profile path" in
    let read name=match List.assoc name fields with
      | `Assoc pair when List.sort String.compare (List.map fst pair)=["device";"inode"] ->
        (match List.assoc "device" pair,List.assoc "inode" pair with
         | `Int device,`Int inode -> Ok {device;inode}
         | _ -> Error "invalid Chrome profile resource identity")
      | _ -> Error "invalid Chrome profile resource identity" in
    let* root=read "root" in let* slot=read "slot" in let* gate=read "gate" in
    let* lease=read "lease" in let* anchor=read "anchor" in
    Ok (Persistent {path;root;slot;gate;lease;anchor})
  | _ -> Error "invalid Chrome profile descriptor"
let load_anchor path =
  let* text=Fs_compat.load_owned_regular_file ~ownership_root:path (anchor_path path)
    |> Result.map_error Fs_compat.owned_regular_file_read_error_to_string in
  match text with
  | None -> Ok None
  | Some text -> let* selected=of_json (Yojson.Safe.from_string text) in
    (match selected with Persistent p -> Ok (Some p)
     | Private -> Error "persistent Chrome anchor cannot select a private allocation")
let verify p = protect (fun () ->
  let* ()=Requirement.canonical ~label:profile_label p.path in
  let resources=[profile_label,p.path,true,p.root;slot_label,claim_directory p,true,p.slot;
    gate_label,Filename.concat (claim_directory p) "gate",false,p.gate;
    lease_label,Filename.concat (claim_directory p) "lease",false,p.lease;
    anchor_label,anchor_path p.path,false,p.anchor] in
  let* ()=List.fold_left (fun result (label,path,directory,expected) ->
    let* ()=result in let* observed=owned ~label ~directory path in
    if observed=expected then Ok ()
    else Error (Requirement.replaced ~label ~path ~expected ~observed)) (Ok ()) resources in
  let* anchor=load_anchor p.path in
  let required=Yojson.Safe.to_string (to_json (Persistent p)) in
  match anchor with
  | Some recorded when recorded=p -> Ok ()
  | Some recorded -> Error (Printf.sprintf "%s %s must record %s; it records %s" anchor_label
      (anchor_path p.path) required (Yojson.Safe.to_string (to_json (Persistent recorded))))
  | None -> Error (Printf.sprintf "%s %s must record %s; it is missing" anchor_label (anchor_path p.path) required))
let sync path =
  let fd=Unix.openfile path [Unix.O_RDONLY;Unix.O_CLOEXEC] 0 in
  Fun.protect ~finally:(fun () -> Unix.close fd) (fun () -> Unix.fsync fd)
let bootstrap path root =
  let slot_path=Filename.concat path ".masc-browser-profile-claim" in
  (* Only the creator may complete an absent anchor. A crash between mkdir and
     publication leaves an explicit refusal, never a replacement admission. *)
  Unix.mkdir slot_path 0o700;
  let* prepared=Native_addon_lease.recover_preparation ~directory:slot_path
    |> Result.map_error Native_addon_lease.error_to_string in
  let* ()=match prepared with Unpublished -> Ok ()
    | Current _ -> Error "new Chrome profile slot unexpectedly has admission history" in
  let* slot=owned ~label:slot_label ~directory:true slot_path in
  let* gate=owned ~label:gate_label ~directory:false (Filename.concat slot_path "gate") in
  let* lease=owned ~label:lease_label ~directory:false (Filename.concat slot_path "lease") in
  let fd=Unix.openfile (anchor_path path) [Unix.O_WRONLY;Unix.O_CREAT;Unix.O_EXCL;Unix.O_CLOEXEC] 0o600 in
  let p={path;root;slot;gate;lease;anchor=identity (Unix.fstat fd)} in
  Fun.protect ~finally:(fun () -> Unix.close fd) (fun () ->
    let bytes=Bytes.of_string (Yojson.Safe.to_string (to_json (Persistent p))) in
    let rec write offset=if offset<Bytes.length bytes then
      let count=Unix.write fd bytes offset (Bytes.length bytes-offset) in
      if count=0 then raise (Sys_error "Chrome profile anchor write made no progress")
      else write (offset+count) in
    write 0;Unix.fsync fd);
  sync path;
  let* ()=verify p in Ok p
let select ~path = match path with
  | None -> Ok Private
  | Some selected -> protect (fun () ->
    let* ()=if absolute selected then Ok () else Error "Chrome profile requires an absolute path" in
    let path=Unix.realpath selected in
    let* root=owned ~label:profile_label ~directory:true path in
    let* previous=load_anchor path in
    let* p=match previous with
      | Some p when p.path=path && p.root=root -> let* ()=verify p in Ok p
      | Some _ -> Error "Chrome profile anchor belongs to another directory"
      | None -> bootstrap path root in
    Ok (Persistent p))
let before_launch p =
  let* ()=verify p in
  protect (fun () -> List.fold_left (fun result name ->
    let* ()=result in
    match Unix.lstat (Filename.concat p.path name) with
    | _ -> Error ("Chrome profile still has " ^ name ^ "; close its browser and inspect the original profile without resetting it")
    | exception Unix.Unix_error (Unix.ENOENT,_,_) -> Ok ())
    (Ok ()) ["SingletonLock";"SingletonSocket";"SingletonCookie"])
