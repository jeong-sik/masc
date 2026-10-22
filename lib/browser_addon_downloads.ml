module B = Browser_lane
let ( let* ) = Result.bind
type descriptor = {snapshot_id:string;root_device:int;root_inode:int;
  device:int;inode:int;bytes:int;sha256:string}
type claim = Snapshot of descriptor | Published of Yojson.Safe.t
type snapshot = {descriptor:descriptor;source:string;source_stat:Unix.stats;
  parents:(string * Unix.stats) list;mutable source_fd:Unix.file_descr option;
  mutable published:Yojson.Safe.t option}
type grant_state = Pending | Claimed | Committed of Yojson.Safe.t
  | Settled of Yojson.Safe.t | Released
type grant = {snapshot:snapshot;actor:string;route:B.route;verb:B.verb;
  mutable state:grant_state}
type t = {directory:string;allocation:Unix.stats;root:string;root_stat:Unix.stats;
  mutex:Mutex.t;changed:Condition.t;cleanup_mutex:Mutex.t;mutable serving:bool;
  mutable preparing:int;mutable settled:bool;mutable failure:string option;
  snapshots:(string,snapshot) Hashtbl.t;grants:(string,grant) Hashtbl.t}
let locked t f = Mutex.lock t.mutex;Fun.protect ~finally:(fun () -> Mutex.unlock t.mutex) f
let io f = try f () with
  | (Unix.Unix_error _|Sys_error _) as exn -> Error (Printexc.to_string exn)
let uuid value = match Uuidm.of_string value with
  | Some id when Uuidm.to_string id=value -> Ok value
  | None|Some _ -> Error "download identifier must be a canonical UUID"
let fresh_id () = Uuidm.(to_string (v4_gen (Random.State.make_self_init ()) ()))
let snapshot_path ~directory ~snapshot_id =
  let* id=uuid snapshot_id in
  Ok (Filename.concat (Filename.concat directory "download-snapshots") (id ^ ".bin"))
let exact names = function
  | `Assoc fields when List.sort String.compare (List.map fst fields)=List.sort String.compare names -> Ok fields
  | `Assoc _|`Null|`Bool _|`Int _|`Intlit _|`Float _|`String _|`List _ -> Error "invalid download broker fields"
let string fields name = match List.assoc_opt name fields with
  | Some (`String value) -> Ok value | None|Some _ -> Error ("missing download " ^ name)
let integer fields name = match List.assoc_opt name fields with
  | Some (`Int value) when value>=0 -> Ok value | None|Some _ -> Error ("invalid download " ^ name)
let descriptor_to_json d = `Assoc ["snapshotId",`String d.snapshot_id;
  "rootDevice",`Int d.root_device;"rootInode",`Int d.root_inode;
  "device",`Int d.device;"inode",`Int d.inode;"bytes",`Int d.bytes;"sha256",`String d.sha256]
let descriptor_of_json json =
  let* fields=exact ["snapshotId";"rootDevice";"rootInode";"device";"inode";"bytes";"sha256"] json in
  let* snapshot_id=string fields "snapshotId" in let* snapshot_id=uuid snapshot_id in
  let* root_device=integer fields "rootDevice" in let* root_inode=integer fields "rootInode" in
  let* device=integer fields "device" in let* inode=integer fields "inode" in
  let* bytes=integer fields "bytes" in let* sha256=string fields "sha256" in
  let* ()=Tool_output.validate_sha256 sha256 |> Result.map_error Tool_output.invalid_sha256_to_string in
  Ok {snapshot_id;root_device;root_inode;device;inode;bytes;sha256}
let publication receipt =
  let* receipt=Lane_addon_action.canonical receipt in
  let* fields=exact ["reference";"reader";"arguments";"bytes"] receipt in
  let* reference=match Tool_output.normalized_artifact_ref_of_json (List.assoc "reference" fields) with
    | Tool_output.Decoded_normalized_artifact_ref reference -> Ok reference
    | Not_normalized_artifact_ref|Invalid_normalized_artifact_ref _ -> Error "download commit lacks a valid artifact reference" in
  let* args=exact ["sha256"] (List.assoc "arguments" fields) in
  if List.assoc "reader" fields=`String "keeper_artifact_read"
    && List.assoc "bytes" fields=`Int reference.bytes && List.assoc "sha256" args=`String reference.sha256
  then Ok (receipt,reference) else Error "inconsistent download artifact receipt"
let claim_to_json = function
  | Snapshot descriptor -> `Assoc ["kind",`String "snapshot";"descriptor",descriptor_to_json descriptor]
  | Published receipt -> `Assoc ["kind",`String "published";"receipt",receipt]
let claim_of_json json =
  let* fields=match json with `Assoc fields -> Ok fields
    | `Null|`Bool _|`Int _|`Intlit _|`Float _|`String _|`List _ -> Error "invalid download claim" in
  match List.assoc_opt "kind" fields with
  | Some (`String "snapshot") -> let* fields=exact ["kind";"descriptor"] json in
      let* descriptor=descriptor_of_json (List.assoc "descriptor" fields) in Ok (Snapshot descriptor)
  | Some (`String "published") -> let* fields=exact ["kind";"receipt"] json in
      let* receipt,_=publication (List.assoc "receipt" fields) in Ok (Published receipt)
  | None|Some _ -> Error "unknown download claim kind"
let same_identity (a:Unix.stats) (b:Unix.stats) =
  a.st_dev=b.st_dev && a.st_ino=b.st_ino && a.st_kind=b.st_kind
let same_file a b = same_identity a b && a.Unix.st_size=b.Unix.st_size
  && a.st_mtime=b.st_mtime && a.st_ctime=b.st_ctime && a.st_nlink=b.st_nlink
  && a.st_uid=b.st_uid && a.st_perm=b.st_perm
let file_observation (stat:Unix.stats) = `Assoc [
  "device",`Int stat.st_dev;"inode",`Int stat.st_ino;
  "kind",`String (match stat.st_kind with
    | Unix.S_REG -> "regular" | S_DIR -> "directory" | S_CHR -> "character"
    | S_BLK -> "block" | S_LNK -> "link" | S_FIFO -> "fifo" | S_SOCK -> "socket");
  "bytes",`Int stat.st_size;"mtime",`Float stat.st_mtime;"ctime",`Float stat.st_ctime;
  "links",`Int stat.st_nlink;"uid",`Int stat.st_uid;"permissions",`Int stat.st_perm]
let changed_source_message snapshot observed =
  "original completed download identity changed: " ^ Yojson.Safe.to_string (`Assoc [
    "snapshotId",`String snapshot.descriptor.snapshot_id;
    "expected",file_observation snapshot.source_stat;
    "observed",file_observation observed])
let private_directory path =
  let info=Unix.lstat path in
  if info.Unix.st_kind=Unix.S_DIR && info.st_uid=Unix.geteuid ()
    && info.st_perm=0o700 && Unix.realpath path=path then Ok info
  else Error "download allocation is not a canonical private directory"
let check t =
  let* allocation=private_directory t.directory in let* root=private_directory t.root in
  if same_identity allocation t.allocation && same_identity root t.root_stat then Ok ()
  else Error "download allocation identity changed"
let create ~directory = io (fun () ->
  let* allocation=private_directory directory in
  let root=Filename.concat directory "download-snapshots" in Unix.mkdir root 0o700;
  let* root_stat=private_directory root in
  Ok {directory;allocation;root;root_stat;mutex=Mutex.create ();changed=Condition.create ();
    cleanup_mutex=Mutex.create ();serving=true;preparing=0;settled=false;failure=None;
    snapshots=Hashtbl.create 8;grants=Hashtbl.create 8})
let remember_failure t detail = locked t (fun () ->
  match t.failure with None -> t.failure<-Some detail | Some _ -> ())
let close_pin snapshot = match snapshot.source_fd with
  | None -> Ok ()
  | Some fd -> snapshot.source_fd<-None;io (fun () -> Unix.close fd;Ok ())
let close_pins snapshots = List.fold_left (fun result snapshot ->
  let closed=close_pin snapshot in
  match result,closed with Error detail,_ | Ok (),Error detail -> Error detail
    | Ok (),Ok () -> Ok ()) (Ok ()) snapshots
let source_parents t path =
  let downloads=Filename.concat t.directory "downloads" in
  let rec collect current acc =
    let stat=Unix.lstat current in
    if stat.Unix.st_kind<>Unix.S_DIR || stat.st_uid<>Unix.geteuid () || stat.st_perm land 0o022<>0
    then Error "download source parent is not owned" else
    let acc=(current,stat)::acc in
    if current=downloads then Ok acc
    else let parent=Filename.dirname current in
      if parent=current || current=t.directory then Error "download source is outside session downloads"
      else collect parent acc in
  collect (Filename.dirname path) []
let check_parents parents = List.fold_left (fun result (path,expected) ->
  let* ()=result in let current=Unix.lstat path in
  if same_identity current expected && current.st_uid=expected.Unix.st_uid
    && current.st_perm=expected.st_perm then Ok () else Error "download source parent identity changed") (Ok ()) parents
let write_all fd buffer count =
  let rec loop offset = if offset<count then
    let written=Unix.write fd buffer offset (count-offset) in
    if written=0 then raise (Sys_error "download snapshot write made no progress") else loop (offset+written) in
  loop 0
let copy t path id = io (fun () ->
  let* ()=check t in
  let* ()=if Unix.realpath path=path then Ok () else Error "download source must be canonical" in
  let* parents=source_parents t path in
  let before=Unix.lstat path in
  let* ()=if before.Unix.st_kind=Unix.S_REG && before.st_uid=Unix.geteuid () && before.st_nlink=1
    then Ok () else Error "download source is not an owned regular file" in
  let source=Unix.openfile path [Unix.O_RDONLY;Unix.O_CLOEXEC;Unix.O_NONBLOCK] 0 in
  let transferred=ref false in
  Fun.protect ~finally:(fun () -> if not !transferred then Unix.close source) (fun () ->
    let observed=Unix.fstat source in
    let* ()=if same_file before observed then Ok () else Error "download source identity changed" in
    let* target=snapshot_path ~directory:t.directory ~snapshot_id:id in
    let output=Unix.openfile target [Unix.O_WRONLY;Unix.O_CREAT;Unix.O_EXCL;Unix.O_CLOEXEC] 0o600 in
    let result=Fun.protect ~finally:(fun () -> Unix.close output) (fun () ->
      let buffer=Bytes.create Sys.io_buffer_size in
      let rec stream digest bytes = match Unix.read source buffer 0 (Bytes.length buffer) with
        | 0 -> Digestif.SHA256.(to_hex (get digest)),bytes
        | count -> write_all output buffer count;
            stream (Digestif.SHA256.feed_bytes digest ~off:0 ~len:count buffer) (bytes+count) in
      let sha256,bytes=stream Digestif.SHA256.empty 0 in
      Unix.fsync output;
      let* ()=check t in let* ()=check_parents parents in
      let* ()=if same_file before (Unix.fstat source) && same_file before (Unix.lstat path)
        && bytes=before.st_size then Ok () else Error "download source changed while copying" in
      let copied=Unix.fstat output in
      let descriptor={snapshot_id=id;root_device=t.root_stat.st_dev;root_inode=t.root_stat.st_ino;
        device=copied.st_dev;inode=copied.st_ino;bytes;sha256} in
      Ok {descriptor;source=path;source_stat=before;parents;source_fd=Some source;published=None}) in
    (match result with Ok _ -> transferred:=true | Error _ -> ());result))
let publish t path =
  let* ()=locked t (fun () -> if not t.serving then Error "download broker is retired"
    else (t.preparing<-t.preparing+1;Ok ())) in
  Fun.protect ~finally:(fun () -> locked t (fun () -> t.preparing<-t.preparing-1;Condition.broadcast t.changed)) (fun () ->
    let id=fresh_id () in
    match copy t path id with
    | Error detail -> remember_failure t detail;Error detail
    | Ok snapshot ->
        let registered=ref false in
        Fun.protect ~finally:(fun () ->
          if not !registered then match close_pin snapshot with
            | Ok () -> () | Error detail -> remember_failure t detail) (fun () ->
          locked t (fun () ->
            Hashtbl.add t.snapshots id snapshot;registered:=true;
            if not t.serving then Error "download broker retired during preparation"
            else Ok (`Assoc ["downloadSnapshot",`String id]))))
let allowed route verb = match route,verb with
  | B.Automation_route,B.Page_downloads _ -> Ok ()
  | (B.Live_route _|Stagehand_route),(B.Page_downloads _)
  | (B.Live_route _|Automation_route|Stagehand_route),
    (B.Tabs_list|Page_read _|Page_document _|Page_capture _|Page_scene _|Page_interact _
    |Session_open _|Session_close|Session_status|Page_goto _|Page_elements _|Page_act _
    |Page_context _|Page_instruct _|Page_locate _|Page_extract _) -> Error "download grants require owned automation downloads"
let bind t ~actor ~route ~verb payload =
  let* ()=allowed route verb in let* payload=Lane_addon_action.canonical payload in
  locked t (fun () -> if not t.serving then Error "download broker is retired" else
    let* fields=match payload with `Assoc fields -> Ok fields
      | `Null|`Bool _|`Int _|`Intlit _|`Float _|`String _|`List _ -> Error "download observation must be an object" in
    let* rows=match List.assoc_opt "downloads" fields with Some (`List rows) -> Ok rows
      | None|Some _ -> Error "download observation lacks rows" in
    let bind_row row =
      let* fields=match row with `Assoc fields -> Ok fields
        | `Null|`Bool _|`Int _|`Intlit _|`Float _|`String _|`List _ -> Error "download row must be an object" in
      let* artifact=match List.assoc_opt "artifact" fields with
        | None -> Ok None
        | Some marker ->
          let* marker=exact ["downloadSnapshot"] marker in
          let* id=string marker "downloadSnapshot" in let* id=uuid id in
          let* snapshot=match Hashtbl.find_opt t.snapshots id with Some snapshot -> Ok snapshot
            | None -> Error "download snapshot does not belong to this worker" in
          let id=fresh_id () in Hashtbl.add t.grants id {snapshot;actor;route;verb;state=Pending};
          Ok (Some (`Assoc ["downloadGrant",`String id])) in
      Ok (`Assoc (List.filter_map (fun (name,value) ->
        if name="path" then None else if name="artifact" then Option.map (fun value -> name,value) artifact
        else Some (name,value)) fields)) in
    let* rows=List.fold_left (fun result row -> let* rows=result in let* row=bind_row row in Ok (row::rows)) (Ok []) rows in
    Ok (`Assoc (List.map (fun (name,value) -> name,(if name="downloads" then `List (List.rev rows) else value)) fields)))
let find t ~id ~actor ~route ~verb =
  let* _=uuid id in match Hashtbl.find_opt t.grants id with
  | Some grant when grant.actor=actor && grant.route=route && grant.verb=verb -> Ok grant
  | None|Some _ -> Error "download grant is absent or belongs to another call"
let claim t ~id ~actor ~route ~verb = locked t (fun () ->
  let* grant=find t ~id ~actor ~route ~verb in
  match grant.state with
  | Claimed|Committed _|Released -> Error "download grant is already claimed or released"
  | Settled receipt -> Ok (Published receipt)
  | Pending when not t.serving -> Error "download broker is retired"
  | Pending -> grant.state<-Claimed;
      Ok (match grant.snapshot.published with Some receipt -> Published receipt
        | None -> Snapshot grant.snapshot.descriptor))
let receipt_for snapshot receipt =
  let* receipt,reference=publication receipt in
  if reference.sha256=snapshot.descriptor.sha256 && reference.bytes=snapshot.descriptor.bytes
  then Ok receipt else Error "download artifact does not match its original snapshot"
let commit t ~id ~actor ~route ~verb ~receipt = locked t (fun () ->
  let* grant=find t ~id ~actor ~route ~verb in let* receipt=receipt_for grant.snapshot receipt in
  let* ()=match grant.snapshot.published with
    | Some previous when previous<>receipt -> Error "download snapshot already has another publication"
    | None|Some _ -> Ok () in
  match grant.state with
  | Pending|Released -> Error "download grant has no existing claim"
  | Committed previous|Settled previous -> if previous=receipt then Ok () else Error "download grant commit changed"
  | Claimed -> grant.snapshot.published<-Some receipt;grant.state<-Committed receipt;
      Condition.broadcast t.changed;Ok ())
let release t ~id ~actor ~route ~verb = locked t (fun () ->
  let* grant=find t ~id ~actor ~route ~verb in
  (match grant.state with Pending|Claimed -> grant.state<-Released
    | Committed receipt -> grant.state<-Settled receipt
    | Settled _|Released -> ());Condition.broadcast t.changed;Ok ())
let revoke t = locked t (fun () -> t.serving<-false)
let rec empty_downloads path =
  match Unix.lstat path with
  | stat when stat.Unix.st_kind=Unix.S_DIR && stat.st_uid=Unix.geteuid () ->
      Array.fold_left (fun result name -> let* ()=result in
        empty_downloads (Filename.concat path name)) (Ok ()) (Sys.readdir path)
  | _ -> Error "session downloads contain an unpublished or unknown resource"
  | exception Unix.Unix_error (Unix.ENOENT,_,_) -> Ok ()
let original_digest fd bytes =
  ignore (Unix.lseek fd 0 Unix.SEEK_SET);
  let buffer=Bytes.create Sys.io_buffer_size in
  let rec stream remaining digest =
    if remaining=0 then
      if Unix.read fd buffer 0 1=0 then Ok Digestif.SHA256.(to_hex (get digest))
      else Error "original completed download has extra bytes"
    else match Unix.read fd buffer 0 (min remaining (Bytes.length buffer)) with
      | 0 -> Error "original completed download was truncated"
      | count -> stream (remaining-count) (Digestif.SHA256.feed_bytes digest ~off:0 ~len:count buffer) in
  stream bytes Digestif.SHA256.empty
let remove_original t snapshot =
  match Unix.lstat snapshot.source with
  | current ->
      let* fd=Option.to_result ~none:"original completed download descriptor is closed" snapshot.source_fd in
      let before=Unix.fstat fd in
      let* ()=if same_identity before snapshot.source_stat && before.st_kind=Unix.S_REG
          && before.st_uid=snapshot.source_stat.st_uid && before.st_perm=snapshot.source_stat.st_perm
          && before.st_nlink=1 && before.st_size=snapshot.descriptor.bytes && same_file before current
        then Ok () else Error (changed_source_message snapshot current) in
      let* digest=original_digest fd snapshot.descriptor.bytes in
      let* ()=if digest=snapshot.descriptor.sha256 then Ok ()
        else Error "original completed download contents changed" in
      let* ()=check t in let* ()=check_parents snapshot.parents in
      let after=Unix.fstat fd and current=Unix.lstat snapshot.source in
      if same_file before after && same_file before current
      then (Unix.unlink snapshot.source;Ok ())
      else Error (changed_source_message snapshot current)
  | exception Unix.Unix_error (Unix.ENOENT,_,_) -> Ok ()
type retirement = Remove_published | Preserve_files
let retire t retirement =
  let result=io (fun () ->
  Mutex.lock t.cleanup_mutex;
  Fun.protect ~finally:(fun () -> Mutex.unlock t.cleanup_mutex) (fun () ->
    if t.settled then (match Unix.lstat t.root with
      | _ -> Error "settled download root reappeared"
      | exception Unix.Unix_error (Unix.ENOENT,_,_) -> Ok ()) else (
    let snapshots,failure=locked t (fun () ->
      t.serving<-false;
      while t.preparing>0 do Condition.wait t.changed t.mutex done;
      (* A remote holder may never settle. Observe deletion authority under the
         grant lock rather than waiting for it; no files may be deleted unless
         every existing claim has settled. Preserve grant states on refusal. *)
      (match t.failure,retirement with
      | Some _,(Remove_published|Preserve_files) | None,Preserve_files -> ()
      | None,Remove_published ->
          let held=Hashtbl.fold (fun _ grant held ->
            match grant.state with Claimed|Committed _ -> true
              | Pending|Settled _|Released -> held) t.grants false in
          if held then t.failure<-Some "download cleanup has unsettled consumer claims");
      Hashtbl.fold (fun _ snapshot acc -> snapshot::acc) t.snapshots [],t.failure) in
    let result=ref (Error "download cleanup did not settle") in
    let ()=Fun.protect ~finally:(fun () ->
      let closed=close_pins snapshots in
      result:=(match !result,closed with
        | Error detail,_ | Ok (),Error detail -> Error detail
        | Ok (),Ok () -> Ok ());
      (* Publish the result before releasing cleanup ownership or reusing any
         consumed descriptor number. Every pin is closed even on failure. *)
      match !result with
      | Error detail -> remember_failure t detail
      | Ok () -> t.settled<-true) (fun () ->
    result:=io (fun () ->
    let* ()=match failure with None -> Ok ()|Some detail -> Error detail in
    let* ()=match retirement with Remove_published -> Ok ()
      | Preserve_files -> Error "download cleanup requires confirmed backend teardown" in
    let* ()=check t in
    let cleanup_snapshot snapshot =
      let* ()=match snapshot.published with None -> Error "download snapshot was not durably published"
        | Some _ -> Ok () in
      let* ()=check_parents snapshot.parents in
      let* ()=remove_original t snapshot in
      let* path=snapshot_path ~directory:t.directory ~snapshot_id:snapshot.descriptor.snapshot_id in
      match Unix.lstat path with
      | stat when stat.Unix.st_dev=snapshot.descriptor.device && stat.st_ino=snapshot.descriptor.inode
          && stat.st_kind=Unix.S_REG && stat.st_size=snapshot.descriptor.bytes
          && stat.st_uid=Unix.geteuid () && stat.st_perm=0o600 && stat.st_nlink=1 -> Unix.unlink path;Ok ()
      | _ -> Error "download snapshot identity changed"
      | exception Unix.Unix_error (Unix.ENOENT,_,_) -> Ok () in
    (* One snapshot's failure must not skip the rest: attempt each snapshot and
       report the failures once, leaving only failed items behind. *)
    let failures=List.fold_left (fun failures snapshot ->
      match io (fun () -> cleanup_snapshot snapshot) with
      | Ok () -> failures | Error detail -> detail::failures) [] snapshots in
    match failures with
    | _::_ -> Error (String.concat "; " (List.rev failures))
    | [] ->
        let* ()=empty_downloads (Filename.concat t.directory "downloads") in
        if Sys.readdir t.root<>[||] then Error "download root contains unknown or partial files"
        else (Unix.rmdir t.root;Ok ()))) in
    !result))) in
  (match result with Ok () -> ()|Error detail -> remember_failure t detail);
  result
let cleanup t = retire t Remove_published
let abandon t = retire t Preserve_files
