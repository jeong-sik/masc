module Models = Runtime_config_models
let success = function Ok value -> value | Error detail -> Alcotest.fail detail
let expect label condition = Alcotest.(check bool) label true condition
let config () =
  match Runtime_toml.parse_string {|
[models."shared.name"]
api-name = "wire-model"
reasoning-effort = "high"
temperature = 0.7
max-context = 64000
[models.unbound]
[model_sets.family]
models = ["shared.name"]
[providers.alpha]
protocol = "openai-compatible-http"
kind = "openai_compat"
endpoint = "http://localhost:9000/v1"
model-set = "family"
max-context = 32000
[providers.beta]
protocol = "openai-compatible-http"
kind = "openai_compat"
endpoint = "http://localhost:9000/v1"
model-set = "family"
enabled = false
[beta."shared.name"]
max-context = 16000
max-tokens = 2048
[providers.unbound]
protocol = "openai-compatible-http"
kind = "openai_compat"
endpoint = "http://localhost:9000/v1"
|} with
  | Ok config -> config
  | Error errors -> Alcotest.fail (String.concat "; "
      (List.map (fun (e : Runtime_toml.parse_error) -> e.path ^ ": " ^ e.message) errors))
let projection () = Models.of_config (config ()) |> success
let wire () = Models.to_json ~path:"/server/runtime.toml" ~source_revision:"revision-a" (Ok (projection ()))
let read = Models.of_json ~path:"/server/runtime.toml" ~source_revision:"revision-a"
let replace key value = function
  | `Assoc fields -> `Assoc ((key,value) :: List.remove_assoc key fields)
  | _ -> Alcotest.fail "fixture is not an object"
let map key f = function
  | `Assoc fields -> `Assoc (List.map (fun (k,v) -> k,if String.equal key k then f v else v) fields)
  | _ -> Alcotest.fail "fixture is not an object"
let map_bindings f = map "outcome" (map "bindings" f)

let test_declarations () =
  let value = projection () in
  expect "unbound providers remain available to membership validation"
    (List.mem "unbound" value.provider_ids);
  expect "unbound shared model does not invent a binding"
    (List.for_all (fun (b : Models.binding) -> b.model = "shared.name") value.bindings);
  let row provider = List.find (fun (b : Models.binding) -> b.provider = provider) value.bindings in
  expect "provider context overrides shared model declaration"
    ((row "alpha").context = Some (Models.Provider,32000));
  expect "disabled declaration stays editable with binding-specific override"
    ((row "beta").context = Some (Models.Binding,16000) && (row "beta").max_tokens = Some 2048);
  expect "original shared default is retained" ((row "beta").model_context = Some 64000);
  expect "undeclared output limit stays absent" ((row "alpha").max_tokens = None);
  expect "wire identity and model knobs retained"
    ((row "alpha").api_name = "wire-model" && (row "alpha").temperature = Some 0.7
     && Option.map Llm_provider.Reasoning_effort.to_string (row "alpha").reasoning_effort = Some "high");
  let c = config () in
  let p = List.hd c.providers and m = List.hd c.models and b = List.hd c.bindings in
  let dotted = Models.of_config {c with
    providers=[{p with id="a.b"}; {p with id="a"}];
    models=[{m with id="c"}; {m with id="b.c"}];
    bindings=[{b with provider_id="a.b";model_id="c"}; {b with provider_id="a";model_id="b.c"}]} |> success in
  expect "dotted provider/model pairs remain distinct declarations" (List.length dotted.bindings = 2)

let test_round_trip_and_identity () =
  let value = wire () |> Yojson.Safe.to_string |> Yojson.Safe.from_string |> read |> success in
  expect "JSON round trip retains typed declarations" (value = projection ());
  expect "different path cannot borrow the projection"
    (Result.is_error (Models.of_json ~path:"/another/runtime.toml" ~source_revision:"revision-a" (wire ())));
  expect "different revision cannot borrow the projection"
    (Result.is_error (Models.of_json ~path:"/server/runtime.toml" ~source_revision:"revision-b" (wire ())));
  let duplicate = match wire () with
    | `Assoc fields -> `Assoc (("source_revision", `String "revision-a") :: fields)
    | _ -> Alcotest.fail "fixture is not an object" in
  expect "duplicate identity fields rejected" (Result.is_error (read duplicate));
  let failure = Models.to_json ~path:"/server/runtime.toml" ~source_revision:"revision-a" (Error "source invalid") in
  expect "unavailable projection is not an empty catalogue" (read failure = Error "source invalid")

let test_malformed_rows () =
  let mutate row = wire () |> map_bindings (function
    | `List (first :: rest) -> `List (row first :: rest)
    | _ -> Alcotest.fail "fixture has no bindings") in
  List.iter (fun json -> expect "invalid row is not silently discarded" (Result.is_error (read json)))
    [mutate (replace "provider" (`String "foreign"));
     mutate (replace "max_tokens" (`Int 0));
     mutate (replace "reasoning_effort" (`String "unknown"));
     mutate (replace "context" (`Assoc ["source",`String "catalog";"tokens",`Int 10]));
     mutate (replace "context" (`Assoc ["source",`String "model";"tokens",`Int 10]));
     wire () |> map_bindings (function `List (first :: rest) -> `List (first :: first :: rest) | rows -> rows)];
  let c = config () in
  let b = List.hd c.bindings in
  expect "dangling source declaration remains an error"
    (Result.is_error (Models.of_config {c with bindings=[{b with provider_id="absent"}]}));
  expect "duplicate source declaration remains an error"
    (Result.is_error (Models.of_config {c with bindings=b :: c.bindings}))

let () = Alcotest.run "runtime_config_models"
  ["source projection", [
    Alcotest.test_case "declared bindings and precedence" `Quick test_declarations;
    Alcotest.test_case "wire provenance and unavailable results" `Quick test_round_trip_and_identity;
    Alcotest.test_case "malformed and dangling declarations" `Quick test_malformed_rows]]
