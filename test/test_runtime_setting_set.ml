(* Runtime_setting_set writes keys of a live runtime.toml that the settings
   registry names. What these tests fix is that a key or value the registry does
   not accept never reaches the file, that an edit leaves what it was not asked
   about as it was, and that what it writes is what the loader reads. *)
open Alcotest

module R = Keeper_runtime_setting_registry
module S = Runtime_setting_set

(* Every commit validates the whole file, not the keys being edited, so a write
   still needs a runtime.toml that loads. Same rows as test_web_search_setup: a
   named [providers] entry keeps the capability gate satisfied. *)
let runtime_base =
  {|[providers."deepseek"]
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
default = "deepseek.chat"
|}

(* A file with an operator's note above a measured setting, and a table that is
   not the one being written. *)
let with_tables =
  runtime_base
  ^ {|
# 2026-10-01: measured on the fleet, do not lower.
[heartbeat]
interval_sec = 30
snapshot_sec = 60

[turn]
# unrelated to heartbeat
|}

let rec cleanup target =
  match Unix.lstat target with
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Array.iter (fun name -> cleanup (Filename.concat target name)) (Sys.readdir target);
    Unix.rmdir target
  | _ -> Unix.unlink target
;;

let fresh_directory () =
  let directory = Filename.temp_file "runtime-setting-set" "" in
  Unix.unlink directory;
  Unix.mkdir directory 0o700;
  directory
;;

let write path contents =
  Out_channel.with_open_bin path (fun out -> output_string out contents)
;;

let read path = In_channel.with_open_bin path In_channel.input_all

let with_config contents f =
  let directory = fresh_directory () in
  let path = Filename.concat directory "runtime.toml" in
  write path contents;
  Fun.protect ~finally:(fun () -> cleanup directory) (fun () -> f path)
;;

(* The layout the loader reads for a base path: <base>/.masc/config/runtime.toml. *)
let with_workspace contents f =
  let base_path = fresh_directory () in
  let masc_directory = Filename.concat base_path ".masc" in
  let config_directory = Filename.concat masc_directory "config" in
  Unix.mkdir masc_directory 0o755;
  Unix.mkdir config_directory 0o755;
  let path = Filename.concat config_directory Config_dir_resolver.runtime_toml_filename in
  write path contents;
  Masc_test_deps.with_process_env "MASC_CONFIG_DIR" None (fun () ->
    Fun.protect
      ~finally:(fun () -> cleanup base_path)
      (fun () -> f ~base_path ~path))
;;

let parsed ~key ~value =
  match S.parse ~key ~value with
  | Ok change -> change
  | Error error -> fail (S.error_message error)
;;

let applied path changes =
  match S.apply ~runtime_config_path:path changes with
  | Ok changed -> changed
  | Error error -> fail (S.error_message error)
;;

let doc_of path =
  match Keeper_toml_loader.parse_toml (read path) with
  | Ok doc -> doc
  | Error message -> fail message
;;

let contains haystack needle =
  let rec found index =
    index + String.length needle <= String.length haystack
    && (String.equal (String.sub haystack index (String.length needle)) needle
        || found (index + 1))
  in
  found 0
;;

let lines_starting_with_hash contents =
  String.split_on_char '\n' contents
  |> List.filter (fun line ->
    let trimmed = String.trim line in
    String.length trimmed > 0 && Char.equal trimmed.[0] '#')
;;

(* ---- parse ---- *)

let toml_keys =
  List.filter_map R.toml_key_opt R.toml_settings
;;

let test_every_registry_key_is_a_table_and_a_key () =
  check bool "the registry has keys" true (toml_keys <> []);
  List.iter
    (fun key ->
       check int
         (key ^ " is <table>.<key>")
         2
         (List.length (String.split_on_char '.' key)))
    toml_keys
;;

let sample_of_kind = function
  | R.Boolean -> "true"
  | R.Integer -> "1"
  | R.Float -> "1.5"
  | R.String -> "text"
;;

let test_every_registry_row_reads_a_value_of_its_kind () =
  List.iter
    (fun (row : R.setting) ->
       match R.toml_key_opt row with
       | None -> fail (row.env_name ^ " is in toml_settings without a key")
       | Some key ->
         (match S.parse ~key ~value:(sample_of_kind row.value_kind) with
          | Ok change -> check string (key ^ " parses to itself") key (S.toml_key change)
          | Error error -> fail (key ^ ": " ^ S.error_message error)))
    R.toml_settings
;;

let test_an_unknown_key_is_refused () =
  List.iter
    (fun key ->
       match S.parse ~key ~value:"1" with
       | Error (S.Unknown_key refused) -> check string "the key is named" key refused
       | Ok _ -> fail (key ^ " was accepted")
       | Error error -> fail (S.error_message error))
    [ "autonomous.bogus"; "bogus.enabled"; "autonomous"; "MASC_KEEPER_AUTONOMOUS_ENABLED" ]
;;

let test_a_value_of_the_wrong_kind_is_refused () =
  List.iter
    (fun (key, value) ->
       match S.parse ~key ~value with
       | Error (S.Invalid_value { toml_key; _ }) -> check string "the key is named" key toml_key
       | Ok _ -> fail (Printf.sprintf "%s=%S was accepted" key value)
       | Error error -> fail (S.error_message error))
    [ "autonomous.enabled", "maybe"
    ; "autonomous.enabled", "True"
    ; "autonomous.enabled", "1"
    ; "autonomous.enabled", ""
    ; "heartbeat.interval_sec", "1.5"
    ; "heartbeat.interval_sec", "0x10"
    ; "heartbeat.interval_sec", "1_000"
    ; "heartbeat.interval_sec", "+5"
    ; "heartbeat.interval_sec", ""
    ; "web_search.cache_ttl_sec", "nan"
    ; "web_search.cache_ttl_sec", "1e999"
    ; "web_search.cache_ttl_sec", "0x1p3"
    ]
;;

let test_text_may_be_empty () =
  (* A blank [sandbox] microvm_dns is a real value: the guest copies the host's
     first resolver. *)
  match S.parse ~key:"sandbox.microvm_dns" ~value:"" with
  | Ok _ -> ()
  | Error error -> fail (S.error_message error)
;;

(* ---- writes ---- *)

let test_a_new_table_is_appended_and_nothing_else_moves () =
  with_config runtime_base (fun path ->
    let changed =
      applied
        path
        [ parsed ~key:"autonomous.enabled" ~value:"false"
        ; parsed ~key:"otel.enabled" ~value:"true"
        ; parsed ~key:"heartbeat.interval_sec" ~value:"30"
        ; parsed ~key:"web_search.cache_ttl_sec" ~value:"2.5"
        ; parsed ~key:"web_search.searxng_url" ~value:"http://localhost:8888"
        ]
    in
    check bool "the file changed" true changed;
    check bool
      "every byte that was there is still there, in place"
      true
      (String.starts_with ~prefix:runtime_base (read path));
    let doc = doc_of path in
    check (option bool) "autonomous.enabled" (Some false)
      (Keeper_toml_loader.toml_bool_opt doc "autonomous.enabled");
    check (option bool) "otel.enabled" (Some true)
      (Keeper_toml_loader.toml_bool_opt doc "otel.enabled");
    check (option int) "heartbeat.interval_sec" (Some 30)
      (Keeper_toml_loader.toml_int_opt doc "heartbeat.interval_sec");
    check (option (float 0.0001)) "web_search.cache_ttl_sec" (Some 2.5)
      (Keeper_toml_loader.toml_float_opt doc "web_search.cache_ttl_sec");
    check (option string) "web_search.searxng_url" (Some "http://localhost:8888")
      (Keeper_toml_loader.toml_string_opt doc "web_search.searxng_url"))
;;

let test_an_existing_key_is_replaced_and_comments_stay () =
  with_config with_tables (fun path ->
    let before = read path in
    ignore (applied path [ parsed ~key:"heartbeat.interval_sec" ~value:"45" ]);
    let after = read path in
    let doc = doc_of path in
    check (option int) "the key has the new value" (Some 45)
      (Keeper_toml_loader.toml_int_opt doc "heartbeat.interval_sec");
    check (option int) "its neighbour is as it was" (Some 60)
      (Keeper_toml_loader.toml_int_opt doc "heartbeat.snapshot_sec");
    check (list string) "every comment is still there"
      (lines_starting_with_hash before)
      (lines_starting_with_hash after);
    check int "the file has one [heartbeat] table" 1
      (String.split_on_char '\n' after
       |> List.filter (fun line -> String.equal (String.trim line) "[heartbeat]")
       |> List.length))
;;

let test_a_second_run_changes_nothing () =
  with_config runtime_base (fun path ->
    let changes () = [ parsed ~key:"autonomous.enabled" ~value:"false" ] in
    check bool "the first run writes" true (applied path (changes ()));
    let first = read path in
    check bool "the second run reports no change" false (applied path (changes ()));
    check string "and leaves the bytes as the first wrote them" first (read path))
;;

let test_existing_values_keep_their_trailing_comments () =
  let contents =
    runtime_base
    ^ {|
[heartbeat]
interval_sec = 30 # keep the measured value
[web_search]
cache_ttl_sec = 2.5 # keep this duration
searxng_url = "http://localhost:8888" # keep this address
[otel]
enabled = false # keep this choice
|}
  in
  with_config contents (fun path ->
    let same_values =
      [ parsed ~key:"heartbeat.interval_sec" ~value:"30"
      ; parsed ~key:"web_search.cache_ttl_sec" ~value:"2.5"
      ; parsed ~key:"web_search.searxng_url" ~value:"http://localhost:8888"
      ; parsed ~key:"otel.enabled" ~value:"false"
      ]
    in
    check bool "existing values report no change" false (applied path same_values);
    check string "their original bytes survive" contents (read path);
    check bool "a separate change is still applied" true
      (applied path (parsed ~key:"autonomous.enabled" ~value:"true" :: same_values));
    let updated = read path in
    check bool "the unchanged lines still have their notes" true
      (contains updated "interval_sec = 30 # keep the measured value\n"
       && contains updated "cache_ttl_sec = 2.5 # keep this duration\n"
       && contains updated "searxng_url = \"http://localhost:8888\" # keep this address\n"
       && contains updated "enabled = false # keep this choice\n");
    check (option bool) "the separate change reads back" (Some true)
      (Keeper_toml_loader.toml_bool_opt (doc_of path) "autonomous.enabled"))
;;

let test_an_existing_integer_spelling_of_a_float_is_unchanged () =
  let contents = runtime_base ^ "\n[web_search]\ncache_ttl_sec = 2 # duration\n" in
  with_config contents (fun path ->
    check bool "the loader already reads the requested float" false
      (applied path [ parsed ~key:"web_search.cache_ttl_sec" ~value:"2.0" ]);
    check string "the spelling and comment stay" contents (read path))
;;

let test_an_existing_invalid_value_is_still_refused () =
  let contents = runtime_base ^ "\n[heartbeat]\ninterval_sec = 0 # invalid\n" in
  with_config contents (fun path ->
    (match
       S.apply ~runtime_config_path:path
         [ parsed ~key:"heartbeat.interval_sec" ~value:"0"
         ; parsed ~key:"autonomous.enabled" ~value:"true"
         ]
     with
     | Error (S.Not_valid _) -> ()
     | Ok _ -> fail "the unchanged but invalid value was accepted"
     | Error error -> fail (S.error_message error));
    check string "neither the invalid nor the other change was written" contents (read path))
;;

let test_changes_are_all_or_none () =
  with_config with_tables (fun path ->
    let before = read path in
    (* heartbeat.interval_sec is at least 1, so the second change is out of
       range, and the first must not land without it. *)
    (match
       S.apply
         ~runtime_config_path:path
         [ parsed ~key:"autonomous.enabled" ~value:"false"
         ; parsed ~key:"heartbeat.interval_sec" ~value:"0"
         ]
     with
     | Error (S.Not_valid detail) ->
       check bool "the message names the key" true
         (contains detail "heartbeat.interval_sec")
     | Ok _ -> fail "an out-of-range value was written"
     | Error error -> fail (S.error_message error));
    check string "the file is untouched" before (read path))
;;

let test_a_key_given_twice_is_refused () =
  with_config runtime_base (fun path ->
    match
      S.apply
        ~runtime_config_path:path
        [ parsed ~key:"autonomous.enabled" ~value:"true"
        ; parsed ~key:"autonomous.enabled" ~value:"false"
        ]
    with
    | Error (S.Conflicting_changes key) ->
      check string "the key is named" "autonomous.enabled" key;
      check string "the file is untouched" runtime_base (read path)
    | Ok _ -> fail "a key given twice was written"
    | Error error -> fail (S.error_message error))
;;

(* [turn] spelled as an inline table: a line editor opens a second [turn] table
   beside it, which the file refuses to load. That has to come back as a refusal,
   not as a half-written file. *)
let test_an_inline_table_is_refused_not_half_written () =
  (* At the root, before any header: after one it would be a key of that table. *)
  let inline = "turn = { batch_limit = 3 }\n" ^ runtime_base in
  with_config inline (fun path ->
    match
      S.apply ~runtime_config_path:path [ parsed ~key:"turn.batch_limit" ~value:"5" ]
    with
    | Error (S.Table_not_reachable table) ->
      check string "the table is named" "turn" table;
      check string "the file is untouched" inline (read path)
    | Ok _ -> fail "an inline table must not be written beside"
    | Error error -> fail (S.error_message error))
;;

let test_dotted_keys_at_the_root_are_refused_not_written_beside () =
  let dotted = "turn.batch_limit = 3\n" ^ runtime_base in
  with_config dotted (fun path ->
    match
      S.apply ~runtime_config_path:path [ parsed ~key:"turn.batch_limit" ~value:"5" ]
    with
    | Error (S.Table_not_reachable table) ->
      check string "the table is named" "turn" table;
      check string "the file is untouched" dotted (read path)
    | Ok _ -> fail "a header must not be opened beside dotted keys"
    | Error error -> fail (S.error_message error))
;;

let test_no_changes_write_nothing () =
  with_config runtime_base (fun path ->
    check bool "nothing to apply" false (applied path []);
    check string "the file is untouched" runtime_base (read path))
;;

(* ---- the loader reads what was written ---- *)

(* The point of the command: a script writes a key before the first start, and
   the server's loader applies it. [metrics.max_bytes] and
   [autonomous.wake_prompt] are read from the file alone, so the shell running
   this suite cannot change the outcome. *)
let test_what_is_written_is_what_the_loader_applies () =
  Config_boot_overrides.reset_for_tests ();
  with_workspace runtime_base (fun ~base_path ~path ->
    ignore
      (applied
         path
         [ parsed ~key:"metrics.max_bytes" ~value:"4096"
         ; parsed ~key:"autonomous.wake_prompt" ~value:"what changed?"
         ]);
    (match Keeper_runtime_config.load_and_apply ~base_path with
     | Ok count -> check int "both keys are applied" 2 count
     | Error failure -> fail (Keeper_runtime_config.load_failure_to_string failure));
    check (option string) "metrics.max_bytes reached the store" (Some "4096")
      (Config_boot_overrides.get_opt "MASC_KEEPER_METRICS_MAX_BYTES");
    check (option string) "autonomous.wake_prompt reached the store"
      (Some "what changed?")
      (Config_boot_overrides.get_opt "MASC_KEEPER_AUTONOMOUS_WAKE_PROMPT"));
  Config_boot_overrides.reset_for_tests ()
;;

let test_float_settings_reach_their_boot_consumers_exactly () =
  Config_boot_overrides.reset_for_tests ();
  Fun.protect ~finally:Config_boot_overrides.reset_for_tests (fun () ->
    with_workspace runtime_base (fun ~base_path ~path ->
      let values =
        [ "heartbeat.sleep_chunk_sec", "0.1234567"
        ; "turn.temperature", "0.1234567"
        ; "turn.stream_idle_timeout_sec", "40.1234567"
        ; "turn.first_event_timeout_sec", "100.1234567"
        ; "turn.provider_call_deadline_sec", "120.1234567"
        ; "supervisor.sweep_sec", "10.1234567"
        ; "web_search.cache_ttl_sec", "123456789.0"
        ]
      in
      let registered = R.toml_settings |> List.filter_map (fun row ->
        if row.R.value_kind = R.Float then R.toml_key_opt row else None) in
      check (list string) "every file-backed float has a fixture"
        (List.sort String.compare registered)
        (List.sort String.compare (List.map fst values));
      ignore (applied path (List.map (fun (key, value) -> parsed ~key ~value) values));
      (match Keeper_runtime_config.load_and_apply ~base_path with
       | Ok count -> check int "all seven floats are applied" 7 count
       | Error failure -> fail (Keeper_runtime_config.load_failure_to_string failure));
      let exact label expected actual =
        check bool (label ^ " reaches the runtime reader without rounding") true
          (Float.equal expected actual) in
      let exact_opt label expected actual =
        check bool (label ^ " reaches the runtime reader without rounding") true
          (Option.equal Float.equal (Some expected) actual) in
      exact "sleep chunk" 0.1234567 (Env_config_keeper.KeeperKeepalive.sleep_chunk_sec ());
      exact "temperature" 0.1234567 (Env_config_keeper.KeeperTurn.temperature ());
      exact_opt "stream idle" 40.1234567 (Env_config_keeper.KeeperKeepalive.stream_idle_timeout_sec ());
      exact_opt "first event" 100.1234567 (Env_config_keeper.KeeperKeepalive.first_event_timeout_sec ());
      exact_opt "provider deadline" 120.1234567 (Env_config_keeper.KeeperKeepalive.provider_call_deadline_sec_override ());
      exact "supervisor sweep" 10.1234567 (Env_config_keeper.KeeperSupervisor.sweep_interval_sec ());
      exact "search cache TTL" 123456789.0 (Env_config_runtime.Tools.web_search_cache_ttl_sec ())))
;;

let () =
  run
    "Runtime_setting_set"
    [ ( "parse"
      , [ test_case "every registry key is a table and a key" `Quick
            test_every_registry_key_is_a_table_and_a_key
        ; test_case "every registry row reads a value of its kind" `Quick
            test_every_registry_row_reads_a_value_of_its_kind
        ; test_case "an unknown key is refused" `Quick test_an_unknown_key_is_refused
        ; test_case "a value of the wrong kind is refused" `Quick
            test_a_value_of_the_wrong_kind_is_refused
        ; test_case "text may be empty" `Quick test_text_may_be_empty
        ] )
    ; ( "write"
      , [ test_case "a new table is appended and nothing else moves" `Quick
            test_a_new_table_is_appended_and_nothing_else_moves
        ; test_case "an existing key is replaced and comments stay" `Quick
            test_an_existing_key_is_replaced_and_comments_stay
        ; test_case "a second run changes nothing" `Quick test_a_second_run_changes_nothing
        ; test_case "existing values keep their trailing comments" `Quick
            test_existing_values_keep_their_trailing_comments
        ; test_case "an integer spelling of a float stays unchanged" `Quick
            test_an_existing_integer_spelling_of_a_float_is_unchanged
        ; test_case "an existing invalid value is still refused" `Quick
            test_an_existing_invalid_value_is_still_refused
        ; test_case "changes are all or none" `Quick test_changes_are_all_or_none
        ; test_case "a key given twice is refused" `Quick test_a_key_given_twice_is_refused
        ; test_case "an inline table is refused, not half written" `Quick
            test_an_inline_table_is_refused_not_half_written
        ; test_case "dotted keys at the root are refused, not written beside" `Quick
            test_dotted_keys_at_the_root_are_refused_not_written_beside
        ; test_case "no changes write nothing" `Quick test_no_changes_write_nothing
        ] )
    ; ( "loader"
      , [ test_case "what is written is what the loader applies" `Quick
            test_what_is_written_is_what_the_loader_applies
        ; test_case "float settings reach the boot consumers exactly" `Quick
            test_float_settings_reach_their_boot_consumers_exactly
        ] )
    ]
;;
