module Identity = Runtime_response_identity

let checked = ref 0
let check message predicate = incr checked; if not predicate then failwith message

let identity ?(runtime = "runtime-a") ?(model = "model-a") suffix =
  match Identity.make ~execution_id:("run-" ^ suffix) ~actor:"worker" ~runtime_id:runtime
    ~response_id:("response-" ^ suffix) ~provider_id:"provider-a" ~model_id:model
    ~tool_use_id:("tool-" ^ suffix) ~provider_turn:1 ~source_tool_use_ordinal:1 with
  | Ok value -> value
  | Error detail -> failwith detail

let () =
  let original = identity "original" in
  let json = Identity.to_yojson original in
  check "wire roundtrip" (match Identity.of_yojson json with
    | Ok value -> Identity.to_yojson value = json | Error _ -> false);
  check "empty model refused" (match Identity.make ~execution_id:"run" ~actor:"worker"
    ~runtime_id:"runtime" ~response_id:"response" ~provider_id:"provider" ~model_id:""
    ~tool_use_id:"tool" ~provider_turn:1 ~source_tool_use_ordinal:0 with Error _ -> true | Ok _ -> false);
  check "negative ordinal refused" (match Identity.make ~execution_id:"run" ~actor:"worker"
    ~runtime_id:"runtime" ~response_id:"response" ~provider_id:"provider" ~model_id:"model"
    ~tool_use_id:"tool" ~provider_turn:(-1) ~source_tool_use_ordinal:0 with Error _ -> true | Ok _ -> false);
  check "negative original source ordinal refused" (match Identity.make ~execution_id:"run" ~actor:"worker"
    ~runtime_id:"runtime" ~response_id:"response" ~provider_id:"provider" ~model_id:"model"
    ~tool_use_id:"tool" ~provider_turn:1 ~source_tool_use_ordinal:(-1) with Error _ -> true | Ok _ -> false);
  check "original source ordinal survives readback" (match Identity.of_yojson json with
    | Ok value -> value.source_tool_use_ordinal=1 | Error _ -> false);
  check "absent original ordinal is not invented" (match json with
    | `Assoc fields -> (match Identity.of_yojson (`Assoc (List.remove_assoc "source_tool_use_ordinal" fields)) with
        | Error _ -> true | Ok _ -> false)
    | _ -> false);
  check "duplicate field refused" (match json with
    | `Assoc fields -> (match Identity.of_yojson (`Assoc (("model_id", `String "forged") :: fields)) with
        | Error _ -> true | Ok _ -> false)
    | _ -> false);
  let alias = identity ~runtime:"other-alias" "alias" in
  check "two aliases cannot invent a distinct model"
    (Identity.observe_pair ~producer:(Some original) ~evaluator:(Some alias) = Identity.Same_model_identity);
  let changed = identity ~model:"model-b" "changed" in
  check "the same alias with a changed reported model is distinct"
    (Identity.observe_pair ~producer:(Some original) ~evaluator:(Some changed) = Identity.Distinct_model_identity);
  check "missing producer remains unknown"
    (Identity.observe_pair ~producer:None ~evaluator:(Some alias) = Identity.Producer_unobserved);
  check "missing judge remains unknown"
    (Identity.observe_pair ~producer:(Some original) ~evaluator:None = Identity.Evaluator_unobserved);
  check "both missing remains unknown"
    (Identity.observe_pair ~producer:None ~evaluator:None = Identity.Both_unobserved);
  check "later execution cannot mutate original identity"
    (Identity.to_yojson original = json && original.response_id = "response-original");
  let summary = Identity.summarize_pairs
    [ Some original, Some alias; Some original, Some changed
    ; None, Some alias; Some original, None; None, None ] in
  check "coverage retains each unknown cause"
    (summary.producer_unobserved_count = 1 && summary.evaluator_unobserved_count = 1
     && summary.both_unobserved_count = 1);
  let observation = Identity.pair_summary_to_yojson summary in
  let member name = Yojson.Safe.Util.member name observation in
  check "only complete pairs count as observed" (member "observed_verdict_count" = `Int 2);
  check "missing pairs are counted separately" (member "unobserved_verdict_count" = `Int 3);
  check "unknown pairs cannot dilute the measured rate" (member "distinct_model_identity_rate" = `Float 0.5);
  let unobserved = Identity.summarize_pairs [None, None]
    |> Identity.pair_summary_to_yojson in
  check "no pair yields an unavailable rate"
    (Yojson.Safe.Util.member "distinct_model_identity_rate" unobserved = `Null);
  Printf.printf "runtime response identity: %d actual-source checks passed\n" !checked
