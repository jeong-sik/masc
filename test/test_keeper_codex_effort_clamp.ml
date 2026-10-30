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

(* Native Anthropic effort declarations now reach the shared catalog clamp.
   Minimal must become Low; values already admitted by the model stay exact. *)
let test_catalog_clamp_applies_to_anthropic_rows () =
  let sonnet = "claude-sonnet-5" in
  check_case
    ~label_prefix:"sonnet"
    ~model_id:(Some sonnet)
    ~requested:(Some Effort.Minimal)
    ~expected:(Some Effort.Low)
    ();
  List.iter (fun effort ->
    check_case ~label_prefix:"sonnet" ~model_id:(Some sonnet)
      ~requested:(Some effort) ~expected:(Some effort) ())
    [ Effort.Low; Effort.Medium; Effort.High; Effort.XHigh; Effort.Max ]
;;

(* The CLI snap remains necessary when the model has no catalog declaration.
   The catalog cannot invent a ladder, but the adapter owns its CLI vocabulary. *)
let test_claude_cli_snap_admits_minimal_as_low () =
  let snap = Runtime_claude_code.cli_admitted_reasoning_effort in
  let after_catalog = Map.clamp_reasoning_effort_to_catalog
    ~model_id:(Some "masc-test-no-such-model") ~requested:(Some Effort.Minimal) in
  Alcotest.(check string) "catalog miss preserves the request" "minimal" (label after_catalog);
  Alcotest.(check string) "CLI still admits the uncatalogued request" "low"
    (label (Option.map snap after_catalog));
  Alcotest.(check string) "minimal snaps to low" "low"
    (Effort.to_string (snap Effort.Minimal));
  let uncatalogued_ultra = Map.clamp_reasoning_effort_to_catalog
    ~model_id:(Some "masc-test-no-such-model") ~requested:(Some Effort.Ultra) in
  Alcotest.(check string) "uncatalogued Claude ultra snaps to max" "max"
    (label (Option.map snap uncatalogued_ultra));
  (match Runtime_claude_code.command ~system_prompt_file:None
      (Runtime_claude_code.default_config ~cwd:"/tmp") ~dynamic_tools:[]
      ~reasoning_effort:(Some Effort.Ultra) ~session_mode:Start ~session_id:"fixture" with
   | Error (Invalid_config _) -> ()
   | Error error -> Alcotest.fail (Runtime_claude_code.error_to_string error)
   | Ok _ -> Alcotest.fail "raw ultra reached Claude argv");
  List.iter
    (fun effort ->
       Alcotest.(check string)
         ("identity for " ^ Effort.to_string effort)
         (Effort.to_string effort)
         (Effort.to_string (snap effort)))
    [ Effort.None_; Effort.Low; Effort.Medium; Effort.High; Effort.XHigh; Effort.Max ]
;;

let test_claude_uncatalogued_ultra_is_admitted_before_argv () =
  let requested = Map.clamp_reasoning_effort_to_catalog
    ~model_id:(Some "masc-test-no-such-model") ~requested:(Some Effort.Ultra) in
  Alcotest.(check string) "catalog miss retains Ultra for adapter admission"
    "ultra" (label requested);
  let command effort = Runtime_claude_code.command ~system_prompt_file:None
    (Runtime_claude_code.default_config ~cwd:"/tmp") ~dynamic_tools:[]
    ~reasoning_effort:effort ~session_mode:Runtime_claude_code.Start
    ~session_id:"11111111-1111-4111-8111-111111111111" in
  (match command requested with
   | Error (Runtime_claude_code.Invalid_config _) -> ()
   | Error error -> Alcotest.fail (Runtime_claude_code.error_to_string error)
   | Ok _ -> Alcotest.fail "unadmitted Ultra must never reach Claude CLI argv");
  let admitted = Option.map Runtime_claude_code.cli_admitted_reasoning_effort requested in
  Alcotest.(check string) "Claude's CLI admission maps Ultra to Max" "max" (label admitted);
  let argv = match command admitted with
    | Ok argv -> argv
    | Error error -> Alcotest.fail (Runtime_claude_code.error_to_string error) in
  let rec effort_flag = function
    | "--effort" :: value :: _ -> Some value
    | _ :: rest -> effort_flag rest
    | [] -> None in
  Alcotest.(check (option string)) "admitted command sends the supported CLI effort"
    (Some "max") (effort_flag argv)
;;

let test_codex_models_preserve_advertised_ultra () =
  List.iter
    (fun model_id ->
       check_case ~label_prefix:model_id ~model_id:(Some model_id)
         ~requested:(Some Effort.Ultra) ~expected:(Some Effort.Ultra) ())
    [ "gpt-6.1-sol"; "gpt-6-astra"; "gpt-6-sol"; "gpt-5.6-sol"; "gpt-5.6-terra" ];
  check_case ~label_prefix:"GPT-6 Luna keeps its own ladder"
    ~model_id:(Some "gpt-6-luna") ~requested:(Some Effort.Ultra)
    ~expected:(Some Effort.Max) ()
;;

let () =
  Alcotest.run
    "keeper_codex_effort_clamp"
    [ ( "clamp"
      , [ Alcotest.test_case "catalog clamps effort" `Quick test_clamp
        ; Alcotest.test_case "Codex models preserve advertised ultra" `Quick
            test_codex_models_preserve_advertised_ultra
        ; Alcotest.test_case
            "catalog clamp applies to anthropic rows"
            `Quick
            test_catalog_clamp_applies_to_anthropic_rows
        ; Alcotest.test_case "uncatalogued Claude Ultra is admitted before argv" `Quick
            test_claude_uncatalogued_ultra_is_admitted_before_argv
        ; Alcotest.test_case
            "claude cli snap admits minimal as low"
            `Quick
            test_claude_cli_snap_admits_minimal_as_low
        ] )
    ]
;;
