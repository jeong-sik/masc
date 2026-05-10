(** Safe_ops Module Tests *)

open Alcotest

let test_int_of_string_safe_valid () =
  let open Safe_ops in
  check (option int) "parses valid int" (Some 42) (int_of_string_safe "42")

let test_int_of_string_safe_invalid () =
  let open Safe_ops in
  check (option int) "None on invalid" None (int_of_string_safe "abc")

let test_int_of_string_with_default () =
  let open Safe_ops in
  check int "default on invalid" 0 (int_of_string_with_default ~default:0 "abc")

let test_float_of_string_safe_valid () =
  let open Safe_ops in
  check (option (float 0.001)) "parses valid float" (Some 3.14) (float_of_string_safe "3.14")

let test_float_of_string_safe_invalid () =
  let open Safe_ops in
  check (option (float 0.001)) "None on invalid" None (float_of_string_safe "abc")

let test_parse_json_safe_valid () =
  let open Safe_ops in
  let result = parse_json_safe ~context:"test" {|{"foo": "bar"}|} in
  check bool "Ok on valid JSON" true (Result.is_ok result)

let test_parse_json_safe_invalid () =
  let open Safe_ops in
  let result = parse_json_safe ~context:"test" "not json" in
  check bool "Error on invalid JSON" true (Result.is_error result)

let test_parse_json_safe_repairs_invalid_utf8_inside_string () =
  let open Safe_ops in
  reset_persistence_utf8_repair_stats_for_tests ();
  let metric_before =
    Masc_mcp.Prometheus.metric_value_or_zero
      Masc_mcp.Prometheus.metric_persistence_utf8_repair
      ()
  in
  let replacement = "\xEF\xBF\xBD" in
  let result = parse_json_safe ~context:"utf8-fixture" "{\"msg\":\"ok\xffbad\"}" in
  match result with
  | Error msg -> fail msg
  | Ok json ->
    let msg = Yojson.Safe.Util.(json |> member "msg" |> to_string) in
    check string "invalid byte replaced" ("ok" ^ replacement ^ "bad") msg;
    let stats = persistence_utf8_repair_stats () in
    check int "one repaired read" 1 stats.repaired_reads;
    check int "one invalid byte" 1 stats.repaired_bytes;
    let metric_after =
      Masc_mcp.Prometheus.metric_value_or_zero
        Masc_mcp.Prometheus.metric_persistence_utf8_repair
        ()
    in
    check (float 0.0001) "UTF-8 repair counter +1"
      (metric_before +. 1.0)
      metric_after

let test_parse_json_safe_still_rejects_malformed_json_after_utf8_repair () =
  let open Safe_ops in
  reset_persistence_utf8_repair_stats_for_tests ();
  let result = parse_json_safe ~context:"utf8-malformed" ("{\xff:1}") in
  check bool "malformed json still rejected" true (Result.is_error result);
  let stats = persistence_utf8_repair_stats () in
  check int "repair was observed" 1 stats.repaired_reads

let latest_log_seq () =
  match Log.Ring.recent ~limit:1 () with
  | (entry : Log.Ring.entry) :: _ -> entry.seq
  | [] -> -1

let has_prefix ~prefix value =
  let prefix_len = String.length prefix in
  String.length value >= prefix_len
  && String.equal prefix (String.sub value 0 prefix_len)

let test_parse_json_safe_rate_limits_repeated_utf8_repair_logs () =
  let open Safe_ops in
  reset_persistence_utf8_repair_stats_for_tests ();
  let baseline = latest_log_seq () in
  ignore (parse_json_safe ~context:"utf8-repeat" "{\"msg\":\"a\xff\"}");
  ignore (parse_json_safe ~context:"utf8-repeat" "{\"msg\":\"b\xff\"}");
  let logs =
    Log.Ring.recent ~limit:20 ~module_filter:"Misc" ~since_seq:baseline ()
    |> List.filter (fun (entry : Log.Ring.entry) ->
           has_prefix ~prefix:"[json] persistence UTF-8 repaired path=utf8-repeat"
             entry.message)
  in
  let stats = persistence_utf8_repair_stats () in
  check int "both repairs counted" 2 stats.repaired_reads;
  check int "duplicate repair warning suppressed" 1 (List.length logs)

let test_sanitize_json_utf8_covers_safe_constructors () =
  let open Safe_ops in
  let replacement = "\xEF\xBF\xBD" in
  let sanitized =
    sanitize_json_utf8
      (`Assoc
        [
          ("bad\xffkey",
             `List
             [
               `String "bad\xfflist";
               `Float 1.25;
               `Assoc [ ("nested\xffkey", `String "bad\xffvalue") ];
             ]);
        ])
  in
  match sanitized with
  | `Assoc [ (key, `List [ `String list_value; `Float 1.25; `Assoc fields ]) ] ->
      check string "assoc key repaired" ("bad" ^ replacement ^ "key") key;
      check string "list string repaired" ("bad" ^ replacement ^ "list") list_value;
      let key, value =
        match fields with
        | [ field ] -> field
        | _ -> fail "expected one assoc field"
      in
      check string "nested key repaired" ("nested" ^ replacement ^ "key") key;
      check string "assoc value repaired" ("bad" ^ replacement ^ "value")
        (Yojson.Safe.Util.to_string value)
  | _ -> fail "unexpected sanitized JSON shape"

let test_sanitize_json_utf8_with_raw_preserves_original () =
  let open Safe_ops in
  let raw = `Assoc [ ("bad\xffkey", `String "bad\xffvalue") ] in
  let replacement = "\xEF\xBF\xBD" in
  let result = sanitize_json_utf8_with_raw raw in
  check bool "changed when utf8 repair needed" true result.changed;
  check bool "raw points at original payload" true (result.raw == raw);
  (match result.raw with
   | `Assoc [ (key, `String value) ] ->
       check string "raw key unchanged" "bad\xffkey" key;
       check string "raw value unchanged" "bad\xffvalue" value
   | _ -> fail "unexpected raw JSON shape");
  match result.sanitized with
  | `Assoc [ (key, `String value) ] ->
      check string "sanitized key repaired" ("bad" ^ replacement ^ "key") key;
      check string "sanitized value repaired" ("bad" ^ replacement ^ "value") value
  | _ -> fail "unexpected sanitized JSON shape"

let test_sanitize_json_utf8_with_raw_marks_clean_payload_unchanged () =
  let open Safe_ops in
  let raw = `Assoc [ ("ok", `String "value") ] in
  let result = sanitize_json_utf8_with_raw raw in
  check bool "clean payload not changed" false result.changed;
  check bool "raw points at original payload" true (result.raw == raw);
  check bool "sanitized reuses original payload" true (result.sanitized == raw)

let test_utf8_repair_log_rate_limit_table_is_bounded () =
  let open Safe_ops in
  reset_persistence_utf8_repair_stats_for_tests ();
  let limit = persistence_utf8_repair_log_entry_limit_for_tests () in
  for i = 1 to limit + 32 do
    ignore
      (repair_utf8_text ~surface:"bounded"
         ~path:(Printf.sprintf "path-%04d" i)
         "\xff")
  done;
  let stats = persistence_utf8_repair_stats () in
  check int "all repairs counted" (limit + 32) stats.repaired_reads;
  check bool "rate-limit keys stay bounded" true
    (persistence_utf8_repair_log_key_count_for_tests () <= limit)

let test_read_file_safe_not_found () =
  let open Safe_ops in
  let result = read_file_safe "/nonexistent/path/file.txt" in
  check bool "Error on missing file" true (Result.is_error result)

(* JSON extraction tests *)
let sample_json = Yojson.Safe.from_string {|{"name": "test", "count": 42, "rate": 3.14, "active": true}|}

let test_json_string () =
  let open Safe_ops in
  check string "extracts string" "test" (json_string "name" sample_json)

let test_json_string_missing () =
  let open Safe_ops in
  check string "default on missing" "default" (json_string ~default:"default" "missing" sample_json)

let test_json_int () =
  let open Safe_ops in
  check int "extracts int" 42 (json_int "count" sample_json)

let test_json_float () =
  let open Safe_ops in
  check (float 0.001) "extracts float" 3.14 (json_float "rate" sample_json)

let test_json_bool () =
  let open Safe_ops in
  check bool "extracts bool" true (json_bool "active" sample_json)

let test_json_string_opt_present () =
  let open Safe_ops in
  check (option string) "Some on present" (Some "test") (json_string_opt "name" sample_json)

let test_json_string_opt_missing () =
  let open Safe_ops in
  check (option string) "None on missing" None (json_string_opt "missing" sample_json)

(* ================================================================
   Additional coverage tests for uncovered functions
   ================================================================ *)

(* try_with_log *)
let test_try_with_log_success () =
  let open Safe_ops in
  let result = try_with_log "test" (fun () -> 42) in
  check (option int) "Some on success" (Some 42) result

let test_try_with_log_failure () =
  let open Safe_ops in
  let result = try_with_log "test" (fun () -> failwith "boom") in
  check (option int) "None on failure" None result

(* try_with_default *)
let test_try_with_default_success () =
  let open Safe_ops in
  let result = try_with_default ~default:0 "test" (fun () -> 42) in
  check int "returns value" 42 result

let test_try_with_default_failure () =
  let open Safe_ops in
  let result = try_with_default ~default:0 "test" (fun () -> failwith "boom") in
  check int "returns default" 0 result

(* float_of_string_with_default *)
let test_float_of_string_with_default_valid () =
  let open Safe_ops in
  check (float 0.001) "parses valid" 2.718
    (float_of_string_with_default ~default:0.0 "2.718")

let test_float_of_string_with_default_invalid () =
  let open Safe_ops in
  check (float 0.001) "default on invalid" 0.0
    (float_of_string_with_default ~default:0.0 "xyz")

(* list_dir_safe *)
let test_list_dir_safe_nonexistent () =
  let open Safe_ops in
  let result = list_dir_safe "/nonexistent/directory/path" in
  check bool "Error on nonexistent" true (Result.is_error result)

let test_list_dir_safe_not_a_dir () =
  let open Safe_ops in
  (* /dev/null exists but is not a directory *)
  let result = list_dir_safe "/dev/null" in
  check bool "Error on non-dir" true (Result.is_error result)

let test_list_dir_safe_valid () =
  let open Safe_ops in
  let result = list_dir_safe "/tmp" in
  check bool "Ok on valid dir" true (Result.is_ok result)

(* read_json_file_safe *)
let test_read_json_file_safe_nonexistent () =
  let open Safe_ops in
  let result = read_json_file_safe "/nonexistent/file.json" in
  check bool "Error on missing" true (Result.is_error result)

let test_read_json_file_safe_valid () =
  let open Safe_ops in
  (* Create a temp file with valid JSON *)
  let path = Filename.temp_file "test_safe_ops_" ".json" in
  let oc = open_out path in
  output_string oc {|{"key": "value"}|};
  close_out oc;
  let result = read_json_file_safe path in
  Sys.remove path;
  check bool "Ok on valid json file" true (Result.is_ok result)

let test_read_json_file_safe_invalid_json () =
  let open Safe_ops in
  let path = Filename.temp_file "test_safe_ops_" ".json" in
  let oc = open_out path in
  output_string oc "not json content";
  close_out oc;
  let result = read_json_file_safe path in
  Sys.remove path;
  check bool "Error on invalid json" true (Result.is_error result)

(* read_file_safe with existing file *)
let test_read_file_safe_valid () =
  let open Safe_ops in
  let path = Filename.temp_file "test_safe_ops_" ".txt" in
  let oc = open_out path in
  output_string oc "hello world";
  close_out oc;
  let result = read_file_safe path in
  Sys.remove path;
  match result with
  | Ok content -> check string "reads content" "hello world" content
  | Error e -> fail (Printf.sprintf "unexpected error: %s" e)

(* remove_file_logged *)
let test_remove_file_logged_existing () =
  let open Safe_ops in
  let path = Filename.temp_file "test_safe_ops_" ".tmp" in
  remove_file_logged path;
  check bool "file removed" false (Sys.file_exists path)

let test_remove_file_logged_nonexistent () =
  let open Safe_ops in
  (* Should not raise, just log *)
  remove_file_logged "/nonexistent/file.tmp";
  ()

let test_remove_file_logged_custom_context () =
  let open Safe_ops in
  remove_file_logged ~context:"custom" "/nonexistent/file.tmp";
  ()

(* close_in_logged *)
let test_close_in_logged_valid () =
  let open Safe_ops in
  let path = Filename.temp_file "test_safe_ops_" ".txt" in
  let oc = open_out path in
  output_string oc "data";
  close_out oc;
  let ic = open_in path in
  close_in_logged ic;
  Sys.remove path;
  ()

(* get_env_int_logged *)
let test_get_env_int_logged_missing () =
  let open Safe_ops in
  let result = get_env_int_logged "MASC_TEST_NONEXISTENT_VAR_12345" ~default:99 in
  check int "default on missing" 99 result

let test_get_env_int_logged_valid () =
  let open Safe_ops in
  Unix.putenv "MASC_TEST_INT_VAR" "42";
  let result = get_env_int_logged "MASC_TEST_INT_VAR" ~default:0 in
  check int "parses env var" 42 result

let test_get_env_int_logged_invalid () =
  let open Safe_ops in
  Unix.putenv "MASC_TEST_INT_VAR_BAD" "not_int";
  let result = get_env_int_logged "MASC_TEST_INT_VAR_BAD" ~default:99 in
  check int "default on invalid" 99 result

(* get_env_float_logged *)
let test_get_env_float_logged_missing () =
  let open Safe_ops in
  let result = get_env_float_logged "MASC_TEST_NONEXISTENT_FLOAT_12345" ~default:1.5 in
  check (float 0.001) "default on missing" 1.5 result

let test_get_env_float_logged_valid () =
  let open Safe_ops in
  Unix.putenv "MASC_TEST_FLOAT_VAR" "2.718";
  let result = get_env_float_logged "MASC_TEST_FLOAT_VAR" ~default:0.0 in
  check (float 0.001) "parses env var" 2.718 result

let test_get_env_float_logged_invalid () =
  let open Safe_ops in
  Unix.putenv "MASC_TEST_FLOAT_VAR_BAD" "not_float";
  let result = get_env_float_logged "MASC_TEST_FLOAT_VAR_BAD" ~default:1.5 in
  check (float 0.001) "default on invalid" 1.5 result

(* json_int_opt *)
let test_json_int_opt_present () =
  let open Safe_ops in
  check (option int) "Some on present" (Some 42) (json_int_opt "count" sample_json)

let test_json_int_opt_missing () =
  let open Safe_ops in
  check (option int) "None on missing" None (json_int_opt "missing" sample_json)

let test_json_int_opt_null () =
  let open Safe_ops in
  let j = Yojson.Safe.from_string {|{"val": null}|} in
  check (option int) "None on null" None (json_int_opt "val" j)

let test_json_int_opt_wrong_type () =
  let open Safe_ops in
  check (option int) "None on string" None (json_int_opt "name" sample_json)

(* json_float_opt *)
let test_json_float_opt_present () =
  let open Safe_ops in
  check (option (float 0.001)) "Some on float" (Some 3.14) (json_float_opt "rate" sample_json)

let test_json_float_opt_from_int () =
  let open Safe_ops in
  check (option (float 0.001)) "Some from int" (Some 42.0) (json_float_opt "count" sample_json)

let test_json_float_opt_missing () =
  let open Safe_ops in
  check (option (float 0.001)) "None on missing" None (json_float_opt "missing" sample_json)

let test_json_float_opt_null () =
  let open Safe_ops in
  let j = Yojson.Safe.from_string {|{"val": null}|} in
  check (option (float 0.001)) "None on null" None (json_float_opt "val" j)

let test_json_float_opt_wrong_type () =
  let open Safe_ops in
  check (option (float 0.001)) "None on string" None (json_float_opt "name" sample_json)

(* Small-LLM coercion: stringified numerics parse into numeric getters.
   Field evidence 2026-04-17/18: keepers routinely send max_results:"0.0",
   offset:"100.0", etc. Missing coercion silently produced zero results
   across hundreds of masc_code_read / masc_code_search calls. *)
let test_json_int_coerces_stringified_int () =
  let open Safe_ops in
  let j = Yojson.Safe.from_string {|{"limit": "42"}|} in
  check int "parses stringified int" 42 (json_int ~default:0 "limit" j)

let test_json_int_coerces_stringified_float () =
  let open Safe_ops in
  let j = Yojson.Safe.from_string {|{"limit": "100.0"}|} in
  check int "parses stringified float by truncation" 100 (json_int ~default:0 "limit" j)

let test_json_int_falls_back_on_garbage_string () =
  let open Safe_ops in
  let j = Yojson.Safe.from_string {|{"limit": "abc"}|} in
  check int "default on unparseable string" 7 (json_int ~default:7 "limit" j)

let test_json_float_coerces_stringified_number () =
  let open Safe_ops in
  let j = Yojson.Safe.from_string {|{"rate": "0.25"}|} in
  check (float 0.001) "parses stringified float"
    0.25 (json_float ~default:0.0 "rate" j)

let test_json_bool_coerces_stringified_bool () =
  let open Safe_ops in
  let j = Yojson.Safe.from_string {|{"flag": "true", "off": "0"}|} in
  check bool "parses 'true'" true (json_bool ~default:false "flag" j);
  check bool "parses '0' as false" false (json_bool ~default:true "off" j)

let test_json_int_opt_coerces_stringified () =
  let open Safe_ops in
  let j = Yojson.Safe.from_string {|{"n": "13", "bad": "not a number"}|} in
  check (option int) "Some from string int" (Some 13) (json_int_opt "n" j);
  check (option int) "None from garbage" None (json_int_opt "bad" j)

(* json_string_list (Safe_ops version) *)
let test_json_string_list_present () =
  let open Safe_ops in
  let j = Yojson.Safe.from_string {|{"tags": ["a", "b", "c"]}|} in
  check (list string) "extracts list" ["a"; "b"; "c"] (json_string_list "tags" j)

let test_json_string_list_missing () =
  let open Safe_ops in
  check (list string) "empty on missing" [] (json_string_list "missing" sample_json)

let test_json_string_list_wrong_type () =
  let open Safe_ops in
  check (list string) "empty on non-list" [] (json_string_list "name" sample_json)

(* json_string_opt with null *)
let test_json_string_opt_null () =
  let open Safe_ops in
  let j = Yojson.Safe.from_string {|{"val": null}|} in
  check (option string) "None on null" None (json_string_opt "val" j)

(* json_bool with defaults *)
let test_json_bool_default () =
  let open Safe_ops in
  check bool "default on missing" false (json_bool "missing" sample_json)

let test_json_bool_custom_default () =
  let open Safe_ops in
  check bool "custom default" true (json_bool ~default:true "missing" sample_json)

(* json_int with default *)
let test_json_int_default () =
  let open Safe_ops in
  check int "default on missing" 0 (json_int "missing" sample_json)

let test_json_int_custom_default () =
  let open Safe_ops in
  check int "custom default" 99 (json_int ~default:99 "missing" sample_json)

(* json_float with default *)
let test_json_float_default () =
  let open Safe_ops in
  check (float 0.001) "default on missing" 0.0 (json_float "missing" sample_json)

(* parse_json_safe long input preview *)
let test_parse_json_safe_long_invalid () =
  let open Safe_ops in
  let long_str = String.make 100 'x' in
  let result = parse_json_safe ~context:"test" long_str in
  check bool "Error on long invalid" true (Result.is_error result)

let () =
  run "Safe_ops" [
    "int_of_string_safe", [
      test_case "valid" `Quick test_int_of_string_safe_valid;
      test_case "invalid" `Quick test_int_of_string_safe_invalid;
      test_case "with default" `Quick test_int_of_string_with_default;
    ];
    "float_of_string_safe", [
      test_case "valid" `Quick test_float_of_string_safe_valid;
      test_case "invalid" `Quick test_float_of_string_safe_invalid;
    ];
    "float_of_string_with_default", [
      test_case "valid" `Quick test_float_of_string_with_default_valid;
      test_case "invalid" `Quick test_float_of_string_with_default_invalid;
    ];
    "parse_json_safe", [
      test_case "valid json" `Quick test_parse_json_safe_valid;
      test_case "invalid json" `Quick test_parse_json_safe_invalid;
      test_case "repairs invalid utf8 inside string" `Quick
        test_parse_json_safe_repairs_invalid_utf8_inside_string;
      test_case "malformed json still rejected after utf8 repair" `Quick
        test_parse_json_safe_still_rejects_malformed_json_after_utf8_repair;
      test_case "rate limits repeated utf8 repair logs" `Quick
        test_parse_json_safe_rate_limits_repeated_utf8_repair_logs;
      test_case "sanitizes safe constructors" `Quick
        test_sanitize_json_utf8_covers_safe_constructors;
      test_case "sanitizes with raw preserved" `Quick
        test_sanitize_json_utf8_with_raw_preserves_original;
      test_case "sanitizes with raw unchanged marker" `Quick
        test_sanitize_json_utf8_with_raw_marks_clean_payload_unchanged;
      test_case "bounds utf8 repair log rate-limit table" `Quick
        test_utf8_repair_log_rate_limit_table_is_bounded;
      test_case "long invalid" `Quick test_parse_json_safe_long_invalid;
    ];
    "read_file_safe", [
      test_case "not found" `Quick test_read_file_safe_not_found;
      test_case "valid file" `Quick test_read_file_safe_valid;
    ];
    "read_json_file_safe", [
      test_case "nonexistent" `Quick test_read_json_file_safe_nonexistent;
      test_case "valid json file" `Quick test_read_json_file_safe_valid;
      test_case "invalid json file" `Quick test_read_json_file_safe_invalid_json;
    ];
    "list_dir_safe", [
      test_case "nonexistent" `Quick test_list_dir_safe_nonexistent;
      test_case "not a dir" `Quick test_list_dir_safe_not_a_dir;
      test_case "valid dir" `Quick test_list_dir_safe_valid;
    ];
    "remove_file_logged", [
      test_case "existing" `Quick test_remove_file_logged_existing;
      test_case "nonexistent" `Quick test_remove_file_logged_nonexistent;
      test_case "custom context" `Quick test_remove_file_logged_custom_context;
    ];
    "close_in_logged", [
      test_case "valid" `Quick test_close_in_logged_valid;
    ];
    "try_with_log", [
      test_case "success" `Quick test_try_with_log_success;
      test_case "failure" `Quick test_try_with_log_failure;
    ];
    "try_with_default", [
      test_case "success" `Quick test_try_with_default_success;
      test_case "failure" `Quick test_try_with_default_failure;
    ];
    "get_env_int_logged", [
      test_case "missing" `Quick test_get_env_int_logged_missing;
      test_case "valid" `Quick test_get_env_int_logged_valid;
      test_case "invalid" `Quick test_get_env_int_logged_invalid;
    ];
    "get_env_float_logged", [
      test_case "missing" `Quick test_get_env_float_logged_missing;
      test_case "valid" `Quick test_get_env_float_logged_valid;
      test_case "invalid" `Quick test_get_env_float_logged_invalid;
    ];
    "json_extraction", [
      test_case "string" `Quick test_json_string;
      test_case "string missing" `Quick test_json_string_missing;
      test_case "int" `Quick test_json_int;
      test_case "int default" `Quick test_json_int_default;
      test_case "int custom default" `Quick test_json_int_custom_default;
      test_case "float" `Quick test_json_float;
      test_case "float default" `Quick test_json_float_default;
      test_case "bool" `Quick test_json_bool;
      test_case "bool default" `Quick test_json_bool_default;
      test_case "bool custom default" `Quick test_json_bool_custom_default;
      test_case "string_opt present" `Quick test_json_string_opt_present;
      test_case "string_opt missing" `Quick test_json_string_opt_missing;
      test_case "string_opt null" `Quick test_json_string_opt_null;
    ];
    "json_int_opt", [
      test_case "present" `Quick test_json_int_opt_present;
      test_case "missing" `Quick test_json_int_opt_missing;
      test_case "null" `Quick test_json_int_opt_null;
      test_case "wrong type" `Quick test_json_int_opt_wrong_type;
    ];
    "json_float_opt", [
      test_case "present" `Quick test_json_float_opt_present;
      test_case "from int" `Quick test_json_float_opt_from_int;
      test_case "missing" `Quick test_json_float_opt_missing;
      test_case "null" `Quick test_json_float_opt_null;
      test_case "wrong type" `Quick test_json_float_opt_wrong_type;
    ];
    "json_string_list", [
      test_case "present" `Quick test_json_string_list_present;
      test_case "missing" `Quick test_json_string_list_missing;
      test_case "wrong type" `Quick test_json_string_list_wrong_type;
    ];
    "json_stringified_coercion", [
      test_case "int from stringified int" `Quick test_json_int_coerces_stringified_int;
      test_case "int from stringified float" `Quick test_json_int_coerces_stringified_float;
      test_case "int falls back on garbage" `Quick test_json_int_falls_back_on_garbage_string;
      test_case "float from stringified number" `Quick test_json_float_coerces_stringified_number;
      test_case "bool from stringified bool" `Quick test_json_bool_coerces_stringified_bool;
      test_case "int_opt from stringified" `Quick test_json_int_opt_coerces_stringified;
    ];
  ]
