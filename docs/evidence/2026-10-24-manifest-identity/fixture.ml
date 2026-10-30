module Manifest = Capability_manifest
let item id tools = `Assoc ["id_prefix",`String id;"supports_tools",`Bool tools]
let json models = `Assoc ["schema_version",`Int 1;"models",`List models]
let parse models = Manifest.of_json (json models)
let unwrap = function Ok value -> value | Error detail -> failwith detail
let tools manifest model =
  Option.bind (Manifest.lookup manifest (Model_identifiers.Model_id.of_string_exn model))
    (fun entry -> entry.Manifest.supports_tools)
let () =
  let initial = unwrap (parse [item "Original" true]) in
  Manifest.set_global initial;
  let rejected = parse [item "duplicate" true;item "DUPLICATE" false] in
  (match rejected with Ok manifest -> Manifest.set_global manifest | Error _ -> ());
  let snapshot = Manifest.global () in
  let distinct = unwrap (parse [item "alpha" true;item "beta" false]) in
  let overlap = unwrap (parse [item "model" true;item "model-v2" false]) in
  let checks = [
    "identical_model_identity_rejected", Result.is_error(parse [item "model" true;item "model" false]);
    "case_variant_identity_rejected", Result.is_error rejected;
    "reverse_order_also_rejected", Result.is_error(parse [item "DUPLICATE" false;item "duplicate" true]);
    "identical_facts_do_not_hide_duplicate_identity", Result.is_error(parse [item "model" true;item "MODEL" true]);
    "distinct_identities_accepted", List.length(Manifest.entries distinct)=2;
    "lookup_uses_declared_identity_comparison", tools initial "original-v1"=Some true;
    "lookup_excludes_unrelated_identity", tools distinct "unknown"=None;
    "original_identity_bytes_preserved", (match Manifest.entries initial with
      | [entry] -> Model_identifiers.Id_prefix.to_string entry.id_prefix="Original" | _ -> false);
    "failed_admission_cannot_replace_installed_snapshot", (match snapshot with
      | Some manifest -> tools manifest "original-v1"=Some true | None -> false);
    "empty_is_explicit_validated_manifest", Manifest.entries Manifest.empty=[];
    "distinct_prefix_order_unchanged", tools overlap "model-v2"=Some true;
    "duplicate_json_fields_still_rejected", Result.is_error(parse [
      `Assoc ["id_prefix",`String "first";"id_prefix",`String "second"]])
  ] in
  Manifest.clear_global ();
  print_endline(Yojson.Safe.to_string(`Assoc(List.map(fun(name,value)->name,`Bool value)checks)))
