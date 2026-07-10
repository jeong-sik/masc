open Alcotest

module TL = Keeper_toml_loader
module KTP = Masc.Keeper_types_profile
module KEP = Masc.Keeper_tool_persona_runtime
module Runtime = Server_routes_http_runtime

let contains_substring s needle =
  let s_len = String.length s in
  let n_len = String.length needle in
  let rec loop i =
    if i + n_len > s_len then false
    else if String.sub s i n_len = needle then true
    else loop (i + 1)
  in
  if n_len = 0 then true else loop 0

let has_repo_keeper_config root =
  Sys.file_exists (Filename.concat root "config/keepers/base.toml")

let repo_root () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root when has_repo_keeper_config root -> root
  | _ ->
    let rec ascend path =
      if has_repo_keeper_config path then path
      else
        let parent = Filename.dirname path in
        if String.equal parent path then Sys.getcwd () else ascend parent
    in
    ascend (Sys.getcwd ())

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
instructions = "You are a log analyzer."
mention_targets = ["sherlock", "log-analyzer"]
proactive_enabled = true
proactive_idle_sec = 300
proactive_cooldown_sec = 60
autoboot_enabled = false
active_goal_ids = ["goal-runtime", "goal-masc"]
|} in
  match TL.parse_toml input with
  | Error e -> fail e
  | Ok doc ->
    match KTP.profile_defaults_of_toml doc with
    | Error e -> fail e
    | Ok d ->
      check (option string) "persona_name" (Some "analyst") d.persona_name;
      check (option string) "goal" (Some "analyze logs") d.goal;
      check (option string) "instructions" (Some "You are a log analyzer.")
        d.instructions;
      check int "mention_targets" 2 (List.length d.mention_targets);
      check (option bool) "proactive" (Some true) d.proactive_enabled;
      check (option bool) "autoboot_enabled" (Some false) d.autoboot_enabled;
      check (option (list string)) "active_goal_ids"
        (Some [ "goal-runtime"; "goal-masc" ])
        d.active_goal_ids

let test_profile_parses_multimodal_policy () =
  let input = {|
[keeper]
goal = "vision delegation"
multimodal_policy = "delegate"
|} in
  match TL.parse_toml input with
  | Error e -> fail e
  | Ok doc ->
    match KTP.profile_defaults_of_toml doc with
    | Error e -> fail e
    | Ok d ->
      check (option string) "multimodal_policy" (Some "delegate")
        (Option.map KTP.multimodal_policy_to_string d.multimodal_policy)

let test_profile_rejects_invalid_multimodal_policy () =
  let input = {|
[keeper]
goal = "vision delegation"
multimodal_policy = "silent_default"
|} in
  match TL.parse_toml input with
  | Error e -> fail e
  | Ok doc ->
    (match KTP.profile_defaults_of_toml doc with
     | Ok _ -> fail "expected invalid multimodal_policy error"
     | Error msg ->
       check bool "mentions multimodal_policy" true
         (contains_substring msg "invalid multimodal_policy");
       check bool "mentions allowed values" true
         (contains_substring msg "delegate"))

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

let test_profile_rejects_removed_ref_keys () =
  let input = {|
[keeper]
goal = "test"
persona_ref = "base-persona"
runtime_ref = "tool-runtime"
|} in
  match TL.parse_toml input with
  | Error e -> fail e
  | Ok doc ->
      (match KTP.profile_defaults_of_toml doc with
       | Ok _ -> fail "expected removed TOML ref key error"
       | Error msg ->
           check bool "mentions removed persona_ref" true
             (contains_substring msg "keeper.persona_ref");
           check bool "mentions removed runtime_ref" true
             (contains_substring msg "keeper.runtime_ref"))

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

let test_load_keeper_toml_inherits_base_defaults () =
  let tmp_dir = Filename.temp_file "keeper_base_toml" "" in
  Sys.remove tmp_dir;
  Unix.mkdir tmp_dir 0o755;
  let base_path = Filename.concat tmp_dir "base.toml" in
  let child_path = Filename.concat tmp_dir "sangsu.toml" in
  let write_file path content =
    let oc = open_out path in
    output_string oc content;
    close_out oc
  in
  Fun.protect
    ~finally:(fun () ->
      if Sys.file_exists child_path then Sys.remove child_path;
      if Sys.file_exists base_path then Sys.remove base_path;
      if Sys.file_exists tmp_dir then Unix.rmdir tmp_dir)
    (fun () ->
      (* persona⊥{model,runtime}: keeper TOML carries no runtime/model
         selection (assignment lives in runtime.toml [[runtime.assignments]]).
         Base inheritance is still exercised by sandbox_profile/network_mode. *)
      write_file base_path {|
[keeper]
sandbox_profile = "docker"
network_mode = "inherit"
|};
      write_file child_path {|
[keeper]
base = "base.toml"
persona_name = "sangsu"

|};
      match KTP.load_keeper_toml child_path with
      | Error e -> fail e
      | Ok (name, defaults) ->
          check string "name from filename" "sangsu" name;
          check (option string) "base sandbox" (Some "docker")
            (Option.map KTP.sandbox_profile_to_string defaults.sandbox_profile);
          check (option string) "base network" (Some "inherit")
            (Option.map KTP.network_mode_to_string defaults.network_mode);
          ())

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

let test_bundled_keeper_profiles_resolve_prompt_defaults () =
  let repo = repo_root () in
  let original_config = Sys.getenv_opt "MASC_CONFIG_DIR" in
  let original_personas = Sys.getenv_opt "MASC_PERSONAS_DIR" in
  let restore key = function
    | Some value -> Unix.putenv key value
    | None -> Unix.putenv key ""
  in
  Fun.protect
    ~finally:(fun () ->
      restore "MASC_CONFIG_DIR" original_config;
      restore "MASC_PERSONAS_DIR" original_personas;
      Config_dir_resolver.reset ())
    (fun () ->
      Unix.putenv "MASC_CONFIG_DIR" (Filename.concat repo "config");
      Unix.putenv "MASC_PERSONAS_DIR"
        (Filename.concat (Filename.concat repo "config") "personas");
      Config_dir_resolver.reset ();
      let keepers_dir = Filename.concat repo "config/keepers" in
      Sys.readdir keepers_dir
      |> Array.to_list
      |> List.filter (fun file ->
           Filename.check_suffix file ".toml"
           && not (String.equal file "base.toml"))
      |> List.iter (fun file ->
           let path = Filename.concat keepers_dir file in
           let name = Filename.chop_extension file in
           match KTP.load_keeper_profile_defaults_result name with
           | Error e -> fail (Printf.sprintf "%s failed to resolve: %s" path e)
           | Ok _defaults -> ()))

let test_bundled_issue_king_uses_local_sandbox () =
  let repo = repo_root () in
  Fun.protect
    ~finally:(fun () -> Config_dir_resolver.reset ())
    (fun () ->
      with_env_restore [ "MASC_CONFIG_DIR"; "MASC_PERSONAS_DIR" ] (fun () ->
          Unix.putenv "MASC_CONFIG_DIR" (Filename.concat repo "config");
          Unix.putenv "MASC_PERSONAS_DIR"
            (Filename.concat (Filename.concat repo "config") "personas");
          Config_dir_resolver.reset ();
          match KTP.load_keeper_profile_defaults_result "issue_king" with
          | Error e -> fail (Printf.sprintf "issue_king failed to resolve: %s" e)
          | Ok defaults ->
            check (option string) "issue_king sandbox" (Some "local")
              (Option.map KTP.sandbox_profile_to_string defaults.sandbox_profile);
            check (option string) "issue_king network" (Some "inherit")
              (Option.map KTP.network_mode_to_string defaults.network_mode)))

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
      (* OCaml 5.5 adds [Unix.unsetenv], but the supported 5.4 floor used here
         does not expose it. Config_dir_resolver normalizes empty env values to
         [None], so this restores the effective resolver state for these tests. *)
      Unix.putenv name ""

let with_personas_dir f =
  with_temp_dir "keeper-personas" @@ fun personas_dir ->
  let original = Sys.getenv_opt "MASC_PERSONAS_DIR" in
  Fun.protect
    ~finally:(fun () ->
      restore_env "MASC_PERSONAS_DIR" original;
      Config_dir_resolver.reset ())
    (fun () ->
      Unix.putenv "MASC_PERSONAS_DIR" personas_dir;
      Config_dir_resolver.reset ();
      f personas_dir)

let with_config_dir f =
  with_temp_dir "keeper-config" @@ fun config_dir ->
  let original = Sys.getenv_opt "MASC_CONFIG_DIR" in
  Fun.protect
    ~finally:(fun () ->
      restore_env "MASC_CONFIG_DIR" original;
      Config_dir_resolver.reset ())
    (fun () ->
      Unix.putenv "MASC_CONFIG_DIR" config_dir;
      Config_dir_resolver.reset ();
      f config_dir)

let test_profile_defaults_materializable_for_name_uses_base_path () =
  let original_config = Sys.getenv_opt "MASC_CONFIG_DIR" in
  let original_personas = Sys.getenv_opt "MASC_PERSONAS_DIR" in
  let original_base_path = Sys.getenv_opt "MASC_BASE_PATH" in
  Fun.protect
    ~finally:(fun () ->
      restore_env "MASC_CONFIG_DIR" original_config;
      restore_env "MASC_PERSONAS_DIR" original_personas;
      restore_env "MASC_BASE_PATH" original_base_path;
      Config_dir_resolver.reset ())
    (fun () ->
      Unix.putenv "MASC_CONFIG_DIR" "";
      Unix.putenv "MASC_PERSONAS_DIR" "";
      Unix.putenv "MASC_BASE_PATH" "";
      Config_dir_resolver.reset ();
      with_temp_dir "keeper-materializable" @@ fun base_path ->
      let config_dir =
        Filename.concat (Filename.concat base_path ".masc") "config"
      in
      let keepers_dir = Filename.concat config_dir "keepers" in
      mkdir_p keepers_dir;
      write_file (Filename.concat config_dir "runtime.toml") "";
      write_file
        (Filename.concat keepers_dir "runtime.toml")
        "[keeper]\nautoboot_enabled = true\ninstructions = \"runtime keeper\"\n";
      write_file
        (Filename.concat keepers_dir "template.toml")
        "[keeper]\ninstructions = \"loader-only template\"\n";
      check bool
        "explicit autoboot keeper is materializable"
        true
        (KTP.keeper_profile_defaults_materializable_for_name ~base_path
           "runtime");
      check bool
        "loader-only template is not materializable"
        false
        (KTP.keeper_profile_defaults_materializable_for_name ~base_path
           "template"))

(* persona⊥{model,runtime}: keeper TOML no longer carries a runtime/model
   selection; a [keeper.runtime_id] (or legacy [keeper.model]) key is rejected
   at load, pointing the operator at runtime.toml [[runtime.assignments]]. *)
let test_profile_rejects_runtime_id_key () =
  let input = {|
[keeper]
goal = "test"
runtime_id = "oas-coding_first"
|} in
  match TL.parse_toml input with
  | Error e -> fail e
  | Ok doc ->
    (match KTP.profile_defaults_of_toml doc with
     | Ok _ -> fail "expected error: keeper.runtime_id is removed"
     | Error _ -> ())

let test_profile_rejects_model_key () =
  let input = {|
[keeper]
goal = "test"
model = "oas-coding_first"
|} in
  match TL.parse_toml input with
  | Error e -> fail e
  | Ok doc ->
    (match KTP.profile_defaults_of_toml doc with
     | Ok _ -> fail "expected error: keeper.model is removed"
     | Error _ -> ())

let test_persona_resolver_omits_unspecified_tool_access () =
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
    KEP.resolved_keeper_args_from_persona
      (`Assoc [ ("persona_name", `String "probe") ])
  with
  | Error e -> fail ("resolver failed: " ^ e)
  | Ok (_, resolved) ->
      let tool_access = Yojson.Safe.Util.member "tool_access" resolved in
      (match tool_access with
       | `Null -> ()
       | _ -> fail "unspecified tool_access should be omitted")

let test_persona_defaults_load_prompt_fields () =
  with_personas_dir @@ fun personas_dir ->
  let persona_dir = Filename.concat personas_dir "probe" in
  mkdir_p persona_dir;
  write_file
    (Filename.concat persona_dir "profile.json")
    {|
{
  "name": "Probe",
  "keeper": {
    "goal": "test persona keeper",
    "instructions": "legacy instructions"
  }
}
|};
  let defaults = KTP.load_keeper_profile_defaults_from_persona "probe" in
  check (option string) "goal still loads" (Some "test persona keeper")
    defaults.goal;
  check (option string) "instructions load" (Some "legacy instructions")
    defaults.instructions

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
    KEP.resolved_keeper_args_from_persona
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
    Json_util.json_string_list
      ([ "masc_status" ])
  in
  match
    KEP.resolved_keeper_args_from_persona
      (`Assoc
        [
          ("persona_name", `String "probe");
          ("allowed_paths", `List [ `String "/tmp/demo" ]);
          ( "tool_access",
            `List [ `String "masc_status" ] );
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
         | _ -> [])

let test_persona_resolver_renders_durable_keeper_toml () =
  let resolved =
    `Assoc
      [
        ("name", `String "probe-keeper");
        ("persona_name", `String "probe");
        ("goal", `String "line1\nline2");
        ("instructions", `String "quote: \"ok\"");
        ("autoboot_enabled", `Bool false);
        ("mention_targets", `List [ `String "probe"; `String "@probe" ]);
        ("proactive_enabled", `Bool true);
        ("proactive_idle_sec", `Int 300);
        ("proactive_cooldown_sec", `Int 60);
        ("allowed_paths", `List [ `String "/tmp/probe" ]);
        ( "tool_access",
          `List [ `String "masc_status" ] );
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
              check (option (list string)) "tool_access"
                (Some [ "masc_status" ]) defaults.tool_access;
              check (option (list string)) "tool_denylist"
                (Some [ "masc_keeper_reset" ]) defaults.tool_denylist))

let test_persona_resolver_renders_tool_access_array_durable_toml () =
  let resolved =
    `Assoc
      [
        ("name", `String "probe-keeper");
        ("persona_name", `String "probe");
        ("goal", `String "test");
        ("mention_targets", `List [ `String "probe" ]);
        ( "tool_access",
          `List [ `String "masc_status" ] );
      ]
  in
  match KEP.render_keeper_toml_from_resolved_args resolved with
  | Error e -> fail ("render failed: " ^ e)
  | Ok toml ->
      check bool "renders tool_access array" true
        (contains_substring toml "tool_access = [\"masc_status\"]")

(* ================================================================ *)
(* Unknown-key detection                                             *)
(* ================================================================ *)

let test_detect_unknown_keys_empty_when_all_canonical () =
  let input = {|
[keeper]
goal = "canonical"
mention_targets = ["a", "b"]
autoboot_enabled = false
active_goal_ids = ["goal-runtime"]
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

let test_detect_unknown_keys_accepts_tool_access_array () =
  let input = {|
[keeper]
goal = "g"
tool_access = ["masc_status"]
|} in
  match TL.parse_toml input with
  | Error e -> fail e
  | Ok doc ->
    let unknown = KTP.detect_unknown_keeper_toml_keys doc in
    check (list string) "tool_access TOML array is canonical" [] unknown

let test_detect_unknown_keys_accepts_loader_base () =
  let input = {|
[keeper]
goal = "g"
base = "base.toml"
legacy_scope = "removed"
|} in
  match TL.parse_toml input with
  | Error e -> fail e
  | Ok doc ->
    let unknown = KTP.detect_unknown_keeper_toml_keys doc in
    check (list string) "base include is a loader key"
      ["keeper.legacy_scope"] unknown

let test_detect_unknown_keys_flags_provider_health_table () =
  let input = {|
[keeper]
goal = "g"
mention_targets = ["a"]

[provider_health]
ttfrc_degraded_ms = 5000.0
timeout_count_5m_unhealthy = 3
|} in
  match TL.parse_toml input with
  | Error e -> fail e
  | Ok doc ->
    let unknown = KTP.detect_unknown_keeper_toml_keys doc in
    check (list string) "provider health table is not keeper config"
      [ "provider_health.timeout_count_5m_unhealthy"
      ; "provider_health.ttfrc_degraded_ms"
      ]
      (List.sort String.compare unknown)

let test_oas_env_parses_allowed_keys () =
  let input = {|
[keeper]
persona_name = "analyst"
[keeper.oas_env]
OAS_DEFAULT_MODEL = "provider-a/fast"
OAS_MAX_TOKENS_DEFAULT = 16384
MASC_KEEPER_OAS_UNIFIED_MAX_TOKENS = 8192
|} in
  match TL.parse_toml input with
  | Error e -> fail e
  | Ok doc ->
    match KTP.profile_defaults_of_toml doc with
    | Error e -> fail e
    | Ok d ->
      check int "oas_env count" 3 (List.length d.oas_env);
      check string "default model value"
        "provider-a/fast" (List.assoc "OAS_DEFAULT_MODEL" d.oas_env);
      check string "max tokens default value"
        "16384" (List.assoc "OAS_MAX_TOKENS_DEFAULT" d.oas_env);
      check string "unified max tokens value"
        "8192" (List.assoc "MASC_KEEPER_OAS_UNIFIED_MAX_TOKENS" d.oas_env);
      check (option int) "unified max tokens override"
        (Some 8192)
        (KTP.unified_max_tokens_override_of_oas_env d.oas_env)

let test_oas_env_rejects_legacy_unified_max_tokens_alias () =
  let input = {|
[keeper]
persona_name = "analyst"
[keeper.oas_env]
MASC_KEEPER_UNIFIED_MAX_TOKENS = 4096
|} in
  match TL.parse_toml input with
  | Error e -> fail e
  | Ok doc ->
    match KTP.profile_defaults_of_toml doc with
    | Error e -> fail e
    | Ok d ->
      check int "legacy oas_env count" 0 (List.length d.oas_env);
      check bool "legacy unified max tokens dropped" false
        (List.mem_assoc "MASC_KEEPER_UNIFIED_MAX_TOKENS" d.oas_env);
      check (option int) "legacy unified max tokens override"
        None
        (KTP.unified_max_tokens_override_of_oas_env d.oas_env)

let test_oas_env_drops_non_oas_prefix () =
  (* Guards against ambient env injection via keeper TOML: arbitrary keys
     outside the audited allowlist are silently dropped. *)
  let input = {|
[keeper]
persona_name = "analyst"
[keeper.oas_env]
PATH = "/evil/bin:/usr/bin"
LD_PRELOAD = "/tmp/hack.so"
OAS_DEFAULT_MODEL = "provider-a/fast"
MASC_KEEPER_AUTONOMOUS_MAX_TOKENS = "9999"
RANDOM_VAR = "nope"
|} in
  match TL.parse_toml input with
  | Error e -> fail e
  | Ok doc ->
    match KTP.profile_defaults_of_toml doc with
    | Error e -> fail e
    | Ok d ->
      check int "only allowed OAS_* survives" 1 (List.length d.oas_env);
      check string "allowed OAS key survives"
        "provider-a/fast" (List.assoc "OAS_DEFAULT_MODEL" d.oas_env);
      check bool "PATH dropped" false (List.mem_assoc "PATH" d.oas_env);
      check bool "LD_PRELOAD dropped" false (List.mem_assoc "LD_PRELOAD" d.oas_env);
      check bool "unlisted keeper key dropped" false
        (List.mem_assoc "MASC_KEEPER_AUTONOMOUS_MAX_TOKENS" d.oas_env);
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
OAS_DEFAULT_MODEL = "provider-a/fast"
|} in
  match TL.parse_toml input with
  | Error e -> fail e
  | Ok doc ->
    let unknown = KTP.detect_unknown_keeper_toml_keys doc in
    check int "oas_env keys whitelisted" 0 (List.length unknown)

let test_oas_env_coerces_bool_to_string () =
  (* Bools in TOML become "1"/"0" strings for active OAS boolean env knobs. *)
  let input = {|
[keeper]
persona_name = "analyst"
[keeper.oas_env]
OAS_ALLOW_TEST_PROVIDERS = true
OAS_DELTA_CHECKPOINT = false
|} in
  match TL.parse_toml input with
  | Error e -> fail e
  | Ok doc ->
    match KTP.profile_defaults_of_toml doc with
    | Error e -> fail e
    | Ok d ->
      check string "true → 1" "1"
        (List.assoc "OAS_ALLOW_TEST_PROVIDERS" d.oas_env);
      check string "false → 0" "0"
        (List.assoc "OAS_DELTA_CHECKPOINT" d.oas_env)

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
  let unknown_metric () =
    Masc.Otel_metric_store.metric_value_or_zero
      Masc.Otel_metric_store.metric_config_unknown_keys_ignored
      ~labels:[("file_path", tmp)]
      ()
  in
  let before_unknown_metric = unknown_metric () in
  match KTP.load_keeper_toml tmp with
  | Error e -> Sys.remove tmp; fail e
  | Ok (_, defaults) ->
    Sys.remove tmp;
    check (slist string String.compare)
      "unknown keys captured on profile defaults"
      [ "keeper.legacy_scope"; "keeper.typo_field" ]
      defaults.KTP.unknown_toml_keys;
    check (float 0.0001)
      "unknown-key metric increments by key count"
      2.0
      (unknown_metric () -. before_unknown_metric)

let test_keeper_toml_unknown_keys_in_dir_reports_files () =
  with_temp_dir "keeper-unknown-dir" @@ fun dir ->
  write_file (Filename.concat dir "alpha.toml")
    {|
[keeper]
name = "alpha"
goal = "g"
base = "base.toml"
legacy_scope = "removed"
|};
  write_file (Filename.concat dir "beta.toml")
    {|
[keeper]
name = "beta"
goal = "g"
base = "base.toml"
|};
  write_file (Filename.concat dir "bad.toml")
    {|
[keeper
name = "bad"
|};
  let rows = KTP.keeper_toml_unknown_keys_in_dir dir in
  match rows with
  | [ row ] ->
    check string "keeper name" "alpha" row.KTP.keeper_name;
    check string "path"
      (Filename.concat dir "alpha.toml")
      row.KTP.path;
    check (list string) "unknown keys"
      [ "keeper.legacy_scope" ]
      row.KTP.unknown_keys
  | _ ->
    fail
      (Printf.sprintf "expected one unknown-key row, got %d"
         (List.length rows))

let test_health_json_surfaces_keeper_toml_unknown_keys () =
  with_config_dir @@ fun config_dir ->
  let keepers_dir = Filename.concat config_dir "keepers" in
  mkdir_p keepers_dir;
  write_file (Filename.concat keepers_dir "alpha.toml")
    {|
[keeper]
name = "alpha"
goal = "g"
base = "base.toml"
legacy_scope = "removed"
|};
  let unknown_metric () =
    Masc.Otel_metric_store.metric_value_or_zero
      Masc.Otel_metric_store.metric_config_unknown_keys_ignored
      ~labels:[("file_path", Filename.concat keepers_dir "alpha.toml")]
      ()
  in
  let before_unknown_metric = unknown_metric () in
  let request = Httpun.Request.create `GET "/health" in
  let json = Runtime.make_health_json request in
  let open Yojson.Safe.Util in
  let listener = json |> member "http_listener" in
  check bool "health exposes http listener diagnostics" true
    (match listener with `Assoc _ -> true | _ -> false);
  check bool "health listener status is surfaced" true
    (match listener |> member "status" with `String _ -> true | _ -> false);
  check bool "health listener active connections surfaced" true
    (match listener |> member "active_connections" with
    | `Int _ -> true
    | _ -> false);
  check int "unknown key count" 1
    (json |> member "keeper_config_unknown_key_count" |> to_int);
  check string "schema status" "blocked"
    (json |> member "keeper_config_schema_status" |> to_string);
  check bool "schema blocks" true
    (json |> member "keeper_config_schema_blocking" |> to_bool);
  check string "schema terminal reason" "config_unknown_keys"
    (json |> member "keeper_config_schema_terminal_reason" |> to_string);
  check bool "operator action required" true
    (json |> member "keeper_config_operator_action_required" |> to_bool);
  let rows = json |> member "keeper_config_unknown_keys" |> to_list in
  (match rows with
   | [ row ] ->
     check string "keeper" "alpha" (row |> member "keeper" |> to_string);
     check string "terminal reason" "config_unknown_keys"
       (row |> member "terminal_reason" |> to_string);
     check string "severity" "error" (row |> member "severity" |> to_string);
     check bool "row blocks" true (row |> member "blocking" |> to_bool);
     check bool "row operator action required" true
       (row |> member "operator_action_required" |> to_bool);
     check string "row next action" "remove_unknown_keeper_toml_keys"
       (row |> member "next_action" |> to_string);
     check (list string) "unknown keys"
       [ "keeper.legacy_scope" ]
       (row |> member "unknown_keys" |> to_list |> List.map to_string)
   | _ ->
     fail
       (Printf.sprintf "expected one health unknown-key row, got %d"
          (List.length rows)));
  check (float 0.0001) "health scan does not increment warning metric"
    before_unknown_metric (unknown_metric ())

let test_health_json_build_exposes_runtime_binary_identity () =
  with_config_dir @@ fun _config_dir ->
  let request = Httpun.Request.create `GET "/health" in
  let json = Runtime.make_health_json request in
  let open Yojson.Safe.Util in
  let build = json |> member "build" in
  check bool "build binary version populated" true
    (String.length (build |> member "binary_version" |> to_string) > 0);
  check bool "build commit source field present" true
    (match build |> member "commit_source" with `Null | `String _ -> true | _ -> false);
  check bool "build binary commit field present" true
    (match build |> member "binary_commit" with `Null | `String _ -> true | _ -> false);
  check bool "build repo head commit field present" true
    (match build |> member "repo_head_commit" with `Null | `String _ -> true | _ -> false);
  check bool "build executable path populated" true
    (String.length (build |> member "executable_path" |> to_string) > 0);
  check bool "build executable dir populated" true
    (String.length (build |> member "executable_dir" |> to_string) > 0);
  check bool "build repo_root field present" true
    (match build |> member "repo_root" with `Null | `String _ -> true | _ -> false)

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

let test_unknown_toml_warning_key_full_path_not_basename () =
  (* Two files that share the same basename but live in different directories
     must each emit their own warning — using only the basename would incorrectly
     suppress the second warning as a duplicate. *)
  let suffix =
    Printf.sprintf "keeper-warning-path-%06x.toml" (Random.bits ())
  in
  let path_a = "/tmp/dir-a/" ^ suffix in
  let path_b = "/tmp/dir-b/" ^ suffix in
  check bool "first file (dir-a) emits warning" true
    (KTP.warn_unknown_keeper_toml_keys_once ~path:path_a [ "keeper.typo_x" ]);
  check bool "second file (dir-b) also emits warning (different full path)" true
    (KTP.warn_unknown_keeper_toml_keys_once ~path:path_b [ "keeper.typo_x" ])

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
    KTP.current_unknown_keeper_toml_warning_keys ()
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
          test_case "parses multimodal_policy" `Quick
            test_profile_parses_multimodal_policy;
          test_case "rejects invalid multimodal_policy" `Quick
            test_profile_rejects_invalid_multimodal_policy;
          test_case "rejects partial proactive interval pair" `Quick
            test_profile_rejects_partial_proactive_interval_pair;
          test_case "rejects removed model keys" `Quick
            test_profile_rejects_removed_model_keys;
          test_case "rejects removed initiative keys" `Quick
            test_profile_rejects_removed_initiative_keys;
          test_case "rejects removed ref keys" `Quick
            test_profile_rejects_removed_ref_keys;
          test_case "rejects keeper.runtime_id key" `Quick
            test_profile_rejects_runtime_id_key;
          test_case "rejects keeper.model key" `Quick
            test_profile_rejects_model_key;
        ] );
      ( "unknown_keys",
        [
          test_case "empty when all canonical" `Quick
            test_detect_unknown_keys_empty_when_all_canonical;
          test_case "flags legacy dead config" `Quick
            test_detect_unknown_keys_flags_legacy_dead_config;
          test_case "accepts tool_access array" `Quick
            test_detect_unknown_keys_accepts_tool_access_array;
          test_case "accepts loader base include" `Quick
            test_detect_unknown_keys_accepts_loader_base;
          test_case "flags provider_health table as unknown" `Quick
            test_detect_unknown_keys_flags_provider_health_table;
          test_case "oas_env keys not flagged as unknown" `Quick
            test_oas_env_not_flagged_as_unknown;
          test_case "load_keeper_toml captures unknown keys on profile" `Quick
            test_load_keeper_toml_captures_unknown_keys_on_profile;
          test_case "unknown-key scanner reports files" `Quick
            test_keeper_toml_unknown_keys_in_dir_reports_files;
          test_case "health JSON surfaces unknown keys" `Quick
            test_health_json_surfaces_keeper_toml_unknown_keys;
          test_case "health JSON build exposes runtime binary identity" `Quick
            test_health_json_build_exposes_runtime_binary_identity;
          test_case "unknown TOML warning key normalizes order" `Quick
            test_unknown_toml_warning_key_normalizes_unknown_order;
          test_case "unknown TOML warning key uses full path not basename" `Quick
            test_unknown_toml_warning_key_full_path_not_basename;
          test_case "unknown TOML warning key cache is bounded" `Quick
            test_unknown_toml_warning_key_cache_is_bounded;
        ] );
      ( "oas_env",
        [
          test_case "parses allowed OAS_* keys" `Quick
            test_oas_env_parses_allowed_keys;
          test_case "rejects legacy unified max tokens alias" `Quick
            test_oas_env_rejects_legacy_unified_max_tokens_alias;
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
          test_case "inherits base defaults" `Quick
            test_load_keeper_toml_inherits_base_defaults;
        ] );
      ( "discovery",
        [
          test_case "empty dir" `Quick test_discover_empty_dir;
          test_case "with files" `Quick test_discover_with_files;
          test_case "nonexistent dir" `Quick test_discover_nonexistent_dir;
          test_case "skips bad files" `Quick test_discover_skips_bad_files;
          test_case "materializable helper uses base path" `Quick
            test_profile_defaults_materializable_for_name_uses_base_path;
          test_case "bundled keeper profiles resolve prompt defaults" `Quick
            test_bundled_keeper_profiles_resolve_prompt_defaults;
          test_case "bundled issue_king uses local sandbox" `Quick
            test_bundled_issue_king_uses_local_sandbox;
          test_case "persona resolver omits unspecified tool_access" `Quick
            test_persona_resolver_omits_unspecified_tool_access;
          test_case "persona defaults load prompt fields" `Quick
            test_persona_defaults_load_prompt_fields;
          test_case "persona resolver rejects OPERATOR_TODO profile" `Quick
            test_persona_resolver_rejects_operator_todo_profile;
          test_case "persona resolver reports placeholder defaults source" `Quick
            test_persona_resolver_reports_placeholder_defaults_source;
          test_case "persona resolver rejects placeholder in resolved payload" `Quick
            test_persona_resolver_rejects_placeholder_in_resolved_payload;
          test_case "persona resolver preserves autoboot_enabled arg" `Quick
            test_persona_resolver_preserves_autoboot_enabled_arg;
          test_case "persona resolver preserves canonical tool_access and allowed_paths" `Quick
            test_persona_resolver_preserves_canonical_tool_access_and_allowed_paths;
          test_case "persona resolver renders durable keeper TOML" `Quick
            test_persona_resolver_renders_durable_keeper_toml;
          test_case "persona resolver renders tool_access durable TOML" `Quick
            test_persona_resolver_renders_tool_access_array_durable_toml;
        ] );
    ]
