(* The [browser.live.ego] table that [masc browser-lane-setup --mode ego]
   writes. What these tests fix: the ego-browser written answers with ego
   lite's and Chromium's versions, a table that is there is not overwritten,
   what is refused leaves the file as it was, and what is written is the table
   the server's loader reads back. Every case works in a scratch directory
   that holds its own runtime.toml. *)
open Alcotest

module E = Masc.Browser_lane_ego_setup
module R = Masc.Browser_runtime_dependencies
module C = Browser_configuration

(* Every commit validates the whole file, so a write needs a runtime.toml that
   loads: [runtime].default is required, and a named provider keeps the
   capability gate satisfied. The same rows test_browser_lane_bidi_setup uses. *)
let runtime_base =
  {|# Operator notes: kept as they are.
[providers."deepseek"]
display-name = "Fixture HTTP (deepseek)"
protocol = "openai-compatible-http"
endpoint = "https://fixture.invalid/v1"
[providers."deepseek".credentials]
type = "inline"
value = "previous-fixture-key"
[models.chat]
api-name = "deepseek-v4-pro"
["deepseek".chat]
[runtime]
default = "deepseek.chat" # the default stays
|}

let with_directory f =
  let dir = Filename.temp_file "ego-setup" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o700;
  let rec remove path =
    match Unix.lstat path with
    | { Unix.st_kind = Unix.S_DIR; _ } ->
      Array.iter (fun entry -> remove (Filename.concat path entry)) (Sys.readdir path);
      (try Unix.rmdir path with Unix.Unix_error _ -> ())
    | _ -> (try Sys.remove path with Sys_error _ -> ())
    | exception Unix.Unix_error _ -> ()
  in
  Fun.protect ~finally:(fun () -> remove dir) (fun () -> f (Unix.realpath dir))

let write ?(mode = 0o644) path contents =
  Out_channel.with_open_bin path (fun out -> output_string out contents);
  Unix.chmod path mode

let read path = In_channel.with_open_bin path In_channel.input_all

(* What ego lite 0.6.0.16 prints for --version once its onboarding is done. *)
let version_lines = "ego-browser 0.6.0.16\n  chromium 154.0.8037.44\n  node v24.21.0"

type fixture =
  { root : string
  ; runtime : string
  ; ego : string  (** answers --version with both versions *)
  ; started : string  (** a file each fixture ego-browser touches when it runs *)
  }

(* A fixture ego-browser that leaves a mark when it runs, so a case can say
   whether a plan started it. *)
let fake_ego ~started ~path ~script = write ~mode:0o755 path (Printf.sprintf "#!/bin/sh\ntouch '%s'\n%s\n" started script)

let operator_table ~command =
  Printf.sprintf
    {|
# 2026-10-23: the ego lite space the Keepers read Slack in.
[browser.live.ego]
command   =   "%s"   # the operator's own link
space = "slack" # not the default
|}
    command

let with_fixture ?(with_table = false) ?config f =
  with_directory (fun root ->
    let started = Filename.concat root "started" in
    let ego = Filename.concat root "ego-browser" in
    fake_ego ~started ~path:ego ~script:(Printf.sprintf "printf '%%s\\n' '%s'" (String.concat "' '" (String.split_on_char '\n' version_lines)));
    let config =
      match config with
      | Some config -> config
      | None -> if with_table then runtime_base ^ operator_table ~command:ego else runtime_base
    in
    let runtime = Filename.concat root "runtime.toml" in
    write runtime config;
    f { root; runtime; ego; started })

let request ?command ?space fixture = { E.runtime_config_path = fixture.runtime; command; space }

let found fixture () = R.probe fixture.ego

let never_asked () : R.check = fail "ego-browser was looked for, and nothing needed one"

let plan_ok ?(find = never_asked) request =
  match E.plan ~find_ego:find request with
  | Ok plan -> plan
  | Error error -> fail (E.error_message error)

let apply_ok plan =
  match E.apply plan with
  | Ok () -> ()
  | Error error -> fail (E.error_message error)

let configured fixture =
  match C.of_file fixture.runtime with
  | Ok { C.live_ego = Some table; _ } -> table
  | Ok _ -> fail "runtime.toml loads with no [browser.live.ego]"
  | Error reason -> fail ("runtime.toml does not load: " ^ reason)

let contains = String_util.contains_substring

let refused label expected fixture request ?(find = never_asked) () =
  let before = read fixture.runtime in
  (match E.plan ~find_ego:find request with
   | Error error when expected error -> ()
   | Error error -> failf "%s was refused for another reason: %s" label (E.error_message error)
   | Ok _ -> failf "%s was planned" label);
  check string (label ^ " leaves the file as it was") before (read fixture.runtime)

(* --- a new table ------------------------------------------------------- *)

let test_the_ego_found_and_the_default_space () =
  with_fixture (fun fixture ->
    let plan = plan_ok ~find:(found fixture) (request fixture) in
    check bool "a new table" true (E.change plan = E.Created);
    check (option (pair string string)) "the versions it answered"
      (Some ("0.6.0.16", "154.0.8037.44")) (E.versions plan);
    apply_ok plan;
    let table = configured fixture in
    check string "the command found" fixture.ego table.command;
    check string "the default space" E.default_space table.space;
    let text = read fixture.runtime in
    check bool "the operator's notes stay" true (contains text "# Operator notes: kept as they are.");
    check bool "the default stays" true (contains text "default = \"deepseek.chat\" # the default stays");
    let once = read fixture.runtime in
    apply_ok (plan_ok ~find:(found fixture) (request fixture));
    check string "applying again writes the same file" once (read fixture.runtime))

let test_named_values () =
  with_fixture (fun fixture ->
    let plan = plan_ok (request ~command:fixture.ego ~space:"work" fixture) in
    apply_ok plan;
    let table = configured fixture in
    check (pair string string) "as named" (fixture.ego, "work") (table.command, table.space))

(* --- a table that is there ---------------------------------------------- *)

let test_a_table_that_is_there_keeps_its_values () =
  with_fixture ~with_table:true (fun fixture ->
    let before = read fixture.runtime in
    let plan = plan_ok (request fixture) in
    check bool "unchanged" true (E.change plan = E.Unchanged);
    check bool "its command is not started" false (Sys.file_exists fixture.started);
    apply_ok plan;
    check string "the file is not rewritten" before (read fixture.runtime))

let test_a_named_key_changes_that_key_and_no_other () =
  with_fixture ~with_table:true (fun fixture ->
    let plan = plan_ok (request ~space:"research" fixture) in
    check bool "only the space" true (E.change plan = E.Updated [ E.Space ]);
    check bool "the command the table keeps is not started" false (Sys.file_exists fixture.started);
    apply_ok plan;
    let table = configured fixture in
    check (pair string string) "the space changed" (fixture.ego, "research") (table.command, table.space);
    check bool "the operator's comment on the command stays" true
      (contains (read fixture.runtime) "# the operator's own link"))

(* --- refused before any write ------------------------------------------ *)

let test_no_ego_to_name_is_refused () =
  with_fixture (fun fixture ->
    refused "no ego-browser" (function E.Ego_not_found -> true | _ -> false) fixture (request fixture)
      ~find:(fun () -> R.Missing "ego-browser") ())

(* An ego lite whose onboarding is not finished answers without its versions;
   the worker could not open a space with it, and would not start. *)
let test_an_ego_that_names_no_versions_is_refused () =
  with_fixture (fun fixture ->
    let unfinished = Filename.concat fixture.root "unfinished" in
    fake_ego ~started:fixture.started ~path:unfinished ~script:"echo 'ego-browser: not signed in'; exit 3";
    refused "an ego-browser that fails --version" (function E.Ego_unusable _ -> true | _ -> false) fixture
      (request ~command:unfinished fixture) ();
    let silent = Filename.concat fixture.root "silent" in
    fake_ego ~started:fixture.started ~path:silent ~script:"echo 'ego-browser 0.6.0.16'";
    refused "an ego-browser that names no Chromium" (function E.Ego_unusable _ -> true | _ -> false) fixture
      (request ~command:silent fixture) ();
    refused "a discovered ego-browser that names no versions"
      (function E.Ego_unusable { detail; _ } -> contains detail "named no ego lite" | _ -> false) fixture
      (request fixture) ~find:(fun () -> R.probe silent) ())

let test_a_named_command_must_be_an_absolute_file_that_runs () =
  with_fixture (fun fixture ->
    List.iter (fun (label, command) ->
      refused label (function E.Ego_not_executable _ -> true | _ -> false) fixture (request ~command fixture) ())
      [ "a relative path", "ego-browser";
        "a missing file", Filename.concat fixture.root "missing";
        "a space around it", " " ^ fixture.ego ];
    let directory = Filename.concat fixture.root "a directory" in
    Unix.mkdir directory 0o700;
    refused "a directory" (function E.Ego_not_executable _ -> true | _ -> false) fixture (request ~command:directory fixture) ())

let test_a_space_the_loader_refuses_is_not_written () =
  with_fixture (fun fixture ->
    refused "a blank space" (function E.Table_refused _ -> true | _ -> false) fixture
      (request ~command:fixture.ego ~space:"  " fixture) ())

let test_a_missing_runtime_toml_is_refused () =
  with_fixture (fun fixture ->
    let path = Filename.concat fixture.root "absent.toml" in
    match E.plan ~find_ego:never_asked { E.runtime_config_path = path; command = None; space = None } with
    | Error (E.Configuration_missing named) -> check string "names the file" path named
    | Error error -> fail (E.error_message error)
    | Ok _ -> fail "a missing runtime.toml was planned")

(* --- after the plan ------------------------------------------------------ *)

let test_a_change_after_the_plan_is_refused_and_not_overwritten () =
  with_fixture (fun fixture ->
    let plan = plan_ok ~find:(found fixture) (request fixture) in
    let changed = runtime_base ^ "# another editor wrote this\n" in
    write fixture.runtime changed;
    (match E.apply plan with
     | Error E.Configuration_changed -> ()
     | Ok () | Error _ -> fail "a file that changed after the plan is refused as changed");
    check string "the other writer's file is kept" changed (read fixture.runtime))

(* Another table of the same command was written since the plan: replanning
   takes the file as it is now and keeps both. *)
let test_a_replan_writes_beside_what_was_written_since () =
  with_fixture (fun fixture ->
    let plan = plan_ok ~find:(found fixture) (request fixture) in
    write fixture.runtime (read fixture.runtime ^ "\n[browser.automation]\ngeckodriver = \"/bin/sh\"\n");
    Sys.remove fixture.started;
    let plan = match E.replan plan with Ok plan -> plan | Error error -> fail (E.error_message error) in
    check bool "nothing is started again" false (Sys.file_exists fixture.started);
    apply_ok plan;
    ignore (configured fixture);
    check bool "the other table stays" true (contains (read fixture.runtime) "geckodriver = \"/bin/sh\""))

let test_a_lane_that_is_off_still_gets_the_table () =
  with_fixture ~config:(runtime_base ^ "\n[browser.live]\nenabled = false\n") (fun fixture ->
    let plan = plan_ok ~find:(found fixture) (request fixture) in
    check bool "the lane is off" false (E.lane_enabled plan);
    apply_ok plan;
    ignore (configured fixture))

let () =
  run "browser_lane_ego_setup"
    [ ( "a new table"
      , [ test_case "the ego found and the default space" `Quick test_the_ego_found_and_the_default_space
        ; test_case "named values" `Quick test_named_values ] )
    ; ( "a table that is there"
      , [ test_case "keeps its values" `Quick test_a_table_that_is_there_keeps_its_values
        ; test_case "a named key changes that key and no other" `Quick
            test_a_named_key_changes_that_key_and_no_other ] )
    ; ( "refused"
      , [ test_case "no ego-browser to name" `Quick test_no_ego_to_name_is_refused
        ; test_case "an ego that names no versions" `Quick test_an_ego_that_names_no_versions_is_refused
        ; test_case "a named command must be an absolute file that runs" `Quick
            test_a_named_command_must_be_an_absolute_file_that_runs
        ; test_case "a space the loader refuses" `Quick test_a_space_the_loader_refuses_is_not_written
        ; test_case "a missing runtime.toml" `Quick test_a_missing_runtime_toml_is_refused ] )
    ; ( "after the plan"
      , [ test_case "a change after the plan" `Quick test_a_change_after_the_plan_is_refused_and_not_overwritten
        ; test_case "a replan writes beside what was written since" `Quick
            test_a_replan_writes_beside_what_was_written_since
        ; test_case "a lane that is off still gets the table" `Quick test_a_lane_that_is_off_still_gets_the_table ] )
    ]
