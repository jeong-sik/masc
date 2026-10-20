let max_file_bytes = 16 * 1024 * 1024
type state = Pending | Owned | Released
type lease = { paths : string list; cleanup : unit -> unit; mutable state : state }
type owner = { mutable leases : lease list }
(* This registry is process-local, shared by Keeper staging and every native
   driver. Operations perform no yielding I/O while holding the mutex. *)
let mutex = Mutex.create ()
let pending = ref []
let locked f = Mutex.lock mutex; Fun.protect ~finally:(fun () -> Mutex.unlock mutex) f
let create_owner () = {leases=[]}
let register ~paths ~cleanup = locked (fun () ->
  let lease = {paths;cleanup;state=Pending} in
  pending := lease :: !pending;
  lease)
let claim ~owner ~paths = locked (fun () ->
  match List.find_opt (fun lease -> lease.paths=paths) !pending with
  | None -> ()
  | Some lease ->
    lease.state <- Owned;
    pending := List.filter (fun candidate -> candidate != lease) !pending;
    owner.leases <- lease :: owner.leases)
let release_pending lease =
  let cleanup = locked (fun () -> match lease.state with
    | Owned | Released -> None
    | Pending ->
      lease.state <- Released;
      pending := List.filter (fun candidate -> candidate != lease) !pending;
      Some lease.cleanup) in
  Option.iter (fun f -> f ()) cleanup
let release_owner owner =
  let leases = locked (fun () ->
    let leases=owner.leases in owner.leases <- [];
    List.iter (fun lease -> lease.state <- Released) leases;
    leases) in
  List.iter (fun lease -> lease.cleanup ()) leases
let ( let* ) = Result.bind
type 'read_error staging_error =
  | Read_failed of 'read_error
  | Snapshot_failed of string

type snapshot = lease
let paths (snapshot:snapshot) = snapshot.paths
let release = release_pending
let pending ~paths = locked (fun () ->
  List.exists (fun lease -> lease.state=Pending && lease.paths=paths) !pending)

type staging_root = {path:string;device:int;inode:int}
let root_mutex = Mutex.create ()
let staging_root = ref None
let default_root () =
  Mutex.lock root_mutex;
  Fun.protect ~finally:(fun () -> Mutex.unlock root_mutex) (fun () ->
    let root=match !staging_root with
      | Some root -> root
      | None ->
        let path=Unix.realpath (Filename.temp_dir ~perms:0o700 "masc-browser-uploads-" "") in
        let info=Unix.lstat path in
        let root={path;device=info.st_dev;inode=info.st_ino} in
        staging_root:=Some root;
        (* The process retains this private staging anchor across batches.
           Exit cleanup only removes its original, already-empty directory. *)
        at_exit (fun () -> try
          let current=Unix.lstat root.path in
          if current.st_kind=Unix.S_DIR && current.st_dev=root.device && current.st_ino=root.inode
            && Sys.readdir root.path=[||] then Unix.rmdir root.path
          with Unix.Unix_error _|Sys_error _ -> ());
        root in
    let current=Unix.lstat root.path in
    if current.st_kind<>Unix.S_DIR || current.st_dev<>root.device || current.st_ino<>root.inode
      || current.st_uid<>Unix.getuid () || current.st_perm<>0o700
    then raise (Sys_error "upload staging anchor identity changed");
    root.path)

let prepare_files ?temp_dir ~files () =
  let* directory,chain =
    try
      let parent=Unix.realpath (match temp_dir with None -> default_root () | Some path -> path) in
      let frozen path = let info=Unix.lstat path in
        {Fs_compat.path;device=info.st_dev;inode=info.st_ino;
          owner_uid=info.st_uid;permissions=info.st_perm} in
      let parent_identity=frozen parent in
      let directory=Filename.temp_dir ~temp_dir:parent ~perms:0o700 "masc-browser-upload-" "" in
      Ok (directory,[parent_identity;frozen directory])
    with
    | (Sys_error _|Unix.Unix_error _) as exn -> Error (Snapshot_failed ("upload staging failed: " ^ Printexc.to_string exn)) in
  let lease = ref None in
  let cleanup () = match Fs_compat.remove_owned_tree chain with
    | Ok () -> () | Error detail -> raise (Sys_error ("upload cleanup unconfirmed: " ^ detail)) in
  Fun.protect ~finally:(fun () -> match !lease with
    | Some _ -> () | None -> cleanup ()) (fun () ->
    let rec stage index acc = function
      | [] -> Ok (List.rev acc)
      | (name,read) :: rest ->
        let* bytes = read () |> Result.map_error (fun error -> Read_failed error) in
        if name="." || name=".." || name="" || Filename.basename name <> name
        then Error (Snapshot_failed "upload snapshot requires a file basename")
        else
          let subdir = Filename.concat directory (string_of_int index) in
          Unix.mkdir subdir 0o700;
          let target = Filename.concat subdir name in
          let oc = open_out_gen [Open_wronly;Open_creat;Open_excl;Open_binary] 0o600 target in
          Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () -> output_string oc bytes);
          stage (index+1) (target :: acc) rest in
    let* paths = try stage 0 [] files with
      | Sys_error message -> Error (Snapshot_failed ("upload staging failed: " ^ message))
      | Unix.Unix_error (error,operation,_) ->
        Error (Snapshot_failed ("upload staging failed: " ^ operation ^ ": " ^ Unix.error_message error)) in
    let snapshot=register ~paths ~cleanup in
    lease := Some snapshot;
    Ok snapshot)

let with_staged_files ~files f =
  let* snapshot=prepare_files ~files () in
  Fun.protect ~finally:(fun () -> release snapshot) (fun () -> Ok (f (paths snapshot)))
