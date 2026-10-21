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
# Both providers back exact-output slots below; a save adding a slot whose
# provider declares no exact-body-timeout-s is refused (#38779).
exact-body-timeout-s = 120.0

[providers.openai]
display-name = "OpenAI"
protocol = "openai-compatible-http"
endpoint = "https://api.openai.example/v1"
exact-body-timeout-s = 120.0

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

[runtime.exact_output_lanes.hitl_auto_judge]
slots = [
  # judge note inside the array
  "openai.gpt",
]
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
      [ "librarian_exact"; "hitl_auto_judge" ]
      (List.map (fun (l : Preset.lane) -> (Runtime_schema.exact_lane_key l.owner)) snapshot.Preset.lanes);
    or_fail (Preset.save ~base_path snapshot);
    let loaded = or_fail (Preset.load ~base_path "morning") in
    check string "description survives" "as of 09:00" loaded.Preset.description;
    check (list (pair string string)) "instructions survive" snapshot.Preset.instructions
      loaded.Preset.instructions;
    check (list (pair string string)) "assignments survive" snapshot.Preset.assignments
      loaded.Preset.assignments;
    check (list string) "lane slots survive"
      [ "openai.gpt"; "runpod_mtp.qwen"; "openai.gpt" ]
      (List.concat_map (fun (l : Preset.lane) -> l.Preset.slots) loaded.Preset.lanes);
    check string "the override value survives" "Overridden body."
      (List.hd loaded.Preset.prompt_overrides).Override.value;
    let listing = Preset.list ~base_path in
    check (list string) "the listing names the preset" [ "morning" ]
      (List.map (fun (m : Preset.manifest) -> m.Preset.preset_name) listing.Preset.presets);
    check (list (pair string string)) "nothing is unreadable" [] listing.Preset.unreadable;
    (* A count says one override; it does not say which. Choosing between two
       presets from a list means the list has to name them. *)
    check (list string) "the listing names the overridden prompts"
      [ "test.preset" ]
      (List.hd listing.Preset.presets).Preset.override_keys;
    (* And the whole of a preset is readable without applying it, because
       applying it is the decision being made. *)
    Alcotest.(check bool) "save/load settings match" true (Preset.same_settings snapshot loaded);
    let shown = Preset.snapshot_to_json loaded in
    let field name =
      match shown with
      | `Assoc fields -> List.assoc_opt name fields
      | _ -> None
    in
    check bool "the snapshot carries the override text" true
      (match field "prompt_overrides" with
       | Some (`List [ `Assoc entry ]) ->
         List.assoc_opt "value" entry = Some (`String "Overridden body.")
       | _ -> false);
    check bool "and the keeper instructions" true
      (match field "instructions" with
       | Some (`List (_ :: _)) -> true
       | _ -> false))
;;

let test_saved_settings_ignore_snapshot_metadata () =
  with_base (fun ~base_path ~keepers:_ ~config:_ ->
    let snapshot = or_fail (Preset.capture ~base_path ~name:"morning" ~description:"first") in
    let renamed = { snapshot with Preset.name = "evening"; description = "another label";
                                  created_at = "2026-09-07T22:00:00Z" } in
    Alcotest.(check bool) "metadata is not a setting" true
      (Preset.same_settings snapshot renamed);
    Alcotest.(check bool) "unchanged durable settings match" true
      (or_fail (Preset.matches_saved_settings ~base_path renamed)))
;;

let test_saved_settings_report_invalid_keeper_toml () =
  with_base (fun ~base_path ~keepers ~config:_ ->
    let snapshot = or_fail (Preset.capture ~base_path ~name:"morning" ~description:"") in
    let broken = Filename.concat keepers "broken.toml" in
    write_file broken "[keeper\ninvalid TOML";
    let ordinary = or_fail (Preset.capture ~base_path ~name:"morning" ~description:"") in
    Alcotest.(check bool) "ordinary capture keeps its existing partial behavior" true
      (Preset.same_settings snapshot ordinary);
    match Preset.matches_saved_settings ~base_path snapshot with
    | Ok _ -> Alcotest.fail "an unreadable Keeper cannot produce a settings verdict"
    | Error detail -> Alcotest.(check bool) "comparison names the unreadable TOML" true
        (contains_substring detail broken))
;;

let test_saved_settings_read_durable_overrides_without_reloading () =
  with_base (fun ~base_path ~keepers:_ ~config ->
    set_override ~base_path "Live original.";
    let snapshot = or_fail (Preset.capture ~base_path ~name:"morning" ~description:"") in
    let live = Prompt_registry.persisted_entries () in
    let path = Filename.concat (Filename.dirname config) "prompt_overrides.json" in
    let changed = List.map (fun (entry : Override.entry) ->
        { entry with value = "Changed directly on disk." }) live in
    (match Override.save ~path changed with
     | Ok () -> () | Error error -> Alcotest.fail (Override.error_to_string error));
    Alcotest.(check bool) "disk drift is visible even while the live registry matches" false
      (or_fail (Preset.matches_saved_settings ~base_path snapshot));
    Alcotest.(check bool) "comparison does not reload the live registry" true
      (Prompt_registry.persisted_entries () = live);
    write_file path "{invalid json";
    (match Preset.matches_saved_settings ~base_path snapshot with
     | Ok _ -> Alcotest.fail "corrupt durable overrides cannot produce a settings verdict"
     | Error detail -> Alcotest.(check bool) "comparison names the corrupt override file" true
         (contains_substring detail path));
    Alcotest.(check bool) "corruption does not clear the live registry" true
      (Prompt_registry.persisted_entries () = live))
;;

let test_invalid_name_is_refused () =
  let open Alcotest in
  with_base (fun ~base_path ~keepers:_ ~config:_ ->
    check bool "a path segment is not a name" false (Preset.is_valid_name "../x");
    check bool "an empty name is refused" false (Preset.is_valid_name "");
    check bool "the autosave name is a name" true (Preset.is_valid_name Preset.autosave_name);
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
     | Preset.Runtime_committed _ -> fail "runtime.toml did not drift, nothing to commit"
     | Preset.Runtime_failed message -> fail ("runtime part failed: " ^ message));
    check string "the restore names the autosave" Preset.autosave_name report.Preset.autosave;
    let autosave = or_fail (Preset.load ~base_path report.Preset.autosave) in
    check string "the autosave holds the state from before the restore" "Afternoon override."
      (List.hd autosave.Preset.prompt_overrides).Override.value;
    check (list (pair string string)) "the autosave holds the drifted instructions"
      [ "alpha", "Do the afternoon work." ]
      autosave.Preset.instructions)
;;

(* A preset saved before a release changed the default is still the
   operator's prompt. It restores, and it keeps the binding it was captured
   with, so the catalog can say the default moved under it rather than
   presenting it as written against today's text. *)
let test_restore_preserves_manifest_while_journal_retained () =
  let open Alcotest in
  with_base (fun ~base_path ~keepers ~config:_ ->
    let morning = or_fail (Preset.capture ~base_path ~name:"guarded" ~description:"") in
    or_fail (Preset.save ~base_path morning);
    write_file (Filename.concat keepers "alpha.toml") (keeper_toml "Keep this edit.");
    let journal_path = Keeper_config_journal.journal_path_for_base_path ~base_path in
    write_file journal_path "{corrupt";
    let report = or_fail (Preset.restore ~base_path "guarded") in
    check (list string) "no manifest restoration was applied" []
      report.Preset.instructions_result.Preset.applied;
    check (option string) "retained journal preserves newer instructions" (Some "Keep this edit.")
      (instructions_of ~keepers);
    check bool "instruction failure is reported" true
      (List.mem_assoc "alpha" report.Preset.instructions_result.Preset.skipped))
;;

let test_override_written_against_an_older_default_still_restores () =
  let open Alcotest in
  with_base (fun ~base_path ~keepers:_ ~config:_ ->
    set_override ~base_path "Morning override.";
    let morning = or_fail (Preset.capture ~base_path ~name:"morning" ~description:"") in
    let older =
      { morning with
        Preset.name = "older"
      ; prompt_overrides =
          List.map
            (fun (e : Override.entry) -> { e with Override.authored_against = "0000" })
            morning.Preset.prompt_overrides
      }
    in
    or_fail (Preset.save ~base_path older);
    set_override ~base_path "Afternoon override.";
    let report = or_fail (Preset.restore ~base_path "older") in
    check (list string) "the override is applied" [ prompt_key ]
      report.Preset.prompt_overrides_result.Preset.applied;
    check (list string) "nothing is skipped" []
      (List.map fst report.Preset.prompt_overrides_result.Preset.skipped);
    check string "a turn gets the restored text" "Morning override."
      (Prompt_registry.get_prompt prompt_key);
    check (list string) "and it still says what it was written against" [ "0000" ]
      (List.map
         (fun (e : Override.entry) -> e.Override.authored_against)
         (Prompt_registry.override_entries ())))
;;

(* What still refuses a preset entry: it names a variable the prompt does
   not declare, so it could not render. *)
let test_override_that_cannot_render_is_skipped_with_the_reason () =
  let open Alcotest in
  with_base (fun ~base_path ~keepers:_ ~config:_ ->
    set_override ~base_path "Morning override.";
    let morning = or_fail (Preset.capture ~base_path ~name:"morning" ~description:"") in
    let unrenderable =
      { morning with
        Preset.name = "unrenderable"
      ; prompt_overrides =
          List.map
            (fun (e : Override.entry) -> { e with Override.value = "Facts {{facts_json}}" })
            morning.Preset.prompt_overrides
      }
    in
    or_fail (Preset.save ~base_path unrenderable);
    set_override ~base_path "Afternoon override.";
    let report = or_fail (Preset.restore ~base_path "unrenderable") in
    check (list string) "nothing is applied" []
      report.Preset.prompt_overrides_result.Preset.applied;
    (match report.Preset.prompt_overrides_result.Preset.skipped with
     | [ (key, reason) ] ->
       check string "skipped under its key" prompt_key key;
       check bool "with the variable named" true (contains_substring reason "facts_json")
     | skipped -> fail (Printf.sprintf "expected one skip, found %d" (List.length skipped)));
    check string "the live override is untouched" "Afternoon override."
      (Prompt_registry.get_prompt prompt_key))
;;

(* A restore replaces the autosave rather than adding one: however many
   restores run, the list holds one autosave, and it holds the state from
   before the latest. *)
let test_a_second_restore_replaces_the_autosave () =
  let open Alcotest in
  with_base (fun ~base_path ~keepers:_ ~config:_ ->
    set_override ~base_path "Morning override.";
    let morning = or_fail (Preset.capture ~base_path ~name:"morning" ~description:"") in
    or_fail (Preset.save ~base_path morning);
    set_override ~base_path "Noon override.";
    let _first = or_fail (Preset.restore ~base_path "morning") in
    set_override ~base_path "Evening override.";
    let second = or_fail (Preset.restore ~base_path "morning") in
    check string "the second restore writes the same autosave" Preset.autosave_name
      second.Preset.autosave;
    let names =
      List.map (fun (m : Preset.manifest) -> m.Preset.preset_name) (Preset.list ~base_path).Preset.presets
    in
    check (list string) "one autosave beside the saved preset"
      [ Preset.autosave_name; "morning" ] (List.sort String.compare names);
    let autosave = or_fail (Preset.load ~base_path Preset.autosave_name) in
    check string "the autosave holds the state from before the latest restore"
      "Evening override." (List.hd autosave.Preset.prompt_overrides).Override.value)
;;

(* A save that fails partway leaves the preset it was replacing whole. The
   autosave is the one copy of the state from before a restore, so a restore
   whose autosave fails must not cost the previous one. The instruction file
   for a keeper name longer than a file name may be fails after the overrides
   and runtime files are written. *)
let test_a_failed_save_keeps_the_preset_it_was_replacing () =
  let open Alcotest in
  with_base (fun ~base_path ~keepers:_ ~config:_ ->
    set_override ~base_path "Morning override.";
    let morning = or_fail (Preset.capture ~base_path ~name:"morning" ~description:"") in
    or_fail (Preset.save ~base_path morning);
    let broken =
      { morning with
        Preset.prompt_overrides = []
      ; instructions = [ String.make 300 'k', "Never written." ]
      }
    in
    (match Preset.save ~base_path broken with
     | Ok () -> fail "an instruction file with a 304-byte name was written"
     | Error _ -> ());
    let kept = or_fail (Preset.load ~base_path "morning") in
    check string "the saved override is still there" "Morning override."
      (List.hd kept.Preset.prompt_overrides).Override.value;
    check (list (pair string string)) "the saved instructions are still there"
      morning.Preset.instructions kept.Preset.instructions;
    let listing = Preset.list ~base_path in
    check (list string) "only the saved preset is listed" [ "morning" ]
      (List.map (fun (m : Preset.manifest) -> m.Preset.preset_name) listing.Preset.presets);
    check (list string) "nothing is unreadable" [] (List.map fst listing.Preset.unreadable);
    let staging = Filename.concat (Config_dir_resolver.masc_root ~base_path) "presets-staging" in
    check (array string) "no holder is left behind" [||] (Sys.readdir staging))
;;

(* Restoring the autosave undoes the latest restore: the state from before it
   comes back, and the autosave then holds the state the undo replaced. *)
let test_restoring_the_autosave_undoes_the_latest_restore () =
  let open Alcotest in
  with_base (fun ~base_path ~keepers:_ ~config:_ ->
    set_override ~base_path "Morning override.";
    let morning = or_fail (Preset.capture ~base_path ~name:"morning" ~description:"") in
    or_fail (Preset.save ~base_path morning);
    set_override ~base_path "Evening override.";
    let _restore = or_fail (Preset.restore ~base_path "morning") in
    check string "the morning override is live" "Morning override."
      (Prompt_registry.get_prompt prompt_key);
    let undo = or_fail (Preset.restore ~base_path Preset.autosave_name) in
    check string "the evening override is back" "Evening override."
      (Prompt_registry.get_prompt prompt_key);
    check string "the undo reports the autosave as restored" Preset.autosave_name
      undo.Preset.restored;
    let autosave = or_fail (Preset.load ~base_path Preset.autosave_name) in
    check string "the autosave now holds the state the undo replaced" "Morning override."
      (List.hd autosave.Preset.prompt_overrides).Override.value)
;;

(* The list and the detail read a preset one way. A preset whose overrides
   file no longer reads is not listed as though it opens: it is unreadable,
   with the reason loading it gives. *)
let test_a_preset_that_does_not_load_is_listed_as_unreadable () =
  let open Alcotest in
  with_base (fun ~base_path ~keepers:_ ~config:_ ->
    let morning = or_fail (Preset.capture ~base_path ~name:"morning" ~description:"") in
    or_fail (Preset.save ~base_path morning);
    let evening = or_fail (Preset.capture ~base_path ~name:"evening" ~description:"") in
    or_fail (Preset.save ~base_path evening);
    write_file
      (Filename.concat (Preset.source_directory ~base_path evening) "prompt_overrides.json")
      {|{"schema_version":1,"overrides":[]}|};
    let reason =
      match Preset.load ~base_path "evening" with
      | Ok _ -> fail "an overrides file of another schema loaded"
      | Error reason -> reason
    in
    check bool "the reason names the schema it could not read" true
      (contains_substring reason "schema_version 1");
    check bool "the reason names the schema this build reads" true
      (contains_substring reason "reads only schema_version 2");
    check bool "the reason says how to get the prompts back" true
      (contains_substring reason "set its prompts again and save them as a new preset");
    let listing = Preset.list ~base_path in
    check (list string) "only the preset that opens is listed" [ "morning" ]
      (List.map (fun (m : Preset.manifest) -> m.Preset.preset_name) listing.Preset.presets);
    check (list (pair string string)) "the other is unreadable, for the reason load gives"
      [ ("evening", reason) ] listing.Preset.unreadable)
;;

(* Delete removes a preset whether or not it loads. A preset saved in an
   older overrides format cannot be restored, so deleting it is what the
   operator can still do with it; the list then holds neither. *)
let test_delete_removes_a_preset_whether_or_not_it_loads () =
  let open Alcotest in
  with_base (fun ~base_path ~keepers:_ ~config:_ ->
    let morning = or_fail (Preset.capture ~base_path ~name:"morning" ~description:"") in
    or_fail (Preset.save ~base_path morning);
    let evening = or_fail (Preset.capture ~base_path ~name:"evening" ~description:"") in
    or_fail (Preset.save ~base_path evening);
    write_file
      (Filename.concat (Preset.source_directory ~base_path evening) "prompt_overrides.json")
      {|{"schema_version":1,"overrides":[]}|};
    let delete name =
      match Preset.delete ~base_path name with
      | Ok () -> ()
      | Error error -> fail (Preset.delete_error_to_string error)
    in
    delete "morning";
    delete "evening";
    let listing = Preset.list ~base_path in
    check (list string) "no preset is listed" []
      (List.map (fun (m : Preset.manifest) -> m.Preset.preset_name) listing.Preset.presets);
    check (list string) "no preset is unreadable" []
      (List.map fst listing.Preset.unreadable);
    check bool "the directory is gone" false
      (Sys.file_exists (Preset.source_directory ~base_path evening));
    let staging = Filename.concat (Config_dir_resolver.masc_root ~base_path) "presets-staging" in
    check (array string) "no holder is left behind" [||] (Sys.readdir staging);
    (match Preset.delete ~base_path "morning" with
     | Error (Preset.Delete_not_found "morning") -> ()
     | Error error -> fail ("wrong refusal: " ^ Preset.delete_error_to_string error)
     | Ok () -> fail "a preset deleted twice was found the second time"))
;;

(* A link left at a preset's place whose target is gone is listed as
   unreadable, so delete removes it too. *)
let test_delete_removes_a_dangling_link () =
  let open Alcotest in
  with_base (fun ~base_path ~keepers:_ ~config:_ ->
    let morning = or_fail (Preset.capture ~base_path ~name:"morning" ~description:"") in
    or_fail (Preset.save ~base_path morning);
    let presets = Filename.dirname (Preset.source_directory ~base_path morning) in
    Unix.symlink (Filename.concat presets "never-there") (Filename.concat presets "ghost");
    check (list string) "the link is listed as unreadable" [ "ghost" ]
      (List.map fst (Preset.list ~base_path).Preset.unreadable);
    (match Preset.delete ~base_path "ghost" with
     | Ok () -> ()
     | Error error -> fail (Preset.delete_error_to_string error));
    check (list string) "nothing is unreadable" []
      (List.map fst (Preset.list ~base_path).Preset.unreadable))
;;

let test_delete_refuses_a_missing_or_invalid_name () =
  let open Alcotest in
  with_base (fun ~base_path ~keepers:_ ~config:_ ->
    (match Preset.delete ~base_path "never-saved" with
     | Error (Preset.Delete_not_found "never-saved") -> ()
     | Error error -> fail ("wrong refusal: " ^ Preset.delete_error_to_string error)
     | Ok () -> fail "a preset that was never saved was deleted");
    (match Preset.delete ~base_path ".." with
     | Error (Preset.Delete_invalid_name "..") -> ()
     | Error error -> fail ("wrong refusal: " ^ Preset.delete_error_to_string error)
     | Ok () -> fail "the parent directory name was accepted"))
;;

(* A preset is opened, listed and restored by its directory's name. A
   directory copied under a new name keeps the original's name in its
   manifest, and listed from it the copy's row would open the original. *)
let test_a_manifest_naming_another_preset_does_not_load () =
  let open Alcotest in
  with_base (fun ~base_path ~keepers:_ ~config:_ ->
    let morning = or_fail (Preset.capture ~base_path ~name:"morning" ~description:"") in
    or_fail (Preset.save ~base_path morning);
    let copy = or_fail (Preset.capture ~base_path ~name:"morning-v2" ~description:"") in
    or_fail (Preset.save ~base_path copy);
    let manifest = Filename.concat (Preset.source_directory ~base_path copy) "manifest.json" in
    let renamed =
      match Yojson.Safe.from_file manifest with
      | `Assoc fields ->
          `Assoc
            (List.map
               (fun (key, value) ->
                 if String.equal key "name" then (key, `String "morning") else (key, value))
               fields)
      | other -> other
    in
    Yojson.Safe.to_file manifest renamed;
    (match Preset.load ~base_path "morning-v2" with
     | Ok _ -> fail "a copied directory opened under the original's name"
     | Error reason ->
         check bool "the reason names both" true
           (contains_substring reason "morning" && contains_substring reason "morning-v2"));
    let listing = Preset.list ~base_path in
    check (list string) "the original alone is listed" [ "morning" ]
      (List.map (fun (m : Preset.manifest) -> m.Preset.preset_name) listing.Preset.presets);
    check (list string) "the copy is unreadable" [ "morning-v2" ]
      (List.map fst listing.Preset.unreadable))
;;

let test_runtime_text_transform () =
  let open Alcotest in
  let text =
    Preset.runtime_text_with
      ~current_assignments:[ "routingtest", "openai.gpt"; "budgettest", "openai.gpt" ]
      ~current_lanes:
        [ { Preset.owner = Runtime_schema.Builtin Standalone_lane.Librarian; enabled = true; slots = [ "openai.gpt"; "runpod_mtp.qwen" ]; cli_slots = []; max_output_tokens = None; thinking = None }
        ; { Preset.owner = Runtime_schema.Builtin Standalone_lane.Hitl_auto_judge; enabled = true; slots = [ "openai.gpt" ]; cli_slots = []; max_output_tokens = None; thinking = None }
        ]
      ~assignments:[ "routingtest", "runpod_mtp.qwen" ]
      ~lanes:
        [ { Preset.owner = Runtime_schema.Builtin Standalone_lane.Librarian; enabled = true; slots = [ "runpod_mtp.qwen" ]; cli_slots = []; max_output_tokens = None; thinking = None }
        ; { Preset.owner = Runtime_schema.Builtin Standalone_lane.Hitl_auto_judge; enabled = true; slots = [ "openai.gpt" ]; cli_slots = []; max_output_tokens = None; thinking = None }
        ]
      runtime_fixture
  in
  let has needle = contains_substring text needle in
  check bool "a lane whose slots already match keeps its inner comment" true
    (has "  # judge note inside the array");
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
       [ "runpod_mtp.qwen"; "openai.gpt" ]
       (List.concat_map (fun (l : Preset.lane) -> l.Preset.slots) lanes)
   | Error message -> fail ("transformed runtime.toml does not parse: " ^ message))
;;

(* RFC operator-quiz §4.3 K1: a preset captures an add-on lane like a
   built-in one and writes it back into its own [runtime.addon_exact_lanes]
   table. *)
let test_runtime_text_carries_addon_lanes () =
  let open Alcotest in
  List.iter (fun (declaration_id, header) ->
  let author = Runtime_schema.Addon (Result.get_ok (Runtime_schema.addon_lane ~declaration_id ~output:"author")) in
  let source =
    runtime_fixture ^ "\n" ^ header ^ "\nslots = [\"openai.gpt\"]\n"
  in
  let captured =
    match Preset.runtime_of_text source with
    | Ok (_, lanes) -> lanes
    | Error message -> fail ("runtime.toml with an add-on lane does not parse: " ^ message)
  in
  check bool "capture includes the add-on lane" true
    (List.exists (fun (lane : Preset.lane) ->
         Runtime_schema.equal_exact_lane_owner lane.Preset.owner author) captured);
  let text =
    Preset.runtime_text_with ~current_assignments:[] ~current_lanes:captured ~assignments:[]
      ~lanes:[ { Preset.owner = author; enabled = false; slots = [ "runpod_mtp.qwen" ]; cli_slots = []; max_output_tokens = None; thinking = None } ]
      source
  in
  match Preset.runtime_of_text text with
  | Error message -> fail ("restored runtime.toml does not parse: " ^ message)
  | Ok (_, lanes) ->
    (match List.find_opt (fun (lane : Preset.lane) ->
         Runtime_schema.equal_exact_lane_owner lane.Preset.owner author) lanes with
     | Some lane ->
       check (list string) (declaration_id ^ ": the add-on table takes the preset's slots")
         [ "runpod_mtp.qwen" ] lane.Preset.slots;
       check bool (declaration_id ^ ": and its activity") false lane.Preset.enabled
     | None -> fail (declaration_id ^ ": the add-on lane is gone after restore")))
    [ "operator-quiz", "[runtime.addon_exact_lanes.operator-quiz.author]";
      "team.quiz", "[runtime.addon_exact_lanes.\"team.quiz\".author]" ]
;;

(* The lane's two optional request settings are part of what a preset carries
   (#38216): present in the preset they are written into the lane table, absent
   in the preset they are removed from it, and the lane notes around them stay. *)
let test_runtime_text_carries_the_lane_request_settings () =
  let open Alcotest in
  let lane ~max_output_tokens ~thinking =
    { Preset.owner = Runtime_schema.Builtin Standalone_lane.Librarian
    ; enabled = true
    ; slots = [ "openai.gpt"; "runpod_mtp.qwen" ]
    ; cli_slots = []
    ; max_output_tokens
    ; thinking
    }
  in
  let apply ~current ~wanted content =
    let text =
      Preset.runtime_text_with
        ~current_assignments:[]
        ~current_lanes:[ current ]
        ~assignments:[]
        ~lanes:[ wanted ]
        content
    in
    match Preset.runtime_of_text text with
    | Ok (_, lanes) ->
      (match List.find_opt (fun (l : Preset.lane) -> l.Preset.owner = Runtime_schema.Builtin Standalone_lane.Librarian) lanes with
       | Some found -> text, found
       | None -> fail "the lane is gone after the edit")
    | Error message -> fail ("edited runtime.toml does not parse: " ^ message)
  in
  let declared = lane ~max_output_tokens:(Some 4096) ~thinking:(Some false) in
  let undeclared = lane ~max_output_tokens:None ~thinking:None in
  (* A lane table that declares neither: the preset's values are added. *)
  let text, found = apply ~current:undeclared ~wanted:declared runtime_fixture in
  check (option int) "the budget is written" (Some 4096) found.Preset.max_output_tokens;
  check (option bool) "thinking is written" (Some false) found.Preset.thinking;
  check bool "the operator note survives" true
    (contains_substring text "# operator note that must survive");
  (* The file holds them, the preset declares none: they are removed, so the
     restored file reads back as the preset captured it. *)
  let text, found = apply ~current:declared ~wanted:undeclared text in
  check (option int) "the budget is removed" None found.Preset.max_output_tokens;
  check (option bool) "thinking is removed" None found.Preset.thinking;
  check bool "the budget line is gone from the text" false
    (contains_substring text "max_output_tokens");
  (* A different value replaces the old one. *)
  let text, _ = apply ~current:undeclared ~wanted:declared runtime_fixture in
  let _, found =
    apply ~current:declared
      ~wanted:(lane ~max_output_tokens:(Some 8192) ~thinking:(Some true)) text
  in
  check (option int) "the budget is replaced" (Some 8192) found.Preset.max_output_tokens;
  check (option bool) "thinking is replaced" (Some true) found.Preset.thinking;
  (* A setting that already holds is not rewritten: the integer writer replaces
     the whole line, so rewriting an unchanged budget would drop its comment. *)
  let commented =
    Toml_line_editor.edit_table_int runtime_fixture
      ~path:"runtime.exact_output_lanes.librarian_exact" ~key:"max_output_tokens" ~value:4096
    |> fun text ->
    let marker = "max_output_tokens = 4096" in
    let i =
      let rec find i = if String.sub text i (String.length marker) = marker then i else find (i + 1) in
      find 0
    in
    String.sub text 0 (i + String.length marker) ^ " # provider cap, do not raise"
    ^ String.sub text (i + String.length marker) (String.length text - i - String.length marker)
  in
  let text, found =
    apply ~current:declared
      ~wanted:(lane ~max_output_tokens:(Some 4096) ~thinking:(Some true))
      (Toml_line_editor.edit_table_bool commented
         ~path:"runtime.exact_output_lanes.librarian_exact" ~key:"thinking" ~value:false)
  in
  check (option int) "the unchanged budget still reads 4096" (Some 4096) found.Preset.max_output_tokens;
  check (option bool) "the changed flag is rewritten" (Some true) found.Preset.thinking;
  check bool "the unchanged budget keeps its trailing comment" true
    (contains_substring text "max_output_tokens = 4096 # provider cap, do not raise")
;;

let test_saved_lane_request_settings_shape () =
  with_base (fun ~base_path ~keepers:_ ~config ->
    let path = Filename.concat config "runtime.toml" in
    let librarian = "runtime.exact_output_lanes.librarian_exact" in
    write_file path
      (Toml_line_editor.edit_table_bool
         (Toml_line_editor.edit_table_int runtime_fixture ~path:librarian
            ~key:"max_output_tokens" ~value:4096)
         ~path:librarian ~key:"thinking" ~value:false);
    let saved = or_fail (Preset.capture ~base_path ~name:"settings" ~description:"") in
    let lane_of (snapshot : Preset.snapshot) id =
      List.find (fun (l : Preset.lane) -> Runtime_schema.exact_lane_key l.Preset.owner = id) snapshot.Preset.lanes
    in
    Alcotest.(check (option int)) "capture reads the budget" (Some 4096)
      (lane_of saved "librarian_exact").Preset.max_output_tokens;
    Alcotest.(check (option bool)) "capture reads thinking" (Some false)
      (lane_of saved "librarian_exact").Preset.thinking;
    Alcotest.(check (option int)) "a lane that declares none captures none" None
      (lane_of saved "hitl_auto_judge").Preset.max_output_tokens;
    or_fail (Preset.save ~base_path saved);
    let loaded = or_fail (Preset.load ~base_path "settings") in
    Alcotest.(check bool) "the lanes read back as saved" true
      (loaded.Preset.lanes = saved.Preset.lanes);
    (* A lane that declares none is saved as null, not left out. *)
    let runtime_json_path = Filename.concat (Preset.source_directory ~base_path saved) "runtime.json" in
    let saved_lane id =
      match Yojson.Safe.from_file runtime_json_path with
      | `Assoc fields ->
        (match List.assoc_opt "exact_output_lanes" fields with
         | Some (`Assoc lanes) ->
           (match List.assoc_opt id lanes with
            | Some (`Assoc lane_fields) -> lane_fields
            | _ -> Alcotest.failf "saved lane %s is missing" id)
         | _ -> Alcotest.fail "saved lanes must be an object")
      | _ -> Alcotest.fail "saved runtime must be an object"
    in
    Alcotest.(check bool) "an undeclared budget is written as null" true
      (List.assoc_opt "max_output_tokens" (saved_lane "hitl_auto_judge") = Some `Null);
    Alcotest.(check bool) "an undeclared thinking flag is written as null" true
      (List.assoc_opt "thinking" (saved_lane "hitl_auto_judge") = Some `Null);
    (* A preset saved before these were kept has no keys. Restoring it would
       have to guess between keeping and removing what the file declares, so it
       is refused with what to do. A value of another type, or a budget that is
       not positive, is refused rather than coerced. *)
    let runtime_json = Filename.concat (Preset.source_directory ~base_path saved) "runtime.json" in
    let original = Yojson.Safe.from_file runtime_json in
    let with_lane_fields change =
      match original with
      | `Assoc fields ->
        `Assoc (List.map (fun (key, value) ->
          if key <> "exact_output_lanes" then key, value else
          key, (match value with
            | `Assoc lanes -> `Assoc (List.map (fun (id, lane) ->
              id, (match lane with
                | `Assoc lane_fields -> `Assoc (change lane_fields)
                | _ -> Alcotest.fail "saved lane must be an object")) lanes)
            | _ -> Alcotest.fail "saved lanes must be an object")) fields)
      | _ -> Alcotest.fail "saved runtime must be an object" in
    List.iter (fun key ->
      Yojson.Safe.to_file runtime_json
        (with_lane_fields (fun fields -> List.remove_assoc key fields));
      match Preset.load ~base_path "settings" with
      | Error detail ->
        Alcotest.(check bool) ("a preset without " ^ key ^ " is refused naming it") true
          (contains_substring detail key);
        Alcotest.(check bool) "and the reason says how to get past it" true
          (contains_substring detail "save the current state as a new preset")
      | Ok _ -> Alcotest.failf "a preset without %s was accepted" key)
      [ "max_output_tokens"; "thinking" ];
    List.iter (fun (label, key, bad) ->
      Yojson.Safe.to_file runtime_json
        (with_lane_fields (fun fields -> (key, bad) :: List.remove_assoc key fields));
      match Preset.load ~base_path "settings" with
      | Error detail ->
        Alcotest.(check bool) (label ^ " is refused naming the key") true
          (contains_substring detail key)
      | Ok _ -> Alcotest.failf "%s was accepted" label)
      [ "a string budget", "max_output_tokens", `String "4096"
      ; "a zero budget", "max_output_tokens", `Int 0
      ; "a negative budget", "max_output_tokens", `Int (-1)
      ; "a string thinking flag", "thinking", `String "false" ])
;;

let test_saved_lane_activity_shape () =
  with_base (fun ~base_path ~keepers:_ ~config:_ ->
    let snapshot = or_fail (Preset.capture ~base_path ~name:"activity-shape" ~description:"") in
    or_fail (Preset.save ~base_path snapshot);
    let path = Filename.concat (Preset.source_directory ~base_path snapshot) "runtime.json" in
    let original = Yojson.Safe.from_file path in
    let with_activity enabled =
      match original with
      | `Assoc fields -> `Assoc (List.map (fun (key, value) ->
        if key <> "exact_output_lanes" then key, value else
        key, (match value with
          | `Assoc lanes -> `Assoc (List.map (fun (id, lane) ->
            id, (match lane with
              | `Assoc fields -> `Assoc (enabled @ List.remove_assoc "enabled" fields)
              | _ -> Alcotest.fail "saved lane must be an object")) lanes)
          | _ -> Alcotest.fail "saved lanes must be an object")) fields)
      | _ -> Alcotest.fail "saved runtime must be an object" in
    (* A preset saved before lanes carried activity has no [enabled]; every
       lane in it was live, so it loads with each lane enabled. *)
    Yojson.Safe.to_file path (with_activity []);
    (match Preset.load ~base_path "activity-shape" with
     | Ok legacy ->
       Alcotest.(check bool) "a legacy preset lists lanes" true (legacy.Preset.lanes <> []);
       List.iter (fun (lane : Preset.lane) ->
         Alcotest.(check bool) ("legacy lane " ^ (Runtime_schema.exact_lane_key lane.owner) ^ " is enabled") true lane.enabled)
         legacy.Preset.lanes
     | Error detail -> Alcotest.failf "a legacy preset without activity must load: %s" detail);
    (* A present value that is not a boolean is still refused, not coerced. *)
    Yojson.Safe.to_file path (with_activity ["enabled", `String "false"]);
    match Preset.load ~base_path "activity-shape" with
    | Error detail -> Alcotest.(check bool) "mistyped activity is explicitly refused" true
        (contains_substring detail "enabled must be a boolean")
    | Ok _ -> Alcotest.fail "mistyped activity was coerced")
;;

let test_restore_preserves_lane_activity_and_autosave () =
  let open Alcotest in
  let previous_catalog = Llm_provider.Model_catalog.global () in
  let previous_runtime = Runtime.For_testing.snapshot () in
  let catalog = or_fail (Llm_provider.Model_catalog.of_toml_string ~source:"preset activity fixture"
    "[[models]]\nid_prefix = \"qwen\"\nprovider_name = \"runpod_mtp\"\nbase = \"openai_chat\"\nmax_context_tokens = 128000\n\n[[models]]\nid_prefix = \"gpt\"\nprovider_name = \"openai\"\nbase = \"openai_chat\"\nmax_context_tokens = 64000\n") in
  Fun.protect ~finally:(fun () ->
    Runtime.For_testing.restore previous_runtime;
    match previous_catalog with
    | Some catalog -> Llm_provider.Model_catalog.set_global catalog
    | None -> Llm_provider.Model_catalog.clear_global ()) @@ fun () ->
  Llm_provider.Model_catalog.set_global catalog;
  List.iter (fun saved_enabled ->
    with_base (fun ~base_path ~keepers:_ ~config ->
      let path = Filename.concat config "runtime.toml" in
      let fixture = Toml_line_editor.edit_table_multiline_array
        (runtime_fixture ^ "\n[runpod_mtp.qwen]\n\n[openai.gpt]\n")
        ~path:"runtime.exact_output_lanes.librarian_exact" ~key:"slots"
        ~values:["openai.gpt"; "runpod_mtp.qwen"] in
      let rec add_note = function
        | line :: rest when String.trim line = "slots = [" ->
          line :: "  # retained candidate note" :: rest
        | line :: rest -> line :: add_note rest
        | [] -> fail "fixture has no candidate array" in
      let fixture = String.concat "\n" (add_note (String.split_on_char '\n' fixture)) in
      let set_activity enabled =
        write_file path (Toml_line_editor.edit_table_bool fixture
          ~path:"runtime.exact_output_lanes.librarian_exact" ~key:"enabled" ~value:enabled)
      in
      set_activity saved_enabled;
      let saved = or_fail (Preset.capture ~base_path ~name:"activity" ~description:"") in
      or_fail (Preset.save ~base_path saved);
      let loaded = or_fail (Preset.load ~base_path "activity") in
      let librarian lanes = List.find (fun (lane : Preset.lane) -> (Runtime_schema.exact_lane_key lane.owner) = "librarian_exact") lanes in
      check bool "saved activity survives preset JSON" saved_enabled (librarian loaded.lanes).enabled;
      set_activity (not saved_enabled);
      check bool "same candidates with changed activity are a drift" false
        (or_fail (Preset.matches_saved_settings ~base_path loaded));
      let report = or_fail (Preset.restore ~base_path "activity") in
      (match report.runtime_result with
       | Preset.Runtime_committed _ -> ()
       | Preset.Runtime_unchanged -> fail "activity drift must commit"
       | Preset.Runtime_failed error -> fail error);
      let restored = or_fail (Preset.capture ~base_path ~name:"restored" ~description:"") in
      check bool "restore reinstates the saved activity" saved_enabled (librarian restored.lanes).enabled;
      check bool "activity-only restore preserves candidate notes" true
        (contains_substring (Fs_compat.load_file path) "# retained candidate note");
      check (list string) "restore retains exactly the candidates"
        (librarian saved.lanes).slots (librarian restored.lanes).slots;
      let autosave = or_fail (Preset.load ~base_path report.autosave) in
      check bool "autosave retains pre-restore activity" (not saved_enabled)
        (librarian autosave.lanes).enabled)) [false; true]
;;

(* The overrides file is read through [Fs_compat], so inside Eio the read runs
   on a system thread and another fiber runs while it is read (#39273). A read
   made in place would finish before the second fiber starts. The outcomes are
   the ones the in-place read gave: a value, a typed read failure for a missing
   file, a typed JSON failure for a broken one. *)
let test_override_load_reads_under_an_installed_eio_fs () =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () ->
      Fs_compat.clear_fs ();
      cleanup_dir dir)
    (fun () ->
      let path = Filename.concat dir "prompt_overrides.json" in
      let entry =
        { Override.key = prompt_key
        ; value = "edited"
        ; authored_against = Override.default_revision ~body:"default"
        ; template_variables = []
        }
      in
      (match Override.save ~path [ entry ] with
       | Ok () -> ()
       | Error error -> Alcotest.fail (Override.error_to_string error));
      let other_fiber_ran = ref false in
      let other_fiber_ran_before_load_returned = ref false in
      Eio.Fiber.both
        (fun () ->
          (match Override.load ~path with
           | Ok [ loaded ] ->
             Alcotest.(check string) "the saved value is read back" "edited" loaded.Override.value
           | Ok entries -> Alcotest.failf "expected one entry, read %d" (List.length entries)
           | Error error -> Alcotest.fail (Override.error_to_string error));
          other_fiber_ran_before_load_returned := !other_fiber_ran)
        (fun () -> other_fiber_ran := true);
      Alcotest.(check bool)
        "another fiber runs while the file is read"
        true
        !other_fiber_ran_before_load_returned;
      (match Override.load ~path:(Filename.concat dir "absent.json") with
       | Error (Override.Read_failed _) -> ()
       | Ok _ | Error _ -> Alcotest.fail "a missing file is a read failure");
      write_file path "{";
      match Override.load ~path with
      | Error (Override.Invalid_json _) -> ()
      | Ok _ | Error _ -> Alcotest.fail "a broken file is a JSON failure")
;;

let test_default_baseline_survives_drift_and_restore () =
  with_base (fun ~base_path ~keepers:_ ~config:_ ->
    let prompts_dir = Filename.concat base_path "prompts" in
    write_file (Filename.concat prompts_dir "test.unoverridden.md")
      "---\ndescription: unoverridden\ncategory: test\n---\nUntouched default.\n";
    Prompt_registry.set_markdown_dir prompts_dir;
    set_override ~base_path "Saved override.";
    let saved = or_fail (Preset.capture ~base_path ~name:"baseline" ~description:"") in
    let saved_hash = match saved.default_revisions with
      | Some rows -> List.assoc prompt_key rows
      | None -> Alcotest.fail "capture must record default bodies" in
    let body = Option.get (Prompt_registry.resolve_prompt prompt_key).file_value in
    let untouched_body = Option.get (Prompt_registry.resolve_prompt "test.unoverridden").file_value in
    Alcotest.(check bool) "unoverridden defaults are also recorded" true
      (match saved.default_revisions with
       | None -> false
       | Some rows -> List.assoc_opt "test.unoverridden" rows =
           Some (Override.default_revision ~body:untouched_body));
    Alcotest.(check string) "hash is the default, not the override"
      (Override.default_revision ~body) saved_hash;
    or_fail (Preset.save ~base_path saved);
    let loaded = or_fail (Preset.load ~base_path "baseline") in
    Alcotest.(check bool) "baseline loads unchanged" true
      (loaded.default_revisions = saved.default_revisions);
    Alcotest.(check bool) "defaults initially match" true
      (Preset.compare_defaults loaded = Preset.Defaults_match);
    let path = Filename.concat (Filename.concat base_path "prompts") (prompt_key ^ ".md") in
    write_file path "---\ndescription: changed\ncategory: test\n---\nNew default body.\n";
    let current = Option.get (Prompt_registry.resolve_prompt prompt_key).file_value in
    let expected = Preset.Defaults_differ
      [prompt_key, Some saved_hash, Some (Override.default_revision ~body:current)] in
    Alcotest.(check bool) "detail sees changed default" true
      (Preset.compare_defaults loaded = expected);
    set_override ~base_path "Current override.";
    let report = or_fail (Preset.restore ~base_path "baseline") in
    Alcotest.(check bool) "restore reports drift" true (report.default_comparison = expected);
    Alcotest.(check string) "drift does not prevent override restore" "Saved override."
      (Prompt_registry.resolve_prompt prompt_key).effective;
    Alcotest.(check (option string)) "default body is never restored" (Some current)
      (Prompt_registry.resolve_prompt prompt_key).file_value;
    let autosave = or_fail (Preset.load ~base_path report.autosave) in
    Alcotest.(check bool) "autosave records current defaults" true
      (Preset.compare_defaults autosave = Preset.Defaults_match);
    Sys.remove path;
    Alcotest.(check bool) "missing default is visible" true
      (Preset.compare_defaults loaded = Preset.Defaults_differ [prompt_key, Some saved_hash, None]);
    let no_defaults = { saved with default_revisions = Some [] } in
    write_file path prompt_fixture;
    Alcotest.(check bool) "new defaults are visible" true
      (match Preset.compare_defaults no_defaults with
       | Preset.Defaults_differ rows -> List.exists (fun (key, before, after) ->
           key = prompt_key && before = None && Option.is_some after) rows
       | Preset.Defaults_unknown | Preset.Defaults_match -> false))
;;

let test_unreadable_default_does_not_block_preset_operations () =
  with_base (fun ~base_path ~keepers:_ ~config:_ ->
    let unreadable_key = "test.unreadable" in
    let prompts_dir = Filename.concat base_path "prompts" in
    let path = Filename.concat prompts_dir (unreadable_key ^ ".md") in
    write_file path "---\ndescription: becomes unreadable\ncategory: test\n---\nAuxiliary default.\n";
    Prompt_registry.set_markdown_dir prompts_dir;
    set_override ~base_path "Saved override.";
    let saved = or_fail (Preset.capture ~base_path ~name:"baseline" ~description:"") in
    or_fail (Preset.save ~base_path saved);
    let hash = match saved.default_revisions with
      | Some rows -> List.assoc unreadable_key rows
      | None -> Alcotest.fail "baseline must include readable auxiliary default" in
    (* A socket behind the registered path reliably refuses ordinary file
       reads regardless of permission privileges. A short temporary leaf keeps
       its bind address independent of the longer preset fixture directory. *)
    Sys.remove path;
    let socket_path = Filename.temp_file "p" ".sock" in
    Sys.remove socket_path;
    let socket = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
    Fun.protect ~finally:(fun () ->
      Unix.close socket;
      ignore (Fs_compat.unlink_if_exists path);
      ignore (Fs_compat.unlink_if_exists socket_path)) (fun () ->
      Unix.bind socket (Unix.ADDR_UNIX socket_path);
      Unix.symlink socket_path path;
      let captured = or_fail (Preset.capture ~base_path ~name:"unreadable" ~description:"") in
      (match captured.default_revisions with
       | Some rows ->
           Alcotest.(check (option string)) "unreadable default alone is omitted" None
             (List.assoc_opt unreadable_key rows);
           Alcotest.(check bool) "healthy default still has its revision" true
             (List.mem_assoc prompt_key rows)
       | None -> Alcotest.fail "read error must not discard healthy baselines");
      or_fail (Preset.save ~base_path captured);
      let expected = Preset.Defaults_differ [unreadable_key, Some hash, None] in
      Alcotest.(check bool) "comparison reports unreadable default without throwing" true
        (Preset.compare_defaults saved = expected);
      set_override ~base_path "Current override.";
      let report = or_fail (Preset.restore ~base_path "baseline") in
      Alcotest.(check bool) "restore reports informational baseline difference" true
        (report.default_comparison = expected);
      Alcotest.(check string) "healthy override is restored" "Saved override."
        (Prompt_registry.resolve_prompt prompt_key).effective;
      let autosave = or_fail (Preset.load ~base_path report.autosave) in
      Alcotest.(check string) "autosave retained the pre-restore override" "Current override."
        (List.assoc prompt_key (List.map (fun (entry : Override.entry) -> entry.key, entry.value)
          autosave.prompt_overrides))))
;;

let test_default_baseline_missing_or_invalid () =
  with_base (fun ~base_path ~keepers:_ ~config:_ ->
    let saved = or_fail (Preset.capture ~base_path ~name:"baseline" ~description:"") in
    or_fail (Preset.save ~base_path saved);
    let path = Filename.concat (Preset.source_directory ~base_path saved) "manifest.json" in
    let fields = match Yojson.Safe.from_file path with
      | `Assoc fields -> List.remove_assoc "default_revisions" fields
      | _ -> Alcotest.fail "manifest must be an object" in
    write_file path (Yojson.Safe.to_string (`Assoc fields));
    let loaded = or_fail (Preset.load ~base_path "baseline") in
    Alcotest.(check bool) "no baseline means unknown" true
      (Preset.compare_defaults loaded = Preset.Defaults_unknown);
    let report = or_fail (Preset.restore ~base_path "baseline") in
    Alcotest.(check bool) "missing baseline does not block restore" true
      (report.default_comparison = Preset.Defaults_unknown);
    write_file path (Yojson.Safe.to_string (`Assoc
      (("default_revisions", `Assoc [prompt_key, `String "invalid"]) :: fields)));
    Alcotest.(check bool) "corrupt hashes are refused" true
      (Result.is_error (Preset.load ~base_path "baseline")))
;;

(* The real restore, runtime replacement and response decoder share one
   observation. Directory fsync fails only after the new file is visible;
   neither that warning nor a decoder error may replay the restore. *)
let test_restore_retains_visible_commit_observation ~sync_fails () =
  let open Alcotest in
  let state = Runtime.For_testing.snapshot () in
  Fun.protect ~finally:(fun () -> Runtime.For_testing.restore state) @@ fun () ->
  with_base (fun ~base_path ~keepers:_ ~config ->
    let path = Filename.concat config "runtime.toml" in
    let baseline = runtime_fixture ^ "\n[runpod_mtp.qwen]\n\n[openai.gpt]\n" in
    write_file path baseline;
    let target = or_fail (Preset.capture ~base_path ~name:"commit-proof" ~description:"") in
    or_fail (Preset.save ~base_path target);
    let drifted = Preset.runtime_text_with
      ~current_assignments:target.assignments ~current_lanes:target.lanes
      ~assignments:["routingtest", "runpod_mtp.qwen"] ~lanes:target.lanes baseline in
    ignore (or_fail (Runtime.save_config_text ~runtime_config_path:path drifted));
    let before = or_fail (Preset.capture ~base_path ~name:"before" ~description:"") in
    let calls = ref 0 and syncs = ref 0 and observed = ref None in
    let commit ~runtime_config_path text =
      incr calls;
      let outcome =
        if sync_fails then
          Runtime.For_testing.save_config_text_with_sync_parent ~runtime_config_path
            ~sync_parent:(fun _ -> incr syncs;
              raise (Unix.Unix_error (Unix.EIO, "fsync", "preset commit fixture"))) text
        else Runtime.save_config_text ~runtime_config_path text
      in
      (match outcome with Ok receipt -> observed := Some receipt | Error _ -> ());
      outcome
    in
    let report = or_fail (Preset.For_testing.restore_with_config_commit ~commit ~base_path "commit-proof") in
    check int "restore commits once, without replay after a visible warning" 1 !calls;
    check int "fault reaches the real parent sync exactly once" (if sync_fails then 1 else 0) !syncs;
    let receipt = match report.runtime_result, !observed with
      | Preset.Runtime_committed receipt, Some original ->
        check bool "the original writer receipt survives unchanged" true (receipt == original);
        receipt
      | Preset.Runtime_unchanged, _ -> fail "routing drift must commit"
      | Preset.Runtime_failed detail, _ -> fail detail
      | Preset.Runtime_committed _, None -> fail "commit has no actual writer observation"
    in
    let detail = match receipt.durability, sync_fails with
      | Runtime.Durable, false -> None
      | Runtime.Durability_unconfirmed {detail}, true -> Some detail
      | Runtime.Durable, true | Runtime.Durability_unconfirmed _, false ->
        fail "durability must match actual sync outcome"
    in
    check (option string) "visible replacement publishes saved routing" (Some "openai.gpt")
      (Runtime.runtime_id_for_keeper "routingtest");
    check (list (pair string string)) "new file has saved assignments" target.assignments
      (or_fail (Preset.runtime_of_text (Fs_compat.load_file path)) |> fst);
    let autosave = or_fail (Preset.load ~base_path report.autosave) in
    check (list (pair string string)) "autosave still holds state before this restore"
      before.assignments autosave.assignments;
    let wire = Preset.report_to_json report in
    let payload report = `Assoc ["ok", `Bool true; "report", report] in
    let decoded = or_fail (Masc.Tui_decode.decode_preset_restore (payload wire)) in
    let decoded_commit = match decoded.prr_runtime with
      | Masc.Tui_decode.Preset_runtime_committed commit -> commit
      | Masc.Tui_decode.Preset_runtime_unchanged | Masc.Tui_decode.Preset_runtime_failed _ ->
        fail "visible commit must remain committed through the wire"
    in
    check string "wire retains source identity"
      (Runtime.config_source_revision_to_string receipt.observation.source_revision)
      decoded_commit.prc_source_revision;
    check string "wire retains commit order" (Runtime.config_commit_order_to_string receipt.order)
      decoded_commit.prc_order;
    check bool "wire retains actual durability including its reason" true
      (receipt.durability = decoded_commit.prc_durability);
    check bool "wire retains lock warnings" true
      (receipt.lock_warnings = decoded_commit.prc_lock_warnings);
    let expected_attention = sync_fails || receipt.lock_warnings <> [] ||
      match receipt.exact_output_registry with
      | Runtime.Exact_output_registry_replaced _ -> false
      | Runtime.Exact_output_registry_unpublished | Runtime.Exact_output_registry_kept _ -> true in
    check bool "wire warning classification follows the actual application" expected_attention
      (Masc.Tui_decode.preset_runtime_commit_needs_attention decoded_commit);
    let replace key value = function
      | `Assoc fields -> `Assoc ((key, value) :: List.remove_assoc key fields)
      | _ -> fail "report part must be an object" in
    let runtime = Yojson.Safe.Util.member "runtime" wire in
    let commit_json = Yojson.Safe.Util.member "commit" runtime in
    List.iter (fun (application, expected_registry) ->
      let runtime = replace "exact_output_registry"
        (Runtime.exact_output_registry_application_to_yojson application) runtime in
      let decoded = or_fail (Masc.Tui_decode.decode_preset_restore
        (payload (replace "runtime" runtime wire))) in
      match decoded.prr_runtime with
      | Masc.Tui_decode.Preset_runtime_committed commit ->
        check bool "registry projection keeps its own application state" true
          (commit.prc_registry = expected_registry)
      | Masc.Tui_decode.Preset_runtime_unchanged | Masc.Tui_decode.Preset_runtime_failed _ ->
        fail "registry projection cannot erase a visible commit")
      [ Runtime.Exact_output_registry_replaced {origin=Runtime.Runtime_binding_targets},
          Masc.Tui_decode.Preset_registry_applied Masc.Tui_decode.Preset_registry_runtime_bindings
      ; Runtime.Exact_output_registry_replaced {origin=Runtime.Replacement_catalog_targets {path="/fixture/catalog"}},
          Masc.Tui_decode.Preset_registry_applied Masc.Tui_decode.Preset_registry_replacement_catalog
      ; Runtime.Exact_output_registry_unpublished, Masc.Tui_decode.Preset_registry_unpublished
      ; Runtime.Exact_output_registry_kept {reason=Runtime_exact_output_registry.Publication_busy},
          Masc.Tui_decode.Preset_registry_kept
            (Runtime_exact_output_registry.publication_error_to_string Runtime_exact_output_registry.Publication_busy)
      ];
    let warnings = [Runtime.Config_lock_release_unconfirmed "fixture unlock observation"] in
    let warned = Runtime.attach_lock_warnings warnings receipt in
    let warned_runtime = replace "commit" (Runtime.config_commit_receipt_to_yojson warned) runtime in
    (match (or_fail (Masc.Tui_decode.decode_preset_restore
      (payload (replace "runtime" warned_runtime wire)))).prr_runtime with
     | Masc.Tui_decode.Preset_runtime_committed commit ->
       check bool "lock warning projection retains original detail" true
         (commit.prc_lock_warnings = receipt.lock_warnings @ warnings);
       check bool "lock warning requires attention" true
         (Masc.Tui_decode.preset_runtime_commit_needs_attention commit)
     | Masc.Tui_decode.Preset_runtime_unchanged | Masc.Tui_decode.Preset_runtime_failed _ ->
       fail "lock warning must remain a committed observation");
    List.iter (fun malformed_runtime ->
      check bool "incomplete or unknown commit observation cannot become clean" true
        (Result.is_error (Masc.Tui_decode.decode_preset_restore
          (payload (replace "runtime" malformed_runtime wire)))))
      [ `Assoc ["effect", `String "runtime_commit"; "status", `String "committed"]
      ; replace "status" (`String "unchanged") runtime
      ; replace "status" (`String "failed") runtime
      ; (match runtime with `Assoc fields -> `Assoc (("status", `String "unchanged") :: fields)
          | _ -> fail "runtime must be an object")
      ; replace "commit" (replace "source_revision" (`String "invalid") commit_json) runtime
      ; replace "commit" (replace "order" (`String "0") commit_json) runtime
      ; replace "commit" (replace "durability" (`String "unknown") commit_json) runtime
      ; replace "commit" (replace "warnings" `Null commit_json) runtime
      ; replace "commit" (replace "durability" (`String "unconfirmed")
          (replace "durability_detail" `Null commit_json)) runtime
      ; replace "exact_output_registry" (`Assoc ["status", `String "future";
          "requires_restart", `Bool false]) runtime
      ];
    (match detail with
     | Some expected -> check (option string) "wire keeps exact original fsync error"
         (Some expected) (match decoded_commit.prc_durability with
            | Runtime.Durability_unconfirmed {detail} -> Some detail
            | Runtime.Durable -> None)
     | None -> ());
    check int "reading and rejecting reports never repeats the commit" 1 !calls;
    check (list (pair string string)) "decoder failures do not overwrite undo state"
      before.assignments (or_fail (Preset.load ~base_path report.autosave)).assignments)
;;

let () =
  Alcotest.run
    "Prompt_preset"
    [ ( "presets"
      , [ Alcotest.test_case "visible restore retains fsync uncertainty without replay" `Quick
            (test_restore_retains_visible_commit_observation ~sync_fails:true)
        ; Alcotest.test_case "durable restore retains its actual commit receipt" `Quick
            (test_restore_retains_visible_commit_observation ~sync_fails:false)
        ; Alcotest.test_case "default baseline survives drift and restore" `Quick test_default_baseline_survives_drift_and_restore
        ; Alcotest.test_case "unreadable baseline cannot block preset capture or restore" `Quick
            test_unreadable_default_does_not_block_preset_operations
        ; Alcotest.test_case "missing baseline is unknown; corrupt hashes are refused" `Quick test_default_baseline_missing_or_invalid
        ; Alcotest.test_case "legacy lane activity loads; mistyped activity is refused" `Quick test_saved_lane_activity_shape
        ; Alcotest.test_case "activity restore and autosave roundtrip" `Quick test_restore_preserves_lane_activity_and_autosave
        ; Alcotest.test_case "capture, save, load, list round trip" `Quick
            test_capture_save_load_round_trip
        ; Alcotest.test_case "an invalid name is refused" `Quick test_invalid_name_is_refused
        ; Alcotest.test_case "a preset that does not load is listed as unreadable" `Quick
            test_a_preset_that_does_not_load_is_listed_as_unreadable
        ; Alcotest.test_case "a manifest naming another preset does not load" `Quick
            test_a_manifest_naming_another_preset_does_not_load
        ; Alcotest.test_case "saved-settings comparison ignores snapshot metadata" `Quick
            test_saved_settings_ignore_snapshot_metadata
        ; Alcotest.test_case "saved-settings comparison reports invalid Keeper TOML" `Quick
            test_saved_settings_report_invalid_keeper_toml
        ; Alcotest.test_case "saved-settings comparison reads disk without reloading" `Quick
            test_saved_settings_read_durable_overrides_without_reloading
        ; Alcotest.test_case "restore puts the saved state back and autosaves first" `Quick
            test_restore_puts_the_saved_state_back
        ; Alcotest.test_case "restore preserves manifest while journal retained" `Quick
            test_restore_preserves_manifest_while_journal_retained
        ; Alcotest.test_case "the runtime.toml text transform keeps every other line" `Quick
            test_runtime_text_transform
        ; Alcotest.test_case "the runtime.toml text carries add-on lanes" `Quick
            test_runtime_text_carries_addon_lanes
        ; Alcotest.test_case "the runtime.toml text carries the lane request settings" `Quick
            test_runtime_text_carries_the_lane_request_settings
        ; Alcotest.test_case "a saved lane keeps its request settings; older presets declare none" `Quick
            test_saved_lane_request_settings_shape
        ; Alcotest.test_case "an override written against an older default still restores" `Quick
            test_override_written_against_an_older_default_still_restores
        ; Alcotest.test_case "an override that cannot render is skipped with the reason" `Quick
            test_override_that_cannot_render_is_skipped_with_the_reason
        ; Alcotest.test_case "delete removes a preset whether or not it loads" `Quick
            test_delete_removes_a_preset_whether_or_not_it_loads
        ; Alcotest.test_case "delete removes a dangling link" `Quick
            test_delete_removes_a_dangling_link
        ; Alcotest.test_case "delete refuses a missing or invalid name" `Quick
            test_delete_refuses_a_missing_or_invalid_name
        ; Alcotest.test_case "a second restore replaces the autosave" `Quick
            test_a_second_restore_replaces_the_autosave
        ; Alcotest.test_case "a failed save keeps the preset it was replacing" `Quick
            test_a_failed_save_keeps_the_preset_it_was_replacing
        ; Alcotest.test_case "restoring the autosave undoes the latest restore" `Quick
            test_restoring_the_autosave_undoes_the_latest_restore
        ; Alcotest.test_case "the overrides file is read under an installed Eio fs" `Quick
            test_override_load_reads_under_an_installed_eio_fs
        ] )
    ]
;;
