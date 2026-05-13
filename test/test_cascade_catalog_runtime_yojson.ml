(** Regression test for [Cascade_catalog_runtime.candidate_probe_to_yojson].

    Pins the post-PR-#15070 behaviour: the boot-log JSON serializer for
    catalog candidates emits the *real* identity fields ([model_string],
    [provider_kind], [model_id], [base_url]) from the probe record, not
    the [public_runtime_*_label] placeholder that #15040 had wired in.

    The Runtime Lens redaction is intentional at external boundaries
    (Prometheus labels via [record_probe_metrics], the dashboard OAS
    bridge, [Keeper_unified_metrics.redacted_*]), but the boot log is an
    internal observability surface — operators need real provider /
    model identity to verify the loaded cascade.toml. If a future PR
    reapplies the lens at this serializer, this test fails first. *)

open Masc_mcp
module C = Cascade_catalog_runtime

let probe ?(status = C.Probe_ok) ~model_string ~provider_kind ~model_id ~base_url
    () : C.candidate_probe =
  { model_string; provider_kind; model_id; base_url; status }

let assoc_string key json =
  match Yojson.Safe.Util.member key json with
  | `String s -> s
  | other ->
      Alcotest.failf "expected string at key %S, got %s" key
        (Yojson.Safe.to_string other)

let assoc_member key json = Yojson.Safe.Util.member key json

let test_probe_ok_real_identity () =
  let p =
    probe ~status:C.Probe_ok
      ~model_string:"ollama_cloud.ollama-cloud-deepseek-v4-pro"
      ~provider_kind:"ollama_http"
      ~model_id:"deepseek-v4-pro:cloud"
      ~base_url:"https://ollama.com"
      ()
  in
  let json = C.candidate_probe_to_yojson p in
  Alcotest.(check string)
    "model_string is real"
    "ollama_cloud.ollama-cloud-deepseek-v4-pro"
    (assoc_string "model_string" json);
  Alcotest.(check string)
    "provider_kind is real" "ollama_http"
    (assoc_string "provider_kind" json);
  Alcotest.(check string)
    "model_id is real" "deepseek-v4-pro:cloud"
    (assoc_string "model_id" json);
  Alcotest.(check string)
    "base_url is real" "https://ollama.com"
    (assoc_string "base_url" json);
  Alcotest.(check string) "status is ok" "ok" (assoc_string "status" json);
  match assoc_member "error" json with
  | `Null -> ()
  | other ->
      Alcotest.failf "expected `Null at error, got %s"
        (Yojson.Safe.to_string other)

let test_probe_not_applicable_real_identity () =
  let p =
    probe
      ~status:(C.Probe_not_applicable "cloud probe not run at boot")
      ~model_string:"claude_code.claude-auto"
      ~provider_kind:"anthropic_cli"
      ~model_id:"auto"
      ~base_url:""
      ()
  in
  let json = C.candidate_probe_to_yojson p in
  Alcotest.(check string)
    "model_string survives not_applicable status" "claude_code.claude-auto"
    (assoc_string "model_string" json);
  Alcotest.(check string)
    "provider_kind survives" "anthropic_cli"
    (assoc_string "provider_kind" json);
  Alcotest.(check string)
    "model_id survives" "auto"
    (assoc_string "model_id" json);
  Alcotest.(check string) "base_url survives empty" ""
    (assoc_string "base_url" json);
  Alcotest.(check string)
    "status is not_applicable" "not_applicable"
    (assoc_string "status" json);
  Alcotest.(check string)
    "error message preserved" "cloud probe not run at boot"
    (assoc_string "error" json)

let test_probe_error_real_identity () =
  let p =
    probe
      ~status:(C.Probe_error "endpoint unreachable")
      ~model_string:"ollama.local-default"
      ~provider_kind:"ollama_http"
      ~model_id:"qwen3.5"
      ~base_url:"http://127.0.0.1:11434"
      ()
  in
  let json = C.candidate_probe_to_yojson p in
  Alcotest.(check string)
    "model_string survives error status" "ollama.local-default"
    (assoc_string "model_string" json);
  Alcotest.(check string) "model_id survives" "qwen3.5"
    (assoc_string "model_id" json);
  Alcotest.(check string)
    "base_url survives" "http://127.0.0.1:11434"
    (assoc_string "base_url" json);
  Alcotest.(check string) "status is error" "error"
    (assoc_string "status" json);
  Alcotest.(check string)
    "error message preserved" "endpoint unreachable"
    (assoc_string "error" json)

let test_probe_skipped_real_identity () =
  let p =
    probe
      ~status:(C.Probe_skipped "endpoint not probed")
      ~model_string:"glm-coding.glm-5-1"
      ~provider_kind:"openai_http"
      ~model_id:"glm-5.1"
      ~base_url:"https://api.z.ai/api/coding/paas/v4"
      ()
  in
  let json = C.candidate_probe_to_yojson p in
  Alcotest.(check string)
    "model_string survives skipped status" "glm-coding.glm-5-1"
    (assoc_string "model_string" json);
  Alcotest.(check string) "status is skipped" "skipped"
    (assoc_string "status" json)

(* Anti-regression: assert specifically that the placeholder strings used
   pre-#15070 do NOT appear in the JSON when the probe carries real
   values. If a future PR reapplies the Runtime Lens here, this test
   detects it directly. *)
let test_no_runtime_placeholder_when_identity_is_real () =
  let p =
    probe ~status:C.Probe_ok
      ~model_string:"specific.model"
      ~provider_kind:"specific_provider"
      ~model_id:"specific-id"
      ~base_url:"https://specific.example/"
      ()
  in
  let json = C.candidate_probe_to_yojson p in
  let text = Yojson.Safe.to_string json in
  let contains_placeholder =
    let placeholder = "\"runtime\"" in
    let placeholder_value_in_identity_field =
      List.exists
        (fun key ->
          let needle = Printf.sprintf "\"%s\":%s" key placeholder in
          let exists s sub =
            let nlen = String.length sub and slen = String.length s in
            let rec loop i =
              i + nlen <= slen && (String.sub s i nlen = sub || loop (i + 1))
            in
            loop 0
          in
          exists text needle)
        [ "model_string"; "provider_kind"; "model_id" ]
    in
    placeholder_value_in_identity_field
  in
  Alcotest.(check bool)
    "no Runtime Lens placeholder leaked into identity fields" false
    contains_placeholder

let case name f = Alcotest.test_case name `Quick f

let () =
  Alcotest.run "Cascade_catalog_runtime.candidate_probe_to_yojson"
    [
      ( "real identity",
        [
          case "Probe_ok emits real identity"
            test_probe_ok_real_identity;
          case "Probe_not_applicable emits real identity"
            test_probe_not_applicable_real_identity;
          case "Probe_error emits real identity"
            test_probe_error_real_identity;
          case "Probe_skipped emits real identity"
            test_probe_skipped_real_identity;
        ] );
      ( "anti-regression",
        [
          case "no Runtime Lens placeholder in identity fields"
            test_no_runtime_placeholder_when_identity_is_real;
        ] );
    ]
