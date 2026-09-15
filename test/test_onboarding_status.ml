open Alcotest

let with_workspace f =
  let path = Filename.temp_file "masc-onboarding-" "" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  let rec remove path =
    match (Unix.lstat path).Unix.st_kind with
    | Unix.S_DIR -> Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path); Unix.rmdir path
    | _ -> Sys.remove path in
  Fun.protect ~finally:(fun () -> remove path) (fun () -> f path)

let write path bytes = Out_channel.with_open_bin path (fun ch -> output_string ch bytes)
let read path = In_channel.with_open_bin path In_channel.input_all
let condition id state =
  (List.find (fun (c : Onboarding_status.check) -> c.id = id) state.Onboarding_status.checks).condition

let message id state =
  (List.find (fun (c : Onboarding_status.check) -> c.id = id) state.Onboarding_status.checks).message

(* Drops a TOML table and its body, so a fixture can lose one declaration while
   the binding that names it stays. *)
let without_table prefix text =
  let rec go kept dropping = function
    | [] -> List.rev kept
    | line :: rest ->
      if String.starts_with ~prefix line then go kept true rest
      else if String.length line > 0 && line.[0] = '[' then go (line :: kept) false rest
      else if dropping then go kept true rest
      else go (line :: kept) false rest
  in
  String.concat "\n" (go [] false (String.split_on_char '\n' text))

let absent_workspace () =
  let observed = Onboarding_status.inspect ~base_path:None in
  check bool "offers a workspace without requiring MASC_BASE_PATH" true
    (condition Onboarding_status.Workspace observed = Onboarding_status.Needs_setup)

let new_location_stays_untouched () = with_workspace @@ fun base ->
  let observed = Onboarding_status.inspect ~base_path:(Some base) in
  check bool "location needs initialization" true
    (condition Onboarding_status.Workspace observed = Onboarding_status.Needs_setup);
  check int "inspection writes nothing" 0 (Array.length (Sys.readdir base))

let declared_is_not_verified () = with_workspace @@ fun base ->
  let root = Filename.concat base ".masc" in
  let config = Filename.concat root "config" in
  let keepers = Filename.concat config "keepers" in
  List.iter (fun path -> Unix.mkdir path 0o700) [root; config; keepers];
  let runtime_path = Filename.concat config "runtime.toml" in
  let keeper_path = Filename.concat keepers "imp.toml" in
  write runtime_path (read "../scripts/fixtures/release-evidence/runtime.toml");
  write keeper_path (read "../config/keepers-default/imp.toml");
  let runtime_before = read runtime_path and keeper_before = read keeper_path in
  let observed = Onboarding_status.inspect ~base_path:(Some base) in
  check bool "declaration appears before any keeper metadata" true
    (condition Onboarding_status.Keeper_declaration observed = Onboarding_status.Satisfied);
  check bool "declaration is not a verified model call" true
    (condition Onboarding_status.Model_connection observed = Onboarding_status.Needs_verification);
  check bool "sandbox declaration is not a running guest" true
    (condition Onboarding_status.Sandbox observed = Onboarding_status.Needs_verification);
  check string "runtime preserved" runtime_before (read runtime_path);
  check string "keeper preserved" keeper_before (read keeper_path);
  check bool "unstarted declaration has no persisted history" true
    (condition Onboarding_status.Keeper_persistence observed = Onboarding_status.Needs_setup);
  check bool "read does not create keeper runtime directory" false
    (Sys.file_exists (Filename.concat root "keepers"));
  let invalid_configs = [
    String.concat "\n" (List.filter (fun line -> not (String.starts_with ~prefix:"default = " line)) (String.split_on_char '\n' runtime_before))
      ^ "\n[runtime.assignments]\nimp = \"ollama_cloud.deepseek-v4-flash\"\n";
    runtime_before ^ "\n[runtime.lanes.broken]\ncandidates = [\"not.configured\"]\n";
    runtime_before ^ "\n[runtime.lanes.only_lane]\ncandidates = [\"ollama_cloud.deepseek-v4-flash\"]\n[runtime.assignments]\nimp = \"only_lane\"\n"
  ] in
  List.iter (fun invalid ->
    write runtime_path invalid;
    let state = Onboarding_status.inspect ~base_path:(Some base) in
    check bool "invalid runtime references are not merely unverified" true
      (condition Onboarding_status.Model_connection state = Onboarding_status.Invalid);
    check string "invalid config preserved" invalid (read runtime_path)) invalid_configs;
  write runtime_path runtime_before;
  let metadata_dir = Filename.concat root "keepers" in
  Unix.mkdir metadata_dir 0o700;
  let metadata_path = Filename.concat metadata_dir "imp.json" in
  let valid_meta = Yojson.Safe.to_string (Masc_test_deps.current_meta_json_fixture ~name:"imp" ()) in
  write metadata_path valid_meta;
  let persisted = Onboarding_status.inspect ~base_path:(Some base) in
  check bool "canonical metadata records history" true
    (condition Onboarding_status.Keeper_persistence persisted = Onboarding_status.Satisfied);
  check bool "persisted history is not sandbox proof" true
    (condition Onboarding_status.Sandbox persisted = Onboarding_status.Needs_verification);
  check string "metadata observation is read-only" valid_meta (read metadata_path);
  write metadata_path (Yojson.Safe.to_string (Masc_test_deps.current_meta_json_fixture ~name:"someone-else" ()));
  let wrong_owner = Onboarding_status.inspect ~base_path:(Some base) in
  check bool "another keeper's metadata is not imp history" true
    (condition Onboarding_status.Keeper_persistence wrong_owner = Onboarding_status.Invalid);
  write metadata_path "{broken";
  let corrupt = Onboarding_status.inspect ~base_path:(Some base) in
  check bool "corrupt metadata is invalid, not absent" true
    (condition Onboarding_status.Keeper_persistence corrupt = Onboarding_status.Invalid);
  check string "read does not repair metadata" "{broken" (read metadata_path);
  write runtime_path "[providers.secret]\napi_key = \"DO_NOT_PROJECT\"\ninvalid = [";
  let broken = Onboarding_status.inspect ~base_path:(Some base) in
  check bool "bad config remains inspectable" true
    (condition Onboarding_status.Model_connection broken = Onboarding_status.Invalid);
  let serialized = Yojson.Safe.to_string (Onboarding_status.to_json broken) in
  check bool "credential-bearing parser input is not exposed" false
    (String_util.contains_substring serialized "DO_NOT_PROJECT")


(* Every load failure still reports Invalid. What changed is that the check
   now carries the reason: which site, and which id failed to resolve. *)
let a_load_failure_says_what_failed () = with_workspace @@ fun base ->
  let root = Filename.concat base ".masc" in
  let config = Filename.concat root "config" in
  List.iter (fun path -> Unix.mkdir path 0o700) [root; config];
  let runtime_path = Filename.concat config "runtime.toml" in
  let fixture = read "../scripts/fixtures/release-evidence/runtime.toml" in

  write runtime_path (fixture ^ "\n[runtime.assignments]\nimp = \"ollama_cloud.absent\"\n");
  let assignment = Onboarding_status.inspect ~base_path:(Some base) in
  check bool "an unresolved assignment names the site it was written at" true
    (String_util.contains_substring
       (message Onboarding_status.Model_connection assignment)
       "[runtime.assignments]");

  write runtime_path (without_table "[models.deepseek-v4-flash]" fixture);
  let dangling = Onboarding_status.inspect ~base_path:(Some base) in
  check bool "a binding without its declaration needs the file edited" true
    (condition Onboarding_status.Model_connection dangling = Onboarding_status.Invalid);
  check bool "the message names the binding that cannot resolve" true
    (String_util.contains_substring
       (message Onboarding_status.Model_connection dangling)
       "ollama_cloud.deepseek-v4-flash")

let browser_lane_fixture ?(server_argument="") ?(connection_port="") () f =
  with_workspace @@ fun base ->
  let root = Filename.concat base ".masc" in
  List.iter (fun path -> Unix.mkdir path 0o700)
    [root; Filename.concat root "config"; Filename.concat root "browser-lane";
     Filename.concat (Filename.concat root "browser-lane") "host"];
  if connection_port <> "" then
    write (Filename.concat root "config/connection.toml")
      ("[server]\nhttp_port = " ^ connection_port ^ "\n");
  write (Filename.concat (Filename.concat root "browser-lane") "host/launch")
    ("#!/bin/sh\nexec /unused/masc-browser-host --base-path " ^ base
     ^ " --token-file /unused/token" ^ server_argument ^ " \"$@\"\n");
  f base

let browser_lane_absent_launcher_is_unobserved () = with_workspace @@ fun base ->
  Unix.mkdir (Filename.concat base ".masc") 0o700;
  let observed = Onboarding_status.inspect ~base_path:(Some base) in
  check bool "an uninstalled lane reports no browser_lane observation" true
    (List.find_opt (fun (c : Onboarding_status.check) -> c.id = Onboarding_status.Browser_lane)
       observed.Onboarding_status.checks = None)

let browser_lane_drift_is_invalid_and_names_both_ports () =
  browser_lane_fixture
    ~server_argument:" --server http://127.0.0.1:8935"
    ~connection_port:"64850" () @@ fun base ->
  let observed = Onboarding_status.inspect ~base_path:(Some base) in
  check bool "a launcher aimed at a stale port is invalid" true
    (condition Onboarding_status.Browser_lane observed = Onboarding_status.Invalid);
  check bool "the stale port is named" true
    (String_util.contains_substring (message Onboarding_status.Browser_lane observed) "8935");
  check bool "the workspace port is named" true
    (String_util.contains_substring (message Onboarding_status.Browser_lane observed) "64850")

let browser_lane_aligned_launcher_is_satisfied () =
  browser_lane_fixture
    ~server_argument:" --server http://127.0.0.1:64850"
    ~connection_port:"64850" () @@ fun base ->
  let observed = Onboarding_status.inspect ~base_path:(Some base) in
  check bool "a launcher aimed at the workspace port is satisfied" true
    (condition Onboarding_status.Browser_lane observed = Onboarding_status.Satisfied)

let browser_lane_dynamic_launcher_is_satisfied () =
  browser_lane_fixture ~connection_port:"64850" () @@ fun base ->
  let observed = Onboarding_status.inspect ~base_path:(Some base) in
  check bool "a launcher without --server follows the workspace" true
    (condition Onboarding_status.Browser_lane observed = Onboarding_status.Satisfied)

(* The front door opened imp's history only when no check at all was Invalid, so
   a browser lane launcher left on an old port sent an operator with a working
   imp back to "choose a workspace" on every bare `masc` (measured 2026-09-15:
   launcher on 64850, workspace connection on 61372). *)
let a_stale_browser_lane_does_not_hold_imp_history_closed () =
  browser_lane_fixture
    ~server_argument:" --server http://127.0.0.1:8935"
    ~connection_port:"64850" () @@ fun base ->
  let root = Filename.concat base ".masc" in
  let config = Filename.concat root "config" in
  let keepers = Filename.concat config "keepers" in
  Unix.mkdir keepers 0o700;
  write (Filename.concat config "runtime.toml")
    (read "../scripts/fixtures/release-evidence/runtime.toml");
  write (Filename.concat keepers "imp.toml") (read "../config/keepers-default/imp.toml");
  let not_booted = Onboarding_status.inspect ~base_path:(Some base) in
  check bool "imp that never booted still needs the journey" true
    (Onboarding_status.opening not_booted = Onboarding_status.Needs_journey);
  let metadata_dir = Filename.concat root "keepers" in
  Unix.mkdir metadata_dir 0o700;
  let metadata_path = Filename.concat metadata_dir "imp.json" in
  write metadata_path
    (Yojson.Safe.to_string (Masc_test_deps.current_meta_json_fixture ~name:"imp" ()));
  let observed = Onboarding_status.inspect ~base_path:(Some base) in
  check bool "the lane drift is still reported" true
    (condition Onboarding_status.Browser_lane observed = Onboarding_status.Invalid);
  check bool "the lane is advisory" true
    (Onboarding_status.role Onboarding_status.Browser_lane = Onboarding_status.Advisory);
  check bool "imp's readable history opens despite the lane" true
    (Onboarding_status.opening observed = Onboarding_status.Open_existing_history);
  let json = Onboarding_status.to_json observed in
  check string "the journey reads the decision from the document"
    "open_existing_history"
    (Yojson.Safe.Util.to_string (Yojson.Safe.Util.member "opening" json));
  write metadata_path "{broken";
  let unreadable = Onboarding_status.inspect ~base_path:(Some base) in
  check bool "unreadable imp history still needs the journey" true
    (Onboarding_status.opening unreadable = Onboarding_status.Needs_journey);
  write metadata_path
    (Yojson.Safe.to_string (Masc_test_deps.current_meta_json_fixture ~name:"imp" ()));
  write (Filename.concat config "runtime.toml")
    "[providers.secret]\napi_key = \"x\"\ninvalid = [";
  let unresolved_model = Onboarding_status.inspect ~base_path:(Some base) in
  check bool "imp history is readable again, so only the model can hold it closed" true
    (condition Onboarding_status.Keeper_persistence unresolved_model
     = Onboarding_status.Satisfied);
  check bool "a model binding imp needs keeps the journey" true
    (Onboarding_status.opening unresolved_model = Onboarding_status.Needs_journey)

(* Only the browser lane is advisory. Pinned per id so moving a check imp needs
   to Advisory fails here instead of silently opening a broken conversation. *)
let only_the_browser_lane_is_advisory () =
  List.iter (fun (id, expected) ->
      check bool (Onboarding_status.check_id_name id) true
        (Onboarding_status.role id = expected))
    Onboarding_status.[ Workspace, Required_to_open;
                        Model_connection, Required_to_open;
                        Keeper_declaration, Required_to_open;
                        Sandbox, Required_to_open;
                        Keeper_persistence, Required_to_open;
                        Browser_lane, Advisory ];
  check bool "no workspace never opens history" true
    (Onboarding_status.opening (Onboarding_status.inspect ~base_path:None)
     = Onboarding_status.Needs_journey)

let () = run "Onboarding observations"
  ["first use", [test_case "missing environment is an actionable state" `Quick absent_workspace;
                 test_case "uninitialized workspace is read-only" `Quick new_location_stays_untouched;
                 test_case "declared imp and concurrent unmet conditions" `Quick declared_is_not_verified;
                 test_case "a load failure names its site and id" `Quick
                   a_load_failure_says_what_failed;
                 test_case "an uninstalled browser lane is not observed" `Quick
                   browser_lane_absent_launcher_is_unobserved;
                 test_case "a stale browser lane port is invalid and names both ports" `Quick
                   browser_lane_drift_is_invalid_and_names_both_ports;
                 test_case "a browser lane aimed at the workspace port is satisfied" `Quick
                   browser_lane_aligned_launcher_is_satisfied;
                 test_case "a browser lane without --server follows the workspace" `Quick
                   browser_lane_dynamic_launcher_is_satisfied;
                 test_case "a stale browser lane does not hold imp's history closed" `Quick
                   a_stale_browser_lane_does_not_hold_imp_history_closed;
                 test_case "only the browser lane is advisory" `Quick
                   only_the_browser_lane_is_advisory]]
