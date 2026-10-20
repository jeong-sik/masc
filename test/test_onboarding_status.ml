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

(* The launcher and, when [declared], the launch.json masc browser-lane-setup
   writes beside it. *)
let browser_lane_fixture ?(declared=true) ?(connection_port="") () f =
  with_workspace @@ fun base ->
  let root = Filename.concat base ".masc" in
  List.iter (fun path -> Unix.mkdir path 0o700)
    [root; Filename.concat root "config"; Filename.concat root "browser-lane";
     Filename.concat (Filename.concat root "browser-lane") "host"];
  if connection_port <> "" then
    write (Filename.concat root "config/connection.toml")
      ("[server]\nhttp_port = " ^ connection_port ^ "\n");
  let script = "#!/bin/sh\nexec /unused/masc-browser-host --base-path " ^ base
               ^ " --token-file /unused/token \"$@\"\n" in
  write (Filename.concat (Filename.concat root "browser-lane") "host/launch") script;
  if declared then
    write (Filename.concat (Filename.concat root "browser-lane") "host/launch.json")
      (Yojson.Safe.to_string (`Assoc ["destination", `String "workspace_connection";
         "launcher_sha256", `String Digestif.SHA256.(to_hex (digest_string script))]));
  f base

let browser_lane_absent_launcher_is_unobserved () = with_workspace @@ fun base ->
  Unix.mkdir (Filename.concat base ".masc") 0o700;
  let observed = inspect ~base_path:(Some base) in
  check bool "an uninstalled lane reports no browser_lane observation" true
    (List.find_opt (fun (c : Onboarding_status.check) -> c.id = Onboarding_status.Browser_lane)
       observed.Onboarding_status.checks = None)

(* Only the declaration beside the launcher says where the host takes its
   address from, so without one the doctor cannot vouch for that host and says
   to install it again. *)
let browser_lane_undeclared_launcher_is_invalid_and_says_reinstall () =
  browser_lane_fixture ~declared:false ~connection_port:"64850" () @@ fun base ->
  let observed = inspect ~base_path:(Some base) in
  check bool "a launcher with no declaration is invalid" true
    (condition Onboarding_status.Browser_lane observed = Onboarding_status.Invalid);
  check bool "the missing declaration is named" true
    (String_util.contains_substring (message Onboarding_status.Browser_lane observed) "launch.json");
  check bool "the operator is told to run the installer again" true
    (String_util.contains_substring (message Onboarding_status.Browser_lane observed)
       "masc browser-lane-setup --mode extension")

(* masc doctor serves no lane, so it cannot see whether a host reaches the
   port the file names: a declared launcher is unverified here, not aligned. *)
let browser_lane_declared_launcher_follows_the_workspace () =
  browser_lane_fixture ~connection_port:"64850" () @@ fun base ->
  let observed = inspect ~base_path:(Some base) in
  check bool "a declared launcher outside a server needs verification" true
    (condition Onboarding_status.Browser_lane observed = Onboarding_status.Needs_verification);
  check bool "the workspace port is named" true
    (String_util.contains_substring (message Onboarding_status.Browser_lane observed) "64850")

(* The BiDi host is read from the record it keeps on disk, so the doctor
   answers for it with no server running. *)
module Record = Masc.Browser_bidi_host_record
module Launcher = Masc.Browser_lane_launcher
module Status = Masc.Browser_bidi_host_status

let bidi_check observed =
  List.find_opt (fun (c : Onboarding_status.check) -> c.id = Onboarding_status.Browser_bidi_host)
    observed.Onboarding_status.checks

let bidi_message observed = message Onboarding_status.Browser_bidi_host observed

let has text fragments =
  List.iter (fun fragment ->
      check bool ("said: " ^ fragment) true (String_util.contains_substring text fragment))
    fragments

let lacks text fragments =
  List.iter (fun fragment ->
      check bool ("not said: " ^ fragment) false (String_util.contains_substring text fragment))
    fragments

let says observed fragments = has (bidi_message observed) fragments

let lane_client raw =
  match Browser_lane.client_id_of_string raw with Ok id -> id | Error detail -> fail detail

let host_client = lane_client "0199c0de-0000-7000-8000-000000000001"
let bidi_address = "ws://127.0.0.1:9222/session"

let take_record base =
  match
    Record.take ~base_path:base ~pid:4242 ~bidi_url:bidi_address ~client_id:host_client
      ~now:1_791_000_000.
  with
  | Ok { held; not_synced = None } -> held
  | Ok { not_synced = Some detail; _ } -> fail detail
  | Error refusal -> fail (Record.refusal_message refusal)

let written = function Ok () -> () | Error failure -> fail (Record.write_failure_message failure)
let released held = match Record.release held with Ok () -> () | Error detail -> fail detail

let unacknowledged : Record.unacknowledged =
  { request_id = Record.request_id_of_wire "0199c0de-0000-4000-8000-0000000000a1"
  ; verb = Some Masc.Browser_bidi_peer.Page_interact; outcome = Record.Unknown
  ; cause = Record.Unconfirmed; at = 1_791_000_030. }

let host_entry : Record.entry =
  { pid = 4242; started_at = 1_791_000_000.; bidi_url = bidi_address; client_id = host_client
  ; attached_at = Some 1_791_000_002.; unacknowledged = []; ended = None }

(* Notes [n] more results than the record keeps, so a test can land exactly on
   the record's limit and then step one past it. *)
let repeat_note held n = for _ = 1 to n do written (Record.note_unacknowledged held unacknowledged) done

(* An observation as a caller holds it, for what no workspace on disk and no
   server in this process can be made to say. *)
let observation ?(base_path = "/workspace") ?(launcher = Launcher.Follows_workspace)
    ?(server = Launcher.Not_serving) ?(keeper = Status.Not_known) record
  : Status.observation =
  { lane = { base_path; launcher; workspace_port = Ok 8935; server }; record; keeper }

let launcher_of base = Filename.quote (Filename.concat base ".masc/browser-lane/host/launch")

(* Before any host: the launcher with the address still to be filled in. *)
let launch_command base = launcher_of base ^ " --bidi-url ws://127.0.0.1:PORT/session"

(* After a host: the launcher with the address that host was given. *)
let run_again base = "runs " ^ launcher_of base ^ " --bidi-url 'ws://127.0.0.1:9222/session'"
let record_file base = Filename.concat base ".masc/browser-lane/bidi-host.json"

let a_workspace_without_a_browser_lane_says_nothing_of_a_bidi_host () = with_workspace @@ fun base ->
  Unix.mkdir (Filename.concat base ".masc") 0o700;
  check bool "no lane and no host record: no BiDi check" true
    (bidi_check (inspect ~base_path:(Some base)) = None)

let a_lane_with_no_bidi_host_says_how_one_is_attached () =
  browser_lane_fixture ~connection_port:"64850" () @@ fun base ->
  let observed = inspect ~base_path:(Some base) in
  check bool "a host that never ran is something to set up" true
    (condition Onboarding_status.Browser_bidi_host observed = Onboarding_status.Needs_setup);
  says observed
    [ "No BiDi browser host has run for this workspace"
    ; "starts Firefox on a profile kept for this with --remote-debugging-port PORT"
    ; "then runs " ^ launch_command base
    ; "docs/design/browser-bidi-live-host.md" ];
  lacks (bidi_message observed) [ "browser-lane-setup" ]

(* The command is only good where its launcher is. The line above this one
   says to install the lane again when the launcher is not as an
   installation wrote it; this one says to install it first, then run it. *)
let a_launcher_that_cannot_be_run_as_it_is_is_installed_first () =
  (browser_lane_fixture ~declared:false ~connection_port:"64850" () @@ fun base ->
   let observed = inspect ~base_path:(Some base) in
   says observed
     [ "then runs " ^ launch_command base
     ; "The launcher there is not as an installation wrote it: the operator first installs the \
        lane again by running masc browser-lane-setup --mode host" ]);
  (* A host started from an executable on the PATH leaves a record in a
     workspace that has no launcher. *)
  (with_workspace @@ fun base ->
   let held = take_record base in
   written (Record.attached held ~now:1_791_000_002.);
   written (Record.ended held ~because:Record.Reason_only ~reason:"stopped by SIGINT" ~session:Record.No_session_left
              ~now:1_791_000_060.);
   released held;
   says (inspect ~base_path:(Some base))
     [ "The operator " ^ run_again base
     ; "No browser lane is installed in this workspace, so that launcher is not there yet: the \
        operator first installs the lane by running masc browser-lane-setup --mode host"
     ; "--base-path " ^ Filename.quote base ]);
  List.iter (fun (name, launcher, standing) ->
      check bool name true
        ((Status.report (observation ~launcher Record.Never_started)).attach.standing = standing))
    [ "installed", Launcher.Follows_workspace, Status.Launcher_installed
    ; "not installed", Launcher.Not_installed, Status.Launcher_not_installed
    ; "undeclared", Launcher.Undeclared, Status.Launcher_needs_reinstall
    ; "unreadable", Launcher.Unreadable, Status.Launcher_needs_reinstall
    ; "declared for another", Launcher.Describes_another_launcher, Status.Launcher_needs_reinstall ];
  (* A path and an address are one shell word each where they are part of a
     command. *)
  has
    (Status.message
       (observation ~base_path:"/work space" ~launcher:Launcher.Not_installed (Record.Died host_entry)))
    [ "runs '/work space/.masc/browser-lane/host/launch' --bidi-url 'ws://127.0.0.1:9222/session'"
    ; "--base-path '/work space'" ]

(* What the operator does next follows what became of the last host's
   session: a Firefox that holds one refuses every host until it is
   restarted, and one that holds none takes the next host as it is. The
   command names the address the last host was given. *)
let a_bidi_host_that_ended_says_why_and_what_comes_first () =
  browser_lane_fixture ~connection_port:"64850" () @@ fun base ->
  let held = take_record base in
  written (Record.attached held ~now:1_791_000_002.);
  let ended_with ~reason session =
    written (Record.ended held ~because:Record.Reason_only ~reason ~session ~now:1_791_000_060.);
    inspect ~base_path:(Some base)
  in
  let run = run_again base in
  let observed = ended_with ~reason:"stopped by SIGINT" Record.No_session_left in
  check bool "a host that ended is something to set up again" true
    (condition Onboarding_status.Browser_bidi_host observed = Onboarding_status.Needs_setup);
  says observed
    [ "No BiDi browser host is running"
    ; "(pid 4242, given ws://127.0.0.1:9222/session) ended at 2026-10-03T"
    ; {|with this reason: "stopped by SIGINT".|}
    ; "It ended its BiDi session, so the Firefox at that address needs no restart and takes the \
       next host while it runs. The operator " ^ run
    ; "a Firefox that was closed is first started again with --remote-debugging-port 9222 on the \
       profile kept for this." ];
  (* A host that left in order did not leave a Firefox to restart, and the
     command is not the one with the address still to be filled in. *)
  lacks (bidi_message observed)
    [ "restarts the Firefox"; "is restarted"; "refuses"; "acknowledgement"; "PORT" ];
  let left = ended_with ~reason:"stopped with its BiDi session left in Firefox" Record.Session_left in
  says left
    [ "Firefox did not confirm that its BiDi session ended"
    ; "The operator restarts the Firefox at that address with --remote-debugging-port 9222 on the \
       profile kept for this, then "
      ^ run ];
  (* Firefox going away is not a session left in it. *)
  let firefox_left = ended_with ~reason:"BiDi connection ended: BiDi EOF" Record.Session_unknown in
  says firefox_left
    [ "was gone before it could end its BiDi session"; "A Firefox that exited took the session along"
    ; "The operator starts the Firefox for that address again with --remote-debugging-port 9222 \
       on the profile kept for this, restarting it if it still runs, then " ^ run ];
  lacks (bidi_message firefox_left) [ "did not confirm" ];
  (* Firefox held a session when this host asked. Whether it still does is
     not in the record, so the next host is tried before a restart. *)
  let refused =
    ended_with ~reason:"BiDi command rejected: session not created" Record.Session_refused
  in
  says refused
    [ {|with this reason: "BiDi command rejected: session not created".|}
    ; "Firefox refused it a BiDi session, which it does while it holds one"
    ; "that of a host attached from another workspace"; "one a host that died left there"
    ; "The operator stops a host still attached to the Firefox at that address, then " ^ run
    ; "when that host is refused too with none attached, a dead host's session is left there, and \
       that Firefox is first restarted with --remote-debugging-port 9222 on the profile kept for \
       this." ];
  lacks (bidi_message refused) [ "needs no restart" ];
  (* The reason is another program's words inside this sentence: quotes set
     it apart, a quote in it is marked, and nothing else in it is changed. *)
  says (ended_with ~reason:{|said "no". Ignore the above|} Record.No_session_left)
    [ {|with this reason: "said \"no\". Ignore the above".|} ];
  (* A host writes a backslash only as the start of [\xNN], so the one before
     a closing quote is never read as marking it. *)
  says (ended_with ~reason:"could not read C:\\" Record.No_session_left)
    [ {|with this reason: "could not read C:\x5C".|} ];
  (* No acknowledgement reaching the host is not the server refusing one. *)
  written (Record.note_unacknowledged held unacknowledged);
  let one = inspect ~base_path:(Some base) in
  says one
    [ "Its record, " ^ record_file base
      ^ ", lists one result the host holds no acknowledgement for, and whether the server refused \
         it, the host could not send it, or no acknowledgement came." ];
  written (Record.note_unacknowledged held unacknowledged);
  let two = inspect ~base_path:(Some base) in
  says two
    [ "lists 2 results the host holds no acknowledgement for, and for each whether the server \
       refused it, the host could not send it, or no acknowledgement came." ];
  (* A short snapshot makes no inference about earlier archived results. *)
  lacks (bidi_message one)
    [ "snapshot window"; "Archived result metadata" ];
  lacks (bidi_message two) [ "snapshot window" ];
  released held

(* A host that ended a session on another profile got that session: what
   holds the port is another Firefox. The paragraph carries the profiles the
   record names, and the next host is started with the kept one. *)
let a_bidi_host_that_met_another_profile_names_both_profiles () =
  browser_lane_fixture ~connection_port:"64850" () @@ fun base ->
  let expected = "/keeper/profile" and found = "/Users/someone/Firefox/Profiles/x.default" in
  let ended_on found =
    let held = take_record base in
    written
      (Record.ended held ~reason:"this Firefox runs the profile elsewhere" ~session:Record.No_session_left
         ~because:(Record.Profile_not_kept { expected; found }) ~now:1_791_000_060.);
    released held;
    inspect ~base_path:(Some base)
  in
  let next_host = Status.firefox_profile_flag ^ " " ^ Filename.quote expected in
  says (ended_on (Some found)) [ found; expected; next_host ];
  says (ended_on None) [ expected; next_host ]

(* Manual host recovery installs the host launcher without changing Addon
   configuration. Addon readiness is not inferred from that record. *)
let manual_host_recovery_installs_only_its_launcher () =
  let ended =
    Record.Ended
      ( host_entry
      , { at = 1_791_000_060.; reason = "stopped"; session = Record.No_session_left
        ; because = Record.Reason_only } ) in
  let records =
    [ Record.Never_started; ended; Record.Died host_entry
    ; Record.Unreadable { detail = "torn by this test"; held = Some false } ] in
  let install = "masc browser-lane-setup --mode host --base-path '/workspace'" in
  List.iter (fun (launcher, lead) ->
      List.iter (fun record ->
          List.iter (fun keeper ->
              let said = Status.message (observation ~launcher ~keeper record) in
              has said [ lead ^ install ];
              lacks said [ "--mode bidi"; "--mode extension" ])
            [ Status.Not_configured; Status.Not_known ])
        records)
    [ Launcher.Not_installed, "the operator first installs the lane by running "
    ; Launcher.Undeclared, "the operator first installs the lane again by running " ]

let live_firefox_configuration_is_observed_without_starting_it () =
  let keeper configuration = Status.keeper_of_configuration configuration in
  let live_bidi : Browser_configuration.live_bidi =
    { firefox = "/Apps/firefox"; port = 9444; profile = "/keeper/profile" } in
  let configured = { Browser_configuration.none with live_bidi = Some live_bidi } in
  check bool "the Addon configuration preserves its selected endpoint and profile" true
    (keeper (Some configured)
     = Status.Addon_managed { port = live_bidi.port; profile = live_bidi.profile });
  check bool "the live lane off, with no table, starts nothing" true
    (keeper (Some { Browser_configuration.none with live_enabled = false }) = Status.Lane_off);
  check bool "the live lane off retains configuration without enabling the Addon" true
    (keeper (Some { configured with live_enabled = false }) = Status.Lane_off);
  check bool "no table" true (keeper (Some Browser_configuration.none) = Status.Not_configured);
  check bool "nothing loaded" true (keeper None = Status.Not_known);
  let paragraph keeper = Status.message (observation ~keeper Record.Never_started) in
  check bool "no table changes the paragraph" false
    (String.equal (paragraph Status.Not_configured) (paragraph Status.Not_known));
  check bool "the lane off changes the paragraph" false
    (String.equal (paragraph Status.Lane_off) (paragraph Status.Not_known))

(* Doctor reads Addon configuration from runtime.toml without starting it. *)
let doctor_reads_addon_firefox_configuration_from_runtime_toml () =
  browser_lane_fixture () @@ fun base ->
  let runtime = Filename.concat base ".masc/config/runtime.toml" in
  let profile = "/keeper/profile" in
  let table = "\n[browser.live.bidi]\nfirefox = \"/Apps/firefox\"\nprofile = \"" ^ profile ^ "\"\n" in
  write runtime (read "../scripts/fixtures/release-evidence/runtime.toml" ^ table);
  let observed = inspect ~base_path:(Some base) in
  says observed [ profile ];
  check bool "no manual host record does not make Addon readiness a setup failure" true
    (condition Onboarding_status.Browser_bidi_host observed = Onboarding_status.Needs_verification);
  check bool "offline Addon readiness is advisory" true
    (Onboarding_status.role Onboarding_status.Browser_bidi_host = Onboarding_status.Advisory);
  write (record_file base) "{broken";
  let unreadable_manual_host = inspect ~base_path:(Some base) in
  check bool "an unreadable manual host record does not decide Addon readiness" true
    (condition Onboarding_status.Browser_bidi_host unreadable_manual_host
     = Onboarding_status.Needs_verification);
  (* A server refuses a file that does not load, and so has no browser
     configuration either: doctor does not read its table. *)
  write runtime table;
  lacks (bidi_message (inspect ~base_path:(Some base))) [ profile ]

(* At the limit, earlier history is unknown. A valid longer record retains
   all listed results; the reader must not pretend it was already trimmed. *)
let a_record_at_the_limit_says_the_newest_are_kept () =
  browser_lane_fixture ~connection_port:"64850" () @@ fun base ->
  let held = take_record base in
  written (Record.attached held ~now:1_791_000_002.);
  repeat_note held Record.unacknowledged_limit;
  let observed = inspect ~base_path:(Some base) in
  says observed
    [ "lists 64 results the host holds no acknowledgement for"
    ; "at the 64-result snapshot window; it may omit older results"
    ; "this count does not establish whether archival succeeded" ];
  let longer = { host_entry with unacknowledged = List.init 65 (fun _ -> unacknowledged) } in
  let json = Record.entry_to_json longer in
  let decoded = match Record.entry_of_json json with
    | Ok record -> record | Error detail -> fail detail in
  let message = Status.message (observation (Record.Running decoded)) in
  has message [ "lists 65 results"; "All 65 listed results remain in the record" ];
  lacks message [ "keeps the newest 64"; "older than those has already left" ];
  released held

(* A host that never reached Firefox left no session there, and what kept it
   from one is still there for the next: it is not told that the Firefox
   takes the next host as it is. *)
let a_bidi_host_that_never_got_a_session_says_what_the_next_one_needs () =
  browser_lane_fixture ~connection_port:"64850" () @@ fun base ->
  let held = take_record base in
  written (Record.ended held ~because:Record.Reason_only ~reason:"BiDi connection failed: Connection refused"
             ~session:Record.No_session_left ~now:1_791_000_060.);
  released held;
  let observed = inspect ~base_path:(Some base) in
  says observed
    [ "It ended before Firefox gave it a session and left none there"
    ; "The next host needs a Firefox that answers at that address, one started with \
       --remote-debugging-port 9222 on the profile kept for this: the operator checks that, then "
      ^ run_again base ];
  lacks (bidi_message observed) [ "needs no restart"; "takes the next host" ]

(* A host that gave the workspace up without an ending reads as one that
   died. The case with a host that is running, read by another process as
   the doctor reads it, is in test_browser_bidi_host_record. *)
let a_bidi_host_that_died_says_the_session_may_be_left () =
  browser_lane_fixture ~connection_port:"64850" () @@ fun base ->
  let held = take_record base in
  written (Record.attached held ~now:1_791_000_002.);
  written (Record.note_unacknowledged held unacknowledged);
  released held;
  let observed = inspect ~base_path:(Some base) in
  check bool "a host that died is something to set up again" true
    (condition Onboarding_status.Browser_bidi_host observed = Onboarding_status.Needs_setup);
  says observed
    [ "(pid 4242, given ws://127.0.0.1:9222/session, started at 2026-10-03T"
    ; "left no reason for ending"; "killed or crashed"; "could not write one"
    ; "Its record, " ^ record_file base ^ ", lists one result the host holds no acknowledgement for"
    ; "Its BiDi session may be left in the Firefox at that address"
    ; "The operator " ^ run_again base
    ; "when Firefox refuses that host a session, the session was left there"
    ; "that Firefox is restarted with --remote-debugging-port 9222 on the profile kept for this \
       before the host is run again" ]

(* A record nobody can read still has a lock that says whether a host runs,
   and a host that runs refuses the one that would replace the record. *)
let a_bidi_host_record_that_cannot_be_read_is_invalid () =
  browser_lane_fixture ~connection_port:"64850" () @@ fun base ->
  let record = record_file base in
  write record "{\"pid\": 1";
  let observed = inspect ~base_path:(Some base) in
  check bool "a record that is not one is invalid" true
    (condition Onboarding_status.Browser_bidi_host observed = Onboarding_status.Invalid);
  says observed
    [ "record cannot be read"; "No host holds this workspace's lock, so none is running"
    ; "The next host keeps a copy of a record it read and cannot load beside it and writes a new \
       one in its place"
    ; "It does not start while the record cannot be read at all, or a new one cannot be written"
    ; "then runs " ^ launch_command base ];
  let held = take_record base in
  write record "{\"pid\": 1";
  let observed = inspect ~base_path:(Some base) in
  check bool "it is invalid while a host runs too" true
    (condition Onboarding_status.Browser_bidi_host observed = Onboarding_status.Invalid);
  says observed
    [ "A BiDi browser host holds this workspace's lock, so one is running"
    ; "its record cannot be read"; "A second host is refused while that one runs"
    ; "Once the operator stops it, the next host keeps a copy of a record it read and cannot load \
       beside it and writes a new one in its place. It does not start while the record cannot be \
       read at all, or a new one cannot be written." ];
  (* Why it cannot be read is the reader's own word; nothing is guessed
     beside it. *)
  lacks (bidi_message observed) [ "then runs" ];
  released held;
  let unasked =
    Status.message (observation (Record.Unreadable { detail = "Too many open files"; held = None }))
  in
  has unasked [ "could not be checked (Too many open files)" ];
  lacks unasked [ "new record"; "runs '/workspace" ]

(* What a running server adds: whether its own client list has the host the
   record names. A host serves hover and drag only on the server that lists
   it, so that is what the doctor is satisfied by. *)
let a_running_host_is_rated_by_the_server_that_lists_it () =
  let client transport client_id : Browser_lane.client_info =
    { client_id; browser = Browser_lane.Firefox; version = "157.0"; engine_version = "157.0"; transport }
  in
  let serving polling = Launcher.Serving { port = 8935; polling } in
  let listing = serving [ client Browser_lane.Webdriver_bidi host_client ] in
  (* The same ID over the extension is another connection. *)
  let lists_no_bidi = [ serving []; serving [ client Browser_lane.Web_extension host_client ] ] in
  (* Another BiDi client may be this host under an ID its record lacks. *)
  let lists_another =
    serving [ client Browser_lane.Webdriver_bidi (lane_client "0199c0de-0000-7000-8000-000000000002") ]
  in
  let connecting = { host_entry with attached_at = None } in
  let said server entry = Status.message (observation ~server (Record.Running entry)) in
  let rated name server entry verdict =
    check bool name true (Status.verdict (observation ~server (Record.Running entry)) = verdict)
  in
  has (said Launcher.Not_serving host_entry)
    [ "is attached to ws://127.0.0.1:9222/session since 2026-10-03T"
    ; "as client 0199c0de-0000-7000-8000-000000000001"
    ; "whether it polls one is not observed here"; "a running server's own check reports it" ];
  rated "outside a server an attached host is still to be verified" Launcher.Not_serving host_entry
    Status.Host_unverified;
  has (said listing host_entry) [ "It polls this server." ];
  rated "a host this server lists serves here" listing host_entry Status.Host_serving;
  List.iter (fun server ->
      has (said server host_entry)
        [ "This server lists no BiDi connection, so hover and drag are refused here"
        ; "the host polls another server"; "MASC_HTTP_BASE_URL or MASC_HTTP_PORT"
        ; "it has not polled for 120 seconds"; "this server started moments ago"
        ; "If no BiDi connection appears, the operator stops that host and starts it again from a \
           shell without those variables" ];
      rated "a host this server does not list is still to be verified" server host_entry
        Status.Host_unverified)
    lists_no_bidi;
  (* Hover and drag may be served on the BiDi connection that is listed, and
     it may be this host: neither a refusal nor stopping the host is said. *)
  has (said lists_another host_entry)
    [ "This server does not list that client and lists another BiDi connection"
    ; "this host's if it registered again under a new ID that it could not write to its record"
    ; "Otherwise it is another host's, and this one polls another server or has stopped polling" ];
  lacks (said lists_another host_entry) [ "refused here"; "stops that host" ];
  rated "a host listed only under another ID is still to be verified" lists_another host_entry
    Status.Host_unverified;
  (* Only a host with its session polls. A record that has not caught up
     does not make a listed host a connecting one. *)
  has (said listing connecting)
    [ "is attached to ws://127.0.0.1:9222/session and polls this server as client"
    ; "Its record does not say since when" ];
  lacks (said listing connecting) [ "is connecting" ];
  rated "a listed host whose record is behind serves here" listing connecting Status.Host_serving;
  List.iter (fun server ->
      has (said server connecting)
        [ "started at 2026-10-03T"; "is connecting to ws://127.0.0.1:9222/session" ];
      rated "a host still connecting is still to be verified" server connecting Status.Host_unverified)
    (Launcher.Not_serving :: lists_another :: lists_no_bidi);
  has (said listing { host_entry with unacknowledged = [ unacknowledged ] })
    [ "Its record, /workspace/.masc/browser-lane/bidi-host.json, lists one result the host holds \
       no acknowledgement for" ];
  (* The record says no host runs and the server lists a BiDi connection:
     the two are told apart and neither is taken for the other. *)
  let ending : Record.ending =
    { at = 1_791_000_060.; reason = "stopped by SIGINT"; session = Record.No_session_left; because = Record.Reason_only }
  in
  List.iter (fun record ->
      has (Status.message (observation ~server:listing record))
        [ "This server lists a BiDi connection all the same"
        ; "a host that died stays listed until 120 seconds pass without a poll"
        ; "a host started for another workspace can poll this server" ];
      List.iter (fun server ->
          lacks (Status.message (observation ~server record)) [ "all the same" ])
        (Launcher.Not_serving :: lists_no_bidi);
      check bool "a listed connection does not make a host that does not run a running one" true
        (match Status.verdict (observation ~server:listing record) with
         | Status.Host_not_running | Status.Host_unreadable -> true
         | Status.Host_absent | Status.Host_serving | Status.Host_unverified -> false))
    [ Record.Never_started; Record.Died host_entry
    ; Record.Ended ({ host_entry with ended = Some ending }, ending)
    ; Record.Unreadable { detail = "torn"; held = Some false } ];
  List.iter (fun (name, launcher, record, verdict) ->
      check bool name true (Status.verdict (observation ~launcher record) = verdict))
    [ "nothing installed and nothing run", Launcher.Not_installed, Record.Never_started, Status.Host_absent
    ; "a lane and no host", Launcher.Follows_workspace, Record.Never_started, Status.Host_not_running
    ; "a lane to reinstall and no host", Launcher.Undeclared, Record.Never_started, Status.Host_not_running
    ; "a record and no lane", Launcher.Not_installed, Record.Died host_entry, Status.Host_not_running
    ; ( "an unreadable record", Launcher.Follows_workspace
      , Record.Unreadable { detail = "torn"; held = Some false }, Status.Host_unreadable ) ]

(* What the server writes of the host, a reader of the same build reads
   back, and it reads nothing else as a report. *)
let a_bidi_host_report_reads_back_as_written () =
  let entry = { host_entry with unacknowledged = [ unacknowledged ] } in
  let ending : Record.ending =
    { at = 1_791_000_060.; reason = "stopped by SIGINT"; session = Record.Session_unknown; because = Record.Reason_only }
  in
  let ended = { entry with ended = Some ending } in
  let refused_ending = { ending with session = Record.Session_refused; because = Record.Reason_only } in
  let report ?launcher record = Status.report (observation ?launcher record) in
  List.iter (fun (name, written) ->
      check bool name true (Status.report_of_json (Status.report_to_json written) = Ok written))
    [ "never started", report Record.Never_started
    ; "record missing but lock held", report Record.Record_missing_but_locked
    ; "connecting", report (Record.Running { entry with attached_at = None })
    ; "attached", report (Record.Running entry)
    ; "ended", report (Record.Ended (ended, ending))
    ; ( "refused a session"
      , report (Record.Ended ({ entry with ended = Some refused_ending }, refused_ending)) )
    ; "died", report (Record.Died entry)
    ; ( "unreadable, no host"
      , report (Record.Unreadable { detail = "bidi-host.json is not JSON"; held = Some false }) )
    ; ( "unreadable, a host runs"
      , report (Record.Unreadable { detail = "written as layout 2"; held = Some true }) )
    ; ( "unreadable, lock unasked"
      , report (Record.Unreadable { detail = "Too many open files"; held = None }) )
    ; "no launcher", report ~launcher:Launcher.Not_installed (Record.Died entry)
    ; "a launcher to reinstall", report ~launcher:Launcher.Undeclared Record.Never_started ];
  (* Addon configuration is read back without any global start record. *)
  let managed = Status.Addon_managed { port = 9222; profile = "/keeper/profile" } in
  let with_keeper keeper record = Status.report (observation ~keeper record) in
  List.iter (fun (name, keeper) ->
      List.iter (fun (state, record) ->
          let written = with_keeper keeper record in
          check bool (name ^ ", " ^ state) true (Status.report_of_json (Status.report_to_json written) = Ok written))
        [ "never started", Record.Never_started; "attached", Record.Running entry
        ; "ended", Record.Ended (ended, ending); "died", Record.Died entry
        ; "unreadable, no host", Record.Unreadable { detail = "torn"; held = Some false } ])
    [ "Addon managed", managed
    ; "the lane is off", Status.Lane_off
    ; "no table", Status.Not_configured
    ; "configuration not loaded", Status.Not_known ];
  (* Times on disk are not whole seconds; one that was read is written and
     read again as it was. *)
  let on_disk = { entry with started_at = 1_791_000_000.123; attached_at = Some 1_791_000_002.457 } in
  let once = Status.report_to_json (report (Record.Running on_disk)) in
  (match Status.report_of_json once with
   | Ok read ->
     check bool "a report that was read is written as it was" true
       (Yojson.Safe.equal once (Status.report_to_json read))
   | Error detail -> fail detail);
  (* The ending a report writes is the one its state carries. *)
  (match
     Status.report_of_json
       (Status.report_to_json (report (Record.Ended ({ entry with ended = None }, ending))))
   with
   | Ok { state = Record.Ended (read, _); _ } ->
     check bool "the state's ending is the record's" true (read.ended = Some ending)
   | Ok _ -> fail "an ended host was read as another state"
   | Error detail -> fail detail);
  check string "the launcher is this workspace's" "/workspace/.masc/browser-lane/host/launch"
    (report Record.Never_started).attach.launcher;
  let fields_of written =
    match Status.report_to_json written with
    | `Assoc fields -> fields
    | _ -> fail "not an object"
  in
  let refused name json = check bool name true (Result.is_error (Status.report_of_json json)) in
  let with_field fields name value = `Assoc ((name, value) :: List.remove_assoc name fields) in
  let without fields name = `Assoc (List.remove_assoc name fields) in
  let ended_fields = fields_of (report (Record.Ended (ended, ending))) in
  let running_fields = fields_of (report (Record.Running entry)) in
  let never_fields = fields_of (report Record.Never_started) in
  let unreadable_fields =
    fields_of (report (Record.Unreadable { detail = "torn"; held = Some false }))
  in
  refused "not an object" (`String "running");
  refused "a state this reader does not know" (with_field ended_fields "state" (`String "paused"));
  (* The name has to be the state the record and the lock make. *)
  refused "running, of a record that has its ending" (with_field ended_fields "state" (`String "running"));
  refused "died, of a record that has its ending" (with_field ended_fields "state" (`String "died"));
  refused "ended, of a record without an ending" (with_field running_fields "state" (`String "ended"));
  refused "died, of a host whose lock is held" (with_field running_fields "state" (`String "died"));
  refused "running, with the lock free" (with_field running_fields "lock_held" (`Bool false));
  refused "running, without a word of the lock" (with_field running_fields "lock_held" `Null);
  refused "ended, with a word of the lock" (with_field ended_fields "lock_held" (`Bool false));
  refused "never started, with a record" (with_field never_fields "record" (Record.entry_to_json entry));
  refused "never started, with a word of the lock" (with_field never_fields "lock_held" (`Bool true));
  refused "running, with no record" (with_field running_fields "record" `Null);
  refused "unreadable, with a record"
    (with_field unreadable_fields "record" (Record.entry_to_json entry));
  refused "unreadable, with no reason" (with_field unreadable_fields "detail" `Null);
  refused "a reason that is no string" (with_field unreadable_fields "detail" (`Int 3));
  refused "a lock that is neither held nor free"
    (with_field running_fields "lock_held" (`String "yes"));
  List.iter (fun name -> refused ("no " ^ name) (without ended_fields name))
    [ "state"; "record"; "lock_held"; "detail"; "attach"; "keeper"; "message" ];
  refused "a message that is no string" (with_field ended_fields "message" (`Int 3));
  (* A field more or a field twice is another layout. *)
  refused "a field this reader does not know" (`Assoc (("since", `Null) :: ended_fields));
  refused "a field written twice" (`Assoc (ended_fields @ [ "state", `String "ended" ]));
  let attach_fields =
    match List.assoc "attach" ended_fields with
    | `Assoc fields -> fields
    | _ -> fail "attach is not an object"
  in
  let with_attach attach = with_field ended_fields "attach" attach in
  refused "a launcher state this reader does not know"
    (with_attach (with_field attach_fields "launcher_state" (`String "broken")));
  List.iter (fun name -> refused ("no attach " ^ name) (with_attach (without attach_fields name)))
    [ "launcher"; "arguments"; "launcher_state" ];
  refused "an attach field this reader does not know"
    (with_attach (`Assoc (("environment", `Null) :: attach_fields)));
  refused "an attach field written twice"
    (with_attach (`Assoc (attach_fields @ [ "launcher", `String "/elsewhere/launch" ])));
  refused "an attach that is no object" (with_attach (`String "launch"));
  refused "an empty launcher" (with_attach (with_field attach_fields "launcher" (`String "")));
  refused "arguments the launcher does not use"
    (with_attach (with_field attach_fields "arguments" (`String "anything goes")));
  refused "a message with a terminal control character"
    (with_field ended_fields "message" (`String "No BiDi browser host is running.\027"));
  let managed_fields =
    match List.assoc "keeper" (fields_of (with_keeper managed Record.Never_started)) with
    | `Assoc fields -> fields
    | _ -> fail "keeper is not an object"
  in
  let with_keeper_json keeper = with_field ended_fields "keeper" keeper in
  let with_managed name value = with_keeper_json (with_field managed_fields name value) in
  refused "a keeper this reader does not know" (with_keeper_json (`Assoc [ "kind", `String "operator" ]));
  refused "a keeper that names no kind" (with_keeper_json (`Assoc []));
  refused "a keeper that is no object" (with_keeper_json (`String "lane_off"));
  refused "a lane that is off, with a port"
    (with_keeper_json (`Assoc [ "kind", `String "lane_off"; "port", `Int 9222 ]));
  List.iter (fun name -> refused ("Addon managed, with no " ^ name) (with_keeper_json (without managed_fields name)))
    [ "port"; "profile" ];
  refused "Addon managed, on no port" (with_managed "port" (`Int 0));
  refused "Addon managed, on a port past the last" (with_managed "port" (`Int 65536));
  refused "Addon managed, on a port that is text" (with_managed "port" (`String "9222"));
  refused "Addon managed, with a profile that has a control character" (with_managed "profile" (`String "/a\027b"));
  refused "the removed global starter layout"
    (with_managed "kind" (`String "masc_starts"));
  refused "a last_start field on Addon configuration"
    (with_managed "last_start" (`Assoc [ "kind", `String "absent" ]));
  refused "a keeper field written twice"
    (with_keeper_json (`Assoc (managed_fields @ [ "port", `Int 9222 ])));
  (* A Keeper is sent the state and the paragraph, not the record. *)
  let ended_observation = observation (Record.Ended (ended, ending)) in
  check bool "the summary is the state and its message" true
    (Status.summary_to_json ended_observation
     = `Assoc
         [ "state", `String "ended"
         ; "message", `String (Status.message ended_observation) ])

(* The front door opened imp's history only when no check at all was Invalid, so
   a browser lane launcher left on an old port sent an operator with a working
   imp back to "choose a workspace" on every bare `masc` (measured 2026-09-15:
   launcher on 64850, workspace connection on 61372). *)
let a_stale_browser_lane_does_not_hold_imp_history_closed () =
  browser_lane_fixture ~declared:false ~connection_port:"64850" () @@ fun base ->
  let root = Filename.concat base ".masc" in
  let config = Filename.concat root "config" in
  let keepers = Filename.concat config "keepers" in
  Unix.mkdir keepers 0o700;
  write (Filename.concat config "runtime.toml")
    (read "../scripts/fixtures/release-evidence/runtime.toml");
  write (Filename.concat keepers "imp.toml") (read "../config/keepers-default/imp.toml");
  let not_booted = inspect ~base_path:(Some base) in
  check bool "imp that never booted still needs the journey" true
    (Onboarding_status.opening not_booted = Onboarding_status.Needs_journey);
  let metadata_dir = Filename.concat root "keepers" in
  Unix.mkdir metadata_dir 0o700;
  let metadata_path = Filename.concat metadata_dir "imp.json" in
  write metadata_path
    (Yojson.Safe.to_string (Masc_test_deps.current_meta_json_fixture ~name:"imp" ()));
  let observed = inspect ~base_path:(Some base) in
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
  let unreadable = inspect ~base_path:(Some base) in
  check bool "unreadable imp history still needs the journey" true
    (Onboarding_status.opening unreadable = Onboarding_status.Needs_journey);
  write metadata_path
    (Yojson.Safe.to_string (Masc_test_deps.current_meta_json_fixture ~name:"imp" ()));
  write (Filename.concat config "runtime.toml")
    "[providers.secret]\napi_key = \"x\"\ninvalid = [";
  let unresolved_model = inspect ~base_path:(Some base) in
  check bool "imp history is readable again, so only runtime.toml can hold it closed" true
    (condition Onboarding_status.Keeper_persistence unresolved_model
     = Onboarding_status.Satisfied);
  check bool "a runtime.toml the server cannot load keeps the journey" true
    (Onboarding_status.opening unresolved_model = Onboarding_status.Needs_journey)

(* A workspace whose Keepers were declared by hand never had imp, and bare
   `masc` walked it back into setup (measured 2026-09-23: sixteen persisted
   Keepers, opening needs_journey, "Your first Keeper, imp, has not been
   created."). History belongs to the workspace, not to one name. *)
let a_workspace_without_imp_opens_its_keepers_history () =
  browser_lane_fixture ~declared:true () @@ fun base ->
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
    | Workspace | Runtime_configuration | Keeper_persistence -> Required_to_open
    | Model_connection | Keeper_declaration | Sandbox | Browser_lane | Browser_bidi_host -> Advisory
  in
  List.iter (fun id ->
      check bool (Onboarding_status.check_id_name id) true
        (Onboarding_status.role id = expected id))
    Onboarding_status.[ Workspace; Runtime_configuration; Keeper_persistence;
                        Model_connection; Keeper_declaration; Sandbox; Browser_lane;
                        Browser_bidi_host ];
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
      (Onboarding_status.inspect_loaded ~configuration:None ~base_path:(Some base)) in
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
  | Ok { Readiness.backend = Readiness.Remote_ssh; _ } ->
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
                 test_case "an uninstalled browser lane is not observed" `Quick
                   browser_lane_absent_launcher_is_unobserved;
                 test_case "an undeclared browser lane launcher is invalid and says reinstall" `Quick
                   browser_lane_undeclared_launcher_is_invalid_and_says_reinstall;
                 test_case "a declared browser lane launcher outside a server needs verification" `Quick
                   browser_lane_declared_launcher_follows_the_workspace;
                 test_case "a stale browser lane does not hold imp's history closed" `Quick
                   a_stale_browser_lane_does_not_hold_imp_history_closed;
                 test_case "a workspace without imp opens its Keepers' history" `Quick
                   a_workspace_without_imp_opens_its_keepers_history;
                 test_case "only checks every Keeper shares hold history closed" `Quick
                   only_shared_checks_hold_history_closed];
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
                       an_unreadable_declaration_is_setup_even_when_not_probed];
   "BiDi host", [test_case "a workspace without a browser lane says nothing of a BiDi host" `Quick
                   a_workspace_without_a_browser_lane_says_nothing_of_a_bidi_host;
                 test_case "a lane with no BiDi host says how one is attached" `Quick
                   a_lane_with_no_bidi_host_says_how_one_is_attached;
                 test_case "a launcher that cannot be run as it is is installed first" `Quick
                   a_launcher_that_cannot_be_run_as_it_is_is_installed_first;
                 test_case "a BiDi host that ended says why and what comes first" `Quick
                   a_bidi_host_that_ended_says_why_and_what_comes_first;
                 test_case "a BiDi host that met another profile names both profiles" `Quick
                   a_bidi_host_that_met_another_profile_names_both_profiles;
                 test_case "manual host recovery installs only its launcher" `Quick
                   manual_host_recovery_installs_only_its_launcher;
                 test_case "live Firefox configuration is observed without starting it" `Quick
                   live_firefox_configuration_is_observed_without_starting_it;
                 test_case "doctor reads Addon Firefox configuration from runtime.toml" `Quick
                   doctor_reads_addon_firefox_configuration_from_runtime_toml;
                 test_case "a record at the limit says the newest are kept" `Quick
                   a_record_at_the_limit_says_the_newest_are_kept;
                 test_case "a BiDi host that never got a session says what the next one needs" `Quick
                   a_bidi_host_that_never_got_a_session_says_what_the_next_one_needs;
                 test_case "a BiDi host that died says the session may be left" `Quick
                   a_bidi_host_that_died_says_the_session_may_be_left;
                 test_case "a BiDi host record that cannot be read is invalid" `Quick
                   a_bidi_host_record_that_cannot_be_read_is_invalid;
                 test_case "a running host is rated by the server that lists it" `Quick
                   a_running_host_is_rated_by_the_server_that_lists_it;
                 test_case "a BiDi host report reads back as written" `Quick
                   a_bidi_host_report_reads_back_as_written]]
