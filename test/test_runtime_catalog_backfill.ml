open Alcotest

let contains = String_util.contains_substring

let with_catalog_content content f =
  let path = Filename.temp_file "runtime-catalog-backfill" ".toml" in
  let oc = open_out path in
  output_string oc content;
  close_out oc;
  Fun.protect
    ~finally:(fun () ->
      try Sys.remove path with
      | _ -> ())
    (fun () ->
      match Llm_provider.Model_catalog.load_file path with
      | Error msg -> failf "catalog fixture should load: %s" msg
      | Ok catalog -> f catalog)
;;

let source_entry_exn catalog =
  match catalog with
  | entry :: _ -> entry
  | [] -> fail "catalog fixture unexpectedly empty"
;;

let backfill_entry_exn missing =
  match Runtime.model_catalog_backfill_entries [ missing ] with
  | Error msg -> failf "backfill entries should render: %s" msg
  | Ok [ entry ] -> entry
  | Ok entries -> failf "expected one backfill entry, got %d" (List.length entries)
;;

let test_backfill_toml_escapes_strings_and_renders_floats () =
  let catalog =
    "[[models]]\n\
     id_prefix = \"sample-family-\"\n\
     base = \"openai_chat\"\n\
     provider_name = \"say \\\"hello\\\"\"\n\
     max_context_tokens = 2048\n\
     supports_tools = true\n\
     accepted_reasoning_efforts = [\"low\", \"high\"]\n\
     input_per_million = 42\n\
     output_per_million = 3.14\n"
  in
  with_catalog_content catalog @@ fun loaded ->
  let source = source_entry_exn loaded in
  let missing : Runtime.missing_catalog_model =
    { runtime_id = "custom.sample"
    ; provider_id = "custom"
    ; provider_label = "openai_compat"
    ; model_id = "sample-line1\nline2\t\"family\"\\variant"
    ; source_catalog_entry = Some source
    }
  in
  let entry = backfill_entry_exn missing in
  check string "runtime id" "custom.sample" entry.runtime_id;
  check
    string
    "provider-qualified id_prefix"
    "openai_compat/sample-line1\nline2\t\"family\"\\variant"
    entry.id_prefix;
  check string "source id_prefix" "sample-family-" entry.source_id_prefix;
  check bool "toml carries source row" true
    (contains entry.toml "Source OAS catalog row: sample-family-");
  check bool "toml escapes id_prefix quotes and slashes" true
    (contains
       entry.toml
       {|id_prefix = "openai_compat/sample-line1\nline2\t\"family\"\\variant"|});
  check bool "toml escapes provider_name quotes" true
    (contains entry.toml {|provider_name = "say \"hello\""|});
  check bool "toml preserves accepted reasoning efforts" true
    (contains entry.toml {|accepted_reasoning_efforts = ["low", "high"]|});
  check bool "integer float gets decimal suffix" true
    (contains entry.toml "input_per_million = 42.0");
  check bool "decimal float is rendered deterministically" true
    (contains entry.toml "output_per_million = 3.1400000000000001")
;;

let test_backfill_refuses_missing_source_row_with_runtime_label () =
  let missing : Runtime.missing_catalog_model =
    { runtime_id = "custom.uncatalogued"
    ; provider_id = "custom"
    ; provider_label = "openai_compat"
    ; model_id = "uncatalogued"
    ; source_catalog_entry = None
    }
  in
  match Runtime.model_catalog_backfill_entries [ missing ] with
  | Ok _ -> fail "backfill must not invent capabilities without a source row"
  | Error msg ->
    check bool "error names runtime/model label" true
      (contains msg "custom.uncatalogued (model=uncatalogued)")
;;

let () =
  Alcotest.run
    "Runtime Catalog Backfill"
    [ ( "model_catalog_backfill_entries"
      , [ test_case
            "escapes strings and renders floats"
            `Quick
            test_backfill_toml_escapes_strings_and_renders_floats
        ; test_case
            "refuses missing source row"
            `Quick
            test_backfill_refuses_missing_source_row_with_runtime_label
        ] )
    ]
;;
