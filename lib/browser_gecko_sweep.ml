module Profile = Private_browser_profile
module Gecko = Browser_gecko_profile

let termination_grace_seconds = 70.

(* A holder sent SIGTERM on an earlier pass, by profile path. *)
type pending = { holder : Profile.holder; kill_after : Monotonic_deadline.t }

type t = { grace : float; gate : Mutex.t; terminated : (string, pending) Hashtbl.t }

let create ~termination_grace_seconds =
  { grace = termination_grace_seconds; gate = Mutex.create (); terminated = Hashtbl.create 8 }

type signalled = { profile : string; pid : int; executable : string option }

type outcome =
  | Removed of string
  | Terminated of signalled
  | Killed of signalled
  | Kept of { path : string; reason : string }

type plan = { kept : outcome list; instances : string list }

let sorted_entries path = Sys.readdir path |> Array.to_list |> List.sort String.compare

let failure path = function
  | Unix.Unix_error (error, call, _) -> Kept { path; reason = call ^ ": " ^ Unix.error_message error }
  | Sys_error reason -> Kept { path; reason }
  | exn -> raise exn

let plan ~root ~sweepable =
  match Gecko.existing_root root with
  | Error reason -> { kept = [Kept { path = root; reason }]; instances = [] }
  | Ok None -> { kept = []; instances = [] }
  | Ok (Some root) ->
    match sorted_entries root with
    | exception (Unix.Unix_error _ | Sys_error _ as exn) -> { kept = [failure root exn]; instances = [] }
    | names ->
      List.fold_right (fun name plan ->
          let path = Filename.concat root name in
          if not (Gecko.is_masc_name name) then
            { plan with kept = Kept { path; reason = "it is not an instance directory masc made" } :: plan.kept }
          else if sweepable name then { plan with instances = path :: plan.instances }
          else plan)
        names { kept = []; instances = [] }

let forget t path =
  match Hashtbl.find_opt t.terminated path with
  | Some pending -> Profile.release pending.holder; Hashtbl.remove t.terminated path
  | None -> ()

let signal_text = function
  | Profile.Holder_changed -> "its holder let go of the lock before the signal"
  | Profile.Other_lock_file -> "the holder was captured from another lock file"
  | Profile.Lock_file_closed -> "the lock file was closed before the signal"
  | Profile.Released -> "the holder capture was released before the signal"
  | Profile.Unsupported -> "this platform cannot signal a captured process"
  | Profile.Failed -> "the kernel refused the signal"

let next_pass = "; the next pass reads it again"

(* Read the executable before the signal: it is read by PID. *)
let record ~profile holder = { profile; pid = Profile.pid holder; executable = Profile.executable holder }

(* The lock file is closed whatever [run] does. *)
let with_lock_file path run =
  match Profile.open_lock ~profile:path ~name:Gecko.lock_name with
  | Error reason -> [Kept { path; reason }]
  | Ok lock_file ->
    let outcomes = try run lock_file with exn -> Profile.close_lock lock_file; raise exn in
    Profile.close_lock lock_file;
    outcomes

let step t path = with_lock_file path (fun lock_file ->
  match Profile.inspect lock_file with
  | Profile.Unreadable reason -> [Kept { path; reason }]
  | Profile.Changing -> [Kept { path; reason = "its lock holder changed while it was read" ^ next_pass }]
  | Profile.Unlocked ->
    forget t path;
    (match Profile.lock lock_file with
     | Error reason -> [Kept { path; reason }]
     | Ok Profile.Held_elsewhere -> [Kept { path; reason = "another process took its lock" ^ next_pass }]
     | Ok Profile.Locked ->
       (match Gecko.remove_locked path with
        | Ok () -> [Removed path]
        | Error reason -> [Kept { path; reason }]))
  | Profile.Held_by holder ->
    match Hashtbl.find_opt t.terminated path with
    | Some pending when Profile.same_process pending.holder holder ->
      Profile.release holder;
      if not (Monotonic_deadline.passed pending.kill_after) then []
      else
        let signalled = record ~profile:path pending.holder in
        (match Profile.request_kill pending.holder lock_file with
         | Ok () -> [Killed signalled]
         | Error error -> [Kept { path; reason = signal_text error ^ next_pass }])
    | Some _ | None ->
      forget t path;
      let signalled = record ~profile:path holder in
      (match Profile.request_termination holder lock_file with
       | Ok () ->
         Hashtbl.replace t.terminated path
           { holder; kill_after = Monotonic_deadline.after ~seconds:t.grace };
         [Terminated signalled]
       | Error error -> Profile.release holder; [Kept { path; reason = signal_text error ^ next_pass }]))

(* Each profile's outcome is its own: a failure in one keeps the signals
   already sent to the others in the report. *)
let sweep_instance t instance =
  match Gecko.check_instance instance with
  | Error reason -> [Kept { path = instance; reason }]
  | Ok () ->
    let profiles = List.concat_map (fun name ->
        let path = Filename.concat instance name in
        if not (Gecko.is_masc_name name) then [Kept { path; reason = "it is not a profile masc made" }]
        else match step t path with
          | outcomes -> outcomes
          | exception (Unix.Unix_error _ | Sys_error _ as exn) -> [failure path exn])
      (sorted_entries instance) in
    match sorted_entries instance with
    | [] -> (match Unix.rmdir instance with
        | () -> profiles
        | exception (Unix.Unix_error _ | Sys_error _ as exn) -> profiles @ [failure instance exn])
    | _ :: _ -> profiles

(* Kept while unsure, so a pass that could not read a profile does not restart
   its grace. *)
let gone path = match Unix.lstat path with
  | _ -> false
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> true
  | exception Unix.Unix_error _ -> false

let pass t plan = Mutex.protect t.gate (fun () ->
  let outcomes = List.concat_map (fun instance ->
      match sweep_instance t instance with
      | outcomes -> outcomes
      | exception (Unix.Unix_error _ | Sys_error _ as exn) -> [failure instance exn])
    plan.instances in
  (* A pending SIGTERM is forgotten once its profile is gone. *)
  Hashtbl.filter_map_inplace (fun path pending ->
      if gone path then (Profile.release pending.holder; None) else Some pending) t.terminated;
  plan.kept @ outcomes)

let signalled_to_string { profile; pid; executable } =
  Printf.sprintf "%s (pid %d, %s)" profile pid
    (match executable with Some path -> path | None -> "executable unknown")

let outcome_to_string = function
  | Removed path -> "removed Gecko profile " ^ path
  | Terminated signalled -> "sent SIGTERM to the holder of Gecko profile " ^ signalled_to_string signalled
  | Killed signalled -> "sent SIGKILL to the holder of Gecko profile " ^ signalled_to_string signalled
  | Kept { path; reason } -> Printf.sprintf "kept Gecko profile entry %s: %s" path reason
