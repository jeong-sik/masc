(* A load never moves or replaces an autosave file unless the caller consents.
   Lane level: the tool arguments and messages are in test_dos_tools. *)

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

let load ?(autosave = Dos_lane.Keep_autosave) fixture =
  Dos_lane.load ~who ~ledger_dir:fixture.directory ~saves_dir:fixture.saves
    ~checkpoint_dir:fixture.checkpoints ~autosave ~program_name:"hello.com"
    ~program_bytes:hello ~files:[] ~announce:ignore
;;

let require = function
  | Ok value -> value
  | Error error -> fail (Dos_lane.error_to_string error)
;;

let step () =
  ignore (require (Dos_lane.step ~who ~steps:1_000 ~until_ready:false))
;;

let slot_path fixture slot =
  match Machine_checkpoint.slot_of_string slot with
  | Ok slot -> Machine_checkpoint.path ~dir:fixture.checkpoints slot
  | Error message -> fail message
;;

let autosave_path fixture = slot_path fixture "autosave"
let prev_path fixture = slot_path fixture "autosave-prev"

let steps_in fixture slot =
  match Machine_checkpoint.slot_of_string slot with
  | Error message -> fail message
  | Ok slot ->
    (match
       Machine_checkpoint.read_meta ~dir:fixture.checkpoints slot
         ~machine:Machine_checkpoint.Dos ~format:Dos_lane.checkpoint_format
     with
     | Error e -> fail (Machine_checkpoint.error_to_string e)
     | Ok { meta = `Assoc fields; _ } ->
       (match List.assoc_opt "steps" fields with
        | Some (`Int steps) -> steps
        | _ -> fail "the checkpoint's meta names no step count")
     | Ok _ -> fail "the checkpoint's meta is not an object")
;;

let incarnation () = (require (Dos_lane.capture_with_identity ())).Dos_lane.incarnation

(* The campaign: a machine that has run past its boot, so its autosave holds a
   step count no fresh boot reaches. *)
let play_a_campaign fixture =
  let booted, _ran = require (load fixture) in
  step ();
  let campaign_steps = steps_in fixture "autosave" in
  check bool "the campaign is past its boot" true (campaign_steps > booted.Dos_lane.steps);
  campaign_steps
;;

let refused_with_status ~name ~expected_steps = function
  | Error (Dos_lane.Autosave_exists (Dos_lane.Held status)) ->
    check string (name ^ ": names the program") "hello.com" status.Dos_lane.program;
    check int (name ^ ": names the step count") expected_steps status.Dos_lane.steps;
    check string (name ^ ": names who saved it") who status.Dos_lane.saved_by
  | Error error -> failf "%s: unexpected %s" name (Dos_lane.error_to_string error)
  | Ok _ -> failf "%s: the load went through over an autosave" name
;;

let test_a_second_load_keeps_the_campaign () =
  with_fixture (fun fixture ->
    let campaign_steps = play_a_campaign fixture in
    let before = Digest.file (autosave_path fixture) in
    let machine = incarnation () in
    refused_with_status ~name:"second load" ~expected_steps:campaign_steps (load fixture);
    check string "the autosave file is byte for byte as it was" before
      (Digest.file (autosave_path fixture));
    check bool "nothing moved to autosave-prev" false (Sys.file_exists (prev_path fixture));
    check string "the running machine is the one from before" machine (incarnation ());
    (* A third attempt meets the same autosave: a refusal changes nothing, so
       repeating it cannot wear the campaign down. *)
    refused_with_status ~name:"third load" ~expected_steps:campaign_steps (load fixture);
    check string "still byte for byte" before (Digest.file (autosave_path fixture)))
;;

let test_a_load_after_a_restore_keeps_the_campaign () =
  with_fixture (fun fixture ->
    let campaign_steps = play_a_campaign fixture in
    let slot =
      match Machine_checkpoint.slot_of_string "autosave" with
      | Ok slot -> slot
      | Error message -> fail message
    in
    ignore
      (require
         (Dos_lane.restore ~who ~dir:fixture.checkpoints ~slot ~ledger_dir:fixture.directory
            ~saves_dir_of:(fun _ -> fixture.saves)
            ~announce:ignore));
    let before = Digest.file (autosave_path fixture) in
    refused_with_status ~name:"load after restore" ~expected_steps:campaign_steps (load fixture);
    check string "the restored-from file is untouched" before
      (Digest.file (autosave_path fixture));
    check bool "nothing moved to autosave-prev" false (Sys.file_exists (prev_path fixture)))
;;

let test_a_load_after_an_eject_keeps_the_campaign () =
  with_fixture (fun fixture ->
    let campaign_steps = play_a_campaign fixture in
    ignore (require (Dos_lane.eject ~who ~announce:ignore ()));
    refused_with_status ~name:"load with no machine" ~expected_steps:campaign_steps
      (load fixture);
    check bool "no machine was installed" true
      (match Dos_lane.screen () with Error Dos_lane.No_machine -> true | _ -> false))
;;

let test_a_consented_load_moves_the_campaign_to_prev () =
  with_fixture (fun fixture ->
    let campaign_steps = play_a_campaign fixture in
    let reloaded, _ran = require (load ~autosave:Dos_lane.Replace_autosave fixture) in
    check int "autosave-prev holds the campaign" campaign_steps (steps_in fixture "autosave-prev");
    check int "and the autosave is the new machine's own boot" reloaded.Dos_lane.steps
      (steps_in fixture "autosave");
    (* The consent covers what autosave-prev held: the next consented load
       replaces it with the autosave the second machine wrote. *)
    step ();
    let second_steps = steps_in fixture "autosave" in
    ignore (require (load ~autosave:Dos_lane.Replace_autosave fixture));
    check int "a second consented load replaces autosave-prev" second_steps
      (steps_in fixture "autosave-prev"))
;;

let test_a_load_with_no_autosave_needs_no_consent () =
  with_fixture (fun fixture ->
    ignore (require (load ~autosave:Dos_lane.Keep_autosave fixture));
    check bool "the boot wrote the autosave" true (Sys.file_exists (autosave_path fixture));
    check bool "and moved nothing" false (Sys.file_exists (prev_path fixture)));
  with_fixture (fun fixture ->
    ignore (require (load ~autosave:Dos_lane.Replace_autosave fixture));
    check bool "consent with nothing to move moves nothing" false
      (Sys.file_exists (prev_path fixture)))
;;

let write_file path contents =
  Out_channel.with_open_bin path (fun oc -> output_string oc contents)
;;

let test_an_unreadable_autosave_stops_a_load_until_consent () =
  with_fixture (fun fixture ->
    Unix.mkdir fixture.checkpoints 0o755;
    write_file (autosave_path fixture) "not a checkpoint";
    (match load fixture with
     | Error (Dos_lane.Autosave_exists (Dos_lane.Held_unreadable _)) -> ()
     | Error error -> fail (Dos_lane.error_to_string error)
     | Ok _ -> fail "a load replaced a file it could not read");
    check string "the file is as it was" "not a checkpoint"
      (In_channel.with_open_bin (autosave_path fixture) In_channel.input_all);
    ignore (require (load ~autosave:Dos_lane.Replace_autosave fixture));
    check string "with consent the file moves to autosave-prev" "not a checkpoint"
      (In_channel.with_open_bin (prev_path fixture) In_channel.input_all))
;;

(* ---------- slots ---------- *)

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

(* lea ax,ax: the core does not implement it, so the boot faults at once. *)
let faulting_program = "\x8d\xc0"

let test_a_faulted_boot_installs_the_machine_and_keeps_the_autosave () =
  with_fixture (fun fixture ->
    let campaign_steps = play_a_campaign fixture in
    let before = Digest.file (autosave_path fixture) in
    let announced = ref 0 in
    let faulting =
      Dos_lane.load ~who ~ledger_dir:fixture.directory ~saves_dir:fixture.saves
        ~checkpoint_dir:fixture.checkpoints ~autosave:Dos_lane.Replace_autosave
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

let () =
  run "DOS autosave guard"
    [ ( "load"
      , [ test_case "a second load keeps the campaign" `Quick
            test_a_second_load_keeps_the_campaign
        ; test_case "a load after a restore keeps the campaign" `Quick
            test_a_load_after_a_restore_keeps_the_campaign
        ; test_case "a load after an eject keeps the campaign" `Quick
            test_a_load_after_an_eject_keeps_the_campaign
        ; test_case "a consented load moves the campaign to autosave-prev" `Quick
            test_a_consented_load_moves_the_campaign_to_prev
        ; test_case "a load with no autosave needs no consent" `Quick
            test_a_load_with_no_autosave_needs_no_consent
        ; test_case "an unreadable autosave stops a load until consent" `Quick
            test_an_unreadable_autosave_stops_a_load_until_consent
        ; test_case "a faulted boot installs the machine and keeps the autosave" `Quick
            test_a_faulted_boot_installs_the_machine_and_keeps_the_autosave
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
    ]
;;
