open Alcotest

module TL = Masc_mcp.Keeper_toml_loader
module KTP = Masc_mcp.Keeper_types_profile
module KPA = Masc_mcp.Keeper_persona_authoring
module KEP = Masc_mcp.Keeper_exec_persona

let contains_substring s needle =
  let s_len = String.length s in
  let n_len = String.length needle in
  let rec loop i =
    if i + n_len > s_len then false
    else if String.sub s i n_len = needle then true
    else loop (i + 1)
  in
  if n_len = 0 then true else loop 0

let with_env_restore keys f =
  let prev = List.map (fun key -> key, Sys.getenv_opt key) keys in
  Fun.protect
    ~finally:(fun () ->
      List.iter
        (fun (key, value) ->
          match value with
          | Some v -> Unix.putenv key v
          | None -> Unix.putenv key "")
        prev)
    f

(* ================================================================ *)
(* TOML parser tests                                                 *)
(* ================================================================ *)

let test_parse_empty () =
  match TL.parse_toml "" with
  | Ok doc -> check int "empty doc" 0 (List.length doc)
  | Error e -> fail e

let test_parse_comments_and_blanks () =
  let input = {|
# This is a comment
   # indented comment

  |} in
  match TL.parse_toml input with
  | Ok doc -> check int "no entries" 0 (List.length doc)
  | Error e -> fail e

let test_parse_string_value () =
  let input = {|key = "hello world"|} in
  match TL.parse_toml input with
  | Ok doc ->
    (match List.assoc_opt "key" doc with
     | Some (TL.Toml_string s) -> check string "string value" "hello world" s
     | _ -> fail "expected Toml_string")
  | Error e -> fail e

let test_parse_string_escapes () =
  let input = {|key = "line1\nline2\ttab"|} in
  match TL.parse_toml input with
  | Ok doc ->
    (match List.assoc_opt "key" doc with
     | Some (TL.Toml_string s) -> check string "escapes" "line1\nline2\ttab" s
     | _ -> fail "expected Toml_string")
  | Error e -> fail e

let test_parse_int_value () =
  let input = "count = 42" in
  match TL.parse_toml input with
  | Ok doc ->
    (match List.assoc_opt "count" doc with
     | Some (TL.Toml_int i) -> check int "int value" 42 i
     | _ -> fail "expected Toml_int")
  | Error e -> fail e

let test_parse_negative_int () =
  let input = "offset = -10" in
  match TL.parse_toml input with
  | Ok doc ->
    (match List.assoc_opt "offset" doc with
     | Some (TL.Toml_int i) -> check int "negative int" (-10) i
     | _ -> fail "expected Toml_int")
  | Error e -> fail e

let test_parse_float_value () =
  let input = "ratio = 0.75" in
  match TL.parse_toml input with
  | Ok doc ->
    (match List.assoc_opt "ratio" doc with
     | Some (TL.Toml_float f) ->
       check (float 0.001) "float value" 0.75 f
     | _ -> fail "expected Toml_float")
  | Error e -> fail e

let test_parse_bool_values () =
  let input = "enabled = true\ndisabled = false" in
  match TL.parse_toml input with
  | Ok doc ->
    (match List.assoc_opt "enabled" doc with
     | Some (TL.Toml_bool b) -> check bool "true" true b
     | _ -> fail "expected true");
    (match List.assoc_opt "disabled" doc with
     | Some (TL.Toml_bool b) -> check bool "false" false b
     | _ -> fail "expected false")
  | Error e -> fail e

let test_parse_string_array () =
  let input = {|tags = ["alpha", "beta", "gamma"]|} in
  match TL.parse_toml input with
  | Ok doc ->
    (match List.assoc_opt "tags" doc with
     | Some (TL.Toml_string_array xs) ->
       check int "array length" 3 (List.length xs);
       check string "first" "alpha" (List.nth xs 0);
       check string "second" "beta" (List.nth xs 1);
       check string "third" "gamma" (List.nth xs 2)
     | _ -> fail "expected Toml_string_array")
  | Error e -> fail e

let test_parse_string_array_escaped_quotes () =
  let input = {|tags = ["a\"b", "c\\d"]|} in
  match TL.parse_toml input with
  | Ok doc ->
    (match List.assoc_opt "tags" doc with
     | Some (TL.Toml_string_array xs) ->
       check int "array length" 2 (List.length xs);
       check string "escaped quote" "a\"b" (List.nth xs 0);
       check string "escaped backslash" "c\\d" (List.nth xs 1)
     | _ -> fail "expected Toml_string_array")
  | Error e -> fail e

let test_parse_empty_array () =
  let input = "items = []" in
  match TL.parse_toml input with
  | Ok doc ->
    (match List.assoc_opt "items" doc with
     | Some (TL.Toml_string_array xs) ->
       check int "empty array" 0 (List.length xs)
     | _ -> fail "expected empty Toml_string_array")
  | Error e -> fail e

let test_parse_table () =
  let input = {|
[keeper]
goal = "test goal"
count = 5
|} in
  match TL.parse_toml input with
  | Ok doc ->
    (match List.assoc_opt "keeper.goal" doc with
     | Some (TL.Toml_string s) -> check string "table key" "test goal" s
     | _ -> fail "expected keeper.goal");
    (match List.assoc_opt "keeper.count" doc with
     | Some (TL.Toml_int i) -> check int "table int" 5 i
     | _ -> fail "expected keeper.count")
  | Error e -> fail e

let test_parse_inline_comment () =
  let input = {|key = "value" # this is a comment|} in
  match TL.parse_toml input with
  | Ok doc ->
    (match List.assoc_opt "key" doc with
     | Some (TL.Toml_string s) -> check string "value with comment" "value" s
     | _ -> fail "expected Toml_string")
  | Error e -> fail e

let test_parse_multiline_basic_string () =
  let input = "[keeper]\ninstructions = \"\"\"\nline one\nline two\nline three\n\"\"\"" in
  match TL.parse_toml input with
  | Ok doc ->
    (match List.assoc_opt "keeper.instructions" doc with
     | Some (TL.Toml_string s) ->
       check string "multiline content" "line one\nline two\nline three\n" s
     | _ -> fail "expected Toml_string for multiline")
  | Error e -> fail ("multiline parse failed: " ^ e)

let test_parse_multiline_single_line () =
  let input = {|key = """inline multiline"""|} in
  match TL.parse_toml input with
  | Ok doc ->
    (match List.assoc_opt "key" doc with
     | Some (TL.Toml_string s) ->
       check string "inline multiline" "inline multiline" s
     | _ -> fail "expected Toml_string")
  | Error e -> fail ("inline multiline failed: " ^ e)

let test_parse_multiline_empty () =
  let input = "key = \"\"\"\n\"\"\"" in
  match TL.parse_toml input with
  | Ok doc ->
    (match List.assoc_opt "key" doc with
     | Some (TL.Toml_string s) ->
       check string "empty multiline" "" s
     | _ -> fail "expected Toml_string")
  | Error e -> fail ("empty multiline failed: " ^ e)

let test_parse_multiline_unterminated () =
  let input = "key = \"\"\"\nunterminated content" in
  match TL.parse_toml input with
  | Ok _ -> fail "expected parse error for unterminated multiline"
  | Error _ -> ()

let test_parse_multiline_with_escapes () =
  let input = "key = \"\"\"\nfirst\\nsecond\n\"\"\"" in
  match TL.parse_toml input with
  | Ok doc ->
    (match List.assoc_opt "key" doc with
     | Some (TL.Toml_string s) ->
       check string "multiline with escape" "first\nsecond\n" s
     | _ -> fail "expected Toml_string")
  | Error e -> fail ("multiline escape failed: " ^ e)

let test_parse_multiline_with_values_after () =
  let input = "[keeper]\ninstructions = \"\"\"\nsome text\n\"\"\"\ngoal = \"test\"" in
  match TL.parse_toml input with
  | Ok doc ->
    (match List.assoc_opt "keeper.instructions" doc with
     | Some (TL.Toml_string s) ->
       check string "multiline" "some text\n" s
     | _ -> fail "expected instructions");
    (match List.assoc_opt "keeper.goal" doc with
     | Some (TL.Toml_string s) ->
       check string "goal after multiline" "test" s
     | _ -> fail "expected goal after multiline")
  | Error e -> fail ("multiline with values after failed: " ^ e)

let test_parse_multiline_preserves_leading_spaces () =
  let input = "key = \"\"\"  keep-leading-space\nnext line\n\"\"\"" in
  match TL.parse_toml input with
  | Ok doc ->
    (match List.assoc_opt "key" doc with
     | Some (TL.Toml_string s) ->
       check string "multiline preserves spaces" "  keep-leading-space\nnext line\n" s
     | _ -> fail "expected Toml_string")
  | Error e -> fail ("multiline whitespace preservation failed: " ^ e)

let test_parse_multiline_allows_escaped_triple_quotes () =
  let input = "key = \"\"\"\ncontains \\\"\\\"\\\" quotes\n\"\"\"" in
  match TL.parse_toml input with
  | Ok doc ->
    (match List.assoc_opt "key" doc with
     | Some (TL.Toml_string s) ->
       check string "escaped triple quotes" "contains \"\"\" quotes\n" s
     | _ -> fail "expected Toml_string")
  | Error e -> fail ("escaped triple quotes failed: " ^ e)

let test_parse_multiline_rejects_trailing_garbage () =
  let inputs =
    [
      "key = \"\"\"inline\"\"\" garbage";
      "key = \"\"\"\nline\n\"\"\" garbage";
    ]
  in
  List.iter
    (fun input ->
      match TL.parse_toml input with
      | Ok _ -> fail "expected parse error for trailing garbage after multiline close"
      | Error _ -> ())
    inputs

let test_parse_multiline_normalizes_crlf () =
  let input = "key = \"\"\"\r\nfirst\r\nsecond\r\n\"\"\"" in
  match TL.parse_toml input with
  | Ok doc ->
    (match List.assoc_opt "key" doc with
     | Some (TL.Toml_string s) ->
       check string "crlf normalized" "first\nsecond\n" s
     | _ -> fail "expected Toml_string")
  | Error e -> fail ("multiline CRLF failed: " ^ e)

(* TOML spec: up to two `"` immediately after closing `"""` are content. *)
let test_parse_multiline_single_trailing_quote_inline () =
  (* Inline multiline string with one trailing quote kept as content. *)
  let input = {|key = """"one quote""""|} in
  match TL.parse_toml input with
  | Ok doc ->
    (match List.assoc_opt "key" doc with
     | Some (TL.Toml_string s) ->
       check string "single trailing quote inline" "\"one quote\"" s
     | _ -> fail "expected Toml_string")
  | Error e -> fail ("single trailing quote inline failed: " ^ e)

let test_parse_multiline_double_trailing_quote_inline () =
  (* Inline multiline string with two trailing quotes kept as content. *)
  let input = {|key = """""two quotes"""""|} in
  match TL.parse_toml input with
  | Ok doc ->
    (match List.assoc_opt "key" doc with
     | Some (TL.Toml_string s) ->
       check string "double trailing quote inline" "\"\"two quotes\"\"" s
     | _ -> fail "expected Toml_string")
  | Error e -> fail ("double trailing quote inline failed: " ^ e)

let test_parse_multiline_trailing_quote_on_close_line () =
  (* Multiline string with one trailing quote on the closing line. *)
  let input = "key = \"\"\"\nsome content\n\"\"\"\"" in
  match TL.parse_toml input with
  | Ok doc ->
    (match List.assoc_opt "key" doc with
     | Some (TL.Toml_string s) ->
       check string "trailing quote multiline" "some content\n\"" s
     | _ -> fail "expected Toml_string")
  | Error e -> fail ("trailing quote multiline failed: " ^ e)

let test_parse_multiline_line_ending_backslash () =
  (* Line-ending backslash joins the next non-whitespace content. *)
  let input = "key = \"\"\"\nfirst \\\n    second\n\"\"\"" in
  match TL.parse_toml input with
  | Ok doc ->
    (match List.assoc_opt "key" doc with
     | Some (TL.Toml_string s) ->
       check string "line ending backslash" "first second\n" s
     | _ -> fail "expected Toml_string")
  | Error e -> fail ("line ending backslash failed: " ^ e)

let test_parse_error_unterminated_table () =
  let input = "[missing_bracket" in
  match TL.parse_toml input with
  | Ok _ -> fail "expected parse error"
  | Error _ -> ()

let test_parse_error_no_equals () =
  let input = "no_equals_here" in
  match TL.parse_toml input with
  | Ok _ -> fail "expected parse error"
  | Error _ -> ()

(* ================================================================ *)
(* Multi-line array tests                                            *)
(* ================================================================ *)

let test_parse_multiline_array () =
  let input = "tags = [\n  \"alpha\",\n  \"beta\",\n  \"gamma\",\n]" in
  match TL.parse_toml input with
  | Ok doc ->
    (match List.assoc_opt "tags" doc with
     | Some (TL.Toml_string_array xs) ->
       check int "array length" 3 (List.length xs);
       check string "first" "alpha" (List.nth xs 0);
       check string "second" "beta" (List.nth xs 1);
       check string "third" "gamma" (List.nth xs 2)
     | _ -> fail "expected Toml_string_array")
  | Error e -> fail e

let test_parse_multiline_array_no_trailing_comma () =
  let input = "tags = [\n  \"one\",\n  \"two\"\n]" in
  match TL.parse_toml input with
  | Ok doc ->
    (match List.assoc_opt "tags" doc with
     | Some (TL.Toml_string_array xs) ->
       check int "array length" 2 (List.length xs);
       check string "first" "one" (List.nth xs 0);
       check string "second" "two" (List.nth xs 1)
     | _ -> fail "expected Toml_string_array")
  | Error e -> fail e

let test_parse_multiline_array_with_comments () =
  let input = "tags = [\n  \"a\", # first\n  \"b\", # second\n]" in
  match TL.parse_toml input with
  | Ok doc ->
    (match List.assoc_opt "tags" doc with
     | Some (TL.Toml_string_array xs) ->
       check int "array length" 2 (List.length xs);
       check string "first" "a" (List.nth xs 0);
       check string "second" "b" (List.nth xs 1)
     | _ -> fail "expected Toml_string_array")
  | Error e -> fail e

let test_parse_multiline_array_empty () =
  let input = "tags = [\n]" in
  match TL.parse_toml input with
  | Ok doc ->
    (match List.assoc_opt "tags" doc with
     | Some (TL.Toml_string_array xs) ->
       check int "empty array" 0 (List.length xs)
     | _ -> fail "expected empty Toml_string_array")
  | Error e -> fail e

let test_parse_multiline_array_single_element () =
  let input = "tags = [\n  \"only\"\n]" in
  match TL.parse_toml input with
  | Ok doc ->
    (match List.assoc_opt "tags" doc with
     | Some (TL.Toml_string_array xs) ->
       check int "array length" 1 (List.length xs);
       check string "only" "only" (List.nth xs 0)
     | _ -> fail "expected Toml_string_array")
  | Error e -> fail e

let test_parse_multiline_array_unterminated () =
  let input = "tags = [\n  \"a\"\n" in
  match TL.parse_toml input with
  | Ok _ -> fail "expected parse error for unterminated multiline array"
  | Error _ -> ()

let test_parse_multiline_array_comment_only_lines () =
  let input = "tags = [\n  \"x\",\n  # comment line\n  \"y\"\n]" in
  match TL.parse_toml input with
  | Ok doc ->
    (match List.assoc_opt "tags" doc with
     | Some (TL.Toml_string_array xs) ->
       check int "array length" 2 (List.length xs);
       check string "first" "x" (List.nth xs 0);
       check string "second" "y" (List.nth xs 1)
     | _ -> fail "expected Toml_string_array")
  | Error e -> fail e

let test_parse_multiline_array_bracket_in_string () =
  let input = "tags = [\n  \"a]\",\n  \"[b\"\n]" in
  match TL.parse_toml input with
  | Ok doc ->
    (match List.assoc_opt "tags" doc with
     | Some (TL.Toml_string_array xs) ->
       check int "array length" 2 (List.length xs);
       check string "first" "a]" (List.nth xs 0);
       check string "second" "[b" (List.nth xs 1)
     | _ -> fail "expected Toml_string_array")
  | Error e -> fail e

(* ================================================================ *)
(* Profile defaults conversion tests                                 *)
(* ================================================================ *)

let test_profile_minimal () =
  let input = {|
[keeper]
goal = "test goal"
|} in
  match TL.parse_toml input with
  | Error e -> fail e
  | Ok doc ->
    match KTP.profile_defaults_of_toml doc with
    | Error e -> fail e
    | Ok defaults ->
      check (option string) "goal" (Some "test goal") defaults.goal

let test_profile_full () =
  let input = {|
[keeper]
persona_name = "analyst"
goal = "analyze logs"
short_goal = "current session"
mid_goal = "build patterns"
long_goal = "continuous improvement"
social_model = "magentic_ledger_v1"
will = "detect issues"
needs = "log access"
desires = "low false positives"
instructions = "You are a log analyzer."
mention_targets = ["sherlock", "log-analyzer"]
proactive_enabled = true
proactive_idle_sec = 300
proactive_cooldown_sec = 60
room_signal_prompt_enabled = true
policy_voice_enabled = false
autoboot_enabled = false
github_identity = "anyang-keepers"
git_identity_mode = "keeper_alias"
active_goal_ids = ["goal-runtime", "goal-masc-mcp"]
|} in
  match TL.parse_toml input with
  | Error e -> fail e
  | Ok doc ->
    match KTP.profile_defaults_of_toml doc with
    | Error e -> fail e
    | Ok d ->
      check (option string) "persona_name" (Some "analyst") d.persona_name;
      check (option string) "goal" (Some "analyze logs") d.goal;
      check (option string) "social_model" (Some "magentic_ledger_v1")
        d.social_model;
      check (option string) "will" (Some "detect issues") d.will;
      check int "mention_targets" 2 (List.length d.mention_targets);
      check (option bool) "proactive" (Some true) d.proactive_enabled;
      check (option bool) "room signal prompt" (Some true)
        d.room_signal_prompt_enabled;
      check (option bool) "policy_voice" (Some false) d.policy_voice_enabled;
      check (option bool) "autoboot_enabled" (Some false) d.autoboot_enabled;
      check (option string) "github_identity" (Some "anyang-keepers")
        d.github_identity;
      check (option string) "git_identity_mode" (Some "keeper_alias")
        d.git_identity_mode;
      check (option (list string)) "active_goal_ids"
        (Some [ "goal-runtime"; "goal-masc-mcp" ])
        d.active_goal_ids

let test_profile_rejects_partial_proactive_interval_pair () =
  let input = {|
[keeper]
goal = "test"
proactive_enabled = true
proactive_idle_sec = 120
|} in
  match TL.parse_toml input with
  | Error e -> fail e
  | Ok doc ->
      (match KTP.profile_defaults_of_toml doc with
       | Ok _ -> fail "expected partial proactive interval error"
       | Error msg ->
           check bool "mentions missing cooldown" true
             (contains_substring msg "proactive_cooldown_sec is missing"))

let test_profile_rejects_invalid_git_identity_mode () =
  let input = {|
[keeper]
goal = "test"
git_identity_mode = "hot_switch"
|} in
  match TL.parse_toml input with
  | Error e -> fail e
  | Ok doc ->
      (match KTP.profile_defaults_of_toml doc with
       | Ok _ -> fail "expected invalid git_identity_mode error"
       | Error msg ->
           check bool "mentions invalid git_identity_mode" true
             (contains_substring msg "invalid git_identity_mode"))

let test_profile_rejects_invalid_social_model () =
  let input = {|
[keeper]
goal = "test"
social_model = "experimental_v99"
|} in
  match TL.parse_toml input with
  | Error e -> fail e
  | Ok doc ->
      (match KTP.profile_defaults_of_toml doc with
       | Ok _ -> fail "expected invalid social_model error"
       | Error msg ->
           check bool "mentions invalid social_model" true
             (try
                ignore
                  (Str.search_forward
                     (Str.regexp_string "invalid social_model")
                     msg 0);
                true
              with Not_found -> false))

let test_profile_rejects_removed_model_keys () =
  let input = {|
[keeper]
goal = "test"
models = ["llama:test"]
|} in
  match TL.parse_toml input with
  | Error e -> fail e
  | Ok doc ->
      (match KTP.profile_defaults_of_toml doc with
       | Ok _ -> fail "expected removed TOML key error"
       | Error msg ->
           check bool "mentions removed models key" true
             (try
                ignore
                  (Str.search_forward
                     (Str.regexp_string "keeper.models")
                     msg 0);
                true
              with Not_found -> false))

let test_profile_rejects_removed_also_allow_alias () =
  let input = {|
[keeper]
goal = "test"
also_allow = ["keeper_shell"]
|} in
  match TL.parse_toml input with
  | Error e -> fail e
  | Ok doc ->
      (match KTP.profile_defaults_of_toml doc with
       | Ok _ -> fail "expected removed TOML alias error"
       | Error msg ->
           check bool "mentions removed also_allow alias" true
             (try
                ignore
                  (Str.search_forward
                     (Str.regexp_string "keeper.also_allow")
                     msg 0);
                true
              with Not_found -> false))

let test_profile_rejects_removed_initiative_keys () =
  let input = {|
[keeper]
goal = "test"
initiative_enabled = true
|} in
  match TL.parse_toml input with
  | Error e -> fail e
  | Ok doc ->
      (match KTP.profile_defaults_of_toml doc with
       | Ok _ -> fail "expected removed TOML key error"
       | Error msg ->
           check bool "mentions removed initiative key" true
             (try
                ignore
                  (Str.search_forward
                     (Str.regexp_string "keeper.initiative_enabled")
                     msg 0);
                true
              with Not_found -> false))

(* ================================================================ *)
(* File loading tests                                                *)
(* ================================================================ *)

let test_load_from_file () =
  (* Write a temp file *)
  let tmp = Filename.temp_file "keeper_toml_test" ".toml" in
  let content = {|
[keeper]
name = "test-keeper"
goal = "testing file load"
|} in
  let oc = open_out tmp in
  output_string oc content;
  close_out oc;
  (match KTP.load_keeper_toml tmp with
   | Error e -> fail e
   | Ok (name, defaults) ->
     check string "name from toml" "test-keeper" name;
     check (option string) "goal" (Some "testing file load") defaults.goal;
     check (option string) "manifest" (Some tmp) defaults.manifest_path);
  Sys.remove tmp

let test_load_name_from_filename () =
  let tmp_dir = Filename.get_temp_dir_name () in
  let path = Filename.concat tmp_dir "my-analyzer.toml" in
  let content = {|
[keeper]
goal = "analyze stuff"
|} in
  let oc = open_out path in
  output_string oc content;
  close_out oc;
  (match KTP.load_keeper_toml path with
   | Error e -> fail e
   | Ok (name, _) ->
     check string "name from filename" "my-analyzer" name);
  Sys.remove path

let test_load_invalid_name () =
  let tmp = Filename.temp_file "keeper_toml_test" ".toml" in
  let content = {|
[keeper]
name = "invalid name with spaces"
goal = "test"
|} in
  let oc = open_out tmp in
  output_string oc content;
  close_out oc;
  (match KTP.load_keeper_toml tmp with
   | Ok _ -> fail "expected error for invalid name"
   | Error _ -> ());
  Sys.remove tmp

(* ================================================================ *)
(* Discovery tests                                                   *)
(* ================================================================ *)

let test_discover_empty_dir () =
  let tmp_dir = Filename.temp_file "keeper_discover" "" in
  Sys.remove tmp_dir;
  Unix.mkdir tmp_dir 0o755;
  let result = KTP.discover_keepers_toml tmp_dir in
  check int "empty dir" 0 (List.length result);
  Unix.rmdir tmp_dir

let test_discover_with_files () =
  let tmp_dir = Filename.temp_file "keeper_discover" "" in
  Sys.remove tmp_dir;
  Unix.mkdir tmp_dir 0o755;
  (* Create two TOML files *)
  let write_file name content =
    let path = Filename.concat tmp_dir name in
    let oc = open_out path in
    output_string oc content;
    close_out oc
  in
  write_file "alpha.toml" {|
[keeper]
goal = "alpha goal"
|};
  write_file "beta.toml" {|
[keeper]
goal = "beta goal"
|};
  write_file "not-toml.json" {|{"ignored": true}|};
  let result = KTP.discover_keepers_toml tmp_dir in
  check int "two keepers" 2 (List.length result);
  let names = List.map fst result in
  check bool "has alpha" true (List.mem "alpha" names);
  check bool "has beta" true (List.mem "beta" names);
  (* Cleanup *)
  Array.iter
    (fun f -> Sys.remove (Filename.concat tmp_dir f))
    (Sys.readdir tmp_dir);
  Unix.rmdir tmp_dir

let test_discover_nonexistent_dir () =
  let result = KTP.discover_keepers_toml "/nonexistent/path/keepers" in
  check int "nonexistent dir" 0 (List.length result)

let test_discover_skips_bad_files () =
  let tmp_dir = Filename.temp_file "keeper_discover" "" in
  Sys.remove tmp_dir;
  Unix.mkdir tmp_dir 0o755;
  let write_file name content =
    let path = Filename.concat tmp_dir name in
    let oc = open_out path in
    output_string oc content;
    close_out oc
  in
  write_file "good.toml" {|
[keeper]
goal = "works"
|};
  write_file "bad.toml" "[broken";
  let result = KTP.discover_keepers_toml tmp_dir in
  check int "one good keeper" 1 (List.length result);
  check string "good name" "good" (fst (List.hd result));
  Array.iter
    (fun f -> Sys.remove (Filename.concat tmp_dir f))
    (Sys.readdir tmp_dir);
  Unix.rmdir tmp_dir

let with_temp_dir prefix f =
  let dir = Filename.temp_file prefix "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let rec rm_rf path =
    if Sys.file_exists path then
      if Sys.is_directory path then begin
        Sys.readdir path |> Array.iter (fun name -> rm_rf (Filename.concat path name));
        Unix.rmdir path
      end else
        Sys.remove path
  in
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)

let rec mkdir_p dir =
  if dir = "" || dir = "." || dir = "/" then ()
  else if Sys.file_exists dir then ()
  else begin
    mkdir_p (Filename.dirname dir);
    Unix.mkdir dir 0o755
  end

let write_file path content =
  let oc = open_out path in
  output_string oc content;
  close_out oc

let restore_env name = function
  | Some value -> Unix.putenv name value
  | None ->
      (* This OCaml Unix module does not expose [unsetenv]. Config_dir_resolver
         normalizes empty env values to [None], so this restores the effective
         resolver state for these tests. *)
      Unix.putenv name ""

let with_personas_dir f =
  with_temp_dir "keeper-personas" @@ fun personas_dir ->
  let original = Sys.getenv_opt "MASC_PERSONAS_DIR" in
  Fun.protect
    ~finally:(fun () ->
      restore_env "MASC_PERSONAS_DIR" original;
      Masc_mcp.Config_dir_resolver.reset ())
    (fun () ->
      Unix.putenv "MASC_PERSONAS_DIR" personas_dir;
      Masc_mcp.Config_dir_resolver.reset ();
      f personas_dir)

let with_config_dir f =
  with_temp_dir "keeper-config" @@ fun config_dir ->
  let original = Sys.getenv_opt "MASC_CONFIG_DIR" in
  Fun.protect
    ~finally:(fun () ->
      restore_env "MASC_CONFIG_DIR" original;
      Masc_mcp.Config_dir_resolver.reset ())
    (fun () ->
      Unix.putenv "MASC_CONFIG_DIR" config_dir;
      Masc_mcp.Config_dir_resolver.reset ();
      f config_dir)

(* Legacy allowed_providers is accepted for compatibility but ignored.
   Provider ownership now lives with OAS cascade resolution. *)

let test_profile_ignores_legacy_allowed_providers () =
  let input = {|
[keeper]
goal = "test"
allowed_providers = ["Ollama", "GLM"]
cascade_name = "big_three"
|} in
  match TL.parse_toml input with
  | Error e -> fail e
  | Ok doc ->
    (match KTP.profile_defaults_of_toml doc with
     | Error e -> fail e
     | Ok d ->
       check (option string) "cascade preserved"
         (Some "big_three") d.cascade_name)

let test_profile_max_turns_overrides () =
  let input = {|
[keeper]
goal = "test"
max_turns_per_call = 25
max_turns_per_call_scheduled_autonomous = 3
|} in
  match TL.parse_toml input with
  | Error e -> fail e
  | Ok doc ->
    (match KTP.profile_defaults_of_toml doc with
     | Error e -> fail e
     | Ok d ->
       check (option int) "max_turns_per_call" (Some 25) d.max_turns_per_call;
       check (option int) "max_turns_per_call_scheduled_autonomous"
         (Some 3) d.max_turns_per_call_scheduled_autonomous;
       check int "effective reactive uses override" 25
         (KTP.effective_max_turns_per_call d);
       (* autonomous is capped by reactive global cap, but 3 < env default 30 *)
       check int "effective autonomous uses override" 3
         (KTP.effective_max_turns_per_call_scheduled_autonomous d))

let test_profile_max_turns_defaults_when_absent () =
  let input = {|
[keeper]
goal = "test"
|} in
  match TL.parse_toml input with
  | Error e -> fail e
  | Ok doc ->
    (match KTP.profile_defaults_of_toml doc with
     | Error e -> fail e
     | Ok d ->
       check (option int) "max_turns_per_call absent" None d.max_turns_per_call;
       check (option int) "max_turns_per_call_scheduled_autonomous absent"
         None d.max_turns_per_call_scheduled_autonomous;
       (* helpers fall back to resolved runtime defaults (30 and min(global, 10)=10) *)
       check int "effective reactive default" 30
         (KTP.effective_max_turns_per_call d);
       check int "effective autonomous default" 10
         (KTP.effective_max_turns_per_call_scheduled_autonomous d))

let test_profile_max_turns_accepts_raised_ceiling () =
  let input = {|
[keeper]
goal = "test"
max_turns_per_call = 99
max_turns_per_call_scheduled_autonomous = 0
|} in
  match TL.parse_toml input with
  | Error e -> fail e
  | Ok doc ->
    (match KTP.profile_defaults_of_toml doc with
     | Error e -> fail e
     | Ok d ->
       check int "reactive accepts raised ceiling" 99
         (KTP.effective_max_turns_per_call d);
       check int "zero autonomous falls back" 10
         (KTP.effective_max_turns_per_call_scheduled_autonomous d))

let test_profile_max_turns_rejects_out_of_range () =
  let input = {|
[keeper]
goal = "test"
max_turns_per_call = 101
max_turns_per_call_scheduled_autonomous = 0
|} in
  match TL.parse_toml input with
  | Error e -> fail e
  | Ok doc ->
    (match KTP.profile_defaults_of_toml doc with
     | Error e -> fail e
     | Ok d ->
       (* Values are parsed as-is but clamp_max_turns_override rejects them,
          so helpers fall back to env defaults. *)
       check int "out-of-range reactive falls back" 30
         (KTP.effective_max_turns_per_call d);
       check int "zero autonomous falls back" 10
         (KTP.effective_max_turns_per_call_scheduled_autonomous d))

let test_profile_normalizes_legacy_keeper_cascade_alias () =
  let input = {|
[keeper]
goal = "test"
cascade_name = "oas-coding_first"
|} in
  match TL.parse_toml input with
  | Error e -> fail e
  | Ok doc ->
    (match KTP.profile_defaults_of_toml doc with
     | Error e -> fail e
     | Ok d ->
       check (option string) "legacy keeper cascade normalized"
         (Some Masc_mcp.Keeper_config.default_cascade_name)
         d.cascade_name)

let test_persona_resolver_defaults_to_research_tool_access () =
  with_personas_dir @@ fun personas_dir ->
  let persona_dir = Filename.concat personas_dir "probe" in
  mkdir_p persona_dir;
  write_file
    (Filename.concat persona_dir "profile.json")
    {|
{
  "name": "Probe",
  "keeper": {
    "goal": "test persona keeper"
  }
}
|};
  match
    Masc_mcp.Keeper_exec_persona.resolved_keeper_args_from_persona
      (`Assoc [ ("persona_name", `String "probe") ])
  with
  | Error e -> fail ("resolver failed: " ^ e)
  | Ok (_, resolved) ->
      let tool_access = Yojson.Safe.Util.member "tool_access" resolved in
      check string "persona default tool_access kind" "preset"
        (Yojson.Safe.Util.member "kind" tool_access |> Yojson.Safe.Util.to_string);
      check string "persona default tool_access preset" "research"
        (Yojson.Safe.Util.member "preset" tool_access |> Yojson.Safe.Util.to_string);
      check bool "legacy tool_preset omitted" false
        (match Yojson.Safe.Util.member "tool_preset" resolved with
         | `String _ -> true
         | _ -> false)

let test_persona_resolver_rejects_operator_todo_profile () =
  with_personas_dir @@ fun personas_dir ->
  let persona_dir = Filename.concat personas_dir "probe" in
  mkdir_p persona_dir;
  write_file
    (Filename.concat persona_dir "profile.json")
    {|
{
  "name": "OPERATOR_TODO: probe display",
  "role": "draft placeholder",
  "keeper": {
    "goal": "OPERATOR_TODO: fill before spawn"
  }
}
|};
  (match KTP.load_persona_summary "probe" with
   | Some _ -> fail "placeholder persona summary should be hidden"
   | None -> ());
  let defaults = KTP.load_keeper_profile_defaults_from_persona "probe" in
  check (option string) "placeholder manifest rejected" None defaults.manifest_path;
  check (option string) "placeholder goal rejected" None defaults.goal;
  match
    KEP.resolved_keeper_args_from_persona
      (`Assoc [ ("persona_name", `String "probe") ])
  with
  | Ok _ -> fail "placeholder persona should not resolve for keeper spawn"
  | Error e ->
      check bool "reports persona unavailable" true
        (contains_substring e "persona not found")

let test_persona_resolver_reports_placeholder_defaults_source () =
  with_personas_dir @@ fun personas_dir ->
  with_config_dir @@ fun config_dir ->
  let persona_dir = Filename.concat personas_dir "probe" in
  mkdir_p persona_dir;
  write_file
    (Filename.concat persona_dir "profile.json")
    {|
{
  "name": "Probe",
  "role": "runtime profile",
  "keeper": {
    "goal": "normal persona goal"
  }
}
|};
  let keepers_dir = Filename.concat config_dir "keepers" in
  mkdir_p keepers_dir;
  let keeper_path = Filename.concat keepers_dir "probe.toml" in
  write_file keeper_path
    {|
[keeper]
persona_name = "probe"
goal = "OPERATOR_TODO: replace before spawn"
|};
  match
    KEP.resolved_keeper_args_from_persona
      (`Assoc [ ("persona_name", `String "probe") ])
  with
  | Ok _ -> fail "placeholder keeper defaults should not resolve"
  | Error e ->
      check bool "reports keeper defaults" true
        (contains_substring e "keeper defaults");
      check bool "reports manifest path" true
        (contains_substring e keeper_path);
      check bool "reports field" true
        (contains_substring e "keeper.goal")

let test_persona_resolver_rejects_placeholder_in_resolved_payload () =
  with_personas_dir @@ fun personas_dir ->
  with_config_dir @@ fun config_dir ->
  let persona_dir = Filename.concat personas_dir "probe" in
  mkdir_p persona_dir;
  write_file
    (Filename.concat persona_dir "profile.json")
    {|
{
  "name": "Probe",
  "role": "runtime profile",
  "keeper": {
    "goal": "normal persona goal"
  }
}
|};
  let keepers_dir = Filename.concat config_dir "keepers" in
  mkdir_p keepers_dir;
  let keeper_path = Filename.concat keepers_dir "probe.toml" in
  write_file keeper_path
    {|
[keeper]
persona_name = "probe"
tool_denylist = ["OPERATOR_TODO: remove before spawn"]
|};
  match
    KEP.resolved_keeper_args_from_persona
      (`Assoc [ ("persona_name", `String "probe") ])
  with
  | Ok _ -> fail "placeholder in resolved keeper args should not resolve"
  | Error e ->
      check bool "reports resolved args" true
        (contains_substring e "resolved keeper args");
      check bool "reports manifest path" true
        (contains_substring e keeper_path);
      check bool "reports resolved payload field" true
        (contains_substring e "$.tool_denylist[0]")

let test_persona_resolver_ignores_non_public_social_model_arg () =
  with_personas_dir @@ fun personas_dir ->
  let persona_dir = Filename.concat personas_dir "probe" in
  mkdir_p persona_dir;
  write_file
    (Filename.concat persona_dir "profile.json")
    {|
{
  "name": "Probe",
  "keeper": {
    "goal": "test persona keeper"
  }
}
|};
  match
    Masc_mcp.Keeper_exec_persona.resolved_keeper_args_from_persona
      (`Assoc
        [
          ("persona_name", `String "probe");
          ("social_model", `String "magentic_ledger_v1");
        ])
  with
  | Error e -> fail ("resolver failed: " ^ e)
  | Ok (_, resolved) ->
      check bool "social_model omitted from resolved args" false
        (match Yojson.Safe.Util.member "social_model" resolved with
         | `String _ -> true
         | _ -> false)

let test_persona_resolver_preserves_autoboot_enabled_arg () =
  with_personas_dir @@ fun personas_dir ->
  let persona_dir = Filename.concat personas_dir "probe" in
  mkdir_p persona_dir;
  write_file
    (Filename.concat persona_dir "profile.json")
    {|
{
  "name": "Probe",
  "keeper": {
    "goal": "test persona keeper"
  }
}
|};
  match
    Masc_mcp.Keeper_exec_persona.resolved_keeper_args_from_persona
      (`Assoc
        [
          ("persona_name", `String "probe");
          ("autoboot_enabled", `Bool false);
        ])
  with
  | Error e -> fail ("resolver failed: " ^ e)
  | Ok (_, resolved) ->
      check (option bool) "autoboot_enabled preserved" (Some false)
        (match Yojson.Safe.Util.member "autoboot_enabled" resolved with
         | `Bool value -> Some value
         | _ -> None)

let test_persona_resolver_preserves_canonical_tool_access_and_allowed_paths () =
  with_personas_dir @@ fun personas_dir ->
  let persona_dir = Filename.concat personas_dir "probe" in
  mkdir_p persona_dir;
  write_file
    (Filename.concat persona_dir "profile.json")
    {|
{
  "name": "Probe",
  "keeper": {
    "goal": "test persona keeper"
  }
}
|};
  let expected_tool_access =
    Masc_mcp.Keeper_types.tool_access_to_json
      (Masc_mcp.Keeper_types.Custom [ "masc_status" ])
  in
  match
    Masc_mcp.Keeper_exec_persona.resolved_keeper_args_from_persona
      (`Assoc
        [
          ("persona_name", `String "probe");
          ("allowed_paths", `List [ `String "/tmp/demo" ]);
          ( "tool_access",
            `Assoc
              [
                ("kind", `String "custom");
                ("tools", `List [ `String "masc_status" ]);
              ] );
        ])
  with
  | Error e -> fail ("resolver failed: " ^ e)
  | Ok (_, resolved) ->
      check string "tool_access preserved"
        (Yojson.Safe.to_string expected_tool_access)
        (Yojson.Safe.to_string (Yojson.Safe.Util.member "tool_access" resolved));
      check (list string) "allowed_paths preserved" [ "/tmp/demo" ]
        (match Yojson.Safe.Util.member "allowed_paths" resolved with
         | `List items ->
             List.filter_map
               (function `String value -> Some value | _ -> None)
               items
         | _ -> []);
      check bool "tool_preset omitted with canonical tool_access" false
        (match Yojson.Safe.Util.member "tool_preset" resolved with
         | `String _ -> true
         | _ -> false)

let test_persona_resolver_renders_durable_keeper_toml () =
  let resolved =
    `Assoc
      [
        ("name", `String "probe-keeper");
        ("persona_name", `String "probe");
        ("goal", `String "line1\nline2");
        ("short_goal", `String "short");
        ("mid_goal", `String "mid");
        ("long_goal", `String "long");
        ("instructions", `String "quote: \"ok\"");
        ("policy_voice_enabled", `Bool false);
        ("autoboot_enabled", `Bool false);
        ("mention_targets", `List [ `String "probe"; `String "@probe" ]);
        ("proactive_enabled", `Bool true);
        ("proactive_idle_sec", `Int 300);
        ("proactive_cooldown_sec", `Int 60);
        ("allowed_paths", `List [ `String "/tmp/probe" ]);
        ( "tool_access",
          `Assoc
            [
              ("kind", `String "preset");
              ("preset", `String "research");
              ("also_allow", `List [ `String "masc_status" ]);
            ] );
        ("tool_denylist", `List [ `String "masc_keeper_reset" ]);
      ]
  in
  match KEP.render_keeper_toml_from_resolved_args resolved with
  | Error e -> fail ("render failed: " ^ e)
  | Ok toml -> (
      match TL.parse_toml toml with
      | Error e -> fail ("rendered TOML did not parse: " ^ e)
      | Ok doc -> (
          match KTP.profile_defaults_of_toml doc with
          | Error e -> fail ("rendered TOML did not load: " ^ e)
          | Ok defaults ->
              check (option string) "name" (Some "probe-keeper")
                (TL.toml_string_opt doc "keeper.name");
              check (option string) "persona_name" (Some "probe")
                defaults.persona_name;
              check (option string) "goal" (Some "line1\nline2")
                defaults.goal;
              check (option string) "instructions"
                (Some "quote: \"ok\"") defaults.instructions;
              check (option bool) "autoboot" (Some false)
                defaults.autoboot_enabled;
              check (list string) "mention targets"
                [ "probe"; "@probe" ] defaults.mention_targets;
              check (option (list string)) "allowed_paths"
                (Some [ "/tmp/probe" ]) defaults.allowed_paths;
              check (option string) "tool_preset" (Some "research")
                defaults.tool_preset;
              check (option (list string)) "tool_also_allow"
                (Some [ "masc_status" ]) defaults.tool_also_allow;
              check (option (list string)) "tool_denylist"
                (Some [ "masc_keeper_reset" ]) defaults.tool_denylist))

let test_persona_resolver_rejects_custom_tool_access_durable_toml () =
  let resolved =
    `Assoc
      [
        ("name", `String "probe-keeper");
        ("persona_name", `String "probe");
        ("goal", `String "test");
        ("mention_targets", `List [ `String "probe" ]);
        ( "tool_access",
          `Assoc
            [
              ("kind", `String "custom");
              ("tools", `List [ `String "masc_status" ]);
            ] );
      ]
  in
  match KEP.render_keeper_toml_from_resolved_args resolved with
  | Ok _ -> fail "expected custom tool_access durable TOML rejection"
  | Error e ->
      check bool "mentions custom tool_access" true
        (contains_substring e "tool_access.kind=custom")

let authoring_minimal_profile =
  `Assoc
    [
      ("name", `String "Probe");
      ("role", `String "research critic");
      ("trait", `String "skeptical and concise");
      ( "keeper",
        `Assoc
          [
            ("goal", `String "Find weak assumptions and make concrete tasks.");
          ] );
    ]

let test_persona_authoring_schema_explains_effects () =
  let json = KPA.schema_json () in
  let rendered = Yojson.Safe.to_string json in
  check bool "documents keeper.goal" true
    (contains_substring rendered "keeper.goal");
  check bool "omits legacy tool_preset" false
    (contains_substring rendered "tool_preset");
  check bool "documents archetype axes" true
    (contains_substring rendered "archetype_axes");
  check bool "documents alignment axis" true
    (contains_substring rendered "alignment");
  check bool "documents choice effects" true
    (contains_substring rendered "choice_effects");
  check bool "documents generated fields" true
    (contains_substring rendered "generated_fields");
  check string "draft tool" "masc_persona_generate"
    (Yojson.Safe.Util.member "authoring_flow" json
     |> Yojson.Safe.Util.member "draft_tool"
     |> Yojson.Safe.Util.to_string);
  check string "save tool" "masc_persona_save"
    (Yojson.Safe.Util.member "authoring_flow" json
     |> Yojson.Safe.Util.member "save_tool"
     |> Yojson.Safe.Util.to_string)

let test_persona_authoring_social_model_choices_follow_variant_ssot () =
  let json = KPA.schema_json () in
  let choices =
    Yojson.Safe.Util.member "choice_sets" json
    |> Yojson.Safe.Util.member "social_model"
    |> Yojson.Safe.Util.to_list
    |> List.map Yojson.Safe.Util.to_string
  in
  check (list string) "persona schema social_model choices"
    Masc_mcp.Keeper_social_model.valid_model_id_strings
    choices;
  check (list string) "profile parser social_model choices"
    Masc_mcp.Keeper_social_model.valid_model_id_strings
    KTP.valid_social_model_strings

let test_persona_authoring_allowed_keeper_fields_follow_catalog () =
  let json = KPA.schema_json () in
  let keeper_prefix = "keeper." in
  let keeper_fields =
    Yojson.Safe.Util.member "field_catalog" json
    |> Yojson.Safe.Util.to_list
    |> List.filter_map (fun entry ->
           let path =
             Yojson.Safe.Util.member "path" entry |> Yojson.Safe.Util.to_string
           in
           if String.starts_with ~prefix:keeper_prefix path
           then
             Some
               (String.sub
                  path
                  (String.length keeper_prefix)
                  (String.length path - String.length keeper_prefix))
           else None)
    |> List.sort String.compare
  in
  check (list string) "allowed keeper fields follow schema catalog" keeper_fields
    (List.sort String.compare KPA.allowed_keeper_fields)

let test_persona_authoring_axes_validate () =
  let args =
    `Assoc
      [
        ("alignment", `String "Chaotic");
        ("risk_posture", `String "high-autonomy");
      ]
  in
  match KPA.selected_archetype_axes_from_args args with
  | Error e -> fail e
  | Ok axes ->
      check string "alignment normalized" "chaotic"
        (Yojson.Safe.Util.member "alignment" (KPA.archetype_axes_to_json axes)
         |> Yojson.Safe.Util.to_string);
      let selected_effects = KPA.selected_archetype_effects_to_json axes in
      let rendered_effects = Yojson.Safe.to_string selected_effects in
      check bool "selected effects include alignment" true
        (contains_substring rendered_effects "alignment");
      check bool "selected effects omit default preset" false
        (contains_substring rendered_effects "default_tool_preset");
      check bool "selected effects expose generated fields" true
        (contains_substring rendered_effects "keeper.instructions")

let test_persona_authoring_axes_reject_unknown_choices () =
  match
    KPA.selected_archetype_axes_from_args
      (`Assoc [ ("alignment", `String "evil") ])
  with
  | Ok _ -> fail "expected invalid alignment rejection"
  | Error e ->
      check bool "mentions invalid alignment" true
        (contains_substring e "invalid alignment");
      check bool "mentions allowed values" true (contains_substring e "helpful")

let test_persona_authoring_normalizes_keeper_defaults () =
  match KPA.normalize_profile ~handle:"probe" authoring_minimal_profile with
  | Error e -> fail e
  | Ok json ->
      let keeper = Yojson.Safe.Util.member "keeper" json in
      check string "handle written" "probe"
        (Yojson.Safe.Util.member "handle" json |> Yojson.Safe.Util.to_string);
      check string "goal preserved"
        "Find weak assumptions and make concrete tasks."
        (Yojson.Safe.Util.member "goal" keeper |> Yojson.Safe.Util.to_string);
      check string "short_goal defaults to goal"
        "Find weak assumptions and make concrete tasks."
        (Yojson.Safe.Util.member "short_goal" keeper
         |> Yojson.Safe.Util.to_string);
      check (list string) "mention target defaults to handle" [ "probe" ]
        (Yojson.Safe.Util.member "mention_targets" keeper
         |> Yojson.Safe.Util.to_list
         |> List.map Yojson.Safe.Util.to_string);
      check bool "legacy tool_preset omitted" false
        (match Yojson.Safe.Util.member "tool_preset" keeper with
         | `String _ -> true
         | _ -> false)

let test_persona_authoring_rejects_unknown_keeper_fields () =
  let profile =
    `Assoc
      [
        ( "keeper",
          `Assoc
            [
              ("goal", `String "test");
              ("evil_chaos_knob", `String "11");
            ] );
      ]
  in
  match KPA.normalize_profile ~handle:"probe" profile with
  | Ok _ -> fail "expected unknown keeper field rejection"
  | Error e ->
      check bool "mentions unknown keeper fields" true
        (contains_substring e "unknown keeper fields");
      check bool "mentions schema tool" true
        (contains_substring e "masc_persona_schema")

let test_persona_authoring_rejects_operator_todo_placeholders () =
  let profile =
    `Assoc
      [
        ("name", `String "OPERATOR_TODO: display label");
        ( "keeper",
          `Assoc
            [
              ("goal", `String "Find weak assumptions and make concrete tasks.");
            ] );
      ]
  in
  match KPA.normalize_profile ~handle:"probe" profile with
  | Ok _ -> fail "expected OPERATOR_TODO placeholder rejection"
  | Error e ->
      check bool "mentions placeholder marker" true
        (contains_substring e "OPERATOR_TODO");
      check bool "mentions replace action" true
        (contains_substring e "replace placeholders")

let test_persona_authoring_save_dry_run_does_not_write () =
  with_personas_dir @@ fun personas_dir ->
  match KPA.save_persona ~dry_run:true ~handle:"probe" authoring_minimal_profile with
  | Error e -> fail e
  | Ok result ->
      check string "root" personas_dir result.personas_root;
      check bool "profile not written" false (Sys.file_exists result.profile_path)

let test_persona_authoring_save_writes_profile_and_loader_reads_it () =
  with_personas_dir @@ fun _personas_dir ->
  match KPA.save_persona ~handle:"probe" authoring_minimal_profile with
  | Error e -> fail e
  | Ok result ->
      check bool "profile written" true (Sys.file_exists result.profile_path);
      (match KTP.load_persona_summary "probe" with
       | None -> fail "saved persona summary not loaded"
       | Some summary ->
           check string "loaded persona name" "probe" summary.persona_name;
           check string "loaded display" "Probe" summary.display_name;
           check bool "has keeper defaults" true summary.has_keeper_defaults)

(* ================================================================ *)
(* Unknown-key detection                                             *)
(* ================================================================ *)

let test_detect_unknown_keys_empty_when_all_canonical () =
  let input = {|
[keeper]
goal = "canonical"
mention_targets = ["a", "b"]
autoboot_enabled = false
cascade_name = "big_three"
github_identity = "anyang-keepers"
git_identity_mode = "keeper_alias"
active_goal_ids = ["goal-runtime"]

[keeper.tool_access]
kind = "preset"
preset = "coding"
also_allow = ["x"]
|} in
  match TL.parse_toml input with
  | Error e -> fail e
  | Ok doc ->
    let unknown = KTP.detect_unknown_keeper_toml_keys doc in
    check (list string) "no unknown keys" [] unknown

let test_detect_unknown_keys_flags_legacy_dead_config () =
  let input = {|
[keeper]
goal = "g"
legacy_scope = "current"
scope_kind = "local"
mention_targets = ["a"]
|} in
  match TL.parse_toml input with
  | Error e -> fail e
  | Ok doc ->
    let unknown = KTP.detect_unknown_keeper_toml_keys doc in
    check (list string) "surfaces dead config"
      ["keeper.legacy_scope"; "keeper.scope_kind"] unknown

let test_detect_unknown_keys_accepts_tool_access_table () =
  let input = {|
[keeper]
goal = "g"

[keeper.tool_access]
kind = "preset"
preset = "coding"
|} in
  match TL.parse_toml input with
  | Error e -> fail e
  | Ok doc ->
    let unknown = KTP.detect_unknown_keeper_toml_keys doc in
    check (list string) "tool_access TOML table is canonical" [] unknown

let test_shared_memory_scope_is_canonical_toml () =
  let input = {|
[keeper]
goal = "g"
shared_memory_scope = "room"
|} in
  match TL.parse_toml input with
  | Error e -> fail e
  | Ok doc ->
    let unknown = KTP.detect_unknown_keeper_toml_keys doc in
    check (list string) "shared_memory_scope is canonical" [] unknown;
    match KTP.profile_defaults_of_toml doc with
    | Error e -> fail e
    | Ok d ->
      check (option string) "shared_memory_scope parsed"
        (Some "room") d.KTP.shared_memory_scope

let test_shared_memory_scope_rejects_invalid_value () =
  let input = {|
[keeper]
goal = "g"
shared_memory_scope = "global"
|} in
  match TL.parse_toml input with
  | Error e -> fail e
  | Ok doc ->
    match KTP.profile_defaults_of_toml doc with
    | Ok _ -> fail "expected invalid shared_memory_scope to be rejected"
    | Error e ->
      check bool "mentions shared_memory_scope" true
        (contains_substring e "shared_memory_scope")

let test_oas_env_parses_allowed_keys () =
  let input = {|
[keeper]
persona_name = "analyst"
[keeper.oas_env]
OAS_CLAUDE_STRICT_MCP = "1"
OAS_GEMINI_NO_MCP = "1"
OAS_CODEX_CONFIG = "mcp_servers={}"
|} in
  match TL.parse_toml input with
  | Error e -> fail e
  | Ok doc ->
    match KTP.profile_defaults_of_toml doc with
    | Error e -> fail e
    | Ok d ->
      check int "oas_env count" 3 (List.length d.oas_env);
      check string "strict_mcp value"
        "1" (List.assoc "OAS_CLAUDE_STRICT_MCP" d.oas_env);
      check string "no_mcp value"
        "1" (List.assoc "OAS_GEMINI_NO_MCP" d.oas_env);
      check string "codex_config value"
        "mcp_servers={}" (List.assoc "OAS_CODEX_CONFIG" d.oas_env)

let test_keeper_oas_context_demotes_gemini_no_mcp_to_plan () =
  let defaults =
    { KTP.empty_keeper_profile_defaults with
      oas_env = [ "OAS_GEMINI_NO_MCP", "1" ];
    }
  in
  let ctx = KTP.keeper_oas_context_of_defaults defaults in
  check bool "no_mcp derived" true ctx.gemini_mcp_disabled;
  check (option string) "approval mode derived" (Some "plan")
    ctx.gemini_approval_mode;
  check bool "approval marked derived" true ctx.gemini_approval_mode_derived

let test_keeper_oas_context_preserves_explicit_gemini_approval_mode () =
  let defaults =
    { KTP.empty_keeper_profile_defaults with
      oas_env =
        [
          "OAS_GEMINI_NO_MCP", "1";
          "OAS_GEMINI_APPROVAL_MODE", "yolo";
        ];
    }
  in
  let ctx = KTP.keeper_oas_context_of_defaults defaults in
  check (option string) "explicit mode preserved" (Some "yolo")
    ctx.gemini_approval_mode;
  check bool "explicit mode not marked derived" false
    ctx.gemini_approval_mode_derived

let test_oas_env_drops_non_oas_prefix () =
  (* Guards against ambient env injection via keeper TOML: keys that
     don't start with OAS_(CLAUDE|CODEX|GEMINI)_ are silently dropped. *)
  let input = {|
[keeper]
persona_name = "analyst"
[keeper.oas_env]
PATH = "/evil/bin:/usr/bin"
LD_PRELOAD = "/tmp/hack.so"
OAS_CLAUDE_STRICT_MCP = "1"
RANDOM_VAR = "nope"
|} in
  match TL.parse_toml input with
  | Error e -> fail e
  | Ok doc ->
    match KTP.profile_defaults_of_toml doc with
    | Error e -> fail e
    | Ok d ->
      check int "only OAS_* survives" 1 (List.length d.oas_env);
      check bool "PATH dropped" false (List.mem_assoc "PATH" d.oas_env);
      check bool "LD_PRELOAD dropped" false (List.mem_assoc "LD_PRELOAD" d.oas_env);
      check bool "RANDOM_VAR dropped" false (List.mem_assoc "RANDOM_VAR" d.oas_env)

let test_oas_env_absent_means_empty () =
  let input = {|
[keeper]
persona_name = "analyst"
|} in
  match TL.parse_toml input with
  | Error e -> fail e
  | Ok doc ->
    match KTP.profile_defaults_of_toml doc with
    | Error e -> fail e
    | Ok d ->
      check int "no table → empty list" 0 (List.length d.oas_env)

let test_oas_env_not_flagged_as_unknown () =
  let input = {|
[keeper]
persona_name = "analyst"
[keeper.oas_env]
OAS_CLAUDE_STRICT_MCP = "1"
|} in
  match TL.parse_toml input with
  | Error e -> fail e
  | Ok doc ->
    let unknown = KTP.detect_unknown_keeper_toml_keys doc in
    check int "oas_env keys whitelisted" 0 (List.length unknown)

let test_oas_env_coerces_bool_to_string () =
  (* Bools in TOML become "1"/"0" string so OAS_*_STRICT_MCP = true works. *)
  let input = {|
[keeper]
persona_name = "analyst"
[keeper.oas_env]
OAS_CLAUDE_STRICT_MCP = true
OAS_CODEX_SKIP_GIT = false
|} in
  match TL.parse_toml input with
  | Error e -> fail e
  | Ok doc ->
    match KTP.profile_defaults_of_toml doc with
    | Error e -> fail e
    | Ok d ->
      check string "true → 1" "1"
        (List.assoc "OAS_CLAUDE_STRICT_MCP" d.oas_env);
      check string "false → 0" "0"
        (List.assoc "OAS_CODEX_SKIP_GIT" d.oas_env)

let test_detect_unknown_keys_flags_also_allow_alias () =
  let input = {|
[keeper]
goal = "g"
also_allow = ["x"]
|} in
  match TL.parse_toml input with
  | Error e -> fail e
  | Ok doc ->
    let unknown = KTP.detect_unknown_keeper_toml_keys doc in
    check (list string) "also_allow alias is stale drift"
      ["keeper.also_allow"] unknown

let test_load_keeper_toml_captures_unknown_keys_on_profile () =
  let tmp = Filename.temp_file "keeper_unknown" ".toml" in
  let oc = open_out tmp in
  output_string oc {|[keeper]
name = "scout"
goal = "g"
legacy_scope = "removed"
typo_field = 42
|};
  close_out oc;
  match KTP.load_keeper_toml tmp with
  | Error e -> Sys.remove tmp; fail e
  | Ok (_, defaults) ->
    Sys.remove tmp;
    check (slist string String.compare)
      "unknown keys captured on profile defaults"
      [ "keeper.legacy_scope"; "keeper.typo_field" ]
      defaults.KTP.unknown_toml_keys

let test_unknown_toml_warning_key_normalizes_unknown_order () =
  let path =
    Printf.sprintf "/tmp/keeper-warning-order-%06x.toml" (Random.bits ())
  in
  check bool "first ordered warning emits" true
    (KTP.warn_unknown_keeper_toml_keys_once ~path
       [ "keeper.zeta"; "keeper.alpha" ]);
  check bool "same set in different order is deduped" false
    (KTP.warn_unknown_keeper_toml_keys_once ~path
       [ "keeper.alpha"; "keeper.zeta" ])

let string_starts_with ~prefix value =
  let prefix_len = String.length prefix in
  String.length value >= prefix_len
  && String.sub value 0 prefix_len = prefix

let test_unknown_toml_warning_key_cache_is_bounded () =
  let prefix =
    Printf.sprintf "keeper-warning-bound-%06x-" (Random.bits ())
  in
  for idx = 0 to KTP.unknown_keeper_toml_warning_key_limit + 3 do
    ignore
      (KTP.warn_unknown_keeper_toml_keys_once
         ~path:("/tmp/" ^ prefix ^ string_of_int idx ^ ".toml")
         [ "keeper.typo_field" ])
  done;
  let matching =
    Atomic.get KTP.unknown_keeper_toml_warning_keys
    |> List.filter (string_starts_with ~prefix)
  in
  check bool "warning cache stays bounded for this prefix" true
    (List.length matching <= KTP.unknown_keeper_toml_warning_key_limit)

(* ================================================================ *)
(* Test suite                                                        *)
(* ================================================================ *)

let () =
  run "Keeper TOML Loader"
    [
      ( "parser",
        [
          test_case "empty" `Quick test_parse_empty;
          test_case "comments and blanks" `Quick test_parse_comments_and_blanks;
          test_case "string value" `Quick test_parse_string_value;
          test_case "string escapes" `Quick test_parse_string_escapes;
          test_case "int value" `Quick test_parse_int_value;
          test_case "negative int" `Quick test_parse_negative_int;
          test_case "float value" `Quick test_parse_float_value;
          test_case "bool values" `Quick test_parse_bool_values;
          test_case "string array" `Quick test_parse_string_array;
          test_case "string array escaped quotes" `Quick
            test_parse_string_array_escaped_quotes;
          test_case "empty array" `Quick test_parse_empty_array;
          test_case "table" `Quick test_parse_table;
          test_case "inline comment" `Quick test_parse_inline_comment;
          test_case "multiline basic string" `Quick test_parse_multiline_basic_string;
          test_case "multiline single line" `Quick test_parse_multiline_single_line;
          test_case "multiline empty" `Quick test_parse_multiline_empty;
          test_case "multiline unterminated" `Quick test_parse_multiline_unterminated;
          test_case "multiline with escapes" `Quick test_parse_multiline_with_escapes;
          test_case "multiline with values after" `Quick test_parse_multiline_with_values_after;
          test_case "multiline preserves leading spaces" `Quick
            test_parse_multiline_preserves_leading_spaces;
          test_case "multiline allows escaped triple quotes" `Quick
            test_parse_multiline_allows_escaped_triple_quotes;
          test_case "multiline rejects trailing garbage" `Quick
            test_parse_multiline_rejects_trailing_garbage;
          test_case "multiline normalizes CRLF" `Quick
            test_parse_multiline_normalizes_crlf;
          test_case "multiline single trailing quote inline" `Quick
            test_parse_multiline_single_trailing_quote_inline;
          test_case "multiline double trailing quote inline" `Quick
            test_parse_multiline_double_trailing_quote_inline;
          test_case "multiline trailing quote on close line" `Quick
            test_parse_multiline_trailing_quote_on_close_line;
          test_case "multiline line-ending backslash" `Quick
            test_parse_multiline_line_ending_backslash;
          test_case "error: unterminated table" `Quick test_parse_error_unterminated_table;
          test_case "error: no equals" `Quick test_parse_error_no_equals;
          test_case "multiline array" `Quick test_parse_multiline_array;
          test_case "multiline array no trailing comma" `Quick
            test_parse_multiline_array_no_trailing_comma;
          test_case "multiline array with comments" `Quick
            test_parse_multiline_array_with_comments;
          test_case "multiline array empty" `Quick test_parse_multiline_array_empty;
          test_case "multiline array single element" `Quick
            test_parse_multiline_array_single_element;
          test_case "multiline array unterminated" `Quick
            test_parse_multiline_array_unterminated;
          test_case "multiline array comment-only lines" `Quick
            test_parse_multiline_array_comment_only_lines;
          test_case "multiline array bracket in string" `Quick
            test_parse_multiline_array_bracket_in_string;
        ] );
      ( "profile_defaults",
        [
          test_case "minimal" `Quick test_profile_minimal;
          test_case "full" `Quick test_profile_full;
          test_case "rejects partial proactive interval pair" `Quick
            test_profile_rejects_partial_proactive_interval_pair;
          test_case "rejects invalid social_model" `Quick
            test_profile_rejects_invalid_social_model;
          test_case "rejects invalid git_identity_mode" `Quick
            test_profile_rejects_invalid_git_identity_mode;
          test_case "rejects removed model keys" `Quick
            test_profile_rejects_removed_model_keys;
          test_case "rejects removed also_allow alias" `Quick
            test_profile_rejects_removed_also_allow_alias;
          test_case "rejects removed initiative keys" `Quick
            test_profile_rejects_removed_initiative_keys;
          test_case "legacy allowed_providers ignored" `Quick
            test_profile_ignores_legacy_allowed_providers;
          test_case "legacy keeper cascade alias normalized" `Quick
            test_profile_normalizes_legacy_keeper_cascade_alias;
          test_case "max_turns overrides parsed and applied" `Quick
            test_profile_max_turns_overrides;
          test_case "max_turns defaults when absent" `Quick
            test_profile_max_turns_defaults_when_absent;
          test_case "max_turns accepts raised ceiling" `Quick
            test_profile_max_turns_accepts_raised_ceiling;
          test_case "max_turns rejects out-of-range values" `Quick
            test_profile_max_turns_rejects_out_of_range;
        ] );
      ( "unknown_keys",
        [
          test_case "empty when all canonical" `Quick
            test_detect_unknown_keys_empty_when_all_canonical;
          test_case "flags legacy dead config" `Quick
            test_detect_unknown_keys_flags_legacy_dead_config;
          test_case "accepts tool_access table" `Quick
            test_detect_unknown_keys_accepts_tool_access_table;
          test_case "accepts shared_memory_scope" `Quick
            test_shared_memory_scope_is_canonical_toml;
          test_case "rejects invalid shared_memory_scope" `Quick
            test_shared_memory_scope_rejects_invalid_value;
          test_case "also_allow alias flagged" `Quick
            test_detect_unknown_keys_flags_also_allow_alias;
          test_case "oas_env keys not flagged as unknown" `Quick
            test_oas_env_not_flagged_as_unknown;
          test_case "load_keeper_toml captures unknown keys on profile" `Quick
            test_load_keeper_toml_captures_unknown_keys_on_profile;
          test_case "unknown TOML warning key normalizes order" `Quick
            test_unknown_toml_warning_key_normalizes_unknown_order;
          test_case "unknown TOML warning key cache is bounded" `Quick
            test_unknown_toml_warning_key_cache_is_bounded;
        ] );
      ( "oas_env",
        [
          test_case "parses allowed OAS_* keys" `Quick
            test_oas_env_parses_allowed_keys;
          test_case "demotes Gemini no-MCP runs to plan approval mode" `Quick
            test_keeper_oas_context_demotes_gemini_no_mcp_to_plan;
          test_case "preserves explicit Gemini approval mode" `Quick
            test_keeper_oas_context_preserves_explicit_gemini_approval_mode;
          test_case "drops non-OAS_* keys (ambient injection guard)" `Quick
            test_oas_env_drops_non_oas_prefix;
          test_case "empty when table absent" `Quick
            test_oas_env_absent_means_empty;
          test_case "coerces bool → \"1\"/\"0\" string" `Quick
            test_oas_env_coerces_bool_to_string;
        ] );
      ( "file_loading",
        [
          test_case "load from file" `Quick test_load_from_file;
          test_case "name from filename" `Quick test_load_name_from_filename;
          test_case "invalid name" `Quick test_load_invalid_name;
        ] );
      ( "discovery",
        [
          test_case "empty dir" `Quick test_discover_empty_dir;
          test_case "with files" `Quick test_discover_with_files;
          test_case "nonexistent dir" `Quick test_discover_nonexistent_dir;
          test_case "skips bad files" `Quick test_discover_skips_bad_files;
          test_case "persona resolver defaults to research tool_access" `Quick
            test_persona_resolver_defaults_to_research_tool_access;
          test_case "persona resolver rejects OPERATOR_TODO profile" `Quick
            test_persona_resolver_rejects_operator_todo_profile;
          test_case "persona resolver reports placeholder defaults source" `Quick
            test_persona_resolver_reports_placeholder_defaults_source;
          test_case "persona resolver rejects placeholder in resolved payload" `Quick
            test_persona_resolver_rejects_placeholder_in_resolved_payload;
          test_case "persona resolver ignores non-public social_model arg" `Quick
            test_persona_resolver_ignores_non_public_social_model_arg;
          test_case "persona resolver preserves autoboot_enabled arg" `Quick
            test_persona_resolver_preserves_autoboot_enabled_arg;
          test_case "persona resolver preserves canonical tool_access and allowed_paths" `Quick
            test_persona_resolver_preserves_canonical_tool_access_and_allowed_paths;
          test_case "persona resolver renders durable keeper TOML" `Quick
            test_persona_resolver_renders_durable_keeper_toml;
          test_case "persona resolver rejects custom tool_access durable TOML" `Quick
            test_persona_resolver_rejects_custom_tool_access_durable_toml;
          test_case "persona authoring schema explains effects" `Quick
            test_persona_authoring_schema_explains_effects;
          test_case "persona authoring social_model choices follow variant SSOT" `Quick
            test_persona_authoring_social_model_choices_follow_variant_ssot;
          test_case "persona authoring allowed keeper fields follow catalog" `Quick
            test_persona_authoring_allowed_keeper_fields_follow_catalog;
          test_case "persona authoring axes validate" `Quick
            test_persona_authoring_axes_validate;
          test_case "persona authoring axes reject unknown choices" `Quick
            test_persona_authoring_axes_reject_unknown_choices;
          test_case "persona authoring normalizes defaults" `Quick
            test_persona_authoring_normalizes_keeper_defaults;
          test_case "persona authoring rejects unknown keeper fields" `Quick
            test_persona_authoring_rejects_unknown_keeper_fields;
          test_case "persona authoring rejects OPERATOR_TODO placeholders" `Quick
            test_persona_authoring_rejects_operator_todo_placeholders;
          test_case "persona authoring dry-run does not write" `Quick
            test_persona_authoring_save_dry_run_does_not_write;
          test_case "persona authoring save is loader-visible" `Quick
            test_persona_authoring_save_writes_profile_and_loader_reads_it;
        ] );
    ]
