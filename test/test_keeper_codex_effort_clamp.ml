(* Pins catalog-driven reasoning-effort clamping for the Codex app-server
   runtime. The official-client runtime sits outside AGENT_CORE's request
   validation, so an operator-declared effort the model rejects (e.g. [Max] on
   a model whose catalog row tops out at [XHigh]) would reach the provider and
   fail the turn with a 400. The keeper clamps the effort into the catalog's
   accepted set before the request leaves the process. *)

module Map = Masc.Keeper_codex_runtime.For_testing
module Effort = Llm_provider.Reasoning_effort

let label = function
  | None -> "none"
  | Some e -> Effort.to_string e

let check_case ~label_prefix ~model_id ~requested ~expected () =
  let got = Map.clamp_reasoning_effort_to_catalog ~model_id ~requested in
  Alcotest.(check string)
    (label_prefix ^ ": " ^ label requested ^ " -> " ^ label expected)
    (label expected)
    (label got)
;;

let test_clamp () =
  let spark = "gpt-5.3-codex-spark-1p-codexswic-ev3" in
  (* Regression: spark tops out at [XHigh]; [Max] must snap down to [XHigh]
     rather than fail the turn. This also pins the spark catalog row: if the
     row is removed the lookup returns [None] and [Max] passes through
     unchanged, failing this assertion. *)
  check_case
    ~label_prefix:"spark"
    ~model_id:(Some spark)
    ~requested:(Some Effort.Max)
    ~expected:(Some Effort.XHigh)
    ();
  check_case
    ~label_prefix:"spark"
    ~model_id:(Some spark)
    ~requested:(Some Effort.XHigh)
    ~expected:(Some Effort.XHigh)
    ();
  check_case
    ~label_prefix:"spark"
    ~model_id:(Some spark)
    ~requested:(Some Effort.High)
    ~expected:(Some Effort.High)
    ();
  check_case
    ~label_prefix:"spark"
    ~model_id:(Some spark)
    ~requested:None
    ~expected:None
    ();
  (* No model id: the keeper cannot look up a catalog row, so the requested
     effort passes through unchanged. *)
  check_case
    ~label_prefix:"no-model"
    ~model_id:None
    ~requested:(Some Effort.Max)
    ~expected:(Some Effort.Max)
    ();
  (* Catalog miss: an unrecognized model imposes no constraint. *)
  check_case
    ~label_prefix:"unknown"
    ~model_id:(Some "masc-test-no-such-model")
    ~requested:(Some Effort.Max)
    ~expected:(Some Effort.Max)
    ()
;;

let () =
  Alcotest.run
    "keeper_codex_effort_clamp"
    [ ( "clamp"
      , [ Alcotest.test_case "catalog clamps effort" `Quick test_clamp ] ) ]
;;
