open Alcotest

module TL = Masc_mcp.Keeper_toml_loader
module KTP = Masc_mcp.Keeper_types_profile

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

let with_personas_dir f =
  with_temp_dir "keeper-personas" @@ fun personas_dir ->
  let original = Sys.getenv_opt "MASC_PERSONAS_DIR" in
  Fun.protect
    ~finally:(fun () ->
      (match original with
      | Some value -> Unix.putenv "MASC_PERSONAS_DIR" value
      | None -> Unix.putenv "MASC_PERSONAS_DIR" "");
      Masc_mcp.Config_dir_resolver.reset ())
    (fun () ->
      Unix.putenv "MASC_PERSONAS_DIR" personas_dir;
      Masc_mcp.Config_dir_resolver.reset ();
      f personas_dir)

(* Legacy allowed_providers is accepted for compatibility but ignored.
   Provider ownership now lives with OAS cascade resolution. *)

let test_profile_ignores_legacy_allowed_providers () =
  let input = {|
[keeper]
goal = "test"
allowed_providers = ["Ollama", "GLM"]
cascade_name = "local_only"
|} in
  match TL.parse_toml input with
  | Error e -> fail e
  | Ok doc ->
    (match KTP.profile_defaults_of_toml doc with
     | Error e -> fail e
     | Ok d ->
       check (option string) "cascade preserved"
         (Some "local_only") d.cascade_name)

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
       (* autonomous is capped by reactive global cap, but 3 < env default 15 *)
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
       (* helpers fall back to env defaults (15 and min(global, 2)=2) *)
       check int "effective reactive default" 15
         (KTP.effective_max_turns_per_call d);
       check int "effective autonomous default" 2
         (KTP.effective_max_turns_per_call_scheduled_autonomous d))

let test_profile_max_turns_rejects_out_of_range () =
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
       (* Values are parsed as-is but clamp_max_turns_override rejects them,
          so helpers fall back to env defaults. *)
       check int "out-of-range reactive falls back" 15
         (KTP.effective_max_turns_per_call d);
       check int "zero autonomous falls back" 2
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

let test_persona_resolver_defaults_to_research_tool_preset () =
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
      let tool_preset = Yojson.Safe.Util.member "tool_preset" resolved in
      check string "persona default tool_preset" "research"
        (Yojson.Safe.Util.to_string tool_preset)

let test_persona_resolver_rejects_non_public_social_model_arg () =
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
  | Ok _ -> fail "expected non-public social_model rejection"
  | Error e ->
      check bool "mentions non-public keeper args" true
        (Str.string_match (Str.regexp_string "non-public keeper args") e 0
         || contains_substring e "non-public keeper args");
      check bool "mentions social_model" true (contains_substring e "social_model")

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

(* ================================================================ *)
(* Unknown-key detection                                             *)
(* ================================================================ *)

let test_detect_unknown_keys_empty_when_all_canonical () =
  let input = {|
[keeper]
goal = "canonical"
mention_targets = ["a", "b"]
tool_preset = "coding"
tool_also_allow = ["x"]
autoboot_enabled = false
cascade_name = "big_three"
github_identity = "anyang-keepers"
git_identity_mode = "keeper_alias"
active_goal_ids = ["goal-runtime"]
[keeper.tool_access]
kind = "preset"
preset = "coding"
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
          test_case "max_turns rejects out-of-range values" `Quick
            test_profile_max_turns_rejects_out_of_range;
        ] );
      ( "unknown_keys",
        [
          test_case "empty when all canonical" `Quick
            test_detect_unknown_keys_empty_when_all_canonical;
          test_case "flags legacy dead config" `Quick
            test_detect_unknown_keys_flags_legacy_dead_config;
          test_case "also_allow alias flagged" `Quick
            test_detect_unknown_keys_flags_also_allow_alias;
          test_case "oas_env keys not flagged as unknown" `Quick
            test_oas_env_not_flagged_as_unknown;
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
          test_case "persona profile canonicalizes soul_profile" `Quick
            test_persona_resolver_defaults_to_research_tool_preset;
          test_case "persona resolver rejects non-public social_model arg" `Quick
            test_persona_resolver_rejects_non_public_social_model_arg;
          test_case "persona resolver preserves autoboot_enabled arg" `Quick
            test_persona_resolver_preserves_autoboot_enabled_arg;
          test_case "persona resolver preserves canonical tool_access and allowed_paths" `Quick
            test_persona_resolver_preserves_canonical_tool_access_and_allowed_paths;
        ] );
    ]
