module Types = Masc_domain

(** Unit tests for Tool_input_validation — OAS-delegated validation with coercion.

    Tests the integration: MASC JSON Schema -> Tool_bridge.params_of_json_schema
    -> Agent_sdk.Tool_input_validation.validate -> pre_hook_action mapping. *)

open Masc

(** Simple substring check — avoids Astring dependency. *)
let string_contains haystack needle =
  let nlen = String.length needle in
  let hlen = String.length haystack in
  if nlen > hlen then false
  else
    let found = ref false in
    for i = 0 to hlen - nlen do
      if not !found && String.sub haystack i nlen = needle then found := true
    done;
    !found

let read_file path =
  let ic = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () -> In_channel.input_all ic)

let rec find_source_root_from dir hops rel =
  if hops > 8 then None
  else if Sys.file_exists (Filename.concat dir rel) then Some dir
  else
    let parent = Filename.dirname dir in
    if String.equal parent dir then None else find_source_root_from parent (hops + 1) rel

let source_root () =
  let anchor = "dune-project" in
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root when String.trim root <> "" && Sys.file_exists (Filename.concat root anchor) ->
    root
  | _ ->
    (match find_source_root_from (Sys.getcwd ()) 0 anchor with
     | Some root -> root
     | None -> Alcotest.fail "could not locate repo source root")

let read_source_file rel = read_file (Filename.concat (source_root ()) rel)

let assert_contains label haystack needle =
  Alcotest.(check bool) label true (string_contains haystack needle)

let assert_not_contains label haystack needle =
  Alcotest.(check bool) label false (string_contains haystack needle)

let identifier_tokens text =
  let is_identifier_char = function
    | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' -> true
    | _ -> false
  in
  String.to_seq text
  |> Seq.map (fun char -> if is_identifier_char char then char else ' ')
  |> String.of_seq
  |> String.split_on_char ' '
  |> List.filter (fun token -> not (String.equal token ""))

(* ================================================================ *)
(* Helper: validate via the same pipeline as the pre-hook            *)
(* ================================================================ *)

(** Reproduce the exact validation pipeline used in the pre-hook:
    JSON Schema -> params_of_json_schema -> OAS validate. *)
let validate_via_oas ~tool_name ~(schema : Yojson.Safe.t) ~(args : Yojson.Safe.t)
  : Tool_dispatch.pre_hook_action =
  let parameters = Tool_bridge.params_of_json_schema schema in
  if parameters = [] then Pass
  else
    let oas_schema : Agent_sdk.Types.tool_schema =
      { name = tool_name; description = ""; parameters; strict = None }
    in
    match Agent_sdk.Tool_input_validation.validate oas_schema args with
    | Agent_sdk.Tool_input_validation.Valid coerced ->
      if Yojson.Safe.equal coerced args then Pass
      else Proceed coerced
    | Agent_sdk.Tool_input_validation.Invalid errors ->
      let msg =
        Agent_sdk.Tool_input_validation.format_errors ~tool_name errors
      in
      Reject
        (Error
           { Tool_result.class_ = Tool_result.Runtime_failure
           ; message = msg
           ; data = `Assoc [("error", `String msg)]
           ; tool_name
           ; duration_ms = 0.0
           })

(** Build a JSON Schema object with given properties and required list. *)
let make_schema ?(required = []) (props : (string * string) list) : Yojson.Safe.t =
  let prop_entries =
    List.map (fun (name, type_str) ->
      (name, `Assoc [("type", `String type_str)])
    ) props
  in
  `Assoc [
    ("type", `String "object");
    ("properties", `Assoc prop_entries);
    ("required", `List (List.map (fun s -> `String s) required));
  ]

let run_registered_hook ?schema ~tool_name ~(args : Yojson.Safe.t) () =
  Tool_dispatch.clear_hooks ();
  (match schema with
   | Some input_schema ->
     let schema_def : Masc_domain.tool_schema =
       { name = tool_name; description = "test"; input_schema }
     in
     Tool_dispatch.register_module_tag ~schemas:[schema_def] ~tag:Mod_misc
   | None -> ());
  Tool_input_validation.register_pre_hook ();
  Tool_dispatch.run_pre_hooks ~name:tool_name ~args

(* ================================================================ *)
(* Test: required field validation                                   *)
(* ================================================================ *)

let test_required_present () =
  let schema = make_schema ~required:["name"] [("name", "string")] in
  let args = `Assoc [("name", `String "alice")] in
  match validate_via_oas ~tool_name:"test" ~schema ~args with
  | Pass -> ()
  | Proceed _ -> ()  (* coerced but still valid *)
  | Reject r -> Alcotest.fail (Printf.sprintf "Expected Pass, got Reject: %s"
      (Yojson.Safe.to_string (Tool_result.data r)))

let test_required_missing () =
  let schema = make_schema ~required:["name"; "workspace"] [("name", "string"); ("workspace", "string")] in
  let args = `Assoc [("name", `String "alice")] in
  match validate_via_oas ~tool_name:"test" ~schema ~args with
  | Reject r ->
    let msg = Yojson.Safe.to_string (Tool_result.data r) in
    Alcotest.(check bool) "mentions workspace" true (string_contains msg "workspace")
  | Pass | Proceed _ -> Alcotest.fail "Expected Reject for missing required field"

let test_required_missing_multiple () =
  let schema = make_schema ~required:["a"; "b"; "c"]
    [("a", "string"); ("b", "string"); ("c", "string")] in
  let args = `Assoc [("a", `String "ok")] in
  match validate_via_oas ~tool_name:"test" ~schema ~args with
  | Reject r ->
    let msg = Yojson.Safe.to_string (Tool_result.data r) in
    Alcotest.(check bool) "mentions b" true (string_contains msg "b");
    Alcotest.(check bool) "mentions c" true (string_contains msg "c")
  | Pass | Proceed _ -> Alcotest.fail "Expected Reject for missing multiple fields"

let test_no_required_fields () =
  let schema = make_schema [("name", "string")] in
  let args = `Assoc [] in
  match validate_via_oas ~tool_name:"test" ~schema ~args with
  | Pass -> ()
  | Proceed _ -> ()
  | Reject r -> Alcotest.fail (Printf.sprintf "Expected Pass, got Reject: %s"
      (Yojson.Safe.to_string (Tool_result.data r)))

(* ================================================================ *)
(* Test: type coercion (Samchon Harness Rank 1)                     *)
(* ================================================================ *)

let test_coerce_string_to_integer () =
  let schema = make_schema [("count", "integer")] in
  let args = `Assoc [("count", `String "42")] in
  match validate_via_oas ~tool_name:"test" ~schema ~args with
  | Proceed coerced ->
    let count = Yojson.Safe.Util.member "count" coerced in
    Alcotest.(check string) "coerced to int" "42"
      (match count with `Int i -> string_of_int i | _ -> "not_int")
  | Pass -> Alcotest.fail "Expected Proceed (coercion), got Pass"
  | Reject r -> Alcotest.fail (Printf.sprintf "Expected Proceed, got Reject: %s"
      (Yojson.Safe.to_string (Tool_result.data r)))

let test_coerce_string_to_boolean () =
  let schema = make_schema [("flag", "boolean")] in
  let args = `Assoc [("flag", `String "true")] in
  match validate_via_oas ~tool_name:"test" ~schema ~args with
  | Proceed coerced ->
    let flag = Yojson.Safe.Util.member "flag" coerced in
    Alcotest.(check bool) "coerced to true" true
      (match flag with `Bool b -> b | _ -> false)
  | Pass -> Alcotest.fail "Expected Proceed (coercion), got Pass"
  | Reject r -> Alcotest.fail (Printf.sprintf "Expected Proceed, got Reject: %s"
      (Yojson.Safe.to_string (Tool_result.data r)))

let test_coerce_string_to_number () =
  let schema = make_schema [("value", "number")] in
  let args = `Assoc [("value", `String "3.14")] in
  match validate_via_oas ~tool_name:"test" ~schema ~args with
  | Proceed coerced ->
    let v = Yojson.Safe.Util.member "value" coerced in
    (match v with
     | `Float f -> Alcotest.(check bool) "close to pi" true (Float.abs (f -. 3.14) < 0.001)
     | _ -> Alcotest.fail "Expected Float after coercion")
  | Pass -> Alcotest.fail "Expected Proceed (coercion), got Pass"
  | Reject r -> Alcotest.fail (Printf.sprintf "Expected Proceed, got Reject: %s"
      (Yojson.Safe.to_string (Tool_result.data r)))

let test_coerce_int_to_number () =
  let schema = make_schema [("value", "number")] in
  let args = `Assoc [("value", `Int 42)] in
  match validate_via_oas ~tool_name:"test" ~schema ~args with
  | Pass -> ()  (* Int is valid Number, may not need coercion *)
  | Proceed _ -> ()  (* widened to Float, also ok *)
  | Reject r -> Alcotest.fail (Printf.sprintf "Expected Pass/Proceed, got Reject: %s"
      (Yojson.Safe.to_string (Tool_result.data r)))

let test_coerce_intlit_to_integer () =
  let schema = make_schema [("count", "integer")] in
  let args = `Assoc [("count", `Intlit "123")] in
  match validate_via_oas ~tool_name:"test" ~schema ~args with
  | Proceed coerced ->
    let count = Yojson.Safe.Util.member "count" coerced in
    Alcotest.(check string) "normalized to Int" "123"
      (match count with `Int i -> string_of_int i | _ -> "not_int")
  | Pass -> ()  (* some impls may consider Intlit valid *)
  | Reject r -> Alcotest.fail (Printf.sprintf "Expected Proceed/Pass, got Reject: %s"
      (Yojson.Safe.to_string (Tool_result.data r)))

let test_invalid_string_to_integer () =
  let schema = make_schema ~required:["count"] [("count", "integer")] in
  let args = `Assoc [("count", `String "not_a_number")] in
  match validate_via_oas ~tool_name:"test" ~schema ~args with
  | Reject r ->
    let msg = Yojson.Safe.to_string (Tool_result.data r) in
    Alcotest.(check bool) "mentions count" true (string_contains msg "count")
  | Pass | Proceed _ -> Alcotest.fail "Expected Reject for non-coercible string"

(* ================================================================ *)
(* Test: correct types pass without coercion                        *)
(* ================================================================ *)

let test_correct_string () =
  let schema = make_schema [("name", "string")] in
  let args = `Assoc [("name", `String "alice")] in
  match validate_via_oas ~tool_name:"test" ~schema ~args with
  | Pass -> ()
  | Proceed _ -> Alcotest.fail "Expected Pass (no coercion needed)"
  | Reject r -> Alcotest.fail (Yojson.Safe.to_string (Tool_result.data r))

let test_correct_integer () =
  let schema = make_schema [("count", "integer")] in
  let args = `Assoc [("count", `Int 5)] in
  match validate_via_oas ~tool_name:"test" ~schema ~args with
  | Pass -> ()
  | Proceed _ -> ()  (* normalization is acceptable *)
  | Reject r -> Alcotest.fail (Yojson.Safe.to_string (Tool_result.data r))

let test_correct_boolean () =
  let schema = make_schema [("flag", "boolean")] in
  let args = `Assoc [("flag", `Bool true)] in
  match validate_via_oas ~tool_name:"test" ~schema ~args with
  | Pass -> ()
  | Proceed _ -> Alcotest.fail "Expected Pass (no coercion needed)"
  | Reject r -> Alcotest.fail (Yojson.Safe.to_string (Tool_result.data r))

(* ================================================================ *)
(* Test: edge cases                                                  *)
(* ================================================================ *)

let test_null_args_no_required () =
  let schema = make_schema [("optional", "string")] in
  let args = `Null in
  match validate_via_oas ~tool_name:"test" ~schema ~args with
  | Pass -> ()
  | Proceed _ -> ()
  | Reject r -> Alcotest.fail (Yojson.Safe.to_string (Tool_result.data r))

let test_null_args_with_required () =
  let schema = make_schema ~required:["name"] [("name", "string")] in
  let args = `Null in
  match validate_via_oas ~tool_name:"test" ~schema ~args with
  | Reject _ -> ()
  | Pass | Proceed _ -> Alcotest.fail "Expected Reject for null args with required fields"

let test_extra_fields_allowed () =
  let schema = make_schema ~required:["name"] [("name", "string")] in
  let args = `Assoc [("name", `String "alice"); ("extra", `Int 42)] in
  match validate_via_oas ~tool_name:"test" ~schema ~args with
  | Pass -> ()
  | Proceed _ -> ()
  | Reject r -> Alcotest.fail (Yojson.Safe.to_string (Tool_result.data r))

let test_empty_schema_allows_empty_args () =
  let schema = `Assoc [] in
  match
    Tool_input_validation.validate_args
      ~schema
      ~name:"__tool_input_validation_empty_schema_empty_args"
      ~args:(`Assoc [])
      ()
  with
  | Ok (`Assoc []) -> ()
  | Ok forwarded ->
    Alcotest.failf
      "expected empty args to pass unchanged, got %s"
      (Yojson.Safe.to_string forwarded)
  | Error result ->
    Alcotest.failf
      "expected empty schema with empty args to pass, got %s"
      (Yojson.Safe.to_string (Tool_result.data result))

let test_empty_schema_rejects_arguments () =
  let schema = `Assoc [] in
  match
    Tool_input_validation.validate_args
      ~schema
      ~name:"__tool_input_validation_empty_schema_rejects_args"
      ~args:(`Assoc [ "anything", `String "goes" ])
      ()
  with
  | Error result ->
    let msg = Yojson.Safe.to_string (Tool_result.data result) in
    Alcotest.(check bool) "reason is empty_schema_args" true
      (string_contains msg "empty_schema_args")
  | Ok forwarded ->
    Alcotest.failf
      "expected empty schema with arguments to fail, got %s"
      (Yojson.Safe.to_string forwarded)

let test_required_without_properties_rejects_schema () =
  let schema = `Assoc [ "required", `List [ `String "name" ] ] in
  match
    Tool_input_validation.validate_args
      ~schema
      ~name:"__tool_input_validation_malformed_schema"
      ~args:(`Assoc [])
      ()
  with
  | Error result ->
    let msg = Yojson.Safe.to_string (Tool_result.data result) in
    Alcotest.(check bool) "reason is malformed_schema" true
      (string_contains msg "malformed_schema")
  | Ok forwarded ->
    Alcotest.failf
      "expected malformed schema to fail, got %s"
      (Yojson.Safe.to_string forwarded)

let test_schema_union_type_does_not_raise () =
  let schema =
    `Assoc
      [
        ("type", `String "object");
        ( "properties",
          `Assoc
            [
              ( "payload",
                `Assoc
                  [
                    ( "type",
                      `List
                        [ `String "object"; `String "string"; `String "array" ]
                    );
                    ("description", `String "A generic union-typed payload.");
                  ] );
            ] );
      ]
  in
  match Tool_bridge.params_of_json_schema schema with
  | [ (param : Agent_sdk.Types.tool_param) ] ->
      Alcotest.(check string)
        "name"
        "payload"
        param.name;
      Alcotest.(check bool) "optional" false param.required;
      (match param.param_type with
       | Agent_sdk.Types.Object -> ()
       | _ -> Alcotest.fail "expected first non-null union type to be object")
  | params ->
      Alcotest.failf "expected one converted parameter, got %d"
        (List.length params)

(* ================================================================ *)
(* Test: registered pre-hook path                                    *)
(* ================================================================ *)

let test_registered_hook_coerces_args () =
  let args = `Assoc [("count", `String "42")] in
  let blocked, forwarded =
    run_registered_hook
      ~schema:(make_schema [("count", "integer")])
      ~tool_name:"__tool_input_validation_registered_coerce"
      ~args
      ()
  in
  Alcotest.(check bool) "not blocked" true (Option.is_none blocked);
  Alcotest.(check bool) "coercion changed args" false
    (Yojson.Safe.equal forwarded args);
  match Yojson.Safe.Util.member "count" forwarded with
  | `Int 42 -> ()
  | _ -> Alcotest.fail "expected integer coercion through registered pre-hook"

let test_registered_hook_keeps_noop_as_pass () =
  let args = `Assoc [("count", `Int 42)] in
  let blocked, forwarded =
    run_registered_hook
      ~schema:(make_schema [("count", "integer")])
      ~tool_name:"__tool_input_validation_registered_noop"
      ~args
      ()
  in
  Alcotest.(check bool) "not blocked" true (Option.is_none blocked);
  Alcotest.(check bool) "args unchanged" true
    (Yojson.Safe.equal forwarded args)

let test_registered_hook_rejects_unknown_tool () =
  let args = `Assoc [("count", `String "42")] in
  let blocked, forwarded =
    run_registered_hook
      ~tool_name:"__tool_input_validation_registered_unknown"
      ~args
      ()
  in
  Alcotest.(check bool) "blocked" true (Option.is_some blocked);
  Alcotest.(check bool) "args unchanged on rejection" true
    (Yojson.Safe.equal forwarded args);
  match blocked with
  | Some result ->
    let msg = Yojson.Safe.to_string (Tool_result.data result) in
    Alcotest.(check bool) "reason is missing_schema" true
      (string_contains msg "missing_schema")
  | None -> Alcotest.fail "expected missing-schema rejection"

let test_registered_hook_rejects_empty_schema_arguments () =
  let args = `Assoc [("anything", `String "goes")] in
  let blocked, forwarded =
    run_registered_hook
      ~schema:(`Assoc [])
      ~tool_name:"__tool_input_validation_registered_empty"
      ~args
      ()
  in
  Alcotest.(check bool) "blocked" true (Option.is_some blocked);
  Alcotest.(check bool) "args unchanged on rejection" true
    (Yojson.Safe.equal forwarded args);
  match blocked with
  | Some result ->
    let msg = Yojson.Safe.to_string (Tool_result.data result) in
    Alcotest.(check bool) "reason is empty_schema_args" true
      (string_contains msg "empty_schema_args")
  | None -> Alcotest.fail "expected empty-schema argument rejection"

let test_registered_hook_allows_empty_schema_without_arguments () =
  let args = `Assoc [] in
  let blocked, forwarded =
    run_registered_hook
      ~schema:(`Assoc [])
      ~tool_name:"__tool_input_validation_registered_empty_no_args"
      ~args
      ()
  in
  Alcotest.(check bool) "not blocked" true (Option.is_none blocked);
  Alcotest.(check bool) "args unchanged" true (Yojson.Safe.equal forwarded args)

let test_validate_args_uses_explicit_schema_without_registry () =
  Tool_dispatch.clear_hooks ();
  let schema = make_schema ~required:["path"] [("path", "string")] in
  match
    Tool_input_validation.validate_args
      ~schema
      ~name:"__tool_input_validation_direct_schema"
      ~args:(`Assoc [])
      ()
  with
  | Error result ->
    let msg = Yojson.Safe.to_string (Tool_result.data result) in
    Alcotest.(check bool) "mentions missing path" true
      (string_contains msg "path");
    Alcotest.(check bool) "marks oas validation" true
      (string_contains msg "oas_tool_middleware")
  | Ok _ -> Alcotest.fail "Expected Error for missing required field"

let find_schema_exn name schemas =
  match List.find_opt (fun (schema : Masc_domain.tool_schema) -> String.equal schema.name name) schemas with
  | Some schema -> schema.input_schema
  | None -> failwith ("missing schema: " ^ name)

let masc_transition_schema =
  find_schema_exn "masc_transition" Task.Schemas.schemas

let masc_goal_list_schema =
  find_schema_exn "masc_goal_list" Tool_schemas_workspace_extra.schemas

let tool_edit_file_schema =
  find_schema_exn "tool_edit_file" Config.raw_all_tool_schemas

let keeper_board_post_schema =
  find_schema_exn "keeper_board_post" Config.raw_all_tool_schemas

let keeper_board_list_schema =
  find_schema_exn "keeper_board_list" Config.raw_all_tool_schemas

let keeper_board_search_schema =
  find_schema_exn "keeper_board_search" Config.raw_all_tool_schemas

let keeper_board_post_get_schema =
  find_schema_exn "keeper_board_post_get" Config.raw_all_tool_schemas

let keeper_task_done_schema =
  find_schema_exn "keeper_task_done" Config.raw_all_tool_schemas

let keeper_task_claim_schema =
  find_schema_exn "keeper_task_claim" Config.raw_all_tool_schemas

let tool_execute_schema =
  find_schema_exn "tool_execute" Config.raw_all_tool_schemas


let assoc_string key json =
  match Yojson.Safe.Util.member key json with
  | `String value -> value
  | _ -> failwith ("expected string field: " ^ key)

let assert_policy_validation_payload ~label result =
  let data = Tool_result.data result in
  Alcotest.(check string)
    (label ^ " reason")
    "invalid_args"
    (assoc_string "reason" data);
  Alcotest.(check string)
    (label ^ " failure_class payload")
    "policy_rejection"
    (assoc_string "failure_class" data);
  Alcotest.(check bool)
    (label ^ " typed failure_class")
    true
    (Tool_result.failure_class result = Some Tool_result.Policy_rejection)

let test_registered_hook_tool_edit_file_patch_args () =
  let args =
    `Assoc
      [ "path", `String "repos/masc/.worktrees/task/lib/foo.ml"
      ; "mode", `String "patch"
      ; "old_string", `String "let x = 1"
      ; "new_string", `String "let x = 2"
      ; "replace_all", `Bool false
      ]
  in
  let blocked, forwarded =
    run_registered_hook
      ~schema:tool_edit_file_schema
      ~tool_name:"tool_edit_file"
      ~args
      ()
  in
  Alcotest.(check bool) "not blocked" true (Option.is_none blocked);
  Alcotest.(check bool) "args unchanged" true
    (Yojson.Safe.equal forwarded args)

let keeper_board_post_sources_args =
  `Assoc
    [ "content", `String "Keeper board post validation regression"
    ; "hearth", `String "ops"
    ; ( "sources"
      , `List
          [ `Assoc
              [ "url", `String "https://example.com/evidence"
              ; "quote", `String "short supporting snippet"
              ]
          ] )
    ; "judgment", `Assoc [ "summary", `String "sources array should pass" ]
    ]

let check_keeper_board_post_sources_preserved forwarded =
  match Yojson.Safe.Util.member "sources" forwarded with
  | `List [ `Assoc source_fields ] ->
    Alcotest.(check (option string))
      "source url preserved"
      (Some "https://example.com/evidence")
      (match List.assoc_opt "url" source_fields with
       | Some (`String value) -> Some value
       | _ -> None)
  | other ->
    Alcotest.failf
      "expected sources array to be preserved, got %s"
      (Yojson.Safe.to_string other)

let test_validate_args_keeper_board_post_accepts_sources_array () =
  match
    Tool_input_validation.validate_args
      ~schema:keeper_board_post_schema
      ~name:"keeper_board_post"
      ~args:keeper_board_post_sources_args
      ()
  with
  | Ok forwarded -> check_keeper_board_post_sources_preserved forwarded
  | Error result ->
    Alcotest.failf
      "expected keeper_board_post sources array to pass validation, got %s"
      (Yojson.Safe.to_string (Tool_result.data result))

let test_registered_hook_keeper_board_post_accepts_sources_array () =
  let blocked, forwarded =
    run_registered_hook
      ~schema:keeper_board_post_schema
      ~tool_name:"keeper_board_post"
      ~args:keeper_board_post_sources_args
      ()
  in
  Alcotest.(check bool) "not blocked" true (Option.is_none blocked);
  check_keeper_board_post_sources_preserved forwarded

(* Regression: the board_list/search backends already read [compact]
   (board_tool_post.ml handle_post_list_uncached, board_tool_handlers.ml
   handle_search), but the keeper_board_* schemas omitted it, so
   qa-king's keeper_board_list compact=true was rejected as an
   unsupported field. Assert the keeper surface now accepts compact while
   additionalProperties stays false (unknown fields still rejected). *)
let test_validate_args_keeper_board_list_accepts_compact () =
  match
    Tool_input_validation.validate_args
      ~schema:keeper_board_list_schema
      ~name:"keeper_board_list"
      ~args:(`Assoc [ "limit", `Int 5; "compact", `Bool false ])
      ()
  with
  | Ok _ -> ()
  | Error result ->
    Alcotest.failf
      "expected keeper_board_list compact arg to pass validation, got %s"
      (Yojson.Safe.to_string (Tool_result.data result))

let test_validate_args_keeper_board_search_accepts_compact () =
  match
    Tool_input_validation.validate_args
      ~schema:keeper_board_search_schema
      ~name:"keeper_board_search"
      ~args:(`Assoc [ "query", `String "x"; "compact", `Bool false ])
      ()
  with
  | Ok _ -> ()
  | Error result ->
    Alcotest.failf
      "expected keeper_board_search compact arg to pass validation, got %s"
      (Yojson.Safe.to_string (Tool_result.data result))

(* Guard the other direction: a genuinely unknown field must still be
   rejected (additionalProperties:false not loosened). *)
let test_validate_args_keeper_board_list_rejects_unknown_field () =
  match
    Tool_input_validation.validate_args
      ~schema:keeper_board_list_schema
      ~name:"keeper_board_list"
      ~args:(`Assoc [ "limit", `Int 5; "definitely_not_a_field", `Bool true ])
      ()
  with
  | Ok forwarded ->
    Alcotest.failf
      "expected unknown field to be rejected, but it passed: %s"
      (Yojson.Safe.to_string forwarded)
  | Error _ -> ()

(* The op enum (derived from Keeper_workspace_op.valid_strings) must accept
   EVERY op the runtime dispatch handles. Guards the regression where the
   enum is hand-listed with only the directory-listing ops, silently
   breaking cat/pwd/find/head/tail/wc/git_log/git_diff. *)
let param_by_name name params =
  List.find_opt
    (fun (param : Agent_sdk.Types.tool_param) -> String.equal param.name name)
    params

let legacy_background_flag_name = "run_" ^ "in_background"

let execute_async_lifecycle_field_names =
  [ legacy_background_flag_name
  ; "job_id"
  ; "request_id"
  ; "backgroundTaskId"
  ; "poll"
  ; "cancel"
  ]

let check_param_type name expected params =
  match param_by_name name params with
  | Some (param : Agent_sdk.Types.tool_param) ->
    Alcotest.(check bool)
      (name ^ " is optional at OAS boundary")
      false
      param.required;
    Alcotest.(check string)
      (name ^ " param type")
      expected
      (match param.param_type with
       | Agent_sdk.Types.String -> "string"
       | Integer -> "integer"
       | Number -> "number"
       | Boolean -> "boolean"
       | Array -> "array"
       | Object -> "object")
  | None -> Alcotest.failf "missing param: %s" name

let test_tool_execute_schema_exposes_typed_boundary () =
  let params = Tool_bridge.params_of_json_schema tool_execute_schema in
  Alcotest.(check bool)
    "retired executable field is not exposed"
    true
    (Option.is_none (param_by_name "executable" params));
  check_param_type "argv" "array" params;
  check_param_type "pipeline" "array" params;
  check_param_type "env" "object" params;
  Alcotest.(check bool)
    "stages alias rejected by schema" true
    (Option.is_none (param_by_name "stages" params));
  Alcotest.(check bool)
    "legacy background flag not exposed"
    true
    (Option.is_none (param_by_name legacy_background_flag_name params));
  List.iter
    (fun field ->
      Alcotest.(check bool)
        (field ^ " async lifecycle field not exposed")
        true
        (Option.is_none (param_by_name field params)))
    execute_async_lifecycle_field_names

let test_validate_args_tool_execute_rejects_empty_object_with_policy_class () =
  let args = `Assoc [] in
  match
    Tool_input_validation.validate_args
      ~schema:tool_execute_schema
      ~name:"tool_execute"
      ~args
      ()
  with
  | Error result ->
    let msg = Yojson.Safe.to_string (Tool_result.data result) in
    Alcotest.(check bool)
      "empty Execute mentions exact-one-of"
      true
      (string_contains msg "exactly one of");
    assert_policy_validation_payload ~label:"empty Execute" result
  | Ok forwarded ->
    Alcotest.failf
      "expected empty tool_execute args to fail, got %s"
      (Yojson.Safe.to_string forwarded)

let test_validate_args_tool_execute_rejects_cmd_string () =
  let args = `Assoc [ "cmd", `String "pwd" ] in
  match
    Tool_input_validation.validate_args
      ~schema:tool_execute_schema
      ~name:"tool_execute"
      ~args
      ()
  with
  | Ok _ -> Alcotest.fail "expected tool_execute cmd string to be rejected"
  | Error result ->
    let msg = Yojson.Safe.to_string (Tool_result.data result) in
    Alcotest.(check bool)
      "validation error returned"
      true
      (String.length msg > 0);
    assert_policy_validation_payload ~label:"cmd string" result;
    Alcotest.(check bool)
      "validation error points to typed argv"
      true
      (string_contains msg "argv=[\\\"git\\\",\\\"status\\\",\\\"--short\\\"]")

let test_validate_args_tool_execute_rejects_command_string () =
  let args = `Assoc [ "command", `String "pwd" ] in
  match
    Tool_input_validation.validate_args
      ~schema:tool_execute_schema
      ~name:"tool_execute"
      ~args
      ()
  with
  | Ok _ -> Alcotest.fail "expected tool_execute command string to be rejected"
  | Error result ->
    let msg = Yojson.Safe.to_string (Tool_result.data result) in
    Alcotest.(check bool)
      "validation error mentions unsupported command field"
      true
      (string_contains msg "unsupported field(s): command");
    Alcotest.(check bool)
      "validation error says command field is unavailable"
      true
      (string_contains msg "no cmd/command field")

let test_validate_args_tool_execute_rejects_background_flag () =
  let args =
    `Assoc
      [ "argv", `List [ `String "pwd" ]; legacy_background_flag_name, `Bool true ]
  in
  match
    Tool_input_validation.validate_args
      ~schema:tool_execute_schema
      ~name:"tool_execute"
      ~args
      ()
  with
  | Ok _ -> Alcotest.fail "expected tool_execute background flag to be rejected"
  | Error result ->
    let msg = Yojson.Safe.to_string (Tool_result.data result) in
    Alcotest.(check bool) "mentions legacy background flag" true
      (string_contains msg legacy_background_flag_name)

let test_validate_args_tool_execute_rejects_async_lifecycle_fields () =
  let cases =
    [ legacy_background_flag_name, `Bool true
    ; "job_id", `String "job-123"
    ; "request_id", `String "req-123"
    ; "backgroundTaskId", `String "bg-123"
    ; "poll", `Bool true
    ; "cancel", `Bool true
    ]
  in
  List.iter
    (fun (field, value) ->
      let args = `Assoc [ "argv", `List [ `String "pwd" ]; field, value ] in
      match
        Tool_input_validation.validate_args
          ~schema:tool_execute_schema
          ~name:"tool_execute"
          ~args
          ()
      with
      | Ok _ ->
          Alcotest.failf
            "expected tool_execute async lifecycle field %s to be rejected"
            field
      | Error result ->
          let msg = Yojson.Safe.to_string (Tool_result.data result) in
          Alcotest.(check bool)
            ("mentions async lifecycle field " ^ field)
            true
            (string_contains msg field))
    cases

let test_validate_args_tool_execute_accepts_typed_exec () =
  let args =
    `Assoc
      [ "argv", `List [ `String "rg"; `String "--files"; `String "lib" ]
      ; "cwd", `String "/tmp"
      ; "env", `Assoc [ "NO_COLOR", `String "1" ]
      ]
  in
  match
    Tool_input_validation.validate_args
      ~schema:tool_execute_schema
      ~name:"tool_execute"
      ~args
      ()
  with
  | Ok forwarded ->
    Alcotest.(check bool) "args unchanged" true (Yojson.Safe.equal args forwarded)
  | Error result ->
    Alcotest.failf
      "expected typed tool_execute exec to pass validation, got %s"
      (Yojson.Safe.to_string (Tool_result.data result))

let test_validate_args_tool_execute_rejects_json_string_argv () =
  let args =
    `Assoc
      [ "argv", `String "[\"git\",\"status\",\"--short\"]"
      ; "cwd", `String "/tmp"
      ]
  in
  match
    Tool_input_validation.validate_args
      ~schema:tool_execute_schema
      ~name:"tool_execute"
      ~args
      ()
  with
  | Error result ->
    let msg = Yojson.Safe.to_string (Tool_result.data result) in
    Alcotest.(check bool)
      "json-string argv remains a schema violation"
      true
      (string_contains msg "expected: array")
  | Ok forwarded ->
    Alcotest.failf
      "expected json-string argv to be rejected, got %s"
      (Yojson.Safe.to_string forwarded)

let test_validate_args_tool_execute_accepts_typed_pipeline () =
  let args =
    `Assoc
      [ ( "pipeline"
        , `List
            [ `Assoc
                [ "argv", `List [ `String "rg"; `String "--files"; `String "lib" ] ]
            ; `Assoc
                [ "argv", `List [ `String "head"; `String "-20" ] ]
            ] )
      ; "cwd", `String "/tmp"
      ]
  in
  match
    Tool_input_validation.validate_args
      ~schema:tool_execute_schema
      ~name:"tool_execute"
      ~args
      ()
  with
  | Ok forwarded ->
    Alcotest.(check bool) "pipeline preserved" true (Yojson.Safe.equal args forwarded)
  | Error result ->
    Alcotest.failf
      "expected typed tool_execute pipeline to pass validation, got %s"
      (Yojson.Safe.to_string (Tool_result.data result))

let test_validate_args_masc_transition_rejects_json_string_handoff_context () =
  let args =
    `Assoc
      [ "agent_name", `String "codex-local-admin"
      ; "task_id", `String "task-1823"
      ; "action", `String "release"
      ; ( "handoff_context"
        , `String
            "{\"summary\":\"task-1823 edits applied\",\"evidence_refs\":[\"board:task-1823\"]}"
        )
      ]
  in
  match
    Tool_input_validation.validate_args
      ~schema:masc_transition_schema
      ~name:"masc_transition"
      ~args
      ()
  with
  | Error result ->
    let msg = Yojson.Safe.to_string (Tool_result.data result) in
    Alcotest.(check bool)
      "json-string handoff remains a schema violation"
      true
      (string_contains msg "expected: object")
  | Ok forwarded ->
    Alcotest.failf
      "expected json-string handoff_context to be rejected, got %s"
      (Yojson.Safe.to_string forwarded)

let test_validate_args_execute_rejects_args_object_envelope () =
  let inner =
    `Assoc
      [ "argv", `List [ `String "git"; `String "status"; `String "--short" ]
      ; "cwd", `String "/tmp"
      ]
  in
  let args = `Assoc [ "args", inner ] in
  match
    Tool_input_validation.validate_args
      ~schema:tool_execute_schema
      ~name:"Execute"
      ~args
      ()
  with
  | Error result ->
    let msg = Yojson.Safe.to_string (Tool_result.data result) in
    Alcotest.(check bool)
      "args object envelope is unsupported"
      true
      (string_contains msg "unsupported field(s): args")
  | Ok forwarded ->
    Alcotest.failf
      "expected Execute args object envelope to be rejected, got %s"
      (Yojson.Safe.to_string forwarded)

let test_validate_args_tool_execute_rejects_args_object_envelope () =
  let inner = `Assoc [ "argv", `List [ `String "pwd" ] ] in
  let args = `Assoc [ "args", inner ] in
  match
    Tool_input_validation.validate_args
      ~schema:tool_execute_schema
      ~name:"tool_execute"
      ~args
      ()
  with
  | Error result ->
    let msg = Yojson.Safe.to_string (Tool_result.data result) in
    Alcotest.(check bool)
      "internal args object envelope is unsupported"
      true
      (string_contains msg "unsupported field(s): args")
  | Ok forwarded ->
    Alcotest.failf
      "expected tool_execute args object envelope to be rejected, got %s"
      (Yojson.Safe.to_string forwarded)

let test_validate_args_execute_rejects_pipeline_envelope () =
  let inner =
    `Assoc
      [ ( "pipeline"
        , `List
            [ `Assoc [ "argv", `List [ `String "printf"; `String "x" ] ]
            ; `Assoc [ "argv", `List [ `String "cat" ] ]
            ] )
      ]
  in
  let args = `Assoc [ "args", inner ] in
  match
    Tool_input_validation.validate_args
      ~schema:tool_execute_schema
      ~name:"Execute"
      ~args
      ()
  with
  | Error result ->
    let msg = Yojson.Safe.to_string (Tool_result.data result) in
    Alcotest.(check bool)
      "pipeline args envelope is unsupported"
      true
      (string_contains msg "unsupported field(s): args")
  | Ok forwarded ->
    Alcotest.failf
      "expected Execute pipeline args envelope to be rejected, got %s"
      (Yojson.Safe.to_string forwarded)

let test_validate_args_execute_rejects_args_array_envelope () =
  let args = `Assoc [ "args", `List [ `String "git"; `String "status" ] ] in
  match
    Tool_input_validation.validate_args
      ~schema:tool_execute_schema
      ~name:"Execute"
      ~args
      ()
  with
  | Ok forwarded ->
    Alcotest.failf
      "expected Execute args array envelope to be rejected, got %s"
      (Yojson.Safe.to_string forwarded)
  | Error result ->
    let msg = Yojson.Safe.to_string (Tool_result.data result) in
    Alcotest.(check bool)
      "unsupported args field remains rejected"
      true
      (string_contains msg "unsupported field(s): args")

let test_validate_args_execute_rejects_mixed_args_envelope () =
  let args =
    `Assoc
      [ ( "args"
        , `Assoc
            [ "argv", `List [ `String "git"; `String "status" ] ] )
      ; "cwd", `String "/tmp"
      ]
  in
  match
    Tool_input_validation.validate_args
      ~schema:tool_execute_schema
      ~name:"Execute"
      ~args
      ()
  with
  | Ok forwarded ->
    Alcotest.failf
      "expected mixed Execute args envelope to be rejected, got %s"
      (Yojson.Safe.to_string forwarded)
  | Error result ->
    let msg = Yojson.Safe.to_string (Tool_result.data result) in
    Alcotest.(check bool)
      "mixed envelope keeps args unsupported"
      true
      (string_contains msg "unsupported field(s): args")

let test_validate_args_non_execute_rejects_args_object_envelope () =
  let args =
    `Assoc [ "args", `Assoc [ "argv", `List [ `String "git" ] ] ]
  in
  match
    Tool_input_validation.validate_args
      ~schema:tool_execute_schema
      ~name:"not_execute"
      ~args
      ()
  with
  | Ok forwarded ->
    Alcotest.failf
      "expected non-Execute args envelope to be rejected, got %s"
      (Yojson.Safe.to_string forwarded)
  | Error result ->
    let msg = Yojson.Safe.to_string (Tool_result.data result) in
    Alcotest.(check bool)
      "non-Execute args envelope remains unsupported"
      true
      (string_contains msg "unsupported field(s): args")

let readonly_exec_input program arguments =
  match
    Keeper_tool_execute_typed_input.of_json
      (`Assoc
        [ "argv", `List (List.map (fun arg -> `String arg) (program :: arguments))
        ; "cwd", `String "/tmp"
        ])
  with
  | Ok input -> input
  | Error msg ->
    Alcotest.failf "expected typed Execute parse to pass, got %s" msg

let readonly_pipeline_input stages =
  match
    Keeper_tool_execute_typed_input.of_json
      (`Assoc
        [ ( "pipeline"
          , `List
              (List.map
                 (fun (program, arguments) ->
                    `Assoc
                      [ ( "argv"
                        , `List
                            (List.map
                               (fun arg -> `String arg)
                               (program :: arguments)) ) ])
                 stages) )
        ; "cwd", `String "/tmp"
        ])
  with
  | Ok input -> input
  | Error msg ->
    Alcotest.failf "expected typed Execute pipeline parse to pass, got %s" msg

let test_tool_execute_write_validation_stays_structural () =
  match
    Keeper_tool_execute_typed_input.validate
      (readonly_exec_input "python3" [ "-c"; "print(1)" ])
  with
  | Ok () -> ()
  | Error e ->
    Alcotest.failf
      "write-capable structural validation should not reject program: %s"
      (Keeper_tool_execute_input.typed_validation_error_text e)

let tool_execute_exec_stage args =
  match Keeper_tool_execute_typed_input.of_json args with
  | Ok (Keeper_tool_execute_typed_input.Exec { argv = program :: arguments; _ }) ->
    program, arguments
  | Ok (Keeper_tool_execute_typed_input.Exec { argv = []; _ }) ->
    Alcotest.fail "expected non-empty argv"
  | Ok (Keeper_tool_execute_typed_input.Pipeline _) ->
    Alcotest.fail "expected exec input"
  | Error msg ->
    Alcotest.failf "expected typed tool_execute parse to pass, got %s" msg

let tool_execute_exec_argv args = snd (tool_execute_exec_stage args)

let test_tool_execute_find_expression_not_rewritten () =
  let argv =
    tool_execute_exec_argv
      (`Assoc
        [ ( "argv"
          , `List
              [ `String "find"
              ; `String "-type"
              ; `String "f"
              ; `String "-name"
              ; `String "*.ml"
              ] ) ])
  in
  Alcotest.(check (list string))
    "find expression remains caller-authored"
    [ "-type"; "f"; "-name"; "*.ml" ]
    argv

let test_tool_execute_find_global_option_not_rewritten () =
  let argv =
    tool_execute_exec_argv
      (`Assoc
        [ "argv"
        , `List [ `String "find"; `String "-E"; `String "-type"; `String "f" ]
        ])
  in
  Alcotest.(check (list string))
    "find global option remains caller-authored"
    [ "-E"; "-type"; "f" ]
    argv

let test_tool_execute_empty_program_not_promoted () =
  let program, argv =
    tool_execute_exec_stage
      (`Assoc
        [ "argv"
        , `List [ `String ""; `String "find"; `String "-type"; `String "f" ]
        ])
  in
  Alcotest.(check string) "empty program preserved" "" program;
  Alcotest.(check (list string))
    "argv0 command is not promoted"
    [ "find"; "-type"; "f" ]
    argv

let test_tool_execute_pipeline_find_expression_not_rewritten () =
  match
    Keeper_tool_execute_typed_input.of_json
      (`Assoc
        [ ( "pipeline"
          , `List
              [ `Assoc
                  [ "argv", `List [ `String "find"; `String "-type"; `String "f" ] ]
              ; `Assoc [ "argv", `List [ `String "head"; `String "-5" ] ]
              ] )
        ])
  with
  | Ok
      (Keeper_tool_execute_typed_input.Pipeline
        { stages = { Keeper_tool_execute_typed_input.argv = argv; _ } :: _; _ }) ->
    Alcotest.(check (list string))
      "pipeline find stage remains caller-authored"
      [ "find"; "-type"; "f" ]
      argv
  | Ok (Keeper_tool_execute_typed_input.Pipeline { stages = []; _ }) ->
    Alcotest.fail "expected non-empty pipeline"
  | Ok (Keeper_tool_execute_typed_input.Exec _) -> Alcotest.fail "expected pipeline input"
  | Error msg ->
    Alcotest.failf "expected typed tool_execute pipeline parse to pass, got %s" msg

let test_validate_args_tool_execute_rejects_bad_argv_type () =
  let args =
    `Assoc [ "argv", `String "rg --files lib" ]
  in
  match
    Tool_input_validation.validate_args
      ~schema:tool_execute_schema
      ~name:"tool_execute"
      ~args
      ()
  with
  | Error result ->
    let msg = Yojson.Safe.to_string (Tool_result.data result) in
    Alcotest.(check bool) "mentions argv" true (string_contains msg "argv")
  | Ok forwarded ->
    Alcotest.failf
      "expected typed tool_execute argv string to fail, got %s"
      (Yojson.Safe.to_string forwarded)

let validation_labels ~tool ~result ~reason =
  [ "tool", tool; "result", result; "reason", reason ]

let validation_metric_value ~tool ~result ~reason =
  Otel_metric_store.metric_value_or_zero
    Otel_metric_store.metric_tool_input_validation
    ~labels:(validation_labels ~tool ~result ~reason)
    ()

let check_validation_metric_increment ~tool ~result ~reason f =
  let before = validation_metric_value ~tool ~result ~reason in
  f ();
  let after = validation_metric_value ~tool ~result ~reason in
  Alcotest.(check (float 0.0001))
    (Printf.sprintf "metric %s/%s/%s increments" tool result reason)
    (before +. 1.0)
    after

let attr_string key attrs =
  match List.assoc_opt key attrs with
  | Some (`String value) -> Some value
  | _ -> None

let test_validation_telemetry_records_pass_and_fail_counters () =
  let valid_tool = "__tool_input_validation_metric_valid" in
  let valid_schema = make_schema [ "count", "integer" ] in
  check_validation_metric_increment
    ~tool:valid_tool
    ~result:"pass"
    ~reason:"valid"
    (fun () ->
       match
         Tool_input_validation.validate_args
           ~schema:valid_schema
           ~name:valid_tool
           ~args:(`Assoc [ "count", `Int 42 ])
           ()
       with
       | Ok _ -> ()
       | Error result ->
         Alcotest.fail
           (Printf.sprintf
              "expected valid input, got %s"
              (Yojson.Safe.to_string (Tool_result.data result))));
  let coerced_tool = "__tool_input_validation_metric_coerced" in
  check_validation_metric_increment
    ~tool:coerced_tool
    ~result:"pass"
    ~reason:"coerced"
    (fun () ->
       match
         Tool_input_validation.validate_args
           ~schema:valid_schema
           ~name:coerced_tool
           ~args:(`Assoc [ "count", `String "42" ])
           ()
       with
       | Ok coerced ->
         (match Yojson.Safe.Util.member "count" coerced with
          | `Int 42 -> ()
          | _ -> Alcotest.fail "expected coerced integer")
       | Error result ->
         Alcotest.fail
           (Printf.sprintf
              "expected coerced input, got %s"
              (Yojson.Safe.to_string (Tool_result.data result))));
  let fail_tool = "__tool_input_validation_metric_fail" in
  check_validation_metric_increment
    ~tool:fail_tool
    ~result:"fail"
    ~reason:"invalid_args"
    (fun () ->
       match
         Tool_input_validation.validate_args
           ~schema:valid_schema
           ~name:fail_tool
           ~args:(`Assoc [ "count", `String "not-an-int" ])
           ()
       with
       | Error _ -> ()
       | Ok _ -> Alcotest.fail "expected invalid args failure");
  let missing_tool = "__tool_input_validation_metric_missing_schema" in
  check_validation_metric_increment
    ~tool:missing_tool
    ~result:"fail"
    ~reason:"missing_schema"
    (fun () ->
       match
         Tool_input_validation.validate_args
           ~name:missing_tool
           ~args:(`Assoc [ "count", `String "not-validated" ])
           ()
       with
       | Error _ -> ()
       | Ok forwarded ->
         Alcotest.fail
           (Printf.sprintf
              "expected missing schema failure, got %s"
              (Yojson.Safe.to_string forwarded)));
  let empty_tool = "__tool_input_validation_metric_empty_schema" in
  check_validation_metric_increment
    ~tool:empty_tool
    ~result:"pass"
    ~reason:"empty_schema"
    (fun () ->
       match
         Tool_input_validation.validate_args
           ~schema:(`Assoc [])
           ~name:empty_tool
           ~args:(`Assoc [])
           ()
       with
       | Ok _ -> ()
       | Error result ->
         Alcotest.fail
           (Printf.sprintf
              "expected empty schema no-arg pass, got %s"
              (Yojson.Safe.to_string (Tool_result.data result))))

let test_validation_telemetry_rejects_retired_transition_aliases () =
  check_validation_metric_increment
    ~tool:"masc_transition"
    ~result:"fail"
    ~reason:"invalid_args"
    (fun () ->
       match
         Tool_input_validation.validate_args
           ~schema:masc_transition_schema
           ~name:"masc_transition"
           ~args:
             (`Assoc
                [
                  "agent_name", `String "codex-local-admin";
                  "task_id", `String "task-239";
                  "action", `String "claim";
                  "to", `String "claimed";
                  "note", `String "PR #8308 Draft";
                ])
           ()
       with
       | Error result ->
         let msg = Yojson.Safe.to_string (Tool_result.data result) in
         Alcotest.(check bool) "mentions retired to" true (string_contains msg "to");
         Alcotest.(check bool) "mentions retired note" true (string_contains msg "note")
       | Ok forwarded ->
         Alcotest.fail
           (Printf.sprintf
              "expected transition alias rejection, got %s"
              (Yojson.Safe.to_string forwarded)))

let test_validation_telemetry_emits_otel_event () =
  let tool = "__tool_input_validation_otel_event" in
  let schema = make_schema ~required:[ "path" ] [ "path", "string" ] in
  let events = ref [] in
  Otel_spans.with_test_event_emitter
    ~enabled:true
    ~emit_event:(fun ~name ~attrs -> events := (name, attrs) :: !events)
    (fun () ->
       match
         Tool_input_validation.validate_args
           ~schema
           ~name:tool
           ~args:(`Assoc [])
           ()
       with
       | Error _ -> ()
       | Ok _ -> Alcotest.fail "expected validation failure");
  match !events with
  | [ event_name, attrs ] ->
    Alcotest.(check string)
      "event name"
      "tool.param.validation"
      event_name;
    Alcotest.(check (option string))
      "tool attr"
      (Some tool)
      (attr_string "tool.name" attrs);
    Alcotest.(check (option string))
      "validation result attr"
      (Some "fail")
      (attr_string "tool.param.validation.result" attrs);
    Alcotest.(check (option string))
      "validation reason attr"
      (Some "invalid_args")
      (attr_string "tool.param.validation.reason" attrs)
  | _ -> Alcotest.fail "expected exactly one validation event"

let test_registered_hook_transition_rejects_to_and_note () =
  let args =
    `Assoc
      [
        ("agent_name", `String "codex-local-admin");
        ("task_id", `String "task-239");
        ("action", `String "claim");
        ("to", `String "claimed");
        ("note", `String "PR #8308 Draft");
      ]
  in
  let blocked, forwarded =
    run_registered_hook
      ~schema:masc_transition_schema
      ~tool_name:"masc_transition"
      ~args
      ()
  in
  match blocked with
  | Some result ->
    let msg = Yojson.Safe.to_string (Tool_result.data result) in
    Alcotest.(check bool) "mentions to" true (string_contains msg "to");
    Alcotest.(check bool) "mentions note" true (string_contains msg "note")
  | None ->
    Alcotest.failf
      "expected transition aliases to be rejected, got forwarded=%s"
      (Yojson.Safe.to_string forwarded)

let test_registered_hook_transition_preserves_canonical_action () =
  let args =
    `Assoc
      [
        ("agent_name", `String "keeper-ani1999-agent");
        ("task_id", `String "task-193");
        ("action", `String "claim");
      ]
  in
  let blocked, forwarded =
    run_registered_hook
      ~schema:masc_transition_schema
      ~tool_name:"masc_transition"
      ~args
      ()
  in
  Alcotest.(check bool) "not blocked" true (Option.is_none blocked);
  Alcotest.(check string) "canonical action value preserved for handler" "claim"
    (assoc_string "action" forwarded)

let test_registered_hook_transition_strips_internal_agent_marker () =
  let args =
    `Assoc
      [
        ("_agent_name", `String "codex-local-admin");
        ("agent_name", `String "codex-local-admin");
        ("task_id", `String "task-216");
        ("action", `String "done");
      ]
  in
  let blocked, forwarded =
    run_registered_hook
      ~schema:masc_transition_schema
      ~tool_name:"masc_transition"
      ~args
      ()
  in
  Alcotest.(check bool) "not blocked" true (Option.is_none blocked);
  Alcotest.(check bool) "_agent_name removed before schema validation" true
    (Yojson.Safe.Util.member "_agent_name" forwarded = `Null);
  Alcotest.(check string) "agent_name preserved" "codex-local-admin"
    (assoc_string "agent_name" forwarded)

let test_registered_hook_goal_list_strips_blank_optional_enums () =
  let args =
    `Assoc
      [
        ("phase", `String " ");
      ]
  in
  let blocked, forwarded =
    run_registered_hook
      ~schema:masc_goal_list_schema
      ~tool_name:"masc_goal_list"
      ~args
      ()
  in
  Alcotest.(check bool) "not blocked" true (Option.is_none blocked);
  Alcotest.(check bool) "phase removed" true
    (Yojson.Safe.Util.member "phase" forwarded = `Null)

let test_registered_hook_goal_list_rejects_status_filter () =
  let args = `Assoc [ ("status", `String "active") ] in
  let blocked, _forwarded =
    run_registered_hook
      ~schema:masc_goal_list_schema
      ~tool_name:"masc_goal_list"
      ~args
      ()
  in
  Alcotest.(check bool) "blocked" true (Option.is_some blocked)

let test_registered_hook_goal_list_preserves_invalid_enum_for_handler () =
  (* RFC-0294: horizon removed; phase is the surviving optional enum. An invalid
     enum value must pass the hook so the handler performs the rejection. *)
  let args = `Assoc [("phase", `String "notaphase")] in
  let blocked, forwarded =
    run_registered_hook
      ~schema:masc_goal_list_schema
      ~tool_name:"masc_goal_list"
      ~args
      ()
  in
  Alcotest.(check bool) "not blocked" true (Option.is_none blocked);
  Alcotest.(check string) "invalid value preserved for handler validation" "notaphase"
    (assoc_string "phase" forwarded)

let test_registered_hook_required_enum_blank_is_not_stripped () =
  let schema =
    `Assoc
      [
        ("type", `String "object");
        ( "properties",
          `Assoc
            [
              ( "mode",
                `Assoc
                  [
                    ("type", `String "string");
                    ("enum", `List [ `String "strict"; `String "lenient" ]);
                  ] );
            ] );
        ("required", `List [ `String "mode" ]);
      ]
  in
  let args = `Assoc [("mode", `String "")] in
  let blocked, forwarded =
    run_registered_hook
      ~schema
      ~tool_name:"__tool_input_validation_required_enum_blank"
      ~args
      ()
  in
  Alcotest.(check bool) "not blocked" true (Option.is_none blocked);
  Alcotest.(check string) "required blank preserved for handler validation" ""
    (assoc_string "mode" forwarded)

let schema_required_fields schema =
  match Yojson.Safe.Util.member "required" schema with
  | `List values ->
    List.filter_map (function `String value -> Some value | _ -> None) values
  | _ -> []

let assert_schema_requires label schema field =
  Alcotest.(check bool)
    (label ^ " requires " ^ field)
    true
    (List.mem field (schema_required_fields schema))

let schema_property_names schema =
  match Yojson.Safe.Util.member "properties" schema with
  | `Assoc props -> List.map fst props
  | _ -> []

let assert_validation_rejects ~label ~schema ~tool_name ~args ~snippets =
  match Tool_input_validation.validate_args ~schema ~name:tool_name ~args () with
  | Error result ->
    let msg = Yojson.Safe.to_string (Tool_result.data result) in
    List.iter
      (fun snippet ->
         assert_contains (label ^ " mentions " ^ snippet) msg snippet)
      snippets
  | Ok forwarded ->
    Alcotest.failf
      "%s: expected validation rejection, got %s"
      label
      (Yojson.Safe.to_string forwarded)

let test_typed_tool_contract_rejection_corpus () =
  List.iter
    (fun (label, tool_name, schema, args, snippets) ->
       assert_validation_rejects ~label ~tool_name ~schema ~args ~snippets)
    [ ( "execute empty object"
      , "tool_execute"
      , tool_execute_schema
      , `Assoc []
      , [ "exactly one of" ] )
    ; ( "execute raw cmd string"
      , "tool_execute"
      , tool_execute_schema
      , `Assoc [ "cmd", `String "git status --short" ]
      , [ "cmd"; "non-empty argv" ] )
    ; ( "keeper_task_done notes-only drift"
      , "keeper_task_done"
      , keeper_task_done_schema
      , `Assoc [ "notes", `String "evidence" ]
      , [ "task_id"; "result" ] )
    ; ( "keeper_task_done requires evidence refs"
      , "keeper_task_done"
      , keeper_task_done_schema
      , `Assoc
          [ "task_id", `String "task-123"
          ; "result", `String "implemented and opened PR#123"
          ]
      , [ "evidence_refs" ] )
    ; ( "keeper_board_post_get missing post_id"
      , "keeper_board_post_get"
      , keeper_board_post_get_schema
      , `Assoc []
      , [ "post_id" ] )
    ; ( "masc_transition retired alias fields"
      , "masc_transition"
      , masc_transition_schema
      , `Assoc
          [ "agent_name", `String "codex-local-admin"
          ; "task_id", `String "task-239"
          ; "action", `String "claim"
          ; "to", `String "claimed"
          ; "note", `String "PR #8308 Draft"
          ]
      , [ "to"; "note" ] )
    ]

let test_keeper_tool_hint_contracts_match_required_fields () =
  Alcotest.(check bool)
    "keeper_task_claim schema accepts optional task_id"
    true
    (List.mem "task_id" (schema_property_names keeper_task_claim_schema));
  Alcotest.(check bool)
    "keeper_task_claim schema does not require task_id"
    false
    (List.mem "task_id" (schema_required_fields keeper_task_claim_schema));
  (match
     Tool_input_validation.validate_args
       ~schema:keeper_task_claim_schema
       ~name:"keeper_task_claim"
       ~args:(`Assoc [ "task_id", `String "task-123" ])
       ()
   with
   | Ok _ -> ()
   | Error result ->
     Alcotest.failf
       "keeper_task_claim task_id should validate: %s"
       (Yojson.Safe.to_string (Tool_result.data result)));
  assert_schema_requires "keeper_task_done schema" keeper_task_done_schema "task_id";
  assert_schema_requires "keeper_task_done schema" keeper_task_done_schema "result";
  assert_schema_requires "keeper_task_done schema" keeper_task_done_schema "evidence_refs";
  assert_schema_requires
    "keeper_board_post_get schema"
    keeper_board_post_get_schema
    "post_id";
  assert_schema_requires "keeper_board_post schema" keeper_board_post_schema "content";
  Alcotest.(check bool)
    "keeper_board_post schema does not require hearth"
    false
    (List.mem "hearth" (schema_required_fields keeper_board_post_schema));
  let claim_guidance =
    read_source_file "config/prompts/keeper.turn_intent.claim_guidance_a.md"
  in
  let capabilities = read_source_file "config/prompts/keeper.capabilities.md" in
  let core_behavior = read_source_file "config/prompts/keeper.core_behavior.md" in
  assert_contains
    "keeper_task_claim hint names optional task_id"
    claim_guidance
    "`keeper_task_claim { \"task_id\": \"task-123\" }`";
  assert_contains
    "Execute core behavior defines argv0 as program"
    core_behavior
    "`argv[0]` is the program";
  assert_contains
    "Execute core behavior gives complete git process vector"
    core_behavior
    "`argv=[\"git\", \"status\", \"--short\"]`";
  assert_not_contains
    "Execute core behavior does not advertise retired executable field"
    core_behavior
    "`executable`";
  assert_contains
    "keeper capabilities delegates call syntax to typed schemas"
    capabilities
    "active typed schema is the only callable catalog";
  assert_contains
    "keeper capabilities keeps typed failures visible"
    capabilities
    "Every failed call returns a typed error";
  assert_not_contains
    "keeper capabilities avoids retired capacity token"
    capabilities
    ("repo" ^ "_cap")

let test_keeper_prompts_do_not_duplicate_model_tool_names () =
  let prompt_paths =
    [ "config/prompts/keeper.unified.system.md"
    ; "config/prompts/keeper.capabilities.md"
    ; "config/prompts/keeper.world.md"
    ]
  in
  let tool_names = Keeper_tool_policy.keeper_model_tool_names () in
  List.iter
    (fun prompt_path ->
       let tokens = identifier_tokens (read_source_file prompt_path) in
       let duplicated_names =
         List.filter (fun tool_name -> List.mem tool_name tokens) tool_names
       in
       Alcotest.(check (list string))
         (prompt_path ^ " derives callable names only from the typed schema")
         []
         duplicated_names)
    prompt_paths

let test_orchestrator_prompt_pins_start_transition () =
  let prompt = read_source_file "config/prompts/system.orchestrator.md" in
  assert_contains "orchestrator prompt claims first" prompt "action: \"claim\"";
  assert_contains "orchestrator prompt starts before work" prompt "action: \"start\"";
  assert_contains "orchestrator prompt marks done" prompt "action: \"done\""

let test_task_lifecycle_guidance_is_externalized () =
  let rule =
    read_source_file "config/prompts/tool_contract.task_lifecycle_rule.md"
  in
  let workflow =
    read_source_file "config/prompts/tool_contract.task_lifecycle_workflow.md"
  in
  assert_contains
    "external rule pins the verification completion path (RFC-0323 G-4)"
    rule
    "Every completion request is judged by the configured LLM";
  assert_contains
    "external workflow includes start transition"
    workflow
    "masc_transition(start)";
  assert_contains
    "external workflow routes completion through submit (RFC-0323 G-4)"
    workflow
    "masc_transition(submit_for_verification)";
  assert_contains
    "external workflow keeps branch-work guidance"
    workflow
    "work in your repo clone on a task branch";
  let schema_source = read_source_file "lib/task/tool_task_schemas.ml" in
  let profile_source =
    read_source_file "lib/mcp_server_eio_tool_profile.ml"
  in
  assert_not_contains
    "task schema does not own lifecycle prose literal"
    schema_source
    "For normal task work, claim first";
  assert_not_contains
    "profile does not own workflow prose literal"
    profile_source
    "masc_status -> masc_transition(claim) -> masc_transition(start)"

(* ================================================================ *)
(* Test: oneOf with empty/null values (regression guard)             *)
(* ================================================================ *)

(** Shape-validation boundary: [not: {required: ["pipeline"]}] must treat the
    [pipeline] key as present even when its value is an empty array. Otherwise
    validation forwards a payload that the typed Execute parser rejects as an
    [argv] + [pipeline] mutually-exclusive pair. *)
let test_validate_args_tool_execute_exec_with_empty_pipeline () =
  let args =
    `Assoc
      [ "argv", `List [ `String "pwd" ]
      ; "pipeline", `List []
      ]
  in
  match
    Tool_input_validation.validate_args
      ~schema:tool_execute_schema
      ~name:"tool_execute"
      ~args
      ()
  with
  | Error result ->
    let msg = Yojson.Safe.to_string (Tool_result.data result) in
    Alcotest.(check bool) "mentions exact-one-of" true
      (string_contains msg "exactly one of")
  | Ok forwarded ->
    Alcotest.failf
      "expected tool_execute with argv + empty pipeline to fail, got %s"
      (Yojson.Safe.to_string forwarded)

(** stages is not a tool_execute input field. Sending stages in args triggers
    additionalProperties rejection since the schema declares
    additionalProperties: false. *)
let test_validate_args_tool_execute_stages_rejected_by_schema () =
  let args =
    `Assoc
      [ "argv", `List [ `String "ls" ]
      ; "stages", `Null
      ]
  in
  match
    Tool_input_validation.validate_args
      ~schema:tool_execute_schema
      ~name:"tool_execute"
      ~args
      ()
  with
  | Error result ->
    let msg = Yojson.Safe.to_string (Tool_result.data result) in
    Alcotest.(check bool) "mentions stages" true (string_contains msg "stages")
  | Ok _ ->
    Alcotest.fail "expected rejection: stages is no longer a schema-advertised field"

let test_validate_args_tool_execute_pipeline_rejects_null_argv () =
  let args =
    `Assoc
      [ "argv", `Null
      ; "pipeline", `List
          [ `Assoc [ "argv", `List [ `String "echo" ] ] ]
      ]
  in
  match
    Tool_input_validation.validate_args
      ~schema:tool_execute_schema
      ~name:"tool_execute"
      ~args
      ()
  with
  | Error result ->
    let msg = Yojson.Safe.to_string (Tool_result.data result) in
    Alcotest.(check bool) "mentions exact-one-of" true
      (string_contains msg "exactly one of")
  | Ok forwarded ->
    Alcotest.failf
      "expected tool_execute pipeline with null argv to fail, got %s"
      (Yojson.Safe.to_string forwarded)

(* ================================================================ *)
(* Test: oneOf with const discriminator                              *)
(* ================================================================ *)

(** Schema where two branches share the same required fields but are
    distinguished by a const value on the 'kind' field. This exercises
    the improvement to [one_of_required_shape_error] that respects
    const discriminators instead of matching purely on required field
    presence. *)
let oneof_const_schema =
  `Assoc
    [
      ("type", `String "object");
      ( "oneOf"
      , `List
          [
            `Assoc
              [
                ( "properties"
                , `Assoc
                    [
                      ("kind", `Assoc [("const", `String "alpha")])
                    ; ("value", `Assoc [("type", `String "string")])
                    ] )
              ; ("required", `List [`String "kind"; `String "value"])
              ]
          ; `Assoc
              [
                ( "properties"
                , `Assoc
                    [
                      ("kind", `Assoc [("const", `String "custom")])
                    ; ("value", `Assoc [("type", `String "string")])
                    ] )
              ; ("required", `List [`String "kind"; `String "value"])
              ]
          ] )
    ]
;;

let test_oneof_const_discriminator_alpha_branch () =
  let args = `Assoc [("kind", `String "alpha"); ("value", `String "minimal")] in
  match
    Tool_input_validation.validate_args
      ~schema:oneof_const_schema
      ~name:"test_oneof_const"
      ~args
      ()
  with
  | Ok forwarded ->
    Alcotest.(check bool) "args unchanged" true (Yojson.Safe.equal args forwarded)
  | Error result ->
    Alcotest.failf
      "expected alpha branch to match, got %s"
      (Yojson.Safe.to_string (Tool_result.data result))
;;

let test_oneof_const_discriminator_custom_branch () =
  let args = `Assoc [("kind", `String "custom"); ("value", `String "my-tool")] in
  match
    Tool_input_validation.validate_args
      ~schema:oneof_const_schema
      ~name:"test_oneof_const"
      ~args
      ()
  with
  | Ok forwarded ->
    Alcotest.(check bool) "args unchanged" true (Yojson.Safe.equal args forwarded)
  | Error result ->
    Alcotest.failf
      "expected custom branch to match, got %s"
      (Yojson.Safe.to_string (Tool_result.data result))
;;

let test_oneof_const_discriminator_rejects_unknown_kind () =
  let args = `Assoc [("kind", `String "unknown"); ("value", `String "x")] in
  match
    Tool_input_validation.validate_args
      ~schema:oneof_const_schema
      ~name:"test_oneof_const"
      ~args
      ()
  with
  | Error result ->
    let msg = (Tool_result.message result) in
    Alcotest.(check bool) "error mentions exact-one-of" true
      (string_contains msg "exactly one of");
    Alcotest.(check bool) "error mentions alpha branch label" true
      (string_contains msg "kind=\"alpha\"");
    Alcotest.(check bool) "error mentions custom branch label" true
      (string_contains msg "kind=\"custom\"")
  | Ok _ -> Alcotest.fail "expected rejection for unknown kind value"
;;

let test_oneof_const_discriminator_rejects_missing_kind () =
  let args = `Assoc [("value", `String "x")] in
  match
    Tool_input_validation.validate_args
      ~schema:oneof_const_schema
      ~name:"test_oneof_const"
      ~args
      ()
  with
  | Error result ->
    let msg = Yojson.Safe.to_string (Tool_result.data result) in
    Alcotest.(check bool) "error mentions exact-one-of" true
      (string_contains msg "exactly one of")
  | Ok _ -> Alcotest.fail "expected rejection for missing kind field"
;;

(** P1 regression: const fields that are not in the branch's required list
    must be treated as optional.  A schema with disjoint required sets and
    optional const discriminators should not reject an input that satisfies
    exactly one branch just because the optional const key is absent. *)
let oneof_optional_const_schema =
  `Assoc
    [
      ("type", `String "object");
      ( "oneOf"
      , `List
          [
            `Assoc
              [
                ( "properties"
                , `Assoc
                    [
                      ("kind", `Assoc [("const", `String "a")])
                    ; ("foo", `Assoc [("type", `String "string")])
                    ] )
              ; ("required", `List [`String "foo"])
              ]
          ; `Assoc
              [
                ( "properties"
                , `Assoc
                    [
                      ("kind", `Assoc [("const", `String "b")])
                    ; ("bar", `Assoc [("type", `String "string")])
                    ] )
              ; ("required", `List [`String "bar"])
              ]
          ] )
    ]
;;

let test_oneof_optional_const_branch_matches_without_const () =
  let args = `Assoc [("foo", `String "x")] in
  match
    Tool_input_validation.validate_args
      ~schema:oneof_optional_const_schema
      ~name:"test_oneof_optional_const"
      ~args
      ()
  with
  | Ok forwarded ->
    Alcotest.(check bool) "args unchanged" true (Yojson.Safe.equal args forwarded)
  | Error result ->
    Alcotest.failf
      "expected branch A to match without optional const, got %s"
      (Yojson.Safe.to_string (Tool_result.data result))
;;

(** P2 regression: "const": null in the schema must be distinguishable from
    a missing const key.  Two branches with the same required field but
    distinguished by null vs non-null const should resolve unambiguously. *)
let oneof_null_const_schema =
  `Assoc
    [
      ("type", `String "object");
      ( "oneOf"
      , `List
          [
            `Assoc
              [
                ( "properties"
                , `Assoc
                    [
                      ("mode", `Assoc [("const", `Null)])
                    ; ("name", `Assoc [("type", `String "string")])
                    ] )
              ; ("required", `List [`String "name"])
              ]
          ; `Assoc
              [
                ( "properties"
                , `Assoc
                    [
                      ("mode", `Assoc [("const", `String "active")])
                    ; ("name", `Assoc [("type", `String "string")])
                    ] )
              ; ("required", `List [`String "name"])
              ]
          ] )
    ]
;;

let test_oneof_null_const_matches_null_branch () =
  let args = `Assoc [("name", `String "x"); ("mode", `Null)] in
  match
    Tool_input_validation.validate_args
      ~schema:oneof_null_const_schema
      ~name:"test_oneof_null_const"
      ~args
      ()
  with
  | Ok forwarded ->
    Alcotest.(check bool) "args unchanged" true (Yojson.Safe.equal args forwarded)
  | Error result ->
    Alcotest.failf
      "expected null-const branch to match, got %s"
      (Yojson.Safe.to_string (Tool_result.data result))
;;

let test_oneof_null_const_matches_non_null_branch () =
  let args = `Assoc [("name", `String "x"); ("mode", `String "active")] in
  match
    Tool_input_validation.validate_args
      ~schema:oneof_null_const_schema
      ~name:"test_oneof_null_const"
      ~args
      ()
  with
  | Ok forwarded ->
    Alcotest.(check bool) "args unchanged" true (Yojson.Safe.equal args forwarded)
  | Error result ->
    Alcotest.failf
      "expected active-const branch to match, got %s"
      (Yojson.Safe.to_string (Tool_result.data result))
;;

(* ================================================================ *)
(* Runner                                                            *)
(* ================================================================ *)

let () =
  Alcotest.run "Tool_input_validation (OAS delegation)" [
    ("required", [
      Alcotest.test_case "present" `Quick test_required_present;
      Alcotest.test_case "missing" `Quick test_required_missing;
      Alcotest.test_case "missing multiple" `Quick test_required_missing_multiple;
      Alcotest.test_case "no required fields" `Quick test_no_required_fields;
    ]);
    ("coercion", [
      Alcotest.test_case "string -> integer" `Quick test_coerce_string_to_integer;
      Alcotest.test_case "string -> boolean" `Quick test_coerce_string_to_boolean;
      Alcotest.test_case "string -> number" `Quick test_coerce_string_to_number;
      Alcotest.test_case "int -> number (widening)" `Quick test_coerce_int_to_number;
      Alcotest.test_case "Intlit -> Int (normalize)" `Quick test_coerce_intlit_to_integer;
      Alcotest.test_case "non-coercible string -> reject" `Quick test_invalid_string_to_integer;
    ]);
    ("correct_types", [
      Alcotest.test_case "string passes" `Quick test_correct_string;
      Alcotest.test_case "integer passes" `Quick test_correct_integer;
      Alcotest.test_case "boolean passes" `Quick test_correct_boolean;
    ]);
    ("edge_cases", [
      Alcotest.test_case "null args no required" `Quick test_null_args_no_required;
      Alcotest.test_case "null args with required" `Quick test_null_args_with_required;
      Alcotest.test_case "extra fields allowed" `Quick test_extra_fields_allowed;
      Alcotest.test_case "empty schema allows empty args" `Quick
        test_empty_schema_allows_empty_args;
      Alcotest.test_case "empty schema rejects arguments" `Quick
        test_empty_schema_rejects_arguments;
      Alcotest.test_case "required without properties rejects schema" `Quick
        test_required_without_properties_rejects_schema;
      Alcotest.test_case "schema union type does not raise" `Quick
        test_schema_union_type_does_not_raise;
    ]);
    ("telemetry", [
      Alcotest.test_case "records pass and fail counters" `Quick
        test_validation_telemetry_records_pass_and_fail_counters;
      Alcotest.test_case "rejects retired transition aliases counter" `Quick
        test_validation_telemetry_rejects_retired_transition_aliases;
      Alcotest.test_case "emits OTel validation event" `Quick
        test_validation_telemetry_emits_otel_event;
    ]);
    ("registered_hook", [
      Alcotest.test_case "coercion flows through registered hook" `Quick
        test_registered_hook_coerces_args;
      Alcotest.test_case "no-op coercion stays pass" `Quick
        test_registered_hook_keeps_noop_as_pass;
      Alcotest.test_case "unknown tool rejects validation" `Quick
        test_registered_hook_rejects_unknown_tool;
      Alcotest.test_case "empty schema rejects arguments" `Quick
        test_registered_hook_rejects_empty_schema_arguments;
      Alcotest.test_case "empty schema allows empty args" `Quick
        test_registered_hook_allows_empty_schema_without_arguments;
      Alcotest.test_case "tool_edit_file accepts patch args" `Quick
        test_registered_hook_tool_edit_file_patch_args;
      Alcotest.test_case "keeper_board_post accepts sources array" `Quick
        test_registered_hook_keeper_board_post_accepts_sources_array;
      Alcotest.test_case "keeper_board_list accepts compact" `Quick
        test_validate_args_keeper_board_list_accepts_compact;
      Alcotest.test_case "keeper_board_search accepts compact" `Quick
        test_validate_args_keeper_board_search_accepts_compact;
      Alcotest.test_case "keeper_board_list still rejects unknown field" `Quick
        test_validate_args_keeper_board_list_rejects_unknown_field;
      Alcotest.test_case "tool_execute exposes typed boundary" `Quick
        test_tool_execute_schema_exposes_typed_boundary;
      Alcotest.test_case "tool_execute rejects empty args with class" `Quick
        test_validate_args_tool_execute_rejects_empty_object_with_policy_class;
      Alcotest.test_case "tool_execute rejects cmd string" `Quick
        test_validate_args_tool_execute_rejects_cmd_string;
      Alcotest.test_case "tool_execute rejects command string" `Quick
        test_validate_args_tool_execute_rejects_command_string;
      Alcotest.test_case "tool_execute rejects background flag" `Quick
        test_validate_args_tool_execute_rejects_background_flag;
      Alcotest.test_case "tool_execute rejects async lifecycle fields" `Quick
        test_validate_args_tool_execute_rejects_async_lifecycle_fields;
      Alcotest.test_case "tool_execute accepts typed exec" `Quick
        test_validate_args_tool_execute_accepts_typed_exec;
      Alcotest.test_case "tool_execute rejects json-string argv" `Quick
        test_validate_args_tool_execute_rejects_json_string_argv;
      Alcotest.test_case "tool_execute accepts typed pipeline" `Quick
        test_validate_args_tool_execute_accepts_typed_pipeline;
      Alcotest.test_case "masc_transition rejects json-string handoff" `Quick
        test_validate_args_masc_transition_rejects_json_string_handoff_context;
      Alcotest.test_case "Execute rejects args object envelope" `Quick
        test_validate_args_execute_rejects_args_object_envelope;
      Alcotest.test_case "tool_execute rejects args object envelope" `Quick
        test_validate_args_tool_execute_rejects_args_object_envelope;
      Alcotest.test_case "Execute rejects pipeline args envelope" `Quick
        test_validate_args_execute_rejects_pipeline_envelope;
      Alcotest.test_case "Execute rejects args array envelope" `Quick
        test_validate_args_execute_rejects_args_array_envelope;
      Alcotest.test_case "Execute rejects mixed args envelope" `Quick
        test_validate_args_execute_rejects_mixed_args_envelope;
      Alcotest.test_case "non-Execute rejects args object envelope" `Quick
        test_validate_args_non_execute_rejects_args_object_envelope;
      Alcotest.test_case "tool_execute write validation stays structural" `Quick
        test_tool_execute_write_validation_stays_structural;
      Alcotest.test_case "tool_execute find expression not rewritten" `Quick
        test_tool_execute_find_expression_not_rewritten;
      Alcotest.test_case "tool_execute find global option not rewritten" `Quick
        test_tool_execute_find_global_option_not_rewritten;
      Alcotest.test_case "tool_execute empty program not promoted" `Quick
        test_tool_execute_empty_program_not_promoted;
      Alcotest.test_case "tool_execute pipeline find not rewritten" `Quick
        test_tool_execute_pipeline_find_expression_not_rewritten;
      Alcotest.test_case "tool_execute rejects bad typed argv" `Quick
        test_validate_args_tool_execute_rejects_bad_argv_type;
      Alcotest.test_case "tool_execute exec + empty pipeline" `Quick
        test_validate_args_tool_execute_exec_with_empty_pipeline;
      Alcotest.test_case "tool_execute stages rejected by schema" `Quick
        test_validate_args_tool_execute_stages_rejected_by_schema;
      Alcotest.test_case "tool_execute pipeline + null argv" `Quick
        test_validate_args_tool_execute_pipeline_rejects_null_argv;
      Alcotest.test_case "direct validation uses explicit schema" `Quick
        test_validate_args_uses_explicit_schema_without_registry;
      Alcotest.test_case "direct keeper_board_post accepts sources array" `Quick
        test_validate_args_keeper_board_post_accepts_sources_array;
      Alcotest.test_case "masc_transition rejects to/note aliases" `Quick
        test_registered_hook_transition_rejects_to_and_note;
      Alcotest.test_case "masc_transition canonical action value" `Quick
        test_registered_hook_transition_preserves_canonical_action;
      Alcotest.test_case "masc_transition strips internal markers" `Quick
        test_registered_hook_transition_strips_internal_agent_marker;
      Alcotest.test_case "masc_goal_list strips blank optional enum filters"
        `Quick test_registered_hook_goal_list_strips_blank_optional_enums;
      Alcotest.test_case "masc_goal_list rejects status filter" `Quick
        test_registered_hook_goal_list_rejects_status_filter;
      Alcotest.test_case "masc_goal_list preserves invalid enum filters" `Quick
        test_registered_hook_goal_list_preserves_invalid_enum_for_handler;
      Alcotest.test_case "required enum blanks are not stripped" `Quick
        test_registered_hook_required_enum_blank_is_not_stripped;
    ]);
    ("typed_tool_contract_harness", [
      Alcotest.test_case "rejects invalid typed call corpus" `Quick
        test_typed_tool_contract_rejection_corpus;
      Alcotest.test_case "keeper prompt hints match schema-required fields" `Quick
        test_keeper_tool_hint_contracts_match_required_fields;
      Alcotest.test_case "keeper prompts do not duplicate model tool names" `Quick
        test_keeper_prompts_do_not_duplicate_model_tool_names;
      Alcotest.test_case "orchestrator prompt includes start transition" `Quick
        test_orchestrator_prompt_pins_start_transition;
      Alcotest.test_case "task lifecycle guidance is externalized" `Quick
        test_task_lifecycle_guidance_is_externalized;
    ]);
    ("oneof_const_discriminator", [
      Alcotest.test_case "alpha branch matches via const" `Quick
        test_oneof_const_discriminator_alpha_branch;
      Alcotest.test_case "custom branch matches via const" `Quick
        test_oneof_const_discriminator_custom_branch;
      Alcotest.test_case "unknown kind is rejected" `Quick
        test_oneof_const_discriminator_rejects_unknown_kind;
      Alcotest.test_case "missing kind is rejected" `Quick
        test_oneof_const_discriminator_rejects_missing_kind;
      Alcotest.test_case "optional const: branch matches without const key" `Quick
        test_oneof_optional_const_branch_matches_without_const;
      Alcotest.test_case "null const: null branch matches" `Quick
        test_oneof_null_const_matches_null_branch;
      Alcotest.test_case "null const: non-null branch matches" `Quick
        test_oneof_null_const_matches_non_null_branch;
    ]);
  ]
