open Alcotest
module F = Masc_tui_model_form
module T = Masc_tui_model_runtime_table
let source = {|
[providers.codex1]
protocol = "codex-app-server"
command = "codex"
is-non-interactive = true
account-home = "/tmp/codex-account-one"
[models."luna.6"]
api-name = "gpt-6-luna"
max-context = 500000
reasoning-effort = "low"
temperature = 0.123456789012345
[models."luna.6".capabilities]
supports-image-input = true
[codex1."luna.6"]
max-context = 272000
max-tokens = 8192
price-input = 0.075
wizard-default = true
[runtime.lanes.primary]
candidates = ["codex1.luna.6"]
|}
let row source = match T.parse (String.split_on_char '\n' source) with
  | Ok (row::_) -> row | Ok [] -> fail "missing binding" | Error e -> fail e
let edit form key = match F.key form key with
  | F.Editing form -> form | _ -> fail "unexpected form outcome"
let set form value = F.paste (edit form "ctrl-u") value
let apply form source = match F.apply form source with Ok text -> text | Error e -> fail e
let config source = match Runtime_toml.parse_string source with
  | Ok c -> c | Error _ -> fail "invalid TOML from model form"
let test_copy_variant () =
  let form = F.create F.Copy (row source) |> fun f -> set f "luna.6-500k"
    |> fun f -> edit f "tab" |> fun f -> set f "500000" in
  let output = apply form source in
  let c = config output in
  check int "one account" 1 (List.length c.providers);
  check int "both variants" 2 (List.length c.bindings);
  let original = List.find (fun (b:Runtime_schema.binding) -> b.model_id = "luna.6") c.bindings in
  let copied = List.find (fun (b:Runtime_schema.binding) -> b.model_id = "luna.6-500k") c.bindings in
  check (option int) "original context preserved" (Some 272000) original.max_context;
  check (option int) "copied context changed" (Some 500000) copied.max_context;
  check string "same account" original.provider_id copied.provider_id;
  check (option (float 0.)) "copy does not round price" original.price_input copied.price_input;
  check bool "copy does not steal default" false copied.wizard_default;
  let old_model = List.find (fun (m:Runtime_schema.model_spec) -> m.id="luna.6") c.models in
  let new_model = List.find (fun (m:Runtime_schema.model_spec) -> m.id="luna.6-500k") c.models in
  check string "same API model" old_model.api_name new_model.api_name;
  check (option (float 0.)) "temperature precision retained" old_model.temperature new_model.temperature;
  check (list string) "order unchanged" ["codex1.luna.6"] (List.hd c.lane_decls).candidate_ids;
  check bool "duplicate name refused" true (Result.is_error (F.apply form output))
let test_edit_and_cancel () =
  let form = F.create F.Edit (row source) |> fun f -> set f "300000" in
  let c = config (apply form source) in
  check (option int) "binding-local context" (Some 300000) (List.hd c.bindings).max_context;
  check (option int) "original model specification" (Some 500000) (List.hd c.models).max_context;
  check bool "Esc cancels" true (match F.key form "esc" with F.Cancelled -> true | _ -> false);
  let bad = set form "no-context" in
  check bool "bad integer refused" true (Result.is_error (F.apply bad source));
  let rendered = F.rows ~width:48 ~height:12 form in
  check bool "fits narrow form" true (List.for_all (fun s -> Masc_tui_message_layout.display_width s <= 48) rendered)
let () = run "Account model variants" ["model editing", [
  test_case "copy retains account, API model and settings" `Quick test_copy_variant;
  test_case "edit context and cancel" `Quick test_edit_and_cancel]]
