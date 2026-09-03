(* Prompt presets (#32777): capture, save, load, list, and restore over a
   temp base path, plus the pure runtime.toml text transform. *)

module Preset = Masc.Prompt_preset
module Profile = Masc.Keeper_types_profile
module Override = Prompt_override_persistence

let contains_substring haystack needle =
  let n = String.length needle and h = String.length haystack in
  let rec go i = i + n <= h && (String.equal (String.sub haystack i n) needle || go (i + 1)) in
  n = 0 || go 0
;;

let test_dir () =
  let tmp = Filename.temp_file "masc_prompt_preset" "" in
  Sys.remove tmp;
  Unix.mkdir tmp 0o755;
  tmp
;;

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path
    then
      if Sys.is_directory path
      then begin
        Sys.readdir path |> Array.iter (fun f -> rm (Filename.concat path f));
        Unix.rmdir path
      end
      else Sys.remove path
  in
  rm dir
;;

let write_file path content =
  Out_channel.with_open_text path (fun oc -> output_string oc content)
;;

let rec mkdir_p path =
  if not (Sys.file_exists path)
  then begin
    mkdir_p (Filename.dirname path);
    Unix.mkdir path 0o755
  end
;;

let prompt_key = "test.preset"

let prompt_fixture =
  {|---
description: a prompt the preset test overrides
category: test
---
The file body.
|}
;;

let keeper_toml instructions =
  Printf.sprintf "[keeper]\nname = \"alpha\"\ninstructions = \"%s\"\n" instructions
;;

let runtime_fixture =
  {|# operator note that must survive a restore
[runtime]
default = "runpod_mtp.qwen"

[runtime.assignments]
routingtest = "openai.gpt"
# a second keeper the preset will drop
budgettest = "openai.gpt"

[providers.runpod_mtp]
display-name = "RunPod"
protocol = "openai-compatible-http"
endpoint = "https://runpod.example/v1"

[providers.openai]
display-name = "OpenAI"
protocol = "openai-compatible-http"
endpoint = "https://api.openai.example/v1"

[models.qwen]
api-name = "qwen"
max-context = 128000
temperature = 0.65
tools-support = true
streaming = true

[models.gpt]
api-name = "gpt"
max-context = 64000
tools-support = true
streaming = true

[runtime.exact_output_lanes.librarian_exact]
slots = ["openai.gpt", "runpod_mtp.qwen"]
|}
;;

(* A base path with one keeper TOML, a runtime.toml, and a prompt registry
   loaded from a temp markdown dir. *)
let with_base f =
  let base_path = test_dir () in
  let masc = Filename.concat base_path ".masc" in
  let config = Filename.concat masc "config" in
  let keepers = Filename.concat config "keepers" in
  mkdir_p keepers;
  write_file (Filename.concat keepers "alpha.toml") (keeper_toml "Do the alpha work.");
  write_file (Filename.concat config "runtime.toml") runtime_fixture;
  let prompts_dir = Filename.concat base_path "prompts" in
  mkdir_p prompts_dir;
  write_file (Filename.concat prompts_dir (prompt_key ^ ".md")) prompt_fixture;
  Fun.protect
    ~finally:(fun () ->
      Prompt_registry.clear ();
      cleanup_dir base_path)
    (fun () ->
      Prompt_registry.clear ();
      Prompt_registry.set_markdown_dir prompts_dir;
      Masc.Prompt_defaults.init ();
      f ~base_path ~keepers ~config)
;;

let or_fail = function
  | Ok value -> value
  | Error message -> Alcotest.fail message
;;

let set_override ~base_path value =
  match Prompt_registry.set_override_persisted ~base_path prompt_key value with
  | Ok () -> ()
  | Error (Prompt_registry.Validation_error m) | Error (Prompt_registry.Persistence_error m) ->
    Alcotest.fail m
;;

let instructions_of ~keepers =
  match Profile.load_keeper_toml (Filename.concat keepers "alpha.toml") with
  | Ok (_, defaults) -> defaults.Masc.Keeper_types_profile_defaults.instructions
  | Error e -> Alcotest.fail (Profile.keeper_toml_load_error_to_string e)
;;

let test_capture_save_load_round_trip () =
  let open Alcotest in
  with_base (fun ~base_path ~keepers:_ ~config:_ ->
    set_override ~base_path "Overridden body.";
    let snapshot = or_fail (Preset.capture ~base_path ~name:"morning" ~description:"as of 09:00") in
    check (list string) "the override keys are captured"
      [ prompt_key ]
      (List.map (fun (e : Override.entry) -> e.Override.key) snapshot.Preset.prompt_overrides);
    check (list (pair string string)) "the keeper instructions are captured"
      [ "alpha", "Do the alpha work." ]
      snapshot.Preset.instructions;
    check (list (pair string string)) "the assignments are captured"
      [ "routingtest", "openai.gpt"; "budgettest", "openai.gpt" ]
      snapshot.Preset.assignments;
    check (list string) "the exact-output lanes are captured"
      [ "librarian_exact" ]
      (List.map (fun (l : Preset.lane) -> l.Preset.id) snapshot.Preset.lanes);
    or_fail (Preset.save ~base_path snapshot);
    let loaded = or_fail (Preset.load ~base_path "morning") in
    check string "description survives" "as of 09:00" loaded.Preset.description;
    check (list (pair string string)) "instructions survive" snapshot.Preset.instructions
      loaded.Preset.instructions;
    check (list (pair string string)) "assignments survive" snapshot.Preset.assignments
      loaded.Preset.assignments;
    check (list string) "lane slots survive"
      [ "openai.gpt"; "runpod_mtp.qwen" ]
      (List.concat_map (fun (l : Preset.lane) -> l.Preset.slots) loaded.Preset.lanes);
    check string "the override value survives" "Overridden body."
      (List.hd loaded.Preset.prompt_overrides).Override.value;
    let listing = Preset.list ~base_path in
    check (list string) "the listing names the preset" [ "morning" ]
      (List.map (fun (m : Preset.manifest) -> m.Preset.preset_name) listing.Preset.presets);
    check (list (pair string string)) "nothing is unreadable" [] listing.Preset.unreadable)
;;

let test_invalid_name_is_refused () =
  let open Alcotest in
  with_base (fun ~base_path ~keepers:_ ~config:_ ->
    check bool "a path segment is not a name" false (Preset.is_valid_name "../x");
    check bool "an empty name is refused" false (Preset.is_valid_name "");
    check bool "a stamp is a name" true (Preset.is_valid_name "_autosave-20260903T120000Z");
    (match Preset.capture ~base_path ~name:"bad name" ~description:"" with
     | Error _ -> ()
     | Ok _ -> fail "a name with a space captured"))
;;

let test_restore_puts_the_saved_state_back () =
  let open Alcotest in
  with_base (fun ~base_path ~keepers ~config:_ ->
    set_override ~base_path "Morning override.";
    let morning = or_fail (Preset.capture ~base_path ~name:"morning" ~description:"") in
    or_fail (Preset.save ~base_path morning);
    (* drift: a new override value and new keeper instructions *)
    set_override ~base_path "Afternoon override.";
    write_file (Filename.concat keepers "alpha.toml") (keeper_toml "Do the afternoon work.");
    let report = or_fail (Preset.restore ~base_path "morning") in
    check string "the override is back" "Morning override." (Prompt_registry.get_prompt prompt_key);
    check (list string) "the override key is reported applied" [ prompt_key ]
      report.Preset.prompt_overrides_result.Preset.applied;
    check (option string) "the keeper instructions are back" (Some "Do the alpha work.")
      (instructions_of ~keepers);
    check (list string) "the keeper is reported applied" [ "alpha" ]
      report.Preset.instructions_result.Preset.applied;
    (match report.Preset.runtime_result with
     | Preset.Runtime_unchanged -> ()
     | Preset.Runtime_committed -> fail "runtime.toml did not drift, nothing to commit"
     | Preset.Runtime_failed message -> fail ("runtime part failed: " ^ message));
    check bool "the autosave carries the prefix" true
      (String.starts_with ~prefix:Preset.autosave_prefix report.Preset.autosave);
    let autosave = or_fail (Preset.load ~base_path report.Preset.autosave) in
    check string "the autosave holds the state from before the restore" "Afternoon override."
      (List.hd autosave.Preset.prompt_overrides).Override.value;
    check (list (pair string string)) "the autosave holds the drifted instructions"
      [ "alpha", "Do the afternoon work." ]
      autosave.Preset.instructions)
;;

let test_runtime_text_transform () =
  let open Alcotest in
  let text =
    Preset.runtime_text_with
      ~current_assignments:[ "routingtest", "openai.gpt"; "budgettest", "openai.gpt" ]
      ~assignments:[ "routingtest", "runpod_mtp.qwen" ]
      ~lanes:[ { Preset.id = "librarian_exact"; slots = [ "runpod_mtp.qwen" ]; cli_slots = [] } ]
      runtime_fixture
  in
  let has needle = contains_substring text needle in
  check bool "the operator note survives" true (has "# operator note that must survive");
  check bool "the kept keeper is reassigned, key quoted" true
    (has "\"routingtest\" = \"runpod_mtp.qwen\"");
  check bool "the dropped keeper's row is gone" false (has "budgettest");
  check bool "the provider tables survive" true (has "[providers.openai]");
  check bool "the lane slots are rewritten" true (has "  \"runpod_mtp.qwen\",");
  check bool "the old lane slot is gone" false (has "\"openai.gpt\", \"runpod_mtp.qwen\"");
  (match Preset.runtime_of_text text with
   | Ok (assignments, lanes) ->
     check (list (pair string string)) "the result parses to the preset's assignments"
       [ "routingtest", "runpod_mtp.qwen" ] assignments;
     check (list string) "the result parses to the preset's lane slots"
       [ "runpod_mtp.qwen" ] (List.concat_map (fun (l : Preset.lane) -> l.Preset.slots) lanes)
   | Error message -> fail ("transformed runtime.toml does not parse: " ^ message))
;;

let () =
  Alcotest.run
    "Prompt_preset"
    [ ( "presets"
      , [ Alcotest.test_case "capture, save, load, list round trip" `Quick
            test_capture_save_load_round_trip
        ; Alcotest.test_case "an invalid name is refused" `Quick test_invalid_name_is_refused
        ; Alcotest.test_case "restore puts the saved state back and autosaves first" `Quick
            test_restore_puts_the_saved_state_back
        ; Alcotest.test_case "the runtime.toml text transform keeps every other line" `Quick
            test_runtime_text_transform
        ] )
    ]
;;
