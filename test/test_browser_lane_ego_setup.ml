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
  ; ego : string  (** answers --version with both versions, and lists the fixture's spaces *)
  ; started : string  (** each fixture ego-browser appends its first argument here when it runs *)
  }

(* A fixture ego-browser that leaves a mark when it runs, so a case can say
   whether a plan started it, and how. Asked to run node, it also keeps the
   flag and the script it was given in [started].script. *)
let fake_ego ~started ~path ~script =
  write ~mode:0o755 path (Printf.sprintf
    "#!/bin/sh\nprintf '%%s\\n' \"$1\" >> '%s'\n[ \"$1\" = nodejs ] && printf '%%s\\n%%s' \"$2\" \"$3\" > '%s.script'\n%s\n"
    started started script)

let runs fixture =
  if Sys.file_exists fixture.started
  then List.filter (fun line -> line <> "") (String.split_on_char '\n' (read fixture.started))
  else []

let versions_answer =
  Printf.sprintf "printf '%%s\\n' '%s'" (String.concat "' '" (String.split_on_char '\n' version_lines))

(* ego lite's task spaces of the name setup asks for, as listTaskSpaces names
   them, on the one answer line the script writes. *)
let space ?(name = E.default_space) id ownership =
  `Assoc [ "spaceId", `Int id; "name", `String name; "ownership", `String ownership ]
let spaces_answer spaces =
  Printf.sprintf "printf '%%s\\n' '%s'"
    (Masc.Browser_ego_peer.result_marker
     ^ Yojson.Safe.to_string (`Assoc [ "ok", `Bool true; "value", `List spaces ]))

(* --version names the versions; nodejs runs the space listing. *)
let ego_script ~nodejs = Printf.sprintf "case \"$1\" in\n  nodejs) %s ;;\n  *) %s ;;\nesac" nodejs versions_answer

let operator_table ~command =
  Printf.sprintf
    {|
# 2026-10-23: the ego lite space the Keepers read Slack in.
[browser.live.ego]
command   =   "%s"   # the operator's own link
space = "slack" # not the default
|}
    command

let with_fixture ?(with_table = false) ?(spaces = []) ?config f =
  with_directory (fun root ->
    let started = Filename.concat root "started" in
    let ego = Filename.concat root "ego-browser" in
    fake_ego ~started ~path:ego ~script:(ego_script ~nodejs:(spaces_answer spaces));
    let config =
      match config with
      | Some config -> config
      | None -> if with_table then runtime_base ^ operator_table ~command:ego else runtime_base
    in
    let runtime = Filename.concat root "runtime.toml" in
    write runtime config;
    f { root; runtime; ego; started })

let request ?command ?space fixture = { E.runtime_config_path = fixture.runtime; command; space }

let found fixture () = R.probe_program R.Ego_browser fixture.ego

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
    check bool "the default space" true (table.space=C.Named_space E.default_space);
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
    check bool "as named" true ((table.command, table.space)=(fixture.ego, C.Named_space "work")))

(* --- a table that is there ---------------------------------------------- *)

let test_a_table_that_is_there_keeps_its_values () =
  with_fixture ~with_table:true (fun fixture ->
    let before = read fixture.runtime in
    let plan = plan_ok (request fixture) in
    check bool "unchanged" true (E.change plan = E.Unchanged);
    check (list string) "its space is looked up, and its command is not asked its versions"
      [ "nodejs" ] (runs fixture);
    apply_ok plan;
    check string "the file is not rewritten" before (read fixture.runtime))

let test_a_named_key_changes_that_key_and_no_other () =
  with_fixture ~with_table:true (fun fixture ->
    let plan = plan_ok (request ~space:"research" fixture) in
    check bool "only the space" true (E.change plan = E.Updated [ E.Space ]);
    check (list string) "the new space is looked up, and the command the table keeps is not asked its versions"
      [ "nodejs" ] (runs fixture);
    apply_ok plan;
    let table = configured fixture in
    check bool "the space changed" true ((table.command, table.space)=(fixture.ego, C.Named_space "research"));
    check bool "the operator's comment on the command stays" true
      (contains (read fixture.runtime) "# the operator's own link"))

(* --- the space against ego's own --------------------------------------- *)

(* ego refuses a worker that opens, by name, a space the operator made, and
   the worker then fails to start; setup refuses the name instead. *)
let test_a_space_the_operator_made_is_refused () =
  with_fixture ~spaces:[ space 36 "user" ] (fun fixture ->
    refused "a new table on the operator's space"
      (function E.Space_held_by_operator { space; space_id = 36 } -> space = C.Named_space E.default_space | _ -> false)
      fixture (request fixture) ~find:(found fixture) ());
  with_fixture ~with_table:true ~spaces:[ space ~name:"masc" 36 "user" ] (fun fixture ->
    refused "a space renamed to the operator's"
      (function E.Space_held_by_operator { space = C.Named_space "masc"; space_id = 36 } -> true | _ -> false)
      fixture (request ~space:"masc" fixture) ())

(* The agent's own space, and the agent's space the operator holds for now,
   are where the worker opens. *)
let test_the_agents_own_space_is_written () =
  List.iter (fun ownership ->
    with_fixture ~spaces:[ space 42 ownership ] (fun fixture ->
      let plan = plan_ok ~find:(found fixture) (request fixture) in
      check bool ("a new table on a space owned by " ^ ownership) true (E.change plan = E.Created);
      check string "ego is given the listing script, which opens no space"
        ("-e\n" ^ Masc.Browser_ego_peer.task_spaces_script) (read (fixture.started ^ ".script"));
      apply_ok plan;
      check bool "the default space" true ((configured fixture).space = C.Named_space E.default_space)))
    [ "agent"; "agentDelegatedToUser" ]

let test_spaces_that_cannot_be_read_are_refused () =
  with_fixture (fun fixture ->
    let closed = Filename.concat fixture.root "closed" in
    fake_ego ~started:fixture.started ~path:closed
      ~script:(ego_script ~nodejs:"echo 'ego lite is not running' >&2; exit 1");
    refused "an ego-browser that does not list its spaces"
      (function E.Spaces_unanswered { detail; _ } -> contains detail "ego lite is not running" | _ -> false)
      fixture (request ~command:closed fixture) ());
  with_fixture (fun fixture ->
    let unreachable = Filename.concat fixture.root "unreachable" in
    let threw = Masc.Browser_ego_peer.result_marker ^ {|{"ok":false,"error":"ego lite cannot be reached"}|} in
    fake_ego ~started:fixture.started ~path:unreachable
      ~script:(ego_script ~nodejs:(Printf.sprintf "printf '%%s\\n' '%s'" threw));
    refused "an ego-browser whose listing threw"
      (function E.Spaces_unanswered { detail; _ } -> contains detail "cannot be reached" | _ -> false)
      fixture (request ~command:unreachable fixture) ());
  with_fixture (fun fixture ->
    let killed = Filename.concat fixture.root "killed" in
    fake_ego ~started:fixture.started ~path:killed ~script:(ego_script ~nodejs:"kill -KILL $$");
    refused "an ego-browser ended by a signal"
      (function E.Spaces_unanswered _ -> true | _ -> false)
      fixture (request ~command:killed fixture) ());
  (* The script answers on success and on a throw alike; ending well with no
     answer line is an ego-browser that did not run it as masc asked. *)
  with_fixture (fun fixture ->
    let mute = Filename.concat fixture.root "mute" in
    fake_ego ~started:fixture.started ~path:mute ~script:(ego_script ~nodejs:"exit 0");
    refused "an ego-browser that ends well without an answer"
      (function E.Spaces_unreadable _ -> true | _ -> false)
      fixture (request ~command:mute fixture) ());
  with_fixture ~spaces:[ space 36 "team" ] (fun fixture ->
    refused "an owner masc does not know"
      (function E.Spaces_unreadable { detail; _ } -> contains detail "team" | _ -> false)
      fixture (request fixture) ~find:(found fixture) ())

(* The incident of 2026-10-26: a table that was there named a space the
   operator made later. Running setup again refuses it rather than leaving
   it as it is, whether the table changes or not. *)
let test_a_kept_space_the_operator_holds_is_refused () =
  with_fixture ~with_table:true ~spaces:[ space ~name:"slack" 36 "user" ] (fun fixture ->
    refused "the table's own space, kept as it is"
      (function E.Space_held_by_operator { space = C.Named_space "slack"; space_id = 36 } -> true | _ -> false)
      fixture (request fixture) ();
    let other = Filename.concat fixture.root "other-ego" in
    fake_ego ~started:fixture.started ~path:other
      ~script:(ego_script ~nodejs:(spaces_answer [ space ~name:"slack" 36 "user" ]));
    refused "the table's own space, with a new command"
      (function E.Space_held_by_operator { space = C.Named_space "slack"; space_id = 36 } -> true | _ -> false)
      fixture (request ~command:other fixture) ();
    Sys.remove fixture.ego;
    refused "a kept command that is gone"
      (function E.Ego_unstartable { path; _ } -> path = fixture.ego | _ -> false)
      fixture (request fixture) ());
  (* Only a space of that name is the table's. *)
  with_fixture ~with_table:true ~spaces:[ space ~name:"masc" 36 "user"; space ~name:"slack" 42 "agent" ] (fun fixture ->
    check bool "the operator's space of another name leaves the table as it is" true
      (E.change (plan_ok (request fixture)) = E.Unchanged))

let test_numeric_pin_is_preserved () =
  with_fixture ~with_table:true (fun fixture ->
    write fixture.runtime (Toml_line_editor.edit_table_int (read fixture.runtime)
      ~path:"browser.live.ego" ~key:"space" ~value:32);
    let before=read fixture.runtime in
    let plan=plan_ok (request fixture) in
    check bool "an existing ID is kept without rediscovery" true (E.change plan=E.Unchanged);
    apply_ok plan;
    check string "the numeric pin is not rewritten as a name" before (read fixture.runtime);
    check bool "server reads the exact numeric reference" true ((configured fixture).space=C.Existing_space 32);
    let named=plan_ok (request ~space:"32" fixture) in
    apply_ok named;
    check bool "an explicit numeric-looking name remains distinct" true ((configured fixture).space=C.Named_space "32"))

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
      (request fixture) ~find:(fun () -> R.probe_program R.Ego_browser silent) ())

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
      (request ~command:fixture.ego ~space:"  " fixture) ();
    check bool "a table that would not load is refused before ego is asked for its spaces" false
      (List.mem "nodejs" (runs fixture)))

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

(* The table itself was written since the plan, by someone else: a replan
   refuses rather than overwrite it. *)
let test_a_replan_refuses_a_table_written_since () =
  with_fixture (fun fixture ->
    let plan = plan_ok ~find:(found fixture) (request fixture) in
    let theirs = read fixture.runtime ^ "\n[browser.live.ego]\ncommand = \"/bin/sh\"\nspace = \"theirs\"\n" in
    write fixture.runtime theirs;
    (match E.replan plan with
     | Error E.Configuration_changed -> ()
     | Ok _ | Error _ -> fail "a table written since the plan is refused as changed");
    check string "their table is kept" theirs (read fixture.runtime))

let () =
  run "browser_lane_ego_setup"
    [ ( "a new table"
      , [ test_case "the ego found and the default space" `Quick test_the_ego_found_and_the_default_space
        ; test_case "named values" `Quick test_named_values ] )
    ; ( "a table that is there"
      , [ test_case "keeps its values" `Quick test_a_table_that_is_there_keeps_its_values
        ; test_case "keeps an exact numeric Space pin" `Quick test_numeric_pin_is_preserved
        ; test_case "a named key changes that key and no other" `Quick
            test_a_named_key_changes_that_key_and_no_other ] )
    ; ( "the space against ego's own"
      , [ test_case "a space the operator made is refused" `Quick test_a_space_the_operator_made_is_refused
        ; test_case "the agent's own space is written" `Quick test_the_agents_own_space_is_written
        ; test_case "spaces that cannot be read are refused" `Quick test_spaces_that_cannot_be_read_are_refused
        ; test_case "a kept space the operator holds is refused" `Quick
            test_a_kept_space_the_operator_holds_is_refused ] )
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
        ; test_case "a replan refuses a table written since" `Quick
            test_a_replan_refuses_a_table_written_since ] )
    ]
