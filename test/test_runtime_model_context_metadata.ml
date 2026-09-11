let test_provider_window () =
  let catalog=Llm_provider.Model_catalog.load_default () |> Result.get_ok in
  let seed=List.hd (Llm_provider.Model_catalog.model_entries catalog) in
  let binding=List.hd (Agent_core.Provider_runtime_binding.all ()) in
  let row provider context = {seed with Llm_provider.Model_catalog.provider_name=provider;
    id_prefix="exact-model";supported_models=None;max_context_tokens=Some context} in
  let find rows=Runtime_model_context_metadata.find ~provider_id:binding.id ~model:"exact-model" rows in
  Alcotest.check (Alcotest.option Alcotest.int) "generic architectural window never substitutes for provider" None
    (find [row None 1000000]);
  Alcotest.check (Alcotest.option Alcotest.int) "exact provider declaration wins without generic conflict" (Some 32768)
    (find [row None 1000000;row (Some binding.id) 32768]);
  Alcotest.check (Alcotest.option Alcotest.int) "other provider not accepted" None
    (find [row (Some "unrelated-provider") 32768]);
  Alcotest.check (Alcotest.option Alcotest.int) "conflicting provider windows refused" None
    (find [row (Some binding.id) 32768;row (Some binding.id) 65536]);
  Alcotest.check (Alcotest.option Alcotest.int) "family prefix cannot prove exact served model" None
    (Runtime_model_context_metadata.find ~provider_id:binding.id ~model:"exact-model-child"
      [row (Some binding.id) 32768])
let () = Alcotest.run "provider context metadata" ["authority",[
  Alcotest.test_case "provider and exact model join" `Quick test_provider_window]]
