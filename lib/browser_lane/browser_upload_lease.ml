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
let with_staged_files ~files f =
  let* directory =
    try Ok (Filename.temp_dir ~perms:0o700 "masc-browser-upload-" "")
    with Sys_error message -> Error ("upload staging failed: " ^ message) in
  let staged = ref [] in
  let subdirs = ref [] in
  let lease = ref None in
  let cleanup () =
    List.iter Unix.unlink !staged;
    List.iter Unix.rmdir !subdirs;
    Unix.rmdir directory in
  Fun.protect ~finally:(fun () -> match !lease with
    | Some lease -> release_pending lease | None -> cleanup ()) (fun () ->
    let rec stage index acc = function
      | [] -> Ok (List.rev acc)
      | (name,read) :: rest ->
        let* bytes = read () in
        if name="." || name=".." || name="" || Filename.basename name <> name
        then Error "upload snapshot requires a file basename"
        else
          let subdir = Filename.concat directory (string_of_int index) in
          Unix.mkdir subdir 0o700;
          subdirs := subdir :: !subdirs;
          let target = Filename.concat subdir name in
          let oc = open_out_gen [Open_wronly;Open_creat;Open_excl;Open_binary] 0o600 target in
          staged := target :: !staged;
          Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () -> output_string oc bytes);
          stage (index+1) (target :: acc) rest in
    let* paths = try stage 0 [] files with
      | Sys_error message -> Error ("upload staging failed: " ^ message)
      | Unix.Unix_error (error,operation,_) ->
        Error ("upload staging failed: " ^ operation ^ ": " ^ Unix.error_message error) in
    lease := Some (register ~paths ~cleanup);
    Ok (f paths))
