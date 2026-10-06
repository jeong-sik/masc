let test_installer_declarations () =
  let specs = Yojson.Safe.from_file "fixtures/runtime-setup-specs.json" |> Yojson.Safe.Util.to_list in
  List.iter (fun json ->
    let open Yojson.Safe.Util in
    let spec = match Runtime_setup_spec.of_json json with
      | Ok spec -> spec | Error error -> Alcotest.fail (Runtime_setup_spec.error_message error) in
    let rendered = Runtime_setup_spec.render spec in
    let whole = "[runtime]\ndefault = " ^ Yojson.Safe.to_string (`String rendered.runtime_id) ^ "\n" ^ rendered.runtime_toml in
    match Runtime_toml.parse_string whole with
    | Error _ -> Alcotest.fail "rendered fragment is not native runtime TOML"
    | Ok config ->
      let model = List.hd config.Runtime_schema.models in
      let binding = List.hd config.bindings in
      Alcotest.check Alcotest.string "selected API model survives rendering"
        (json |> member "model" |> to_string) model.api_name;
      Alcotest.check (Alcotest.option Alcotest.int) "declared context survives rendering"
        (Some (json |> member "max_context" |> to_int)) model.max_context;
      Alcotest.check Alcotest.string "binding uses the account connection"
        (Runtime_setup_spec.provider_id spec) binding.provider_id;
      Alcotest.check Alcotest.string "rendered identity resolves to its binding"
        rendered.runtime_id (Runtime_schema.binding_key binding)) specs
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
let test_official_client_account_selection_is_identity () =
  let render choice home =
    let fields = ["choice", `String choice; "model", `String "fixture-model";
      "max_context", `Int 8192; "tools", `Bool true; "streaming", `Bool true]
      @ (match home with None -> [] | Some path -> ["account_home", `String path]) in
    match Runtime_setup_spec.of_json (`Assoc fields) with
    | Ok spec -> Runtime_setup_spec.render spec
    | Error error -> Alcotest.fail (Runtime_setup_spec.error_message error) in
  List.iter (fun choice ->
    let old = render choice None in
    let first = render choice (Some "/synthetic/account-a") in
    let second = render choice (Some "/synthetic/account-b") in
    Alcotest.(check bool) "selected account differs from ambient identity" false
      (String.equal old.runtime_id first.runtime_id);
    Alcotest.(check bool) "different selected accounts cannot overwrite each other" false
      (String.equal first.runtime_id second.runtime_id);
    let whole = "[runtime]\ndefault = " ^ Yojson.Safe.to_string (`String first.runtime_id)
      ^ "\n" ^ first.runtime_toml in
    match Runtime_toml.parse_string whole with
    | Error _ -> Alcotest.fail "selected account rendering must parse"
    | Ok config ->
      let provider = List.hd config.Runtime_schema.providers in
      Alcotest.(check (option string)) "account home survives rendering"
        (Some "/synthetic/account-a") provider.account_home)
    ["claude_code"; "codex"]

let test_empty_selected_account_never_becomes_ambient () =
  List.iter (fun choice ->
    let fields = ["choice", `String choice; "model", `String "fixture-model";
      "max_context", `Int 8192; "tools", `Bool true; "streaming", `Bool true;
      "account_home", `String ""] in
    Alcotest.(check bool) "explicit empty account is refused" true
      (Result.is_error (Runtime_setup_spec.of_json (`Assoc fields))))
    ["claude_code"; "codex"]

let test_muse_requires_explicit_account () =
  let fields = ["choice", `String "muse"; "model", `String "fixture-model";
    "max_context", `Int 8192; "tools", `Bool true; "streaming", `Bool true;
    "account_home", `String "/synthetic/muse-account"] in
  Alcotest.(check bool) "account_home is required" true
    (Result.is_error (Runtime_setup_spec.of_json (`Assoc (List.remove_assoc "account_home" fields))));
  let spec = match Runtime_setup_spec.of_json (`Assoc fields) with
    | Ok spec -> spec | Error error -> Alcotest.fail (Runtime_setup_spec.error_message error) in
  let rendered = Runtime_setup_spec.render spec in
  let whole = "[runtime]\ndefault = " ^ Yojson.Safe.to_string (`String rendered.runtime_id)
      ^ "\n" ^ rendered.runtime_toml in
  match Runtime_toml.parse_string whole with
  | Error _ -> Alcotest.fail "Muse setup rendering must parse"
  | Ok config ->
    let provider = List.hd config.Runtime_schema.providers in
    Alcotest.(check bool) "Muse protocol" true
      (provider.api_format = Runtime_schema.Muse_serve_runtime);
    Alcotest.(check (option string)) "selected account" (Some "/synthetic/muse-account") provider.account_home

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
    ; "an HTTP connection cannot carry an account home",
      {|{"choice":"messages","model":"m","max_context":1024,"tools":true,"streaming":true,"endpoint":"https://fixture.invalid","provider_kind":"anthropic","account_home":"/accounts/a"}|} ]
(* Human-readable prefixes keep the client and model recognizable. The
   hashes distinguish account connections and model declarations separately. *)
let test_id_names_the_client_and_the_model () =
  let render model =
    let input = Printf.sprintf
      {|{"choice":"vllm","model":%s,"max_context":8192,"tools":true,"streaming":false,"endpoint":"http://h:9/v1"}|}
      (Yojson.Safe.to_string (`String model)) in
    match Runtime_setup_spec.of_json (Yojson.Safe.from_string input) with
    | Ok spec -> Runtime_setup_spec.render spec
    | Error error -> Alcotest.fail (Runtime_setup_spec.error_message error) in
  let rendered = render "meta-llama/Llama-3.1:8b" in
  let id = rendered.runtime_id in
  let split_last sep text = match String.rindex_opt text sep with
    | Some at -> String.sub text 0 at, String.sub text (at + 1) (String.length text - at - 1)
    | None -> Alcotest.fail (Printf.sprintf "%S has no %C" text sep) in
  let provider, model_key = match String.index_opt id '.' with
    | Some at -> String.sub id 0 at, String.sub id (at + 1) (String.length id - at - 1)
    | None -> Alcotest.fail (Printf.sprintf "%S has no provider.model split" id) in
  let client, provider_hash = split_last '_' provider in
  let model, model_hash = split_last '_' model_key in
  Alcotest.check Alcotest.string "the provider names the client" "vllm" client;
  Alcotest.check Alcotest.string "the model key names the model" "meta-llama-Llama-3.1-8b" model;
  let korean = (render "gpt 모델").runtime_id in
  Alcotest.check Alcotest.string "each Hangul syllable becomes one '-'" "gpt---"
    (fst (split_last '_' (snd (split_last '.' korean))));
  Alcotest.check Alcotest.bool "a short hash follows the client" true
    (String.length provider_hash = 8
     && String.for_all (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false) provider_hash);
  Alcotest.check Alcotest.bool "a model declaration has its own identity" true
    (String.length model_hash = 8 && provider_hash <> model_hash);
  let whole = "[runtime]\ndefault = " ^ Yojson.Safe.to_string (`String id) ^ "\n" ^ rendered.runtime_toml in
  Alcotest.check Alcotest.bool "the rendered connection parses as configuration" true
    (Result.is_ok (Runtime_toml.parse_string whole))
let test_image_declaration_survives_native_save () =
  List.iter (fun declaration ->
    let fields = ["choice", `String "codex"; "model", `String "selected-model";
      "max_context", `Int 750000; "tools", `Bool true; "streaming", `Bool true]
      @ (match declaration with None -> [] | Some value -> ["supports_image_input", `Bool value]) in
    let spec = match Runtime_setup_spec.of_json (`Assoc fields) with
      | Ok spec -> spec | Error error -> Alcotest.fail (Runtime_setup_spec.error_message error) in
    let rendered = Runtime_setup_spec.render spec in
    let whole = "[runtime]\ndefault = " ^ Yojson.Safe.to_string (`String rendered.runtime_id)
      ^ "\n" ^ rendered.runtime_toml in
    match Runtime_toml.parse_string whole with
    | Error _ -> Alcotest.fail "saved native connection does not load"
    | Ok config ->
      match config.models with
      | [model] ->
        Alcotest.check (Alcotest.option Alcotest.bool) "image declaration survives save"
          declaration (Option.bind model.capabilities
            (fun caps -> caps.Runtime_schema.supports_image_input));
        Alcotest.check (Alcotest.option Alcotest.int) "context is preserved"
          (Some 750000) model.max_context
      | _ -> Alcotest.fail "expected one saved model") [None; Some false; Some true]

let test_http_request_surface () =
  let parse path =
    Runtime_setup_spec.of_json (`Assoc (["choice", `String "openai_compatible";
      "model", `String "selected-model"; "max_context", `Int 8192;
      "tools", `Bool true; "streaming", `Bool true;
      "endpoint", `String "https://fixture.invalid/v1";
      "api_key_env", `String "MASC_SETUP_TEST_KEY"]
      @ match path with None -> [] | Some path -> ["request_path", `String path])) in
  let get = function Ok value -> value | Error error -> Alcotest.fail (Runtime_setup_spec.error_message error) in
  let bare = get (parse None) in
  Alcotest.(check string) "explicit default surface retains its identity"
    (Runtime_setup_spec.provider_id bare)
    (Runtime_setup_spec.provider_id (get (parse (Some "/v1/chat/completions"))));
  List.iter (fun path ->
    let spec = get (parse (Some path)) in
    let rendered = Runtime_setup_spec.render spec in
    let config = Runtime_toml.parse_string rendered.runtime_toml |> Result.get_ok in
    let provider = List.hd config.Runtime_schema.providers in
    let kind, resolved = Runtime_adapter.http_protocol_metadata provider |> Result.get_ok in
    Alcotest.(check string) "Responses surface survives generated provider and endpoint normalization" "/responses" resolved;
    let wire = Llm_provider.Provider_config.make ~kind ~request_path:resolved
        ~model_id:"selected-model" ~base_url:"https://fixture.invalid/v1" () in
    Alcotest.(check bool) "dispatch surface selects Responses" true
      (Llm_provider.Provider_config.request_path_targets_responses_api wire.request_path);
    Alcotest.(check bool) "chat transport cannot reuse a Responses account" true
      (Option.is_none (Runtime_setup_spec.for_provider bare provider));
    Alcotest.(check bool) "matching path can reuse the saved account" true
      (Option.is_some (Runtime_setup_spec.for_provider spec provider))) ["/responses"; "/v1/responses"];
  List.iter (fun path -> Alcotest.(check bool) "unsafe surface rejected" true
    (Result.is_error (parse (Some path))))
    ["https://other.invalid/responses"; "//other.invalid/responses"; "/responses?secret=x"; "/responses#fragment"; "/bad path"]

let test_configured_account_resolution () =
  let spec = Runtime_setup_spec.of_json (`Assoc ["choice", `String "codex";
    "model", `String "new-model"; "max_context", `Int 8192;
    "tools", `Bool true; "streaming", `Bool true; "account_home", `String "/fixture/account-a"])
    |> Result.get_ok in
  let config = Runtime_toml.parse_string {|
[providers.operator_account]
protocol = "codex-app-server"
command = "codex"
account-home = "/fixture/account-a"
is-non-interactive = true
|} |> Result.get_ok in
  let provider = List.hd config.Runtime_schema.providers in
  let bound = Runtime_setup_spec.resolve_provider spec config.providers |> Result.get_ok in
  Alcotest.(check string) "new model reuses operator-owned account ID" "operator_account"
    (Runtime_setup_spec.provider_id bound);
  let exact = Runtime_setup_spec.of_json (`Assoc ["choice", `String "codex";
    "existing_provider_id", `String "operator_account"; "model", `String "new-model";
    "max_context", `Int 8192; "tools", `Bool true; "streaming", `Bool true;
    "account_home", `String "/fixture/account-a"]) |> Result.get_ok in
  let exact = Runtime_setup_spec.resolve_provider exact [provider; {provider with id="sibling"}] |> Result.get_ok in
  Alcotest.(check string) "explicit configured selection survives identical sibling accounts" "operator_account"
    (Runtime_setup_spec.provider_id exact);
  let previous = Sys.getenv_opt "CODEX_HOME" in
  Fun.protect ~finally:(fun () -> match previous with
    | Some value -> Unix.putenv "CODEX_HOME" value | None -> Unix.unsetenv "CODEX_HOME") (fun () ->
    Unix.putenv "CODEX_HOME" "/fixture/account-a";
    let ambient = {provider with account_home=None} in
    let selected = Runtime_setup_spec.resolve_provider spec [ambient] |> Result.get_ok in
    Alcotest.(check string) "explicit effective default reuses ambient configured account"
      "operator_account" (Runtime_setup_spec.provider_id selected);
    Alcotest.(check bool) "same native default is not a new disabled account" true
      (Runtime_setup_spec.account_home_matches Runtime_setup_spec.Codex None (Some "/fixture/account-a")));
  let disabled = {provider with enabled=false} in
  Alcotest.(check bool) "disabled provider is not reusable" true
    (Option.is_none (Runtime_setup_spec.for_provider spec disabled));
  Alcotest.(check bool) "disabled matching account is refused before rendering" true
    (Result.is_error (Runtime_setup_spec.resolve_provider spec [disabled]));
  Alcotest.(check bool) "stale bound identity cannot target a disabled provider" true
    (Result.is_error (Runtime_setup_spec.resolve_provider bound [disabled]));
  Alcotest.(check bool) "identical operator accounts require explicit choice" true
    (Result.is_error (Runtime_setup_spec.resolve_provider spec [provider; {provider with id="other"}]))

let test_inventory_groups_existing_account_providers () =
  let source = {|
[providers.first]
display-name = "Codex shared label"
protocol = "codex-app-server"
command = "codex"
is-non-interactive = true
account-home = "/fixture/account-one"
[providers.first_wide]
display-name = "Codex shared label"
protocol = "codex-app-server"
command = "codex"
is-non-interactive = true
account-home = "/fixture/account-one"
[providers.second]
display-name = "Codex shared label"
protocol = "codex-app-server"
command = "codex"
is-non-interactive = true
account-home = "/fixture/account-two"
[models.luna]
api-name = "gpt-6-luna"
max-context = 272000
[models.luna_wide]
api-name = "gpt-6-luna"
max-context = 500000
[first.luna]
[first_wide.luna_wide]
[second.luna]
|} in
  let config = match Runtime_toml.parse_string source with
    | Ok config -> config | Error _ -> Alcotest.fail "account grouping fixture must parse" in
  let json = Runtime_wizard_inventory.to_json config in
  let open Yojson.Safe.Util in
  let groups = json |> member "account_groups" |> to_list in
  let ids group field = group |> member field |> to_list |> List.map to_string in
  Alcotest.check (Alcotest.list (Alcotest.list Alcotest.string)) "same native scope groups only its own providers"
    [["first";"first_wide"];["second"]] (List.map (fun group -> ids group "integration_ids") groups);
  Alcotest.check (Alcotest.list (Alcotest.list Alcotest.string)) "both context variants retain their original runtime IDs"
    [["first.luna";"first_wide.luna_wide"];["second.luna"]] (List.map (fun group -> ids group "runtime_ids") groups);
  Alcotest.check Alcotest.int "public inventory retains all runtime rows" 3
    (json |> member "runtimes" |> to_list |> List.length);
  Alcotest.check (Alcotest.list Alcotest.int) "public runtime variants retain context" [272000;500000;272000]
    (json |> member "runtimes" |> to_list |> List.map (fun row -> row |> member "max_context" |> to_int));
  Alcotest.check (Alcotest.list Alcotest.string) "Setup group IDs match Runtime and persisted Usage scope IDs"
    (List.map (fun home -> Runtime_quota_window.scope_id
      (Runtime_quota_window.scope_of_codex_home (Some home)))
      ["/fixture/account-one";"/fixture/account-two"])
    (List.map (fun group -> group |> member "id" |> to_string) groups);
  Alcotest.check Alcotest.bool "public quota scope IDs expose no account home" false
    (String_util.contains_substring (Yojson.Safe.to_string (`List groups)) "/fixture/")

let test_cli_reuse_requires_non_interactive () =
  List.iter (fun (choice, fields) ->
    let json = `Assoc (["choice", `String choice; "model", `String "fixture-model";
      "max_context", `Int 8192; "tools", `Bool true; "streaming", `Bool true] @ fields) in
    let spec = Runtime_setup_spec.of_json json |> Result.get_ok in
    let rendered = Runtime_setup_spec.render spec in
    let config = Runtime_toml.parse_string rendered.runtime_toml |> Result.get_ok in
    let provider = List.hd config.Runtime_schema.providers in
    let binding = List.hd config.bindings in
    Alcotest.(check bool) (choice ^ " generated provider is executable") true
      (Result.is_ok (Runtime_adapter.binding_to_execution config binding));
    let interactive = {provider with is_non_interactive=false} in
    let interactive_config = {config with providers=[interactive]} in
    Alcotest.(check bool) (choice ^ " actual adapter refuses interactive declaration") true
      (Result.is_error (Runtime_adapter.binding_to_execution interactive_config binding));
    Alcotest.(check bool) (choice ^ " direct reuse refuses interactive declaration") true
      (Option.is_none (Runtime_setup_spec.for_provider spec interactive));
    Alcotest.(check bool) (choice ^ " implicit account resolution refuses before stage") true
      (Result.is_error (Runtime_setup_spec.resolve_provider spec [interactive]));
    let bound = Runtime_setup_spec.for_provider spec provider |> Option.get in
    Alcotest.(check bool) (choice ^ " selected identity is rechecked") true
      (Result.is_error (Runtime_setup_spec.resolve_provider bound [interactive]));
    let sibling = {provider with id="admissible_account"} in
    let selected = Runtime_setup_spec.resolve_provider spec [interactive;sibling] |> Result.get_ok in
    Alcotest.(check string) (choice ^ " alias chooses the admissible existing connection")
      sibling.id (Runtime_setup_spec.provider_id selected))
    ["codex", ["account_home", `String "/fixture/codex"];
     "claude_code", ["account_home", `String "/fixture/claude"];
     "antigravity", ["credential_file", `String "/fixture/oauth.json"; "timeout_s", `Int 60];
     "muse", ["account_home", `String "/fixture/muse"]]

let test_existing_inline_selection () =
  let parse extra = Runtime_setup_spec.of_json (`Assoc (["choice",`String "openai_compatible";
    "endpoint",`String "https://fixture.invalid/v1";"request_path",`String "/responses";
    "model",`String "fixture-model";"max_context",`Int 8192;"tools",`Bool true;"streaming",`Bool true] @ extra))
    |> Result.get_ok in
  let spec=parse [] in
  let config=Runtime_setup_spec.render spec |> fun row -> Runtime_toml.parse_string row.runtime_toml |> Result.get_ok in
  let provider={ (List.hd config.Runtime_schema.providers) with
    id="operator_account";credentials=Some (Runtime_schema.Inline "fixture-inline-secret")} in
  Alcotest.(check bool) "an ordinary anonymous spec cannot reuse inline credentials" true
    (Option.is_none (Runtime_setup_spec.for_provider spec provider));
  let bound=Runtime_setup_spec.for_existing_inline_provider spec provider |> Option.get in
  let rechecked=Runtime_setup_spec.resolve_provider bound [provider;{provider with id="same-secret-sibling"}] |> Result.get_ok in
  Alcotest.(check string) "explicit inline selection survives locked account resolution"
    provider.id (Runtime_setup_spec.provider_id rechecked);
  List.iter (fun changed -> Alcotest.(check bool) "locked selection refuses changed credential or connection" true
    (Result.is_error (Runtime_setup_spec.resolve_provider bound [changed])))
    [{provider with credentials=Some (Runtime_schema.Inline "replacement")};
     {provider with credentials=Some (Runtime_schema.File "/fixture/arbitrary-carrier")};
     {provider with enabled=false};{provider with request_path=Some "/chat/completions"}];
  List.iter (fun fields -> Alcotest.(check bool) "replacement references cannot claim inline provenance" true
    (Option.is_none (Runtime_setup_spec.for_existing_inline_provider (parse fields) provider)))
    [["credential_file",`String "/fixture/arbitrary-carrier"];["api_key_env",`String "NEW_API_KEY"];
     ["existing_provider_id",`String "some-other-provider"]];
  let rendered=Runtime_setup_spec.render bound in
  let parsed=Otoml.Parser.from_string_result rendered.runtime_toml |> Result.get_ok in
  Alcotest.(check bool) "inline rendering never rewrites the configured provider" true
    (Otoml.find_opt parsed Otoml.get_table ["providers"]=None);
  Alcotest.(check bool) "inline secret never enters rendered fragments" false
    (String_util.contains_substring rendered.runtime_toml "fixture-inline-secret");
  let repeated=Runtime_setup_spec.for_existing_inline_provider (parse []) provider |> Option.get |> Runtime_setup_spec.render in
  Alcotest.(check string) "repeated explicit selection has stable runtime identity" rendered.runtime_id repeated.runtime_id

let test_antigravity_inventory_keeps_declared_timeout () =
  let config = Runtime_toml.parse_string {|
[providers.saved]
protocol = "antigravity-cli"
command = "agy"
is-non-interactive = true
timeout-s = 824.5
[providers.saved.credentials]
type = "file"
path = "/fixture/oauth"
[models.existing]
api-name = "existing"
max-context = 8192
[saved.existing]
|} |> Result.get_ok in
  let open Yojson.Safe.Util in
  let inventory = Runtime_wizard_inventory.to_json ~include_credential_references:true config in
  let provider = inventory |> member "integrations" |> to_list
    |> List.find (fun row -> (row |> member "id") = `String "saved") in
  let runtime = inventory |> member "runtimes" |> to_list |> List.hd in
  List.iter (fun row -> Alcotest.(check (float 0.)) "declared transport timeout is projected" 824.5
    (row |> member "provider_timeout_s" |> to_float)) [provider; runtime]

let () = Alcotest.run "native runtime setup spec" ["contract",[
  Alcotest.test_case "existing inline account selection is revalidated without exporting secrets" `Quick test_existing_inline_selection;
  Alcotest.test_case "Antigravity inventory preserves declared timeout" `Quick test_antigravity_inventory_keeps_declared_timeout;
  Alcotest.test_case "CLI reuse follows actual execution eligibility" `Quick test_cli_reuse_requires_non_interactive;
  Alcotest.test_case "HTTP request surface survives setup" `Quick test_http_request_surface;
  Alcotest.test_case "existing and disabled account identity" `Quick test_configured_account_resolution;
  Alcotest.test_case "inventory groups existing account providers without renaming" `Quick test_inventory_groups_existing_account_providers;
  Alcotest.test_case "image declaration survives native save" `Quick test_image_declaration_survives_native_save;
  Alcotest.test_case "installer declarations survive rendering" `Quick test_installer_declarations;
  Alcotest.test_case "native fractional number identity" `Quick test_native_fractional_identity;
  Alcotest.test_case "typed input rejects incompatible declarations" `Quick test_rejects_invalid_transport_claims;
  Alcotest.test_case "one answer is one connection" `Quick test_one_answer_is_one_connection;
  Alcotest.test_case "the id names the client and the model" `Quick test_id_names_the_client_and_the_model;
  Alcotest.test_case "selected official accounts remain distinct" `Quick test_official_client_account_selection_is_identity;
  Alcotest.test_case "empty selected account does not inherit" `Quick test_empty_selected_account_never_becomes_ambient;
  Alcotest.test_case "Muse account is explicit and asks no byte budget" `Quick test_muse_requires_explicit_account;
  Alcotest.test_case "codex account home survives save" `Quick test_codex_account_home_preserved]]
