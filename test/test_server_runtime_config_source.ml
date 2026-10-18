open Alcotest
open Masc
module Source = Server_runtime_config_source
module Keeper = Keeper_toml_loader

let fixture = {|[providers.api]
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:9/v1"
display-name = """first
second"""
[models."quoted.model"]
api-name = "fixture-model"
max-context = 4096
[api."quoted.model"]
[keeper]
instructions = """first
second"""
escaped = "one\r\ntwo"
|}

let keeper = function Ok doc -> doc | Error detail -> fail detail
let runtime = function
  | Ok config -> config
  | Error errors -> fail (String.concat "; " (List.map (fun (e : Runtime_toml.parse_error) -> e.path ^ ": " ^ e.message) errors))
let model_names config = List.map (fun (row : Runtime_schema.model_spec) -> row.id) config.Runtime_schema.models
let display config = match Runtime_schema.provider_of_id config "api" with
  | Some provider -> provider.display_name | None -> fail "provider missing"

let shared_source_keeps_both_reader_results () =
  let prepared = Source.prepare fixture in
  check bool "identical syntax inputs share the parse" true (prepared.syntax_inputs=Source.Shared_input);
  check string "revision-bearing original bytes retained" fixture prepared.source_text;
  let doc = keeper prepared.keeper in
  check bool "Keeper projection equals its existing reader" true (doc = keeper (Keeper.parse_toml fixture));
  check (option string) "multiline Keeper value retained" (Some "first\nsecond")
    (Keeper.toml_string_opt doc "keeper.instructions");
  check (list string) "quoted model ID remains one declared ID" ["quoted.model"] (model_names (runtime prepared.runtime));
  check string "Runtime interpretation retains original display value"
    (display (runtime (Runtime_toml.parse_string fixture))) (display (runtime prepared.runtime))

let reader_specific_newlines_keep_original_semantics () =
  let source = String.concat "\r\n" (String.split_on_char '\n' fixture) in
  let prepared = Source.prepare source in
  check bool "different exact inputs are not merged" true (prepared.syntax_inputs=Source.Reader_specific_inputs);
  check string "source revision input is not normalized" source prepared.source_text;
  let doc = keeper prepared.keeper in
  check bool "Keeper still uses its normalized input" true (doc = keeper (Keeper.parse_toml source));
  check (option string) "physical CRLF multiline newlines follow Keeper policy" (Some "first\nsecond")
    (Keeper.toml_string_opt doc "keeper.instructions");
  check (option string) "escaped CRLF is not rewritten after parsing" (Some "one\r\ntwo")
    (Keeper.toml_string_opt doc "keeper.escaped");
  check string "Runtime retains its original raw-source interpretation"
    (display (runtime (Runtime_toml.parse_string source))) (display (runtime prepared.runtime))

let semantic_failure_keeps_the_other_projection () =
  let source = {|[providers.api]
protocol = "unknown-protocol"
endpoint = "http://127.0.0.1:9/v1"
[keeper]
instructions = "repair this original source"
|} in
  let prepared = Source.prepare source in
  check (option string) "Runtime failure cannot erase Keeper document" (Some "repair this original source")
    (Keeper.toml_string_opt (keeper prepared.keeper) "keeper.instructions");
  check bool "failed Runtime validation is not an empty successful config" true
    (match prepared.runtime with Error (_::_) -> true | Error [] | Ok _ -> false);
  check string "source remains repairable" source prepared.source_text

let syntax_failure_and_non_document_roots_are_refused () =
  let source = "[keeper\n" in
  let prepared = Source.prepare source in
  check string "malformed source retained" source prepared.source_text;
  check bool "Keeper syntax failure stays explicit" true (Result.is_error prepared.keeper);
  check bool "Runtime syntax failure retains parse provenance" true
    (match prepared.runtime with Error [{Runtime_toml.path="<parse>";_}] -> true
     | Error [] | Error (_::_) | Ok _ -> false);
  check bool "Keeper parsed-root boundary rejects a scalar" true
    (Result.is_error (Keeper.of_otoml (Otoml.TomlString "not a document")));
  check bool "Runtime parsed-root boundary rejects a scalar" true
    (Result.is_error (Runtime_toml.parse_toml (Otoml.TomlString "not a document")))

let runtime_home_expansion_remains_an_environment_effect () =
  let previous = Sys.getenv_opt "HOME" in
  Fun.protect ~finally:(fun () -> match previous with
    | Some value -> Unix.putenv "HOME" value | None -> Unix.unsetenv "HOME") (fun () ->
    Unix.putenv "HOME" "/tmp/masc-synthetic-source-home";
    let source = fixture ^ {|
[providers.agy]
protocol = "antigravity-cli"
command = "/usr/bin/true"
is-non-interactive = true
timeout-s = 10.0
credentials = { type = "file", path = "~/synthetic-login.json" }
[models.gemini]
api-name = "gemini-fixture"
max-context = 128000
[agy.gemini]
|} in
    let prepared = Source.prepare source in
    match Runtime_schema.provider_of_id (runtime prepared.runtime) "agy" with
    | Some {credentials=Some (Runtime_schema.File path);_} ->
        check string "semantic projection keeps explicit environment-dependent expansion"
          "/tmp/masc-synthetic-source-home/synthetic-login.json" path
    | None | Some _ -> fail "expanded credential source missing")

let () = run "server runtime source preparation" ["reader continuity",[
  test_case "shared syntax retains both reader results" `Quick shared_source_keeps_both_reader_results;
  test_case "distinct normalized input preserves newline semantics" `Quick reader_specific_newlines_keep_original_semantics;
  test_case "semantic failure keeps the independent projection" `Quick semantic_failure_keeps_the_other_projection;
  test_case "malformed syntax and scalar roots are refused" `Quick syntax_failure_and_non_document_roots_are_refused;
  test_case "Runtime home expansion remains effectful" `Quick runtime_home_expansion_remains_an_environment_effect;
]]
