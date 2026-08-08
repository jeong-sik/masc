module Model_catalog = Llm_provider.Model_catalog
module EO = Llm_provider.Exact_output

let fail message =
  Printf.eprintf "model_catalog_standalone_probe: %s\n" message;
  exit 1
;;

let () =
  Model_catalog.clear_global ();
  match Model_catalog.load_default () with
  | Error detail -> fail ("embedded default catalog was unavailable: " ^ detail)
  | Ok catalog ->
    let model_count = List.length (Model_catalog.model_entries catalog) in
    let provider_count = List.length (Model_catalog.provider_entries catalog) in
    if model_count = 0
    then fail "embedded default catalog contained no model entries"
    else (
      Printf.printf
        "embedded model catalog: %d models, %d providers\n"
        model_count
        provider_count;
      let io : EO.resolver_io = { getenv = (fun _ -> Ok None) } in
      match EO.load_resolver_snapshot ~io () with
      | Error _ -> fail "embedded resolver snapshot failed"
      | Ok _ -> ())
;;
