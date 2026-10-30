open Type_extract
module Source = Reasoning_source
let unwrap = function Ok value -> value | Error _ -> failwith "unexpected codec failure"
let source endpoint = Source.create ~provider_kind:Provider_kind.OpenAI_compat
  ~provider_instance:(Source.provider_instance ~base_url:endpoint ~request_path:"/chat")
  ~canonical_model_id:"shared-model"
  ~replay_contract:Reasoning_replay_contract.{replay_policy=All_assistant_messages;
    streaming=No_streaming_reasoning;output_wire=No_output_control} |> unwrap
let () =
  let original=source "https://a.example/private?token=private-value" in
  let checkpoint=Payloads.fixture (Some original) in
  let before=Before_fields.checkpoint_json_with_messages checkpoint [] in
  let after=Current_fields.checkpoint_json_with_messages checkpoint [] in
  let binding=Yojson.Safe.Util.member "provider_binding" after in
  let mutate key value = match binding with
    | `Assoc fields -> `Assoc((key,value)::List.remove_assoc key fields) | value -> value in
  let fields=Yojson.Safe.Util.to_assoc binding in
  let decode=Codec_helpers.provider_binding_of_json ~scope:"fixture" in
  let same = function Some value -> Source.equal original value | None -> false in
  let rotated=source "https://b.example" in
  let checks=[
    "historical_checkpoint_fields_drop_producer", not(List.mem_assoc "provider_binding" (Yojson.Safe.Util.to_assoc before));
    "current_field_builder_emits_exact_source", binding=Source.to_yojson original;
    "actual_binding_codec_roundtrip", same(unwrap(decode binding));
    "no_artifact_messages_required", checkpoint.messages=[] && same(unwrap(decode binding));
    "explicit_null_roundtrip", unwrap(decode `Null)=None;
    "unrecorded_field_is_explicit_null", Yojson.Safe.Util.member "provider_binding"
      (Current_fields.checkpoint_json_with_messages (Payloads.fixture None) [])=`Null;
    "noncanonical_kind_rejected", Result.is_error(decode(mutate "provider_kind" (`String "OPENAI_COMPAT")));
    "invalid_endpoint_hash_rejected", Result.is_error(decode(mutate "provider_instance_id" (`String "https://a.example")));
    "missing_model_rejected", Result.is_error(decode(`Assoc(List.remove_assoc "canonical_model_id" fields)));
    "duplicate_model_rejected", Result.is_error(decode(`Assoc(("canonical_model_id",`String "other")::fields)));
    "duplicate_contract_field_rejected", Result.is_error(decode(mutate "replay_contract"
      (match List.assoc "replay_contract" fields with
       | `Assoc ((key,value)::_ as entries) -> `Assoc ((key,value)::entries)
       | value -> value)));
    "unknown_binding_field_rejected", Result.is_error(decode(`Assoc(("credentials",`String "secret")::fields)));
    "binding_contains_only_nonsecret_fields", List.sort String.compare (List.map fst fields)
      =["canonical_model_id";"provider_instance_id";"provider_kind";"replay_contract"];
    "endpoint_difference_is_observable", not(Source.equal original rotated);
    "declared_text_rotation_still_admits", Source.rotation_admits ~rotation_policy:Allow_endpoint_rotation ~stored:original ~target:rotated;
    "declared_signed_rotation_still_refuses", not(Source.rotation_admits ~rotation_policy:Require_identical_source ~stored:original ~target:rotated)
  ] in
  print_endline(Yojson.Safe.to_string(`Assoc(List.map(fun(k,v)->k,`Bool v) checks)))
