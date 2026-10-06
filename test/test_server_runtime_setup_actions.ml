module Actions = Server_runtime_setup_actions
let save path text = Out_channel.with_open_bin path (fun channel -> output_string channel text)
let get = function Ok value -> value | Error e -> Alcotest.fail (Actions.error_message e)
let fixture test = Eio_main.run (fun env -> Eio.Switch.run (fun sw ->
  let base=Filename.temp_dir "masc-web-setup-test-" "" |> Unix.realpath in
  let previous=Sys.getenv_opt "XDG_CONFIG_HOME" in
  Unix.putenv "XDG_CONFIG_HOME" base;
  Eio.Switch.on_release sw (fun () -> Unix.putenv "XDG_CONFIG_HOME" (Option.value previous ~default:""); Fs_compat.remove_tree base);
  let masc=Common.masc_dir_from_base_path ~base_path:base in Unix.mkdir masc 0o700;
  let config=Filename.concat masc "config" in Unix.mkdir config 0o700;
  let runtime=Filename.concat config "runtime.toml" in
  let spec=Runtime_setup_spec.of_json (`Assoc ["choice",`String "codex";"model",`String "old";
    "max_context",`Int 1024;"tools",`Bool true;"streaming",`Bool true]) |> Result.get_ok in
  let rendered=Runtime_setup_spec.render spec in
  save runtime ("[runtime]\ndefault = " ^ Yojson.Safe.to_string (`String rendered.runtime_id) ^ "\n" ^ rendered.runtime_toml);
  let python=match Process_eio.run_argv_with_status_split_or_refusal ["python3";"-c";"import sys;print(sys.executable)"] with
    | Ok (Unix.WEXITED 0,s,_) -> String.trim s | _ -> Alcotest.fail "Python fixture unavailable" in
  let binary=Filename.concat base "native-fixture" in
  save binary ("#!" ^ python ^ {|
import json,sys,os,tomllib
args=sys.argv[1:]
if args[0]=='runtime-antigravity-account':
    assert args[1]=='--base-path' and args[3:]==['--cli-path','agy']
    assert os.path.isdir(os.path.join(args[2],'.masc'))
    assert os.stat(os.path.join(args[2],'.masc')).st_mode & 0o777 == 0o700
    credential=os.path.join(args[2],'fixture-account.json')
    with open(credential,'w') as f: f.write('fixture-imported-account')
    os.chmod(credential,0o600)
    print(json.dumps({'schema':'masc.antigravity_account.v1','credential_file':credential,
      'provider_timeout_s':123.5,'invocation_verified':False,
      'catalog':{'models':[{'id':'fresh-antigravity','label':'Fresh account model','context':None}]}}))
    sys.exit(0)
if args[0]=='runtime-muse-models':
    assert args[1:3] == ['--cli-path','muse'] and args[3] == '--account-home'
    catalog_file=os.path.join(args[4],'fixture-muse-catalog.json')
    if os.path.exists(catalog_file):
        with open(catalog_file) as f: models=json.load(f)
    else: models=[{'id':'reported-muse','label':'Reported Muse','context':32768}]
    print(json.dumps({'schema':'masc.muse_models.v1','source':'providerCatalog',
      'invocation_verified':False,'account_availability_verified':False,
      'models':models}))
    sys.exit(0)
if args[0]=='runtime-model-list':
    assert args[1] in ('codex','claude-code') and len(args)==2
    catalog_file=os.path.join(os.path.dirname(__file__),'fixture-native-catalog.json')
    if os.path.exists(catalog_file):
        with open(catalog_file) as f: models=json.load(f)
    else: models=[{'id':'fresh-model','max_context':272000,'supports_image_input':True}]
    print(json.dumps({'models':models}))
    sys.exit(0)
if args[0]=='runtime-codex-models':
    with open(os.path.join(os.path.dirname(__file__),'codex-args.json'),'w') as f:
        json.dump(args,f)
    catalog_file=os.path.join(os.path.dirname(__file__),'fixture-codex-catalog.json')
    if os.path.exists(catalog_file):
        with open(catalog_file) as f: models=json.load(f)
    else: models=[
      {'id':'fresh-model','label':'Fresh model','context':272000,
       'supported_reasoning_efforts':['low','high','ultra','adaptive-v2'],'default_reasoning_effort':'high'},
      {'id':'second-model','label':'Second model','context':272000,
       'supported_reasoning_efforts':[],'default_reasoning_effort':'native-auto'},
      {'id':'other-model','label':'Other account model','context':272000}]
    print(json.dumps({'schema':'masc.codex_model_refresh.v1','models':models,
      'credential_file':'/private/not-for-browser'}))
    sys.exit(0)
assert args[1]=='--base-path'
with open(os.path.join(os.path.dirname(__file__),'save-calls'),'a') as f:
    f.write(args[0]+'\n')
if args[0]=='runtime-default-set':
    if len(args)>4: assert args[4:6]==['--setup-lanes','--setup-imp']
    elif args[3]!='conversation': raise AssertionError(args)
elif args[0]=='runtime-verify':
    with open(os.path.join(args[2],'.masc','config','runtime.toml'),'rb') as f:
        staged=tomllib.load(f)
    provider_id,model_key=args[3].split('.',1)
    provider=staged['providers'][provider_id]
    with open(os.path.join(os.path.dirname(__file__),'verified-provider.json'),'w') as f:
        json.dump({'runtime_id':args[3],'command':provider.get('command'),
          'account_home':provider.get('account-home'),
          'model':staged['models'][model_key]['api-name']},f)
    # The shape Runtime_verification.to_json writes; of_json refuses any other key set.
    print(json.dumps({'schema':'masc.runtime_verification.v1','runtime_id':args[3],'model':'fixture-model',
      'observed_model':'fixture-model','status':'verified',
      'checks':{'response':True,'tool_called':True,'tool_roundtrip':True},'failure':None}))
else: raise AssertionError(args)
|}); Unix.chmod binary 0o700;
  test base runtime binary (Eio.Stdenv.net env)))
let request ?(context=1024) base source =
  let revision=Runtime_setup_batch.observe ~base_path:base |> Result.get_ok |> Runtime_setup_batch.revision_to_string in
  `Assoc ["revision",`String revision;
    "connections",`List [`Assoc ["source",source;"models",`List [
      `Assoc ["id",`String "selected-model";"context",`Int context;"streaming",`Bool true]]]];
    "selection",`List [`Assoc ["connection",`Int 0;"model",`Int 0]]]
let source fields = `Assoc (["integration_id",`String "vllm";"endpoint",`String "http://127.0.0.1:19001/v1"] @ fields)
let test_private_key () = fixture (fun base runtime binary _net ->
  let receipt=get (Actions.save ~binary ~base_path:base (request base (source ["api_key",`String "fixture-secret-key"]))) in
  let config=Runtime_toml.parse_file runtime |> Result.get_ok in
  let paths=List.filter_map (fun (p:Runtime_schema.provider) -> match p.credentials with
    | Some (Runtime_schema.File path) -> Some path | _ -> None) config.providers in
  Alcotest.check Alcotest.int "one committed private key" 1 (List.length paths);
  let key_path=List.hd paths in
  Alcotest.check Alcotest.int "key remains private after request cleanup" 0o600 (Unix.stat key_path).st_perm;
  Alcotest.check Alcotest.string "key material correct" "fixture-secret-key" (In_channel.with_open_bin key_path In_channel.input_all);
  let open Yojson.Safe.Util in
  Alcotest.check Alcotest.string "response/tool verified scope" "verified" (receipt |> member "readiness" |> to_string);
  let keys=receipt |> to_assoc |> List.map fst |> List.sort String.compare in
  Alcotest.check (Alcotest.list Alcotest.string) "safe receipt fields only"
    (List.sort String.compare ["runtime_id";"runtime_ids";"models";"configured";"validation";"readiness";"commit"]) keys;
  let commit = receipt |> member "commit" in
  Alcotest.check (Alcotest.list Alcotest.string) "commit omits private source and storage details"
    ["durability";"order";"source_revision";"warnings"]
    (commit |> to_assoc |> List.map fst |> List.sort String.compare);
  Alcotest.check Alcotest.bool "private credential reference stays out of receipt" false
    (String_util.contains_substring (Yojson.Safe.to_string receipt) key_path))
let test_forbidden_reference () = fixture (fun base runtime binary _net ->
  let before=In_channel.with_open_bin runtime In_channel.input_all in
  List.iter (fun fields ->
    Alcotest.check Alcotest.bool "browser cannot supply private files or commands" true
      (Actions.save ~binary ~base_path:base (request base (source fields)) = Error Actions.Invalid_request))
    [["account_home",`String "/private/home"];["credential_file",`String "/private/credential"];["command",`String "/untrusted/program"]];
  Alcotest.check Alcotest.string "invalid request preserves configuration" before (In_channel.with_open_bin runtime In_channel.input_all))
let test_existing_http_context_variant () = fixture (fun base runtime binary _net ->
  let initial = get (Actions.save ~binary ~base_path:base
    (request base (source ["api_key", `String "fixture-key"]))) in
  let open Yojson.Safe.Util in
  let initial_id = initial |> member "runtime_id" |> to_string in
  let before = Runtime_toml.parse_file runtime |> Result.get_ok in
  let first_binding = List.find (fun binding -> Runtime_schema.binding_key binding=initial_id) before.bindings in
  let provider_id = first_binding.provider_id in
  let receipt = get (Actions.save ~binary ~base_path:base
    (request ~context:2048 base (`Assoc ["integration_id", `String provider_id]))) in
  let added_id = receipt |> member "runtime_id" |> to_string in
  let after = Runtime_toml.parse_file runtime |> Result.get_ok in
  let added = List.find (fun binding -> Runtime_schema.binding_key binding=added_id) after.bindings in
  Alcotest.check Alcotest.string "HTTP variant uses the selected provider" provider_id added.provider_id;
  Alcotest.check Alcotest.int "HTTP provider is not duplicated on a later save"
    (List.length before.providers) (List.length after.providers);
  Alcotest.check (Alcotest.option Alcotest.int) "HTTP variant preserves its context window"
    (Some 2048) added.max_context;
  Alcotest.check Alcotest.bool "both context variants remain available" true
    (initial_id<>added_id && List.exists (fun binding -> Runtime_schema.binding_key binding=initial_id) after.bindings))
let test_existing_inline_http_account () = fixture (fun base runtime binary _net ->
  let inline_provider = {|
[providers.operator_account]
display-name = "Operator account"
protocol = "openai-compatible-http"
kind = "openai_compat"
endpoint = "http://127.0.0.1:19001/v1"
request-path = "/responses"
connect-timeout-s = 37.0
exact-body-timeout-s = 89.0
[providers.operator_account.credentials]
type = "inline"
value = "fixture-inline-secret"
|} in
  Out_channel.with_open_gen [Open_append;Open_binary] 0o600 runtime (fun channel -> output_string channel inline_provider);
  let original=Runtime_toml.parse_file runtime |> Result.get_ok in
  let original_provider=List.find (fun (p:Runtime_schema.provider) -> p.id="operator_account") original.providers in
  let selected=`Assoc ["integration_id",`String original_provider.id] in
  let add context = get (Actions.save ~binary ~base_path:base (request ~context base selected)) in
  let first=add 2048 in
  let repeated=add 2048 in
  let second=add 4096 in
  let open Yojson.Safe.Util in
  let id receipt=receipt |> member "runtime_id" |> to_string in
  Alcotest.check Alcotest.string "same inline model/context saves are idempotent" (id first) (id repeated);
  let after=Runtime_toml.parse_file runtime |> Result.get_ok in
  Alcotest.check Alcotest.int "inline variants add no providers" (List.length original.providers) (List.length after.providers);
  Alcotest.check Alcotest.bool "original credential, request surface and operator timeouts stay intact" true
    (List.find (fun (p:Runtime_schema.provider) -> p.id=original_provider.id) after.providers=original_provider);
  List.iter (fun receipt ->
    let binding=List.find (fun binding -> Runtime_schema.binding_key binding=id receipt) after.bindings in
    Alcotest.check Alcotest.string "inline variants retain the chosen account" original_provider.id binding.provider_id;
    Alcotest.check Alcotest.bool "receipt never exposes inline secret" false
      (String_util.contains_substring (Yojson.Safe.to_string receipt) "fixture-inline-secret")) [first;second];
  Alcotest.check Alcotest.int "existing-inline save adds no file credential providers" 0
    (List.length (List.filter_map (fun (p:Runtime_schema.provider) -> match p.credentials with Some (Runtime_schema.File p) -> Some p | _ -> None) after.providers));
  let replacement=get (Actions.save ~binary ~base_path:base (request ~context:8192 base
    (`Assoc ["integration_id",`String original_provider.id;"api_key",`String "new-account-key"]))) in
  let changed=Runtime_toml.parse_file runtime |> Result.get_ok in
  let new_binding=List.find (fun binding -> Runtime_schema.binding_key binding=id replacement) changed.bindings in
  Alcotest.check Alcotest.bool "explicit replacement key selects a separate account" true (new_binding.provider_id<>original_provider.id);
  Alcotest.check Alcotest.bool "new key does not replace original inline account settings" true
    (List.find (fun (p:Runtime_schema.provider) -> p.id=original_provider.id) changed.providers=original_provider);
  let new_provider=List.find (fun (p:Runtime_schema.provider) -> p.id=new_binding.provider_id) changed.providers in
  match new_provider.credentials with
  | Some (Runtime_schema.File path) -> Alcotest.check Alcotest.string "new account owns its new key" "new-account-key" (In_channel.with_open_bin path In_channel.input_all)
  | _ -> Alcotest.fail "new key must keep its separate private file")
let test_native_client_metadata () = fixture (fun base _runtime binary net ->
  Eio.Switch.run (fun sw ->
    let json=get (Actions.discover ~binary ~sw ~net ~base_path:base (`Assoc ["integration_id",`String "codex"])) in
    let open Yojson.Safe.Util in
    Alcotest.check Alcotest.string "native selected-account model source" "codex_isolated_account_model_list"
      (json |> member "source" |> to_string);
    Alcotest.check Alcotest.bool "metadata does not claim account invocation verification" false
      (json |> member "account_availability_verified" |> to_bool);
    let model=json |> member "models" |> to_list |> List.hd in
    Alcotest.check Alcotest.bool "exact catalog image support joins CLI metadata" true
      (model |> member "supports_image_input" |> to_bool);
    Alcotest.check Alcotest.int "fresh client context retained" 272000 (model |> member "context" |> to_int);
    Alcotest.check (Alcotest.list Alcotest.string) "reported effort vocabulary retained without clamping"
      ["low";"high";"ultra";"adaptive-v2"]
      (model |> member "supported_reasoning_efforts" |> to_list |> List.map to_string);
    Alcotest.check Alcotest.string "reported default effort retained" "high"
      (model |> member "default_reasoning_effort" |> to_string);
    let second=json |> member "models" |> to_list |> List.tl |> List.hd in
    Alcotest.check Alcotest.bool "uncatalogued model image support stays unknown" true
      (second |> member "supports_image_input" = `Null);
    Alcotest.check Alcotest.bool "empty supported effort list is valid" true
      (second |> member "supported_reasoning_efforts" = `List []);
    Alcotest.check Alcotest.string "default need not occur in the supported list" "native-auto"
      (second |> member "default_reasoning_effort" |> to_string);
    Alcotest.check Alcotest.bool "child private field not projected" true (json |> member "credential_file" = `Null)))
let test_malformed_client_reasoning_efforts () = fixture (fun base runtime binary net ->
  let before=In_channel.with_open_bin runtime In_channel.input_all in
  let supported value="supported_reasoning_efforts",value in
  let default value="default_reasoning_effort",value in
  let valid_supported=supported (`List [`String "ultra"]) in
  let valid_default=default (`String "ultra") in
  Eio.Switch.run (fun sw ->
    List.iter (fun metadata ->
      save (Filename.concat base "fixture-codex-catalog.json")
        (Yojson.Safe.to_string (`List [`Assoc (["id",`String "fresh";"context",`Int 272000] @ metadata)]));
      Alcotest.check Alcotest.bool "malformed advertised effort metadata is refused" true
        (Actions.discover ~binary ~sw ~net ~base_path:base (`Assoc ["integration_id",`String "codex"])
         = Error Actions.Unsupported_connection))
      [ [valid_supported];[valid_default];[supported `Null;valid_default]
      ; [supported (`String "ultra");valid_default];[supported (`List [`Int 1]);valid_default]
      ; [supported (`List [`String ""]);valid_default]
      ; [supported (`List [`String "ultra";`String "ultra"]);valid_default]
      ; [valid_supported;default `Null];[valid_supported;default (`String "")] ]);
  Alcotest.check Alcotest.string "failed discovery leaves the runtime source untouched" before
    (In_channel.with_open_bin runtime In_channel.input_all))
let test_configured_codex_account_save () = fixture (fun base runtime binary net ->
  let account_home = Filename.concat base "private-selected-codex" ^ "/" in
  Unix.mkdir account_home 0o700;
  Out_channel.with_open_gen [Open_append;Open_binary] 0o600 runtime (fun channel ->
    output_string channel (Printf.sprintf
      "\n[providers.private_codex]\ndisplay-name = \"My Codex account\"\nprotocol = \"codex-app-server\"\ncommand = \"selected-codex\"\nis-non-interactive = true\nmax-context = 4096\naccount-home = %S\n"
      account_home));
  let config = Runtime_toml.parse_file runtime |> Result.get_ok in
  let public = Runtime_wizard_inventory.to_json config in
  let private_inventory = Runtime_wizard_inventory.to_json ~include_credential_references:true config in
  let private_row = Yojson.Safe.Util.(private_inventory |> member "integrations" |> to_list)
    |> List.find (fun row -> Yojson.Safe.Util.(row |> member "id" |> to_string) = "private_codex") in
  Alcotest.check Alcotest.string "private terminal inventory retains selected account" account_home
    Yojson.Safe.Util.(private_row |> member "account_home" |> to_string);
  Alcotest.check Alcotest.bool "public inventory keeps the account path private" false
    (String_util.contains_substring (Yojson.Safe.to_string public) account_home);
  Eio.Switch.run (fun sw ->
    let selected_source = `Assoc ["integration_id",`String "private_codex"] in
    let result = get (Actions.discover ~binary ~sw ~net ~base_path:base selected_source) in
    let args = Yojson.Safe.from_file (Filename.concat base "codex-args.json")
      |> Yojson.Safe.Util.to_list |> List.map Yojson.Safe.Util.to_string in
    Alcotest.check (Alcotest.list Alcotest.string) "configured selected account reaches native discovery"
      ["runtime-codex-models";"--cli-path";"selected-codex";"--account-home";account_home] args;
    Alcotest.check Alcotest.bool "discovery response does not leak the selected path" false
      (String_util.contains_substring (Yojson.Safe.to_string result) account_home);
    Alcotest.check Alcotest.bool "browser cannot override the configured home" true
      (Actions.discover ~binary ~sw ~net ~base_path:base
        (`Assoc ["integration_id",`String "private_codex";"account_home",`String "/untrusted"])
       = Error Actions.Invalid_request);
    let open Yojson.Safe.Util in
    let fresh_model = result |> member "models" |> to_list |> List.hd in
    let model_id = fresh_model |> member "id" |> to_string in
    let revision = Runtime_setup_batch.observe ~base_path:base |> Result.get_ok
      |> Runtime_setup_batch.revision_to_string in
    let receipt = get (Actions.save ~binary ~base_path:base (`Assoc [
      "revision",`String revision;
      "connections",`List [`Assoc ["source",selected_source;"models",`List [`Assoc [
        "id",`String model_id;"context",fresh_model |> member "context";"streaming",`Bool true]]]];
      "selection",`List [`Assoc ["connection",`Int 0;"model",`Int 0]]])) in
    let runtime_id = receipt |> member "runtime_id" |> to_string in
    let verified = Yojson.Safe.from_file (Filename.concat base "verified-provider.json") in
    Alcotest.check Alcotest.string "new selected runtime reaches staged verification"
      runtime_id (verified |> member "runtime_id" |> to_string);
    Alcotest.check Alcotest.string "verification uses the discovered model"
      model_id (verified |> member "model" |> to_string);
    Alcotest.check Alcotest.string "verification keeps the selected command"
      "selected-codex" (verified |> member "command" |> to_string);
    Alcotest.check Alcotest.string "verification keeps the exact configured account home"
      account_home (verified |> member "account_home" |> to_string);
    let saved = Runtime_toml.parse_file runtime |> Result.get_ok in
    let binding = List.find (fun binding -> Runtime_instance.id_of_binding binding = runtime_id) saved.bindings in
    let provider = List.find (fun (provider:Runtime_schema.provider) -> provider.id = binding.provider_id) saved.providers in
    Alcotest.check Alcotest.string "new model remains on the selected configured provider"
      "private_codex" provider.id;
    Alcotest.check Alcotest.string "configured account display name is preserved"
      "My Codex account" provider.display_name;
    Alcotest.check (Alcotest.option Alcotest.int) "variant context overrides the provider default"
      (Some 272000) binding.max_context;
    Alcotest.check (Alcotest.option Alcotest.string) "saved provider retains that same account"
      (Some account_home) provider.account_home;
    Alcotest.check Alcotest.bool "save receipt keeps the account path private" false
      (String_util.contains_substring (Yojson.Safe.to_string receipt) account_home);
    let new_home = Filename.concat base "new-codex-account" in
    Unix.mkdir new_home 0o700;
    let reference = Runtime_setup_accounts.register_home ~workspace:base
        ~integration_id:"private_codex" ~cli_path:"selected-codex" ~account_home:new_home
      |> Result.get_ok |> Runtime_setup_accounts.reference_to_string in
    let changed = get (Actions.save ~binary ~base_path:base (request base
      (`Assoc ["integration_id", `String "private_codex"; "account_ref", `String reference]))) in
    let changed_id = changed |> member "runtime_id" |> to_string in
    let after = Runtime_toml.parse_file runtime |> Result.get_ok in
    let added_binding = List.find (fun binding -> Runtime_instance.id_of_binding binding=changed_id) after.bindings in
    Alcotest.check Alcotest.bool "a new account cannot overwrite the selected provider" true
      (added_binding.provider_id<>"private_codex");
    let retained = List.find (fun (provider:Runtime_schema.provider) -> provider.id="private_codex") after.providers in
    Alcotest.check (Alcotest.option Alcotest.string) "the previous account home remains unchanged"
      (Some account_home) retained.account_home))
let test_disabled_provider_refused () = fixture (fun base runtime binary net ->
  Out_channel.with_open_gen [Open_append;Open_binary] 0o600 runtime (fun out ->
    output_string out {|
[providers.disabled_account]
protocol = "codex-app-server"
command = "codex"
is-non-interactive = true
enabled = false
|});
  let before = In_channel.with_open_bin runtime In_channel.input_all in
  let source = `Assoc ["integration_id", `String "disabled_account"] in
  Eio.Switch.run (fun sw ->
    Alcotest.(check bool) "disabled account discovery refuses" true
      (Actions.discover ~binary ~sw ~net ~base_path:base source = Error Actions.Disabled_connection));
  Alcotest.(check bool) "disabled account save refuses" true
    (Actions.save ~binary ~base_path:base (request base source) = Error Actions.Disabled_connection);
  Alcotest.(check string) "no silent enable or new provider" before
    (In_channel.with_open_bin runtime In_channel.input_all);
  let current_home = Filename.concat base "current-account-home" in
  Unix.mkdir current_home 0o700;
  let current_ref = Runtime_setup_accounts.register_home ~workspace:base
      ~integration_id:"disabled_account" ~cli_path:"codex" ~account_home:current_home
    |> Result.get_ok |> Runtime_setup_accounts.reference_to_string in
  let previous = Sys.getenv_opt "CODEX_HOME" in
  Fun.protect ~finally:(fun () -> match previous with
    | Some value -> Unix.putenv "CODEX_HOME" value | None -> Unix.unsetenv "CODEX_HOME") (fun () ->
    Unix.putenv "CODEX_HOME" current_home;
    Alcotest.(check bool) "explicit reference to disabled effective default remains refused" true
      (Actions.save ~binary ~base_path:base (request base (`Assoc [
        "integration_id", `String "disabled_account"; "account_ref", `String current_ref]))
       = Error Actions.Disabled_connection));
  let new_home = Filename.concat base "new-account-home" in
  Unix.mkdir new_home 0o700;
  let account_ref = Runtime_setup_accounts.register_home ~workspace:base
      ~integration_id:"disabled_account" ~cli_path:"codex" ~account_home:new_home
    |> Result.get_ok |> Runtime_setup_accounts.reference_to_string in
  ignore (get (Actions.save ~binary ~base_path:base (request base (`Assoc [
    "integration_id", `String "disabled_account"; "account_ref", `String account_ref]))));
  let after = Runtime_toml.parse_file runtime |> Result.get_ok in
  let retained = Runtime_schema.provider_of_id after "disabled_account" |> Option.get in
  Alcotest.(check bool) "new login never enables its disabled template" false retained.enabled;
  Alcotest.(check bool) "new login has a separate enabled account provider" true
    (List.exists (fun (provider:Runtime_schema.provider) ->
      provider.id<>retained.id && provider.enabled && provider.account_home=Some new_home) after.providers))

let test_catalog_responses_save () = fixture (fun base runtime binary _net ->
  List.iter (fun id ->
    let selected = `Assoc ["integration_id", `String id; "api_key", `String "fixture-private-key"] in
    let receipt = get (Actions.save ~binary ~base_path:base (request base selected)) in
    let runtime_id = Yojson.Safe.Util.(receipt |> member "runtime_id" |> to_string) in
    let config = Runtime_toml.parse_file runtime |> Result.get_ok in
    let binding = List.find (fun binding -> Runtime_schema.binding_key binding=runtime_id) config.bindings in
    let provider = Runtime_schema.provider_of_id config binding.provider_id |> Option.get in
    let _, actual = Runtime_adapter.http_protocol_metadata provider |> Result.get_ok in
    let inventory = Runtime_wizard_inventory.to_json config in
    let catalog = Yojson.Safe.Util.(inventory |> member "integrations" |> to_list)
      |> List.find (fun row -> Yojson.Safe.Util.(row |> member "id" |> to_string)=id) in
    let expected = Yojson.Safe.Util.(catalog |> member "request_path" |> to_string) in
    let endpoint = match provider.transport with Runtime_schema.Http endpoint -> endpoint | Cli _ -> Alcotest.fail "HTTP expected" in
    Alcotest.(check string) "catalog request surface survives generated account"
      (Runtime_adapter.normalize_http_request_path ~kind:Runtime_schema.OpenAI_compat ~base_url:endpoint ~request_path:expected) actual;
    Alcotest.(check bool) "Responses dispatch remains selected" true
      (Llm_provider.Provider_config.request_path_targets_responses_api actual);
    let same = `Assoc ["integration_id", `String provider.id] in
    ignore (get (Actions.save ~binary ~base_path:base (request ~context:16384 base same)));
    let after = Runtime_toml.parse_file runtime |> Result.get_ok in
    Alcotest.(check int) "next variant retains the catalog-derived account" 2
      (List.length (List.filter (fun (b:Runtime_schema.binding) -> b.provider_id=provider.id) after.bindings)))
    ["openai-responses"; "deepseek-responses"])

let test_alias_reuses_operator_account () = fixture (fun base runtime binary net ->
  let home = Filename.concat base "alias-selected-account" in
  Unix.mkdir home 0o700;
  Out_channel.with_open_gen [Open_append;Open_binary] 0o600 runtime (fun out ->
    output_string out (Printf.sprintf {|
[providers.operator_codex]
protocol = "codex-app-server"
command = "codex"
is-non-interactive = true
account-home = %S
[models.already_bound]
api-name = "fresh-model"
max-context = 272000
tools-support = true
[operator_codex.already_bound]
|} home));
  let reference = Runtime_setup_accounts.register_home ~workspace:base
      ~integration_id:"codex" ~cli_path:"codex" ~account_home:home
    |> Result.get_ok |> Runtime_setup_accounts.reference_to_string in
  let source = `Assoc ["integration_id", `String "codex"; "account_ref", `String reference] in
  Eio.Switch.run (fun sw ->
    let models = get (Actions.discover ~binary ~sw ~net ~base_path:base source)
      |> Yojson.Safe.Util.member "models" |> Yojson.Safe.Util.to_list in
    let bound = List.find (fun row -> Yojson.Safe.Util.(row |> member "id" |> to_string)="fresh-model") models in
    Alcotest.(check bool) "product alias sees configured account's bound models" true
      Yojson.Safe.Util.(bound |> member "bound" |> to_bool));
  let before = Runtime_toml.parse_file runtime |> Result.get_ok in
  let receipt = get (Actions.save ~binary ~base_path:base (request base source)) in
  let id = Yojson.Safe.Util.(receipt |> member "runtime_id" |> to_string) in
  let after = Runtime_toml.parse_file runtime |> Result.get_ok in
  let binding = List.find (fun binding -> Runtime_schema.binding_key binding=id) after.bindings in
  Alcotest.(check string) "alias save retains configured provider ID" "operator_codex" binding.provider_id;
  Alcotest.(check int) "alias adds no duplicate provider" (List.length before.providers) (List.length after.providers))

let test_configured_muse_readiness_inventory () = fixture (fun _base runtime _binary _net ->
  Out_channel.with_open_gen [Open_append;Open_binary] 0o600 runtime (fun channel ->
    output_string channel {|
[providers.ready_muse]
protocol = "muse-serve"
command = "muse"
account-home = "/synthetic-selected-muse"
is-non-interactive = true
[models.ready_muse]
api-name = "fixture-muse"
max-context = 200000
max-prompt-bytes = 8192
tools-support = true
[ready_muse.ready_muse]
|});
  let config = Runtime_toml.parse_file runtime |> Result.get_ok in
  let open Yojson.Safe.Util in
  let integration = Runtime_wizard_inventory.to_json config |> member "integrations" |> to_list
    |> List.find (fun row -> row |> member "id" = `String "ready_muse") in
  Alcotest.check Alcotest.string "configured Muse can verify response and tool"
    "response_tool" (integration |> member "verification_support" |> to_string);
  Alcotest.check Alcotest.string "configured Muse supports setup as well as readiness"
    "existing_binding" (integration |> member "setup_support" |> to_string);
  Alcotest.check (Alcotest.list Alcotest.string) "readiness names the configured binding"
    ["ready_muse.ready_muse"]
    (integration |> member "configured_runtime_ids" |> to_list |> List.map to_string);
  Alcotest.check Alcotest.bool "inventory does not claim authenticated availability" false
    (integration |> member "account_availability_verified" |> to_bool))
let test_account_reference () = fixture (fun base _runtime binary _net ->
  let receipt=get (Actions.import_account ~binary ~base_path:base (`Assoc ["integration_id",`String "antigravity"])) in
  let open Yojson.Safe.Util in
  let reference=receipt |> member "account_ref" |> to_string in
  Alcotest.check Alcotest.bool "opaque account identity" true (Auth.is_generated_token_shape reference);
  Alcotest.check Alcotest.bool "import is not invocation verification" false (receipt |> member "invocation_verified" |> to_bool);
  let model=receipt |> member "catalog" |> member "models" |> to_list |> List.hd in
  Alcotest.check Alcotest.bool "other providers receive no invented Codex effort metadata" true
    ((model |> member "supported_reasoning_efforts") = `Null
     && (model |> member "default_reasoning_effort") = `Null);
  Alcotest.check (Alcotest.list Alcotest.string) "safe import response only"
    (List.sort String.compare ["schema";"account_ref";"account_imported";"invocation_verified";"catalog"])
    (receipt |> to_assoc |> List.map fst |> List.sort String.compare);
  let selected=`Assoc ["integration_id",`String "antigravity";"account_ref",`String reference] in
  ignore (get (Actions.save ~binary ~base_path:base (request base selected)));
  Alcotest.check Alcotest.bool "browser cannot replace account source path" true
    (Actions.import_account ~binary ~base_path:base (`Assoc ["integration_id",`String "antigravity";"credential_file",`String "/private/source"])
      = Error Actions.Invalid_request))
(* Proves the connection kind comes from the declared provider's typed
   api_format and transport, not from a protocol string table: a Gemini
   provider is refused by the exhaustive api_format arm and a Messages
   provider over a CLI transport by the transport arm, before any child
   process or network request. A new api_format constructor breaks the
   compile of [choice_of_api_format] instead of falling into a wildcard. *)
let test_declared_provider_variants () = fixture (fun base runtime binary net ->
  let append text = Out_channel.with_open_gen [Open_append;Open_binary] 0o600 runtime
    (fun channel -> output_string channel text) in
  append "\n[providers.gemini]\ndisplay-name = \"Gemini\"\nprotocol = \"gemini-http\"\nendpoint = \"http://127.0.0.1:19002\"\n";
  append "\n[providers.messages-cli]\ndisplay-name = \"Messages CLI\"\nprotocol = \"messages-cli\"\ncommand = \"messages\"\n";
  Eio.Switch.run (fun sw ->
    List.iter (fun id ->
      Alcotest.check Alcotest.bool (id ^ " is refused by its typed variant") true
        (Actions.discover ~binary ~sw ~net ~base_path:base (`Assoc ["integration_id",`String id])
         = Error Actions.Unsupported_connection)) ["gemini";"messages-cli"]))
(* Proves the route status is a function of the error sum rather than a
   blanket 400: a server whose Eio context has no net answers 503 through
   [Network_unavailable], a moved setup revision 409, an upstream discovery
   failure 502, and a wrong body 400. On origin/main [Network_unavailable]
   and [status_of_error] do not exist, so this suite does not compile there. *)
let test_selected_native_account () = fixture (fun base runtime binary net ->
  let account_home = Filename.concat base "selected-account" ^ "/" in
  Unix.mkdir account_home 0o700;
  let append text = Out_channel.with_open_gen [Open_append;Open_text] 0o600 runtime (fun out -> output_string out text) in
  List.iter (fun (id,protocol,command) ->
    append (Printf.sprintf "\n[providers.%s]\nprotocol = %S\ncommand = %S\nis-non-interactive = true\naccount-home = %S\n" id protocol command account_home);
    let selection=get (Actions.select_account ~base_path:base (`Assoc ["integration_id",`String id])) in
    let open Yojson.Safe.Util in
    Alcotest.check Alcotest.bool "selection is not invocation proof" false (selection |> member "invocation_verified" |> to_bool);
    Alcotest.check Alcotest.bool "private home omitted from receipt" true (selection |> member "account_home" = `Null);
    let reference=selection |> member "account_ref" |> to_string in
    let retried=get (Actions.select_account ~base_path:base (`Assoc ["integration_id",`String id])) in
    Alcotest.check Alcotest.string "repeated selections reuse the scoped reference" reference
      (retried |> member "account_ref" |> to_string);
    let selected=`Assoc ["integration_id",`String id;"account_ref",`String reference] in
    if protocol="muse-serve" then Eio.Switch.run (fun sw ->
      let catalog=get (Actions.discover ~binary ~sw ~net ~base_path:base selected) in
      Alcotest.check Alcotest.string "source remains vendor metadata" "muse_providerCatalog" (catalog |> member "source" |> to_string));
    let request=request base selected in
    let request=if protocol<>"muse-serve" then request else
      (match request with `Assoc root -> `Assoc (List.map (fun (key,v) ->
        if key<>"connections" then key,v else key,`List [`Assoc ["source",selected;
          "models",`List [`Assoc ["id",`String "reported-muse";"context",`Int 32768;
            "streaming",`Bool true]]]]) root)
       | _ -> assert false) in
    let account_reference=Runtime_setup_accounts.reference_of_string reference |> Result.get_ok in
    let resolve ()=Runtime_setup_accounts.resolve ~workspace:base ~integration_id:id ~cli_path:command account_reference in
    let rejected=match request with
      | `Assoc fields -> `Assoc (("selection",`List [])::List.remove_assoc "selection" fields)
      | _ -> Alcotest.fail "fixture request must be an object" in
    Alcotest.check Alcotest.bool "failed transaction leaves account available for retry" true
      (Result.is_error (Actions.save ~binary ~base_path:base rejected) && Result.is_ok (resolve ()));
    let receipt = get (Actions.save ~binary ~base_path:base request) in
    Alcotest.check Alcotest.bool "successful transaction preserves concurrent account selections" true
      (Result.is_ok (resolve ()));
    (match Actions.save ~binary ~base_path:base request with
     | Error (Actions.Save_failed Runtime_setup_batch.Changed_configuration) -> ()
     | _ -> Alcotest.fail "lost-response retry must report revision conflict, not missing credentials");
    Alcotest.check Alcotest.bool "successful save retains the actual account" true (Sys.is_directory account_home);
    let parsed=Runtime_toml.parse_file runtime |> Result.get_ok in
    if protocol="muse-serve" then (
      let saved_runtime_id = receipt |> member "runtime_id" |> to_string in
      let model_id = match String.index_opt saved_runtime_id '.' with
        | Some i -> String.sub saved_runtime_id (i + 1) (String.length saved_runtime_id - i - 1)
        | None -> Alcotest.fail "saved runtime id names no model" in
      let model = List.find (fun (m : Runtime_schema.model_spec) -> String.equal m.id model_id)
          parsed.Runtime_schema.models in
      Alcotest.check Alcotest.(option int) "a saved Muse model declares no byte capacity"
        None model.max_prompt_bytes);
    let homes=List.filter_map (fun (p:Runtime_schema.provider) -> p.account_home) parsed.providers in
    Alcotest.check Alcotest.bool "selected native home survives save byte-for-byte" true (List.mem account_home homes))
    ["selected-claude","claude-code","claude";"selected-codex","codex-app-server","codex";
     "selected-muse","muse-serve","muse"];
  Alcotest.check Alcotest.bool "web cannot select arbitrary home" true
    (Actions.select_account ~base_path:base (`Assoc ["integration_id",`String "selected-muse";
      "account_home",`String "/arbitrary"]) = Error Actions.Invalid_request))

let test_muse_save_rechecks_selected_catalog ?supported () = fixture (fun base runtime binary net ->
  let account_home=Filename.concat base "catalog-account" in
  Unix.mkdir account_home 0o700;
  Out_channel.with_open_gen [Open_append;Open_text] 0o600 runtime (fun out ->
    Printf.fprintf out "\n[providers.muse]\nprotocol = \"muse-serve\"\ncommand = \"muse\"\nis-non-interactive = true\naccount-home = %S\n" account_home);
  let selection=get (Actions.select_account ~base_path:base (`Assoc ["integration_id",`String "muse"])) in
  let open Yojson.Safe.Util in
  let reference=selection |> member "account_ref" |> to_string in
  let selected=`Assoc ["integration_id",`String "muse";"account_ref",`String reference] in
  Eio.Switch.run (fun sw ->
    ignore (get (Actions.discover ~binary ~sw ~net ~base_path:base selected)));
  let before=In_channel.with_open_bin runtime In_channel.input_all in
  let revision=Runtime_setup_batch.observe ~base_path:base |> Result.get_ok |> Runtime_setup_batch.revision_to_string in
  let request ?image id context=`Assoc ["revision",`String revision;
    "connections",`List [`Assoc ["source",selected;"models",`List [`Assoc ([
      "id",`String id;"context",`Int context;"streaming",`Bool true]
      @ (match image with None -> [] | Some value -> ["supports_image_input", value]))]]];
    "selection",`List [`Assoc ["connection",`Int 0;"model",`Int 0]]] in
  let row context=`Assoc ["id",`String "reported-muse";"context",context] in
  let reported = match row (`Int 32768) with
    | `Assoc fields -> `Assoc (fields @ (match supported with None -> []
        | Some value -> ["supports_image_input", `Bool value]))
    | _ -> Alcotest.fail "fixture model is not an object" in
  let catalog_path=Filename.concat account_home "fixture-muse-catalog.json" in
  List.iter (fun (name,models,id,context) ->
    save catalog_path (Yojson.Safe.to_string (`List models));
    Alcotest.check Alcotest.bool (name ^ " refuses save") true
      (Result.is_error (Actions.save ~binary ~base_path:base (request id context)));
    Alcotest.check Alcotest.string (name ^ " preserves runtime configuration") before
      (In_channel.with_open_bin runtime In_channel.input_all);
    Alcotest.check Alcotest.bool (name ^ " never configures or verifies") false
      (Sys.file_exists (Filename.concat base "save-calls"));
    let reference=Runtime_setup_accounts.reference_of_string reference |> Result.get_ok in
    Alcotest.check Alcotest.bool (name ^ " leaves account lease reusable") true
      (Result.is_ok (Runtime_setup_accounts.resolve ~workspace:base
        ~integration_id:"muse" ~cli_path:"muse" reference)))
    ["unreported ID",[reported],"invented-muse",32768;
     "tampered context",[reported],"reported-muse",65536;
     "catalog lost after discovery",[],"reported-muse",32768;
     "context absent",[row `Null],"reported-muse",32768;
     "context nonpositive",[row (`Int 0)],"reported-muse",32768;
     "ambiguous catalog ID",[reported;reported],"reported-muse",32768];
  List.iter (fun (name, capability, requested) ->
    let model = match row (`Int 32768) with `Assoc fields ->
      `Assoc (fields @ (match capability with None -> []
        | Some value -> ["supports_image_input", `Bool value]))
      | _ -> Alcotest.fail "fixture model is not an object" in
    save catalog_path (Yojson.Safe.to_string (`List [model]));
    Alcotest.check Alcotest.bool (name ^ " refuses capability tampering") true
      (Actions.save ~binary ~base_path:base
        (request ~image:requested "reported-muse" 32768) = Error Actions.Invalid_request);
    Alcotest.check Alcotest.string (name ^ " preserves configuration") before
      (In_channel.with_open_bin runtime In_channel.input_all);
    Alcotest.check Alcotest.bool (name ^ " avoids native verification") false
      (Sys.file_exists (Filename.concat base "save-calls")))
    ["false cannot become true", Some false, `Bool true;
     "true cannot become false", Some true, `Bool false;
     "unknown cannot become asserted", None, `Bool true;
     "malformed capability", Some true, `String "true"];
  save catalog_path (Yojson.Safe.to_string (`List [reported]));
  ignore (get (Actions.save ~binary ~base_path:base (request "reported-muse" 32768)));
  Alcotest.check Alcotest.bool "matching fresh metadata reaches native verification" true
    (Sys.file_exists (Filename.concat base "save-calls"));
  let configured = Runtime_toml.parse_file runtime |> Result.get_ok in
  let model = List.find (fun (model : Runtime_schema.model_spec) -> model.api_name = "reported-muse") configured.models in
  Alcotest.check (Alcotest.option Alcotest.bool)
    "omitted browser capability saves the authoritative reported value"
    supported (Option.bind model.capabilities (fun caps -> caps.supports_image_input)))

let test_native_save_rechecks_image_capabilities () =
  List.iter (fun client -> List.iter (fun supported -> fixture (fun base runtime binary _net ->
    let before=In_channel.with_open_bin runtime In_channel.input_all in
    let catalog=`Assoc (["id",`String "selected-model";"max_context",`Int 1024]
      @ (match supported with None -> [] | Some value -> ["supports_image_input",`Bool value])) in
    save (Filename.concat base "fixture-native-catalog.json") (Yojson.Safe.to_string (`List [catalog]));
    let revision=Runtime_setup_batch.observe ~base_path:base |> Result.get_ok |> Runtime_setup_batch.revision_to_string in
    let request ?image () = `Assoc ["revision",`String revision;
      "connections",`List [`Assoc ["source",`Assoc ["integration_id",`String client];
        "models",`List [`Assoc (["id",`String "selected-model";"context",`Int 1024;"streaming",`Bool true]
          @ (match image with None -> [] | Some value -> ["supports_image_input",`Bool value]))]]];
      "selection",`List [`Assoc ["connection",`Int 0;"model",`Int 0]]] in
    let forged=match supported with None -> true | Some value -> not value in
    Alcotest.check Alcotest.bool "native capability forgery is rejected" true
      (Actions.save ~binary ~base_path:base (request ~image:forged ()) = Error Actions.Invalid_request);
    Alcotest.check Alcotest.string "rejection preserves runtime bytes" before
      (In_channel.with_open_bin runtime In_channel.input_all);
    Alcotest.check Alcotest.bool "rejection precedes verification" false
      (Sys.file_exists (Filename.concat base "save-calls"));
    ignore (get (Actions.save ~binary ~base_path:base (request ())));
    let configured=Runtime_toml.parse_file runtime |> Result.get_ok in
    let model=List.find (fun (model:Runtime_schema.model_spec) -> model.api_name="selected-model") configured.models in
    Alcotest.check (Alcotest.option Alcotest.bool) "omission preserves server capability"
      supported (Option.bind model.capabilities (fun caps -> caps.supports_image_input))))
    [None;Some true;Some false]) ["codex";"claude-code"]

let test_named_lane_save () = fixture (fun base runtime binary _net ->
  let config = Runtime_toml.parse_file runtime |> Result.get_ok in
  let primary = Option.get config.default_runtime_id in
  let configured = In_channel.with_open_bin runtime In_channel.input_all in
  let configured = Toml_line_editor.edit_table_scalar configured ~path:"runtime"
    ~key:"default" ~value:(Some "conversation") in
  let configured = Toml_line_editor.edit_table_multiline_array configured
    ~path:"runtime.lanes.conversation" ~key:"candidates" ~values:[primary] in
  save runtime configured;
  let revision=Runtime_setup_batch.observe ~base_path:base |> Result.get_ok |> Runtime_setup_batch.revision_to_string in
  let request route = `Assoc ["revision",`String revision;"default_runtime_id",route;
    "connections",`List [];"selection",`List [`Assoc ["runtime_id",`String primary]]] in
  List.iter (fun invalid ->
    Alcotest.check Alcotest.bool "invalid default route refused" true
      (Actions.save ~binary ~base_path:base (request invalid)=Error Actions.Invalid_request))
    [`Null; `Int 1; `String "missing-lane"];
  Alcotest.check Alcotest.bool "invalid route does not begin native save" false
    (Sys.file_exists (Filename.concat base "save-calls"));
  let receipt = get (Actions.save ~binary ~base_path:base (request (`String "conversation"))) in
  let open Yojson.Safe.Util in
  Alcotest.check Alcotest.string "HTTP receipt retains named route" "conversation"
    (receipt |> member "runtime_id" |> to_string);
  Alcotest.check (Alcotest.list Alcotest.string) "HTTP selection remains concrete" [primary]
    (receipt |> member "runtime_ids" |> to_list |> List.map to_string);
  let after = Runtime_toml.parse_file runtime |> Result.get_ok in
  Alcotest.check (Alcotest.option Alcotest.string) "HTTP save preserves configured route" (Some "conversation") after.default_runtime_id)
let test_bound_models_follow_account_home () = fixture (fun base runtime binary net ->
  let home = Filename.concat base "shared-codex-account" in
  let other_home = Filename.concat base "other-codex-account" in
  Unix.mkdir home 0o700; Unix.mkdir other_home 0o700;
  let add ?(include_provider=true) model account_home =
    let spec = Runtime_setup_spec.of_json (`Assoc [
      "choice",`String "codex"; "model",`String model;
      "max_context",`Int 32768; "tools",`Bool true; "streaming",`Bool true;
      "command",`String "codex"; "account_home",`String account_home]) |> Result.get_ok in
    Runtime_setup_spec.render ~include_provider ~wizard_default:include_provider spec in
  let first = add "fresh-model" home in
  let second = add ~include_provider:false "second-model" home in
  let other = add "other-model" other_home in
  Out_channel.with_open_gen [Open_append;Open_binary] 0o600 runtime (fun channel ->
    List.iter (fun rendered -> output_string channel ("\n" ^ rendered.Runtime_setup_spec.runtime_toml))
      [first;second;other]);
  let provider_id rendered =
    match String.split_on_char '.' rendered.Runtime_setup_spec.runtime_id with
    | id :: _ -> id | [] -> Alcotest.fail "rendered runtime has no provider" in
  Eio.Switch.run (fun sw ->
    let flags rendered =
      let json = get (Actions.discover ~binary ~sw ~net ~base_path:base
        (`Assoc ["integration_id",`String (provider_id rendered)])) in
      let open Yojson.Safe.Util in
      json |> member "models" |> to_list |> List.map (fun row ->
        row |> member "id" |> to_string, row |> member "bound" |> to_bool) in
    let shared = ["fresh-model",true;"second-model",true;"other-model",false] in
    let isolated = ["fresh-model",false;"second-model",false;"other-model",true] in
    Alcotest.check (Alcotest.list (Alcotest.pair Alcotest.string Alcotest.bool))
      "first provider sees every model on its account" shared (flags first);
    Alcotest.check (Alcotest.list (Alcotest.pair Alcotest.string Alcotest.bool))
      "second provider sees every model on its account" shared (flags second);
    Alcotest.check (Alcotest.list (Alcotest.pair Alcotest.string Alcotest.bool))
      "another account keeps its own model" isolated (flags other)))
let test_bound_models_follow_effective_ambient_home () = fixture (fun base runtime binary net ->
  let ambient = match Runtime_codex_app_server.effective_account_home None with
    | Some home -> home | None -> Alcotest.fail "fixture needs an effective native home" in
  let other = Filename.concat base "different-native-account" in
  Unix.mkdir other 0o700;
  let add id model home = Printf.sprintf
    "\n[providers.%s]\nprotocol=\"codex-app-server\"\ncommand=\"codex\"\nis-non-interactive=true\n%s\n[models.%s]\napi-name=%S\nmax-context=272000\ntools-support=true\n[%s.%s]\n"
    id (match home with None -> "" | Some home -> "account-home=" ^ Printf.sprintf "%S" home)
    id model id id in
  Out_channel.with_open_gen [Open_append;Open_binary] 0o600 runtime (fun channel ->
    output_string channel (add "ambient_first" "fresh-model" None
      ^ add "ambient_hidden" "second-model" None
      ^ add "ambient_explicit" "fresh-model" (Some ambient)
      ^ add "other_account" "other-model" (Some other)));
  Eio.Switch.run (fun sw ->
    let flags source = get (Actions.discover ~binary ~sw ~net ~base_path:base source)
      |> Yojson.Safe.Util.member "models" |> Yojson.Safe.Util.to_list
      |> List.map (fun row -> Yojson.Safe.Util.(row |> member "id" |> to_string,
          row |> member "bound" |> to_bool)) in
    let shared = ["fresh-model",true;"second-model",true;"other-model",false] in
    List.iter (fun id -> Alcotest.check (Alcotest.list (Alcotest.pair Alcotest.string Alcotest.bool))
      "implicit and explicit homes expose the same existing models" shared
      (flags (`Assoc ["integration_id",`String id]))) ["ambient_first";"ambient_explicit"];
    let reference = Runtime_setup_accounts.register_home ~workspace:base
      ~integration_id:"ambient_first" ~cli_path:"codex" ~account_home:other
      |> Result.get_ok |> Runtime_setup_accounts.reference_to_string in
    Alcotest.check (Alcotest.list (Alcotest.pair Alcotest.string Alcotest.bool))
      "a newly selected account does not inherit models from the provider's old home"
      ["fresh-model",false;"second-model",false;"other-model",true]
      (flags (`Assoc ["integration_id",`String "ambient_first";"account_ref",`String reference]))))

let test_status_of_error () =
  let check name expected error =
    Alcotest.check Alcotest.bool name true (Actions.status_of_error error = expected) in
  check "commit storage failure is 503" `Service_unavailable (Actions.Save_failed (Runtime_setup_batch.Write_failed "disk full"));
  check "commit validation refusal is 400" `Bad_request (Actions.Save_failed (Runtime_setup_batch.Commit_refused "invalid source"));
  check "missing net is 503" `Service_unavailable Actions.Network_unavailable;
  check "unreadable configuration is 503" `Service_unavailable Actions.Configuration_unavailable;
  check "wrong body is 400" `Bad_request Actions.Invalid_request;
  check "moved revision is 409" `Conflict (Actions.Save_failed Runtime_setup_batch.Changed_configuration);
  check "upstream discovery failure is 502" `Bad_gateway
    (Actions.Discovery_failed Runtime_model_discovery.Request_failed);
  check "wrong discovery connection is 400" `Bad_request
    (Actions.Discovery_failed Runtime_model_discovery.Invalid_connection)
let () = Alcotest.run "web setup actions" ["request boundary",[
  Alcotest.test_case "inline account variants preserve the provider while replacement keys stay separate" `Quick test_existing_inline_http_account;
  Alcotest.test_case "product alias reuses the configured account" `Quick test_alias_reuses_operator_account;
  Alcotest.test_case "disabled provider is preserved and refused" `Quick test_disabled_provider_refused;
  Alcotest.test_case "catalog Responses paths survive account setup and reuse" `Quick test_catalog_responses_save;
  Alcotest.test_case "bound models use the same effective home as account grouping" `Quick test_bound_models_follow_effective_ambient_home;
  Alcotest.test_case "private key joins verified native save" `Quick test_private_key;
  Alcotest.test_case "configured HTTP account accepts another context variant" `Quick test_existing_http_context_variant;
  Alcotest.test_case "no browser credential paths or executable override" `Quick test_forbidden_reference;
  Alcotest.test_case "native client metadata without private fields" `Quick test_native_client_metadata;
  Alcotest.test_case "malformed advertised reasoning efforts refuse discovery" `Quick test_malformed_client_reasoning_efforts;
  Alcotest.test_case "configured Codex account survives discovery, verification and save" `Quick test_configured_codex_account_save;
  Alcotest.test_case "configured Muse advertises readiness independently" `Quick test_configured_muse_readiness_inventory;
  Alcotest.test_case "imported opaque account joins native save" `Quick test_account_reference;
  Alcotest.test_case "declared provider variants refuse before discovery" `Quick test_declared_provider_variants;
  Alcotest.test_case "selected native accounts survive verified save" `Quick test_selected_native_account;
  Alcotest.test_case "Muse save rechecks selected account catalog before effects" `Quick (fun () ->
    test_muse_save_rechecks_selected_catalog ();
    test_muse_save_rechecks_selected_catalog ~supported:true ();
    test_muse_save_rechecks_selected_catalog ~supported:false ());
  Alcotest.test_case "bound models follow account home across provider IDs" `Quick test_bound_models_follow_account_home;
  Alcotest.test_case "native save rechecks image capability" `Quick test_native_save_rechecks_image_capabilities;
  Alcotest.test_case "named default route survives HTTP save" `Quick test_named_lane_save;
  Alcotest.test_case "route status follows the error sum" `Quick test_status_of_error]]
