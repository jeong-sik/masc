module Manifest = Capability_manifest
module Model = Model_identifiers.Model_id
let before = Array.length Sys.argv > 1 && Sys.argv.(1) = "before"
let version = if before then 1 else 2
let field = if before then "id_prefix" else "model_id"
let entry id tools = `Assoc [field,`String id; "supports_tools",`Bool tools]
let json entries = `Assoc ["schema_version",`Int version; "models",`List entries]
let parse entries = match Manifest.of_json (json entries) with
  | Ok manifest -> manifest | Error error -> failwith error
let lookup manifest id = Manifest.lookup manifest (Model.of_string_exn id)
let tools manifest id = Option.bind (lookup manifest id) (fun entry -> entry.Manifest.supports_tools)
let broad = entry "custom-model" false
let exact = entry "custom-model-q4" true
let ordered = parse [broad;exact]
let reversed = parse [exact;broad]
let checks = if before then
  ["unknown_suffix_inherits_permission",tools (parse [entry "custom-model" true]) "custom-model-unregistered" = Some true;
   "declaration_order_changes_exact_target",tools ordered "custom-model-q4" = Some false
       && tools reversed "custom-model-q4" = Some true]
else
  let rejects value = match Manifest.of_json value with Error _ -> true | Ok _ -> false in
  ["exact_model_uses_own_permission",tools ordered "custom-model-q4" = Some true;
   "reordering_preserves_exact_target",tools reversed "custom-model-q4" = Some true;
   "other_exact_model_keeps_own_permission",tools ordered "custom-model" = Some false;
   "unknown_suffix_has_no_authority",lookup ordered "custom-model-q4-extra" = None;
   "unknown_quantization_has_no_authority",lookup ordered "custom-model-q8" = None;
   "provider_qualified_id_not_stripped",lookup ordered "vendor/custom-model-q4" = None;
   "case_folded_exact_id",tools ordered "CUSTOM-MODEL-Q4" = Some true;
   "duplicate_case_identity_rejected",rejects (json [exact;entry "CUSTOM-MODEL-Q4" false]);
   "old_schema_rejected",rejects (`Assoc ["schema_version",`Int 1;"models",`List []]);
   "prefix_field_rejected",rejects (json [`Assoc ["id_prefix",`String "custom-model"]]);
   "missing_model_id_rejected",rejects (json [`Assoc ["supports_tools",`Bool true]]);
   "missing_models_rejected",rejects (`Assoc ["schema_version",`Int version]);
   "null_models_rejected",rejects (`Assoc ["schema_version",`Int version;"models",`Null]);
   "explicit_empty_is_valid",(match Manifest.of_json (json []) with Ok m -> Manifest.entries m=[] | Error _->false)]
let () = Yojson.Safe.to_channel stdout (`Assoc (List.map(fun(k,v)->k,`Bool v) checks));print_newline ()
