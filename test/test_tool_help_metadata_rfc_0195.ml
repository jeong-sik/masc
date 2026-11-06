(* test/test_tool_help_metadata_rfc_0195.ml

   RFC-0195 P0 — help_entry record gains two optional, additive
   metadata fields: [examples] and [alternatives]. These fields
   exist so LLMs can recover from a typed rejection or catalog miss
   without parsing prose hints (RFC-0194 §2).

   This test checks:
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

(* Authored TOML help reaches the JSON entry: both list fields are emitted
   for a tool that declares them. *)
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

let () =
  Alcotest.run "tool_help_metadata_rfc_0195"
    [
      ( "registry_invariants",
        [
          Alcotest.test_case "alternatives names resolve through find_entry"
            `Quick test_alternatives_never_dangling;
          Alcotest.test_case "examples are calls the schema accepts"
            `Quick test_examples_are_calls_the_schema_accepts; Alcotest.test_case "the short description is the entry's own"
            `Quick test_the_short_description_is_the_entrys_own;

        ] );
      ( "json_projection",
        [
          Alcotest.test_case "populated optional fields are emitted"
            `Quick test_entry_json_includes_populated_fields;
        ] );
    ]
