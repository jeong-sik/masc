open Alcotest
let require = function Ok value -> value | Error error -> fail (Msx_lane.error_to_string error)
let parse text = match Otoml.Parser.from_string_result text with
  | Error error -> fail error
  | Ok toml -> Machine_configuration.parse toml
let current = ref Machine_configuration.default
let observe () = if !current.Machine_configuration.msx_enabled then Machine_configuration.Enabled else Disabled
let with_machine run =
  let directory = Filename.temp_dir "masc-msx-activity-" "" in
  current := Machine_configuration.default;
  Msx_lane.install_activity_observer (Some observe);
  let rec remove path =
    if Sys.is_directory path then (Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path); Unix.rmdir path)
    else Sys.remove path in
  Fun.protect ~finally:(fun () -> ignore (Msx_lane.eject ()); Msx_lane.install_activity_observer None; remove directory)
    (fun () ->
      ignore (require (Msx_lane.load ~ledger_dir:directory ~roms_dir:None ~cart_path:None ~disk_path:None));
      run directory)
let off () = current := { !current with msx_enabled = false }
let rejected name result = match result with
  | Error Msx_lane.Activity_disabled -> ()
  | Error error -> failf "%s: unexpected %s" name (Msx_lane.error_to_string error)
  | Ok _ -> fail (name ^ " ran while off")
let test_configuration () =
  check bool "omitted flags are enabled" true (parse "" = Ok Machine_configuration.default);
  check bool "MSX flag does not disable DOS" true
    (parse "[machines.msx]\nenabled=false\n" = Ok { Machine_configuration.msx_enabled=false; dos_enabled=true });
  check bool "separate machine settings" true
    (parse "[machines.msx]\nenabled=true\n[machines.dos]\nenabled=false\n" = Ok { Machine_configuration.msx_enabled=true; dos_enabled=false });
  List.iter (fun text -> check bool "malformed activity is rejected" true (Result.is_error (parse text)))
    ["machines=false"; "[machines.other]\nenabled=false"; "[machines.msx]\nenabled='false'";
     "[machines.dos]\nunknown=true"; "[machines]\nmsx=1"];
  check bool "machines is reserved as a configuration namespace" true
    (Runtime_toml_namespace.of_key "machines" = Some Machines)
let test_off_retains () = with_machine @@ fun directory ->
  let before = require (Msx_lane.capture_with_identity ()) in
  let ledger = Msx_lane.ledger () in
  off ();
  rejected "load" (Msx_lane.load ~ledger_dir:directory ~roms_dir:None ~cart_path:None ~disk_path:None);
  rejected "step" (Msx_lane.step ~frames:1);
  rejected "settle" (Msx_lane.step_until_change ~max_frames:1);
  rejected "HTTP tick owner" (Msx_lane.step_frame ~frames:1);
  rejected "press" (Msx_lane.press ~who:"fixture" ~keys:[Msx.Space] ~hold_frames:1 ~step_frames:1 ~sequence:false);
  rejected "restore" (Msx_lane.restore ~path:(Filename.concat directory "absent") ~ledger_dir:directory);
  let backup = Filename.concat directory "must-not-write.dsk" in
  rejected "disk swap" (Msx_lane.change_disk ~path:(Filename.concat directory "absent.dsk") ~backup_path:backup);
  check bool "off does not write disk backup" false (Sys.file_exists backup);
  let after = require (Msx_lane.capture_with_identity ()) in
  check string "same machine" before.incarnation after.incarnation;
  check int "same frame" before.observation.frame after.observation.frame;
  check bool "same input ledger" true (ledger = Msx_lane.ledger ());
  ignore (require (Msx_lane.peek ~address:0 ~length:1));
  ignore (require (Msx_lane.ram_diff ()));
  let path = Filename.concat directory "retained.json" in
  ignore (require (Msx_lane.save ~path));
  check bool "checkpoint can be saved while off" true (Sys.file_exists path);
  current := { !current with msx_enabled = true };
  let resumed = require (Msx_lane.step ~frames:1) in
  check int "re-enable continues the retained frame" (before.observation.frame + 1) resumed.frame;
  ignore (require (Msx_lane.restore ~path ~ledger_dir:directory))
let test_unobserved () = with_machine @@ fun _ ->
  Msx_lane.install_activity_observer None;
  (match Msx_lane.step ~frames:1 with Error Msx_lane.Activity_unobserved -> () | _ -> fail "missing config must refuse new execution");
  ignore (require (Msx_lane.screen ()));
  ignore (require (Msx_lane.eject ()))
let test_accepted_finishes () = with_machine @@ fun _ ->
  let calls = ref 0 in
  Msx_lane.install_activity_observer (Some (fun () ->
    incr calls; let accepted = observe () in off (); accepted));
  let before = require (Msx_lane.screen ()) in
  let after = require (Msx_lane.press ~who:"fixture" ~keys:[Msx.Space] ~hold_frames:1 ~step_frames:2 ~sequence:false) in
  check int "single admission" 1 !calls;
  check int "both held and released frames ran" (before.frame + 2) after.frame;
  check bool "last key edge releases the key" true
    (match List.rev (Msx_lane.ledger ()) with entry::_ -> not entry.Msx_lane.down | [] -> false);
  rejected "subsequent step" (Msx_lane.step ~frames:1)
let () = run "MSX activity with retained state"
  ["activity", [test_case "configuration and reserved namespace" `Quick test_configuration;
    test_case "off refuses mutation and preserves machine/checkpoint" `Quick test_off_retains;
    test_case "unobserved refuses execution but allows inspection/cleanup" `Quick test_unobserved;
    test_case "accepted input finishes after off" `Quick test_accepted_finishes]]
