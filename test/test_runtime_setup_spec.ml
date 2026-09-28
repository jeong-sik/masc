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
(* The sibling of the fractional case above: an answer left out and the same
   answer written with its default are one answer, so they are one connection.
   The inventory fills [provider_kind] on every round trip, so before identity
   came from the parsed value, adding an endpoint and reconfiguring it produced
   two ids for one endpoint — the second arriving as a duplicate row beside a
   stale one, because the batch appends an id it has not seen. *)
let test_one_answer_is_one_connection () =
  let id input =
    match Runtime_setup_spec.of_json (Yojson.Safe.from_string input) with
    | Ok spec -> (Runtime_setup_spec.render spec).runtime_id
    | Error error -> Alcotest.fail (Runtime_setup_spec.error_message error) in
  let base = {|"choice":"vllm","model":"m","max_context":8192,"tools":true,"streaming":false,"endpoint":"http://h:9/v1"|} in
  let bare = id ("{" ^ base ^ "}") in
  Alcotest.check Alcotest.string "a dialect written as its own default is the same connection"
    bare (id ("{" ^ base ^ {|,"provider_kind":"openai_compat"|} ^ "}"));
  Alcotest.check Alcotest.string "an empty credential name is no credential, not another one"
    bare (id ("{" ^ base ^ {|,"api_key_env":""|} ^ "}"));
  List.iter (fun (label, changed) ->
    Alcotest.check Alcotest.bool label true (bare <> id ("{" ^ changed ^ "}")))
    [ "a different dialect is a different connection",
      base ^ {|,"provider_kind":"glm"|}
    ; "a different endpoint is a different connection",
      {|"choice":"vllm","model":"m","max_context":8192,"tools":true,"streaming":false,"endpoint":"http://other:9/v1"|}
    ; "a different model is a different connection",
      {|"choice":"vllm","model":"m2","max_context":8192,"tools":true,"streaming":false,"endpoint":"http://h:9/v1"|}
    ; "a different window is a different connection",
      {|"choice":"vllm","model":"m","max_context":4096,"tools":true,"streaming":false,"endpoint":"http://h:9/v1"|} ]
(* Discovery lists Codex models from the declared provider's account home;
   the saved provider must keep that home or it renders the ambient
   account instead. *)
let test_codex_account_home_preserved () =
  let parse input =
    match Runtime_setup_spec.of_json (Yojson.Safe.from_string input) with
    | Ok spec -> spec | Error error -> Alcotest.fail (Runtime_setup_spec.error_message error) in
  let base = {|"choice":"codex","model":"m","max_context":1024,"tools":true,"streaming":true|} in
  let spec = parse ("{" ^ base ^ {|,"account_home":"/accounts/a"|} ^ "}") in
  let rendered = Runtime_setup_spec.render spec in
  let whole = "[runtime]\ndefault = " ^ Yojson.Safe.to_string (`String rendered.runtime_id) ^ "\n" ^ rendered.runtime_toml in
  let home = match Runtime_toml.parse_string whole with
    | Ok parsed -> (match parsed.Runtime_schema.providers with
      | [ provider ] -> provider.Runtime_schema.account_home
      | _ -> Alcotest.fail "rendered fragment declares one provider")
    | Error _ -> Alcotest.fail "rendered account-home is not native runtime TOML" in
  Alcotest.check (Alcotest.option Alcotest.string) "saved provider keeps the discovered account home"
    (Some "/accounts/a") home;
  let other = (Runtime_setup_spec.render (parse ("{" ^ base ^ {|,"account_home":"/accounts/b"|} ^ "}"))).runtime_id in
  let ambient = (Runtime_setup_spec.render (parse ("{" ^ base ^ "}"))).runtime_id in
  Alcotest.check Alcotest.bool "different account homes are different connections" true (rendered.runtime_id <> other);
  Alcotest.check Alcotest.bool "a declared home leaves the ambient identity" true (rendered.runtime_id <> ambient);
  List.iter (fun (label, input) ->
    Alcotest.check Alcotest.bool label true
      (Result.is_error (Runtime_setup_spec.of_json (Yojson.Safe.from_string input))))
    [ "a relative account home is refused",
      "{" ^ base ^ {|,"account_home":"accounts/a"|} ^ "}"
    ; "a non-Codex client cannot carry an account home",
      {|{"choice":"claude_code","model":"m","max_context":1024,"tools":true,"streaming":true,"account_home":"/accounts/a"}|}
    ; "an HTTP connection cannot carry an account home",
      {|{"choice":"messages","model":"m","max_context":1024,"tools":true,"streaming":true,"endpoint":"https://fixture.invalid","provider_kind":"anthropic","account_home":"/accounts/a"}|} ]
let () = Alcotest.run "native runtime setup spec" ["contract",[
  Alcotest.test_case "representative installer identity and TOML parity" `Quick test_existing_installer_contract;
  Alcotest.test_case "native fractional number identity" `Quick test_native_fractional_identity;
  Alcotest.test_case "typed input rejects incompatible declarations" `Quick test_rejects_invalid_transport_claims;
  Alcotest.test_case "one answer is one connection" `Quick test_one_answer_is_one_connection;
  Alcotest.test_case "codex account home survives save" `Quick test_codex_account_home_preserved]]
