(* Live proof that an Anthropic catalog row reaches the Messages API and comes
   back whole.

   Not wired into any test alias: it needs ANTHROPIC_API_KEY and spends real
   money, the same shape as openrouter_live_proof. Run it after adding or
   changing an Anthropic row, naming the model the row covers:

     ANTHROPIC_LIVE=1 dune exec \
       packages/agent_core/test/anthropic_live_proof.exe -- claude-haiku-5-5

   What it settles that a unit test cannot: test_model_catalog_default reads
   the request body a row produces, so it proves what is sent. This sends it,
   so it proves the API accepts every shape the row allows -- each declared
   effort, thinking turned off, caller-set sampling parameters, forced tool
   use -- and that a signed thinking block the model returns replays through a
   tool turn. *)

module Provider_config = Llm_provider.Provider_config
module Model_catalog = Llm_provider.Model_catalog
module Reasoning_effort = Llm_provider.Reasoning_effort
module Http_client = Llm_provider.Http_client
module Types = Agent_core.Types

let default_model_id = "claude-haiku-5-5"

(* Thinking tokens count against max_tokens, so the budget leaves room for a
   thinking block at the highest effort and the text after it. *)
let max_tokens = 4000
let body_timeout_s = 180.0
let reasoning_prompt = "Work out 4177 * 3391 step by step, then state the product."
let lookup_code = "K7Q2"

let lookup_tool =
  `Assoc
    [ "name", `String "lookup"
    ; "description", `String "Return the code stored under a key."
    ; ( "input_schema"
      , `Assoc
          [ "type", `String "object"
          ; "properties", `Assoc [ "key", `Assoc [ "type", `String "string" ] ]
          ; "required", `List [ `String "key" ]
          ] )
    ]
;;

(* The key depends on a calculation, so the model has something to think about
   before the tool call; a bare "call the tool" request comes back with no
   thinking block and leaves replay unexercised. *)
let lookup_prompt =
  "Work out 4177 * 3391. Call the lookup tool with key \"odd\" if the product is odd \
   and \"even\" if it is even. Then reply with the code it returns and nothing else."
;;

(* "claude" is the catalog's [[providers]] entry for Anthropic's own API. It
   declares serves_bare_rows, which is what lets a config that names a provider
   read the claude-* rows; under any other label the row is not read and the
   run proves nothing about it. *)
let base_config ~api_key ~model_id =
  Provider_config.make
    ~kind:Provider_config.Anthropic
    ~provider_id:"claude"
    ~model_id
    ~base_url:"https://api.anthropic.com"
    ~api_key
    ~request_path:"/v1/messages"
    ~headers:[ "Content-Type", "application/json"; "anthropic-version", "2023-06-01" ]
    ~max_tokens
    ()
;;

type seen =
  { text : string
  ; thinking_blocks : int
  ; signed_thinking_blocks : int
  ; tool_use_ids : string list
  }

let seen_of_blocks blocks =
  List.fold_left
    (fun seen block ->
       match (block : Types.content_block) with
       | Types.Text s -> { seen with text = seen.text ^ s }
       | Types.Thinking { signature; _ } ->
         { seen with
           thinking_blocks = seen.thinking_blocks + 1
         ; signed_thinking_blocks =
             (seen.signed_thinking_blocks + if Option.is_some signature then 1 else 0)
         }
       | Types.RedactedThinking _ ->
         { seen with thinking_blocks = seen.thinking_blocks + 1 }
       | Types.ToolUse { id; _ } -> { seen with tool_use_ids = seen.tool_use_ids @ [ id ] }
       | Types.ReasoningDetails _
       | Types.ToolResult _
       | Types.Image _
       | Types.Document _
       | Types.Audio _ -> seen)
    { text = ""; thinking_blocks = 0; signed_thinking_blocks = 0; tool_use_ids = [] }
    blocks
;;

let describe_error (e : Http_client.http_error) =
  match e with
  | Http_client.HttpError { code; body; _ } ->
    Printf.sprintf "HTTP %d: %s" code (Http_client.refusal_body_text body)
  | Http_client.NetworkError { message; _ } -> "network: " ^ message
  | Http_client.TimeoutError { message; _ } -> "timeout: " ^ message
  | Http_client.AcceptRejected { reason } -> "refused before dispatch: " ^ reason
  | Http_client.ProviderTerminal { message; _ } -> "provider terminal: " ^ message
  | Http_client.ProviderFailure { message; _ } -> "provider failure: " ^ message
;;

let describe_response (response : Types.api_response) =
  let seen = seen_of_blocks response.content in
  let usage =
    match response.usage with
    | None -> "usage unreported"
    | Some u ->
      Printf.sprintf
        "in=%d out=%d cost=%s"
        u.input_tokens
        u.output_tokens
        (match u.cost_usd with
         | Some cost -> Printf.sprintf "$%.6f" cost
         | None -> "unknown")
  in
  Printf.sprintf
    "stop=%s thinking=%d signed=%d tool_use=%d text_chars=%d %s"
    (Types.stop_reason_to_string response.stop_reason)
    seen.thinking_blocks
    seen.signed_thinking_blocks
    (List.length seen.tool_use_ids)
    (String.length (String.trim seen.text))
    usage
;;

let failed = ref false

let fail label detail =
  failed := true;
  Printf.printf "FAIL  %s: %s\n%!" label detail
;;

let pass label detail = Printf.printf "ok    %s: %s\n%!" label detail
let warn label detail = Printf.printf "WARN  %s: %s\n%!" label detail

let () =
  if Sys.getenv_opt "ANTHROPIC_LIVE" <> Some "1"
  then (
    print_endline "skipped: set ANTHROPIC_LIVE=1 to run this live proof";
    exit 0);
  let api_key =
    match Sys.getenv_opt "ANTHROPIC_API_KEY" with
    | Some key when String.trim key <> "" -> key
    | Some _ | None ->
      prerr_endline "ANTHROPIC_API_KEY is unset";
      exit 1
  in
  let model_id = if Array.length Sys.argv > 1 then Sys.argv.(1) else default_model_id in
  (match Model_catalog.load_default () with
   | Ok catalog -> Model_catalog.set_global catalog
   | Error detail ->
     Printf.eprintf "embedded catalog unavailable: %s\n" detail;
     exit 1);
  let config = base_config ~api_key ~model_id in
  let caps =
    match Provider_config.capabilities_for_config_model config with
    | None ->
      Printf.eprintf "no capabilities resolved for %s\n" model_id;
      exit 1
    | Some caps -> caps
  in
  let efforts = Option.value caps.accepted_reasoning_efforts ~default:[] in
  Printf.printf
    "model: %s, declared efforts: [%s]\n%!"
    model_id
    (String.concat "; " (List.map Reasoning_effort.to_string efforts));
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let sync ?tools ~config messages =
    Llm_provider.Complete.complete
      ~sw
      ~net
      ~clock
      ~body_timeout_s
      ~config
      ~messages
      ?tools
      ()
  in
  let stream ?tools ~config messages =
    Llm_provider.Complete.complete_stream
      ~sw
      ~net
      ~clock
      ~body_timeout_s
      ~config
      ~messages
      ?tools
      ~on_event:(fun _ -> ())
      ()
  in
  let thinking_on = { config with Provider_config.enable_thinking = Some true } in
  (* Thinking on, at the row's default effort and through the sync path. Its
     thinking block count is what the thinking-off case is read against. *)
  let default_thinking_blocks =
    match sync ~config:thinking_on [ Types.user_msg reasoning_prompt ] with
    | Error e ->
      fail "thinking on, default effort (sync)" (describe_error e);
      0
    | Ok response ->
      pass "thinking on, default effort (sync)" (describe_response response);
      (seen_of_blocks response.content).thinking_blocks
  in
  (* Every effort the row declares must be one the API accepts. *)
  List.iter
    (fun effort ->
       let label = Printf.sprintf "effort %s (stream)" (Reasoning_effort.to_string effort) in
       match
         stream
           ~config:{ thinking_on with Provider_config.reasoning_effort = Some effort }
           [ Types.user_msg reasoning_prompt ]
       with
       | Error e -> fail label (describe_error e)
       | Ok response -> pass label (describe_response response))
    efforts;
  (* A request that turns thinking off must either be refused here or come
     back without a thinking block. A row whose control sends nothing for
     that request lets the API keep thinking on, and this is where it shows. *)
  (let label = "thinking off (sync)" in
   match
     sync
       ~config:{ config with Provider_config.enable_thinking = Some false }
       [ Types.user_msg reasoning_prompt ]
   with
   | Error (Http_client.AcceptRejected { reason }) ->
     pass label ("refused before dispatch: " ^ reason)
   | Error e -> fail label (describe_error e)
   | Ok response ->
     let seen = seen_of_blocks response.content in
     if seen.thinking_blocks > 0
     then fail label ("thinking stayed on: " ^ describe_response response)
     else (
       pass label (describe_response response);
       if default_thinking_blocks = 0
       then
         warn
           label
           "the thinking-on request returned no thinking block either, so this did \
            not show the switch taking effect"));
  (* Sampling parameters a caller sets must not turn into an API refusal: the
     row either lets them through because the model accepts them or drops
     them because it does not. *)
  (let label = "caller-set temperature, top_p and top_k (sync)" in
   match
     sync
       ~config:
         { config with
           Provider_config.temperature = Some 0.2
         ; top_p = Some 0.9
         ; top_k = Some 40
         }
       [ Types.user_msg "Reply with the single word: ok." ]
   with
   | Error e -> fail label (describe_error e)
   | Ok response -> pass label (describe_response response));
  (* Forced tool use. A row that offers it must have it accepted, and a row
     that does not must stop the request here: the API answers 400 to it on
     the models that dropped it. Thinking is left unset because the backend
     refuses a forced choice on a request that also turns thinking on. *)
  (let label = "forced tool_choice (sync)" in
   match
     sync
       ~tools:[ lookup_tool ]
       ~config:{ config with Provider_config.tool_choice = Some Types.Any }
       [ Types.user_msg lookup_prompt ]
   with
   | Error (Http_client.AcceptRejected { reason })
     when not caps.supports_required_tool_choice ->
     pass label ("refused before dispatch: " ^ reason)
   | Error e -> fail label (describe_error e)
   | Ok response ->
     if (seen_of_blocks response.content).tool_use_ids = []
     then fail label ("no tool call came back: " ^ describe_response response)
     else pass label (describe_response response));
  (* Tool turn at the highest declared effort: the assistant turn, thinking
     block included, goes back with the tool result. *)
  let tool_config =
    match List.rev efforts with
    | highest :: _ -> { thinking_on with Provider_config.reasoning_effort = Some highest }
    | [] -> thinking_on
  in
  let label = "tool round trip (stream)" in
  let question = Types.user_msg lookup_prompt in
  (match stream ~tools:[ lookup_tool ] ~config:tool_config [ question ] with
   | Error e -> fail label ("first turn: " ^ describe_error e)
   | Ok first ->
     let seen = seen_of_blocks first.content in
     Printf.printf "      first turn: %s\n%!" (describe_response first);
     (match seen.tool_use_ids, Types.assistant_message_of_response first with
      | [], _ -> fail label "the model did not call the tool"
      | _ :: _, Error e ->
        fail label ("assistant turn not replayable: " ^ Types.show_assistant_message_error e)
      | tool_use_id :: _, Ok assistant ->
        let result =
          Types.tool_result_msg
            ~tool_use_id
            ~content:(Printf.sprintf {|{"code":"%s"}|} lookup_code)
            ()
        in
        (match
           stream ~tools:[ lookup_tool ] ~config:tool_config [ question; assistant; result ]
         with
         | Error e -> fail label ("second turn: " ^ describe_error e)
         | Ok second ->
           let text = (seen_of_blocks second.content).text in
           if not (Re.execp (Re.compile (Re.str lookup_code)) text)
           then fail label ("second turn did not return the code: " ^ String.trim text)
           else (
             pass label (describe_response second);
             if seen.signed_thinking_blocks = 0
             then
               warn
                 label
                 "the first turn carried no signed thinking block, so replay was not \
                  exercised"))));
  if !failed
  then (
    print_endline "FAIL: at least one request shape the row allows did not come back whole";
    exit 1);
  print_endline "PASS: every request shape the row allows came back whole"
;;
