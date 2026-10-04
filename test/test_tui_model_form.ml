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
let test_inline_refusal_and_visible_error () =
  let inline = {|
[providers.codex1]
protocol = "codex-app-server"
command = "codex"
is-non-interactive = true
[models.a]
max-context = 272000
[codex1]
a = {max-tokens=8192, price-input=0.075}
|} in
  let form = F.create F.Copy (row inline) in
  check bool "inline values cannot silently disappear" true (Result.is_error (F.apply form inline));
  let form = F.refused form "Context must be a positive integer" in
  let lines = F.rows ~width:48 ~height:12 form in
  check bool "failure visible on short terminal" true
    (List.exists (fun line -> String.starts_with ~prefix:"Error: Context" line) lines)

let test_inline_edit_refusal () =
  let inline_binding = {|
[providers.codex1]
protocol = "codex-app-server"
command = "codex"
is-non-interactive = true
[models.a]
max-context = 272000
[codex1]
a = {max-tokens=8192}
|} in
  let edit_inline source =
    let form = F.create F.Edit (row source)
      |> fun f -> edit f "tab" |> fun f -> edit f "tab" |> fun f -> edit f "tab"
      |> fun f -> set f "" in
    check bool "inline clear is refused, never a successful no-op" true
      (Result.is_error (F.apply form source)) in
  edit_inline inline_binding;
  edit_inline {|
[providers.codex1]
protocol = "codex-app-server"
command = "codex"
is-non-interactive = true
[models]
a = {max-context=272000, temperature=0.5}
[codex1.a]
max-tokens = 8192
|}

let test_dotted_parent_refusal () =
  let dotted = {|
[providers.codex1]
protocol = "codex-app-server"
command = "codex"
is-non-interactive = true
[models]
a.max-context = 272000
a.temperature = 0.5
[models.a.capabilities]
supports-image-input = true
[codex1.a]
max-tokens = 8192
|} in
  let form = F.create F.Edit (row dotted) |> fun f -> edit f "tab"
    |> fun f -> edit f "tab" |> fun f -> set f "" in
  check bool "descendant header does not make dotted model editable" true
    (Result.is_error (F.apply form dotted));
  check bool "copy does not discard dotted parent settings" true
    (Result.is_error (F.apply (F.create F.Copy (row dotted)) dotted))

let test_error_height_bound () =
  let form = F.refused (F.create F.Edit (row source))
      (String.concat " " (List.init 100 (fun _ -> "configuration failure"))) in
  List.iter (fun (width,height) ->
    let lines = F.rows ~width ~height form in
    check bool "error obeys the frame height" true (List.length lines <= height);
    check bool "every line obeys the frame width" true
      (List.for_all (fun line -> Masc_tui_message_layout.display_width line <= width) lines))
    [24,0;24,1;24,5;48,8;80,12];
  let lines = F.rows ~width:48 ~height:8 form in
  check bool "cancel remains reachable in visible hints" true
    (List.exists (fun line -> Astring.String.is_infix ~affix:"Esc cancel" line) lines);
  check bool "failure remains visible" true
    (List.exists (fun line -> String.starts_with ~prefix:"Error:" line) lines)

let test_ollama_context () =
  let source = {|
[providers.local]
protocol = "ollama-http"
endpoint = "http://localhost:11434"
[models.a]
max-context = 272000
[local.a]
num-ctx = 272000
|} in
  let form = F.create F.Copy (row source) |> fun f -> edit f "tab" |> fun f -> set f "500000" in
  let c = config (apply form source) in
  let copied = List.find (fun (b:Runtime_schema.binding) -> b.model_id="a-copy") c.bindings in
  check (option int) "Ollama serving context changes with variant" (Some 500000) copied.num_ctx;
  let source = source ^ "max-context = 128000\n" in
  let form = F.create F.Edit (row source) |> fun f -> set f "" in
  let c = config (apply form source) in
  check (option int) "clearing context inherits the model serving context" (Some 272000) (List.hd c.bindings).num_ctx;
  check (option int) "clearing context removes the override" None (List.hd c.bindings).max_context

let test_copy_preserves_ollama_request_context () =
  List.iter (fun declaration ->
    let source = {|
[providers.local]
protocol = "ollama-http"
endpoint = "http://localhost:11434"
[models.a]
|} ^ declaration ^ {|
[local.a]
num-ctx = 8192
|} in
    let copied = config (apply (F.create F.Copy (row source)) source)
      |> fun c -> List.find (fun (b:Runtime_schema.binding) -> b.model_id="a-copy") c.bindings in
    check (option int) "unchanged Copy preserves transport num-ctx" (Some 8192) copied.num_ctx;
    let changed = F.create F.Copy (row source) |> fun f -> edit f "tab"
      |> fun f -> set f "16384" in
    let copied = config (apply changed source)
      |> fun c -> List.find (fun (b:Runtime_schema.binding) -> b.model_id="a-copy") c.bindings in
    check (option int) "changing Context updates transport num-ctx" (Some 16384) copied.num_ctx)
    [""; "max-context = 272000\n"]

let test_temperature_round_trip () =
  let selected = row source in
  let displayed = match selected.temperature with Some n -> n | None -> fail "missing temperature" in
  check (float 0.) "displayed temperature represents exact value"
    0.123456789012345 (float_of_string displayed);
  let form = F.create F.Edit selected |> fun f -> edit f "tab" |> fun f -> edit f "tab" in
  let unchanged = apply (set form displayed) source in
  check string "unchanged exact value preserves source" source unchanged;
  let updated = config (apply (set form "0.123457") source) in
  check (option (float 0.)) "a distinct explicitly entered value is applied"
    (Some 0.123457) (List.hd updated.models).temperature

let () = run "Account model variants" ["model editing", [
  test_case "copy retains account, API model and settings" `Quick test_copy_variant;
  test_case "edit context and cancel" `Quick test_edit_and_cancel;
  test_case "inline copy refusal is visible" `Quick test_inline_refusal_and_visible_error;
  test_case "inline edit clear cannot be a no-op" `Quick test_inline_edit_refusal;
  test_case "dotted parent cannot lose settings" `Quick test_dotted_parent_refusal;
  test_case "wrapped error obeys form height" `Quick test_error_height_bound;
  test_case "Ollama requested context follows variant" `Quick test_ollama_context;
  test_case "Ollama Copy preserves unchanged request context" `Quick test_copy_preserves_ollama_request_context;
  test_case "temperature display and edit round-trip" `Quick test_temperature_round_trip]]
