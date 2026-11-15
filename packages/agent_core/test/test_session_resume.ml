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
  let agent = (Agent.resume ~media_store:(Agent_core.History.Memory_store.create ()) ~net ~checkpoint:cp () |> Result.get_ok) in
  Alcotest.(check int) "message count" 4 (List.length (Agent.state agent).messages)
;;

let test_resume_restores_context () =
  with_net
  @@ fun net ->
  let ctx = Context.create_sync () in
  Context.set_scoped ctx Context.User "theme" (`String "dark");
  let cp = make_checkpoint ~context:ctx () in
  let agent = (Agent.resume ~media_store:(Agent_core.History.Memory_store.create ()) ~net ~checkpoint:cp () |> Result.get_ok) in
  Alcotest.(check bool)
    "context restored"
    true
    (Context.get_scoped (Agent.context agent) Context.User "theme" = Some (`String "dark"))
;;

let test_resume_restores_usage () =
  with_net
  @@ fun net ->
  let cp = make_checkpoint ~usage:sample_usage () in
  let agent = (Agent.resume ~media_store:(Agent_core.History.Memory_store.create ()) ~net ~checkpoint:cp () |> Result.get_ok) in
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
  let agent = (Agent.resume ~media_store:(Agent_core.History.Memory_store.create ()) ~net ~checkpoint:cp () |> Result.get_ok) in
  Alcotest.(check int) "turn_count" 5 (Agent.state agent).turn_count
;;

let test_resume_restores_model () =
  with_net
  @@ fun net ->
  let cp = make_checkpoint ~model:"claude-opus-5-5" () in
  let agent = (Agent.resume ~media_store:(Agent_core.History.Memory_store.create ()) ~net ~checkpoint:cp () |> Result.get_ok) in
  Alcotest.(check string) "model" "claude-opus-5-5" (Agent.state agent).config.model
;;

let test_resume_restores_agent_name () =
  with_net
  @@ fun net ->
  let cp = make_checkpoint ~agent_name:"my-agent" () in
  let agent = (Agent.resume ~media_store:(Agent_core.History.Memory_store.create ()) ~net ~checkpoint:cp () |> Result.get_ok) in
  Alcotest.(check string) "name" "my-agent" (Agent.state agent).config.name
;;

let test_resume_restores_system_prompt () =
  with_net
  @@ fun net ->
  let cp = make_checkpoint ~system_prompt:(Some "Be concise.") () in
  let agent = (Agent.resume ~media_store:(Agent_core.History.Memory_store.create ()) ~net ~checkpoint:cp () |> Result.get_ok) in
  Alcotest.(check (option string))
    "system_prompt"
    (Some "Be concise.")
    (Agent.state agent).config.system_prompt
;;

let test_resume_restores_tool_choice () =
  with_net
  @@ fun net ->
  let cp = make_checkpoint ~tool_choice:(Some Types.Any) () in
  let agent = (Agent.resume ~media_store:(Agent_core.History.Memory_store.create ()) ~net ~checkpoint:cp () |> Result.get_ok) in
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
  let agent = (Agent.resume ~media_store:(Agent_core.History.Memory_store.create ()) ~net ~checkpoint:cp () |> Result.get_ok) in
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
  let agent = (Agent.resume ~media_store:(Agent_core.History.Memory_store.create ()) ~net ~checkpoint:cp ~tools:[ tool ] () |> Result.get_ok) in
  Alcotest.(check int) "tool count" 1 (Tool_set.size (Agent.tools agent))
;;

let test_resume_default_options () =
  with_net
  @@ fun net ->
  let cp = make_checkpoint () in
  let agent = (Agent.resume ~media_store:(Agent_core.History.Memory_store.create ()) ~net ~checkpoint:cp () |> Result.get_ok) in
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
  let agent = (Agent.resume ~media_store:(Agent_core.History.Memory_store.create ()) ~net ~checkpoint:cp ~options:opts () |> Result.get_ok) in
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
  let agent = (Agent.resume ~media_store:(Agent_core.History.Memory_store.create ()) ~net ~checkpoint:cp ~config:cfg () |> Result.get_ok) in
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
  let agent = (Agent.resume ~media_store:(Agent_core.History.Memory_store.create ()) ~net ~checkpoint:cp () |> Result.get_ok) in
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
  let agent = (Agent.resume ~media_store:(Agent_core.History.Memory_store.create ()) ~net ~checkpoint:cp () |> Result.get_ok) in
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
  let agent = (Agent.resume ~media_store:(Agent_core.History.Memory_store.create ()) ~net ~checkpoint:cp2 () |> Result.get_ok) in
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
  let agent = (Agent.resume ~media_store:(Agent_core.History.Memory_store.create ()) ~net ~checkpoint:cp () |> Result.get_ok) in
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
  let agent = (Agent.resume ~media_store:(Agent_core.History.Memory_store.create ()) ~net ~checkpoint:cp () |> Result.get_ok) in
  Alcotest.(check string) "custom model" "my-local-model" (Agent.state agent).config.model
;;

module Binding_source = Llm_provider.Types.Reasoning_source
module Binding_projection = Llm_provider.Reasoning_history_projection
module Binding_provider = Llm_provider.Provider_config

let binding_provider ?(kind=Binding_provider.OpenAI_compat) ?(path="/chat")
    ?(replay=Llm_provider.Capabilities.Force_preserve_always) ?(model="shared-model") endpoint =
  let caps = Llm_provider.Capabilities.{openai_compat_chat_capabilities with
    supports_reasoning=true; reasoning_replay_override=replay} in
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
      (Binding_projection.Incompatible_reasoning_artifact {message_index;_})) -> message_index
  | Error error -> Alcotest.fail(Agent_checkpoint.resume_error_to_string error)
  | Ok _ -> Alcotest.fail "incompatible reasoning was admitted"
;;
let test_binding_exact_resume () = with_net (fun net ->
  let provider=binding_provider "https://same.example" in
  let source=binding_source provider in
  let cp=binding_checkpoint provider [binding_message source] in
  let before=Checkpoint.to_json cp in
  let agent=Agent.resume ~media_store:(Agent_core.History.Memory_store.create ()) ~net ~checkpoint:cp ~options:(binding_options provider) () |> binding_resume_ok in
  Alcotest.(check bool) "canonical history retained without projection" true
    ((Agent.state agent).messages == cp.messages);
  Alcotest.(check bool) "last producer remains recorded" true
    (match (Agent.state agent).provider_binding with Some actual -> Binding_source.equal source actual | None -> false);
  let admitted=Agent.provider_config agent |> Option.get in
  Alcotest.(check bool) "admitted carrier is request-frozen" true (admitted.request_policy_snapshot<>None);
  Alcotest.(check bool) "source checkpoint not mutated" true (before=Checkpoint.to_json cp))
;;
let test_binding_provider_model_and_contract_mismatch () = with_net (fun net ->
  let original=binding_provider "https://same.example" in
  let cp=binding_checkpoint original [binding_message(binding_source original)] in
  let no_replay={original with Binding_provider.model_capabilities_override=Some
    Llm_provider.Capabilities.{openai_compat_chat_capabilities with reasoning_replay_override=Force_no_replay}} in
  let targets=[binding_provider ~kind:Binding_provider.Kimi "https://same.example";
    binding_provider ~model:"other-model" "https://same.example";no_replay] in
  List.iter(fun target ->
    let config=Types.default_config ~model:target.Binding_provider.model_id in
    let result=Agent.resume ~media_store:(Agent_core.History.Memory_store.create ()) ~net ~checkpoint:cp ~config ~options:(binding_options target) () in
    Alcotest.(check int) "kind/model/contract cannot silently discard replay" 0
      (expect_binding_incompatible result)) targets)
;;
(* Restore validates reasoning over the history as it is: it reads no media,
   so a store that cannot return any bytes still restores a history that
   holds an image, and a blob outside the next request is never read. *)
let test_restore_reads_no_media () = with_net (fun net ->
  let provider = binding_provider "https://same.example" in
  let image = Types.Image
    { media_type = "image/png"; source = Types.Stored (Agent_core.History.stored_of_raw "pixels") } in
  let cp = binding_checkpoint provider
    [Types.user_msg_blocks [Types.Text "look"; image]; binding_message (binding_source provider)] in
  let reads = ref 0 in
  let media_store : Agent_core.History.media_store =
    { put = (fun ~media_type:_ ~raw -> Ok (Agent_core.History.stored_of_raw raw))
    ; get = (fun stored -> incr reads; Error (Agent_core.History.Missing_bytes stored)) } in
  let plan = Agent_checkpoint.build_resume ~checkpoint:cp ~provider_config:provider ()
    |> binding_resume_ok in
  Alcotest.(check bool) "the producer is identical" true
    (plan.binding_disposition = Agent_checkpoint.Identical_source);
  let agent = Agent.resume ~media_store ~net ~checkpoint:cp ~options:(binding_options provider) ()
    |> binding_resume_ok in
  Alcotest.(check bool) "the history is restored as saved" true
    ((Agent.state agent).messages == cp.messages);
  Alcotest.(check int) "no media was read" 0 !reads)
;;

let test_binding_declared_rotation () = with_net (fun net ->
  let original=binding_provider "https://original.example" in
  let source=binding_source original in
  let cp=binding_checkpoint original [binding_message source] in
  List.iter(fun target ->
    let plan=Agent_checkpoint.build_resume ~checkpoint:cp ~provider_config:target () |> binding_resume_ok in
    Alcotest.(check bool) "declared text endpoint/path rotation admitted" true
      (plan.binding_disposition=Agent_checkpoint.Declared_endpoint_rotation);
    let agent=Agent.resume ~media_store:(Agent_core.History.Memory_store.create ()) ~net ~checkpoint:cp ~options:(binding_options target) () |> binding_resume_ok in
    Alcotest.(check bool) "original reasoning kept" true ((Agent.state agent).messages==cp.messages))
    [binding_provider "https://rotated.example";binding_provider ~path:"/other-chat" "https://original.example"])
;;
let test_binding_signed_rotation_refused () = with_net (fun net ->
  let original=binding_provider ~kind:Binding_provider.Anthropic "https://original.example" in
  let cp=binding_checkpoint original [binding_message(binding_source original)] in
  List.iter(fun target ->
    Alcotest.(check int) "signed endpoint/path source cannot rotate" 0
      (expect_binding_incompatible(Agent.resume ~media_store:(Agent_core.History.Memory_store.create ()) ~net ~checkpoint:cp ~options:(binding_options target) ())))
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
    (expect_binding_incompatible(Agent.resume ~media_store:(Agent_core.History.Memory_store.create ()) ~net ~checkpoint:cp ~options:(binding_options target) ())))
;;
let test_binding_text_only_rebind () = with_net (fun net ->
  let original=binding_provider "https://original.example" in
  let target=binding_provider ~kind:Binding_provider.Kimi "https://other.example" in
  let cp=binding_checkpoint original [Types.assistant_msg "text only"] in
  let plan=Agent_checkpoint.build_resume ~checkpoint:cp ~provider_config:target () |> binding_resume_ok in
  Alcotest.(check bool) "text-only source change has explicit disposition" true
    (plan.binding_disposition=Agent_checkpoint.Rebound_without_replay_loss);
  let agent=Agent.resume ~media_store:(Agent_core.History.Memory_store.create ()) ~net ~checkpoint:cp ~options:(binding_options target) () |> binding_resume_ok in
  Alcotest.(check bool) "text retained" true ((Agent.state agent).messages==cp.messages))
;;
let test_binding_explicit_disable () = with_net (fun net ->
  let original=binding_provider "https://original.example" in
  let target=binding_provider ~replay:Llm_provider.Capabilities.Force_no_replay ~kind:Binding_provider.Kimi "https://other.example" in
  let cp=binding_checkpoint original [binding_message(binding_source original)] in
  let config={ (Types.default_config ~model:target.model_id) with preserve_thinking=Some false} in
  let plan=Agent_checkpoint.build_resume ~checkpoint:cp ~provider_config:target ~config () |> binding_resume_ok in
  Alcotest.(check bool) "caller exclusion is explicit" true
    (plan.binding_disposition=Agent_checkpoint.Replay_disabled_by_caller);
  let agent=Agent.resume ~media_store:(Agent_core.History.Memory_store.create ()) ~net ~checkpoint:cp ~config ~options:(binding_options target) () |> binding_resume_ok in
  Alcotest.(check bool) "caller exclusion does not destroy canonical reasoning" true ((Agent.state agent).messages==cp.messages);
  let ignores_false=binding_provider ~kind:Binding_provider.Kimi "https://other.example" in
  Alcotest.(check int) "a wire ignoring false cannot claim caller exclusion" 0
    (expect_binding_incompatible(Agent.resume ~media_store:(Agent_core.History.Memory_store.create ()) ~net ~checkpoint:cp ~config
      ~options:(binding_options ignores_false) ())))
;;
let test_binding_missing_and_corrupt_source () = with_net (fun net ->
  let target=binding_provider "https://same.example" in
  let source=binding_source target in
  let absent={ (binding_message source) with Types.metadata=[]} in
  let cp=binding_checkpoint target [absent] in
  (match Agent.resume ~media_store:(Agent_core.History.Memory_store.create ()) ~net ~checkpoint:cp ~options:(binding_options target) () with
   | Error (Agent_checkpoint.Replay_rejected (Binding_projection.Unbound_reasoning_artifact {message_index=0})) -> ()
   | Error error -> Alcotest.fail(Agent_checkpoint.resume_error_to_string error)
   | Ok _ -> Alcotest.fail "session source must not be invented as an artifact source");
  let duplicate={ (binding_message source) with Types.metadata=Binding_source.metadata source @ Binding_source.metadata source} in
  let cp={cp with messages=[duplicate]} in
  let config={ (Types.default_config ~model:target.model_id) with preserve_thinking=Some false} in
  (match Agent.resume ~media_store:(Agent_core.History.Memory_store.create ()) ~net ~checkpoint:cp ~config ~options:(binding_options target) () with
   | Error (Agent_checkpoint.Replay_rejected (Binding_projection.Invalid_reasoning_source _)) -> ()
   | Error error -> Alcotest.fail(Agent_checkpoint.resume_error_to_string error)
   | Ok _ -> Alcotest.fail "caller replay exclusion cannot admit corrupt provenance");
  let wrong_role={absent with Types.role=Types.User} in
  (match Agent.resume ~media_store:(Agent_core.History.Memory_store.create ()) ~net ~checkpoint:{cp with messages=[wrong_role]}
      ~config ~options:(binding_options target) () with
   | Error (Agent_checkpoint.Replay_rejected (Binding_projection.Invalid_reasoning_artifact_role {message_index=0})) -> ()
   | Error error -> Alcotest.fail(Agent_checkpoint.resume_error_to_string error)
   | Ok _ -> Alcotest.fail "caller replay exclusion cannot admit an invalid reasoning role"))
;;
let test_binding_inline_carrier_producers () = with_net (fun net ->
  let original=binding_provider "https://original.example" in
  let target=binding_provider ~kind:Binding_provider.Kimi "https://other.example" in
  List.iter (fun (content,raw_content,block_indices) ->
    let replay=Types.Inline_content_replay.make ~content ~raw_content ~block_indices |> Result.get_ok in
    let carrier_metadata=[Types.Inline_content_replay.metadata replay] in
    let history_content=Agent_core.History.of_wire_blocks
        (Agent_core.History.Memory_store.create ()) content |> Result.get_ok in
    let message={ (Types.assistant_msg "") with content=history_content;
      metadata=carrier_metadata @ Binding_source.metadata(binding_source original)} in
    let cp=binding_checkpoint original [message] in
    Alcotest.(check int) "metadata-only carrier has a checked producer" 0
      (expect_binding_incompatible(Agent.resume ~media_store:(Agent_core.History.Memory_store.create ()) ~net ~checkpoint:cp ~options:(binding_options target) ()));
    let unbound={cp with messages=[{message with metadata=carrier_metadata}]} in
    (match Agent.resume ~media_store:(Agent_core.History.Memory_store.create ()) ~net ~checkpoint:unbound ~options:(binding_options target) () with
     | Error (Agent_checkpoint.Replay_rejected (Binding_projection.Unbound_reasoning_artifact {message_index=0})) -> ()
     | Error error -> Alcotest.fail(Agent_checkpoint.resume_error_to_string error)
     | Ok _ -> Alcotest.fail "inline carrier borrowed the session producer");
    let exact=Agent.resume ~media_store:(Agent_core.History.Memory_store.create ()) ~net ~checkpoint:cp ~options:(binding_options original) () |> binding_resume_ok in
    Alcotest.(check bool) "exact carrier retained" true ((Agent.state exact).messages==cp.messages);
    let excluded=binding_provider ~replay:Llm_provider.Capabilities.Force_no_replay
      ~kind:Binding_provider.Kimi "https://other.example" in
    let config={ (Types.default_config ~model:excluded.model_id) with preserve_thinking=Some false} in
    let agent=Agent.resume ~media_store:(Agent_core.History.Memory_store.create ()) ~net ~checkpoint:unbound ~config ~options:(binding_options excluded) () |> binding_resume_ok in
    Alcotest.(check bool) "explicit exclusion preserves canonical carrier" true
      ((Agent.state agent).messages==unbound.messages))
    [[],"",[]; [],"<think></think>",[]; [Llm_provider.Types.Text "answer"],"answer",[0]])
;;
let test_binding_non_dispatch_restore () = with_net (fun net ->
  let provider=binding_provider "https://same.example" in
  let cp=binding_checkpoint provider [{ (binding_message(binding_source provider)) with Types.metadata=[]}] in
  let plan=Agent_checkpoint.build_resume ~checkpoint:cp () |> binding_resume_ok in
  Alcotest.(check bool) "unconfigured non-dispatch disposition" true
    (plan.binding_disposition=Agent_checkpoint.Unconfigured_target && plan.provider_config=None);
  let agent=Agent.resume ~media_store:(Agent_core.History.Memory_store.create ()) ~net ~checkpoint:cp () |> binding_resume_ok in
  Alcotest.(check bool) "unconfigured restore preserves input settlement state" true
    (Agent.provider_config agent=None && (Agent.state agent).messages==cp.messages))
;;
let test_binding_direct_old_or_invalid_checkpoint () = with_net (fun net ->
  let provider=binding_provider "https://same.example" in
  let cp=binding_checkpoint provider [] in
  (match Agent.resume ~media_store:(Agent_core.History.Memory_store.create ()) ~net ~checkpoint:{cp with version=Checkpoint.checkpoint_version-1} () with
   | Error (Agent_checkpoint.Invalid_checkpoint_version {expected; got}) ->
     Alcotest.(check int) "expected current checkpoint version" Checkpoint.checkpoint_version expected;
     Alcotest.(check int) "rejected the previous checkpoint version" (Checkpoint.checkpoint_version-1) got
   | Error error -> Alcotest.fail(Agent_checkpoint.resume_error_to_string error)
   | Ok _ -> Alcotest.fail "old direct checkpoint cannot silently migrate");
  let source={ (binding_source provider) with Binding_source.canonical_model_id=""} in
  (match Agent.resume ~media_store:(Agent_core.History.Memory_store.create ()) ~net ~checkpoint:{cp with provider_binding=Some source} () with
   | Error (Agent_checkpoint.Invalid_checkpoint_binding _) -> ()
   | Error error -> Alcotest.fail(Agent_checkpoint.resume_error_to_string error)
   | Ok _ -> Alcotest.fail "invalid direct binding must be rejected"))
;;

let test_binding_hook_cannot_reenable_incompatible_replay () = with_net (fun net ->
  Eio.Switch.run (fun sw ->
    List.iter(fun (stream, reenable) ->
      let original=binding_provider "https://original.example" in
      let target=binding_provider ~replay:Llm_provider.Capabilities.Force_no_replay ~kind:Binding_provider.Kimi "https://other.example" in
      let cp=binding_checkpoint original [binding_message(binding_source original)] in
      let before=Checkpoint.to_json cp in
      let calls=ref 0 in
      let response=Provider_mock.text_response "continued without replay" [] in
      let transport=Llm_provider.Llm_transport.custom ({
        complete_sync=(fun _ -> incr calls; {response=Ok response;latency_ms=Some 0});
        complete_stream=(fun ?on_telemetry:_ ~on_event:_ _ -> incr calls;Ok response)}) in
      let hooks={Hooks.empty with before_turn_params=Some(function
        | Hooks.BeforeTurnParams {current_params;_} when reenable ->
          Hooks.AdjustParams {current_params with preserve_thinking=Some true}
        | _ -> Hooks.Continue)} in
      let options={ (binding_options target) with transport=Some transport;hooks} in
      let config={ (Types.default_config ~model:target.model_id) with
        preserve_thinking=Some false;max_tokens=Some 16} in
      let agent=Agent.resume ~media_store:(Agent_core.History.Memory_store.create ()) ~net ~checkpoint:cp ~config ~options () |> binding_resume_ok in
      let result=if stream then Agent.run_stream ~sw ~on_event:ignore agent "next"
        else Agent.run ~sw agent "next" in
      (match reenable,result with
       | true,Error (Error.Config (Error.InvalidConfig {field="reasoning_replay";_})) -> ()
       | false,Ok _ -> ()
       | _,Error error -> Alcotest.fail(Error.to_string error)
       | true,Ok _ -> Alcotest.fail "hook re-enabled incompatible replay"
       );
      Alcotest.(check int) "rejected hook never reaches transport; explicit exclusion does"
        (if reenable then 0 else 1) !calls;
      Alcotest.(check bool) "checkpoint remains unchanged" true (before=Checkpoint.to_json cp);
      Alcotest.(check bool) "native artifact remains canonical" true
        (List.hd (Agent.state agent).messages=List.hd cp.messages))
      [false,false;false,true;true,false;true,true]))
;;

(* A failover must retain canonical provenance and settled tool effects while
   both dispatch modes admit only the target-compatible wire reasoning. Each
   boundary that admits the change records which message it excluded, why and
   for which target; the record is compared with the typed admission, and it
   never carries the reasoning itself. *)
let test_binding_explicit_source_change () = with_net (fun net ->
  Eio.Switch.run (fun sw ->
    List.iter (fun stream ->
      let original = binding_provider ~kind:Binding_provider.Glm ~model:"glm-5.3-flash"
          "https://original.example" in
      let target = binding_provider ~model:"deepseek-v4.1-flash"
          ~replay:Llm_provider.Capabilities.Force_latest_user_turn_tool_calls
          "https://target.example" in
      let foreign = { (binding_message (binding_source original)) with
        content = [Types.Thinking {content="foreign-reasoning";signature=None};
          Types.Text "already inspected";
          Types.ToolUse {id="settled";name="inspect";input=`Assoc []}] } in
      let compatible = { (binding_message (binding_source target)) with
        content = [Types.Thinking {content="target-reasoning";signature=None};Types.Text "continue"] } in
      let result = Types.tool_result_msg ~tool_use_id:"settled" ~content:"saved result" () in
      let cp = binding_checkpoint original [Types.user_msg "inspect";foreign;result;compatible] in
      let before = Checkpoint.to_json cp in
      let config = { (Types.default_config ~model:target.model_id) with max_tokens=Some 64 } in
      let plan = Agent_checkpoint.build_resume ~checkpoint:cp ~config ~provider_config:target
          ~source_change_policy:Binding_projection.Exclude_unselected () |> binding_resume_ok in
      let pending = match plan.binding_disposition with
        | Agent_checkpoint.Rebound_pending_dispatch exclusion -> exclusion
        | Unconfigured_target | Unrecorded_producer | Identical_source
        | Declared_endpoint_rotation | Rebound_without_replay_loss | Replay_disabled_by_caller ->
          Alcotest.fail "missing source-change exclusion evidence" in
      (match pending with
       | {boundary=Provider_dispatch _;_} ->
         Alcotest.fail "restore must name its own boundary"
       | {boundary=Checkpoint_restore;target=pending_target;drops} ->
         Alcotest.(check bool) "the pending exclusion names the target" true
           (Binding_source.equal pending_target (binding_source target));
         Alcotest.(check (list int)) "exact excluded message indices" [1]
           (List.map (fun (drop : Binding_projection.reasoning_replay_drop) -> drop.message_index) drops);
         List.iter (fun (drop : Binding_projection.reasoning_replay_drop) -> match drop.reason with
           | Incompatible_reasoning_source source ->
             Alcotest.(check bool) "exact foreign producer is reported" true
               (Binding_source.equal source (binding_source original))
           | Replay_policy_excluded _ | Missing_reasoning_source | Reasoning_on_non_assistant ->
             Alcotest.fail "wrong exclusion reason") drops);
      let sink, records = Log.collector_sink () in
      Log.add_sink sink;
      let calls = ref 0 in
      let check_request (request : Llm_provider.Llm_transport.completion_request) =
        incr calls;
        let projection = Llm_provider.Backend_openai_serialize.project_history
            ~tools_present:true request.config request.messages |> Result.get_ok in
        let blocks = List.concat_map (fun (message : Llm_provider.Types.message) -> message.content) projection.messages in
        Alcotest.(check bool) "foreign reasoning excluded from wire" false
          (List.mem (Llm_provider.Types.Thinking {content="foreign-reasoning";signature=None}) blocks);
        Alcotest.(check bool) "past target reasoning follows the query boundary" false
          (List.mem (Llm_provider.Types.Thinking {content="target-reasoning";signature=None}) blocks);
        Alcotest.(check bool) "settled tool call retained" true
          (List.mem (Llm_provider.Types.ToolUse {id="settled";name="inspect";input=`Assoc []}) blocks);
        let result_wire = Agent_core.History.to_wire_message
            (Agent_core.History.Memory_store.create ()) result |> Result.get_ok in
        Alcotest.(check bool) "settled tool result retained" true
          (List.for_all (fun block -> List.mem block blocks) result_wire.content)
      in
      let response = Provider_mock.text_response "continued" [] in
      let transport = Llm_provider.Llm_transport.custom {
        complete_sync=(fun request -> check_request request;{response=Ok response;latency_ms=Some 0});
        complete_stream=(fun ?on_telemetry:_ ~on_event:_ request -> check_request request;Ok response)} in
      let options = { (binding_options target) with transport=Some transport;
        reasoning_source_change=Binding_projection.Exclude_unselected } in
      let blocked = Agent.resume ~media_store:(Agent_core.History.Memory_store.create ()) ~net ~checkpoint:cp ~config ~options () |> binding_resume_ok in
      (
        let api_strategy = if stream then Agent.Stream {on_event=ignore;on_telemetry=None}
          else Agent.Sync in
        (match Agent.Advanced.continue ~sw ~api_strategy
            ~on_tool_boundary:(fun _ -> Agent.Advanced.Continue) blocked with
         | Error (Error.Api (Llm_provider.Retry.InvalidRequest
             {reason=Llm_provider.Retry.Attempt_rejected;_})) -> ()
         | Error error -> Alcotest.fail (Error.to_string error)
         | Ok _ -> Alcotest.fail "continuation must retain mandatory replay admission");
        Alcotest.(check int) "active foreign replay never reaches transport" 0 !calls);
      let agent = Agent.resume ~media_store:(Agent_core.History.Memory_store.create ()) ~net ~checkpoint:cp ~config ~options () |> binding_resume_ok in
      (
        Alcotest.(check bool) "resume retains exact message spine" true
          ((Agent.state agent).messages == cp.messages);
        let outcome = if stream then Agent.run_stream ~sw ~on_event:ignore agent "next"
          else Agent.run ~sw agent "next" in
        (match outcome with Ok _ -> () | Error error -> Alcotest.fail (Error.to_string error));
        Alcotest.(check int) "one completion without re-executing historical tools" 1 !calls;
        Alcotest.(check bool) "canonical source history remains" true
          (List.for_all2 (=) cp.messages
             (List.take (List.length cp.messages) (Agent.state agent).messages));
        Alcotest.(check bool) "checkpoint remains unchanged" true (before=Checkpoint.to_json cp));
      Log.clear_sinks ();
      let recorded = List.filter_map (fun (record : Log.record) ->
        List.find_map (function
          | Log.J ("reasoning_replay_exclusion", json) -> Some json
          | Log.J _ | Log.S _ | Log.I _ | Log.F _ | Log.B _ | Log.Secret _ -> None) record.fields)
        (records ()) in
      let count expected = List.length (List.filter (Yojson.Safe.equal expected) recorded) in
      let at_restore = Binding_projection.replay_exclusion_to_json pending in
      let at_dispatch = Binding_projection.replay_exclusion_to_json
          { pending with boundary=Provider_dispatch {tools_present=
              Llm_provider.Complete_common.request_tools_present ~config:target ~tools:[]} } in
      (* Two resumes restored the checkpoint. The refused continuation never
         admitted a dispatch; the completed run admitted exactly one. *)
      Alcotest.(check int) "each restore records its pending exclusion" 2 (count at_restore);
      Alcotest.(check int) "the admitted dispatch records its exclusion" 1 (count at_dispatch);
      Alcotest.(check int) "no other exclusion is recorded" 3 (List.length recorded);
      List.iter (fun json ->
        let text = Yojson.Safe.to_string json in
        let private_bytes = "foreign-reasoning" in
        let length = String.length private_bytes in
        let rec from index =
          index + length <= String.length text
          && (String.equal (String.sub text index length) private_bytes || from (index + 1)) in
        Alcotest.(check bool) "the record carries no reasoning content" false (from 0)) recorded
    ) [false;true]))
;;

let anthropic_target () =
  Binding_provider.make ~kind:Binding_provider.Anthropic ~model_id:"claude-sonnet-5-5"
    ~base_url:"https://api.anthropic.com" ~max_tokens:64 ()
;;

let test_binding_source_change_respects_active_replay () =
  let original = binding_provider "https://original.example" in
  let foreign = { (binding_message (binding_source original)) with
    content=[Types.Thinking {content="foreign";signature=None};
      Types.ToolUse {id="settled";name="inspect";input=`Assoc []}] } in
  let result = Types.tool_result_msg ~tool_use_id:"settled" ~content:"saved" () in
  let base = [Types.user_msg "inspect";foreign;result] in
  let target = binding_provider ~model:"other-model"
      ~replay:Llm_provider.Capabilities.Force_latest_user_turn_tool_calls "https://target.example" in
  let validate provider history = Binding_projection.validate_replay_continuity_for_provider_config
      ~boundary:(Provider_dispatch {tools_present=true})
      ~source_change_policy:Binding_projection.Exclude_unselected provider
      (Agent_core.History.to_wire_messages (Agent_core.History.Memory_store.create ()) history
       |> Result.get_ok) in
  let rejected = function
    | Error (Binding_projection.Required_reasoning_unreadable {message_index=1;_}) -> ()
    | Error error -> Alcotest.fail (Binding_projection.error_to_string error)
    | Ok _ -> Alcotest.fail "required foreign reasoning must not be stripped" in
  rejected (validate target base);
  let control = { (Types.user_msg "system followup") with origin=Types.Agent_instruction } in
  rejected (validate target (base @ [control]));
  (match validate target (base @ [Types.user_msg "next query"]) with
   | Ok _ -> () | Error error -> Alcotest.fail (Binding_projection.error_to_string error));
  let all_history = binding_provider ~model:"other-model" "https://target.example" in
  rejected (validate all_history (base @ [Types.user_msg "next query"]));
  let opaque = binding_provider ~model:"other-model" ~path:"/v1/responses" "https://target.example" in
  rejected (validate opaque (base @ [Types.user_msg "next query"]));
  let request_tools = binding_provider ~model:"other-model"
      ~replay:Llm_provider.Capabilities.Force_preserve_with_request_tools "https://target.example" in
  rejected (validate request_tools (base @ [Types.user_msg "next query"]));
  (* Anthropic selects every assistant but requires thinking back only in
     the exchange the latest caller query opened (RFC-0507). *)
  let anthropic = anthropic_target () in
  rejected (validate anthropic base);
  (* The refusal keeps the producer and the target apart, in that order. *)
  (match validate anthropic base with
   | Error (Binding_projection.Required_reasoning_unreadable {stored;target;_} as refusal) ->
     Alcotest.(check bool) "the refusal carries the stored producer" true
       (Binding_source.equal stored (binding_source original));
     Alcotest.(check bool) "the refusal carries the target that cannot read it" true
       (Binding_source.equal target (binding_source anthropic));
     let message = Binding_projection.error_to_string refusal in
     let names fragment =
       let length = String.length fragment in
       let rec from index =
         index + length <= String.length message
         && (String.equal (String.sub message index length) fragment || from (index + 1)) in
       from 0 in
     Alcotest.(check bool) "the refusal names the target it must go back to" true
       (names "must go back to anthropic claude-sonnet-5-5");
     Alcotest.(check bool) "the refusal names the provider change from stored to target" true
       (names "provider openai_compat -> anthropic")
   | Error error -> Alcotest.fail (Binding_projection.error_to_string error)
   | Ok _ -> Alcotest.fail "required foreign reasoning must not be stripped");
  rejected (validate anthropic (base @ [control]));
  (* With no caller query in the history, all of it counts as the open
     exchange, the same rule selection uses. *)
  rejected (validate anthropic [control;foreign;result]);
  (* The same model on another endpoint: the refusal names the endpoint only,
     not a provider or model that did not change. *)
  let other_endpoint = Binding_provider.make ~kind:Binding_provider.Anthropic
      ~model_id:"claude-sonnet-5-5" ~base_url:"https://proxy.example" ~max_tokens:64 () in
  let moved = {foreign with metadata=Binding_source.metadata (binding_source other_endpoint)} in
  (match validate anthropic [Types.user_msg "inspect";moved;result] with
   | Error (Binding_projection.Required_reasoning_unreadable _ as refusal) ->
     Alcotest.(check string) "the refusal names only the endpoint"
       "reasoning at history index 1 must go back to anthropic claude-sonnet-5-5, \
        which cannot read it (stored source differs in endpoint)"
       (Binding_projection.error_to_string refusal)
   | Error error -> Alcotest.fail (Binding_projection.error_to_string error)
   | Ok _ -> Alcotest.fail "an endpoint change inside the open exchange must be refused");
  (match validate anthropic (base @ [Types.user_msg "next query"]) with
   | Ok {disposition=Binding_projection.Source_change_admitted drops;_} ->
     Alcotest.(check (list int)) "the finished foreign turn is a recorded drop" [1]
       (List.map (fun (drop : Binding_projection.reasoning_replay_drop) -> drop.message_index) drops)
   | Ok {disposition=(Preserve_reasoning | Caller_excluded_reasoning);_} ->
     Alcotest.fail "the foreign drop must be reported"
   | Error error -> Alcotest.fail (Binding_projection.error_to_string error));
  let current = {foreign with metadata=Binding_source.metadata (binding_source target)} in
  let history = base @ [Types.user_msg "next query";current;result] in
  (match validate target history with
   | Ok _ -> () | Error error -> Alcotest.fail (Binding_projection.error_to_string error));
  let wire_history = Agent_core.History.to_wire_messages
      (Agent_core.History.Memory_store.create ()) history |> Result.get_ok in
  let projected = Llm_provider.Backend_openai_serialize.project_history
      ~tools_present:true target wire_history |> Result.get_ok in
  Alcotest.(check int) "active compatible reasoning survives" 1
    (List.fold_left (fun n (message : Llm_provider.Types.message) -> n + List.length (List.filter
      (function Llm_provider.Types.Thinking _ -> true
        | Text _ | RedactedThinking _ | ReasoningDetails _ | ToolUse _
        | ToolResult _ | Image _ | Document _ | Audio _ -> false) message.content)) 0 projected.messages)
;;

let test_binding_source_change_uses_effective_request_tools () = with_net (fun net ->
  Eio.Switch.run (fun sw ->
    let original=binding_provider ~kind:Binding_provider.Glm ~model:"glm-5.3-flash"
        "https://original.example" in
    let target=binding_provider ~model:"deepseek-v4.1-flash"
        ~replay:Llm_provider.Capabilities.Force_preserve_with_request_tools
        "https://target.example" in
    let foreign={ (binding_message (binding_source original)) with
      content=[Types.Thinking {content="foreign-private-reasoning";signature=None};
        Types.Text "historical-visible-answer";
        Types.ToolUse {id="settled";name="inspect";input=`Assoc []}] } in
    let tool_result=Types.tool_result_msg ~tool_use_id:"settled" ~content:"settled-result" () in
    let cp=binding_checkpoint original [Types.user_msg "inspect";foreign;tool_result] in
    let before=Checkpoint.to_json cp in
    let tool_calls=ref 0 in
    let tool=Tool.create ~name:"inspect" ~description:"Inspect" ~parameters:[] (fun _ ->
      incr tool_calls;Ok {Types.content="unexpected re-execution";content_blocks=None;_meta=None}) in
    List.iter (fun stream ->
      List.iter (fun (has_tools,initial_choice,hook_choice,blocked) ->
        let config={ (Types.default_config ~model:target.model_id) with
          max_tokens=Some 64;tool_choice=initial_choice } in
        let hooks={Hooks.empty with before_turn_params=Some (function
          | Hooks.BeforeTurnParams {current_params;_} ->
            (match hook_choice with
             | None -> Hooks.Continue
             | Some choice -> Hooks.AdjustParams {current_params with tool_choice=Some choice})
          | _ -> Hooks.Continue)} in
        let requests=ref 0 in
        let check_request (request:Llm_provider.Llm_transport.completion_request) =
          incr requests;
          let artifact=match Llm_provider.Complete_common.serialize_http_request ~stream
              ~config:request.config ~messages:request.messages ~tools:request.tools with
            | Ok artifact -> artifact
            | Error _ -> Alcotest.fail "native request serialization failed" in
          let json=Yojson.Safe.from_string artifact.body in
          let open Yojson.Safe.Util in
          Alcotest.(check bool) "unselected tools absent from actual native wire" true
            (match member "tools" json with `Null | `List [] -> true | _ -> false);
          let messages=member "messages" json |> to_list in
          Alcotest.(check bool) "unselected foreign reasoning never sent" true
            (List.for_all (fun message -> member "reasoning_content" message=`Null) messages);
          Alcotest.(check bool) "settled tool result reaches native wire" true
            (List.exists (fun message -> member "content" message=`String "settled-result") messages)
        in
        let response=Provider_mock.text_response "continued" [] in
        let transport=Llm_provider.Llm_transport.custom {
          complete_sync=(fun request -> check_request request;{response=Ok response;latency_ms=None});
          complete_stream=(fun ?on_telemetry:_ ~on_event:_ request -> check_request request;Ok response)} in
        let options={ (binding_options target) with hooks;transport=Some transport;
          reasoning_source_change=Binding_projection.Exclude_unselected } in
        let agent=Agent.resume ~media_store:(Agent_core.History.Memory_store.create ()) ~net ~checkpoint:cp ~config ~options
            ~tools:(if has_tools then [tool] else []) () |> binding_resume_ok in
        (
          let outcome=if stream then Agent.run_stream ~sw ~on_event:ignore agent "new query"
            else Agent.run ~sw agent "new query" in
          (match blocked,outcome with
           | true,Error (Error.Api (Llm_provider.Retry.InvalidRequest
               {reason=Llm_provider.Retry.Attempt_rejected;_})) -> ()
           | false,Ok _ -> ()
           | _,Error error -> Alcotest.fail (Error.to_string error)
           | true,Ok _ -> Alcotest.fail "foreign mandatory replay reached a tool-bearing request");
          Alcotest.(check int) "only admitted requests reach transport" (if blocked then 0 else 1) !requests;
          Alcotest.(check bool) "canonical foreign reasoning remains" true
            (List.mem foreign (Agent.state agent).messages);
          Alcotest.(check bool) "source checkpoint remains unchanged" true (before=Checkpoint.to_json cp))
      ) [false,None,None,false;true,None,None,true;
         true,Some Types.None_,None,false;
         true,None,Some Types.None_,false;
         true,Some Types.None_,Some Types.Auto,true]
    ) [false;true];
    Alcotest.(check int) "historical tool effects are never replayed" 0 !tool_calls))
;;

let test_binding_source_change_rejects_invalid_provenance () = with_net (fun net ->
  let original = binding_provider "https://original.example" in
  let target = binding_provider ~model:"other-model" "https://target.example" in
  let source = binding_source original in
  let foreign = binding_message source in
  let config = Types.default_config ~model:target.model_id in
  let options = { (binding_options target) with
    reasoning_source_change=Binding_projection.Exclude_unselected } in
  let invalid_messages = [
    {foreign with metadata=[]};
    {foreign with metadata=Binding_source.metadata source @ Binding_source.metadata source};
    {foreign with role=Types.User}] in
  List.iteri (fun index message ->
    (* The first valid exclusion must not hide a later corrupt artifact. *)
    let cp = binding_checkpoint original [foreign;message] in
    match index,Agent.resume ~media_store:(Agent_core.History.Memory_store.create ()) ~net ~checkpoint:cp ~config ~options () with
    | 0, Error (Agent_checkpoint.Replay_rejected (Binding_projection.Unbound_reasoning_artifact {message_index=1}))
    | 1, Error (Agent_checkpoint.Replay_rejected (Binding_projection.Invalid_reasoning_source {message_index=1;_}))
    | 2, Error (Agent_checkpoint.Replay_rejected (Binding_projection.Reasoning_source_on_non_assistant {message_index=1;_})) -> ()
    | _, Error error -> Alcotest.fail (Agent_checkpoint.resume_error_to_string error)
    | _, Ok _ -> Alcotest.fail "source-change policy admitted invalid provenance"
  ) invalid_messages)
;;

(* The 11-06 lane move: Keepers moved onto Claude carried finished turns that
   qwen, deepseek and glm produced, and every turn was refused before any
   request left. Those turns now go out without the foreign reasoning and with
   their text, tool calls and results; Claude's own thinking is not invented
   (RFC-0507). *)
let test_binding_anthropic_sends_finished_foreign_turns () = with_net (fun net ->
  Eio.Switch.run (fun sw ->
    let producers =
      [ "qwen", binding_provider ~model:"qwen3.8-flash" "https://qwen.example"
      ; "deepseek", binding_provider ~model:"deepseek-v4.1-flash" "https://deepseek.example"
      ; "glm", binding_provider ~kind:Binding_provider.Glm ~model:"glm-5.3-flash"
          "https://glm.example" ] in
    let turn (name, provider) =
      let source = binding_source provider in
      let call_id = name ^ "-call" in
      [ Types.user_msg ("ask " ^ name)
      ; { (binding_message source) with
          content=[Types.Thinking {content=name ^ "-tool-reasoning";signature=None};
            Types.ToolUse {id=call_id;name="inspect";input=`Assoc []}] }
      ; Types.tool_result_msg ~tool_use_id:call_id ~content:(name ^ "-result") ()
      ; { (binding_message source) with
          content=[Types.Thinking {content=name ^ "-answer-reasoning";signature=None};
            Types.Text (name ^ "-answer")] } ] in
    let history = List.concat_map turn producers in
    let last_producer = snd (List.nth producers 2) in
    let cp = binding_checkpoint last_producer history in
    let before = Checkpoint.to_json cp in
    let target = anthropic_target () in
    let tool_calls = ref 0 in
    let tool = Tool.create ~name:"inspect" ~description:"Inspect" ~parameters:[] (fun _ ->
      incr tool_calls;Ok {Types.content="unexpected re-execution";content_blocks=None;_meta=None}) in
    List.iter (fun stream ->
      let requests = ref 0 in
      let check_request (request : Llm_provider.Llm_transport.completion_request) =
        incr requests;
        let artifact = match Llm_provider.Complete_common.serialize_http_request ~stream
            ~config:request.config ~messages:request.messages ~tools:request.tools with
          | Ok artifact -> artifact
          | Error _ -> Alcotest.fail "Anthropic request serialization failed" in
        let open Yojson.Safe.Util in
        let blocks = member "messages" (Yojson.Safe.from_string artifact.body) |> to_list
          |> List.concat_map (fun message -> match member "content" message with
            | `List blocks -> blocks | _ -> []) in
        let typed kind = List.filter (fun block -> member "type" block = `String kind) blocks in
        Alcotest.(check int) "no foreign reasoning reaches the Messages wire" 0
          (List.length (typed "thinking" @ typed "redacted_thinking"));
        Alcotest.(check (list string)) "every finished tool call is sent"
          ["qwen-call";"deepseek-call";"glm-call"]
          (List.map (fun block -> member "id" block |> to_string) (typed "tool_use"));
        Alcotest.(check int) "every finished tool result is sent" 3
          (List.length (typed "tool_result"));
        Alcotest.(check bool) "finished answers are sent" true
          (List.for_all (fun name -> List.exists (fun block ->
            member "type" block = `String "text"
            && member "text" block = `String (name ^ "-answer")) blocks)
            ["qwen";"deepseek";"glm"])
      in
      let response = Provider_mock.text_response "continued" [] in
      let transport = Llm_provider.Llm_transport.custom {
        complete_sync=(fun request -> check_request request;{response=Ok response;latency_ms=Some 0});
        complete_stream=(fun ?on_telemetry:_ ~on_event:_ request -> check_request request;Ok response)} in
      let options = { (binding_options target) with transport=Some transport;
        reasoning_source_change=Binding_projection.Exclude_unselected } in
      let config = { (Types.default_config ~model:target.model_id) with max_tokens=Some 64 } in
      let agent = Agent.resume ~media_store:(Agent_core.History.Memory_store.create ()) ~net
          ~checkpoint:cp ~config ~options ~tools:[tool] () |> binding_resume_ok in
      let outcome = if stream then Agent.run_stream ~sw ~on_event:ignore agent "next"
        else Agent.run ~sw agent "next" in
      (match outcome with Ok _ -> () | Error error -> Alcotest.fail (Error.to_string error));
      Alcotest.(check int) "one request reaches the Anthropic transport" 1 !requests;
      Alcotest.(check bool) "canonical foreign reasoning remains" true
        (List.for_all2 (=) cp.messages
           (List.take (List.length cp.messages) (Agent.state agent).messages));
      Alcotest.(check bool) "checkpoint remains unchanged" true (before=Checkpoint.to_json cp))
      [false;true];
    Alcotest.(check int) "finished tool effects are never replayed" 0 !tool_calls))
;;

(* A caller query after an answered foreign tool call, with no assistant reply
   in between, closes that exchange by the same rule selection uses
   (RFC-0507 §3.2). The request goes out with the call and its result and
   without the foreign reasoning. *)
let test_binding_anthropic_sends_answered_foreign_tool_call () = with_net (fun net ->
  Eio.Switch.run (fun sw ->
    let qwen = binding_provider ~model:"qwen3.8-flash" "https://qwen.example" in
    let answered = { (binding_message (binding_source qwen)) with
      content=[Types.Thinking {content="qwen-reasoning";signature=None};
        Types.ToolUse {id="answered-call";name="inspect";input=`Assoc []}] } in
    let cp = binding_checkpoint qwen
        [ Types.user_msg "inspect"; answered
        ; Types.tool_result_msg ~tool_use_id:"answered-call" ~content:"answered-result" () ] in
    let target = anthropic_target () in
    let tool = Tool.create ~name:"inspect" ~description:"Inspect" ~parameters:[] (fun _ ->
      Ok {Types.content="unexpected re-execution";content_blocks=None;_meta=None}) in
    List.iter (fun stream ->
      let requests = ref 0 in
      let check_request (request : Llm_provider.Llm_transport.completion_request) =
        incr requests;
        let artifact = match Llm_provider.Complete_common.serialize_http_request ~stream
            ~config:request.config ~messages:request.messages ~tools:request.tools with
          | Ok artifact -> artifact
          | Error _ -> Alcotest.fail "Anthropic request serialization failed" in
        let open Yojson.Safe.Util in
        let blocks = member "messages" (Yojson.Safe.from_string artifact.body) |> to_list
          |> List.concat_map (fun message -> match member "content" message with
            | `List blocks -> blocks | _ -> []) in
        let typed kind = List.filter (fun block -> member "type" block = `String kind) blocks in
        Alcotest.(check int) "the foreign reasoning is not sent" 0
          (List.length (typed "thinking" @ typed "redacted_thinking"));
        Alcotest.(check (list string)) "the answered tool call is sent" ["answered-call"]
          (List.map (fun block -> member "id" block |> to_string) (typed "tool_use"));
        Alcotest.(check (list string)) "its result is sent" ["answered-call"]
          (List.map (fun block -> member "tool_use_id" block |> to_string) (typed "tool_result"));
        Alcotest.(check bool) "the new caller query is sent" true
          (List.exists (fun block ->
             member "type" block = `String "text" && member "text" block = `String "next query")
             blocks)
      in
      let response = Provider_mock.text_response "continued" [] in
      let transport = Llm_provider.Llm_transport.custom {
        complete_sync=(fun request -> check_request request;{response=Ok response;latency_ms=Some 0});
        complete_stream=(fun ?on_telemetry:_ ~on_event:_ request -> check_request request;Ok response)} in
      let options = { (binding_options target) with transport=Some transport;
        reasoning_source_change=Binding_projection.Exclude_unselected } in
      let config = { (Types.default_config ~model:target.model_id) with max_tokens=Some 64 } in
      let agent = Agent.resume ~media_store:(Agent_core.History.Memory_store.create ()) ~net
          ~checkpoint:cp ~config ~options ~tools:[tool] () |> binding_resume_ok in
      let outcome = if stream then Agent.run_stream ~sw ~on_event:ignore agent "next query"
        else Agent.run ~sw agent "next query" in
      (match outcome with Ok _ -> () | Error error -> Alcotest.fail (Error.to_string error));
      Alcotest.(check int) "one request reaches the Anthropic transport" 1 !requests)
      [false;true]))
;;

(* A failover inside a tool-use exchange hands Claude a tool call it did not
   reason about. The Messages wire needs that exchange's own thinking, which a
   foreign producer cannot give, so no request leaves and the refusal tells the
   lane to try another binding instead of naming a configuration fault. *)
let test_binding_anthropic_refuses_open_foreign_exchange () = with_net (fun net ->
  Eio.Switch.run (fun sw ->
    let qwen = binding_provider ~model:"qwen3.8-flash" "https://qwen.example" in
    let open_exchange = { (binding_message (binding_source qwen)) with
      content=[Types.Thinking {content="qwen-reasoning";signature=None};
        Types.ToolUse {id="open-call";name="inspect";input=`Assoc []}] } in
    let cp = binding_checkpoint qwen
        [ Types.user_msg "inspect"; open_exchange
        ; Types.tool_result_msg ~tool_use_id:"open-call" ~content:"open-result" () ] in
    let target = anthropic_target () in
    List.iter (fun stream ->
      let requests = ref 0 in
      let response = Provider_mock.text_response "unexpected" [] in
      let transport = Llm_provider.Llm_transport.custom {
        complete_sync=(fun _ -> incr requests;{response=Ok response;latency_ms=Some 0});
        complete_stream=(fun ?on_telemetry:_ ~on_event:_ _ -> incr requests;Ok response)} in
      let options = { (binding_options target) with transport=Some transport;
        reasoning_source_change=Binding_projection.Exclude_unselected } in
      let config = { (Types.default_config ~model:target.model_id) with max_tokens=Some 64 } in
      let agent = Agent.resume ~media_store:(Agent_core.History.Memory_store.create ()) ~net
          ~checkpoint:cp ~config ~options () |> binding_resume_ok in
      let api_strategy = if stream then Agent.Stream {on_event=ignore;on_telemetry=None}
        else Agent.Sync in
      (match Agent.Advanced.continue_detailed ~sw ~api_strategy
          ~on_tool_boundary:(fun _ -> Agent.Advanced.Continue) agent with
       | Error ({error=Error.Api (Llm_provider.Retry.InvalidRequest
           {reason=Llm_provider.Retry.Attempt_rejected;_});provider_failure} : Agent.detailed_error) ->
         (* The binding refused a request it would not send, so the failure
            names that binding and request validation, not a configuration
            with no binding. *)
         (match provider_failure with
          | Some {Provider_failure_attribution.evidence=Request_validation;binding=Some _;_} -> ()
          | Some _ | None ->
            Alcotest.fail "the refusal must be attributed to this binding's request validation")
       | Error {error;_} -> Alcotest.fail (Error.to_string error)
       | Ok _ -> Alcotest.fail "an open foreign exchange must not reach Anthropic");
      Alcotest.(check int) "no request leaves" 0 !requests;
      Alcotest.(check bool) "the open exchange stays canonical" true
        ((Agent.state agent).messages = cp.messages))
      [false;true]))
;;

(* ── Test runner ─────────────────────────────────────────────── *)

let () =
  let open Alcotest in
  run
    "Session Resume"
    [ "provider replay binding", [
        test_case "explicit provider/model failover preserves canonical history and tool effects" `Quick test_binding_explicit_source_change;
        test_case "source-change exclusion protects active replay and control boundaries" `Quick test_binding_source_change_respects_active_replay;
        test_case "source-change admission follows actual tools and hook suppression in both dispatch modes" `Quick test_binding_source_change_uses_effective_request_tools;
        test_case "source-change exclusion still rejects invalid provenance" `Quick test_binding_source_change_rejects_invalid_provenance;
        test_case "Anthropic sends finished turns other providers produced" `Quick test_binding_anthropic_sends_finished_foreign_turns;
        test_case "Anthropic sends an answered tool call before a new query" `Quick test_binding_anthropic_sends_answered_foreign_tool_call;
        test_case "Anthropic refuses an open exchange another provider produced" `Quick test_binding_anthropic_refuses_open_foreign_exchange;
        test_case "same exact binding retains canonical history" `Quick test_binding_exact_resume;
        test_case "provider model and replay contract mismatch" `Quick test_binding_provider_model_and_contract_mismatch;
        test_case "restore reads no media" `Quick test_restore_reads_no_media;
        test_case "declared text endpoint and path rotation" `Quick test_binding_declared_rotation;
        test_case "signed source endpoint and path mismatch" `Quick test_binding_signed_rotation_refused;
        test_case "mixed-producer history" `Quick test_binding_mixed_history;
        test_case "text-only source change" `Quick test_binding_text_only_rebind;
        test_case "explicit caller replay exclusion" `Quick test_binding_explicit_disable;
        test_case "missing and corrupt artifact provenance" `Quick test_binding_missing_and_corrupt_source;
        test_case "inline Chat carrier producers" `Quick test_binding_inline_carrier_producers;
        test_case "non-dispatch restoration" `Quick test_binding_non_dispatch_restore;
        test_case "direct old and invalid checkpoint" `Quick test_binding_direct_old_or_invalid_checkpoint;
        test_case "hook cannot silently re-enable incompatible replay" `Quick test_binding_hook_cannot_reenable_incompatible_replay]
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
