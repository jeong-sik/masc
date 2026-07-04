(** token⊥cost: provider cost_usd is accounted independently of token-count trust.

    Before this decoupling, an untrusted *token count* (e.g.
    [zero_token_usage_reported]) forced the accounted [cost_usd] to 0.0 and the
    source label to [untrusted_usage], even when the provider reported a positive
    authoritative cost. Empirically this had never suppressed a real dollar (all
    untrusted ledger rows carried raw_cost_usd=0.0), so the coupling was a no-op that
    carried a latent footgun: a future provider reporting 0 tokens + nonzero
    cost_usd would have real spend silently dropped from accounting.

    These tests pin the decoupled contract on the assembled cost-ledger payload:

    - untrusted token usage + positive cost_usd => the positive cost is accounted
      ([cost_usd] field), [cost_status="reported"], [cost_usd_source="computed"],
      WHILE [usage_trust="untrusted"] is still surfaced (token-trust visibility
      preserved — only the COST coupling was removed).
    - untrusted token usage + zero/absent cost_usd => 0.0 accounted, and the
      [untrusted_usage] labels are retained (no-op vs. pre-decouple behavior, as
      every real untrusted row carries cost_usd=0.0 today). *)

open Alcotest

module H = Masc.Keeper_hooks_oas
module Trust = Keeper_usage_trust

let string_field payload key =
  match payload with
  | `Assoc fields -> (
      match List.assoc_opt key fields with
      | Some (`String s) -> s
      | Some other -> Alcotest.failf "%s not a string: %s" key (Yojson.Safe.to_string other)
      | None -> Alcotest.failf "%s absent from payload" key)
  | _ -> Alcotest.fail "payload not an object"

let float_field payload key =
  match payload with
  | `Assoc fields -> (
      match List.assoc_opt key fields with
      | Some (`Float f) -> f
      | Some (`Int i) -> float_of_int i
      | Some other -> Alcotest.failf "%s not a number: %s" key (Yojson.Safe.to_string other)
      | None -> Alcotest.failf "%s absent from payload" key)
  | _ -> Alcotest.fail "payload not an object"

let int_field payload key =
  match payload with
  | `Assoc fields -> (
      match List.assoc_opt key fields with
      | Some (`Int n) -> n
      | Some other -> Alcotest.failf "%s not an int: %s" key (Yojson.Safe.to_string other)
      | None -> Alcotest.failf "%s absent from payload" key)
  | _ -> Alcotest.fail "payload not an object"

let check_null_field payload key =
  match payload with
  | `Assoc fields -> (
      match List.assoc_opt key fields with
      | Some `Null -> ()
      | Some other -> Alcotest.failf "%s not null: %s" key (Yojson.Safe.to_string other)
      | None -> Alcotest.failf "%s absent from payload" key)
  | _ -> Alcotest.fail "payload not an object"

(* The canonical untrusted-token signal: provider reported zero token counts. *)
let untrusted_zero_tokens : Trust.t =
  Trust.Usage_untrusted [ "zero_token_usage_reported" ]

let payload
    ?(input_tokens = 0)
    ?(output_tokens = 0)
    ?(cache_creation_input_tokens = 0)
    ?(cache_read_input_tokens = 0)
    ~cost_usd
    ~usage_trust =
  H.cost_event_payload
    ~agent_name:"test_agent"
    ~task_id:None
    ~input_tokens
    ~output_tokens
    ~cost_usd
    ~cache_creation_input_tokens
    ~cache_read_input_tokens
    ~usage_trust
    ()

(* --- the decoupling: untrusted tokens must not drop a real reported cost --- *)

let test_untrusted_tokens_positive_cost_is_accounted () =
  (* 0 tokens (untrusted) but a positive provider cost: the footgun row. *)
  let p = payload ~cost_usd:0.0123 ~usage_trust:untrusted_zero_tokens in
  check (float 1e-9) "positive cost_usd is accounted, not masked to 0.0" 0.0123
    (float_field p "cost_usd");
  check string "cost_status reflects the reported cost" "reported"
    (string_field p "cost_status");
  check string "cost_usd_source labels the accounted cost as computed" "computed"
    (string_field p "cost_usd_source")

let test_untrusted_tokens_still_surface_trust () =
  (* Token-trust visibility is preserved: decoupling cost does NOT silence the
     usage_trust signal that operators alert on. *)
  let p = payload ~cost_usd:0.0123 ~usage_trust:untrusted_zero_tokens in
  check string "usage_trust still surfaces untrusted" "untrusted"
    (string_field p "usage_trust")

(* --- no-op leg: untrusted tokens + zero/absent cost stays 0.0 + untrusted --- *)

let test_untrusted_tokens_zero_cost_stays_zero () =
  let p = payload ~cost_usd:0.0 ~usage_trust:untrusted_zero_tokens in
  check (float 1e-9) "zero cost stays 0.0" 0.0 (float_field p "cost_usd");
  check string "cost_usd_source remains untrusted_usage for zero cost"
    "untrusted_usage" (string_field p "cost_usd_source");
  check string "usage_trust still untrusted" "untrusted"
    (string_field p "usage_trust")

let test_trusted_tokens_positive_cost_unchanged () =
  (* Regression guard: the always-trusted path is unaffected. *)
  let p =
    H.cost_event_payload ~agent_name:"test_agent" ~task_id:None
      ~input_tokens:100 ~output_tokens:50 ~cost_usd:0.0042
      ~usage_trust:Trust.Usage_trusted ()
  in
  check (float 1e-9) "trusted positive cost accounted" 0.0042
    (float_field p "cost_usd");
  check string "trusted positive cost => computed" "computed"
    (string_field p "cost_usd_source");
  check string "trusted positive cost => reported" "reported"
    (string_field p "cost_status")

let test_trusted_tokens_include_cache_delta () =
  let p =
    payload
      ~input_tokens:100
      ~output_tokens:50
      ~cache_creation_input_tokens:10
      ~cache_read_input_tokens:20
      ~cost_usd:0.0042
      ~usage_trust:Trust.Usage_trusted
  in
  check int "cache creation tokens are recorded" 10
    (int_field p "cache_creation_tokens");
  check int "cache read tokens are recorded" 20
    (int_field p "cache_read_tokens");
  check int "cache miss is derived from input minus read/write cache tokens" 70
    (int_field p "cache_miss_input_tokens")

let test_untrusted_tokens_mask_cache_delta () =
  let p =
    payload
      ~input_tokens:100
      ~output_tokens:50
      ~cache_creation_input_tokens:10
      ~cache_read_input_tokens:20
      ~cost_usd:0.0
      ~usage_trust:untrusted_zero_tokens
  in
  check_null_field p "cache_creation_tokens";
  check_null_field p "cache_read_tokens";
  check_null_field p "cache_miss_input_tokens";
  check int "raw cache creation is still available for diagnosis" 10
    (int_field p "raw_cache_creation_tokens");
  check int "raw cache read is still available for diagnosis" 20
    (int_field p "raw_cache_read_tokens")

let () =
  run "cost_token_decouple"
    [
      ( "decouple",
        [
          test_case "untrusted tokens + positive cost is accounted" `Quick
            test_untrusted_tokens_positive_cost_is_accounted;
          test_case "untrusted tokens still surface usage_trust" `Quick
            test_untrusted_tokens_still_surface_trust;
        ] );
      ( "no-op-leg",
        [
          test_case "untrusted tokens + zero cost stays 0.0/untrusted" `Quick
            test_untrusted_tokens_zero_cost_stays_zero;
          test_case "trusted tokens + positive cost unchanged" `Quick
            test_trusted_tokens_positive_cost_unchanged;
        ] );
      ( "cache-delta",
        [
          test_case "trusted tokens include cache delta" `Quick
            test_trusted_tokens_include_cache_delta;
          test_case "untrusted tokens mask cache delta" `Quick
            test_untrusted_tokens_mask_cache_delta;
        ] );
    ]
