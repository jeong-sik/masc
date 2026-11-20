(* Live proof for RFC-a-request-part-sits-where-its-change-rate-fits §3.3.
   Not wired into a test alias: it needs ANTHROPIC_API_KEY and spends real money.

     ANTHROPIC_LIVE=1 dune exec \
       packages/agent_core/test/anthropic_tool_search_live_proof.exe -- claude-haiku-5-5

   The first response is forced to call a custom search tool. Its result contains
   only a typed tool_reference. The second request repeats the exact tool array
   and forces the referenced lookup. A passing run prints cache-read usage for
   the second response and never prints credentials or provider response text. *)

module Provider_config = Llm_provider.Provider_config
module Types = Llm_provider.Types
module Http_client = Llm_provider.Http_client

let default_model_id = "claude-haiku-5-5"
let body_timeout_s = 180.0

let search_tool =
  `Assoc
    [ "name", `String "keeper_tool_search"
    ; "description", `String "Find a tool by exact name and make it callable."
    ; ( "input_schema"
      , `Assoc
          [ "type", `String "object"
          ; "properties", `Assoc [ "names", `Assoc [ "type", `String "array"; "items", `Assoc [ "type", `String "string" ] ] ]
          ; "required", `List [ `String "names" ]
          ] )
    ]
;;

let lookup_tool =
  `Assoc
    [ "name", `String "lookup"
    ; "description", `String "Return the code stored under a key."
    ; "defer_loading", `Bool true
    ; ( "input_schema"
      , `Assoc
          [ "type", `String "object"
          ; "properties", `Assoc [ "key", `Assoc [ "type", `String "string" ] ]
          ; "required", `List [ `String "key" ]
          ] )
    ]
;;

let tools = [ search_tool; lookup_tool ]

let stable_system_prompt =
  List.init 180 (fun index ->
    Printf.sprintf
      "Stable instruction %d: keep this line unchanged across both requests so the prompt prefix remains cacheable."
      index)
  |> String.concat "\n"
;;

let base_config ~api_key ~model_id =
  Provider_config.make
    ~kind:Provider_config.Anthropic
    ~provider_id:"claude"
    ~model_id
    ~base_url:"https://api.anthropic.com"
    ~api_key
    ~request_path:"/v1/messages"
    ~headers:[ "Content-Type", "application/json"; "anthropic-version", "2023-06-01" ]
    ~system_prompt:stable_system_prompt
    ~cache_system_prompt:true
    ~max_tokens:512
    ()
;;

let describe_error (error : Http_client.http_error) =
  match error with
  | Http_client.HttpError { code; _ } -> Printf.sprintf "HTTP %d" code
  | Http_client.NetworkError _ -> "network error"
  | Http_client.Connect_failed _ -> "connection failed"
  | Http_client.TimeoutError _ -> "timeout"
  | Http_client.AcceptRejected { reason } -> "refused before dispatch: " ^ reason
  | Http_client.ProviderTerminal { message } -> "provider terminal: " ^ message
  | Http_client.ProviderFailure { message } -> "provider failure: " ^ message
;;

let fail label detail =
  Printf.eprintf "FAIL %s: %s\n%!" label detail;
  exit 1
;;

let tool_calls content =
  List.filter_map
    (function
      | Types.ToolUse { id; name; input } -> Some (id, name, input)
      | _ -> None)
    content
;;

let require_call label content =
  match tool_calls content with
  | [ call ] -> call
  | [] -> fail label "provider returned no tool call"
  | _ :: _ -> fail label "provider returned multiple tool calls"
;;

let cache_read (response : Types.api_response) =
  match response.usage with
  | Some usage -> usage.cache_read_input_tokens
  | None -> 0
;;

let print_usage label (response : Types.api_response) =
  match response.usage with
  | Some usage ->
    Printf.printf
      "%s: input=%d cache_creation=%d cache_read=%d output=%d\n%!"
      label
      usage.input_tokens
      usage.cache_creation_input_tokens
      usage.cache_read_input_tokens
      usage.output_tokens
  | None -> Printf.printf "%s: usage unreported\n%!" label
;;

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
  (match Llm_provider.Model_catalog.load_default () with
   | Ok catalog ->
     Llm_provider.Catalog_snapshot.publish
       (Agent_core_test_deps.admit_catalogs ~models:(Some catalog) ~providers:None)
   | Error detail -> fail "catalog" detail);
  let config = base_config ~api_key ~model_id in
  if not (Provider_config.supports_deferred_tool_loading config)
  then fail "capability" (model_id ^ " does not declare deferred tool loading");
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let complete ~config messages =
    (Llm_provider.Complete.complete
       ~sw
       ~net
       ~clock
       ~body_timeout_s
       ~config
       ~messages
       ~tools
       ()).Llm_provider.Completion_outcome.result
  in
  let question = Types.user_msg "Find the lookup tool." in
  let first_config = { config with Provider_config.tool_choice = Some (Types.Tool "keeper_tool_search") } in
  (match complete ~config:first_config [ question ] with
   | Error error -> fail "search request" (describe_error error)
   | Ok first ->
     print_usage "search" first;
     let search_id, search_name, _ = require_call "search request" first.content in
     if not (String.equal search_name "keeper_tool_search")
     then fail "search request" ("unexpected tool: " ^ search_name);
     (match Types.assistant_message_of_response first with
      | Error error -> fail "assistant replay" (Types.show_assistant_message_error error)
      | Ok assistant ->
        let reference_result : Types.message =
          { origin = Types.Conversation
          ; role = Types.Tool
          ; content =
              [ Types.ToolResult
                  { tool_use_id = search_id
                  ; content = "now callable:\n- lookup"
                  ; outcome = Types.Tool_succeeded
                  ; json = None
                  ; content_blocks = Some [ Types.ToolReference { tool_name = "lookup" } ]
                  }
              ]
          ; name = None
          ; tool_call_id = None
          ; metadata = []
          }
        in
        let second_config = { config with Provider_config.tool_choice = Some (Types.Tool "lookup") } in
        match complete ~config:second_config [ question; assistant; reference_result ] with
        | Error error -> fail "referenced request" (describe_error error)
        | Ok second ->
          print_usage "referenced" second;
          let _, called_name, _ = require_call "referenced request" second.content in
          if not (String.equal called_name "lookup")
          then fail "referenced request" ("unexpected tool: " ^ called_name);
          if cache_read second <= 0
          then fail "cache" "the referenced request read no cached input tokens";
          Printf.printf "PASS: tool_reference expanded and the second request read cached input\n%!"))
;;
