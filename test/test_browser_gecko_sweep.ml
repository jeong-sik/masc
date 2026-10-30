module Sweep = Masc.Browser_gecko_sweep
module Gecko = Masc.Browser_gecko_profile

let rec remove_tree path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR ->
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  | Unix.S_REG | Unix.S_LNK | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK -> Unix.unlink path
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()

let uuid () = Uuidm.(to_string (v4_gen (Random.State.make_self_init ()) ()))

(* A profile root with one instance holding one profile, as the worker leaves it. *)
let with_profile work =
  let base = Filename.temp_dir "masc-gecko-sweep-" "" in
  Fun.protect ~finally:(fun () -> remove_tree base) (fun () ->
    let root = Filename.concat base "gecko-profiles" in
    let instance_id = uuid () in
    let instance = match Gecko.prepare_instance ~root ~instance_id with
      | Ok instance -> instance | Error detail -> Alcotest.fail detail in
    let profile = match Gecko.create ~instance with
      | Ok profile -> profile | Error detail -> Alcotest.fail detail in
    Alcotest.(check bool) "fresh gecko profile seeds user.js resource guards" true
      (Sys.file_exists (Filename.concat profile "user.js"));
    Out_channel.with_open_bin (Filename.concat profile "prefs.js") (fun _ -> ());
    Out_channel.with_open_bin (Filename.concat profile Gecko.lock_name) (fun _ -> ());
    work ~root ~instance_id ~instance ~profile)

let fork_child body =
  match Unix.fork () with
  | 0 -> (try body () with _ -> Unix._exit 2); Unix._exit 0
  | child -> child

(* A browser stand-in: holds the profile's lock until a signal ends it. *)
let holding_child ~term profile =
  let ready_read, ready_write = Unix.pipe () in
  let child = fork_child (fun () ->
    Unix.close ready_read;
    Sys.set_signal Sys.sigterm term;
    let fd = Unix.openfile (Filename.concat profile Gecko.lock_name) [Unix.O_RDWR] 0o600 in
    Unix.lockf fd Unix.F_LOCK 0;
    ignore (Unix.write_substring ready_write "r" 0 1);
    while true do (try Unix.pause () with Unix.Unix_error (Unix.EINTR, _, _) -> ()) done) in
  Unix.close ready_write;
  let byte = Bytes.create 1 in
  let count = Unix.read ready_read byte 0 1 in
  Unix.close ready_read;
  if count <> 1 then Alcotest.fail "the browser stand-in ended before it was ready";
  child

let stop child =
  (try Unix.kill child Sys.sigkill with Unix.Unix_error _ -> ());
  (try ignore (Unix.waitpid [] child) with Unix.Unix_error (Unix.ECHILD, _, _) -> ())

let ended_by child = snd (Unix.waitpid [] child)

let describe outcomes = String.concat "; " (List.map Sweep.outcome_to_string outcomes)

let removed profile outcomes =
  Alcotest.(check bool) ("the profile is removed: " ^ describe outcomes) true
    (List.exists (function Sweep.Removed path -> String.equal path profile
       | Sweep.Terminated _ | Sweep.Killed _ | Sweep.Kept _ -> false) outcomes);
  Alcotest.(check bool) "the profile directory is gone" false (Sys.file_exists profile)

let terminated child outcomes =
  Alcotest.(check bool) ("the holder is sent SIGTERM: " ^ describe outcomes) true
    (List.exists (function Sweep.Terminated { pid; _ } -> pid = child
       | Sweep.Removed _ | Sweep.Killed _ | Sweep.Kept _ -> false) outcomes)

let ended_instance _ = true
let host_grace = Sweep.termination_grace_seconds
let pass sweep ~root ~sweepable = Sweep.pass sweep (Sweep.plan ~root ~sweepable)

let a_free_profile_is_removed () = with_profile (fun ~root ~instance_id:_ ~instance ~profile ->
  removed profile (pass (Sweep.create ~termination_grace_seconds:host_grace) ~root ~sweepable:ended_instance);
  Alcotest.(check bool) "the emptied instance directory is gone" false (Sys.file_exists instance))

let an_instance_the_host_holds_is_left_alone () = with_profile (fun ~root ~instance_id ~instance:_ ~profile ->
  let outcomes = pass (Sweep.create ~termination_grace_seconds:host_grace) ~root
      ~sweepable:(fun id -> not (String.equal id instance_id)) in
  Alcotest.(check int) ("nothing is done: " ^ describe outcomes) 0 (List.length outcomes);
  Alcotest.(check bool) "the held profile stays" true (Sys.file_exists profile))

let a_directory_made_after_the_plan_is_not_touched () =
  with_profile (fun ~root ~instance_id:_ ~instance:_ ~profile:_ ->
    let sweep = Sweep.create ~termination_grace_seconds:host_grace in
    let plan = Sweep.plan ~root ~sweepable:(fun _ -> true) in
    let later = match Gecko.prepare_instance ~root ~instance_id:(uuid ()) with
      | Ok instance -> instance | Error detail -> Alcotest.fail detail in
    let later_profile = match Gecko.create ~instance:later with
      | Ok profile -> profile | Error detail -> Alcotest.fail detail in
    ignore (Sweep.pass sweep plan);
    Alcotest.(check bool) "a profile made after the plan stays" true (Sys.file_exists later_profile))

let a_holder_is_terminated_then_removed () = with_profile (fun ~root ~instance_id:_ ~instance:_ ~profile ->
  let sweep = Sweep.create ~termination_grace_seconds:host_grace in
  let child = holding_child ~term:Sys.Signal_default profile in
  Fun.protect ~finally:(fun () -> stop child) (fun () ->
    terminated child (pass sweep ~root ~sweepable:ended_instance);
    Alcotest.(check bool) "the holder ended on SIGTERM" true (ended_by child = Unix.WSIGNALED Sys.sigterm);
    removed profile (pass sweep ~root ~sweepable:ended_instance)))

let a_holder_within_the_grace_is_left_alone () = with_profile (fun ~root ~instance_id:_ ~instance:_ ~profile ->
  let sweep = Sweep.create ~termination_grace_seconds:host_grace in
  let child = holding_child ~term:Sys.Signal_ignore profile in
  Fun.protect ~finally:(fun () -> stop child) (fun () ->
    terminated child (pass sweep ~root ~sweepable:ended_instance);
    let outcomes = pass sweep ~root ~sweepable:ended_instance in
    Alcotest.(check int) ("a pass within the grace sends nothing: " ^ describe outcomes) 0 (List.length outcomes);
    Alcotest.(check bool) "the holder still runs" true (fst (Unix.waitpid [Unix.WNOHANG] child) = 0)))

let a_holder_that_stays_is_killed_after_the_grace () = with_profile (fun ~root ~instance_id:_ ~instance:_ ~profile ->
  let sweep = Sweep.create ~termination_grace_seconds:0. in
  let child = holding_child ~term:Sys.Signal_ignore profile in
  Fun.protect ~finally:(fun () -> stop child) (fun () ->
    terminated child (pass sweep ~root ~sweepable:ended_instance);
    let outcomes = pass sweep ~root ~sweepable:ended_instance in
    Alcotest.(check bool) ("the same holder is sent SIGKILL: " ^ describe outcomes) true
      (List.exists (function Sweep.Killed { pid; _ } -> pid = child
         | Sweep.Removed _ | Sweep.Terminated _ | Sweep.Kept _ -> false) outcomes);
    Alcotest.(check bool) "the holder ended on SIGKILL" true (ended_by child = Unix.WSIGNALED Sys.sigkill);
    removed profile (pass sweep ~root ~sweepable:ended_instance)))

let a_pending_sigterm_outlives_a_pass_that_skips_it () =
  with_profile (fun ~root ~instance_id:_ ~instance:_ ~profile ->
    let sweep = Sweep.create ~termination_grace_seconds:0. in
    let child = holding_child ~term:Sys.Signal_ignore profile in
    Fun.protect ~finally:(fun () -> stop child) (fun () ->
      terminated child (pass sweep ~root ~sweepable:ended_instance);
      ignore (pass sweep ~root ~sweepable:(fun _ -> false));
      let outcomes = pass sweep ~root ~sweepable:ended_instance in
      Alcotest.(check bool) ("the grace kept running, so the holder is sent SIGKILL: " ^ describe outcomes) true
        (List.exists (function Sweep.Killed { pid; _ } -> pid = child
           | Sweep.Removed _ | Sweep.Terminated _ | Sweep.Kept _ -> false) outcomes)))

let a_relaunched_holder_starts_with_termination () = with_profile (fun ~root ~instance_id:_ ~instance:_ ~profile ->
  let sweep = Sweep.create ~termination_grace_seconds:0. in
  let first = holding_child ~term:Sys.Signal_default profile in
  terminated first (pass sweep ~root ~sweepable:ended_instance);
  ignore (ended_by first);
  let second = holding_child ~term:Sys.Signal_default profile in
  Fun.protect ~finally:(fun () -> stop second) (fun () ->
    terminated second (pass sweep ~root ~sweepable:ended_instance);
    Alcotest.(check bool) "the new holder ended on SIGTERM, not SIGKILL" true
      (ended_by second = Unix.WSIGNALED Sys.sigterm)))

let names_masc_did_not_make_are_kept () = with_profile (fun ~root ~instance_id:_ ~instance ~profile:_ ->
  let foreign_instance = Filename.concat (Unix.realpath root) "not-an-instance" in
  Unix.mkdir foreign_instance 0o700;
  let foreign_profile = Filename.concat instance "not-a-profile" in
  Unix.mkdir foreign_profile 0o700;
  let outcomes = pass (Sweep.create ~termination_grace_seconds:host_grace) ~root ~sweepable:ended_instance in
  let kept path = List.exists (function Sweep.Kept { path = kept; _ } -> String.equal kept path
    | Sweep.Removed _ | Sweep.Terminated _ | Sweep.Killed _ -> false) outcomes in
  Alcotest.(check bool) ("an unknown instance name is kept: " ^ describe outcomes) true (kept foreign_instance);
  Alcotest.(check bool) "an unknown profile name is kept" true (kept foreign_profile);
  Alcotest.(check bool) "both stay on disk" true (Sys.file_exists foreign_instance && Sys.file_exists foreign_profile))

let a_symlinked_root_is_refused () = with_profile (fun ~root ~instance_id:_ ~instance:_ ~profile ->
  let link = Filename.concat (Filename.dirname root) "linked-profiles" in
  Unix.symlink root link;
  let outcomes = pass (Sweep.create ~termination_grace_seconds:host_grace) ~root:link ~sweepable:ended_instance in
  Alcotest.(check bool) ("the linked root is kept: " ^ describe outcomes) true
    (List.exists (function Sweep.Kept { path; _ } -> String.equal path link
       | Sweep.Removed _ | Sweep.Terminated _ | Sweep.Killed _ -> false) outcomes);
  Alcotest.(check bool) "nothing behind the link is removed" true (Sys.file_exists profile))

let a_missing_root_is_nothing () =
  let root = Filename.concat (Filename.get_temp_dir_name ()) ("masc-gecko-sweep-missing-" ^ uuid ()) in
  Alcotest.(check int) "no outcome" 0
    (List.length (pass (Sweep.create ~termination_grace_seconds:host_grace) ~root ~sweepable:ended_instance))

let () = Alcotest.run "browser gecko sweep" [
  "pass", [
    Alcotest.test_case "a free profile of an ended instance is removed" `Quick a_free_profile_is_removed;
    Alcotest.test_case "an instance the host holds is left alone" `Quick an_instance_the_host_holds_is_left_alone;
    Alcotest.test_case "a directory made after the plan is not touched" `Quick
      a_directory_made_after_the_plan_is_not_touched;
    Alcotest.test_case "a holder gets SIGTERM, then the profile is removed" `Quick a_holder_is_terminated_then_removed;
    Alcotest.test_case "a holder within the grace is left alone" `Quick a_holder_within_the_grace_is_left_alone;
    Alcotest.test_case "a holder that stays gets SIGKILL after the grace" `Quick
      a_holder_that_stays_is_killed_after_the_grace;
    Alcotest.test_case "a pending SIGTERM outlives a pass that skips it" `Quick
      a_pending_sigterm_outlives_a_pass_that_skips_it;
    Alcotest.test_case "a relaunched holder starts with SIGTERM" `Quick a_relaunched_holder_starts_with_termination;
    Alcotest.test_case "names masc did not make are kept" `Quick names_masc_did_not_make_are_kept;
    Alcotest.test_case "a symlinked root is refused" `Quick a_symlinked_root_is_refused;
    Alcotest.test_case "a missing root is nothing" `Quick a_missing_root_is_nothing]]
