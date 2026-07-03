open Alcotest

let contains = String_util.contains_substring

let missing_model ?(runtime_id = "custom.uncatalogued")
    ?(provider_id = "custom")
    ?(provider_label = "openai_compat")
    ?(model_id = "uncatalogued") () : Runtime.missing_catalog_model =
  { runtime_id; provider_id; provider_label; model_id }
;;

let report missing_models : Runtime.missing_catalog_report =
  { config_path = "/tmp/runtime.toml"; missing_models }
;;

let message missing_models =
  Runtime.strict_init_error_to_string (Runtime.Missing_catalog_models (report missing_models))
;;

let test_missing_catalog_report_names_runtime_and_model () =
  let msg = message [ missing_model () ] in
  check bool "runtime/model label" true
    (contains msg "custom.uncatalogued (model=uncatalogued)");
  check bool "count" true (contains msg "1 runtime model(s)");
  check bool "catalog filename" true (contains msg "oas-models.toml")
;;

let test_missing_catalog_report_joins_multiple_models () =
  let msg =
    message
      [ missing_model ~runtime_id:"custom.alpha" ~model_id:"alpha" ()
      ; missing_model ~runtime_id:"custom.beta" ~model_id:"beta" ()
      ]
  in
  check bool "count" true (contains msg "2 runtime model(s)");
  check bool "alpha label" true (contains msg "custom.alpha (model=alpha)");
  check bool "beta label" true (contains msg "custom.beta (model=beta)")
;;

let () =
  Alcotest.run
    "Runtime Missing Catalog Report"
    [ ( "strict_init_error_to_string"
      , [ test_case
            "names runtime and model"
            `Quick
            test_missing_catalog_report_names_runtime_and_model
        ; test_case
            "joins multiple models"
            `Quick
            test_missing_catalog_report_joins_multiple_models
        ] )
    ]
;;
