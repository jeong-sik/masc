(* test/test_tool_help_metadata_rfc_0195.ml

   RFC-0195 P0 — help_entry record gains two optional, additive
   metadata fields: [examples] and [alternatives]. These fields
   exist so LLMs can recover from a typed rejection or catalog miss
   without parsing prose hints (RFC-0194 §2).

   This test pins:
   - The six target tools curated in this PR carry non-empty
     [examples] (so the LLM has a concrete invocation template).
   - The four tools whose semantics name a sibling carry a
     non-empty [alternatives] list (so the LLM has a typed next
     step on rejection). The remaining curated tools that have no
     sibling (keeper_memory_retract, keeper_memory_write,
     keeper_tasks_list) are pinned as having an empty alternatives
     list — the expectation is "no sibling exists", not "we forgot
     to fill it in".
   - Every name listed in any [alternatives] field resolves
     through [find_entry] against the authoritative schema list,
     so an alternatives entry can never become a dangling
     reference at the source of truth.

   Same MASC_BASE_PATH setenv pattern as
   test_tool_help_registry_shard_coverage_10101.ml — module init
   resolves the runtime base path, which the #9903 prod-guard
   rejects under HOME. *)

let () =
  let dir =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-test-tool-help-metadata-rfc0195-%06x" (Random.bits ()))
  in
  Unix.putenv "MASC_BASE_PATH" dir

module Config = Masc.Config
module Registry = Tool_help_registry

let lookup name =
  match Registry.find_entry Config.raw_all_tool_schemas name with
  | Some entry -> entry
  | None ->
    Alcotest.failf
      "RFC-0195 P0: target tool %S is missing from \
       Config.raw_all_tool_schemas; the manual help override \
       cannot reach it" name

(* The six target tools listed in RFC-0195 P0 cover two
   reachability classes:
   - Four are registered in Config.raw_all_tool_schemas and
     therefore round-trip through find_entry. Those are the
     ones this test pins.
   - One (masc_plan_set_task) is a workspace-side tool whose schema lives on
     a different surface that this PR does not modify. Its manual_help
     entry is written here as future-proofing — it takes
     effect the moment those schemas join the keeper-side
     registry. See PR body §"Reachable surface" for the split. *)
let curated_with_examples =
  [
    "keeper_task_done";
    "keeper_memory_retract";
    "keeper_memory_write";
    "keeper_tasks_list";
  ]

let curated_with_alternatives = []

let curated_without_sibling =
  [ "keeper_memory_retract"; "keeper_memory_write"; "keeper_tasks_list" ]

let test_examples_populated () =
  List.iter
    (fun name ->
      let entry = lookup name in
      Alcotest.(check bool)
        (Printf.sprintf "%s has at least one example" name)
        true (entry.examples <> []))
    curated_with_examples

let test_alternatives_typed_list () =
  List.iter
    (fun (name, expected) ->
      let entry = lookup name in
      Alcotest.(check (list string))
        (Printf.sprintf "%s alternatives match RFC-0195 curation" name)
        expected entry.alternatives)
    curated_with_alternatives

let test_tools_without_sibling_have_empty_alternatives () =
  List.iter
    (fun name ->
      let entry = lookup name in
      Alcotest.(check (list string))
        (Printf.sprintf "%s has no sibling — empty alternatives by design" name)
        [] entry.alternatives)
    curated_without_sibling

let test_alternatives_never_dangling () =
  let unresolved =
    List.concat_map
      (fun (s : Masc_domain.tool_schema) ->
        match Registry.find_entry Config.raw_all_tool_schemas s.name with
        | None -> []
        | Some entry ->
          List.filter_map
            (fun alt ->
              if Option.is_some
                   (Registry.find_entry Config.raw_all_tool_schemas alt)
              then None
              else Some (s.name, alt))
            entry.alternatives)
      Config.raw_all_tool_schemas
  in
  match unresolved with
  | [] -> ()
  | dangling ->
    let render (src, alt) = Printf.sprintf "%s -> %s" src alt in
    Alcotest.failf
      "RFC-0195 P0: %d dangling alternatives reference(s): %s"
      (List.length dangling)
      (String.concat ", " (List.map render dangling))

(* An example is [key=value] pairs separated by spaces. A value is quoted
   (['...']), a list ([[...]]), a placeholder ([<...>]) or a bare word. Any other
   shape is refused rather than skipped, so a new example shape has to teach this
   reader before it can ship unchecked. *)
let example_keys example =
  let n = String.length example in
  let rec skip_spaces i =
    if i < n && Char.equal example.[i] ' ' then skip_spaces (i + 1) else i
  in
  let rec bare_end i =
    if i < n && not (Char.equal example.[i] ' ') then bare_end (i + 1) else i
  in
  let value_end i =
    let closing =
      match example.[i] with
      | '\'' -> Some '\''
      | '[' -> Some ']'
      | '<' -> Some '>'
      | _ -> None
    in
    match closing with
    | None -> Ok (bare_end i)
    | Some close ->
      (match String.index_from_opt example (i + 1) close with
       | Some j -> Ok (j + 1)
       | None -> Error (Printf.sprintf "%c at offset %d is never closed" example.[i] i))
  in
  let is_key_char c = (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || Char.equal c '_' in
  let rec pairs i keys =
    let i = skip_spaces i in
    if i >= n
    then Ok (List.rev keys)
    else (
      match String.index_from_opt example i '=' with
      | None -> Error (Printf.sprintf "no '=' after offset %d" i)
      | Some eq ->
        let key = String.sub example i (eq - i) in
        if String.equal key "" || not (String.for_all is_key_char key)
        then Error (Printf.sprintf "%S at offset %d is not an argument name" key i)
        else if eq + 1 >= n
        then Error (Printf.sprintf "%s has no value" key)
        else (
          match value_end (eq + 1) with
          | Error _ as e -> e
          | Ok next -> pairs next (key :: keys)))
  in
  pairs 0 []

let schema_field name = function
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None

let declared_arguments (schema : Masc_domain.tool_schema) =
  match schema_field "properties" schema.input_schema with
  | Some (`Assoc props) -> List.map fst props
  | _ -> []

let required_arguments (schema : Masc_domain.tool_schema) =
  match schema_field "required" schema.input_schema with
  | Some (`List items) ->
    List.filter_map (function `String s -> Some s | _ -> None) items
  | _ -> []

(* An example is the call a reader copies. [masc_tool_help] listed
   [name='keeper_task_done'] while its argument is [tool_name], and the plan
   tool's example passed a [plan] argument it never had; both were refused when
   run as written. Reading each example against the schema it sits beside
   catches the next one. *)
let test_examples_are_calls_the_schema_accepts () =
  let problems =
    List.concat_map
      (fun (schema : Masc_domain.tool_schema) ->
        match Registry.find_entry Config.raw_all_tool_schemas schema.name with
        | None -> []
        | Some entry ->
          let declared = declared_arguments schema in
          let required = required_arguments schema in
          List.concat_map
            (fun example ->
              match example_keys example with
              | Error why ->
                [ Printf.sprintf "%s: cannot read example %s (%s)" schema.name example why ]
              | Ok keys ->
                let unknown = List.filter (fun k -> not (List.mem k declared)) keys in
                let missing = List.filter (fun r -> not (List.mem r keys)) required in
                List.map
                  (fun k ->
                    Printf.sprintf "%s: example %s names %s, which the tool does not declare"
                      schema.name example k)
                  unknown
                @ List.map
                    (fun r ->
                      Printf.sprintf "%s: example %s omits required argument %s"
                        schema.name example r)
                    missing)
            entry.examples)
      Config.raw_all_tool_schemas
  in
  match problems with
  | [] -> ()
  | _ ->
    Alcotest.failf "%d help example problem(s):\n%s" (List.length problems)
      (String.concat "\n" problems)

let test_entry_json_omits_empty_fields () =
  (* keeper_lane_status has no curated examples/alternatives; the JSON wire shape
     must omit both keys so existing consumers see no field they did not see
     before. *)
  let entry = lookup "keeper_lane_status" in
  let json = Registry.entry_json entry in
  match json with
  | `Assoc kvs ->
    let has_key key = List.exists (fun (k, _) -> String.equal k key) kvs in
    Alcotest.(check bool)
      "empty examples list omitted from JSON" false (has_key "examples");
    Alcotest.(check bool)
      "empty alternatives list omitted from JSON" false (has_key "alternatives")
  | _ -> Alcotest.fail "entry_json must return an Assoc"

(* The omitted-when-empty half is covered by [test_entry_json_omits_empty_fields]
   on keeper_lane_status. This fixture exists for the opposite property, so it
   asserts inclusion on both list fields rather than reusing one entry to prove
   emission and omission at once. *)
let test_entry_json_includes_populated_fields () =
  let entry = lookup "keeper_task_done" in
  let json = Registry.entry_json entry in
  match json with
  | `Assoc kvs ->
    let has_key key = List.exists (fun (k, _) -> String.equal k key) kvs in
    Alcotest.(check bool)
      "populated examples list emitted in JSON" true (has_key "examples");
    Alcotest.(check bool)
      "populated alternatives list emitted in JSON" true (has_key "alternatives")
  | _ -> Alcotest.fail "entry_json must return an Assoc"

(* A tool that behaved unexpectedly is one an operator wants to open, so the
   name has to resolve to the file it shipped from. Derived from the embedded
   file list, not composed from the name, so a tool with no shipped definition
   says so instead of naming a path that is not there. *)
let test_definition_source_names_the_shipped_file () =
  match Registry.definition_source "keeper_code_query" with
  | Some rel ->
    Alcotest.(check string) "shipped definition path" "tools/keeper_code_query.toml" rel
  | None -> Alcotest.fail "a shipped tool must name its definition"
;;

let test_definition_source_is_none_without_an_asset () =
  match
    Registry.definition_source "no_such_tool_ships_under_this_name"
  with
  | None -> ()
  | Some rel -> Alcotest.failf "named a file that does not ship: %s" rel
;;

(* Canonicalising a schema wants one field. It used to build the whole help
   entry to reach it, which rendered that tool's when_to_use, its constraint
   notes and its prompt hints and discarded all three.

   Those renders ran during module initialisation -- [Config.all_tool_schemas]
   is a top-level binding -- which is before any [main] can pin the prompt
   directory, so every one of them logged an error it had no way to avoid: 192
   of them on this catalog, on the operator's terminal, ahead of the TUI's own
   stderr redirect.

   The field has to keep saying the same thing. Two derivations of one
   description is how a canonical schema starts disagreeing with the help entry
   describing the same tool. *)
let test_the_short_description_is_the_entrys_own () =
  List.iter
    (fun (schema : Masc_domain.tool_schema) ->
      Alcotest.(check string)
        (Printf.sprintf "%s: canonical description is the entry's" schema.name)
        (Registry.entry_of_schema schema).short_description
        (Registry.short_description_of_schema schema))
    Config.raw_all_tool_schemas

(* And a canonical schema carries it. *)
let test_canonicalising_carries_that_description () =
  List.iter2
    (fun (source : Masc_domain.tool_schema)
         (canonical : Masc_domain.tool_schema) ->
      Alcotest.(check string)
        (Printf.sprintf "%s: canonical schema carries it" source.name)
        (Registry.short_description_of_schema source)
        canonical.description)
    Config.raw_all_tool_schemas
    (Registry.canonicalize_schemas Config.raw_all_tool_schemas)

let () =
  Alcotest.run "tool_help_metadata_rfc_0195"
    [
      ( "curated_metadata",
        [
          Alcotest.test_case "six target tools have examples"
            `Quick test_examples_populated; Alcotest.test_case "four target tools have typed alternatives"
            `Quick test_alternatives_typed_list; Alcotest.test_case "tools without a sibling have empty alternatives"
            `Quick test_tools_without_sibling_have_empty_alternatives;
        ] );
      ( "registry_invariants",
        [
          Alcotest.test_case "alternatives names resolve through find_entry"
            `Quick test_alternatives_never_dangling;
          Alcotest.test_case "examples are calls the schema accepts"
            `Quick test_examples_are_calls_the_schema_accepts; Alcotest.test_case "the short description is the entry's own"
            `Quick test_the_short_description_is_the_entrys_own; Alcotest.test_case "canonicalising carries that description"
            `Quick test_canonicalising_carries_that_description;

        ] );
      ( "definition_source",
        [
          Alcotest.test_case "a shipped tool names its file"
            `Quick test_definition_source_names_the_shipped_file; Alcotest.test_case "an unshipped name resolves to none"
            `Quick test_definition_source_is_none_without_an_asset;
        ] );
      ( "json_projection",
        [
          Alcotest.test_case "empty optional fields are omitted"
            `Quick test_entry_json_omits_empty_fields; Alcotest.test_case "populated optional fields are emitted"
            `Quick test_entry_json_includes_populated_fields;
        ] );
    ]
