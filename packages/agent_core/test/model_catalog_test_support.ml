let load_embedded_model_catalog ~suite =
  match Llm_provider.Model_catalog.load_default () with
  | Ok catalog -> catalog
  | Error msg ->
    Alcotest.failf "embedded models.toml should parse for %s tests: %s" suite msg
;;

let install_embedded_model_catalog ~suite =
  Llm_provider.Model_catalog.set_global (load_embedded_model_catalog ~suite)
;;

let repository_model_catalog_path ~suite =
  let executable_dir = Filename.dirname Sys.executable_name in
  if executable_dir = "." || executable_dir = ""
  then
    Alcotest.failf
      "models.toml path unavailable for %s tests; run the suite through Dune"
      suite
  else Filename.concat (Filename.dirname executable_dir) "models.toml"
;;

let load_repo_model_catalog ~suite =
  let path = repository_model_catalog_path ~suite in
  match Llm_provider.Model_catalog.load_file path with
  | Ok catalog -> catalog
  | Error msg ->
    Alcotest.failf "models.toml should parse for %s tests (%s): %s" suite path msg
;;
