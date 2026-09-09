open Alcotest
module Verify = Runtime_verification

let contains text needle =
  let rec loop index =
    index + String.length needle <= String.length text
    && (String.sub text index (String.length needle) = needle || loop (index + 1))
  in
  loop 0
;;

let measure run =
  Verify.For_testing.measure
    ~runtime_id:"chosen.model"
    ~selected_model:"selected-model"
    ~challenge:"unpredictable-test-challenge"
    ~run
;;

let observation text = { Verify.model = "observed-model"; text }
let reply = "{\"challenge\":\"unpredictable-test-challenge\"}"

let test_roundtrip () =
  let result =
    measure (fun tool ~prompt ->
      check
        bool
        "challenge absent before tool execution"
        false
        (contains prompt "unpredictable-test-challenge");
      let output =
        tool.Runtime_official_client_tool.call ~call_id:"actual-call" (`Assoc [])
      in
      check bool "harmless tool returned a result" true output.success;
      Ok (observation output.content))
  in
  check int "actual returned challenge verifies" 0 (Verify.exit_code result);
  check bool "tool roundtrip" true result.tool_roundtrip;
  check
    (option string)
    "observed model retained separately"
    (Some "observed-model")
    result.observed_model;
  check string "exact selected runtime remains" "chosen.model" result.runtime_id
;;

let test_no_tool_cannot_claim_success () =
  let result = measure (fun _ ~prompt:_ -> Ok (observation reply)) in
  check int "even correct-looking reply without call fails" 1 (Verify.exit_code result);
  check bool "actual response distinguished from login" true result.response;
  check bool "tool not invoked" false result.tool_called;
  check bool "no roundtrip" false result.tool_roundtrip
;;

let test_result_must_be_consumed () =
  List.iter
    (fun text ->
       let result =
         measure (fun tool ~prompt:_ ->
           ignore (tool.Runtime_official_client_tool.call ~call_id:"call" (`Assoc []));
           Ok (observation text))
       in
       check int "uncorrelated answer is not ready" 1 (Verify.exit_code result);
       check bool "invocation alone is insufficient" true result.tool_called;
       check bool "result not consumed" false result.tool_roundtrip)
    [ "I can use tools"
    ; "{\"challenge\":\"invented\"}"
    ; "{\"challenge\":\"unpredictable-test-challenge\",\"challenge\":\"invented\"}"
    ; ""
    ]
;;

let test_missing_model_identity () =
  let result =
    measure (fun tool ~prompt:_ ->
      let output = tool.Runtime_official_client_tool.call ~call_id:"call" (`Assoc []) in
      Ok { Verify.model = ""; text = output.content })
  in
  check int "missing model identity is not verified" 1 (Verify.exit_code result);
  check (option string) "empty identity is not an observation" None result.observed_model
;;

let test_invalid_call_and_errors () =
  let result =
    measure (fun tool ~prompt:_ ->
      let output =
        tool.Runtime_official_client_tool.call
          ~call_id:"call"
          (`Assoc [ "path", `String "/workspace" ])
      in
      check bool "invalid tool args rejected" false output.success;
      Ok (observation reply))
  in
  check bool "invalid tool args not counted" false result.tool_called;
  List.iter
    (fun failure ->
       let result = measure (fun _ ~prompt:_ -> Error failure) in
       check bool "provider/config failure not success" false result.tool_roundtrip;
       check bool "no response fabricated" false result.response)
    [ Verify.Provider_rejected; Timed_out; Unavailable Missing_credential ]
;;

let test_inventory_keeps_all_models_and_no_secrets () =
  let config =
    {|
[runtime]
default = "cloud.first"
[providers.cloud]
display-name = "My endpoint"
protocol = "openai-compatible-http"
endpoint = "https://example.com/v1"
[providers.cloud.credentials]
type = "inline"
value = "must-not-leak"
[models.first]
api-name = "first-model"
max-context = 4096
tools-support = true
streaming = true
[models.second]
api-name = "second-model"
max-context = 8192
tools-support = true
streaming = true
[cloud.first]
wizard-default = true
[cloud.second]
|}
  in
  match Runtime_toml.parse_string config with
  | Error _ -> fail "inventory fixture parses"
  | Ok config ->
    List.iter
      (fun credential ->
         let private_config =
           { config with
             providers =
               List.map
                 (fun (p : Runtime_schema.provider) ->
                    { p with
                      credentials = Some credential
                    ; transport =
                        Runtime_schema.Http
                          "https://user:must-not-leak@example.com/v1?key=must-not-leak"
                    })
                 config.providers
           }
         in
         let projected =
           Runtime_wizard_inventory.to_json private_config |> Yojson.Safe.to_string
         in
         check
           bool
           "credential and URL secrets not serialized"
           false
           (contains projected "must-not-leak"))
      [ Runtime_schema.File "/private/must-not-leak"; Inline "must-not-leak" ];
    let json = Runtime_wizard_inventory.to_json config in
    let open Yojson.Safe.Util in
    let rows = json |> member "runtimes" |> to_list in
    check int "all bindings, not one per provider" 2 (List.length rows);
    List.iter
      (fun row ->
         check
           bool
           "inline secret not exposed"
           false
           (List.mem_assoc "api_key_env" (to_assoc row));
         check string "credential kind retained without value" "inline"
           (row |> member "credential_kind" |> to_string))
      rows;
    check
      bool
      "inline credential not serialized"
      false
      (contains (Yojson.Safe.to_string json) "must-not-leak");
    check
      (list string)
      "model identities"
      [ "first-model"; "second-model" ]
      (List.map (fun row -> row |> member "model" |> to_string) rows)
;;

let () =
  run
    "runtime verification"
    [ ( "readiness"
      , [ test_case "actual tool-result roundtrip" `Quick test_roundtrip
        ; test_case "no tool cannot claim ready" `Quick test_no_tool_cannot_claim_success
        ; test_case "tool result must be consumed" `Quick test_result_must_be_consumed
        ; test_case "missing observed model" `Quick test_missing_model_identity
        ; test_case "invalid input and errors" `Quick test_invalid_call_and_errors
        ; test_case
            "all configured model inventory"
            `Quick
            test_inventory_keeps_all_models_and_no_secrets
        ] )
    ]
;;
