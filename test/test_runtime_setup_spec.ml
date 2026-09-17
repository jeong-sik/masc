let test_existing_installer_contract () =
  let rows = Yojson.Safe.from_file "fixtures/runtime-setup-spec-parity.json" |> Yojson.Safe.Util.to_list in
  List.iter (fun row ->
    let open Yojson.Safe.Util in
    let spec = match Runtime_setup_spec.of_json (row |> member "spec") with
      | Ok spec -> spec | Error error -> Alcotest.fail (Runtime_setup_spec.error_message error) in
    let rendered = Runtime_setup_spec.render spec in
    Alcotest.check Alcotest.string "same persistent provider/model identity"
      (row |> member "runtime_id" |> to_string) rendered.runtime_id;
    Alcotest.check Alcotest.string "same appended runtime fragment"
      (row |> member "runtime_toml" |> to_string) rendered.runtime_toml;
    Alcotest.check Alcotest.string "same capability/provider/target declarations"
      (row |> member "model_overlay_toml" |> to_string) rendered.model_overlay_toml;
    let whole = "[runtime]\ndefault = " ^ Yojson.Safe.to_string (`String rendered.runtime_id) ^ "\n" ^ rendered.runtime_toml in
    match Runtime_toml.parse_string whole with
    | Ok _ -> () | Error _ -> Alcotest.fail "rendered fragment is not native runtime TOML") rows
let test_rejects_invalid_transport_claims () =
  let valid = {|{"choice":"codex","model":"m","max_context":1024,"tools":true,"streaming":true}|} in
  let fields = match Yojson.Safe.from_string valid with `Assoc fields -> fields | _ -> assert false in
  List.iter (fun spec ->
    Alcotest.check Alcotest.bool "invalid specification refused" true
      (Result.is_error (Runtime_setup_spec.of_json spec))) [
      `Assoc (("model",`String "another")::fields);
      `Assoc (("secret",`String "must-not-enter-spec")::fields);
      `Assoc (("endpoint",`String "https://unrelated.invalid")::fields);
      `Assoc (("max_context",`Bool true)::List.remove_assoc "max_context" fields)];
  let invalid = {|{"choice":"messages","model":"m","max_context":1024,"tools":true,"streaming":true,"endpoint":"https://fixture.invalid","provider_kind":"openai_compat"}|} in
  Alcotest.check Alcotest.bool "messages cannot disguise OpenAI wire semantics" true
    (Result.is_error (Runtime_setup_spec.of_json (Yojson.Safe.from_string invalid)))
let test_native_fractional_identity () =
  (* The native renderer is the identity authority. Equivalent JSON decimal
     spellings must join even when Python's shortest printer spells them
     differently from Yojson. Callers consume this runtime_id before selection. *)
  let render timeout =
    let input = Printf.sprintf
      {|{"choice":"antigravity","model":"selected-model","max_context":1024,"tools":true,"streaming":false,"credential_file":"/owned/oauth","timeout_s":%s}|} timeout in
    match Runtime_setup_spec.of_json (Yojson.Safe.from_string input) with
    | Ok spec -> Runtime_setup_spec.render spec
    | Error error -> Alcotest.fail (Runtime_setup_spec.error_message error) in
  let shortest = render "824.844977148233" in
  let roundtrip = render "824.8449771482331" in
  Alcotest.check Alcotest.string "equivalent IEEE number has one native identity"
    shortest.runtime_id roundtrip.runtime_id;
  Alcotest.check Alcotest.string "equivalent number renders the same configuration"
    shortest.runtime_toml roundtrip.runtime_toml;
  let whole = "[runtime]\ndefault = " ^ Yojson.Safe.to_string (`String shortest.runtime_id) ^ "\n" ^ shortest.runtime_toml in
  Alcotest.check Alcotest.bool "native fractional output parses as configuration"
    true (Result.is_ok (Runtime_toml.parse_string whole))
(* A workspace whose librarian_exact lane has no slot boots with one WARN and
   curates nothing, and setup is the only place that knows which runtime this
   machine actually has. An official client is admitted by its runtime id and
   an HTTP runtime by its overlay target id; both are the runtime_id here, so
   what changes between the two is which key carries it. *)
let test_setup_declares_the_librarian_lane () =
  let render input =
    match Runtime_setup_spec.of_json (Yojson.Safe.from_string input) with
    | Ok spec -> Runtime_setup_spec.render spec
    | Error error -> Alcotest.fail (Runtime_setup_spec.error_message error) in
  let contains haystack needle =
    let n = String.length needle and h = String.length haystack in
    let rec scan i = i + n <= h && (String.sub haystack i n = needle || scan (i + 1)) in
    n = 0 || scan 0 in
  let client =
    render {|{"choice":"claude_code","model":"claude-sonnet-5","max_context":200000,"tools":true,"streaming":true}|} in
  Alcotest.check Alcotest.bool "an official client is declared as a cli slot" true
    (contains client.runtime_toml
       ({|"cli_slots" = ["|} ^ client.runtime_id ^ {|"]|}));
  Alcotest.check Alcotest.bool "and carries no catalog slot" true
    (contains client.runtime_toml {|"slots" = []|});
  let http =
    render {|{"choice":"ollama","model":"fixture-model","max_context":8192,"tools":true,"streaming":true,"endpoint":"https://fixture.invalid/v1"}|} in
  Alcotest.check Alcotest.bool "an HTTP runtime is declared as a catalog slot" true
    (contains http.runtime_toml ({|"slots" = ["|} ^ http.runtime_id ^ {|"]|}));
  Alcotest.check Alcotest.bool "and carries no cli slot" true
    (contains http.runtime_toml {|"cli_slots" = []|});
  List.iter
    (fun rendered ->
       let whole =
         "[runtime]\ndefault = "
         ^ Yojson.Safe.to_string (`String rendered.Runtime_setup_spec.runtime_id)
         ^ "\n" ^ rendered.Runtime_setup_spec.runtime_toml in
       match Runtime_toml.parse_string whole with
       | Ok _ -> ()
       | Error _ -> Alcotest.fail "declared librarian lane is not native runtime TOML")
    [ client; http ]

let () = Alcotest.run "native runtime setup spec" ["contract",[
  Alcotest.test_case "representative installer identity and TOML parity" `Quick test_existing_installer_contract;
  Alcotest.test_case "native fractional number identity" `Quick test_native_fractional_identity;
  Alcotest.test_case "typed input rejects incompatible declarations" `Quick test_rejects_invalid_transport_claims;
  Alcotest.test_case "setup declares the librarian lane" `Quick test_setup_declares_the_librarian_lane]]
