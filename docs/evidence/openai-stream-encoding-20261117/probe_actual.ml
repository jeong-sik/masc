open Llm_provider
open Types

let config = Provider_config.make ~kind:OpenAI_compat ~model_id:"owned-stream-fixture"
  ~base_url:"https://example.invalid" ~request_path:"/v1/chat/completions"
  ~max_tokens:1024
  ~model_capabilities_override:{ Capabilities.openai_compat_chat_capabilities with
    max_output_tokens=Some 4096; supports_tools=true } ()

let error_result = function
  | Ok value -> Ok value
  | Error (Http_client.AcceptRejected { reason }) -> Error reason
  | Error (Http_client.HttpError _ | NetworkError _ | Connect_failed _ | TimeoutError _
          | ProviderTerminal _ | ProviderFailure _) -> failwith "unexpected nonserialization HTTP error"

let before_with_tools tools messages =
  Common_before.serialize_final_http_request_unadmitted ~stream:true ~config ~messages ~tools
  |> Result.map (fun (request : Common_before.serialized_http_request) ->
       request.body, request.output_token_receipt)
  |> error_result

let after_with_tools tools messages =
  Common_after.serialize_final_http_request_unadmitted ~stream:true ~config ~messages ~tools
  |> Result.map (fun (request : Common_after.serialized_http_request) ->
       request.body, request.output_token_receipt)
  |> error_result

let before = before_with_tools []
let after = after_with_tools []

let run operation messages =
  try operation messages with
  | Invalid_argument detail -> Error("Invalid_argument:"^detail)
  | Yojson.Json_error detail -> Error("Json_error:"^detail)

let equal left right = match left,right with
  | Ok(a,ra),Ok(b,rb) -> String.equal a b && equal_output_token_receipt ra rb
  | Error a,Error b -> String.equal a b
  | (Ok _,Error _) | (Error _,Ok _) -> false

let describe = function
  | Error detail -> `Assoc["error",`String detail]
  | Ok(body,receipt) -> `Assoc[
      "body_bytes",`Int(String.length body);
      "body_sha256",`String Agent_core_sha256.(to_hex(digest_string body));
      "output_token_receipt",output_token_receipt_to_yojson receipt]

let tool_message input =
  let message=assistant_msg "call" in
  {message with content=[ToolUse{id="owned-call";name="fixture";input=`Assoc["value",input]}]}

let measure operation messages =
  Gc.full_major();
  let a=Gc.allocated_bytes() and c=Sys.time() and w=Unix.gettimeofday() in
  for _=1 to 8 do match Sys.opaque_identity(run operation messages) with
    | Ok _ -> () | Error e -> failwith e done;
  let wall=Unix.gettimeofday()-.w and cpu=Sys.time()-.c and allocated=Gc.allocated_bytes()-.a in
  `Assoc["counter_allocated_bytes",`Float allocated;"process_cpu_seconds",`Float cpu;
    "wall_seconds",`Float wall;"repetitions",`Int 8]

let control_assertions = ref 0
let check label value = incr control_assertions; if not value then failwith label
let control_cases () =
  let cases = [Provider_config.OpenAI_compat,"/v1/chat/completions";
    OpenAI_compat,"/v1/responses"; Anthropic,"/v1/messages";
    Kimi,"/v1/messages"; Gemini,"/v1beta/models/m:generateContent";
    Ollama,"/api/chat"; Glm,"/v1/chat/completions"] in
  List.iter (fun(kind,request_path)->
    let config=Provider_config.make ~kind ~model_id:"receipt-completion" ~request_path
      ~base_url:"https://provider.invalid" ~max_tokens:200
      ~model_capabilities_override:{Capabilities.default_capabilities with max_output_tokens=Some 100} () in
    List.iter(fun stream->
      let messages=[system_msg "Goal: preserve authority order";user_msg "owned synthetic request"] in
      let b=Common_before.serialize_final_http_request_unadmitted ~stream ~config ~messages ~tools:[]
      and a=Common_after.serialize_final_http_request_unadmitted ~stream ~config ~messages ~tools:[] in
      match b,a with
      | Ok b,Ok a ->
        check "control wire bytes" (String.equal b.body a.body);
        check "control sealed digest" (String.equal b.body_sha256 a.body_sha256);
        check "digest from actual final bytes"
          (String.equal a.body_sha256 Agent_core_sha256.(to_hex(digest_string a.body)));
        check "control codec" (String.equal (Provider_http_codec.fingerprint_tag b.http_codec)
          (Provider_http_codec.fingerprint_tag a.http_codec));
        check "control output receipt" (equal_output_token_receipt b.output_token_receipt a.output_token_receipt)
      | (Error _,Ok _) | (Ok _,Error _) | (Error _,Error _) -> failwith "positive control did not serialize")
      [false;true])cases

let () =
  control_cases ();
  let adversarial=["null",`Null;"int",`Int 42;"float",`Float 1.25;
    "negative-zero",`Float(-0.);"nan",`Float nan;"infinity",`Float infinity;
    "large-intlit",`Intlit "999999999999999999999999999999999999999999999";
    "intlit-int",`Intlit "123";"intlit-leading-zero",`Intlit "00123";
    "intlit-exp",`Intlit "1e3";"intlit-decimal",`Intlit "1.0";
    "intlit-invalid",`Intlit "invalid";"intlit-empty",`Intlit "";
    "escaped-text",`String "quote\" slash\\ newline\n 한글";
    "nested",`List[`Assoc["a",`Intlit "1e3";"a",`Float(-0.)]]]
    |>List.concat_map(fun(label,value)->
      let tool=`Assoc["name",`String "fixture";"description",`String "synthetic";
        "input_schema",`Assoc["type",`String "object";"properties",`Assoc[];"default",value]] in
      let variants=["argument:"^label,[tool_message value],[];
        "schema:"^label,[user_msg "use fixture"],[tool]] in
      List.map(fun(label,messages,tools)->
        let b=run (before_with_tools tools) messages and a=run (after_with_tools tools) messages in
        let same=equal b a in check ("adversarial parity: "^label) same;
      `Assoc["case",`String label;"same",`Bool same;"before",describe b;"after",describe a]) variants) in
  let cases=List.map(fun size->
    let text=String.init size (fun i->"abc\"\\\n0123456789".[i mod 16]) in
    let messages=[user_msg text] in
    let b=run before messages and a=run after messages in
    check "normal request parity" (equal b a);
    let rounds=List.init 4(fun i->
      let b,a=if i mod 2=0 then let b=measure before messages in let a=measure after messages in b,a
        else let a=measure after messages in let b=measure before messages in b,a in
      `Assoc["before",b;"after",a]) in
    `Assoc["input_bytes",`Int size;"before",describe b;"same",`Bool true;"rounds",`List rounds]) [4096;262144] in
  let literal_fallback_cases=List.map(fun size->
    let tools=[`Assoc["name",`String "fixture";"description",`String "synthetic";
      "input_schema",`Assoc["type",`String "object";"properties",`Assoc[];"default",`Intlit "1e3"]]] in
    let messages=[user_msg (String.make size 'x')] in
    let before=before_with_tools tools and after=after_with_tools tools in
    let b=run before messages and a=run after messages in
    check "literal fallback exact parity" (equal b a);
    let rounds=List.init 4(fun i->
      let b,a=if i mod 2=0 then let b=measure before messages in let a=measure after messages in b,a
        else let a=measure after messages in let b=measure before messages in b,a in
      `Assoc["before",b;"after",a]) in
    `Assoc["input_bytes",`Int size;"before",describe b;"same",`Bool true;"rounds",`List rounds]) [4096;262144] in
  print_endline(Yojson.Safe.to_string(`Assoc[
    "assertions",`Int !control_assertions;"literal_fallback_cases",`List literal_fallback_cases;"adversarial",`List adversarial;"cases",`List cases;
    "scope",`String "Complete actual before/after Common modules and fresh actual streaming Core; prebuilt other dependencies; standalone, no HTTP/provider/runtime execution";
    "live_runtime_actions",`Bool false]))
