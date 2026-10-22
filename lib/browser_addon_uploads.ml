module B = Browser_lane
module Lease = B.Upload_lease
module Requirement = Resource_requirement
let ( let* ) = Result.bind
type grant = {actor:string;route:B.route;verb:B.verb;snapshot:Lease.snapshot}
type preparation = Staging | Withdrawn
type state = Preparing of preparation | Pending of grant | Claimed | Releasing
  | Release_failed of string | Consumed
type t = {directory:string;device:int;inode:int;mutex:Mutex.t;changed:Condition.t;
  cleanup_mutex:Mutex.t;mutable settled:bool;
  mutable serving:bool;grants:(string,state) Hashtbl.t}
let locked t f = Mutex.lock t.mutex;Fun.protect ~finally:(fun () -> Mutex.unlock t.mutex) f
let protect f = try f () with
  | (Unix.Unix_error _|Sys_error _) as exn -> Error (Printexc.to_string exn)
let uploads_label = "upload directory"
let private_directory ~label path =
  let* info=Requirement.lstat ~label Requirement.private_directory path in
  let* ()=Requirement.canonical ~label path in Ok info
let check t =
  let* info=private_directory ~label:uploads_label t.directory in
  if info.Unix.st_dev=t.device && info.st_ino=t.inode then Ok ()
  else Error "upload allocation identity changed"
let create ~directory = protect (fun () ->
  let* _=private_directory ~label:"browser allocation directory" directory in
  let directory=Filename.concat directory "uploads" in
  Unix.mkdir directory 0o700;
  let info=Unix.lstat directory in
  Ok {directory;device=info.st_dev;inode=info.st_ino;mutex=Mutex.create ();
    changed=Condition.create ();cleanup_mutex=Mutex.create ();settled=false;
    serving=true;grants=Hashtbl.create 4})
let source path = protect (fun () ->
  let before=Unix.lstat path in
  let* ()=Requirement.check ~label:"upload source" Requirement.private_file ~path before in
  let fd=Unix.openfile path [Unix.O_RDONLY;Unix.O_CLOEXEC;Unix.O_NONBLOCK] 0 in
  Fun.protect ~finally:(fun () -> Unix.close fd) (fun () ->
    let info=Unix.fstat fd in
    if info.st_dev<>before.st_dev || info.st_ino<>before.st_ino || info.st_kind<>Unix.S_REG
      || info.st_uid<>before.st_uid || info.st_nlink<>1 || info.st_perm<>0o600
    then Error "upload source identity changed"
    else if info.st_size>Lease.max_file_bytes then Error "upload source exceeds the per-file resource bound"
    else
      let bytes=Bytes.create info.st_size in
      let rec read offset =
        if offset=Bytes.length bytes then Ok ()
        else match Unix.read fd bytes offset (Bytes.length bytes-offset) with
          | 0 -> Error "upload source shortened during copy"
          | count -> read (offset+count) in
      let* ()=read 0 in
      let after=Unix.fstat fd in
      if after.st_size<>info.st_size || after.st_mtime<>info.st_mtime
        || after.st_ctime<>info.st_ctime then Error "upload source changed during copy"
      else Ok (Bytes.to_string bytes)))
let upload_paths = function
  | B.Page_act (B.Action.On_tab {interaction=B.Action.Upload {paths;_};_}) -> Ok paths
  | Tabs_list|Page_read _|Page_document _|Page_downloads _ | Page_console _ | Page_network _ | Page_cookies _|Page_capture _|Page_scene _|Page_interact _
  | Session_open _|Session_close|Session_status|Page_goto _|Page_elements _
  | Page_act (Open_tab _|On_tab {interaction=Click _|Fill _|Press _|Scroll _|Select _|Close_tab|Back|Forward|Reload|Accept_dialog _|Dismiss_dialog;_})
  | Page_context _|Page_instruct _|Page_locate _|Page_extract _ -> Error "grant requires one upload command"
let release_failed t ~id exn =
  let backtrace=Printexc.get_raw_backtrace () in
  locked t (fun () ->
    Hashtbl.replace t.grants id (Release_failed (Printexc.to_string exn));
    Condition.broadcast t.changed);
  Printexc.raise_with_backtrace exn backtrace
let release t ~id snapshot =
  let finish state=locked t (fun () ->
    Hashtbl.replace t.grants id state;Condition.broadcast t.changed) in
  match Lease.release snapshot with
  | () -> finish Consumed
  | exception exn -> release_failed t ~id exn

let stage t ~id ~actor ~route ~verb = protect (fun () ->
  let* _=B.client_id_of_string id in
  let* ()=match route with B.Automation_route -> Ok ()
    | Live_route _|Stagehand_route -> Error "this upload broker requires the owned Gecko backend" in
  let* paths=upload_paths verb in
  let* ()=locked t (fun () ->
    if not t.serving then Error "upload broker is retired"
    else if Hashtbl.mem t.grants id then Error "upload grant id already used"
    else (Hashtbl.add t.grants id (Preparing Staging);Ok ())) in
  Fun.protect ~finally:(fun () -> locked t (fun () ->
    (match Hashtbl.find_opt t.grants id with
     | Some (Preparing _) -> Hashtbl.replace t.grants id Consumed
     | None|Some (Pending _|Claimed|Releasing|Release_failed _|Consumed) -> ());
    Condition.broadcast t.changed)) (fun () ->
    let* ()=check t in
    let files=List.map (fun path -> Filename.basename path,(fun () -> source path)) paths in
    let* snapshot=(match Lease.prepare_files ~temp_dir:t.directory ~files () with
      | result -> result
      | exception exn -> release_failed t ~id exn) |> Result.map_error (function
      | Lease.Read_failed detail|Snapshot_failed detail -> detail) in
    let published=ref false in
    Fun.protect ~finally:(fun () -> if not !published then release t ~id snapshot) (fun () ->
      let* ()=check t in
      locked t (fun () ->
        if not t.serving || Hashtbl.find_opt t.grants id<>Some (Preparing Staging)
        then Error "upload grant retired during staging"
        else (Hashtbl.replace t.grants id (Pending {actor;route;verb;snapshot});
          published:=true;Ok ())))))


let with_claim t ~id ~actor ~route ~verb f =
  let grant=locked t (fun () ->
    if not t.serving then Error "upload broker is retired" else
    match Hashtbl.find_opt t.grants id with
    | Some (Pending grant) when grant.actor=actor && grant.route=route && grant.verb=verb ->
        Hashtbl.replace t.grants id Claimed;Ok grant
    | None|Some (Preparing _|Pending _|Claimed|Releasing|Release_failed _|Consumed) -> Error "upload grant is absent, consumed or belongs to another command") in
  let* grant=grant in
  let finish () = Eio.Cancel.protect (fun () ->
    Eio_unix.run_in_systhread (fun () -> release t ~id grant.snapshot)) in
  Fun.protect ~finally:finish (fun () ->
    let* ()=protect (fun () -> check t) in
    match verb with
    | B.Page_act (B.Action.On_tab ({interaction=Upload {selector;_};_} as target)) ->
        Ok (f (B.Page_act (B.Action.On_tab {target with interaction=Upload {selector;paths=Lease.paths grant.snapshot}})))
    | Tabs_list|Page_read _|Page_document _|Page_downloads _ | Page_console _ | Page_network _ | Page_cookies _|Page_capture _|Page_scene _|Page_interact _
    | Session_open _|Session_close|Session_status|Page_goto _|Page_elements _
    | Page_act (Open_tab _|On_tab {interaction=Click _|Fill _|Press _|Scroll _|Select _|Close_tab|Back|Forward|Reload|Accept_dialog _|Dismiss_dialog;_})
    | Page_context _|Page_instruct _|Page_locate _|Page_extract _ -> Error "grant command is not an upload")
let discard t ~id =
  let snapshot=locked t (fun () -> match Hashtbl.find_opt t.grants id with
    | Some (Pending grant) -> Hashtbl.replace t.grants id Releasing;Some grant.snapshot
    | Some (Preparing _) -> Hashtbl.replace t.grants id (Preparing Withdrawn);None
    | None -> Hashtbl.add t.grants id Consumed;None
    | Some (Claimed|Releasing|Release_failed _|Consumed) -> None) in
  Option.iter (release t ~id) snapshot
let revoke t = locked t (fun () -> t.serving<-false)
let await_releases t =
  let active ()=Hashtbl.fold (fun _ state waiting -> match state with
    | Preparing _|Claimed|Releasing -> true
    | Pending _|Release_failed _|Consumed -> waiting) t.grants false in
  while active () do Condition.wait t.changed t.mutex done
let cleanup t = protect (fun () ->
  Mutex.lock t.cleanup_mutex;
  Fun.protect ~finally:(fun () -> Mutex.unlock t.cleanup_mutex) (fun () ->
    if t.settled then
      (match Unix.lstat t.directory with
       | _ -> Error "settled upload allocation reappeared"
       | exception Unix.Unix_error (Unix.ENOENT,_,_) -> Ok ())
    else (
      revoke t;
      let snapshots=locked t (fun () ->
        await_releases t;
        Hashtbl.fold (fun id state acc -> match state with
          | Pending grant -> (id,grant.snapshot)::acc
          | Preparing _|Claimed|Releasing|Release_failed _|Consumed -> acc) t.grants []) in
      List.iter (fun (id,snapshot) ->
        let pending=locked t (fun () -> match Hashtbl.find_opt t.grants id with
          | Some (Pending _) -> Hashtbl.replace t.grants id Releasing;true
          | None|Some (Preparing _|Claimed|Releasing|Release_failed _|Consumed) -> false) in
        if pending then release t ~id snapshot) snapshots;
      let failures=locked t (fun () ->
        await_releases t;
        Hashtbl.fold (fun _ state errors -> match state with
        | Release_failed detail -> detail::errors
        | Preparing _|Pending _|Claimed|Releasing|Consumed -> errors) t.grants []) in
      let* ()=match failures with [] -> Ok () | _::_ -> Error (String.concat "; " failures) in
      let* ()=check t in
      if Sys.readdir t.directory=[||] then (Unix.rmdir t.directory;t.settled<-true;Ok ())
      else Error "upload allocation still contains owned or unconfirmed files")))
