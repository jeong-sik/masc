(* Pins catalog-driven reasoning-effort clamping for the official-client
   lanes (Codex and Claude Code share the host implementation). These
   runtimes sit outside AGENT_CORE's request validation, so an
   operator-declared effort the model rejects (e.g. [Max] on a model whose
   catalog row tops out at [XHigh], or [Minimal] which the Claude CLI refuses
   outright) would fail the turn. The host clamps the effort into the
   catalog's accepted set before the request leaves the process. *)

module Map = Masc.Keeper_official_client_host
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

(* Anthropic catalog rows declare [accepted_reasoning_efforts], but the
   capability layer withholds the list for models whose
   [thinking_control_format] is [No_thinking_control] (capabilities.ml), so
   the catalog clamp is a no-op for the Claude lane. This case pins that
   fact: if the capability layer ever starts exposing the anthropic accepted
   set, this goes red and the Claude lane's own CLI snap below becomes
   partially redundant — re-evaluate both then. *)
let test_catalog_clamp_is_a_noop_for_anthropic_rows () =
  let sonnet = "claude-sonnet-5" in
  check_case
    ~label_prefix:"sonnet"
    ~model_id:(Some sonnet)
    ~requested:(Some Effort.Minimal)
    ~expected:(Some Effort.Minimal)
    ()
;;

(* The Claude lane survives [minimal] through the CLI-vocabulary snap owned
   by the adapter, not through the catalog: [minimal] is the one effort the
   CLI refuses and its nearest admitted neighbour is [low]. Before the snap,
   [reasoning_args] rejected it with Invalid_config and the whole turn
   died. *)
let test_claude_cli_snap_admits_minimal_as_low () =
  let snap = Runtime_claude_code.cli_admitted_reasoning_effort in
  Alcotest.(check string) "minimal snaps to low" "low"
    (Effort.to_string (snap Effort.Minimal));
  List.iter
    (fun effort ->
       Alcotest.(check string)
         ("identity for " ^ Effort.to_string effort)
         (Effort.to_string effort)
         (Effort.to_string (snap effort)))
    [ Effort.None_; Effort.Low; Effort.Medium; Effort.High; Effort.XHigh; Effort.Max ]
;;

let () =
  Alcotest.run
    "keeper_codex_effort_clamp"
    [ ( "clamp"
      , [ Alcotest.test_case "catalog clamps effort" `Quick test_clamp
        ; Alcotest.test_case
            "catalog clamp is a no-op for anthropic rows"
            `Quick
            test_catalog_clamp_is_a_noop_for_anthropic_rows
        ; Alcotest.test_case
            "claude cli snap admits minimal as low"
            `Quick
            test_claude_cli_snap_admits_minimal_as_low
        ] )
    ]
;;
