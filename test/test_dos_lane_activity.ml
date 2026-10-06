open Alcotest
let require = function Ok value -> value | Error error -> fail (Dos_lane.error_to_string error)
let current = ref Machine_configuration.Enabled
let observe () = !current
let who = "activity-fixture"
let hello = "\xb4\x09\xba\x11\x01\xcd\x21\xb4\x00\xcd\x16\x09\xc0\x74\xf8\xcd\x20HI$"
let with_machine run =
  let directory = Filename.temp_dir "masc-dos-activity-" "" in
  let saves = Filename.concat directory "game" and checkpoints = Filename.concat directory "checkpoints" in
  current := Machine_configuration.Enabled;
  Dos_lane.install_activity_observer (Some observe);
  let rec remove path =
    if Sys.is_directory path then (Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path); Unix.rmdir path)
    else Sys.remove path in
  Fun.protect ~finally:(fun () ->
    let holder = match Dos_lane.screen () with Ok { controller=Some holder; _ } -> holder | _ -> who in
    ignore (Dos_lane.eject ~who:holder ~announce:ignore ());
    Dos_lane.install_activity_observer None; remove directory) (fun () ->
    let load () = Dos_lane.load ~who ~ledger_dir:directory ~saves_dir:saves ~checkpoint_dir:checkpoints
      ~program_name:"hello.com" ~program_bytes:hello ~files:[] ~announce:ignore in
    ignore (require (load ()));
    run directory saves checkpoints load)
let rejected name = function
  | Error Dos_lane.Activity_disabled -> ()
  | Error error -> failf "%s: unexpected %s" name (Dos_lane.error_to_string error)
  | Ok _ -> fail (name ^ " ran while off")
let slot = match Machine_checkpoint.slot_of_string "retained" with Ok slot -> slot | Error error -> fail error
let test_off_retains () = with_machine @@ fun directory saves checkpoints load ->
  let before = require (Dos_lane.capture_with_identity ()) in
  current := Machine_configuration.Disabled;
  rejected "load" (load ());
  rejected "step" (Dos_lane.step ~who ~steps:1 ~until_ready:false);
  rejected "press" (Dos_lane.press ~who ~keys:["space"] ~steps:1);
  rejected "Play pad owner" (Dos_lane.press_into ~saves_name:"game" ~who ~keys:["space"] ~steps:1);
  rejected "click" (Dos_lane.click ~who ~x:0 ~y:0 ~buttons:1 ~steps:2);
  rejected "type" (Dos_lane.type_text ~who ~text:"a" ~steps:1);
  rejected "pass to another holder" (Dos_lane.pass ~who ~to_:(Some "next") ~announce:ignore);
  rejected "restore" (Dos_lane.restore ~who ~dir:checkpoints ~slot ~ledger_dir:directory ~saves_dir_of:(fun _ -> saves) ~announce:ignore);
  let after = require (Dos_lane.capture_with_identity ()) in
  check string "same machine" before.incarnation after.incarnation;
  check int "same steps" before.observation.steps after.observation.steps;
  check (option string) "controller retained" before.observation.controller after.observation.controller;
  ignore (require (Dos_lane.peek ~address:0 ~length:1));
  ignore (require (Dos_lane.save ~who ~dir:checkpoints ~slot));
  check bool "checkpoint retained" true (Sys.file_exists (Machine_checkpoint.path ~dir:checkpoints slot));
  ignore (require (Dos_lane.checkpoints ~dir:checkpoints));
  ignore (require (Dos_lane.pass ~who ~to_:None ~announce:ignore));
  current := Machine_configuration.Enabled;
  ignore (require (Dos_lane.restore ~who ~dir:checkpoints ~slot ~ledger_dir:directory ~saves_dir_of:(fun _ -> saves) ~announce:ignore));
  ignore (require (Dos_lane.step ~who ~steps:1 ~until_ready:false))
let test_unobserved () = with_machine @@ fun _ _ _ _ ->
  Dos_lane.install_activity_observer None;
  (match Dos_lane.step ~who ~steps:1 ~until_ready:false with Error Dos_lane.Activity_unobserved -> () | _ -> fail "missing config must refuse new execution");
  ignore (require (Dos_lane.screen ()));
  ignore (require (Dos_lane.release_left ~holder:who ~announce:ignore));
  ignore (require (Dos_lane.eject ~who ~announce:ignore ()))
let test_accepted_finishes () = with_machine @@ fun _ _ _ _ ->
  let calls = ref 0 in
  Dos_lane.install_activity_observer (Some (fun () -> incr calls; let result= !current in current:=Machine_configuration.Disabled; result));
  ignore (require (Dos_lane.press ~who ~keys:["space"] ~steps:Dos_lane.max_steps_per_call));
  check int "single admission for key and checkpoint" 1 !calls;
  rejected "next step" (Dos_lane.step ~who ~steps:1 ~until_ready:false)
let () = run "DOS activity with retained state"
  ["activity", [test_case "off preserves machine/controller/checkpoints" `Quick test_off_retains;
    test_case "unobserved keeps inspection/cleanup" `Quick test_unobserved;
    test_case "accepted input finishes after off" `Quick test_accepted_finishes]]
