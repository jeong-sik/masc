(* The [browser.live.bidi] table that [masc browser-lane-setup --mode bidi]
   writes. What these tests fix: a table that is there is not overwritten, what
   is refused leaves the file as it was, and what is written is the table the
   server's loader reads back. Every case works in a scratch directory that
   holds its own runtime.toml and home. *)
open Alcotest

module B = Masc.Browser_lane_bidi_setup
module R = Masc.Browser_runtime_dependencies
module C = Browser_configuration

(* Every commit validates the whole file, so a write needs a runtime.toml that
   loads: [runtime].default is required, and a named provider keeps the
   capability gate satisfied. The same rows test_voice_setup uses. *)
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
  let dir = Filename.temp_file "bidi-setup" "" in
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

let exists path =
  match Unix.lstat path with
  | _ -> true
  | exception Unix.Unix_error _ -> false

type fixture =
  { root : string
  ; runtime : string
  ; home : string
  ; firefox : string
  ; operator_firefox : string
  ; operator_profile : string
  }

(* The table an operator wrote earlier, naming a Firefox and a profile that
   exist in the scratch directory. *)
let operator_table ~firefox ~profile =
  Printf.sprintf
    {|
# 2026-10-13: the profile the Keepers are logged in to.
[browser.live.bidi]
firefox = "%s"
profile = "%s"
port = 9300 # not the default
|}
    firefox profile

let with_fixture ?(with_table = false) ?config f =
  with_directory (fun root ->
    let home = Filename.concat root "home" in
    Unix.mkdir home 0o700;
    let firefox = Filename.concat root "fake firefox" in
    write ~mode:0o755 firefox "#!/bin/sh\necho 'Mozilla Firefox 0.0 (fixture)'\n";
    let operator_firefox = Filename.concat root "operator firefox" in
    write ~mode:0o755 operator_firefox "#!/bin/sh\necho 'Mozilla Firefox 0.1 (operator)'\n";
    let operator_profile = Filename.concat root "operator profile" in
    Unix.mkdir operator_profile 0o700;
    let config =
      match config with
      | Some config -> config
      | None ->
        if with_table
        then runtime_base ^ operator_table ~firefox:operator_firefox ~profile:operator_profile
        else runtime_base
    in
    let runtime = Filename.concat root "runtime.toml" in
    write runtime config;
    f { root; runtime; home; firefox; operator_firefox; operator_profile })

let request ?firefox ?profile ?port fixture =
  { B.runtime_config_path = fixture.runtime
  ; home = Some fixture.home
  ; firefox
  ; profile
  ; port
  }

let found fixture () =
  R.Started { command = fixture.firefox; path = fixture.firefox; output = "Mozilla Firefox 0.0" }

let never_asked () : R.check = fail "Firefox was looked for, and nothing needed one"

let plan_ok ?(find = never_asked) request =
  match B.plan ~find_firefox:find request with
  | Ok plan -> plan
  | Error error -> fail (B.error_message error)

let apply_ok plan =
  match B.apply plan with
  | Ok applied -> applied
  | Error error -> fail (B.error_message error)

let configured fixture =
  match C.of_file fixture.runtime with
  | Ok { C.live_bidi = Some table; _ } -> table
  | Ok _ -> fail "runtime.toml loads with no [browser.live.bidi]"
  | Error reason -> fail ("runtime.toml does not load: " ^ reason)

let contains = String_util.contains_substring

let message_of = function
  | Ok _ -> fail "expected a refusal"
  | Error error -> B.error_message error

(* A refusal the planner makes: the file is as it was and no directory was
   made. [expected] reads the error. *)
let refused ?(find = never_asked) label expected fixture request =
  let before = read fixture.runtime in
  (match B.plan ~find_firefox:find request with
   | Ok _ -> fail (label ^ ": expected a refusal")
   | Error error ->
     check bool (label ^ " (got: " ^ B.error_message error ^ ")") true (expected error));
  check string (label ^ ": runtime.toml is as it was") before (read fixture.runtime)

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
    (walk (String.split_on_char '\n' edited) (String.split_on_char '\n' original))

let has_key text key =
  List.exists
    (fun line -> String.starts_with ~prefix:(key ^ " ") (String.trim line))
    (String.split_on_char '\n' text)

let values (table : C.live_bidi) = table.firefox, table.profile, table.port

(* --- a table that is not there ------------------------------------------- *)

let test_a_table_is_written_with_the_found_firefox_and_the_default_profile () =
  with_fixture (fun fixture ->
    let plan = plan_ok ~find:(found fixture) (request fixture) in
    let profile = Filename.concat fixture.home "masc-keeper-firefox-profile" in
    check string "planning writes nothing" runtime_base (read fixture.runtime);
    check bool "planning makes no profile" false (exists profile);
    check bool "the table is new" true (B.change plan = B.Created);
    let applied = apply_ok plan in
    check bool "the profile was made" true applied.B.profile_created;
    check int "the profile is private: it keeps cookies" 0o700 (Unix.stat profile).Unix.st_perm;
    let edited = read fixture.runtime in
    lines_kept "the notes and tables" runtime_base edited;
    check bool "no port is written for the default" false (has_key edited "port");
    check (triple string string int) "what the loader reads"
      (fixture.firefox, profile, C.default_live_bidi_port)
      (values (configured fixture)))

let test_named_values_are_written_and_a_port_only_when_named () =
  with_fixture (fun fixture ->
    let profile = Filename.concat fixture.root "chosen profile" in
    let plan = plan_ok (request ~firefox:fixture.firefox ~profile ~port:9333 fixture) in
    ignore (apply_ok plan);
    check bool "the port is written" true (has_key (read fixture.runtime) "port");
    check (triple string string int) "what the loader reads" (fixture.firefox, profile, 9333)
      (values (configured fixture));
    check bool "the named profile was made" true (Sys.is_directory profile))

let test_applying_twice_writes_the_same_file () =
  with_fixture (fun fixture ->
    ignore (apply_ok (plan_ok ~find:(found fixture) (request fixture)));
    let once = read fixture.runtime in
    let second = plan_ok (request fixture) in
    check bool "the table is there the second time" true (B.change second = B.Unchanged);
    ignore (apply_ok second);
    check string "the file is the same" once (read fixture.runtime))

(* --- a table that is there ------------------------------------------------ *)

let test_a_table_that_is_there_keeps_its_values () =
  with_fixture ~with_table:true (fun fixture ->
    let before = read fixture.runtime in
    (* No Firefox is asked for: the table names its own. *)
    let plan = plan_ok (request fixture) in
    check bool "nothing was named" true (B.change plan = B.Unchanged);
    check (triple string string int) "the plan holds what the file holds"
      (fixture.operator_firefox, fixture.operator_profile, 9300)
      (values (B.table plan));
    let applied = apply_ok plan in
    check bool "its profile was there" false applied.B.profile_created;
    check string "the file is byte for byte as it was" before (read fixture.runtime))

let test_a_named_key_changes_that_key_and_no_other () =
  with_fixture ~with_table:true (fun fixture ->
    let before = read fixture.runtime in
    let plan = plan_ok (request ~port:9444 fixture) in
    check bool "only the port is changed" true (B.change plan = B.Updated [ B.Port ]);
    ignore (apply_ok plan);
    (* Toml_line_editor keeps a trailing comment only for a boolean, so the
       line that is rewritten loses the one it had. Every other line stays. *)
    let changed line = if has_key line "port" then "port = 9444" else line in
    let expected = String.concat "\n" (List.map changed (String.split_on_char '\n' before)) in
    check string "one line differs" expected (read fixture.runtime);
    check (triple string string int) "the others are as they were"
      (fixture.operator_firefox, fixture.operator_profile, 9444)
      (values (configured fixture)))

let test_naming_the_value_it_holds_changes_nothing () =
  with_fixture ~with_table:true (fun fixture ->
    let before = read fixture.runtime in
    let plan =
      plan_ok (request ~firefox:fixture.operator_firefox ~profile:fixture.operator_profile
                 ~port:9300 fixture)
    in
    check bool "nothing differs" true (B.change plan = B.Unchanged);
    ignore (apply_ok plan);
    check string "the file is as it was" before (read fixture.runtime))

let test_a_profile_the_table_names_is_made_when_missing () =
  with_fixture ~with_table:true (fun fixture ->
    Unix.rmdir fixture.operator_profile;
    let before = read fixture.runtime in
    let applied = apply_ok (plan_ok (request fixture)) in
    check bool "the table's profile was made" true applied.B.profile_created;
    check bool "it exists" true (Sys.is_directory fixture.operator_profile);
    check string "the table was not rewritten" before (read fixture.runtime))

(* --- what is refused leaves the file as it was --------------------------- *)

let test_no_firefox_to_name_is_refused () =
  with_fixture (fun fixture ->
    refused "nothing found"
      (function B.Firefox_not_found -> true | _ -> false)
      fixture
      (request fixture)
      ~find:(fun () -> R.Missing "firefox");
    refused "a Firefox that does not answer"
      (function B.Firefox_does_not_answer { path; _ } -> String.equal path "/opt/f" | _ -> false)
      fixture
      (request fixture)
      ~find:(fun () ->
        R.Failed { command = "/opt/f"; path = "/opt/f"; status = Unix.WEXITED 3; detail = "broken" });
    check bool "no profile was made" false
      (exists (Filename.concat fixture.home "masc-keeper-firefox-profile")))

let test_a_named_firefox_must_be_a_file_that_can_run () =
  with_fixture (fun fixture ->
    let absent = Filename.concat fixture.root "absent firefox" in
    refused "absent"
      (function B.Firefox_not_executable path -> String.equal path absent | _ -> false)
      fixture
      (request ~firefox:absent fixture);
    let plain = Filename.concat fixture.root "plain file" in
    write plain "not a program";
    refused "not executable"
      (function B.Firefox_not_executable path -> String.equal path plain | _ -> false)
      fixture
      (request ~firefox:plain fixture))

let test_values_the_loader_refuses_are_not_written () =
  with_fixture (fun fixture ->
    List.iter
      (fun (label, request, sentence) ->
         let before = read fixture.runtime in
         let message = message_of (B.plan ~find_firefox:never_asked request) in
         check bool (label ^ ": the loader's sentence (got: " ^ message ^ ")") true
           (contains message sentence);
         check string (label ^ ": runtime.toml is as it was") before (read fixture.runtime))
      [ "a Firefox that is not a path", request ~firefox:"firefox" ~profile:fixture.root fixture
        , "must be a non-empty absolute path"
      ; "a profile with a tilde", request ~firefox:fixture.firefox ~profile:"~/profile" fixture
        , "must be a non-empty absolute path"
      ; "port zero", request ~firefox:fixture.firefox ~profile:fixture.root ~port:0 fixture
        , "must be an integer from 1 to 65535"
      ; "port too large", request ~firefox:fixture.firefox ~profile:fixture.root ~port:65536 fixture
        , "must be an integer from 1 to 65535"
      ])

let test_a_profile_that_is_a_file_is_refused () =
  with_fixture (fun fixture ->
    let profile = Filename.concat fixture.root "a file" in
    write profile "not a directory";
    refused "a file"
      (function B.Profile_not_a_directory path -> String.equal path profile | _ -> false)
      fixture
      (request ~firefox:fixture.firefox ~profile fixture))

let test_the_default_profile_needs_a_home () =
  with_fixture (fun fixture ->
    refused "no home"
      (function B.Home_unknown -> true | _ -> false)
      fixture
      { (request fixture) with B.home = None }
      ~find:(found fixture);
    refused "an empty home"
      (function B.Home_unknown -> true | _ -> false)
      fixture
      { (request fixture) with B.home = Some "" }
      ~find:(found fixture);
    ignore
      (plan_ok { (request ~profile:fixture.root fixture) with B.home = None }
         ~find:(found fixture)))

let test_a_missing_runtime_toml_is_refused_and_not_created () =
  with_fixture (fun fixture ->
    Sys.remove fixture.runtime;
    (match B.plan ~find_firefox:never_asked (request fixture) with
     | Error (B.Configuration_missing path) -> check string "the path it names" fixture.runtime path
     | Ok _ | Error _ -> fail "a missing runtime.toml is refused as missing");
    check bool "it was not created" false (exists fixture.runtime))

let test_a_configuration_that_does_not_load_is_refused_untouched () =
  List.iter
    (fun (label, config, sentence) ->
       with_fixture ~config (fun fixture ->
         let message = message_of (B.plan ~find_firefox:(found fixture) (request fixture)) in
         check bool (label ^ " (got: " ^ message ^ ")") true (contains message sentence);
         check string (label ^ ": untouched") config (read fixture.runtime)))
    [ "a table with only a port"
    , runtime_base ^ "\n[browser.live.bidi]\nport = 9222\n"
    , "firefox is required"
    ; "a key the loader does not know", runtime_base ^ "\n[browser]\nsurprise = 1\n", "surprise"
    ; "a file the server would not load"
    , "[runtime]\nunknown_default = true\n"
    , "runtime"
    ]

let test_a_table_written_inline_is_not_edited_into_a_second_table () =
  let inline root_firefox root_profile =
    Printf.sprintf
      "\n[browser.live]\nbidi = { firefox = \"%s\", profile = \"%s\" }\n"
      root_firefox root_profile
  in
  with_directory (fun probe ->
    let config = runtime_base ^ inline "/opt/f" probe in
    with_fixture ~config (fun fixture ->
      refused "an inline table"
        (function B.Table_refused _ -> true | _ -> false)
        fixture
        (request ~port:9555 fixture);
      ignore (plan_ok (request fixture))))

let test_the_profile_is_made_before_the_table_and_a_failure_leaves_no_table () =
  with_fixture (fun fixture ->
    let locked = Filename.concat fixture.root "locked" in
    Unix.mkdir locked 0o500;
    let profile = Filename.concat locked "profile" in
    let plan = plan_ok (request ~firefox:fixture.firefox ~profile fixture) in
    let before = read fixture.runtime in
    (match B.apply plan with
     | Error (B.Profile_not_created { path; _ }) -> check string "the path it names" profile path
     | Ok _ | Error _ -> fail "a profile that cannot be made is refused as that");
    check string "no table was written" before (read fixture.runtime))

let test_a_change_after_the_plan_is_refused_and_not_overwritten () =
  with_fixture (fun fixture ->
    let plan = plan_ok ~find:(found fixture) (request fixture) in
    let changed = runtime_base ^ "# another editor wrote this\n" in
    write fixture.runtime changed;
    (match B.apply plan with
     | Error B.Configuration_changed -> ()
     | Ok _ | Error _ -> fail "a file that changed after the plan is refused as changed");
    check string "the other writer's file is kept" changed (read fixture.runtime))

(* --- the port ------------------------------------------------------------ *)

let listening_port f =
  let socket = Unix.socket ~cloexec:true Unix.PF_INET Unix.SOCK_STREAM 0 in
  Unix.bind socket (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
  Unix.listen socket 4;
  let port =
    match Unix.getsockname socket with
    | Unix.ADDR_INET (_, port) -> port
    | Unix.ADDR_UNIX _ -> fail "a TCP socket has a port"
  in
  Fun.protect ~finally:(fun () -> Unix.close socket) (fun () -> f port)

let free_port () =
  let socket = Unix.socket ~cloexec:true Unix.PF_INET Unix.SOCK_STREAM 0 in
  Unix.bind socket (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
  let port =
    match Unix.getsockname socket with
    | Unix.ADDR_INET (_, port) -> port
    | Unix.ADDR_UNIX _ -> fail "a TCP socket has a port"
  in
  Unix.close socket;
  port

let test_a_port_that_answers_is_reported () =
  with_fixture (fun fixture ->
    let plan_on port =
      plan_ok (request ~firefox:fixture.firefox ~profile:fixture.root ~port fixture)
    in
    listening_port (fun port ->
      check bool "something listens" true (B.port_answers (plan_on port)));
    check bool "nothing listens" false (B.port_answers (plan_on (free_port ()))))

let () =
  run "browser lane bidi setup"
    [ ( "a table that is not there"
      , [ test_case "found Firefox and the default profile" `Quick
            test_a_table_is_written_with_the_found_firefox_and_the_default_profile
        ; test_case "named values, and a port only when named" `Quick
            test_named_values_are_written_and_a_port_only_when_named
        ; test_case "applying twice writes the same file" `Quick
            test_applying_twice_writes_the_same_file
        ] )
    ; ( "a table that is there"
      , [ test_case "keeps its values" `Quick test_a_table_that_is_there_keeps_its_values
        ; test_case "a named key changes that key and no other" `Quick
            test_a_named_key_changes_that_key_and_no_other
        ; test_case "naming the value it holds changes nothing" `Quick
            test_naming_the_value_it_holds_changes_nothing
        ; test_case "its profile is made when missing" `Quick
            test_a_profile_the_table_names_is_made_when_missing
        ] )
    ; ( "refusals"
      , [ test_case "no Firefox to name" `Quick test_no_firefox_to_name_is_refused
        ; test_case "a named Firefox must run" `Quick test_a_named_firefox_must_be_a_file_that_can_run
        ; test_case "values the loader refuses" `Quick test_values_the_loader_refuses_are_not_written
        ; test_case "a profile that is a file" `Quick test_a_profile_that_is_a_file_is_refused
        ; test_case "the default profile needs a home" `Quick test_the_default_profile_needs_a_home
        ; test_case "a missing runtime.toml" `Quick
            test_a_missing_runtime_toml_is_refused_and_not_created
        ; test_case "a configuration that does not load" `Quick
            test_a_configuration_that_does_not_load_is_refused_untouched
        ; test_case "an inline table is not edited into a second one" `Quick
            test_a_table_written_inline_is_not_edited_into_a_second_table
        ; test_case "a profile that cannot be made leaves no table" `Quick
            test_the_profile_is_made_before_the_table_and_a_failure_leaves_no_table
        ; test_case "a change after the plan" `Quick
            test_a_change_after_the_plan_is_refused_and_not_overwritten
        ] )
    ; "the port", [ test_case "an answering port is reported" `Quick test_a_port_that_answers_is_reported ]
    ]
