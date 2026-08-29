open Alcotest

module TL = Keeper_toml_loader
module KTP = Masc.Keeper_types_profile
module Runtime = Server_routes_http_runtime

let request_trust_policy =
  match
    Server_request_authority.make_trust_policy
      ~bind_host:"127.0.0.1"
      ~bind_port:8935
      ~explicit_base_url:None
  with
  | Ok policy -> policy
  | Error error ->
    fail (Server_request_authority.trust_policy_error_to_string error)
;;

let health_request () =
  Httpun.Request.create
    ~headers:(Httpun.Headers.of_list [ "host", "localhost:8935" ])
    `GET
    "/health"
;;

let request_authority_exn request =
  match
    Server_request_authority.classify_http1_request
      ~trust_policy:request_trust_policy
      request
  with
  | Server_request_authority.Single authority -> authority
  | ( Server_request_authority.Missing
    | Server_request_authority.Multiple
    | Server_request_authority.Malformed
    | Server_request_authority.Untrusted ) ->
    fail "expected valid authority"
;;

let has_repo_keeper_config root =
  let keepers_dir = Filename.concat root "config/keepers" in
  Sys.file_exists keepers_dir && Sys.is_directory keepers_dir

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

let test_parse_literal_string () =
  match TL.parse_toml "key = 'keeper\\path'" with
  | Ok doc ->
    (match List.assoc_opt "key" doc with
     | Some (TL.Toml_string s) -> check string "literal string" "keeper\\path" s
     | _ -> fail "expected Toml_string")
  | Error e -> fail e

let test_parse_unicode_and_control_escapes () =
  match TL.parse_toml {|key = "\u0041\b\f"|} with
  | Ok doc ->
    (match List.assoc_opt "key" doc with
     | Some (TL.Toml_string s) -> check string "unicode/control escapes" "A\b\012" s
     | _ -> fail "expected Toml_string")
  | Error e -> fail e

let test_parse_quoted_and_dotted_keys_do_not_collide () =
  let input = "\"a.b\" = \"literal\"\na.b = \"nested\"" in
  match TL.parse_toml input with
  | Ok doc ->
    (match List.assoc_opt {|"a.b"|} doc with
     | Some (TL.Toml_string s) -> check string "literal dotted key" "literal" s
     | _ -> fail "expected quoted literal dotted key");
    (match List.assoc_opt "a.b" doc with
     | Some (TL.Toml_string s) -> check string "nested dotted key" "nested" s
     | _ -> fail "expected nested dotted key")
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

let test_parse_general_array () =
  match TL.parse_toml {|items = [1, "two", true]|} with
  | Ok doc ->
    (match List.assoc_opt "items" doc with
     | Some
         (TL.Toml_array
           [ TL.Toml_int 1; TL.Toml_string "two"; TL.Toml_bool true ]) -> ()
     | _ -> fail "expected mixed Toml_array")
  | Error e -> fail e

let test_parse_inline_table () =
  match TL.parse_toml {|point = { x = 1, label = "origin" }|} with
  | Ok doc ->
    (match List.assoc_opt "point" doc with
     | Some (TL.Toml_inline_table fields) ->
       check (option int) "x" (Some 1)
         (match List.assoc_opt "x" fields with
          | Some (TL.Toml_int value) -> Some value
          | _ -> None);
       check (option string) "label" (Some "origin")
         (match List.assoc_opt "label" fields with
          | Some (TL.Toml_string value) -> Some value
          | _ -> None)
     | _ -> fail "expected Toml_inline_table")
  | Error e -> fail e

let test_parse_datetime_values () =
  let input = "offset = 1979-05-27T07:32:00Z\ndate = 1979-05-27" in
  match TL.parse_toml input with
  | Ok doc ->
    (match List.assoc_opt "offset" doc with
     | Some (TL.Toml_offset_datetime value) ->
       check string "offset datetime" "1979-05-27T07:32:00Z" value
     | _ -> fail "expected Toml_offset_datetime");
    (match List.assoc_opt "date" doc with
     | Some (TL.Toml_local_date value) -> check string "local date" "1979-05-27" value
     | _ -> fail "expected Toml_local_date")
  | Error e -> fail e

let test_parse_table_array () =
  let input = "[[products]]\nname = \"hammer\"\n[[products]]\nname = \"nail\"" in
  match TL.parse_toml input with
  | Ok doc ->
    (match List.assoc_opt "products" doc with
     | Some (TL.Toml_table_array [ TL.Toml_table first; TL.Toml_table second ]) ->
       check bool "first table" true
         (List.mem ("name", TL.Toml_string "hammer") first);
       check bool "second table" true
         (List.mem ("name", TL.Toml_string "nail") second)
     | _ -> fail "expected Toml_table_array")
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

let test_profile_rejects_unknown_key () =
  let input = "[keeper]\ntypo_field = true\n" in
  match TL.parse_toml input with
  | Error error -> fail error
  | Ok doc ->
    (match KTP.profile_defaults_of_toml doc with
     | Ok _ -> fail "unknown Keeper field must fail closed"
     | Error detail ->
       check bool "generic unknown-key error" true
         (String_util.contains_substring detail "unknown keeper TOML keys");
       check bool "names unknown key" true
         (String_util.contains_substring detail "keeper.typo_field"))

(* Two RFCs put a key in [keeper.tools] within days of each other, and the
   second one's loader accepted the whole [keeper.tools.] prefix so its own
   nested key would pass. That also accepted [tools.nativ], which is the
   silence RFC-0390 declared its key to prevent: a typo would leave the
   runtime on its default posture with nothing said. Both keys are declared
   now, so the table is closed again. *)
let test_profile_rejects_a_typo_in_the_tools_table () =
  List.iter
    (fun (input, typo) ->
       match TL.parse_toml input with
       | Error error -> fail error
       | Ok doc ->
         (match KTP.profile_defaults_of_toml doc with
          | Ok _ ->
            fail (Printf.sprintf "%s must fail closed, not read as a default" typo)
          | Error detail ->
            check bool
              (Printf.sprintf "%s is named as unknown" typo)
              true
              (String_util.contains_substring detail typo)))
    [ "[keeper.tools]\nnativ = \"read\"\n", "keeper.tools.nativ"
    ; "[keeper.tools]\ngroup = [\"execute\"]\n", "keeper.tools.group"
    ; "[keeper.tools]\nnative_posture = \"read\"\n", "keeper.tools.native_posture"
    ]

(* Each declared kind must reject a value of another kind. Paired with
   [keeper_toml_fields], where a key cannot exist without a kind, this covers a
   newly added key too: it has to pick one of these four, and each is shown to
   fail the load rather than fall through to [Keeper_toml_loader], where a
   wrong-typed value and an absent one produce the same default (#26622). *)
let test_each_keeper_field_kind_rejects_a_wrong_typed_value () =
  List.iter
    (fun (field, wrong, expected_kind) ->
       let input = Printf.sprintf "[keeper]\n%s = %s\n" field wrong in
       match TL.parse_toml input with
       | Error error -> failf "fixture for %s did not parse: %s" field error
       | Ok doc ->
         (match KTP.profile_defaults_of_toml doc with
          | Ok _ -> failf "%s accepted a wrong-typed value" field
          | Error detail ->
            check bool
              (field ^ " names the field")
              true
              (String_util.contains_substring detail ("keeper." ^ field));
            check bool
              (field ^ " names the expected kind")
              true
              (String_util.contains_substring detail expected_kind)))
    [ "name", "true", "string"
    ; "autoboot_enabled", "\"yes\"", "boolean"
    ; "max_context_override", "\"128001\"", "integer"
    ; "mention_targets", "true", "string array"
    ]

(* RFC-0390: [keeper.tools] carries exactly one key. The declared kind list
   makes any sibling an unknown key, so a typo cannot silently keep the
   runtime's default posture. *)
let test_profile_parses_tools_native () =
  List.iter
    (fun (raw, expected) ->
       let input = Printf.sprintf "[keeper.tools]\nnative = %S\n" raw in
       match TL.parse_toml input with
       | Error error -> fail error
       | Ok doc ->
         (match KTP.profile_defaults_of_toml doc with
          | Error e -> fail e
          | Ok d ->
            check bool
              (Printf.sprintf "native %s parses" raw)
              true
              (d.native_tool_posture = Some expected)))
    [ "none", Runtime_native_tools.Native_none
    ; "read", Runtime_native_tools.Native_read
    ; "full", Runtime_native_tools.Native_full
    ]




let test_profile_absent_tools_native_is_none () =
  let input = "[keeper]\nproactive_enabled = true\n" in
  match TL.parse_toml input with
  | Error error -> fail error
  | Ok doc ->
    (match KTP.profile_defaults_of_toml doc with
     | Error e -> fail e
     | Ok d ->
       check bool "absent native is None" true (d.native_tool_posture = None))

let test_profile_rejects_invalid_tools_native () =
  let input = "[keeper.tools]\nnative = \"yolo\"\n" in
  match TL.parse_toml input with
  | Error error -> fail error
  | Ok doc ->
    (match KTP.profile_defaults_of_toml doc with
     | Ok _ -> fail "invalid keeper.tools.native must fail closed"
     | Error detail ->
       check bool "names the key" true
         (String_util.contains_substring detail "keeper.tools.native");
       check bool "lists allowed values" true
         (String_util.contains_substring detail "none, read, full"))

let test_profile_rejects_unknown_tools_sibling_key () =
  let input = "[keeper.tools]\ngroup = [\"board\"]\n" in
  match TL.parse_toml input with
  | Error error -> fail error
  | Ok doc ->
    (match KTP.profile_defaults_of_toml doc with
     | Ok _ -> fail "unknown [keeper.tools] key must fail closed"
     | Error detail ->
       check bool "generic unknown-key error" true
         (String_util.contains_substring detail "unknown keeper TOML keys");
       check bool "names unknown key" true
         (String_util.contains_substring detail "keeper.tools.group"))



let test_skill_names_preserve_absent_empty_and_exact_values () =
  let parse input =
    match TL.parse_toml input with
    | Error error -> fail error
    | Ok doc ->
      (match KTP.profile_defaults_of_toml doc with
       | Ok defaults -> defaults
       | Error detail -> fail detail)
  in
  let absent = parse "[keeper]\ninstructions = \"test\"\n" in
  check (option (list string)) "absent means all" None absent.KTP.skill_names;
  let empty = parse "[keeper]\ninstructions = \"test\"\n[keeper.skills]\nnames = []\n" in
  check (option (list string)) "explicit empty means none" (Some []) empty.KTP.skill_names;
  let exact =
    parse
      "[keeper]\ninstructions = \"test\"\n[keeper.skills]\nnames = [\"guide\", \"Guide\", \"guide\"]\n"
  in
  check
    (option (list string))
    "exact values are deduplicated without case normalization"
    (Some [ "guide"; "Guide" ])
    exact.KTP.skill_names;
  let merged =
    KTP.merge_keeper_profile_defaults
      ~base:{ KTP.empty_keeper_profile_defaults with skill_names = Some [ "guide" ] }
      ~overlay:{ KTP.empty_keeper_profile_defaults with skill_names = Some [] }
  in
  check (option (list string)) "explicit empty overrides inherited names" (Some []) merged.skill_names
;;

let test_profile_full () =
  let input = {|
[keeper]
mention_targets = ["sherlock", "log-analyzer"]
proactive_enabled = true
autoboot_enabled = false
max_context_override = 128001
|} in
  match TL.parse_toml input with
  | Error e -> fail e
  | Ok doc ->
    match KTP.profile_defaults_of_toml doc with
    | Error e -> fail e
    | Ok d ->
      check int "mention_targets" 2 (List.length d.mention_targets);
      check (option bool) "proactive" (Some true) d.proactive_enabled;
      check (option bool) "autoboot_enabled" (Some false) d.autoboot_enabled;
      check (option int) "max_context_override" (Some 128_001)
        d.max_context_override

let test_profile_rejects_wrong_known_field_shape () =
  let input =
    {|
[keeper]
autoboot_enabled = [true, false]
|}
  in
  match TL.parse_toml input with
  | Error error -> fail error
  | Ok doc ->
    (match KTP.profile_defaults_of_toml doc with
     | Ok _ -> fail "known scalar field must not silently use its default"
     | Error message ->
       check bool "names field" true
         (String_util.contains_substring message "keeper.autoboot_enabled");
       check bool "names expected type" true
         (String_util.contains_substring message "boolean"))

let test_profile_rejects_invalid_max_context_override () =
  let input =
    {|
[keeper]
max_context_override = 0
|}
  in
  match TL.parse_toml input with
  | Error error -> fail error
  | Ok doc ->
    (match KTP.profile_defaults_of_toml doc with
     | Ok _ -> fail "expected invalid max_context_override error"
     | Error message ->
       check bool "names max_context_override" true
         (String_util.contains_substring message "max_context_override"))

(* ================================================================ *)
(* File loading tests                                                *)
(* ================================================================ *)

let test_load_from_file () =
  (* Write a temp file *)
  let tmp = Filename.temp_file "keeper_toml_test" ".toml" in
  let content = {|
[keeper]
name = "test-keeper"
|} in
  let oc = open_out tmp in
  output_string oc content;
  close_out oc;
  (match KTP.load_keeper_toml tmp with
   | Error e -> fail (KTP.keeper_toml_load_error_to_string e)
   | Ok (name, defaults) ->
     check string "name from toml" "test-keeper" name;
     check (option string) "instructions" None defaults.instructions;
     check (option string) "manifest" (Some tmp) defaults.manifest_path);
  Sys.remove tmp

let test_load_name_from_filename () =
  let tmp_dir = Filename.get_temp_dir_name () in
  let path = Filename.concat tmp_dir "my-analyzer.toml" in
  let content = {|
[keeper]
|} in
  let oc = open_out path in
  output_string oc content;
  close_out oc;
  (match KTP.load_keeper_toml path with
   | Error e -> fail (KTP.keeper_toml_load_error_to_string e)
   | Ok (name, _) ->
     check string "name from filename" "my-analyzer" name);
  Sys.remove path

let test_load_invalid_name () =
  let tmp = Filename.temp_file "keeper_toml_test" ".toml" in
  let content = {|
[keeper]
name = "invalid name with spaces"
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
instructions = "alpha instructions"
|};
  write_file "beta.toml" {|
[keeper]
instructions = "beta instructions"
|};
  write_file "not-toml.json" {|{"ignored": true}|};
  let result = KTP.discover_keepers_toml tmp_dir in
  check int "two keepers" 2 (List.length result);
  let names = List.map KTP.keeper_toml_discovery_name result in
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

let test_discover_retains_invalid_files () =
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
autoboot_enabled = false
|};
  write_file "bad.toml" "[broken";
  let result = KTP.discover_keepers_toml tmp_dir in
  check int "valid and invalid keepers remain visible" 2 (List.length result);
  let names = List.map KTP.keeper_toml_discovery_name result in
  check (list string) "configured names" [ "bad"; "good" ] names;
  (match List.hd result with
   | KTP.Invalid { keeper_name; error } ->
     check string "invalid keeper name comes from file" "bad" keeper_name;
     check bool "invalid file keeps parse kind" true
       (error.kind = KTP.Parse_error)
   | KTP.Loaded _ -> fail "expected bad.toml to remain as Invalid");
  Array.iter
    (fun f -> Sys.remove (Filename.concat tmp_dir f))
    (Sys.readdir tmp_dir);
  Unix.rmdir tmp_dir

let test_bundled_keeper_profiles_resolve_prompt_defaults () =
  let repo = repo_root () in
  let original_config = Sys.getenv_opt "MASC_CONFIG_DIR" in
  let restore key = function
    | Some value -> Unix.putenv key value
    | None -> Unix.putenv key ""
  in
  Fun.protect
    ~finally:(fun () ->
      restore "MASC_CONFIG_DIR" original_config;
      Config_dir_resolver.reset ())
    (fun () ->
      Unix.putenv "MASC_CONFIG_DIR" (Filename.concat repo "config");
      Config_dir_resolver.reset ();
      let keepers_dir = Filename.concat repo "config/keepers" in
      Sys.readdir keepers_dir
      |> Array.to_list
      |> List.filter (fun file -> Filename.check_suffix file ".toml")
      |> List.iter (fun file ->
           let path = Filename.concat keepers_dir file in
           let name = Filename.chop_extension file in
           match KTP.load_keeper_profile_defaults_result name with
           | Error e ->
             fail
               (Printf.sprintf
                  "%s failed to resolve: %s"
                  path
                  (KTP.keeper_toml_load_error_to_string e))
           | Ok _defaults -> ()))

let read_text_file path =
  let channel = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr channel)
    (fun () -> really_input_string channel (in_channel_length channel))
;;

let test_bundled_profiles_reject_local_sandbox () =
  (* RFC-0394: the local playground is fail-closed, so no bundled keeper
     profile may pin sandbox_profile = "local". *)
  let repo = repo_root () in
  let keepers_dir = Filename.concat repo "config/keepers" in
  Sys.readdir keepers_dir
  |> Array.to_list
  |> List.filter (fun file -> Filename.check_suffix file ".toml")
  |> List.iter (fun file ->
       let contents = read_text_file (Filename.concat keepers_dir file) in
       let squeezed = String.concat "" (String.split_on_char ' ' contents) in
       check bool (file ^ " must not pin the local playground") false
         (String_util.contains_substring squeezed "sandbox_profile=\"local\""))

let concrete_keeper_inventory_path repo =
  Filename.concat repo "test/fixtures/concrete-keeper-identities.txt"
;;

let concrete_keeper_inventory repo =
  read_text_file (concrete_keeper_inventory_path repo)
  |> String.split_on_char '\n'
  |> List.map String.trim
  |> List.filter (fun line -> line <> "" && not (String.starts_with ~prefix:"#" line))
;;

let rec ocaml_source_files path =
  if Sys.is_directory path
  then
    Sys.readdir path
    |> Array.to_list
    |> List.concat_map (fun name -> ocaml_source_files (Filename.concat path name))
  else if Filename.check_suffix path ".ml" || Filename.check_suffix path ".mli"
  then [ path ]
  else []
;;

let test_ocaml_sources_exclude_declared_concrete_keeper_identities () =
  let repo = repo_root () in
  let identities = concrete_keeper_inventory repo in
  check bool "concrete Keeper inventory is declared" true (identities <> []);
  let source_files =
    [ "bin"; "lib"; "packages"; "test" ]
    |> List.concat_map (fun root -> ocaml_source_files (Filename.concat repo root))
  in
  (* Every violation, not the first. [failf] inside the loop stopped at one
     file, so four of the five that had accumulated by 2026-08-24 stayed
     invisible until the one ahead of them was cleared -- and each round of
     that costs a full CI build to learn the next name. *)
  let violations =
    source_files
    |> List.concat_map (fun path ->
         let source = read_text_file path |> String.lowercase_ascii in
         identities
         |> List.filter (fun identity ->
              String_util.contains_substring source (String.lowercase_ascii identity))
         |> List.map (fun identity -> Printf.sprintf "%s: %S" path identity))
  in
  if violations <> []
  then
    failf
      "concrete Keeper identities remain in OCaml source (%d):\n  %s\n\nA fixture needs a name, and an ordinary word eventually picks a live Keeper's. Rename it to one absent from %s. Three fixtures in one file hit this on 2026-08-25, each from an unrelated PR, because nothing tells an author which words are taken until CI does."
      (List.length violations)
      (String.concat "\n  " violations)
      (concrete_keeper_inventory_path repo)
;;

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

let test_typed_keeper_toml_edits_preserve_unrelated_fields () =
  with_temp_dir "keeper-toml-edits" @@ fun dir ->
  let path = Filename.concat dir "probe.toml" in
  write_file path
    {|
# operator comment
[keeper]
name = "probe"
"proactive_enabled"	= true
max_context_override	= 200000

[keeper.agent_core_env]
AGENT_CORE_OPENAI_BASE_URL = "http://127.0.0.1:1"
|};
  (match
     TL.edit_keeper_toml_fields_strict_staged
       ~path
       [ "proactive_enabled", TL.Set (TL.Toml_bool false)
       ; "sandbox_image", TL.Set (TL.Toml_string "keeper:test")
       ; "mention_targets", TL.Set (TL.Toml_string_array [ "/tmp/a"; "/tmp/b" ])
       ; "max_context_override", TL.Remove
       ]
   with
   | Error error -> fail (Fs_compat.atomic_replace_failure_to_string error)
   | Ok () -> ());
  let content =
    match Safe_ops.read_file_safe path with
    | Error error -> fail error
    | Ok content -> content
  in
  check bool "comment survives" true
    (String_util.contains_substring content "# operator comment");
  match TL.parse_toml content with
  | Error error -> fail error
  | Ok doc ->
    check (option bool) "bool updated" (Some false)
      (TL.toml_bool_opt doc "keeper.proactive_enabled");
    check (option string) "sandbox image inserted" (Some "keeper:test")
      (TL.toml_string_opt doc "keeper.sandbox_image");
    check (list string) "list inserted" [ "/tmp/a"; "/tmp/b" ]
      (TL.toml_string_list doc "keeper.mention_targets");
    check (option int) "context override removed" None
      (TL.toml_int_opt doc "keeper.max_context_override");
    check (option string) "unrelated table survives"
      (Some "http://127.0.0.1:1")
      (TL.toml_string_opt doc "keeper.agent_core_env.AGENT_CORE_OPENAI_BASE_URL")

let test_keeper_toml_writer_rejects_table_assignment_shapes () =
  with_temp_dir "keeper-toml-invalid-writer-shape" @@ fun dir ->
  let shapes =
    [ "table", TL.Toml_table [ "nested", TL.Toml_string "value" ]
    ; "table array", TL.Toml_table_array []
    ]
  in
  List.iter
    (fun (label, value) ->
      let path = Filename.concat dir (String.map (function ' ' -> '-' | c -> c) label ^ ".toml") in
      match TL.create_keeper_toml_file_strict_staged ~path [ "invalid", value ] with
      | Ok () -> failf "%s must not be rendered as a key assignment" label
      | Error failure ->
        let message = Fs_compat.atomic_replace_failure_to_string failure in
        check bool (label ^ " error is explicit") true
          (String_util.contains_substring message "cannot be rendered");
        check bool (label ^ " file is not created") false (Sys.file_exists path))
    shapes

let test_keeper_toml_writer_round_trips_control_escapes () =
  with_temp_dir "keeper-toml-control-escapes" @@ fun dir ->
  let path = Filename.concat dir "control.toml" in
  write_file path "[keeper]\ninstructions = \"old\"\n";
  let value =
    "before"
    ^ String.make 1 (Char.chr 8)
    ^ String.make 1 (Char.chr 12)
    ^ "after"
  in
  (match
     TL.edit_keeper_toml_fields_strict_staged
       ~path
       [ "instructions", TL.Set (TL.Toml_string value) ]
   with
   | Error error -> fail (Fs_compat.atomic_replace_failure_to_string error)
   | Ok () -> ());
  match Safe_ops.read_file_safe path with
  | Error error -> fail error
  | Ok content ->
    (match TL.parse_toml content with
     | Error error -> fail ("writer emitted invalid TOML: " ^ error)
     | Ok doc ->
       check (option string) "control escapes survive writer round-trip"
         (Some value)
         (TL.toml_string_opt doc "keeper.instructions"))

let test_keeper_toml_writer_edits_multiline_assignments () =
  with_temp_dir "keeper-toml-multiline-edits" @@ fun dir ->
  let fixture () =
    "[keeper]\n"
    ^ "instructions = \"\"\"\n"
    ^ "line one\n"
    ^ "line two\n"
    ^ "\"\"\"\n"
    ^ "mention_targets = [\n"
    ^ "  \"/tmp/old-a\",\n"
    ^ "  \"/tmp/old-b\",\n"
    ^ "]\n"
  in
  let update_path = Filename.concat dir "update.toml" in
  write_file update_path (fixture ());
  (match
     TL.edit_keeper_toml_fields_strict_staged
       ~path:update_path
       [ "instructions", TL.Set (TL.Toml_string "updated\ninstructions")
       ; "mention_targets", TL.Set (TL.Toml_string_array [ "/tmp/new-a" ])
       ]
   with
   | Error error -> fail (Fs_compat.atomic_replace_failure_to_string error)
   | Ok () -> ());
  (match Safe_ops.read_file_safe update_path with
   | Error error -> fail error
   | Ok content ->
     match TL.parse_toml content with
     | Error error -> fail ("multiline update emitted invalid TOML: " ^ error)
     | Ok doc ->
       check (option string) "multiline string replaced"
         (Some "updated\ninstructions")
         (TL.toml_string_opt doc "keeper.instructions");
       check (list string) "multiline array replaced" [ "/tmp/new-a" ]
         (TL.toml_string_list doc "keeper.mention_targets"));
  let remove_path = Filename.concat dir "remove.toml" in
  write_file remove_path (fixture ());
  (match
     TL.edit_keeper_toml_fields_strict_staged
       ~path:remove_path
       [ "instructions", TL.Remove ]
   with
   | Error error -> fail (Fs_compat.atomic_replace_failure_to_string error)
   | Ok () -> ());
  match Safe_ops.read_file_safe remove_path with
  | Error error -> fail error
  | Ok content ->
    (match TL.parse_toml content with
     | Error error -> fail ("multiline removal emitted invalid TOML: " ^ error)
     | Ok doc ->
       check (option string) "multiline string removed" None
         (TL.toml_string_opt doc "keeper.instructions"))

let with_profile_base f =
  with_env_restore [ "MASC_CONFIG_DIR" ] @@ fun () ->
  Unix.putenv "MASC_CONFIG_DIR" "";
  Config_dir_resolver.reset ();
  with_temp_dir "keeper-profile-base" @@ fun base_path ->
  let config_dir = Filename.concat (Filename.concat base_path ".masc") "config" in
  let keepers_dir = Filename.concat config_dir "keepers" in
  mkdir_p keepers_dir;
  f ~base_path ~config_dir ~keepers_dir

let expect_profile_load_error ~base_path ~keeper_name ~kind ~failing_path =
  match
    KTP.load_keeper_profile_defaults_result_for_base_path
      ~base_path
      keeper_name
  with
  | Ok _ -> failf "expected %s profile to fail closed" keeper_name
  | Error error ->
    check bool "typed load error kind" true (error.kind = kind);
    check string "failing path" failing_path error.failing_path;
    error

let test_invalid_child_profile_fails_closed_before_dispatch () =
  with_profile_base @@ fun ~base_path ~config_dir:_ ~keepers_dir ->
  let keeper_path = Filename.concat keepers_dir "broken.toml" in
  write_file keeper_path
    "[keeper]\ngoal = [\n";
  let error =
    expect_profile_load_error
      ~base_path
      ~keeper_name:"broken"
      ~kind:KTP.Parse_error
      ~failing_path:keeper_path
  in
  check string "keeper path" keeper_path error.keeper_path;
  match
    Masc.Keeper_unified_turn_pre_dispatch.load_profile_defaults
      ~base_path
      ~keeper_name:"broken"
  with
  | Ok _ -> fail "invalid profile reached runtime execution construction"
  | Error
      (Agent_core.Error.Config
         (Agent_core.Error.InvalidConfig { field; detail })) ->
    check string "typed agent-core config field" "keeper.profile" field;
    check bool "agent-core error retains failing path" true
      (String_util.contains_substring detail keeper_path)
  | Error err ->
    failf "expected typed InvalidConfig, got %s" (Agent_core.Error.to_string err)

let test_default_source_snapshot_uses_explicit_base_path () =
  with_profile_base @@ fun ~base_path ~config_dir:_ ~keepers_dir ->
  let keeper_path = Filename.concat keepers_dir "snapshot-broken.toml" in
  write_file keeper_path "[broken";
  let snapshot =
    KTP.keeper_default_source_snapshot ~base_path "snapshot-broken"
  in
  check (option string) "invalid source is not projected" None snapshot.source_kind;
  match snapshot.config_error with
  | None -> fail "expected explicit-base snapshot to retain config error"
  | Some error ->
    check bool "snapshot parse kind" true (error.kind = KTP.Parse_error);
    check string "snapshot keeper path" keeper_path error.keeper_path;
    check string "snapshot failing path" keeper_path error.failing_path

let test_absent_profile_is_legitimate_empty_defaults () =
  with_profile_base @@ fun ~base_path ~config_dir:_ ~keepers_dir:_ ->
  match
    KTP.load_keeper_profile_defaults_result_for_base_path
      ~base_path
      "absent"
  with
  | Error error -> fail (KTP.keeper_toml_load_error_to_string error)
  | Ok defaults ->
    check (option string) "no manifest" None defaults.manifest_path;
    check (option string) "no instructions" None defaults.instructions

let test_keeper_config_directory_probe_is_typed () =
  let path = Filename.temp_file "keeper-config-not-dir" ".toml" in
  Fun.protect
    ~finally:(fun () -> if Sys.file_exists path then Sys.remove path)
    (fun () ->
      match KTP.keeper_toml_config_errors_in_dir_result path with
      | Ok _ -> fail "expected non-directory config path to fail the probe"
      | Error error ->
        check bool "closed probe kind" true
          (error.kind = KTP.Not_a_directory);
        check (option string) "probe path" (Some path) error.directory_path;
        let json = KTP.keeper_config_probe_error_to_json error in
        let open Yojson.Safe.Util in
        check string "projected probe kind" "not_a_directory"
          (json |> member "kind" |> to_string);
        check bool "probe is blocking" true
          (json |> member "blocking" |> to_bool))

let restore_env name = function
  | Some value -> Unix.putenv name value
  | None ->
      (* OCaml 5.5 adds [Unix.unsetenv], but the supported 5.4 floor used here
         does not expose it. Config_dir_resolver normalizes empty env values to
         [None], so this restores the effective resolver state for these tests. *)
      Unix.putenv name ""

let with_config_dir f =
  with_temp_dir "keeper-config" @@ fun config_dir ->
  mkdir_p (Filename.concat config_dir "prompts");
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
  let original_base_path = Sys.getenv_opt "MASC_BASE_PATH" in
  Fun.protect
    ~finally:(fun () ->
      restore_env "MASC_CONFIG_DIR" original_config;
      restore_env "MASC_BASE_PATH" original_base_path;
      Config_dir_resolver.reset ())
    (fun () ->
      Unix.putenv "MASC_CONFIG_DIR" "";
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
      check bool
        "explicit autoboot keeper is materializable"
        true
        (KTP.keeper_profile_defaults_materializable_for_name ~base_path
           "runtime"))

(* ================================================================ *)
(* Unknown-key detection                                             *)
(* ================================================================ *)

let test_detect_unknown_keys_empty_when_all_canonical () =
  let input = {|
[keeper]
mention_targets = ["a", "b"]
autoboot_enabled = false
|} in
  match TL.parse_toml input with
  | Error e -> fail e
  | Ok doc ->
    let unknown = KTP.detect_unknown_keeper_toml_keys doc in
    check (list string) "no unknown keys" [] unknown

let test_detect_unknown_keys_flags_provider_health_table () =
  let input = {|
[keeper]
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

let test_agent_core_env_parses_allowed_keys () =
  let input = {|
[keeper]
[keeper.agent_core_env]
AGENT_CORE_DEFAULT_MODEL = "provider-a/fast"
AGENT_CORE_MAX_TOKENS_DEFAULT = 16384
|} in
  match TL.parse_toml input with
  | Error e -> fail e
  | Ok doc ->
    match KTP.profile_defaults_of_toml doc with
    | Error e -> fail e
    | Ok d ->
      check int "agent_core_env count" 2 (List.length d.agent_core_env);
      check string "default model value"
        "provider-a/fast" (List.assoc "AGENT_CORE_DEFAULT_MODEL" d.agent_core_env);
      check string "max tokens default value"
        "16384" (List.assoc "AGENT_CORE_MAX_TOKENS_DEFAULT" d.agent_core_env)

let test_agent_core_env_drops_non_agent_core_prefix () =
  (* Guards against ambient env injection via keeper TOML: arbitrary keys
     outside the audited allowlist are silently dropped. *)
  let input = {|
[keeper]
[keeper.agent_core_env]
PATH = "/evil/bin:/usr/bin"
LD_PRELOAD = "/tmp/hack.so"
AGENT_CORE_DEFAULT_MODEL = "provider-a/fast"
MASC_KEEPER_AUTONOMOUS_MAX_TOKENS = "9999"
RANDOM_VAR = "nope"
|} in
  match TL.parse_toml input with
  | Error e -> fail e
  | Ok doc ->
    match KTP.profile_defaults_of_toml doc with
    | Error e -> fail e
    | Ok d ->
      check int "only allowed AGENT_CORE_* survives" 1 (List.length d.agent_core_env);
      check string "allowed AGENT_CORE key survives"
        "provider-a/fast" (List.assoc "AGENT_CORE_DEFAULT_MODEL" d.agent_core_env);
      check bool "PATH dropped" false (List.mem_assoc "PATH" d.agent_core_env);
      check bool "LD_PRELOAD dropped" false (List.mem_assoc "LD_PRELOAD" d.agent_core_env);
      check bool "unlisted keeper key dropped" false
        (List.mem_assoc "MASC_KEEPER_AUTONOMOUS_MAX_TOKENS" d.agent_core_env);
      check bool "RANDOM_VAR dropped" false (List.mem_assoc "RANDOM_VAR" d.agent_core_env)

let test_agent_core_env_absent_means_empty () =
  let input = {|
[keeper]
|} in
  match TL.parse_toml input with
  | Error e -> fail e
  | Ok doc ->
    match KTP.profile_defaults_of_toml doc with
    | Error e -> fail e
    | Ok d ->
      check int "no table → empty list" 0 (List.length d.agent_core_env)

let test_agent_core_env_not_flagged_as_unknown () =
  let input = {|
[keeper]
[keeper.agent_core_env]
AGENT_CORE_DEFAULT_MODEL = "provider-a/fast"
|} in
  match TL.parse_toml input with
  | Error e -> fail e
  | Ok doc ->
    let unknown = KTP.detect_unknown_keeper_toml_keys doc in
    check int "agent_core_env keys whitelisted" 0 (List.length unknown)

let test_agent_core_env_coerces_bool_to_string () =
  (* Bools in TOML become "1"/"0" strings for active AGENT_CORE boolean env knobs. *)
  let input = {|
[keeper]
[keeper.agent_core_env]
AGENT_CORE_ALLOW_TEST_PROVIDERS = true
AGENT_CORE_DELTA_CHECKPOINT = false
|} in
  match TL.parse_toml input with
  | Error e -> fail e
  | Ok doc ->
    match KTP.profile_defaults_of_toml doc with
    | Error e -> fail e
    | Ok d ->
      check string "true → 1" "1"
        (List.assoc "AGENT_CORE_ALLOW_TEST_PROVIDERS" d.agent_core_env);
      check string "false → 0" "0"
        (List.assoc "AGENT_CORE_DELTA_CHECKPOINT" d.agent_core_env)

let test_load_keeper_toml_rejects_unknown_keys () =
  let tmp = Filename.temp_file "keeper_unknown" ".toml" in
  write_file tmp "[keeper]\ntypo_field = 42\n";
  match KTP.load_keeper_toml tmp with
  | Ok _ ->
    Sys.remove tmp;
    fail "unknown Keeper TOML key must fail closed"
  | Error error ->
    Sys.remove tmp;
    check bool "profile error" true (error.kind = KTP.Profile_error);
    check bool "generic unknown-key error" true
      (String_util.contains_substring error.detail "unknown keeper TOML keys");
    check bool "unknown key retained" true
      (String_util.contains_substring error.detail "keeper.typo_field")

let test_keeper_toml_unknown_keys_in_dir_reports_files () =
  with_temp_dir "keeper-unknown-dir" @@ fun dir ->
  write_file (Filename.concat dir "alpha.toml")
    {|
[keeper]
name = "alpha"
typo_field = "unexpected"
|};
  write_file (Filename.concat dir "beta.toml")
    {|
[keeper]
name = "beta"
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
      [ "keeper.typo_field" ]
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
sandbox_profile = "local"
typo_field = "unexpected"
|};
  let request = health_request () in
  let json =
    Runtime.make_health_json
      ~request_authority:(request_authority_exn request)
      request
  in
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
  check string "schema terminal reason" "config_invalid"
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
       [ "keeper.typo_field" ]
       (row |> member "unknown_keys" |> to_list |> List.map to_string)
   | _ ->
     fail
       (Printf.sprintf "expected one health unknown-key row, got %d"
          (List.length rows)));
  ()

let test_health_json_surfaces_typed_keeper_config_error () =
  with_config_dir @@ fun config_dir ->
  let keepers_dir = Filename.concat config_dir "keepers" in
  mkdir_p keepers_dir;
  let keeper_path = Filename.concat keepers_dir "broken.toml" in
  (* Unreadable keeper TOML: the path exists with a .toml suffix but cannot be
     read, so the loader reports Read_error against the keeper file itself. *)
  Unix.mkdir keeper_path 0o755;
  let request = health_request () in
  let json =
    Runtime.make_health_json
      ~request_authority:(request_authority_exn request)
      request
  in
  let open Yojson.Safe.Util in
  check int "config error count" 1
    (json |> member "keeper_config_error_count" |> to_int);
  check string "schema terminal reason" "config_invalid"
    (json |> member "keeper_config_schema_terminal_reason" |> to_string);
  check bool "config schema blocks dispatch" true
    (json |> member "keeper_config_schema_blocking" |> to_bool);
  let rows = json |> member "keeper_config_errors" |> to_list in
  match rows with
  | [ row ] ->
    check string "keeper" "broken" (row |> member "keeper" |> to_string);
    check string "typed kind" "read_error" (row |> member "kind" |> to_string);
    check string "child path" keeper_path
      (row |> member "keeper_path" |> to_string);
    check string "failing path" keeper_path
      (row |> member "failing_path" |> to_string);
    check string "terminal reason" "config_invalid"
      (row |> member "terminal_reason" |> to_string);
    check string "repair action" "fix_keeper_toml_config"
      (row |> member "next_action" |> to_string)
  | _ -> failf "expected one typed config error row, got %d" (List.length rows)

let test_health_json_build_exposes_runtime_binary_identity () =
  with_config_dir @@ fun _config_dir ->
  let request = health_request () in
  let json =
    Runtime.make_health_json
      ~request_authority:(request_authority_exn request)
      request
  in
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
          test_case "literal string" `Quick test_parse_literal_string;
          test_case "unicode and control escapes" `Quick
            test_parse_unicode_and_control_escapes;
          test_case "quoted and dotted keys do not collide" `Quick
            test_parse_quoted_and_dotted_keys_do_not_collide;
          test_case "int value" `Quick test_parse_int_value;
          test_case "negative int" `Quick test_parse_negative_int;
          test_case "float value" `Quick test_parse_float_value;
          test_case "bool values" `Quick test_parse_bool_values;
          test_case "string array" `Quick test_parse_string_array;
          test_case "string array escaped quotes" `Quick
            test_parse_string_array_escaped_quotes;
          test_case "empty array" `Quick test_parse_empty_array;
          test_case "general array" `Quick test_parse_general_array;
          test_case "inline table" `Quick test_parse_inline_table;
          test_case "datetime values" `Quick test_parse_datetime_values;
          test_case "table array" `Quick test_parse_table_array;
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
          test_case "rejects unknown key" `Quick
            test_profile_rejects_unknown_key;
          test_case "parses tools.native postures" `Quick
            test_profile_parses_tools_native;
        Alcotest.test_case "a typo in [keeper.tools] fails the load" `Quick
            test_profile_rejects_a_typo_in_the_tools_table;
          test_case "absent tools.native is None" `Quick
            test_profile_absent_tools_native_is_none;
          test_case "rejects invalid tools.native" `Quick
            test_profile_rejects_invalid_tools_native;
          test_case "rejects unknown [keeper.tools] sibling" `Quick
            test_profile_rejects_unknown_tools_sibling_key;
          test_case "full" `Quick test_profile_full;
          test_case "rejects wrong known-field shape" `Quick
            test_profile_rejects_wrong_known_field_shape;
          test_case "rejects invalid max_context_override" `Quick
            test_profile_rejects_invalid_max_context_override;
        ] );
      ( "writer",
        [
          test_case "typed edits preserve unrelated fields" `Quick
            test_typed_keeper_toml_edits_preserve_unrelated_fields;
          test_case "rejects table assignment shapes" `Quick
            test_keeper_toml_writer_rejects_table_assignment_shapes;
          test_case "round-trips control escapes" `Quick
            test_keeper_toml_writer_round_trips_control_escapes;
          test_case "edits multiline assignments" `Quick
            test_keeper_toml_writer_edits_multiline_assignments;
        ] );
      ( "unknown_keys",
        [
          test_case "empty when all canonical" `Quick
            test_detect_unknown_keys_empty_when_all_canonical;
          test_case "flags provider_health table as unknown" `Quick
            test_detect_unknown_keys_flags_provider_health_table;
          test_case "agent_core_env keys not flagged as unknown" `Quick
            test_agent_core_env_not_flagged_as_unknown;
          test_case "load_keeper_toml rejects unknown keys" `Quick
            test_load_keeper_toml_rejects_unknown_keys;
          test_case "unknown-key scanner reports files" `Quick
            test_keeper_toml_unknown_keys_in_dir_reports_files;
          test_case "health JSON surfaces unknown keys" `Quick
            test_health_json_surfaces_keeper_toml_unknown_keys;
          test_case "health JSON surfaces typed config errors" `Quick
            test_health_json_surfaces_typed_keeper_config_error;
          test_case "health JSON build exposes runtime binary identity" `Quick
            test_health_json_build_exposes_runtime_binary_identity;
        ] );
      ( "agent_core_env",
        [
          test_case "parses allowed AGENT_CORE_* keys" `Quick
            test_agent_core_env_parses_allowed_keys;
          test_case "drops non-AGENT_CORE_* keys (ambient injection guard)" `Quick
            test_agent_core_env_drops_non_agent_core_prefix;
          test_case "empty when table absent" `Quick
            test_agent_core_env_absent_means_empty;
          test_case "coerces bool → \"1\"/\"0\" string" `Quick
            test_agent_core_env_coerces_bool_to_string;
        ] );
      ( "file_loading",
        [
          test_case "load from file" `Quick test_load_from_file;
          test_case "name from filename" `Quick test_load_name_from_filename;
          test_case "invalid name" `Quick test_load_invalid_name;
          test_case "invalid child blocks before dispatch" `Quick
            test_invalid_child_profile_fails_closed_before_dispatch;
          test_case "default source snapshot uses explicit base path" `Quick
            test_default_source_snapshot_uses_explicit_base_path;
          test_case "absent profile is valid empty defaults" `Quick
            test_absent_profile_is_legitimate_empty_defaults;
          test_case "config directory probe is typed" `Quick
            test_keeper_config_directory_probe_is_typed;
        ] );
      ( "discovery",
        [
          test_case "empty dir" `Quick test_discover_empty_dir;
          test_case "with files" `Quick test_discover_with_files;
          test_case "nonexistent dir" `Quick test_discover_nonexistent_dir;
          test_case "retains invalid files" `Quick
            test_discover_retains_invalid_files;
          test_case "each field kind rejects a wrong-typed value" `Quick
            test_each_keeper_field_kind_rejects_a_wrong_typed_value;
          test_case "Skill names preserve three-state selection" `Quick
            test_skill_names_preserve_absent_empty_and_exact_values;
          test_case "materializable helper uses base path" `Quick
            test_profile_defaults_materializable_for_name_uses_base_path;
          test_case "bundled keeper profiles resolve prompt defaults" `Quick
            test_bundled_keeper_profiles_resolve_prompt_defaults;
          test_case "bundled profiles reject local sandbox" `Quick
            test_bundled_profiles_reject_local_sandbox;
          test_case "OCaml sources exclude concrete Keeper identities" `Quick
            test_ocaml_sources_exclude_declared_concrete_keeper_identities;
        ] );
    ]
