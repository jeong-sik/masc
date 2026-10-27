(* The automation lane's configuration that [masc browser-lane-setup --mode
   automation] writes. What these tests fix: a configuration that is there is
   not overwritten and is edited where it is, what is refused leaves the file
   as it was, and what is written is what the server's loader reads back. Every
   case works in a scratch directory that holds its own runtime.toml. *)
open Alcotest

module A = Masc.Browser_lane_automation_setup
module R = Masc.Browser_runtime_dependencies
module C = Browser_configuration

(* Every commit validates the whole file, so a write needs a runtime.toml that
   loads. The rows test_voice_setup uses. *)
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
  let dir = Filename.temp_file "automation-setup" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o700;
  let rec remove path =
    match Unix.lstat path with
    | { Unix.st_kind = Unix.S_DIR; _ } ->
      (try Unix.chmod path 0o700 with Unix.Unix_error _ -> ());
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
let contains = String_util.contains_substring

type fixture =
  { root : string
  ; runtime : string
  ; driver : string  (** A geckodriver that answers --version. *)
  ; other_driver : string
  ; browser : string
  }

let program ~mode path text = write ~mode path ("#!/bin/sh\necho '" ^ text ^ "'\n")

let with_fixture ?(config = runtime_base) f =
  with_directory (fun root ->
    let driver = Filename.concat root "geckodriver one" in
    program ~mode:0o755 driver "geckodriver 0.0 (fixture)";
    let other_driver = Filename.concat root "geckodriver two" in
    program ~mode:0o755 other_driver "geckodriver 0.1 (other)";
    let browser = Filename.concat root "fake zen" in
    program ~mode:0o755 browser "Zen 0.0 (fixture)";
    let runtime = Filename.concat root "runtime.toml" in
    write runtime config;
    f { root; runtime; driver; other_driver; browser })

let request ?geckodriver ?browser fixture =
  { A.runtime_config_path = fixture.runtime; geckodriver; browser }

let found fixture () =
  R.Started { command = fixture.driver; path = fixture.driver; output = "geckodriver 0.0" }

let never_asked () : R.check = fail "geckodriver was looked for, and nothing needed one"

let plan_ok ?(find = never_asked) request =
  match A.plan ~find_geckodriver:find request with
  | Ok plan -> plan
  | Error error -> fail (A.error_message error)

let apply_ok plan =
  match A.apply plan with
  | Ok () -> ()
  | Error error -> fail (A.error_message error)

let configured fixture =
  match C.of_file fixture.runtime with
  | Ok { C.automation = Some table; _ } -> table
  | Ok _ -> fail "runtime.toml loads with no automation configuration"
  | Error reason -> fail ("runtime.toml does not load: " ^ reason)

let message_of = function
  | Ok _ -> fail "expected a refusal"
  | Error error -> A.error_message error

(* A refusal the planner makes: the file is as it was. *)
let refused ?(find = never_asked) label expected fixture request =
  let before = read fixture.runtime in
  (match A.plan ~find_geckodriver:find request with
   | Ok _ -> fail (label ^ ": expected a refusal")
   | Error error ->
     check bool (label ^ " (got: " ^ A.error_message error ^ ")") true (expected error));
  check string (label ^ ": runtime.toml is as it was") before (read fixture.runtime)

let lines text = String.split_on_char '\n' text

(* Each line of [original], in order, is still a line of [edited]. *)
let lines_kept label original edited =
  let rec walk kept = function
    | [] -> true
    | line :: rest ->
      (match kept with
       | [] -> false
       | candidate :: after ->
         if String.equal line candidate then walk after rest else walk after (line :: rest))
  in
  check bool (label ^ ": every original line survives, in order") true
    (walk (lines edited) (lines original))

let count_lines text wanted =
  List.length (List.filter (fun line -> String.equal (String.trim line) wanted) (lines text))

let values (table : C.automation) = table.driver, table.binary

(* --- a configuration that is not there ----------------------------------- *)

let test_a_new_table_is_written_with_the_found_geckodriver_and_no_browser () =
  with_fixture (fun fixture ->
    let plan = plan_ok ~find:(found fixture) (request fixture) in
    check string "planning writes nothing" runtime_base (read fixture.runtime);
    check bool "a new table" true (A.location plan = A.New_table);
    check bool "created" true (A.change plan = A.Created);
    apply_ok plan;
    let edited = read fixture.runtime in
    lines_kept "the notes and tables" runtime_base edited;
    check int "one automation header" 1 (count_lines edited "[browser.automation]");
    check bool "no binary is written for a Firefox nobody named" false
      (contains edited "binary");
    check (pair string (option string)) "what the loader reads"
      (fixture.driver, None) (values (configured fixture)))

let test_named_values_are_written_as_named () =
  with_fixture (fun fixture ->
    let plan =
      plan_ok (request ~geckodriver:fixture.other_driver ~browser:fixture.browser fixture)
    in
    apply_ok plan;
    check (pair string (option string)) "what the loader reads"
      (fixture.other_driver, Some fixture.browser) (values (configured fixture)))

let test_applying_twice_writes_the_same_file () =
  with_fixture (fun fixture ->
    apply_ok (plan_ok ~find:(found fixture) (request fixture));
    let once = read fixture.runtime in
    let second = plan_ok (request fixture) in
    check bool "unchanged the second time" true (A.change second = A.Unchanged);
    apply_ok second;
    check string "the file is the same" once (read fixture.runtime))

(* --- a configuration that is there ---------------------------------------- *)

let automation_table fixture =
  Printf.sprintf
    "\n# the driver the Keepers use\n[browser.automation]\ngeckodriver   = \"%s\"   # pinned\n"
    fixture.driver

let test_a_table_that_is_there_keeps_its_values_byte_for_byte () =
  with_fixture (fun fixture ->
    let config = runtime_base ^ automation_table fixture in
    write fixture.runtime config;
    let plan = plan_ok (request fixture) in
    check bool "where it was" true (A.location plan = A.Automation_table);
    check bool "nothing named" true (A.change plan = A.Unchanged);
    check (list string) "programs that are there are not noted" [] (A.notes plan);
    apply_ok plan;
    check string "the file is as it was" config (read fixture.runtime))

let test_a_named_browser_is_added_to_the_table_that_is_there () =
  with_fixture (fun fixture ->
    let config = runtime_base ^ automation_table fixture in
    write fixture.runtime config;
    let plan = plan_ok (request ~browser:fixture.browser fixture) in
    check bool "only the browser" true (A.change plan = A.Updated [ A.Browser ]);
    apply_ok plan;
    let edited = read fixture.runtime in
    lines_kept "the original lines" config edited;
    check int "no second header" 1 (count_lines edited "[browser.automation]");
    check (pair string (option string)) "driver kept, browser added"
      (fixture.driver, Some fixture.browser) (values (configured fixture)))

(* The live runtime.toml of the operator who wrote this is spelled this way:
   the keys directly in [browser]. A second spelling beside them is a file the
   loader refuses. *)
let root_spelling fixture =
  Printf.sprintf "\n[browser]\ngeckodriver = \"%s\"\nbinary = \"%s\"\n" fixture.driver
    fixture.browser

let test_keys_that_are_directly_in_browser_are_edited_there () =
  with_fixture (fun fixture ->
    let config = runtime_base ^ root_spelling fixture in
    write fixture.runtime config;
    let plan = plan_ok (request ~geckodriver:fixture.other_driver fixture) in
    check bool "where it was" true (A.location plan = A.Browser_table);
    check bool "only the driver" true (A.change plan = A.Updated [ A.Geckodriver ]);
    apply_ok plan;
    let edited = read fixture.runtime in
    check int "no [browser.automation] was added" 0 (count_lines edited "[browser.automation]");
    check string "one line differs"
      (String.concat "\n"
         (List.map
            (fun line ->
               if contains line "geckodriver =" then
                 Printf.sprintf "geckodriver = \"%s\"" fixture.other_driver
               else line)
            (lines config)))
      edited;
    check (pair string (option string)) "browser kept"
      (fixture.other_driver, Some fixture.browser) (values (configured fixture)))

(* A table that is there names a Firefox to drive, so one with no driver is a
   file the server refuses, and setup refuses it untouched. *)
let test_a_table_with_no_driver_is_refused_untouched () =
  with_fixture (fun fixture ->
    let config = runtime_base ^ "\n[browser.automation]\n" in
    write fixture.runtime config;
    (match A.plan ~find_geckodriver:(found fixture) (request fixture) with
     | Error (A.Configuration_refused _) -> ()
     | Ok _ | Error _ -> fail "a table with no driver is refused");
    check string "untouched" config (read fixture.runtime))

let test_other_browser_tables_are_not_touched () =
  with_fixture (fun fixture ->
    let others =
      "\n[browser.live.bidi]\nfirefox = \"/opt/f\"\nprofile = \"/opt/p\"\n\n[browser.stagehand]\n\
       chrome = \"/opt/c\"\nextension = \"/opt/e\"\n"
    in
    (* The paths need not exist: the loader reads them as text. *)
    write fixture.runtime (runtime_base ^ others);
    apply_ok (plan_ok ~find:(found fixture) (request fixture));
    lines_kept "the other tables" (runtime_base ^ others) (read fixture.runtime);
    check bool "the bidi table still loads" true
      (match C.of_file fixture.runtime with
       | Ok { C.live_bidi = Some _; stagehand = Some _; automation = Some _; _ } -> true
       | Ok _ | Error _ -> false))

(* --- what is refused leaves the file as it was --------------------------- *)

let test_no_geckodriver_to_name_is_refused () =
  with_fixture (fun fixture ->
    refused "nothing found"
      (function A.Geckodriver_not_found -> true | _ -> false)
      fixture
      (request fixture)
      ~find:(fun () -> R.Missing "geckodriver");
    refused "one that does not answer"
      (function A.Geckodriver_does_not_answer { path; _ } -> String.equal path "/opt/g" | _ -> false)
      fixture
      (request fixture)
      ~find:(fun () ->
        R.Failed { command = "/opt/g"; path = "/opt/g"; status = Unix.WEXITED 3; detail = "broken" }))

let test_a_named_program_must_be_a_file_that_can_run () =
  with_fixture (fun fixture ->
    let absent = Filename.concat fixture.root "absent driver" in
    refused "an absent driver"
      (function
        | A.Not_executable { key = A.Geckodriver; path } -> String.equal path absent
        | _ -> false)
      fixture
      (request ~geckodriver:absent fixture);
    let plain = Filename.concat fixture.root "plain file" in
    write plain "not a program";
    refused "a browser that is not executable"
      (function
        | A.Not_executable { key = A.Browser; path } -> String.equal path plain
        | _ -> false)
      fixture
      (request ~geckodriver:fixture.driver ~browser:plain fixture))

let test_values_the_loader_refuses_are_not_written () =
  with_fixture (fun fixture ->
    List.iter
      (fun (label, request) ->
         let before = read fixture.runtime in
         let message = message_of (A.plan ~find_geckodriver:never_asked request) in
         check bool (label ^ " (got: " ^ message ^ ")") true
           (contains message "absolute path");
         check string (label ^ ": runtime.toml is as it was") before (read fixture.runtime))
      [ "a driver that is not a path", request ~geckodriver:"geckodriver" fixture
      ; "a browser with a tilde"
      , request ~geckodriver:fixture.driver ~browser:"~/Applications/Zen" fixture
      ])

let test_a_missing_runtime_toml_is_refused_and_not_created () =
  with_fixture (fun fixture ->
    Sys.remove fixture.runtime;
    (match A.plan ~find_geckodriver:never_asked (request fixture) with
     | Error (A.Configuration_missing path) -> check string "the path" fixture.runtime path
     | Ok _ | Error _ -> fail "a missing runtime.toml is refused as missing");
    check bool "it was not created" false (Sys.file_exists fixture.runtime))

(* The table is fine and the file is not one the server would load: the
   commit validates the whole file, so a write is refused for the file. *)
let test_a_file_the_server_would_not_load_is_refused_untouched () =
  with_fixture ~config:"[runtime]\nunknown_default = true\n" (fun fixture ->
    let before = read fixture.runtime in
    let message =
      message_of (A.plan ~find_geckodriver:never_asked (request ~geckodriver:fixture.driver fixture))
    in
    check bool ("refused as the file (got: " ^ message ^ ")") true (contains message "runtime");
    check string "untouched" before (read fixture.runtime))

let test_both_spellings_in_the_file_are_refused_by_the_loader () =
  with_fixture (fun fixture ->
    let config =
      runtime_base ^ root_spelling fixture ^ "\n[browser.automation]\ngeckodriver = \"/x\"\n"
    in
    write fixture.runtime config;
    let message = message_of (A.plan ~find_geckodriver:never_asked (request fixture)) in
    check bool ("refused as the loader says (got: " ^ message ^ ")") true
      (contains message "only one place");
    check string "untouched" config (read fixture.runtime))

(* The loader accepts a header beside dotted keys or an inline table; a strict
   reader refuses that file. None of these is edited. *)
let test_a_spelling_the_line_editor_cannot_reach_is_refused_untouched () =
  List.iter
    (fun (label, extra, request_of) ->
       with_fixture (fun fixture ->
         let config = extra fixture ^ runtime_base in
         write fixture.runtime config;
         refused label
           (function A.Table_refused _ -> true | _ -> false)
           fixture
           (request_of fixture)
           ~find:(found fixture)))
    [ ( "dotted keys at the root"
      , (fun f -> Printf.sprintf "browser.automation.geckodriver = \"%s\"\n" f.driver)
      , fun f -> request ~browser:f.browser f )
    ; ( "an inline automation table"
      , (fun f ->
          Printf.sprintf "[browser]\nautomation = { geckodriver = \"%s\" }\n" f.driver)
      , fun f -> request ~browser:f.browser f )
    ; ( "[browser] written inline"
      , (fun _ -> "browser = { live = { ego = { command = \"/bin/sh\", space = \"masc\" } } }\n")
      , fun f -> request f )
    ; ( "dotted keys directly under browser"
      , (fun f -> Printf.sprintf "browser.geckodriver = \"%s\"\n" f.driver)
      , fun f -> request ~browser:f.browser f )
    ]

(* A run that writes the bidi table first changes runtime.toml after this plan
   was made. The plan is made again from the file as it is: it keeps what it
   decided, looks for no program again, and is then accepted. *)
let test_a_plan_made_again_keeps_its_decisions_and_runs_nothing () =
  with_fixture (fun fixture ->
    let calls = ref 0 in
    let find () =
      incr calls;
      R.Started { command = fixture.driver; path = fixture.driver; output = "geckodriver 0.0" }
    in
    let plan = plan_ok ~find (request fixture) in
    check int "asked once to plan" 1 !calls;
    let other_write = runtime_base ^ "\n[browser.live.bidi]\nfirefox = \"/opt/f\"\nprofile = \"/opt/p\"\n" in
    write fixture.runtime other_write;
    (match A.apply plan with
     | Error A.Configuration_changed -> ()
     | Ok () | Error _ -> fail "the stale plan is refused");
    (match A.replan plan with
     | Ok again ->
       check int "nothing was looked for again" 1 !calls;
       check bool "the same table" true
         (Browser_configuration.equal_automation (A.table plan) (A.table again));
       apply_ok again
     | Error error -> fail (A.error_message error));
    lines_kept "the other writer's table survives" other_write (read fixture.runtime);
    check string "and the driver is there" fixture.driver (configured fixture).C.driver)

(* The automation table itself was written since the plan, by someone else:
   a replan refuses rather than overwrite it. *)
let test_a_plan_made_again_refuses_a_table_written_since () =
  with_fixture (fun fixture ->
    let plan = plan_ok ~find:(found fixture) (request fixture) in
    let theirs = read fixture.runtime ^ "\n[browser.automation]\ngeckodriver = \"/bin/sh\"\n" in
    write fixture.runtime theirs;
    (match A.replan plan with
     | Error A.Configuration_changed -> ()
     | Ok _ | Error _ -> fail "an automation table written since the plan is refused as changed");
    check string "their table is kept" theirs (read fixture.runtime))

let test_a_plan_made_again_is_refused_when_the_file_no_longer_takes_it () =
  with_fixture (fun fixture ->
    let plan = plan_ok ~find:(found fixture) (request fixture) in
    (* Before the first header, so the key is at the root of the file. *)
    write fixture.runtime
      (Printf.sprintf "browser.automation.geckodriver = \"%s\"\n" fixture.driver ^ runtime_base);
    match A.replan plan with
    | Error (A.Table_refused _) -> ()
    | Ok _ | Error _ -> fail "a file that now declares the table another way is refused")

(* The probe trims what it is given. A value written with a space around it
   would name a file the probe never saw. *)
let test_a_named_path_with_a_space_around_it_is_refused () =
  with_fixture (fun fixture ->
    List.iter
      (fun (label, request, key, path) ->
         refused label
           (function
             | A.Not_executable { key = found_key; path = found } ->
               found_key = key && String.equal found path
             | _ -> false)
           fixture
           request)
      [ ( "a trailing space on the driver"
        , request ~geckodriver:(fixture.driver ^ " ") fixture
        , A.Geckodriver
        , fixture.driver ^ " " )
      ; ( "a trailing tab on the browser"
        , request ~geckodriver:fixture.driver ~browser:(fixture.browser ^ "\t") fixture
        , A.Browser
        , fixture.browser ^ "\t" )
      ])

(* A line inside a multi-line string that reads like a header is data. It is
   not a declaration of the table, and it does not hide one. *)
let string_with_a_fake_header =
  {|# Operator notes: kept as they are.
[providers."deepseek"]
display-name = """
[browser.automation]
"""
protocol = "openai-compatible-http"
endpoint = "https://fixture.invalid/v1"
[providers."deepseek".credentials]
type = "inline"
value = "previous-fixture-key"
[models.chat]
api-name = "deepseek-v4-pro"
["deepseek".chat]
[runtime]
default = "deepseek.chat"
|}

let test_a_header_inside_a_string_is_not_a_declaration_and_does_not_hide_one () =
  with_fixture ~config:string_with_a_fake_header (fun fixture ->
    let plan = plan_ok ~find:(found fixture) (request fixture) in
    check bool "the table is new" true (A.location plan = A.New_table);
    apply_ok plan;
    check string "the driver is there" fixture.driver (configured fixture).C.driver);
  with_fixture
    ~config:
      (Printf.sprintf "browser.automation.geckodriver = \"%s\"\n" "/opt/g" ^ string_with_a_fake_header)
    (fun fixture ->
       let message =
         message_of
           (A.plan ~find_geckodriver:never_asked (request ~browser:fixture.browser fixture))
       in
       check bool ("refused as dotted keys (got: " ^ message ^ ")") true
         (contains message "dotted keys"))

let test_a_change_after_the_plan_is_refused_and_not_overwritten () =
  with_fixture (fun fixture ->
    let plan = plan_ok ~find:(found fixture) (request fixture) in
    let changed = runtime_base ^ "# another editor wrote this\n" in
    write fixture.runtime changed;
    (match A.apply plan with
     | Error A.Configuration_changed -> ()
     | Ok () | Error _ -> fail "a file that changed after the plan is refused as changed");
    check string "the other writer's file is kept" changed (read fixture.runtime))

let test_a_named_driver_that_does_not_answer_is_written_with_a_note () =
  with_fixture (fun fixture ->
    let broken = Filename.concat fixture.root "broken driver" in
    write ~mode:0o755 broken "#!/bin/sh\necho broken >&2\nexit 3\n";
    let plan = plan_ok (request ~geckodriver:broken fixture) in
    (match A.notes plan with
     | [ note ] ->
       check bool "the note names it" true (contains note broken);
       check bool "and says it is not verified" true (contains note "not verified")
     | notes -> fail (Printf.sprintf "expected one note, got %d" (List.length notes)));
    apply_ok plan;
    check string "written as named" broken (configured fixture).C.driver;
    check (list string) "one that answers has no note" []
      (A.notes (plan_ok (request ~geckodriver:fixture.driver fixture))))

(* A value that is kept can name a program that is gone: a brew upgrade, a
   removed install. The command and the install wizard both found a geckodriver
   on PATH, and only the server would fail on the old path. The value is not
   changed, which is what keeping it means, and the note says it is not there. *)
let gone fixture = Filename.concat fixture.root "removed/geckodriver"

let kept_note label ~flag ~path notes =
  match notes with
  | [ note ] ->
    check bool (label ^ ": names the path") true (contains note path);
    check bool (label ^ ": says it is left as it is") true (contains note "left as it is");
    check bool (label ^ ": names the flag that changes it") true (contains note flag)
  | notes -> fail (Printf.sprintf "%s: expected one note, got %d" label (List.length notes))

let test_a_kept_driver_that_is_gone_is_said_and_not_changed () =
  with_fixture (fun fixture ->
    let config =
      runtime_base ^ Printf.sprintf "\n[browser.automation]\ngeckodriver = \"%s\"\n" (gone fixture)
    in
    write fixture.runtime config;
    let plan = plan_ok (request fixture) in
    check bool "left alone" true (A.change plan = A.Unchanged);
    kept_note "unchanged" ~flag:"--geckodriver" ~path:(gone fixture) (A.notes plan);
    (* Said again by a plan made again: the command re-plans after the BiDi
       table, and the note must not be lost there. *)
    (match A.replan plan with
     | Ok again -> kept_note "replanned" ~flag:"--geckodriver" ~path:(gone fixture) (A.notes again)
     | Error error -> fail (A.error_message error));
    apply_ok plan;
    check string "the file is as it was" config (read fixture.runtime))

let test_a_kept_browser_that_is_gone_is_said_beside_a_named_driver () =
  with_fixture (fun fixture ->
    let config =
      runtime_base
      ^ Printf.sprintf "\n[browser.automation]\ngeckodriver = \"%s\"\nbinary = \"%s\"\n"
          fixture.driver (Filename.concat fixture.root "removed/zen")
    in
    write fixture.runtime config;
    (* The driver is named and answers, so it is written and not noted; only
       the browser that is kept and gone is. *)
    let plan = plan_ok (request ~geckodriver:fixture.other_driver fixture) in
    check bool "the driver is replaced" true (A.change plan = A.Updated [ A.Geckodriver ]);
    kept_note "browser" ~flag:"--browser" ~path:(Filename.concat fixture.root "removed/zen")
      (A.notes plan))

let test_a_named_value_replaces_a_gone_one_and_is_not_noted () =
  with_fixture (fun fixture ->
    write fixture.runtime
      (runtime_base ^ Printf.sprintf "\n[browser.automation]\ngeckodriver = \"%s\"\n" (gone fixture));
    let plan = plan_ok (request ~geckodriver:fixture.driver fixture) in
    check (list string) "the gone value is being replaced, so it is not said" [] (A.notes plan);
    apply_ok plan;
    check string "replaced" fixture.driver (configured fixture).C.driver)

let test_a_kept_program_that_exists_and_does_not_answer_is_not_said () =
  (* It may need variables the probe runs without. Saying so each run would be
     noise, and the server starts it with its own environment. *)
  with_fixture (fun fixture ->
    let broken = Filename.concat fixture.root "broken driver" in
    write ~mode:0o755 broken "#!/bin/sh\nexit 3\n";
    write fixture.runtime
      (runtime_base ^ Printf.sprintf "\n[browser.automation]\ngeckodriver = \"%s\"\n" broken);
    check (list string) "no note" [] (A.notes (plan_ok (request fixture))))

(* The kept program is the operator's. It is looked for, not started: a
   launcher may open a window, and the question is only whether the file is
   there. A program that writes a marker when it runs shows a start. *)
let test_a_kept_program_is_looked_for_and_never_started () =
  with_fixture (fun fixture ->
    let marker = Filename.concat fixture.root "was-run" in
    let driver = Filename.concat fixture.root "kept driver" in
    program ~mode:0o755 driver (Printf.sprintf "geckodriver 0.0'; touch '%s" marker);
    let browser = Filename.concat fixture.root "kept browser" in
    program ~mode:0o755 browser (Printf.sprintf "Zen 0.0'; touch '%s" marker);
    write fixture.runtime
      (runtime_base
       ^ Printf.sprintf "\n[browser.automation]\ngeckodriver = \"%s\"\nbinary = \"%s\"\n"
           driver browser);
    let plan = plan_ok (request fixture) in
    check (list string) "both are there, so nothing is said" [] (A.notes plan);
    check bool "neither was started" false (Sys.file_exists marker))

let test_a_kept_file_that_cannot_run_is_said () =
  with_fixture (fun fixture ->
    let plain = Filename.concat fixture.root "not executable" in
    write ~mode:0o644 plain "#!/bin/sh\necho x\n";
    write fixture.runtime
      (runtime_base
       ^ Printf.sprintf "\n[browser.automation]\ngeckodriver = \"%s\"\n" plain);
    kept_note "no execute bit" ~flag:"--geckodriver" ~path:plain
      (A.notes (plan_ok (request fixture))))

(* The loader takes a value with a space after it, and the file lookup trims
   what it is given: the program that exists is not the one the server would
   be told to start. *)
let test_a_kept_value_with_a_space_after_it_is_not_the_file_that_is_there () =
  with_fixture (fun fixture ->
    write fixture.runtime
      (runtime_base
       ^ Printf.sprintf "\n[browser.automation]\ngeckodriver = \"%s \"\n" fixture.driver);
    check bool "the trimmed file is there" true (Sys.file_exists fixture.driver);
    kept_note "a space after it" ~flag:"--geckodriver" ~path:(fixture.driver ^ " ")
      (A.notes (plan_ok (request fixture))))

let () =
  run "browser lane automation setup"
    [ ( "a configuration that is not there"
      , [ test_case "found geckodriver, no browser" `Quick
            test_a_new_table_is_written_with_the_found_geckodriver_and_no_browser
        ; test_case "named values are written as named" `Quick test_named_values_are_written_as_named
        ; test_case "applying twice writes the same file" `Quick
            test_applying_twice_writes_the_same_file
        ] )
    ; ( "a configuration that is there"
      , [ test_case "keeps its values byte for byte" `Quick
            test_a_table_that_is_there_keeps_its_values_byte_for_byte
        ; test_case "a named browser is added to it" `Quick
            test_a_named_browser_is_added_to_the_table_that_is_there
        ; test_case "keys directly in [browser] are edited there" `Quick
            test_keys_that_are_directly_in_browser_are_edited_there
        ; test_case "other browser tables are not touched" `Quick
            test_other_browser_tables_are_not_touched
        ] )
    ; ( "refusals"
      , [ test_case "no geckodriver to name" `Quick test_no_geckodriver_to_name_is_refused
        ; test_case "a named program must run" `Quick test_a_named_program_must_be_a_file_that_can_run
        ; test_case "values the loader refuses" `Quick test_values_the_loader_refuses_are_not_written
        ; test_case "a missing runtime.toml" `Quick
            test_a_missing_runtime_toml_is_refused_and_not_created
        ; test_case "a file the server would not load" `Quick
            test_a_file_the_server_would_not_load_is_refused_untouched
        ; test_case "a table with no driver" `Quick test_a_table_with_no_driver_is_refused_untouched
        ; test_case "both spellings in the file" `Quick
            test_both_spellings_in_the_file_are_refused_by_the_loader
        ; test_case "a spelling the line editor cannot reach" `Quick
            test_a_spelling_the_line_editor_cannot_reach_is_refused_untouched
        ; test_case "a change after the plan" `Quick
            test_a_change_after_the_plan_is_refused_and_not_overwritten
        ; test_case "a plan made again keeps its decisions" `Quick
            test_a_plan_made_again_keeps_its_decisions_and_runs_nothing
        ; test_case "a plan made again is refused when the file does not take it" `Quick
            test_a_plan_made_again_is_refused_when_the_file_no_longer_takes_it
        ; test_case "a plan made again refuses a table written since" `Quick
            test_a_plan_made_again_refuses_a_table_written_since
        ; test_case "a named path with a space around it" `Quick
            test_a_named_path_with_a_space_around_it_is_refused
        ; test_case "a header inside a string" `Quick
            test_a_header_inside_a_string_is_not_a_declaration_and_does_not_hide_one
        ] )
    ; ( "what is not refused"
      , [ test_case "a driver that does not answer is noted" `Quick
            test_a_named_driver_that_does_not_answer_is_written_with_a_note
        ] )
    ; ( "a value that is kept and gone"
      , [ test_case "a kept driver that is gone is said, not changed" `Quick
            test_a_kept_driver_that_is_gone_is_said_and_not_changed
        ; test_case "a kept browser that is gone is said beside a named driver" `Quick
            test_a_kept_browser_that_is_gone_is_said_beside_a_named_driver
        ; test_case "a named value replaces a gone one" `Quick
            test_a_named_value_replaces_a_gone_one_and_is_not_noted
        ; test_case "one that exists and does not answer is not said" `Quick
            test_a_kept_program_that_exists_and_does_not_answer_is_not_said
        ; test_case "a kept program is looked for and never started" `Quick
            test_a_kept_program_is_looked_for_and_never_started
        ; test_case "a kept file that cannot run is said" `Quick
            test_a_kept_file_that_cannot_run_is_said
        ; test_case "a kept value with a space after it" `Quick
            test_a_kept_value_with_a_space_after_it_is_not_the_file_that_is_there
        ] )
    ]
