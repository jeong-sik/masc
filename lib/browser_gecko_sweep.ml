module Profile = Private_browser_profile
module Gecko = Browser_gecko_profile

(* A holder sent SIGTERM on an earlier pass, by profile path. *)
type t = { terminated : (string, Profile.holder) Hashtbl.t }

let create () = { terminated = Hashtbl.create 8 }

type signalled = { profile : string; pid : int; executable : string option }

type outcome =
  | Removed of string
  | Terminated of signalled
  | Killed of signalled
  | Kept of { path : string; reason : string }

let forget t path =
  match Hashtbl.find_opt t.terminated path with
  | Some holder -> Profile.release holder; Hashtbl.remove t.terminated path
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

let step t path =
  match Profile.open_lock ~profile:path ~name:Gecko.lock_name with
  | Error reason -> Kept { path; reason }
  | Ok lock_file ->
    Fun.protect ~finally:(fun () -> Profile.close_lock lock_file) (fun () ->
      match Profile.inspect lock_file with
      | Profile.Unreadable reason -> Kept { path; reason }
      | Profile.Changing -> Kept { path; reason = "its lock holder changed while it was read" ^ next_pass }
      | Profile.Unlocked ->
        forget t path;
        (match Profile.lock lock_file with
         | Error reason -> Kept { path; reason }
         | Ok Profile.Held_elsewhere -> Kept { path; reason = "another process took its lock" ^ next_pass }
         | Ok Profile.Locked ->
           (match Gecko.remove_locked path with
            | Ok () -> Removed path
            | Error reason -> Kept { path; reason }))
      | Profile.Held_by holder ->
        match Hashtbl.find_opt t.terminated path with
        | Some previous when Profile.same_process previous holder ->
          Profile.release holder;
          let signalled = record ~profile:path previous in
          (match Profile.request_kill previous lock_file with
           | Ok () -> Killed signalled
           | Error error -> Kept { path; reason = signal_text error ^ next_pass })
        | Some _ | None ->
          forget t path;
          let signalled = record ~profile:path holder in
          (match Profile.request_termination holder lock_file with
           | Ok () -> Hashtbl.replace t.terminated path holder; Terminated signalled
           | Error error -> Profile.release holder; Kept { path; reason = signal_text error ^ next_pass }))

let sorted_entries path = Sys.readdir path |> Array.to_list |> List.sort String.compare

let failure path = function
  | Unix.Unix_error (error, call, _) -> Kept { path; reason = call ^ ": " ^ Unix.error_message error }
  | Sys_error reason -> Kept { path; reason }
  | exn -> raise exn

let sweep_instance t ~seen instance =
  match Gecko.check_instance instance with
  | Error reason -> [Kept { path = instance; reason }]
  | Ok () ->
    let profiles = List.map (fun name ->
        let path = Filename.concat instance name in
        Hashtbl.replace seen path ();
        if Gecko.is_masc_name name then step t path
        else Kept { path; reason = "it is not a profile masc made" })
      (sorted_entries instance) in
    match sorted_entries instance with
    | [] -> (match Unix.rmdir instance with
        | () -> profiles
        | exception exn -> profiles @ [failure instance exn])
    | _ :: _ -> profiles

let sweep_root t ~seen ~live root =
  match Gecko.check_root root with
  | Error reason -> [Kept { path = root; reason }]
  | Ok () ->
    List.concat_map (fun name ->
        let instance = Filename.concat root name in
        if not (Gecko.is_masc_name name) then [Kept { path = instance; reason = "it is not an instance directory masc made" }]
        else if live name then []
        else match sweep_instance t ~seen instance with
          | outcomes -> outcomes
          | exception exn -> [failure instance exn])
      (sorted_entries root)

let pass t ~root ~live =
  let seen = Hashtbl.create 8 in
  let outcomes = match Unix.realpath root with
    | exception Unix.Unix_error (Unix.ENOENT, _, _) -> []
    | exception exn -> [failure root exn]
    | root -> (match sweep_root t ~seen ~live root with
        | outcomes -> outcomes
        | exception exn -> [failure root exn]) in
  (* A pending SIGTERM whose profile is gone, or whose instance is live again,
     is forgotten. *)
  Hashtbl.filter_map_inplace (fun path holder ->
      if Hashtbl.mem seen path then Some holder else (Profile.release holder; None)) t.terminated;
  outcomes

let signalled_to_string { profile; pid; executable } =
  Printf.sprintf "%s (pid %d, %s)" profile pid
    (match executable with Some path -> path | None -> "executable unknown")

let outcome_to_string = function
  | Removed path -> "removed Gecko profile " ^ path
  | Terminated signalled -> "sent SIGTERM to the holder of Gecko profile " ^ signalled_to_string signalled
  | Killed signalled -> "sent SIGKILL to the holder of Gecko profile " ^ signalled_to_string signalled
  | Kept { path; reason } -> Printf.sprintf "kept Gecko profile entry %s: %s" path reason
