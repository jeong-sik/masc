open Alcotest
module Http = Masc_tui_http

let receipt ?(keeper = "alpha") ?(submission = "submitted") ?(completion = "unobserved") () =
  `Assoc ["schema", `String "keeper.memory.catch_up.v1";
    "keeper", `String keeper; "submission", `String submission;
    "completion", `String completion]

let outcome response =
  Http.mutation_outcome response |> Http.keeper_memory_catch_up_outcome ~keeper_name:"alpha"

let label = function
  | Http.Catch_up_submitted -> "submitted"
  | Catch_up_coalesced -> "coalesced"
  | Catch_up_not_sent _ -> "not sent"
  | Catch_up_refused _ -> "refused"
  | Catch_up_unconfirmed _ -> "unconfirmed"

let test_only_matching_acceptance_is_confirmed () =
  List.iter (fun (submission, expected) ->
    check string "acceptance receipt" expected
      (label (outcome (Ok (202, Yojson.Safe.to_string (receipt ~submission ()))))))
    ["submitted", "submitted"; "coalesced", "coalesced"];
  let malformed =
    [receipt ~keeper:"beta" (); receipt ~submission:"dropped" (); receipt ~completion:"done" ();
     `Assoc ["schema", `String "keeper.memory.catch_up.v1"];
     `Assoc ["schema", `String "keeper.memory.catch_up.v1"; "keeper", `String "alpha";
       "submission", `String "submitted"; "completion", `String "unobserved"; "extra", `Null]] in
  List.iter (fun json ->
    check string "unmatched success leaves admission unconfirmed" "unconfirmed"
      (label (outcome (Ok (202, Yojson.Safe.to_string json))))) malformed

let test_transport_and_server_refusal_are_distinct () =
  List.iter (fun (response, expected) ->
    check string "effect certainty" expected (label (outcome response)))
    [Error "connection lost", "unconfirmed";
     Ok (403, {|{"error":"permission refused"}|}), "refused";
     Ok (409, {|{"error":"disabled"}|}), "refused";
     Ok (503, {|{"error":"executor unavailable"}|}), "unconfirmed";
     Ok (202, "truncated{"), "unconfirmed"]

let () =
  run "memory catch-up receipt"
    ["effect boundary", [
      test_case "receipt binds Keeper and distinguishes acceptance from completion" `Quick
        test_only_matching_acceptance_is_confirmed;
      test_case "response loss is not a refusal" `Quick
        test_transport_and_server_refusal_are_distinct]]
