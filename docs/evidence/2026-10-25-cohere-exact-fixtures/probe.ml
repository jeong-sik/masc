let checks = ref 0
let require label condition =
  if not condition then failwith label;
  incr checks; Printf.printf "PASS %s\n" label
let expected_error label = function
  | Error detail -> incr checks; Printf.printf "BEFORE_REJECT %s: %s\n" label detail
  | Ok _ -> failwith (label ^ ": expected original helper to be rejected")
let rejected label = function
  | Error detail -> incr checks; Printf.printf "PASS %s: %s\n" label detail
  | Ok _ -> failwith (label ^ ": unknown dialect was accepted")
let get label = function Ok value -> value | Error detail -> failwith (label ^ ": " ^ detail)
let () =
  List.iter (fun (dialect,expected) ->
    expected_error ("original TOML " ^ dialect)
      (Model_catalog.of_toml_string ~source:"existing Cohere helper" (Before_helpers.catalog dialect));
    expected_error ("original manifest " ^ dialect)
      (Capability_manifest.of_json (Before_helpers.manifest dialect));
    let catalog = get "fixed TOML" (Model_catalog.of_toml_string
      ~source:"existing Cohere helper" (After_helpers.catalog dialect)) in
    (match Model_catalog.model_entries catalog with
     | [row] -> require ("fixed TOML typed row " ^ dialect)
         (Model_identifiers.Model_id.to_string row.model_id = "same-model"
          && row.json_schema_dialect=Some expected && row.provider_name=Some "fixture"
          && row.supports_structured_output=Some true)
     | _ -> failwith "fixed TOML must retain one original typed row");
    let manifest = get "fixed manifest" (Capability_manifest.of_json (After_helpers.manifest dialect)) in
    (match Capability_manifest.entries manifest with
     | [row] -> require ("fixed manifest typed row " ^ dialect)
         (Model_identifiers.Model_id.to_string row.model_id = "same-model"
          && row.json_schema_dialect=Some expected)
     | _ -> failwith "fixed manifest must retain one original typed row"))
    ["json_object_schema",Capability_vocab.Json_object_schema;
     "openai_json_schema",Capability_vocab.Openai_json_schema];
  List.iter (fun dialect ->
    rejected ("unknown TOML dialect " ^ Printf.sprintf "%S" dialect)
      (Model_catalog.of_toml_string ~source:"existing Cohere helper" (After_helpers.catalog dialect));
    rejected ("unknown manifest dialect " ^ Printf.sprintf "%S" dialect)
      (Capability_manifest.of_json (After_helpers.manifest dialect))) ["unknown"; ""];
  let embedded = get "actual embedded catalog" (Model_catalog.load_default ()) in
  require "actual candidate embedded catalog remains parseable" (Model_catalog.model_entries embedded <> []);
  let schema_version helper = match helper "json_object_schema" with
    | `Assoc fields -> List.assoc "schema_version" fields
    | _ -> failwith "provider helper must remain an object" in
  require "provider helper v1 preserved" (schema_version Before_helpers.provider = `Int 1
    && schema_version After_helpers.provider = `Int 1);
  Printf.printf "COMPONENT_PROBES %d PASS\n" !checks
