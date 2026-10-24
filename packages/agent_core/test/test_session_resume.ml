open Agent_core

(* ── Test helpers ────────────────────────────────────────────── *)

let make_checkpoint
      ?(provider_binding = None)
      ?(session_id = "sess-original")
      ?(agent_name = "test-agent")
      ?(model = "claude-sonnet-5")
      ?(system_prompt = Some "You are helpful.")
      ?(messages = [])
      ?(usage = Types.empty_usage)
      ?(turn_count = 0)
      ?(created_at = 1000.0)
      ?(tools = [])
      ?(tool_choice = None)
      ?(context = Context.create_sync ())
      ?(enable_thinking = None)
      ?(preserve_thinking = None)
      ?(reasoning_effort = None)
      ()
  : Checkpoint.t
  =
  { provider_binding; version = Checkpoint.checkpoint_version
  ; session_id
  ; agent_name
  ; model
  ; system_prompt
  ; messages
  ; usage
  ; turn_count
  ; created_at
  ; tools
  ; tool_choice
  ; disable_parallel_tool_use = false
  ; temperature = None
  ; top_p = None
  ; top_k = None
  ; min_p = None
  ; enable_thinking
  ; preserve_thinking
  ; response_format = Types.Off
  ; reasoning_effort
  ; cache_system_prompt = false
  ; context
  ; pending_input = None; mcp_sessions = []
  ; working_context = None
  }
;;

let sample_messages =
  [ { origin = Llm_provider.Types.Conversation;  Types.role = Types.User
    ; content = [ Types.Text "Hello" ]
    ; name = None
    ; tool_call_id = None
    ; metadata = []
    }
  ; { origin = Llm_provider.Types.Conversation;  Types.role = Types.Assistant
    ; content = [ Types.Text "Hi there." ]
    ; name = None
    ; tool_call_id = None
    ; metadata = []
    }
  ; { origin = Llm_provider.Types.Conversation;  Types.role = Types.User
    ; content = [ Types.Text "What is 2+2?" ]
    ; name = None
    ; tool_call_id = None
    ; metadata = []
    }
  ; { origin = Llm_provider.Types.Conversation;  Types.role = Types.Assistant
    ; content = [ Types.Text "4" ]
    ; name = None
    ; tool_call_id = None
    ; metadata = []
    }
  ]
;;

let sample_usage : Types.usage_stats =
  { total_input_tokens = 150
  ; total_output_tokens = 80
  ; total_cache_creation_input_tokens = 20
  ; total_cache_read_input_tokens = 10
  ; api_calls = 3
  ; missing_usage_responses = 1
  ; estimated_cost_usd = 0.0
  ; pricing_gap = Some Types.Usage_not_reported
  }
;;

let sample_tool_schema : Types.tool_schema =
  Types.tool_schema_of_params
    ~name:"get_weather"
    ~description:"Get weather for a location"
    ~parameters:
      [ { Types.name = "location"
        ; description = "City name"
        ; param_type = Types.String
        ; required = true
        }
      ]
    ()
;;

(* ── Session.resume_from tests ───────────────────────────────── *)

let test_resume_from_generates_new_id () =
  let cp = make_checkpoint ~session_id:"orig-123" () in
  let s = Session.resume_from cp in
  Alcotest.(check bool) "new id is not original" true (s.id <> "orig-123");
  Alcotest.(check bool)
    "starts with session-"
    true
    (String.length s.id > 8 && String.sub s.id 0 8 = "session-")
;;

let test_resume_from_links_session_id () =
  let cp = make_checkpoint ~session_id:"orig-456" () in
  let s = Session.resume_from cp in
  Alcotest.(check (option string)) "resumed_from" (Some "orig-456") s.resumed_from
;;

let test_resume_from_carries_turn_count () =
  let cp = make_checkpoint ~turn_count:7 () in
  let s = Session.resume_from cp in
  Alcotest.(check int) "turn_count" 7 s.turn_count
;;

let test_resume_from_fresh_timestamps () =
  let cp = make_checkpoint ~created_at:1000.0 () in
  let s = Session.resume_from cp in
  Alcotest.(check bool) "started_at is recent" true (s.started_at > 1000.0);
  Alcotest.(check bool) "last_active_at is recent" true (s.last_active_at > 1000.0)
;;

let test_resume_from_cwd_is_none () =
  let cp = make_checkpoint () in
  let s = Session.resume_from cp in
  Alcotest.(check (option string)) "cwd" None s.cwd
;;

let test_resume_from_fresh_metadata () =
  let cp = make_checkpoint () in
  let s = Session.resume_from cp in
  Alcotest.(check (option string))
    "no keys"
    None
    (match Context.get s.metadata "anything" with
     | Some (`String v) -> Some v
     | _ -> None)
;;

let test_resume_from_copies_checkpoint_context () =
  let ctx = Context.create_sync () in
  Context.set_scoped ctx Context.Session "trace_id" (`String "abc");
  let cp = make_checkpoint ~context:ctx () in
  let s = Session.resume_from cp in
  Alcotest.(check bool)
    "metadata copied"
    true
    (Context.get_scoped s.metadata Context.Session "trace_id" = Some (`String "abc"))
;;

let test_resume_from_zero_turn_checkpoint () =
  let cp = make_checkpoint ~turn_count:0 ~messages:[] () in
  let s = Session.resume_from cp in
  Alcotest.(check int) "turn_count" 0 s.turn_count;
  Alcotest.(check (option string)) "resumed_from" (Some "sess-original") s.resumed_from
;;

let test_resume_from_unique_ids () =
  let cp = make_checkpoint () in
  let s1 = Session.resume_from cp in
  let s2 = Session.resume_from cp in
  Alcotest.(check bool) "different ids" true (s1.id <> s2.id)
;;

let test_resume_from_empty_session_id () =
  let cp = make_checkpoint ~session_id:"" () in
  let s = Session.resume_from cp in
  Alcotest.(check (option string)) "empty session_id yields None" None s.resumed_from
;;

(* ── Agent.resume tests ──────────────────────────────────────── *)

let with_net f =
  Eio_main.run
  @@ fun env ->
  let net = Eio.Stdenv.net env in
  f net
;;

let test_resume_restores_messages () =
  with_net
  @@ fun net ->
  let cp = make_checkpoint ~messages:sample_messages () in
  let agent = (Agent.resume ~net ~checkpoint:cp () |> Result.get_ok) in
  Alcotest.(check int) "message count" 4 (List.length (Agent.state agent).messages)
;;

let test_resume_restores_context () =
  with_net
  @@ fun net ->
  let ctx = Context.create_sync () in
  Context.set_scoped ctx Context.User "theme" (`String "dark");
  let cp = make_checkpoint ~context:ctx () in
  let agent = (Agent.resume ~net ~checkpoint:cp () |> Result.get_ok) in
  Alcotest.(check bool)
    "context restored"
    true
    (Context.get_scoped (Agent.context agent) Context.User "theme" = Some (`String "dark"))
;;

let test_resume_restores_usage () =
  with_net
  @@ fun net ->
  let cp = make_checkpoint ~usage:sample_usage () in
  let agent = (Agent.resume ~net ~checkpoint:cp () |> Result.get_ok) in
  Alcotest.(check int) "input_tokens" 150 (Agent.state agent).usage.total_input_tokens;
  Alcotest.(check int) "output_tokens" 80 (Agent.state agent).usage.total_output_tokens;
  Alcotest.(check int) "api_calls" 3 (Agent.state agent).usage.api_calls;
  Alcotest.(check int) "missing usage survives resume" 1
    (Agent.state agent).usage.missing_usage_responses
;;

let test_resume_restores_turn_count () =
  with_net
  @@ fun net ->
  let cp = make_checkpoint ~turn_count:5 () in
  let agent = (Agent.resume ~net ~checkpoint:cp () |> Result.get_ok) in
  Alcotest.(check int) "turn_count" 5 (Agent.state agent).turn_count
;;

let test_resume_restores_model () =
  with_net
  @@ fun net ->
  let cp = make_checkpoint ~model:"claude-opus-5-5" () in
  let agent = (Agent.resume ~net ~checkpoint:cp () |> Result.get_ok) in
  Alcotest.(check string) "model" "claude-opus-5-5" (Agent.state agent).config.model
;;

let test_resume_restores_agent_name () =
  with_net
  @@ fun net ->
  let cp = make_checkpoint ~agent_name:"my-agent" () in
  let agent = (Agent.resume ~net ~checkpoint:cp () |> Result.get_ok) in
  Alcotest.(check string) "name" "my-agent" (Agent.state agent).config.name
;;

let test_resume_restores_system_prompt () =
  with_net
  @@ fun net ->
  let cp = make_checkpoint ~system_prompt:(Some "Be concise.") () in
  let agent = (Agent.resume ~net ~checkpoint:cp () |> Result.get_ok) in
  Alcotest.(check (option string))
    "system_prompt"
    (Some "Be concise.")
    (Agent.state agent).config.system_prompt
;;

let test_resume_restores_tool_choice () =
  with_net
  @@ fun net ->
  let cp = make_checkpoint ~tool_choice:(Some Types.Any) () in
  let agent = (Agent.resume ~net ~checkpoint:cp () |> Result.get_ok) in
  let tc_str =
    match (Agent.state agent).config.tool_choice with
    | Some Types.Any -> "any"
    | Some Types.Auto -> "auto"
    | Some (Types.Tool n) -> "tool:" ^ n
    | Some Types.None_ -> "none_"
    | None -> "none"
  in
  Alcotest.(check string) "tool_choice" "any" tc_str
;;

let test_resume_none_system_prompt () =
  with_net
  @@ fun net ->
  let cp = make_checkpoint ~system_prompt:None () in
  let agent = (Agent.resume ~net ~checkpoint:cp () |> Result.get_ok) in
  Alcotest.(check (option string))
    "system_prompt"
    None
    (Agent.state agent).config.system_prompt
;;

let test_resume_with_tools () =
  with_net
  @@ fun net ->
  let tool =
    Tool.create ~name:"echo" ~description:"Echo input" ~parameters:[] (fun input ->
      Ok { Types.content = Yojson.Safe.to_string input; content_blocks = None; _meta = None })
  in
  let cp = make_checkpoint () in
  let agent = (Agent.resume ~net ~checkpoint:cp ~tools:[ tool ] () |> Result.get_ok) in
  Alcotest.(check int) "tool count" 1 (Tool_set.size (Agent.tools agent))
;;

let test_resume_default_options () =
  with_net
  @@ fun net ->
  let cp = make_checkpoint () in
  let agent = (Agent.resume ~net ~checkpoint:cp () |> Result.get_ok) in
  Alcotest.(check bool)
    "no provider config"
    true
    (Option.is_none (Agent.options agent).provider_config)
;;

let test_resume_custom_options () =
  with_net
  @@ fun net ->
  let cp = make_checkpoint () in
  let provider_config =
    Provider_mock.local_provider_config
      ~base_url:"http://localhost:8080"
      ~model_id:"resume-model"
      ~request_path:"/v1/chat/completions"
      ()
  in
  let opts = { Agent.default_options with provider_config = Some provider_config } in
  let agent = (Agent.resume ~net ~checkpoint:cp ~options:opts () |> Result.get_ok) in
  Alcotest.(check string)
    "custom provider endpoint"
    "http://localhost:8080"
    (Option.get (Agent.options agent).provider_config).base_url
;;

let test_resume_with_config_override () =
  with_net
  @@ fun net ->
  let cp =
    make_checkpoint
      ~agent_name:"cp-name"
      ~enable_thinking:(Some true)
      ~preserve_thinking:(Some true)
      ()
  in
  let cfg =
    { (Types.default_config ~model:"test-model") with
      name = "current-agent"
    ; system_prompt = Some "current runtime prompt"
    ; max_tokens = Some 8192
    ; enable_thinking = Some false
    ; preserve_thinking = Some false
    }
  in
  let agent = (Agent.resume ~net ~checkpoint:cp ~config:cfg () |> Result.get_ok) in
  Alcotest.(check string)
    "exact caller config"
    (Types.show_agent_config cfg)
    (Types.show_agent_config (Agent.state agent).config);
  Alcotest.(check string)
    "name from caller config"
    "current-agent"
    (Agent.state agent).config.name;
  Alcotest.(check string)
    "model from caller config"
    "test-model"
    (Agent.state agent).config.model;
  Alcotest.(check (option string))
    "system prompt from caller config"
    (Some "current runtime prompt")
    (Agent.state agent).config.system_prompt;
  Alcotest.(check (option int))
    "max_tokens from config"
    (Some 8192)
    (Agent.state agent).config.max_tokens;
  Alcotest.(check (option bool))
    "enable_thinking from config"
    (Some false)
    (Agent.state agent).config.enable_thinking;
  Alcotest.(check (option bool))
    "preserve_thinking from config"
    (Some false)
    (Agent.state agent).config.preserve_thinking
;;

let test_resume_empty_checkpoint () =
  with_net
  @@ fun net ->
  let cp = make_checkpoint ~messages:[] ~usage:Types.empty_usage ~turn_count:0 () in
  let agent = (Agent.resume ~net ~checkpoint:cp () |> Result.get_ok) in
  Alcotest.(check int) "messages" 0 (List.length (Agent.state agent).messages);
  Alcotest.(check int) "turn_count" 0 (Agent.state agent).turn_count;
  Alcotest.(check int) "api_calls" 0 (Agent.state agent).usage.api_calls
;;

let test_resume_preserves_message_content () =
  with_net
  @@ fun net ->
  let msgs =
    [ { origin = Llm_provider.Types.Conversation;  Types.role = Types.User
      ; content = [ Types.Text "Hello"; Types.Text "World" ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ]
  in
  let cp = make_checkpoint ~messages:msgs () in
  let agent = (Agent.resume ~net ~checkpoint:cp () |> Result.get_ok) in
  let first_msg = List.hd (Agent.state agent).messages in
  Alcotest.(check int) "content blocks" 2 (List.length first_msg.content);
  let first_text =
    match List.hd first_msg.content with
    | Types.Text s -> s
    | _ -> "not text"
  in
  Alcotest.(check string) "first text" "Hello" first_text
;;

(* ── Checkpoint → resume roundtrip ───────────────────────────── *)

let test_checkpoint_resume_roundtrip () =
  with_net
  @@ fun net ->
  let cp =
    make_checkpoint
      ~session_id:"rt-sess"
      ~agent_name:"rt-agent"
      ~model:"claude-opus-5-5"
      ~system_prompt:(Some "Be brief.")
      ~messages:sample_messages
      ~usage:sample_usage
      ~turn_count:4
      ~tools:[ sample_tool_schema ]
      ~tool_choice:(Some (Types.Tool "get_weather"))
      ()
  in
  let json_str = Checkpoint.to_string cp in
  let cp2 = Result.get_ok (Checkpoint.of_string json_str) in
  let agent = (Agent.resume ~net ~checkpoint:cp2 () |> Result.get_ok) in
  Alcotest.(check string) "agent_name" "rt-agent" (Agent.state agent).config.name;
  Alcotest.(check int) "messages" 4 (List.length (Agent.state agent).messages);
  Alcotest.(check int) "turn_count" 4 (Agent.state agent).turn_count;
  Alcotest.(check int) "input_tokens" 150 (Agent.state agent).usage.total_input_tokens
;;

let test_session_resume_from_then_record () =
  let cp = make_checkpoint ~turn_count:3 () in
  let s = Session.resume_from cp in
  let s = Session.record_turn s in
  let s = Session.record_turn s in
  Alcotest.(check int) "turn_count after 2 more" 5 s.turn_count
;;

let test_resume_cache_tokens () =
  with_net
  @@ fun net ->
  let usage : Types.usage_stats =
    { total_input_tokens = 100
    ; total_output_tokens = 50
    ; total_cache_creation_input_tokens = 30
    ; total_cache_read_input_tokens = 25
    ; api_calls = 2
    ; missing_usage_responses = 0
    ; estimated_cost_usd = 0.0
    ; pricing_gap = None
    }
  in
  let cp = make_checkpoint ~usage () in
  let agent = (Agent.resume ~net ~checkpoint:cp () |> Result.get_ok) in
  Alcotest.(check int)
    "cache_creation"
    30
    (Agent.state agent).usage.total_cache_creation_input_tokens;
  Alcotest.(check int)
    "cache_read"
    25
    (Agent.state agent).usage.total_cache_read_input_tokens
;;

let test_resume_custom_model () =
  with_net
  @@ fun net ->
  let cp = make_checkpoint ~model:"my-local-model" () in
  let agent = (Agent.resume ~net ~checkpoint:cp () |> Result.get_ok) in
  Alcotest.(check string) "custom model" "my-local-model" (Agent.state agent).config.model
;;

module Binding_source = Llm_provider.Types.Reasoning_source
module Binding_projection = Llm_provider.Reasoning_history_projection
module Binding_provider = Llm_provider.Provider_config

let binding_provider ?(kind=Binding_provider.OpenAI_compat) ?(path="/chat")
    ?(model="shared-model") endpoint =
  let caps = Llm_provider.Capabilities.{openai_compat_chat_capabilities with
    supports_reasoning=true; reasoning_replay_override=Force_preserve_always} in
  Binding_provider.make ~kind ~model_id:model ~base_url:endpoint ~request_path:path
    ~model_capabilities_override:caps ()
;;
let binding_source provider =
  Llm_provider.Reasoning_dialect.reasoning_source_for_provider_config provider |> Result.get_ok
;;
let binding_message source =
  { (Types.assistant_msg "answer") with
    content=[Types.Thinking {content="reasoning";signature=None};Types.Text "answer"];
    metadata=Binding_source.metadata source }
;;
let binding_checkpoint provider messages =
  make_checkpoint ~model:provider.Binding_provider.model_id
    ~provider_binding:(Some(binding_source provider)) ~messages ()
;;
let binding_options provider = {Agent.default_options with provider_config=Some provider}
let binding_resume_ok = function
  | Ok value -> value
  | Error error -> Alcotest.fail(Agent_checkpoint.resume_error_to_string error)
let expect_binding_incompatible = function
  | Error (Agent_checkpoint.Replay_rejected
      (Binding_projection.Incompatible_resume_reasoning_source {message_index;_})) -> message_index
  | Error error -> Alcotest.fail(Agent_checkpoint.resume_error_to_string error)
  | Ok _ -> Alcotest.fail "incompatible reasoning was admitted"
;;
let test_binding_exact_resume () = with_net (fun net ->
  let provider=binding_provider "https://same.example" in
  let source=binding_source provider in
  let cp=binding_checkpoint provider [binding_message source] in
  let before=Checkpoint.to_json cp in
  let agent=Agent.resume ~net ~checkpoint:cp ~options:(binding_options provider) () |> binding_resume_ok in
  Alcotest.(check bool) "canonical history retained without projection" true
    ((Agent.state agent).messages == cp.messages);
  Alcotest.(check bool) "last producer remains recorded" true
    (match (Agent.state agent).provider_binding with Some actual -> Binding_source.equal source actual | None -> false);
  let admitted=Agent.provider_config agent |> Option.get in
  Alcotest.(check bool) "admitted carrier is request-frozen" true (admitted.request_policy_snapshot<>None);
  Alcotest.(check bool) "source checkpoint not mutated" true (before=Checkpoint.to_json cp);
  Agent.close agent)
;;
let test_binding_provider_model_and_contract_mismatch () = with_net (fun net ->
  let original=binding_provider "https://same.example" in
  let cp=binding_checkpoint original [binding_message(binding_source original)] in
  let no_replay={original with Binding_provider.model_capabilities_override=Some
    Llm_provider.Capabilities.{openai_compat_chat_capabilities with reasoning_replay_override=Force_drop}} in
  let targets=[binding_provider ~kind:Binding_provider.Kimi "https://same.example";
    binding_provider ~model:"other-model" "https://same.example";no_replay] in
  List.iter(fun target ->
    let config=Types.default_config ~model:target.Binding_provider.model_id in
    let result=Agent.resume ~net ~checkpoint:cp ~config ~options:(binding_options target) () in
    Alcotest.(check int) "kind/model/contract cannot silently discard replay" 0
      (expect_binding_incompatible result)) targets)
;;
let test_binding_declared_rotation () = with_net (fun net ->
  let original=binding_provider "https://original.example" in
  let source=binding_source original in
  let cp=binding_checkpoint original [binding_message source] in
  List.iter(fun target ->
    let plan=Agent_checkpoint.build_resume ~checkpoint:cp ~provider_config:target () |> binding_resume_ok in
    Alcotest.(check bool) "declared text endpoint/path rotation admitted" true
      (plan.binding_disposition=Agent_checkpoint.Declared_endpoint_rotation);
    let agent=Agent.resume ~net ~checkpoint:cp ~options:(binding_options target) () |> binding_resume_ok in
    Alcotest.(check bool) "original reasoning kept" true ((Agent.state agent).messages==cp.messages);
    Agent.close agent)
    [binding_provider "https://rotated.example";binding_provider ~path:"/other-chat" "https://original.example"])
;;
let test_binding_signed_rotation_refused () = with_net (fun net ->
  let original=binding_provider ~kind:Binding_provider.Anthropic "https://original.example" in
  let cp=binding_checkpoint original [binding_message(binding_source original)] in
  List.iter(fun target ->
    Alcotest.(check int) "signed endpoint/path source cannot rotate" 0
      (expect_binding_incompatible(Agent.resume ~net ~checkpoint:cp ~options:(binding_options target) ())))
    [binding_provider ~kind:Binding_provider.Anthropic "https://rotated.example";
     binding_provider ~kind:Binding_provider.Anthropic ~path:"/other" "https://original.example"])
;;
let test_binding_mixed_history () = with_net (fun net ->
  let target=binding_provider "https://target.example" in
  let foreign=binding_provider ~kind:Binding_provider.Kimi "https://foreign.example" in
  (* Last producer is compatible; an earlier native artifact is not. *)
  let cp=binding_checkpoint target [binding_message(binding_source foreign);
    Types.user_msg "later";binding_message(binding_source target)] in
  Alcotest.(check int) "all artifact producers checked" 0
    (expect_binding_incompatible(Agent.resume ~net ~checkpoint:cp ~options:(binding_options target) ())))
;;
let test_binding_text_only_rebind () = with_net (fun net ->
  let original=binding_provider "https://original.example" in
  let target=binding_provider ~kind:Binding_provider.Kimi "https://other.example" in
  let cp=binding_checkpoint original [Types.assistant_msg "text only"] in
  let plan=Agent_checkpoint.build_resume ~checkpoint:cp ~provider_config:target () |> binding_resume_ok in
  Alcotest.(check bool) "text-only source change has explicit disposition" true
    (plan.binding_disposition=Agent_checkpoint.Rebound_without_replay_loss);
  let agent=Agent.resume ~net ~checkpoint:cp ~options:(binding_options target) () |> binding_resume_ok in
  Alcotest.(check bool) "text retained" true ((Agent.state agent).messages==cp.messages);
  Agent.close agent)
;;
let test_binding_explicit_disable () = with_net (fun net ->
  let original=binding_provider "https://original.example" in
  let target=binding_provider ~kind:Binding_provider.Kimi "https://other.example" in
  let cp=binding_checkpoint original [binding_message(binding_source original)] in
  let config={ (Types.default_config ~model:target.model_id) with preserve_thinking=Some false} in
  let plan=Agent_checkpoint.build_resume ~checkpoint:cp ~provider_config:target ~config () |> binding_resume_ok in
  Alcotest.(check bool) "caller exclusion is explicit" true
    (plan.binding_disposition=Agent_checkpoint.Replay_disabled_by_caller);
  let agent=Agent.resume ~net ~checkpoint:cp ~config ~options:(binding_options target) () |> binding_resume_ok in
  Alcotest.(check bool) "caller exclusion does not destroy canonical reasoning" true ((Agent.state agent).messages==cp.messages);
  Agent.close agent)
;;
let test_binding_missing_and_corrupt_source () = with_net (fun net ->
  let target=binding_provider "https://same.example" in
  let source=binding_source target in
  let absent={ (binding_message source) with Types.metadata=[]} in
  let cp=binding_checkpoint target [absent] in
  (match Agent.resume ~net ~checkpoint:cp ~options:(binding_options target) () with
   | Error (Agent_checkpoint.Replay_rejected (Binding_projection.Missing_resume_reasoning_source {message_index=0})) -> ()
   | Error error -> Alcotest.fail(Agent_checkpoint.resume_error_to_string error)
   | Ok _ -> Alcotest.fail "session source must not be invented as an artifact source");
  let duplicate={ (binding_message source) with Types.metadata=Binding_source.metadata source @ Binding_source.metadata source} in
  let cp={cp with messages=[duplicate]} in
  let config={ (Types.default_config ~model:target.model_id) with preserve_thinking=Some false} in
  (match Agent.resume ~net ~checkpoint:cp ~config ~options:(binding_options target) () with
   | Error (Agent_checkpoint.Replay_rejected (Binding_projection.Invalid_reasoning_source _)) -> ()
   | Error error -> Alcotest.fail(Agent_checkpoint.resume_error_to_string error)
   | Ok _ -> Alcotest.fail "caller replay exclusion cannot admit corrupt provenance");
  let wrong_role={absent with Types.role=Types.User} in
  (match Agent.resume ~net ~checkpoint:{cp with messages=[wrong_role]}
      ~config ~options:(binding_options target) () with
   | Error (Agent_checkpoint.Replay_rejected (Binding_projection.Invalid_resume_reasoning_role {message_index=0})) -> ()
   | Error error -> Alcotest.fail(Agent_checkpoint.resume_error_to_string error)
   | Ok _ -> Alcotest.fail "caller replay exclusion cannot admit an invalid reasoning role"))
;;
let test_binding_non_dispatch_restore () = with_net (fun net ->
  let provider=binding_provider "https://same.example" in
  let cp=binding_checkpoint provider [{ (binding_message(binding_source provider)) with Types.metadata=[]}] in
  let plan=Agent_checkpoint.build_resume ~checkpoint:cp () |> binding_resume_ok in
  Alcotest.(check bool) "unconfigured non-dispatch disposition" true
    (plan.binding_disposition=Agent_checkpoint.Unconfigured_target && plan.provider_config=None);
  let agent=Agent.resume ~net ~checkpoint:cp () |> binding_resume_ok in
  Alcotest.(check bool) "unconfigured restore preserves input settlement state" true
    (Agent.provider_config agent=None && (Agent.state agent).messages==cp.messages);
  Agent.close agent)
;;
let test_binding_direct_old_or_invalid_checkpoint () = with_net (fun net ->
  let provider=binding_provider "https://same.example" in
  let cp=binding_checkpoint provider [] in
  (match Agent.resume ~net ~checkpoint:{cp with version=14} () with
   | Error (Agent_checkpoint.Invalid_checkpoint_version {expected=15;got=14}) -> ()
   | Error error -> Alcotest.fail(Agent_checkpoint.resume_error_to_string error)
   | Ok _ -> Alcotest.fail "old direct checkpoint cannot silently migrate");
  let source={ (binding_source provider) with Binding_source.canonical_model_id=""} in
  (match Agent.resume ~net ~checkpoint:{cp with provider_binding=Some source} () with
   | Error (Agent_checkpoint.Invalid_checkpoint_binding _) -> ()
   | Error error -> Alcotest.fail(Agent_checkpoint.resume_error_to_string error)
   | Ok _ -> Alcotest.fail "invalid direct binding must be rejected"))
;;

(* ── Test runner ─────────────────────────────────────────────── *)

let () =
  let open Alcotest in
  run
    "Session Resume"
    [ "provider replay binding", [
        test_case "same exact binding retains canonical history" `Quick test_binding_exact_resume;
        test_case "provider model and replay contract mismatch" `Quick test_binding_provider_model_and_contract_mismatch;
        test_case "declared text endpoint and path rotation" `Quick test_binding_declared_rotation;
        test_case "signed source endpoint and path mismatch" `Quick test_binding_signed_rotation_refused;
        test_case "mixed-producer history" `Quick test_binding_mixed_history;
        test_case "text-only source change" `Quick test_binding_text_only_rebind;
        test_case "explicit caller replay exclusion" `Quick test_binding_explicit_disable;
        test_case "missing and corrupt artifact provenance" `Quick test_binding_missing_and_corrupt_source;
        test_case "non-dispatch restoration" `Quick test_binding_non_dispatch_restore;
        test_case "direct old and invalid checkpoint" `Quick test_binding_direct_old_or_invalid_checkpoint]
    ; ( "Session.resume_from"
      , [ test_case "generates new id" `Quick test_resume_from_generates_new_id
        ; test_case "links session_id" `Quick test_resume_from_links_session_id
        ; test_case "carries turn_count" `Quick test_resume_from_carries_turn_count
        ; test_case "fresh timestamps" `Quick test_resume_from_fresh_timestamps
        ; test_case "cwd is None" `Quick test_resume_from_cwd_is_none
        ; test_case "fresh metadata" `Quick test_resume_from_fresh_metadata
        ; test_case
            "copies checkpoint context"
            `Quick
            test_resume_from_copies_checkpoint_context
        ; test_case "zero turn checkpoint" `Quick test_resume_from_zero_turn_checkpoint
        ; test_case "unique ids" `Quick test_resume_from_unique_ids
        ; test_case "empty session_id" `Quick test_resume_from_empty_session_id
        ] )
    ; ( "Agent.resume"
      , [ test_case "restores messages" `Quick test_resume_restores_messages
        ; test_case "restores context" `Quick test_resume_restores_context
        ; test_case "restores usage" `Quick test_resume_restores_usage
        ; test_case "restores turn_count" `Quick test_resume_restores_turn_count
        ; test_case "restores model" `Quick test_resume_restores_model
        ; test_case "restores agent_name" `Quick test_resume_restores_agent_name
        ; test_case "restores system_prompt" `Quick test_resume_restores_system_prompt
        ; test_case "restores tool_choice" `Quick test_resume_restores_tool_choice
        ; test_case "none system_prompt" `Quick test_resume_none_system_prompt
        ; test_case "with tools" `Quick test_resume_with_tools
        ; test_case "default options" `Quick test_resume_default_options
        ; test_case "custom options" `Quick test_resume_custom_options
        ; test_case "config override" `Quick test_resume_with_config_override
        ; test_case "empty checkpoint" `Quick test_resume_empty_checkpoint
        ; test_case
            "preserves message content"
            `Quick
            test_resume_preserves_message_content
        ; test_case "cache tokens" `Quick test_resume_cache_tokens
        ; test_case "custom model" `Quick test_resume_custom_model
        ] )
    ; ( "roundtrip"
      , [ test_case
            "checkpoint → serialize → resume"
            `Quick
            test_checkpoint_resume_roundtrip
        ; test_case
            "resume_from then record_turn"
            `Quick
            test_session_resume_from_then_record
        ] )
    ]
;;
