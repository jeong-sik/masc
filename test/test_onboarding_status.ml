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

module Readiness = Masc.Sandbox_readiness

(* Commands the sandbox probe may issue, answered from a table. A command the
   table does not list is a missing executable, as on a host without it. The
   calls are kept so a test can bound how many commands one inspection spends. *)
let fixture_runner responses =
  let calls = ref [] in
  let run argv =
    calls := argv :: !calls;
    match List.assoc_opt argv responses with
    | Some reply -> reply
    | None -> Error Readiness.Missing_command in
  run, (fun () -> List.rev !calls)

let linux_host = [ ["uname"; "-s"], Ok "Linux\n"; ["uname"; "-m"], Ok "x86_64\n" ]
let macos26_arm64_host =
  [ ["uname"; "-s"], Ok "Darwin\n"; ["uname"; "-m"], Ok "arm64\n";
    ["sw_vers"; "-productVersion"], Ok "26.0\n" ]
let docker_info = ["docker"; "info"; "--format"; "{{json .}}"]
let healthy_docker =
  linux_host @ [ docker_info, Ok {|{"OSType":"linux","SecurityOptions":[]}|} ]
let apple_inventory = ["container"; "list"; "-a"; "--format"; "json"]
let apple_properties = ["container"; "system"; "property"; "list"; "--format"; "json"]
let rosetta_receipt = ["pkgutil"; "--pkg-info"; "com.apple.pkg.RosettaUpdateAuto"]
let rosetta_installed = rosetta_receipt, Ok "package-id: com.apple.pkg.RosettaUpdateAuto\n"
let rosetta_absent = rosetta_receipt, Error Readiness.Command_failed
let apple_settings ~rosetta ~kernel =
  apple_properties,
  Ok (Printf.sprintf {|{"build":{"rosetta":%b},"kernel":%s}|} rosetta
        (if kernel then {|{"binaryPath":"opt/kata/vmlinux"}|} else "{}"))

(* The sandbox check of a workspace the other tests build, answered by a host
   with a healthy Docker engine, which is the default imp declaration. *)
let inspect = Onboarding_status.inspect
  ~sandbox:(Onboarding_status.Probe_with (fst (fixture_runner healthy_docker)))

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
  let observed = inspect ~base_path:None in
  check bool "offers a workspace without requiring MASC_BASE_PATH" true
    (condition Onboarding_status.Workspace observed = Onboarding_status.Needs_setup)

let new_location_stays_untouched () = with_workspace @@ fun base ->
  let observed = inspect ~base_path:(Some base) in
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
  let observed = inspect ~base_path:(Some base) in
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
      ^ "\n[runtime.assignments]\nimp = \"ollama_cloud.deepseek-v4.1-flash\"\n";
    runtime_before ^ "\n[runtime.lanes.broken]\ncandidates = [\"not.configured\"]\n";
    (* An assignment naming neither a declared lane nor a runtime is rejected
       at load, whatever the admission domain. *)
    runtime_before ^ "\n[runtime.assignments]\nimp = \"never-declared-anywhere\"\n"
  ] in
  List.iter (fun invalid ->
    write runtime_path invalid;
    let state = inspect ~base_path:(Some base) in
    check bool "invalid runtime references are not merely unverified" true
      (condition Onboarding_status.Runtime_configuration state = Onboarding_status.Invalid);
    check string "invalid config preserved" invalid (read runtime_path)) invalid_configs;
  (* RFC-0456: an assignment may name a declared lane. The doctor resolves the
     lane's entry candidate, so a lane-bound imp reads as declared but
     unverified, not as a load failure. *)
  write runtime_path
    (runtime_before ^ "\n[runtime.lanes.only_lane]\ncandidates = [\"ollama_cloud.deepseek-v4.1-flash\"]\n[runtime.assignments]\nimp = \"only_lane\"\n");
  let lane_named = inspect ~base_path:(Some base) in
  check bool "an assignment naming a declared lane is not a load failure" true
    (condition Onboarding_status.Model_connection lane_named = Onboarding_status.Needs_verification);
  write runtime_path runtime_before;
  let metadata_dir = Filename.concat root "keepers" in
  Unix.mkdir metadata_dir 0o700;
  let metadata_path = Filename.concat metadata_dir "imp.json" in
  let valid_meta = Yojson.Safe.to_string (Masc_test_deps.current_meta_json_fixture ~name:"imp" ()) in
  write metadata_path valid_meta;
  let persisted = inspect ~base_path:(Some base) in
  check bool "canonical metadata records history" true
    (condition Onboarding_status.Keeper_persistence persisted = Onboarding_status.Satisfied);
  check bool "persisted history is not sandbox proof" true
    (condition Onboarding_status.Sandbox persisted = Onboarding_status.Needs_verification);
  check string "metadata observation is read-only" valid_meta (read metadata_path);
  write metadata_path "{broken";
  let corrupt = inspect ~base_path:(Some base) in
  check bool "corrupt metadata is invalid, not absent" true
    (condition Onboarding_status.Keeper_persistence corrupt = Onboarding_status.Invalid);
  check string "read does not repair metadata" "{broken" (read metadata_path);
  write runtime_path "[providers.secret]\napi_key = \"DO_NOT_PROJECT\"\ninvalid = [";
  let broken = inspect ~base_path:(Some base) in
  check bool "bad config remains inspectable" true
    (condition Onboarding_status.Runtime_configuration broken = Onboarding_status.Invalid);
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
  let assignment = inspect ~base_path:(Some base) in
  check bool "an unresolved assignment names the site it was written at" true
    (String_util.contains_substring
       (message Onboarding_status.Runtime_configuration assignment)
       "[runtime.assignments]");

  write runtime_path (without_table "[models.\"deepseek-v4.1-flash\"]" fixture);
  let dangling = inspect ~base_path:(Some base) in
  check bool "a binding without its declaration needs the file edited" true
    (condition Onboarding_status.Runtime_configuration dangling = Onboarding_status.Invalid);
  check bool "the message names the binding that cannot resolve" true
    (String_util.contains_substring
       (message Onboarding_status.Runtime_configuration dangling)
       "ollama_cloud.deepseek-v4.1-flash")

(* A workspace with its config root, as a first server start leaves it. *)
let workspace_fixture f =
  with_workspace @@ fun base ->
  let root = Filename.concat base ".masc" in
  List.iter (fun path -> Unix.mkdir path 0o700) [root; Filename.concat root "config"];
  f base

(* A workspace whose Keepers were declared by hand never had imp, and bare
   `masc` walked it back into setup (measured 2026-09-23: sixteen persisted
   Keepers, opening needs_journey, "Your first Keeper, imp, has not been
   created."). History belongs to the workspace, not to one name. *)
let a_workspace_without_imp_opens_its_keepers_history () =
  workspace_fixture @@ fun base ->
  let root = Filename.concat base ".masc" in
  write (Filename.concat root "config/runtime.toml")
    (read "../scripts/fixtures/release-evidence/runtime.toml");
  let metadata_dir = Filename.concat root "keepers" in
  Unix.mkdir metadata_dir 0o700;
  let persist name =
    write (Filename.concat metadata_dir (name ^ ".json"))
      (Yojson.Safe.to_string (Masc_test_deps.current_meta_json_fixture ~name ())) in
  persist "geek-scout";
  persist "glossary-maniac";
  let observed = inspect ~base_path:(Some base) in
  check bool "imp is still undeclared" true
    (condition Onboarding_status.Keeper_declaration observed = Onboarding_status.Needs_setup);
  check bool "other Keepers' history is persisted history" true
    (condition Onboarding_status.Keeper_persistence observed = Onboarding_status.Satisfied);
  check bool "the workspace opens without imp" true
    (Onboarding_status.opening observed = Onboarding_status.Open_existing_history);
  (* The server skips an imp it cannot load and boots every other Keeper, so a
     broken imp declaration is reported beside the history, not in its way. *)
  let keepers = Filename.concat root "config/keepers" in
  Unix.mkdir keepers 0o700;
  write (Filename.concat keepers "imp.toml") "[keeper\nbroken";
  let broken_imp = inspect ~base_path:(Some base) in
  check bool "a broken imp declaration is reported" true
    (condition Onboarding_status.Keeper_declaration broken_imp = Onboarding_status.Invalid);
  check bool "and does not close the other Keepers' history" true
    (Onboarding_status.opening broken_imp = Onboarding_status.Open_existing_history);
  Sys.remove (Filename.concat keepers "imp.toml");
  (* Once .masc/config exists the server does not write runtime.toml again, so
     a missing one boots it with no runtime; the journey's model step writes it. *)
  let runtime_path = Filename.concat root "config/runtime.toml" in
  let runtime_text = read runtime_path in
  Sys.remove runtime_path;
  let no_runtime = inspect ~base_path:(Some base) in
  check bool "a missing runtime.toml needs setup" true
    (condition Onboarding_status.Runtime_configuration no_runtime = Onboarding_status.Needs_setup);
  check bool "and keeps the journey" true
    (Onboarding_status.opening no_runtime = Onboarding_status.Needs_journey);
  write runtime_path runtime_text;
  (* The server's boot reconcile refuses every Keeper when one metadata file
     cannot be read, so the readable ones do not make the workspace openable. *)
  write (Filename.concat metadata_dir "broken-one.json") "{broken";
  let one_broken = inspect ~base_path:(Some base) in
  check bool "one unreadable Keeper is invalid history" true
    (condition Onboarding_status.Keeper_persistence one_broken = Onboarding_status.Invalid);
  check bool "and keeps the journey, as boot would refuse" true
    (Onboarding_status.opening one_broken = Onboarding_status.Needs_journey);
  check bool "the unreadable Keeper is named" true
    (String_util.contains_substring
       (message Onboarding_status.Keeper_persistence one_broken) "broken-one");
  check string "observation does not repair it" "{broken"
    (read (Filename.concat metadata_dir "broken-one.json"))

(* Only what every Keeper shares holds history closed; imp's own checks and the
   browser lane are advisory. Pinned per id so moving a check across fails here
   instead of silently changing what a bare `masc` opens. *)
let only_shared_checks_hold_history_closed () =
  (* Exhaustive, so a new check id does not compile here until its role is
     decided in this test too. *)
  let expected : Onboarding_status.check_id -> Onboarding_status.role = function
    | Workspace | Runtime_configuration | Keeper_persistence | Multi_account_request
    | Unknown_account_mode ->
      Required_to_open
    | Model_connection | Keeper_declaration | Sandbox | Person_account_homes -> Advisory
  in
  List.iter (fun id ->
      check bool (Onboarding_status.check_id_name id) true
        (Onboarding_status.role id = expected id))
    Onboarding_status.[ Workspace; Runtime_configuration; Keeper_persistence;
                        Model_connection; Keeper_declaration; Sandbox;
                        Multi_account_request; Unknown_account_mode; Person_account_homes ];
  check bool "no workspace never opens history" true
    (Onboarding_status.opening (inspect ~base_path:None)
     = Onboarding_status.Needs_journey)

(* A workspace whose imp declares [keeper_toml]; the doctor reads the sandbox
   backend from it and probes that backend only. *)
let imp_workspace base keeper_toml =
  let root = Filename.concat base ".masc" in
  let config = Filename.concat root "config" in
  let keepers = Filename.concat config "keepers" in
  List.iter (fun path -> Unix.mkdir path 0o700) [root; config; keepers];
  write (Filename.concat config "runtime.toml") (read "../scripts/fixtures/release-evidence/runtime.toml");
  write (Filename.concat keepers "imp.toml") keeper_toml

(* A workspace whose config asks for accounts boots the account server. Its
   history does not open and the journey of a single user does not run,
   whatever else the workspace holds, and what imp runs on is not read. *)
let a_workspace_that_asks_for_accounts_is_an_account_installation () =
  with_workspace @@ fun base ->
  imp_workspace base (read "../config/keepers-default/imp.toml");
  let root = Filename.concat base ".masc" in
  let metadata_dir = Filename.concat root "keepers" in
  Unix.mkdir metadata_dir 0o700;
  write (Filename.concat metadata_dir "geek-scout.json")
    (Yojson.Safe.to_string (Masc_test_deps.current_meta_json_fixture ~name:"geek-scout" ()));
  let run, calls = fixture_runner healthy_docker in
  let inspect () =
    Onboarding_status.inspect ~sandbox:(Onboarding_status.Probe_with run) ~base_path:(Some base) in
  check bool "without a request, the history opens" true
    (Onboarding_status.opening (inspect ()) = Onboarding_status.Open_existing_history);
  check bool "and imp's sandbox was probed" true (calls () <> []);
  let auth = Filename.concat root "auth" in
  Unix.mkdir auth 0o700;
  let config = Filename.concat auth "config.json" in
  let single_user = {|{"enabled":true,"require_token":true,"account_mode":"Single_user"}|} in
  let multi_account = {|{"enabled":true,"require_token":true,"account_mode":"Multi_account"}|} in
  write config single_user;
  check bool "a request for a single user changes nothing" true
    (Onboarding_status.opening (inspect ()) = Onboarding_status.Open_existing_history);
  (* Runtime roots that persons left behind are reported, with the turns the
     server refuses while they are there; the history still opens. *)
  let ids observed =
    List.map (fun (c : Onboarding_status.check) -> Onboarding_status.check_id_name c.id)
      observed.Onboarding_status.checks in
  check bool "no runtime roots of persons, no check" false
    (List.mem "person_account_homes" (ids (inspect ())));
  let left_behind = Filename.concat root Runtime_account_home_layout.accounts_dir in
  Unix.mkdir left_behind 0o700;
  let with_roots = inspect () in
  check bool "runtime roots of persons are reported" true
    (condition Onboarding_status.Person_account_homes with_roots = Onboarding_status.Needs_setup);
  check (option string) "with the sentence a refused turn would get first"
    (Runtime_account_access.person_homes_notice (Ok true))
    (Some (message Onboarding_status.Person_account_homes with_roots));
  check (option string) "a workspace without them is told nothing" None
    (Runtime_account_access.person_homes_notice (Ok false));
  check bool "and the history still opens" true
    (Onboarding_status.opening with_roots = Onboarding_status.Open_existing_history);
  Unix.rmdir left_behind;
  write config multi_account;
  let asked = List.length (calls ()) in
  let observed = inspect () in
  check bool "a request for accounts is an account installation" true
    (Onboarding_status.opening observed = Onboarding_status.Account_installation);
  check (list string) "the workspace and the request are its checks"
    [ "workspace"; "multi_account_request" ]
    (List.map (fun (c : Onboarding_status.check) -> Onboarding_status.check_id_name c.id)
       observed.Onboarding_status.checks);
  check bool "the request is not verified here" true
    (condition Onboarding_status.Multi_account_request observed
     = Onboarding_status.Needs_verification);
  check int "no command is issued for it" asked (List.length (calls ()));
  check bool "the inspection of a server answers the same" true
    (Onboarding_status.opening (Onboarding_status.inspect_loaded ~base_path:(Some base))
     = Onboarding_status.Account_installation);
  (match Onboarding_status.to_json observed with
   | `Assoc fields ->
     check bool "the document names the opening" true
       (List.assoc_opt "opening" fields = Some (`String "account_installation"))
   | _ -> fail "the document is an object");
  check string "the config is left as it was" multi_account (read config);
  (* An account mode the boot does not know: the boot of this workspace stops,
     so the doctor says so in the words of the boot and offers no journey. *)
  let unknown = {|{"enabled":true,"require_token":true,"account_mode":"multi_account"}|} in
  write config unknown;
  let asked = List.length (calls ()) in
  let observed = inspect () in
  check bool "an unknown account mode is refused, not a journey" true
    (Onboarding_status.opening observed = Onboarding_status.Refused_by_boot);
  check (list string) "the workspace and the refusal are its checks"
    [ "workspace"; "unknown_account_mode" ]
    (ids observed);
  check bool "the refusal is invalid" true
    (condition Onboarding_status.Unknown_account_mode observed = Onboarding_status.Invalid);
  (* The refusal a boot of this file gives (test_authz_boot_mode_read pins
     that the boot decides it), in the boot's words. *)
  let boot_sentence =
    Authz_boot_mode.refusal_to_string (Authz_boot_mode.Unknown_account_mode {|"multi_account"|})
  in
  check bool "with the sentence the boot stops with" true
    (String.starts_with ~prefix:boot_sentence
       (message Onboarding_status.Unknown_account_mode observed));
  check int "no command is issued for it" asked (List.length (calls ()));
  check bool "the inspection of a server answers the same" true
    (Onboarding_status.opening (Onboarding_status.inspect_loaded ~base_path:(Some base))
     = Onboarding_status.Refused_by_boot);
  (match Onboarding_status.to_json observed with
   | `Assoc fields ->
     check bool "the document names the opening" true
       (List.assoc_opt "opening" fields = Some (`String "refused_by_boot"))
   | _ -> fail "the document is an object");
  check string "the config is left as it was" unknown (read config)

let microvm_imp backend =
  Printf.sprintf
    "[keeper]\nactivation_mode = \"manual\"\nsandbox_profile = \"microvm\"\nmicrovm_backend = \"%s\"\nsandbox_image = \"base\"\nnetwork_mode = \"inherit\"\ninstructions = \"Respond to the operator.\"\n"
    backend

let sandbox_of state = Onboarding_status.sandbox_check_of_entry
  { Readiness.backend = Readiness.Apple_container; state; guest_verification = Readiness.Not_run }

let sandbox_check_of_entry_for backend state = Onboarding_status.sandbox_check_of_entry
  { Readiness.backend; state; guest_verification = Readiness.Not_run }

let sandbox_check_of observed =
  List.find (fun (c : Onboarding_status.check) -> c.id = Onboarding_status.Sandbox)
    observed.Onboarding_status.checks

(* The doctor's answer for imp's declared sandbox, with the commands it spent. *)
let doctor_sandbox ~keeper_toml responses = with_workspace @@ fun base ->
  imp_workspace base keeper_toml;
  let run, calls = fixture_runner responses in
  let observed = Onboarding_status.inspect ~sandbox:(Onboarding_status.Probe_with run) ~base_path:(Some base) in
  sandbox_check_of observed, calls ()

(* What the probe itself answers for Apple Container on the same fixture. *)
let apple_probe responses =
  let run, _ = fixture_runner responses in
  (Readiness.probe ~host:(Readiness.Macos {architecture = Readiness.Arm64; major = 26}) ~run
     ~require_rootless:false ~require_userns:false Readiness.Apple_container).state

(* masc doctor used to print one fixed sentence for every declared sandbox.
   The four situations below are different facts about the same declaration:
   each one must reach the check as its own condition and its own reason. *)
let a_declared_apple_container_is_probed_not_assumed () =
  let keeper_toml = microvm_imp "apple_container" in
  let healthy = macos26_arm64_host
    @ [ apple_inventory, Ok "[]"; rosetta_installed; apple_settings ~rosetta:true ~kernel:true ] in
  let ready, ready_calls = doctor_sandbox ~keeper_toml healthy in
  check bool "a service that answers is declared but unverified" true
    (ready = sandbox_of Readiness.Service_ready);
  check bool "an answering service is Needs_verification" true
    (ready.condition = Onboarding_status.Needs_verification);

  (* The builder VM starts with Rosetta unless build.rosetta is false, and does
     not start on a Mac without it. *)
  let no_rosetta = macos26_arm64_host
    @ [ apple_inventory, Ok "[]"; rosetta_absent; apple_settings ~rosetta:true ~kernel:true ] in
  let rosetta, rosetta_calls = doctor_sandbox ~keeper_toml no_rosetta in
  let rosetta_state = apple_probe no_rosetta in
  check bool "the probe says a prerequisite is missing" true
    (match rosetta_state with Readiness.Missing_prerequisite _ -> true | _ -> false);
  check bool "that is the Rosetta question, not the kernel one" true
    (rosetta_state <> Readiness.Missing_prerequisite Readiness.kernel_missing_reason);
  check bool "the doctor carries the probe's own Rosetta reason" true
    (rosetta = sandbox_of rosetta_state);
  check bool "a builder that cannot start needs setup" true
    (rosetta.condition = Onboarding_status.Needs_setup);
  check bool "the setup action is offered" true
    (rosetta.actions = [Onboarding_status.Configure_sandbox]);
  check bool "Rosetta is what the CLI's own question names" true
    (Readiness.apple_container_needs_rosetta
       ~run:(fst (fixture_runner no_rosetta)));

  let no_kernel = macos26_arm64_host
    @ [ apple_inventory, Ok "[]"; rosetta_installed; apple_settings ~rosetta:true ~kernel:false ] in
  let kernel, kernel_calls = doctor_sandbox ~keeper_toml no_kernel in
  check bool "a missing default kernel names the kernel" true
    (kernel = sandbox_of (Readiness.Missing_prerequisite Readiness.kernel_missing_reason));
  check bool "a missing default kernel needs setup" true
    (kernel.condition = Onboarding_status.Needs_setup);
  check bool "Rosetta and kernel are told apart" true (kernel.message <> rosetta.message);
  check bool "the CLI's kernel question agrees" true
    (Readiness.apple_container_needs_default_kernel
       ~run:(fst (fixture_runner no_kernel)));

  let stopped = macos26_arm64_host
    @ [ apple_inventory, Error Readiness.Command_failed; rosetta_installed;
        apple_settings ~rosetta:true ~kernel:true ] in
  let stopped_check, stopped_calls = doctor_sandbox ~keeper_toml stopped in
  check bool "a service that refuses its inventory needs setup" true
    (stopped_check.condition = Onboarding_status.Needs_setup);
  check bool "the probe calls that Probe_failed" true
    (match apple_probe stopped with Readiness.Probe_failed _ -> true | _ -> false);
  check bool "a stopped service is not an answering one" true
    (stopped_check <> ready);
  let absent, absent_calls = doctor_sandbox ~keeper_toml macos26_arm64_host in
  check bool "a missing container command needs setup" true
    (absent.condition = Onboarding_status.Needs_setup);
  check bool "a missing command and a stopped service say different things" true
    (absent.message <> stopped_check.message);
  List.iter (fun (what, calls) ->
    check bool (what ^ " stays within a handful of read-only commands") true
      (List.length calls <= 7))
    [ "healthy", ready_calls; "no Rosetta", rosetta_calls; "no kernel", kernel_calls;
      "stopped", stopped_calls; "absent", absent_calls ];
  check int "a healthy Apple Container costs six commands" 6 (List.length ready_calls)

let a_declared_docker_is_probed_as_docker () =
  let docker_toml = read "../config/keepers-default/imp.toml" in
  let ready, calls = doctor_sandbox ~keeper_toml:docker_toml healthy_docker in
  check bool "a Docker engine that answers is declared but unverified" true
    (ready.condition = Onboarding_status.Needs_verification);
  check bool "the Docker probe asks the Docker engine" true
    (List.mem docker_info calls);
  check bool "no Apple Container command is issued for a Docker declaration" false
    (List.exists (fun argv -> List.mem argv [apple_inventory; apple_properties; rosetta_receipt]) calls);
  let down, _ = doctor_sandbox ~keeper_toml:docker_toml
    (linux_host @ [ docker_info, Error Readiness.Command_failed ]) in
  check bool "a Docker daemon that refuses to answer needs setup" true
    (down.condition = Onboarding_status.Needs_setup);
  check bool "a stopped daemon is not rated like a healthy one" true (down <> ready);
  let no_docker, _ = doctor_sandbox ~keeper_toml:docker_toml linux_host in
  check bool "a host without docker needs setup" true
    (no_docker.condition = Onboarding_status.Needs_setup);
  let unknown_host, no_commands = doctor_sandbox ~keeper_toml:docker_toml [] in
  check bool "a host that cannot be identified needs setup" true
    (unknown_host.condition = Onboarding_status.Needs_setup);
  check bool "host detection alone is what a failed host spends" true (List.length no_commands <= 3)

(* Every state the probe can return, once, so a new variant breaks this table
   and the mapping together. *)
let every_probe_state_has_one_condition () =
  let condition state = (sandbox_of state).condition in
  let setup = Onboarding_status.Needs_setup and verify = Onboarding_status.Needs_verification in
  check bool "Service_ready" true (condition Readiness.Service_ready = verify);
  check bool "Needs_configuration" true (condition (Readiness.Needs_configuration "r") = verify);
  check bool "Missing_prerequisite" true (condition (Readiness.Missing_prerequisite "r") = setup);
  check bool "Unsupported_host" true (condition (Readiness.Unsupported_host "r") = setup);
  check bool "Unsupported_capability" true (condition (Readiness.Unsupported_capability "r") = setup);
  check bool "Probe_failed" true (condition (Readiness.Probe_failed "r") = setup);
  List.iter (fun state ->
    check bool "a probe reason reaches the operator whole" true
      (String_util.contains_substring (sandbox_of state).message "the one reason"))
    Readiness.[ Missing_prerequisite "the one reason"; Unsupported_host "the one reason";
                Unsupported_capability "the one reason"; Probe_failed "the one reason" ];
  (* The reason of Needs_configuration asks the operator to choose an endpoint,
     which the declaration the doctor already read has done. *)
  check bool "Needs_configuration does not repeat the probe's request" true
    (sandbox_of (Readiness.Needs_configuration "the one reason")
     = sandbox_of (Readiness.Needs_configuration "another reason"));
  check bool "Needs_configuration shows no probe reason" false
    (String_util.contains_substring
       (sandbox_of (Readiness.Needs_configuration "the one reason")).message "the one reason")

(* A microvm declaration that names no backend boots: the server takes the
   host's runtime through [microvm_backend_of_profile_defaults]. The doctor
   reads the same answer, so a host with a runtime probes it and a host
   without one reports the reason boot refuses with, probing nothing. The
   expected side is computed from the same host default, which is the only
   thing the test machine decides. *)
let a_declaration_that_names_no_backend_is_read_as_boot_reads_it () = with_workspace @@ fun base ->
  imp_workspace base
    "[keeper]\nactivation_mode = \"manual\"\nsandbox_profile = \"microvm\"\nsandbox_image = \"base\"\nnetwork_mode = \"inherit\"\ninstructions = \"Respond to the operator.\"\n";
  let healthy = macos26_arm64_host
    @ [ apple_inventory, Ok "[]"; rosetta_installed; apple_settings ~rosetta:true ~kernel:true ] in
  let run, calls = fixture_runner healthy in
  let observed = Onboarding_status.inspect ~sandbox:(Onboarding_status.Probe_with run) ~base_path:(Some base) in
  let sandbox = sandbox_check_of observed in
  check bool "the Keeper declaration itself loads" true
    (condition Onboarding_status.Keeper_declaration observed = Onboarding_status.Satisfied);
  (match Masc.Keeper_microvm_backend.default_for_host () with
   | Some Masc.Keeper_microvm_backend.Apple_container ->
     check bool "boot resolves it to Apple Container, so that is what is probed" true
       (sandbox = sandbox_of Readiness.Service_ready);
     check bool "the service was asked" true (List.mem apple_inventory (calls ()))
   | Some Masc.Keeper_microvm_backend.Nerdctl_kata | Some Masc.Keeper_microvm_backend.Microsandbox ->
     fail "no host assumes a runtime other than Apple Container"
   | None ->
     (match Readiness.boot_declaration ~base_path:base with
      | Error { Readiness.kind = Readiness.Declaration_invalid; detail } ->
        check string "the reason boot refuses with is the message" detail sandbox.message;
        check bool "a host with no runtime needs setup" true
          (sandbox.condition = Onboarding_status.Needs_setup);
        check bool "setup is the action" true
          (sandbox.actions = [Onboarding_status.Configure_sandbox]);
        check int "nothing is probed without a backend" 0 (List.length (calls ()))
      | Error { Readiness.kind = Readiness.Declaration_unreadable; _ } | Ok _ ->
        fail "the declaration should be invalid on a host with no runtime"))

(* A declared backend is never replaced by the host's. *)
let a_named_backend_is_not_replaced_by_the_host_default () = with_workspace @@ fun base ->
  imp_workspace base (microvm_imp "nerdctl_kata");
  let run, calls = fixture_runner macos26_arm64_host in
  let observed = Onboarding_status.inspect ~sandbox:(Onboarding_status.Probe_with run) ~base_path:(Some base) in
  check bool "nerdctl_kata is read from the file" true
    (sandbox_check_of observed
     = Onboarding_status.sandbox_check_of_entry
         { Readiness.backend = Readiness.Nerdctl_kata;
           state = Readiness.Unsupported_host "Kata setup requires a Linux host with hardware virtualization";
           guest_verification = Readiness.Not_run });
  check bool "the host default's service is not asked" false
    (List.mem apple_inventory (calls ()))

(* A selected remote SSH backend cannot be observed from here: the probe says
   Needs_configuration whatever the declaration holds. The doctor reaches the
   probe only after the declaration named an endpoint, so it does not tell the
   operator to choose one again. *)
(* A server answering requests reads no backend state: its inspection is
   [Not_probed], so a stopped service stays unverified there while the CLI
   probe reads the same declaration as needing setup. *)
let a_server_inspection_does_not_probe_the_backend () = with_workspace @@ fun base ->
  imp_workspace base (microvm_imp "apple_container");
  let stopped = macos26_arm64_host @ [ apple_inventory, Error Readiness.Command_failed ] in
  let run, _ = fixture_runner stopped in
  let probed = sandbox_check_of
      (Onboarding_status.inspect ~sandbox:(Onboarding_status.Probe_with run) ~base_path:(Some base)) in
  let served = sandbox_check_of
      (Onboarding_status.inspect_loaded ~base_path:(Some base)) in
  check bool "the CLI probe reads a stopped service as needing setup" true
    (probed.condition = Onboarding_status.Needs_setup);
  check bool "the server answer is unverified, not setup" true
    (served.condition = Onboarding_status.Needs_verification);
  check bool "its actions are the unverified ones" true
    (served.actions = [Onboarding_status.Configure_sandbox; Onboarding_status.Start_imp])

(* [Not_probed] still reads the declaration, which is a file and no command. *)
let an_unreadable_declaration_is_setup_even_when_not_probed () = with_workspace @@ fun base ->
  imp_workspace base "[keeper]\nsandbox_profile = \"microvm\"\nmicrovm_backend = \"no_such_backend\"\n";
  let served = sandbox_check_of
      (Onboarding_status.inspect ~sandbox:Onboarding_status.Not_probed ~base_path:(Some base)) in
  check bool "an invalid declaration is not called unverified" true
    (served.condition = Onboarding_status.Needs_setup)

let a_declared_remote_ssh_backend_is_unverified_not_unconfigured () = with_workspace @@ fun base ->
  imp_workspace base
    "[keeper]\nactivation_mode = \"manual\"\nsandbox_profile = \"remote_ssh\"\nremote_endpoint = \"builder\"\nnetwork_mode = \"inherit\"\ninstructions = \"Respond to the operator.\"\n";
  let run, _ = fixture_runner linux_host in
  let observed = Onboarding_status.inspect ~sandbox:(Onboarding_status.Probe_with run) ~base_path:(Some base) in
  match Readiness.declaration ~base_path:base with
  | Ok (Some { Readiness.backend = Readiness.Remote_ssh; _ }) ->
    let sandbox = sandbox_check_of observed in
    let asked_again = match
        (Readiness.probe ~host:(Readiness.Linux Readiness.X64) ~run
           ~require_rootless:false ~require_userns:false Readiness.Remote_ssh).state with
      | Readiness.Needs_configuration reason -> reason
      | Readiness.Service_ready | Readiness.Missing_prerequisite _ | Readiness.Unsupported_host _
      | Readiness.Unsupported_capability _ | Readiness.Probe_failed _ ->
        fail "the probe should ask remote SSH for configuration" in
    check bool "a declared endpoint is unverified" true
      (sandbox.condition = Onboarding_status.Needs_verification);
    check bool "the request to choose an endpoint is not repeated" false
      (String_util.contains_substring sandbox.message asked_again);
    check bool "the check is the one built from the typed state" true
      (sandbox = sandbox_check_of_entry_for Readiness.Remote_ssh
                   (Readiness.Needs_configuration asked_again))
  | Ok _ | Error _ -> fail "the fixture should declare remote_ssh"

let () = run "Onboarding observations"
  ["first use", [test_case "missing environment is an actionable state" `Quick absent_workspace;
                 test_case "uninitialized workspace is read-only" `Quick new_location_stays_untouched;
                 test_case "declared imp and concurrent unmet conditions" `Quick declared_is_not_verified;
                 test_case "a load failure names its site and id" `Quick
                   a_load_failure_says_what_failed;
                 test_case "a workspace without imp opens its Keepers' history" `Quick
                   a_workspace_without_imp_opens_its_keepers_history;
                 test_case "only checks every Keeper shares hold history closed" `Quick
                   only_shared_checks_hold_history_closed;
                 test_case "a workspace that asks for accounts is an account installation" `Quick
                   a_workspace_that_asks_for_accounts_is_an_account_installation];
   "sandbox probe", [test_case "a declared Apple Container is probed, not assumed" `Quick
                       a_declared_apple_container_is_probed_not_assumed;
                     test_case "a declared Docker is probed as Docker" `Quick
                       a_declared_docker_is_probed_as_docker;
                     test_case "every probe state has one condition" `Quick
                       every_probe_state_has_one_condition;
                     test_case "a declaration that names no backend is read as boot reads it" `Quick
                       a_declaration_that_names_no_backend_is_read_as_boot_reads_it;
                     test_case "a named backend is not replaced by the host default" `Quick
                       a_named_backend_is_not_replaced_by_the_host_default;
                     test_case "a declared remote SSH backend is unverified, not unconfigured" `Quick
                       a_declared_remote_ssh_backend_is_unverified_not_unconfigured;
                     test_case "a server inspection does not probe the backend" `Quick
                       a_server_inspection_does_not_probe_the_backend;
                     test_case "an unreadable declaration is setup even when not probed" `Quick
                       an_unreadable_declaration_is_setup_even_when_not_probed]]
