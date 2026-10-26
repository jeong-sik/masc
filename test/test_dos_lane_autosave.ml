(* Starting a machine -- a load, or a restore -- never discards the previous
   autosave unless the caller consents. Its first autosave copies the autosave
   to autosave-prev, so what is at stake is the file in autosave-prev; with no
   file there the autosave moves in and survives, and nothing is asked. Lane
   level: the tool arguments and messages are in test_dos_tools. *)

open Alcotest

let who = "autosave-fixture"

(* Prints HI, then polls the BIOS key read until a key arrives. It asks for a
   key at once, so a load settles and a later step has something to run. *)
let hello =
  "\xb4\x09\xba\x11\x01\xcd\x21\xb4\x00\xcd\x16\x09\xc0\x74\xf8\xcd\x20HI$"
;;

type fixture =
  { directory : string
  ; saves : string
  ; checkpoints : string
  }

let rec remove path =
  if Sys.is_directory path
  then (
    Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path)
  else Sys.remove path
;;

let with_fixture run =
  let directory = Filename.temp_dir "masc-dos-autosave-" "" in
  let fixture =
    { directory
    ; saves = Filename.concat directory "game"
    ; checkpoints = Filename.concat directory "checkpoints"
    }
  in
  Dos_lane.install_activity_observer (Some (fun () -> Machine_configuration.Enabled));
  Fun.protect
    ~finally:(fun () ->
      let holder =
        match Dos_lane.screen () with
        | Ok { Dos_lane.controller = Some holder; _ } -> holder
        | Ok _ | Error _ -> who
      in
      ignore (Dos_lane.eject ~who:holder ~announce:ignore () : (unit, Dos_lane.error) result);
      Dos_lane.install_activity_observer None;
      remove directory)
    (fun () -> run fixture)
;;

let load ?(previous_autosave = Dos_lane.Keep_previous_autosave) fixture =
  Dos_lane.load ~who ~ledger_dir:fixture.directory ~saves_dir:fixture.saves
    ~checkpoint_dir:fixture.checkpoints ~previous_autosave ~program_name:"hello.com"
    ~program_bytes:hello ~files:[] ~announce:ignore
;;

let restore ?(previous_autosave = Dos_lane.Keep_previous_autosave) fixture slot =
  Dos_lane.restore ~who ~dir:fixture.checkpoints ~slot ~previous_autosave
    ~ledger_dir:fixture.directory
    ~saves_dir_of:(fun _ -> fixture.saves)
    ~announce:ignore
;;

let require = function
  | Ok value -> value
  | Error error -> fail (Dos_lane.error_to_string error)
;;

let step () =
  ignore (require (Dos_lane.step ~who ~steps:1_000 ~until_ready:false))
;;

let slot_of name =
  match Machine_checkpoint.slot_of_string name with
  | Ok slot -> slot
  | Error message -> fail message
;;

let named_of name =
  match Dos_lane.classify_slot (slot_of name) with
  | Dos_lane.Named named -> named
  | Dos_lane.Current_autosave | Dos_lane.Previous_autosave ->
    failf "%s is a slot the lane writes itself" name
;;

let slot_path fixture name = Machine_checkpoint.path ~dir:fixture.checkpoints (slot_of name)
let autosave_path fixture = slot_path fixture "autosave"
let prev_path fixture = slot_path fixture "autosave-prev"

let steps_in fixture name =
  match
    Machine_checkpoint.read_meta ~dir:fixture.checkpoints (slot_of name)
      ~machine:Machine_checkpoint.Dos ~format:Dos_lane.checkpoint_format
  with
  | Error e -> fail (Machine_checkpoint.error_to_string e)
  | Ok { meta = `Assoc fields; _ } ->
    (match List.assoc_opt "steps" fields with
     | Some (`Int steps) -> steps
     | _ -> fail "the checkpoint's meta names no step count")
  | Ok _ -> fail "the checkpoint's meta is not an object"
;;

let incarnation () = (require (Dos_lane.capture_with_identity ())).Dos_lane.incarnation

let write_file path contents =
  Out_channel.with_open_bin path (fun oc -> output_string oc contents)
;;

(* The campaign: a machine that has run past its boot, so its autosave holds a
   step count no fresh boot reaches. *)
let play_a_campaign fixture =
  let booted, _boot = require (load fixture) in
  step ();
  let campaign_steps = steps_in fixture "autosave" in
  check bool "the campaign is past its boot" true (campaign_steps > booted.Dos_lane.steps);
  campaign_steps
;;

(* The state a second start meets: the campaign in autosave-prev and a fresh
   machine's boot in the autosave. The first start asked for nothing, because
   autosave-prev was empty. Returns the campaign's step count and the boot's. *)
let campaign_in_previous fixture =
  let campaign_steps = play_a_campaign fixture in
  let booted, _boot = require (load fixture) in
  check int "the campaign moved to autosave-prev" campaign_steps (steps_in fixture "autosave-prev");
  (campaign_steps, booted.Dos_lane.steps)
;;

let would_discard ~name ~discarded_steps ~kept_steps = function
  | Error
      (Dos_lane.Would_discard_previous_autosave
        { previous = Dos_lane.Held discarded; current = Dos_lane.Held kept }) ->
    check int (name ^ ": the steps it would discard") discarded_steps discarded.Dos_lane.steps;
    check int (name ^ ": the steps that move into its place") kept_steps kept.Dos_lane.steps;
    check string (name ^ ": who saved the one it would discard") who discarded.Dos_lane.saved_by
  | Error error -> failf "%s: unexpected %s" name (Dos_lane.error_to_string error)
  | Ok _ -> failf "%s: the start went through and discarded the previous autosave" name
;;

let unchanged ~name fixture ~autosave ~previous =
  check string (name ^ ": the autosave is byte for byte as it was") autosave
    (Digest.file (autosave_path fixture));
  check string (name ^ ": the previous autosave is byte for byte as it was") previous
    (Digest.file (prev_path fixture))
;;

let test_a_start_over_an_autosave_alone_keeps_it_and_asks_nothing () =
  with_fixture (fun fixture ->
    let campaign_steps = play_a_campaign fixture in
    let campaign = Digest.file (autosave_path fixture) in
    check bool "autosave-prev is empty" false (Sys.file_exists (prev_path fixture));
    let reloaded, _boot = require (load fixture) in
    check string "the campaign file survives as autosave-prev" campaign
      (Digest.file (prev_path fixture));
    check int "with its steps" campaign_steps (steps_in fixture "autosave-prev");
    check int "and the autosave is the new machine's own boot" reloaded.Dos_lane.steps
      (steps_in fixture "autosave"))
;;

(* The repeat of the original bug: a second start moved the campaign to
   autosave-prev, and a third replaced autosave-prev with the fresh boot. *)
let test_a_third_start_would_discard_the_campaign_and_is_refused () =
  with_fixture (fun fixture ->
    let campaign_steps, boot_steps = campaign_in_previous fixture in
    let autosave = Digest.file (autosave_path fixture)
    and previous = Digest.file (prev_path fixture) in
    let machine = incarnation () in
    let refused name =
      would_discard ~name ~discarded_steps:campaign_steps ~kept_steps:boot_steps (load fixture);
      unchanged ~name fixture ~autosave ~previous;
      check string (name ^ ": the running machine is the one from before") machine
        (incarnation ())
    in
    refused "third start";
    (* A refusal changes nothing, so repeating it cannot wear the campaign down. *)
    refused "fourth start";
    let reloaded, _boot = require (load ~previous_autosave:Dos_lane.Discard_previous_autosave fixture) in
    check int "with consent the boot moves into autosave-prev" boot_steps
      (steps_in fixture "autosave-prev");
    check int "and the autosave is the newest machine's own boot" reloaded.Dos_lane.steps
      (steps_in fixture "autosave"))
;;

(* After a restart there is no machine and both files are on disk. *)
let test_a_load_after_an_eject_is_refused_when_it_would_discard () =
  with_fixture (fun fixture ->
    let campaign_steps, boot_steps = campaign_in_previous fixture in
    ignore (require (Dos_lane.eject ~who ~announce:ignore ()));
    would_discard ~name:"load with no machine" ~discarded_steps:campaign_steps
      ~kept_steps:boot_steps (load fixture);
    check bool "no machine was installed" true
      (match Dos_lane.screen () with Error Dos_lane.No_machine -> true | _ -> false))
;;

(* The second bug the review found: autosave A, restore a named slot, run,
   restore it again, run. The second run's first save replaced the copy of A. *)
let test_a_restore_asks_before_it_would_discard_the_campaign () =
  with_fixture (fun fixture ->
    let campaign_steps = play_a_campaign fixture in
    ignore (require (Dos_lane.save ~who ~dir:fixture.checkpoints ~slot:(named_of "quick")));
    ignore (require (restore fixture (slot_of "quick")));
    step ();
    check int "the first restore asked nothing and kept the campaign" campaign_steps
      (steps_in fixture "autosave-prev");
    let autosave = Digest.file (autosave_path fixture)
    and previous = Digest.file (prev_path fixture) in
    let machine = incarnation () in
    let kept_steps = steps_in fixture "autosave" in
    would_discard ~name:"second restore" ~discarded_steps:campaign_steps ~kept_steps
      (restore fixture (slot_of "quick"));
    unchanged ~name:"second restore" fixture ~autosave ~previous;
    check string "the running machine is the one from before" machine (incarnation ());
    ignore
      (require
         (restore ~previous_autosave:Dos_lane.Discard_previous_autosave fixture (slot_of "quick")));
    step ();
    check int "with consent autosave-prev holds the machine that was running" kept_steps
      (steps_in fixture "autosave-prev"))
;;

let test_a_restore_of_the_autosave_asks_when_both_files_are_there () =
  with_fixture (fun fixture ->
    let campaign_steps, boot_steps = campaign_in_previous fixture in
    would_discard ~name:"restore of the autosave" ~discarded_steps:campaign_steps
      ~kept_steps:boot_steps (restore fixture Dos_lane.autosave_slot))
;;

(* What would be replaced is already inside the machine that restore builds. *)
let test_a_restore_of_the_previous_autosave_asks_nothing () =
  with_fixture (fun fixture ->
    let campaign_steps, _boot_steps = campaign_in_previous fixture in
    let restored = require (restore fixture Dos_lane.autosave_prev_slot) in
    check int "the campaign is the restored machine" campaign_steps restored.Dos_lane.steps)
;;

let test_a_slot_that_does_not_exist_is_reported_not_asked_about () =
  with_fixture (fun fixture ->
    ignore (campaign_in_previous fixture);
    match restore fixture (slot_of "never-saved") with
    | Error (Dos_lane.Checkpoint_refused (Machine_checkpoint.No_slot _)) -> ()
    | Error error -> fail (Dos_lane.error_to_string error)
    | Ok _ -> fail "a slot that was never saved restored")
;;

(* A file that will not read still counts: it may hold the only copy. *)
let test_an_unreadable_previous_autosave_is_at_stake () =
  with_fixture (fun fixture ->
    ignore (play_a_campaign fixture);
    write_file (prev_path fixture) "not a checkpoint";
    (match load fixture with
     | Error
         (Dos_lane.Would_discard_previous_autosave
           { previous = Dos_lane.Held_unreadable _; current = Dos_lane.Held _ }) -> ()
     | Error error -> fail (Dos_lane.error_to_string error)
     | Ok _ -> fail "a load replaced a previous autosave it could not read");
    check string "the file is as it was" "not a checkpoint"
      (In_channel.with_open_bin (prev_path fixture) In_channel.input_all))
;;

let test_an_unreadable_autosave_moves_to_previous_and_asks_nothing () =
  with_fixture (fun fixture ->
    Unix.mkdir fixture.checkpoints 0o755;
    write_file (autosave_path fixture) "not a checkpoint";
    ignore (require (load fixture));
    check string "the file moved to autosave-prev byte for byte" "not a checkpoint"
      (In_channel.with_open_bin (prev_path fixture) In_channel.input_all))
;;

let test_an_unreadable_autosave_is_at_stake_when_previous_holds_something () =
  with_fixture (fun fixture ->
    ignore (play_a_campaign fixture);
    let campaign = Digest.file (autosave_path fixture) in
    (* The campaign is the previous autosave; the autosave is damaged. *)
    Sys.rename (autosave_path fixture) (prev_path fixture);
    write_file (autosave_path fixture) "damaged";
    (match load fixture with
     | Error
         (Dos_lane.Would_discard_previous_autosave
           { previous = Dos_lane.Held _; current = Dos_lane.Held_unreadable _ }) -> ()
     | Error error -> fail (Dos_lane.error_to_string error)
     | Ok _ -> fail "a load replaced a previous autosave");
    check string "the previous autosave is as it was" campaign (Digest.file (prev_path fixture)))
;;

(* With no autosave there is nothing to copy, so the previous one stays. *)
let test_a_start_with_only_a_previous_autosave_leaves_it () =
  with_fixture (fun fixture ->
    ignore (play_a_campaign fixture);
    Sys.rename (autosave_path fixture) (prev_path fixture);
    let previous = Digest.file (prev_path fixture) in
    ignore (require (load fixture));
    check string "autosave-prev is untouched" previous (Digest.file (prev_path fixture));
    check bool "and the new machine wrote its own autosave" true
      (Sys.file_exists (autosave_path fixture)))
;;

let test_a_start_with_nothing_on_disk_asks_nothing () =
  with_fixture (fun fixture ->
    ignore (require (load fixture));
    check bool "the boot wrote the autosave" true (Sys.file_exists (autosave_path fixture));
    check bool "and moved nothing" false (Sys.file_exists (prev_path fixture)))
;;

(* A load that lands between a restore's preparation and its commit copies the
   autosave into autosave-prev; the restore's own first save would then replace
   what that load just kept. The commit notices. *)
let test_a_restore_commit_refuses_when_the_previous_autosave_changed () =
  with_fixture (fun fixture ->
    let campaign_steps = play_a_campaign fixture in
    ignore (require (Dos_lane.save ~who ~dir:fixture.checkpoints ~slot:(named_of "quick")));
    let prepared =
      require
        (Dos_lane.prepare_restore ~dir:fixture.checkpoints ~slot:(slot_of "quick")
           ~previous_autosave:Dos_lane.Keep_previous_autosave ~ledger_dir:fixture.directory
           ~saves_dir_of:(fun _ -> fixture.saves))
    in
    Fun.protect
      ~finally:(fun () -> Dos_lane.discard_prepared_restore prepared)
      (fun () ->
        ignore (require (load fixture));
        check int "the load kept the campaign" campaign_steps (steps_in fixture "autosave-prev");
        let machine = incarnation () in
        (match Dos_lane.commit_restore ~who prepared ~announce:ignore with
         | Error (Dos_lane.Invalid_request _) -> ()
         | Error error -> fail (Dos_lane.error_to_string error)
         | Ok _ -> fail "a restore went through over a previous autosave it had not seen");
        check string "the running machine is the one from before" machine (incarnation ())))
;;

(* ---------- slots ---------- *)

let test_the_lane_owned_slots_are_not_named () =
  let kind name =
    match Dos_lane.classify_slot (slot_of name) with
    | Dos_lane.Named _ -> "named"
    | Dos_lane.Current_autosave -> "autosave"
    | Dos_lane.Previous_autosave -> "autosave-prev"
  in
  List.iter
    (fun (name, expected) -> check string name expected (kind name))
    [ "autosave", "autosave"
    ; "AUTOSAVE", "autosave"
    ; "AutoSave", "autosave"
    ; "autosave-prev", "autosave-prev"
    ; "Autosave-PREV", "autosave-prev"
    ; "quick", "named"
    ; "autosave2", "named"
    ; "autosave_prev", "named"
    ; "my-autosave", "named"
    ]
;;

let test_a_save_says_what_it_replaced () =
  with_fixture (fun fixture ->
    let campaign_steps = play_a_campaign fixture in
    let named = named_of "before-the-battle" in
    (match Dos_lane.save ~who ~dir:fixture.checkpoints ~slot:named with
     | Ok (_, Dos_lane.Fresh_slot) -> ()
     | Ok (_, (Dos_lane.Replaced _ | Dos_lane.Replaced_unreadable _)) ->
       fail "a new name replaced something"
     | Error error -> fail (Dos_lane.error_to_string error));
    step ();
    (match Dos_lane.save ~who ~dir:fixture.checkpoints ~slot:named with
     | Ok (_, Dos_lane.Replaced status) ->
       check string "the replaced checkpoint's program" "hello.com" status.Dos_lane.program;
       check int "and its steps" campaign_steps status.Dos_lane.steps;
       check string "and who saved it" who status.Dos_lane.saved_by
     | Ok (_, (Dos_lane.Fresh_slot | Dos_lane.Replaced_unreadable _)) ->
       fail "the second save did not report the first"
     | Error error -> fail (Dos_lane.error_to_string error));
    check bool "the slot now holds the later machine" true
      (steps_in fixture "before-the-battle" > campaign_steps))
;;

let test_a_save_over_an_unreadable_file_says_so () =
  with_fixture (fun fixture ->
    ignore (play_a_campaign fixture);
    write_file (slot_path fixture "junk") "not a checkpoint";
    match Dos_lane.save ~who ~dir:fixture.checkpoints ~slot:(named_of "junk") with
    | Ok (_, Dos_lane.Replaced_unreadable _) -> ()
    | Ok (_, (Dos_lane.Fresh_slot | Dos_lane.Replaced _)) ->
      fail "the unreadable file was not reported"
    | Error error -> fail (Dos_lane.error_to_string error))
;;

let test_a_save_leaves_only_the_checkpoint () =
  with_fixture (fun fixture ->
    ignore (play_a_campaign fixture);
    ignore (require (Dos_lane.save ~who ~dir:fixture.checkpoints ~slot:(named_of "kept")));
    let files = List.sort String.compare (Array.to_list (Sys.readdir fixture.checkpoints)) in
    check (list string) "the slot and the autosave, no stray temp file"
      [ "autosave.ckpt"; "kept.ckpt" ] files)
;;

(* The copy that keeps the previous autosave fails: autosave-prev cannot be
   replaced because a directory holds its name. Nothing is written, the old
   autosave is the file it was, and the call says why. Once the blocker is gone
   the next call keeps the autosave and writes. *)
let test_a_failed_copy_keeps_the_old_autosave_and_is_retried () =
  with_fixture (fun fixture ->
    ignore (play_a_campaign fixture);
    ignore (require (Dos_lane.save ~who ~dir:fixture.checkpoints ~slot:(named_of "quick")));
    let campaign = Digest.file (autosave_path fixture) in
    Unix.mkdir (prev_path fixture) 0o755;
    (* The directory is an unreadable previous autosave, so the restore asks. *)
    (match restore fixture (slot_of "quick") with
     | Error
         (Dos_lane.Would_discard_previous_autosave
           { previous = Dos_lane.Held_unreadable _; current = Dos_lane.Held _ }) -> ()
     | Error error -> fail (Dos_lane.error_to_string error)
     | Ok _ -> fail "a restore went through over a previous autosave it could not read");
    ignore
      (require
         (restore ~previous_autosave:Dos_lane.Discard_previous_autosave fixture
            (slot_of "quick")));
    let stepped = require (Dos_lane.step ~who ~steps:1_000 ~until_ready:false) in
    (match (snd stepped).Dos_lane.autosave with
     | Dos_lane.Autosave_failed _ -> ()
     | Dos_lane.Autosaved | Dos_lane.Not_attempted ->
       fail "the autosave was written although the previous one could not be kept");
    check string "the old autosave is the file it was" campaign (Digest.file (autosave_path fixture));
    Unix.rmdir (prev_path fixture);
    let retried = require (Dos_lane.step ~who ~steps:1_000 ~until_ready:false) in
    (match (snd retried).Dos_lane.autosave with
     | Dos_lane.Autosaved -> ()
     | Dos_lane.Autosave_failed reason -> fail reason
     | Dos_lane.Not_attempted -> fail "no autosave attempted");
    check string "the old autosave was kept under autosave-prev" campaign
      (Digest.file (prev_path fixture));
    check bool "and the autosave is the machine's own now" true
      (Digest.file (autosave_path fixture) <> campaign);
    (* The copy is made once: a later autosave leaves autosave-prev alone. *)
    ignore (require (Dos_lane.step ~who ~steps:1_000 ~until_ready:false));
    check string "autosave-prev is still the kept file" campaign (Digest.file (prev_path fixture)))
;;

(* lea ax,ax: the core does not implement it, so the boot faults at once. *)
let faulting_program = "\x8d\xc0"

let test_a_faulted_boot_installs_the_machine_and_keeps_the_autosave () =
  with_fixture (fun fixture ->
    let campaign_steps = play_a_campaign fixture in
    let before = Digest.file (autosave_path fixture) in
    let announced = ref 0 in
    let faulting =
      Dos_lane.load ~who ~ledger_dir:fixture.directory ~saves_dir:fixture.saves
        ~checkpoint_dir:fixture.checkpoints ~previous_autosave:Dos_lane.Keep_previous_autosave
        ~program_name:"fault.com" ~program_bytes:faulting_program ~files:[]
        ~announce:(fun () -> incr announced)
    in
    (match faulting with
     | Ok (_, Dos_lane.Boot_faulted (Dos_lane.Unimplemented_instruction message)) ->
       check bool "the fault is named" true (message <> "")
     | Ok (_, Dos_lane.Boot_faulted (Dos_lane.Core_exception _)) ->
       fail "an unimplemented instruction is not a core exception"
     | Ok (_, Dos_lane.Booted _) -> fail "the program should have faulted"
     | Error error -> fail (Dos_lane.error_to_string error));
    check int "the machine's change was announced once" 1 !announced;
    let screen = require (Dos_lane.screen ()) in
    check (option string) "the machine is installed and the loader holds it" (Some "fault.com")
      screen.Dos_lane.program;
    check (option string) "controller" (Some who) screen.Dos_lane.controller;
    check string "no autosave was written for a machine that faults again" before
      (Digest.file (autosave_path fixture));
    check bool "so nothing was displaced to autosave-prev" false (Sys.file_exists (prev_path fixture));
    check int "and the campaign is the autosave" campaign_steps (steps_in fixture "autosave"))
;;

(* ---------- a worker's start ----------

   A restart leaves the files on disk and no machine. In one process an eject
   is that: it writes nothing. *)

let restart () = require (Dos_lane.eject ~who ~announce:ignore ())

let resume fixture =
  Dos_lane.resume_autosave ~dir:fixture.checkpoints ~ledger_dir:fixture.directory
    ~saves_dir_of:(fun _ -> fixture.saves)
;;

let describe_resume = function
  | Dos_lane.Nothing_to_resume -> "nothing to resume"
  | Dos_lane.Machine_loaded -> "a machine was already loaded"
  | Dos_lane.Resumed o -> Printf.sprintf "resumed at %d steps" o.Dos_lane.steps
  | Dos_lane.Not_resumed error -> "not resumed: " ^ Dos_lane.error_to_string error
;;

let resumed ~name = function
  | Dos_lane.Resumed observation -> observation
  | (Dos_lane.Nothing_to_resume | Dos_lane.Machine_loaded | Dos_lane.Not_resumed _) as other ->
    failf "%s: %s" name (describe_resume other)
;;

let loaded () =
  match Dos_lane.live ~since:None with
  | Dos_lane.Nothing_loaded -> false
  | Dos_lane.Unchanged _ | Dos_lane.Changed _ -> true
;;

let controller () = (require (Dos_lane.screen ())).Dos_lane.controller

let test_a_start_resumes_the_autosave_with_the_controller_free () =
  with_fixture (fun fixture ->
    let campaign_steps = play_a_campaign fixture in
    restart ();
    let machine = resumed ~name:"a start over the campaign's autosave" (resume fixture) in
    check int "the machine is where the autosave left it" campaign_steps machine.Dos_lane.steps;
    check (option string) "nobody holds the controller" None machine.Dos_lane.controller;
    check (option string) "the screen agrees" None (controller ());
    (* A free controller goes to whoever moves next (RFC play-link §2.8). *)
    ignore (require (Dos_lane.step ~who:"guest" ~steps:1_000 ~until_ready:false));
    check (option string) "the first to move takes it" (Some "guest") (controller ()))
;;

(* No autosave: nothing comes back, and autosave-prev is not a fallback. *)
let test_a_start_with_no_autosave_stays_unloaded () =
  with_fixture (fun fixture ->
    (match resume fixture with
     | Dos_lane.Nothing_to_resume -> ()
     | (Dos_lane.Machine_loaded | Dos_lane.Resumed _ | Dos_lane.Not_resumed _) as other ->
       failf "an empty directory: %s" (describe_resume other));
    check bool "an empty directory loads nothing" false (loaded ());
    ignore (play_a_campaign fixture);
    restart ();
    Sys.rename (autosave_path fixture) (prev_path fixture);
    let previous = Digest.file (prev_path fixture) in
    (match resume fixture with
     | Dos_lane.Nothing_to_resume -> ()
     | (Dos_lane.Machine_loaded | Dos_lane.Resumed _ | Dos_lane.Not_resumed _) as other ->
       failf "only autosave-prev on disk: %s" (describe_resume other));
    check bool "only autosave-prev loads nothing" false (loaded ());
    check string "and autosave-prev is untouched" previous (Digest.file (prev_path fixture)))
;;

let test_an_unreadable_autosave_is_not_resumed_and_says_why () =
  with_fixture (fun fixture ->
    ignore (play_a_campaign fixture);
    restart ();
    (* The campaign is the previous autosave; the autosave is damaged. *)
    Sys.rename (autosave_path fixture) (prev_path fixture);
    write_file (autosave_path fixture) "damaged";
    let previous = Digest.file (prev_path fixture) in
    let reason =
      match resume fixture with
      | Dos_lane.Not_resumed error -> Dos_lane.error_to_string error
      | (Dos_lane.Nothing_to_resume | Dos_lane.Machine_loaded | Dos_lane.Resumed _) as other ->
        failf "a damaged autosave: %s" (describe_resume other)
    in
    check bool "nothing is loaded" false (loaded ());
    check string "the damaged file is as it was" "damaged"
      (In_channel.with_open_bin (autosave_path fixture) In_channel.input_all);
    check string "autosave-prev was neither restored nor replaced" previous
      (Digest.file (prev_path fixture));
    match Dos_lane.recent_activity () with
    | newest :: _ ->
      check bool "the activity feed carries the reason" true
        (String.ends_with ~suffix:reason newest.Machine_action_feed.action)
    | [] -> fail "the failed resume left no line on the activity feed")
;;

(* The equivalence the resume rests on. An uninterrupted machine's autosaves
   replace the autosave and leave autosave-prev alone, and so do a resumed
   machine's. Restoring the autosave instead would move it into autosave-prev
   on the first save and lose the campaign kept there. *)
let test_the_first_save_after_a_resume_leaves_autosave_prev_as_play_would () =
  with_fixture (fun fixture ->
    ignore (campaign_in_previous fixture);
    step ();
    let campaign = Digest.file (prev_path fixture) in
    step ();
    check string "uninterrupted play leaves autosave-prev alone" campaign
      (Digest.file (prev_path fixture));
    let autosaved = steps_in fixture "autosave" in
    restart ();
    let machine = resumed ~name:"a start after the second game" (resume fixture) in
    check int "the resumed machine is the autosave" autosaved machine.Dos_lane.steps;
    step ();
    check bool "its first save replaced the autosave" true (steps_in fixture "autosave" > autosaved);
    check string "and left autosave-prev as uninterrupted play does" campaign
      (Digest.file (prev_path fixture)))
;;

let test_a_start_leaves_a_loaded_machine_alone () =
  with_fixture (fun fixture ->
    ignore (play_a_campaign fixture);
    let before = incarnation () in
    (match resume fixture with
     | Dos_lane.Machine_loaded -> ()
     | (Dos_lane.Nothing_to_resume | Dos_lane.Resumed _ | Dos_lane.Not_resumed _) as other ->
       failf "a loaded machine: %s" (describe_resume other));
    check string "the same machine" before (incarnation ());
    check (option string) "and its holder" (Some who) (controller ()))
;;

let () =
  run "DOS autosave guard"
    [ ( "start"
      , [ test_case "a start over an autosave alone keeps it and asks nothing" `Quick
            test_a_start_over_an_autosave_alone_keeps_it_and_asks_nothing
        ; test_case "a third start would discard the campaign and is refused" `Quick
            test_a_third_start_would_discard_the_campaign_and_is_refused
        ; test_case "a load after an eject is refused when it would discard" `Quick
            test_a_load_after_an_eject_is_refused_when_it_would_discard
        ; test_case "an unreadable previous autosave is at stake" `Quick
            test_an_unreadable_previous_autosave_is_at_stake
        ; test_case "an unreadable autosave moves to previous and asks nothing" `Quick
            test_an_unreadable_autosave_moves_to_previous_and_asks_nothing
        ; test_case "an unreadable autosave is at stake when previous holds something" `Quick
            test_an_unreadable_autosave_is_at_stake_when_previous_holds_something
        ; test_case "a start with only a previous autosave leaves it" `Quick
            test_a_start_with_only_a_previous_autosave_leaves_it
        ; test_case "a start with nothing on disk asks nothing" `Quick
            test_a_start_with_nothing_on_disk_asks_nothing
        ; test_case "a failed copy keeps the old autosave and is retried" `Quick
            test_a_failed_copy_keeps_the_old_autosave_and_is_retried
        ; test_case "a faulted boot installs the machine and keeps the autosave" `Quick
            test_a_faulted_boot_installs_the_machine_and_keeps_the_autosave
        ] )
    ; ( "restore"
      , [ test_case "a restore asks before it would discard the campaign" `Quick
            test_a_restore_asks_before_it_would_discard_the_campaign
        ; test_case "a restore of the autosave asks when both files are there" `Quick
            test_a_restore_of_the_autosave_asks_when_both_files_are_there
        ; test_case "a restore of the previous autosave asks nothing" `Quick
            test_a_restore_of_the_previous_autosave_asks_nothing
        ; test_case "a slot that does not exist is reported, not asked about" `Quick
            test_a_slot_that_does_not_exist_is_reported_not_asked_about
        ; test_case "a restore commit refuses when the previous autosave changed" `Quick
            test_a_restore_commit_refuses_when_the_previous_autosave_changed
        ] )
    ; ( "slots"
      , [ test_case "the lane-owned slots are not names" `Quick
            test_the_lane_owned_slots_are_not_named
        ; test_case "a save says what it replaced" `Quick test_a_save_says_what_it_replaced
        ; test_case "a save over an unreadable file says so" `Quick
            test_a_save_over_an_unreadable_file_says_so
        ; test_case "a save leaves only the checkpoint" `Quick
            test_a_save_leaves_only_the_checkpoint
        ] )
    ; ( "worker start"
      , [ test_case "a start resumes the autosave with the controller free" `Quick
            test_a_start_resumes_the_autosave_with_the_controller_free
        ; test_case "a start with no autosave stays unloaded" `Quick
            test_a_start_with_no_autosave_stays_unloaded
        ; test_case "an unreadable autosave is not resumed and says why" `Quick
            test_an_unreadable_autosave_is_not_resumed_and_says_why
        ; test_case "the first save after a resume leaves autosave-prev as play would" `Quick
            test_the_first_save_after_a_resume_leaves_autosave_prev_as_play_would
        ; test_case "a start leaves a loaded machine alone" `Quick
            test_a_start_leaves_a_loaded_machine_alone
        ] )
    ]
;;
