(** Ollama native API request building and response parsing.

    Uses [/api/chat] endpoint with [think] parameter for thinking control
    except token-controlled models whose documented thinking control is
    chat-template based,
    and [options] object for sampling parameters.

    @since 0.113.0 *)

open Types

type request_artifact = string Request_artifact_internal.t

let request_payload = Request_artifact_internal.payload
let request_output_token_receipt = Request_artifact_internal.output_token_receipt
let ( let* ) = Result.bind

(* ── Request building ────────────────────────────────── *)

(** Build Ollama native [/api/chat] request body.
    Key differences from Openai compat:
    - [think] parameter (boolean) instead of [chat_template_kwargs], except
      token-controlled models where thinking is triggered by a catalog-declared
      token in the system prompt
    - Sampling params go inside [options] object
    - [num_predict] instead of [max_tokens]
    - No [tool_choice] support *)
let build_request_artifact
      ?(stream = false)
      ~(config : Provider_config.t)
      ~(messages : message list)
      ?(tools : Yojson.Safe.t list = [])
      ()
  =
  let think_requested = Option.value config.enable_thinking ~default:false in
  let caps =
    match Provider_config.capabilities_for_config_model config with
    | Some c -> c
    | None -> Capabilities.ollama_capabilities
  in
  let output_token_receipt =
    Backend_openai_request.output_token_receipt
      ~envelope:Types.Ollama_options_num_predict
      config
  in
  (* The chat-template token injection is shared with the OpenAI-compat request
     builder ([Backend_openai_serialize]) so the same catalog row cannot be
     handled asymmetrically (oas#2483). The token is carried by
     [Chat_template_token] in the resolved capabilities (fail-closed at
     catalog/manifest load), so there is no per-request token lookup that could
     be missing. *)
  let chat_template_token_thinking =
    Backend_openai_serialize.chat_template_thinking_active
      ~thinking_requested:think_requested
      ~caps
  in
  let system_prompt =
    Backend_openai_serialize.system_prompt_with_thinking_token
      ~thinking_requested:think_requested
      ~config
      ~caps
  in
  let projected_messages =
    match
      Reasoning_history_projection.project_for_provider_config
        ~assistant_has_payload:(fun content -> content <> [])
        ~reasoning_block_supported:(function
          | Thinking _ -> true
          | ReasoningDetails _
          | RedactedThinking _
          | Text _
          | ToolUse _
          | ToolResult _
          | Image _
          | Document _
          | Audio _ -> false)
        config
        messages
    with
    | Error error ->
      invalid_arg
        ("Backend_ollama.build_request: "
         ^ Reasoning_history_projection.error_to_string error)
    | Ok projection ->
      Reasoning_history_projection.observe ~component:"backend_ollama" projection;
      projection.messages
  in
  let provider_messages =
    match
      Backend_openai_serialize.ollama_messages_of_history
        ~modality_priority:caps.modality_priority
        ~supports_image_input:caps.supports_image_input
        ~supports_document_input:caps.supports_document_input
        projected_messages
    with
    | Error error -> invalid_arg ("Backend_ollama.build_request: " ^ error)
    | Ok messages ->
      (match system_prompt with
       | Some s when not (Api_common.string_is_blank s) ->
         [ `Assoc
             [ "role", `String "system"; "content", `String (Utf8_sanitize.sanitize s) ]
         ]
       | _ -> [])
      @ messages
  in
  let body = [ "model", `String config.model_id; "messages", `List provider_messages ] in
  (* Emit native thinking control only when the caller supplied it. Some
     token-controlled models are the exception: current Ollama rejects
     [think:true] even though the model's documented control is a
     chat-template token. For those catalog-declared rows we inject the token
     into the system turn and omit the top-level [think] field so Ollama returns
     [message.thinking] instead of failing the request. *)
  let body =
    if chat_template_token_thinking
    then body
    else (
      match config.enable_thinking with
      | Some enabled -> ("think", `Bool enabled) :: body
      | None -> body)
  in
  (* Ollama defaults to stream=true, so always send explicit value *)
  let body = ("stream", `Bool stream) :: body in
  (* Ollama accepts [keep_alive] as either integer seconds or a duration
     string. Preserve caller omission; in particular, permanent residency is
     an operator policy and is never injected by the SDK. Explicit integer
     values such as [-1] must use the JSON integer wire form because Ollama
     parses string values as durations. *)
  let body =
    match config.keep_alive with
    | None -> body
    | Some value ->
      let keep_alive_json : Yojson.Safe.t =
        match int_of_string_opt value with
        | Some seconds -> `Int seconds
        | None -> `String value
      in
      ("keep_alive", keep_alive_json) :: body
  in
  let body =
    match config.response_format with
    | Types.JsonSchema schema -> ("format", schema) :: body
    | Types.JsonMode -> ("format", `String "json") :: body
    | Types.Off -> body
  in
  let body =
    match tools with
    | [] -> body
    | ts ->
      (* The native /api/chat wire has no parallel-disable field (unlike
         OpenAI [parallel_tool_calls] or Anthropic
         [tool_choice.disable_parallel_tool_use]), so an effective disable
         request cannot be honored — surface the drop instead of ignoring
         it silently, mirroring the Gemini backend. *)
      if
        Capabilities.effective_disable_parallel_tool_use
          ~caller_disabled:config.disable_parallel_tool_use
          ~supports_parallel_tool_calls:caps.supports_parallel_tool_calls
          ~tools_present:true
      then
        Backend_openai.warn_capability_drop
          ~model_id:config.model_id
          ~field:"disable_parallel_tool_use";
      ("tools", `List (List.map Backend_openai_serialize.build_openai_tool_json ts))
      :: body
  in
  (* Sampling parameters go inside Ollama's "options" object.

     top_k / min_p are now capability-gated — not because native
     Ollama rejects them (its Options struct has both, llama.cpp
     samplers support them), but to mirror the #830/#831 contract
     across every OAS serializer so a future capability record that
     lowers either flag actually takes effect everywhere in the
     request-build pipeline.

     For the default ollama_capabilities (inherited from
     openai_compat_chat_extended_capabilities) both flags are true, so
     behaviour is byte-identical for the common path. The gate only
     fires when an operator explicitly sets [supports_min_p = false]
     or [supports_top_k = false] for a specific Ollama variant — at
     which point the one-shot WARN from Backend_openai also fires. *)
  let options = ref [] in
  (* Shared budget policy (caller override clamped to catalog ceiling,
     omitted when both are unknown) — Ollama's [num_predict] is optional,
     and omission lets the server apply the model's own limit. Previously
     this arm bypassed the capability catalog and invented 16384. *)
  (match Types.output_token_receipt_effective output_token_receipt with
   | Some mt -> options := ("num_predict", `Int mt) :: !options
   | None -> ());
  (match config.temperature with
   | Some t -> options := ("temperature", `Float t) :: !options
   | None -> ());
  (match config.top_p with
   | Some p -> options := ("top_p", `Float p) :: !options
   | None -> ());
  (match config.top_k with
   | Some k when caps.supports_top_k -> options := ("top_k", `Int k) :: !options
   | Some _ ->
     Backend_openai.warn_capability_drop ~model_id:config.model_id ~field:"top_k"
   | None -> ());
  (match config.min_p with
   | Some p when caps.supports_min_p -> options := ("min_p", `Float p) :: !options
   | Some _ ->
     Backend_openai.warn_capability_drop ~model_id:config.model_id ~field:"min_p"
   | None -> ());
  (match caps.supports_seed, config.seed with
   | true, Some seed -> options := ("seed", `Int seed) :: !options
   | false, Some _ ->
     invalid_arg
       (Printf.sprintf
          "Backend_ollama.build_request: model %S does not support seed"
          config.model_id)
   | true, None | false, None -> ());
  (* num_ctx: per-request KV cache allocation in tokens. Honored by Ollama
     only. [None] omits the field so Ollama uses its own default. Invalid
     explicit values fail at the request boundary instead of disappearing. *)
  (match config.num_ctx with
   | Some n when n > 0 -> options := ("num_ctx", `Int n) :: !options
   | Some n ->
     invalid_arg
       (Printf.sprintf "Backend_ollama.build_request: num_ctx must be positive, got %d" n)
   | None -> ());
  let body = ("options", `Assoc !options) :: body in
  Request_artifact_internal.create
    ~payload:(Yojson.Safe.to_string (`Assoc body))
    ~output_token_receipt
;;

let build_request ?stream ~config ~messages ?tools () =
  build_request_artifact ?stream ~config ~messages ?tools () |> request_payload
;;

(* ── Response parsing ────────────────────────────────── *)

let parse_ollama_tool_arguments ~tool_index json =
  match json with
  | `Assoc _ as input -> Ok input
  | `String s when not (Api_common.string_is_blank s) ->
    (match Yojson.Safe.from_string s with
     | `Assoc _ as input -> Ok input
     | `Null | `List _ | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _ ->
       Error
         (Printf.sprintf
            "malformed_ollama_tool_call_arguments:index:%d:not_object"
            tool_index)
     | exception Yojson.Json_error msg ->
       Error
         (Printf.sprintf
            "malformed_ollama_tool_call_arguments:index:%d:%s"
            tool_index
            msg))
  | `Null | `String _ ->
    Error
      (Printf.sprintf "malformed_ollama_tool_call:index:%d:missing_arguments" tool_index)
  | `List _ | `Int _ | `Intlit _ | `Float _ | `Bool _ ->
    Error
      (Printf.sprintf
         "malformed_ollama_tool_call_arguments:index:%d:not_object"
         tool_index)
;;

let parse_ollama_tool_call ~tool_index tc =
  let open Yojson.Safe.Util in
  let* fn =
    match tc |> member "function" with
    | `Assoc _ as fn -> Ok fn
    | `Null | `List _ | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _ ->
      Error
        (Printf.sprintf "malformed_ollama_tool_call:index:%d:missing_function" tool_index)
  in
  let* name =
    match fn |> member "name" |> to_string_option with
    | Some name when not (Api_common.string_is_blank name) -> Ok name
    | Some _ | None ->
      Error (Printf.sprintf "malformed_ollama_tool_call:index:%d:missing_name" tool_index)
  in
  let* input = parse_ollama_tool_arguments ~tool_index (fn |> member "arguments") in
  let id =
    match tc |> member "id" |> to_string_option with
    | Some id when not (Api_common.string_is_blank id) -> id
    | Some _ | None -> Api_common.fresh_tool_use_id ()
  in
  Ok (ToolUse { id; name; input })
;;

let parse_ollama_tool_calls = function
  | `Null -> Ok []
  | `List calls ->
    let rec loop acc index = function
      | [] -> Ok (List.rev acc)
      | tc :: rest ->
        (match parse_ollama_tool_call ~tool_index:index tc with
         | Ok tool_call -> loop (tool_call :: acc) (index + 1) rest
         | Error _ as error -> error)
    in
    loop [] 0 calls
  | `Assoc _ | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _ ->
    Error "malformed_ollama_tool_calls:not_list"
;;

let parse_ollama_response json_str =
  let open Yojson.Safe.Util in
  let json = Yojson.Safe.from_string json_str in
  match json |> member "error" with
  | `String s -> Error s
  | `Assoc _ as err -> Error (Yojson.Safe.to_string err)
  | `List _ | `Int _ | `Intlit _ | `Float _ | `Bool _ ->
    Error "malformed_ollama_error:not_string_or_object"
  | `Null ->
    let message = json |> member "message" in
    let* text_content, tool_blocks, thinking_blocks =
      match message with
      | `Assoc _ ->
        let* txt =
          match message |> member "content" with
          | `String s -> Ok s
          | `Null -> Ok ""
          | `Assoc _ | `List _ | `Int _ | `Intlit _ | `Float _ | `Bool _ ->
            Error "malformed_ollama_message:content_not_string"
        in
        let* tools = parse_ollama_tool_calls (message |> member "tool_calls") in
        if List.length tools > 1
        then
          Diag.debug
            "backend_ollama"
            "parsed %d Ollama tool_calls from one assistant response"
            (List.length tools);
        let* thinking =
          match message |> member "thinking" with
          | `String s when not (Api_common.string_is_blank s) ->
            Ok [ Thinking { signature = None; content = s } ]
          | `String _ | `Null -> Ok []
          | `Assoc _ | `List _ | `Int _ | `Intlit _ | `Float _ | `Bool _ ->
            Error "malformed_ollama_message:thinking_not_string"
        in
        Ok (txt, tools, thinking)
      | `Null -> Error "malformed_ollama_response:missing_message"
      | `List _ | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _ ->
        Error "malformed_ollama_response:message_not_object"
    in
    let* done_reason =
      match json |> member "done_reason" |> to_string_option with
      | Some done_reason -> Ok done_reason
      | None -> Error "malformed_ollama_response:missing_done_reason"
    in
    let stop_reason =
      Stop_reason_wire.of_finish
        (Stop_reason_wire.wire_finish_of_string done_reason)
        ~has_tool_blocks:(tool_blocks <> [])
    in
    let input_tokens = Cli_common_json.member_int "prompt_eval_count" json in
    let output_tokens = Cli_common_json.member_int "eval_count" json in
    let usage =
      if input_tokens = 0 && output_tokens = 0
      then None
      else
        Some
          { input_tokens
          ; output_tokens
          ; cache_creation_input_tokens = 0
          ; cache_read_input_tokens = 0
          ; cost_usd = None
          }
    in
    let telemetry =
      let system_fingerprint = None in
      (* Ollama reports durations in nanoseconds. Surface them as
       inference_timings so downstream can distinguish hardware
       decode rate from wall-clock tok/s. *)
      let timings =
        let prompt_n = json |> member "prompt_eval_count" |> to_int_option in
        let prompt_ns = json |> member "prompt_eval_duration" |> to_int_option in
        let predicted_n = json |> member "eval_count" |> to_int_option in
        let predicted_ns = json |> member "eval_duration" |> to_int_option in
        let any_set =
          Option.is_some prompt_n
          || Option.is_some prompt_ns
          || Option.is_some predicted_n
          || Option.is_some predicted_ns
        in
        if not any_set
        then None
        else (
          let ms_of_ns ns_opt = Option.map (fun ns -> float_of_int ns /. 1e6) ns_opt in
          let per_second n_opt ns_opt =
            match n_opt, ns_opt with
            | Some n, Some ns when ns > 0 ->
              Some (float_of_int n /. (float_of_int ns /. 1e9))
            | _ -> None
          in
          Some
            { Types.prompt_n
            ; prompt_ms = ms_of_ns prompt_ns
            ; prompt_per_second = per_second prompt_n prompt_ns
            ; predicted_n
            ; predicted_ms = ms_of_ns predicted_ns
            ; predicted_per_second = per_second predicted_n predicted_ns
            ; cache_n = None
            })
      in
      let reasoning_tokens = None in
      Some
        { Types.default_inference_telemetry with
          system_fingerprint
        ; timings
        ; reasoning_tokens
        }
    in
    Ok
      { id = json |> member "model" |> to_string_option |> Option.value ~default:"ollama"
      ; model = Cli_common_json.member_str "model" json
      ; stop_reason
      ; content =
          thinking_blocks
          @ (if Api_common.string_is_blank text_content then [] else [ Text text_content ])
          @ tool_blocks
      ; usage
      ; telemetry
      }
;;

(* ── Inline tests ────────────────────────────────── *)

[@@@coverage off]

let%test "build_request omits keep_alive when caller omits it" =
  let config =
    Provider_config.make
      ~kind:Ollama
      ~model_id:"dashscope-3.5:35b-a3b-nvfp4"
      ~base_url:"http://127.0.0.1:11434"
      ()
  in
  let messages =
    [ { role = User
      ; content = [ Text "hi" ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ]
  in
  let body = build_request ~config ~messages () in
  let json = Yojson.Safe.from_string body in
  Yojson.Safe.Util.member "keep_alive" json = `Null
;;

let%test "build_request preserves explicit keep_alive duration" =
  let config =
    Provider_config.make
      ~kind:Ollama
      ~model_id:"dashscope-3.5:35b-a3b-nvfp4"
      ~base_url:"http://127.0.0.1:11434"
      ~keep_alive:"5m"
      ()
  in
  let messages =
    [ { role = User
      ; content = [ Text "hi" ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ]
  in
  let body = build_request ~config ~messages () in
  let json = Yojson.Safe.from_string body in
  let open Yojson.Safe.Util in
  json |> member "keep_alive" |> to_string = "5m"
;;

let%test "build_request serializes explicit keep_alive integer as JSON integer" =
  let config =
    Provider_config.make
      ~kind:Ollama
      ~model_id:"dashscope-3.5:35b-a3b-nvfp4"
      ~base_url:"http://127.0.0.1:11434"
      ~keep_alive:"-1"
      ()
  in
  let messages =
    [ { role = User
      ; content = [ Text "hi" ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ]
  in
  let body = build_request ~config ~messages () in
  let json = Yojson.Safe.from_string body in
  let open Yojson.Safe.Util in
  json |> member "keep_alive" |> to_int = -1
;;

let%test "build_request config.num_ctx injected into options" =
  let config =
    Provider_config.make
      ~kind:Ollama
      ~model_id:"dashscope-3:8b"
      ~base_url:"http://127.0.0.1:11434"
      ~num_ctx:8192
      ()
  in
  let messages =
    [ { role = User
      ; content = [ Text "hi" ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ]
  in
  let body = build_request ~config ~messages () in
  let json = Yojson.Safe.from_string body in
  let open Yojson.Safe.Util in
  json |> member "options" |> member "num_ctx" |> to_int = 8192
;;

let%test "build_request omits num_ctx when None" =
  let config =
    Provider_config.make
      ~kind:Ollama
      ~model_id:"dashscope-3:8b"
      ~base_url:"http://127.0.0.1:11434"
      ()
  in
  let messages =
    [ { role = User
      ; content = [ Text "hi" ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ]
  in
  let body = build_request ~config ~messages () in
  let json = Yojson.Safe.from_string body in
  let open Yojson.Safe.Util in
  json |> member "options" |> member "num_ctx" = `Null
;;

let%test "build_request emits only an explicit supported seed" =
  let config =
    Provider_config.make
      ~kind:Ollama
      ~model_id:"dashscope-3:8b"
      ~base_url:"http://127.0.0.1:11434"
      ~seed:42
      ~model_capabilities_override:
        { Capabilities.default_capabilities with supports_seed = true }
      ()
  in
  let body = build_request ~config ~messages:[] () in
  let json = Yojson.Safe.from_string body in
  let open Yojson.Safe.Util in
  json |> member "options" |> member "seed" |> to_int = 42
;;

let%test "build_request omits seed when caller omits it" =
  let config =
    Provider_config.make
      ~kind:Ollama
      ~model_id:"dashscope-3:8b"
      ~base_url:"http://127.0.0.1:11434"
      ()
  in
  let body = build_request ~config ~messages:[] () in
  let json = Yojson.Safe.from_string body in
  Yojson.Safe.Util.(json |> member "options" |> member "seed") = `Null
;;

let%test "build_request rejects non-positive explicit num_ctx" =
  let config =
    Provider_config.make
      ~kind:Ollama
      ~model_id:"dashscope-3:8b"
      ~base_url:"http://127.0.0.1:11434"
      ~num_ctx:0
      ()
  in
  match build_request ~config ~messages:[] () with
  | _ -> false
  | exception Invalid_argument message ->
    String.equal message "Backend_ollama.build_request: num_ctx must be positive, got 0"
;;

let%test "parse_ollama_response populates timings from eval_count/eval_duration" =
  let json =
    {|{"model":"dashscope-3.5:35b-a3b-nvfp4","done":true,"done_reason":"stop",
       "message":{"role":"assistant","content":"hi"},
       "prompt_eval_count":100,"prompt_eval_duration":200000000,
       "eval_count":120,"eval_duration":2000000000}|}
  in
  match parse_ollama_response json with
  | Error _ -> false
  | Ok resp ->
    (match resp.telemetry with
     | Some { timings = Some t; _ } ->
       t.predicted_n = Some 120
       && (match t.predicted_per_second with
           | Some v -> abs_float (v -. 60.0) < 0.001
           | None -> false)
       && t.prompt_n = Some 100
       &&
         (match t.prompt_per_second with
         | Some v -> abs_float (v -. 500.0) < 0.001
         | None -> false)
     | _ -> false)
;;

let%test "parse_ollama_response maps prompt/eval counts to usage" =
  let json =
    {|{"model":"dashscope-3.5:35b-a3b-nvfp4","done":true,"done_reason":"stop",
       "message":{"role":"assistant","content":"hi"},
       "prompt_eval_count":17,"eval_count":23}|}
  in
  match parse_ollama_response json with
  | Error _ -> false
  | Ok resp ->
    (match resp.usage with
     | Some usage ->
       usage.input_tokens = 17
       && usage.output_tokens = 23
       && usage.cache_creation_input_tokens = 0
       && usage.cache_read_input_tokens = 0
     | None -> false)
;;

let%test "parse_ollama_response guards zero eval_duration" =
  let json =
    {|{"model":"dashscope-3.5:35b-a3b-nvfp4","done":true,"done_reason":"stop",
       "message":{"role":"assistant","content":"hi"},
       "eval_count":10,"eval_duration":0}|}
  in
  match parse_ollama_response json with
  | Error _ -> false
  | Ok resp ->
    (match resp.telemetry with
     | Some { timings = Some t; _ } ->
       (* eval_count present → timings record exists,
          but predicted_per_second is None because duration is 0. *)
       t.predicted_n = Some 10 && t.predicted_per_second = None
     | _ -> false)
;;

let%test "parse_ollama_response returns timings=None when no timing fields present" =
  let json =
    {|{"model":"dashscope-3.5:35b-a3b-nvfp4","done":true,"done_reason":"stop",
       "message":{"role":"assistant","content":"hi"}}|}
  in
  match parse_ollama_response json with
  | Error _ -> false
  | Ok resp ->
    (match resp.telemetry with
     | Some { timings = None; _ } -> true
     | _ -> false)
;;

let%test "build_request sets think=true when enable_thinking=true" =
  let config =
    Provider_config.make
      ~kind:Ollama
      ~model_id:"dashscope-3:8b"
      ~base_url:"http://127.0.0.1:11434"
      ~enable_thinking:true
      ()
  in
  let body = build_request ~config ~messages:[] () in
  let json = Yojson.Safe.from_string body in
  let open Yojson.Safe.Util in
  json |> member "think" |> to_bool = true
;;

let%test "build_request sets think=false when enable_thinking=false" =
  let config =
    Provider_config.make
      ~kind:Ollama
      ~model_id:"dashscope-3:8b"
      ~base_url:"http://127.0.0.1:11434"
      ~enable_thinking:false
      ()
  in
  let body = build_request ~config ~messages:[] () in
  let json = Yojson.Safe.from_string body in
  let open Yojson.Safe.Util in
  json |> member "think" |> to_bool = false
;;

let%test "build_request omits think when caller omits it" =
  let config =
    Provider_config.make
      ~kind:Ollama
      ~model_id:"dashscope-3:8b"
      ~base_url:"http://127.0.0.1:11434"
      ()
  in
  let body = build_request ~config ~messages:[] () in
  let json = Yojson.Safe.from_string body in
  Yojson.Safe.Util.member "think" json = `Null
;;

let%test "build_request maps max_tokens to num_predict in options" =
  let config =
    Provider_config.make
      ~kind:Ollama
      ~model_id:"dashscope-3:8b"
      ~base_url:"http://127.0.0.1:11434"
      ~max_tokens:2048
      ()
  in
  let body = build_request ~config ~messages:[] () in
  let json = Yojson.Safe.from_string body in
  let open Yojson.Safe.Util in
  json |> member "options" |> member "num_predict" |> to_int = 2048
;;

let%test
    "build_request includes top_k in options when supports_top_k=true (default ollama \
     caps)"
  =
  (* Pins the supported path: default Ollama capabilities have
     supports_top_k=true, so the serializer threads top_k into options.
     The capability-gated drop path (supports_top_k=false ->
     warn_capability_drop) is covered by the OpenAI-compat tests in
     backend_openai.ml; Ollama uses the same gate via shared helpers. *)
  let config =
    Provider_config.make
      ~kind:Ollama
      ~model_id:"dashscope-3:8b"
      ~base_url:"http://127.0.0.1:11434"
      ~top_k:40
      ()
  in
  let body = build_request ~config ~messages:[] () in
  let json = Yojson.Safe.from_string body in
  let open Yojson.Safe.Util in
  json |> member "options" |> member "top_k" |> to_int = 40
;;

let%test "parse_ollama_response maps done_reason=tool_calls to StopToolUse" =
  let json =
    {|{"model":"dashscope-3:8b","done":true,"done_reason":"tool_calls",
       "message":{"role":"assistant","content":"",
         "tool_calls":[{"function":{"name":"get_weather","arguments":"{\"city\":\"Seoul\"}"}}]}}|}
  in
  match parse_ollama_response json with
  | Error _ -> false
  | Ok resp ->
    resp.stop_reason = Types.StopToolUse
    &&
      (match resp.content with
      | [ Types.ToolUse { name = "get_weather"; _ } ] -> true
      | _ -> false)
;;

let%test "parse_ollama_response rejects tool_calls without tool blocks" =
  match
    parse_ollama_response
      {|{"model":"dashscope-3:8b","done":true,"done_reason":"tool_calls","message":{"role":"assistant","content":""}}|}
  with
  | Ok response -> response.stop_reason = Types.UnmatchedToolCalls
  | Error _ -> false
;;

let%test "parse_ollama_response trusts complete tool blocks over stop label" =
  let json =
    {|{"model":"dashscope-3:8b","done":true,"done_reason":"stop",
       "message":{"role":"assistant","content":"",
         "tool_calls":[{"function":{"name":"get_weather","arguments":"{\"city\":\"Seoul\"}"}}]}}|}
  in
  match parse_ollama_response json with
  | Ok response -> response.stop_reason = Types.StopToolUse
  | Error _ -> false
;;

let%test "parse_ollama_response keeps unknown reason non-executable" =
  let json =
    {|{"model":"dashscope-3:8b","done":true,"done_reason":"provider_terminal",
       "message":{"role":"assistant","content":"",
         "tool_calls":[{"function":{"name":"get_weather","arguments":"{\"city\":\"Seoul\"}"}}]}}|}
  in
  match parse_ollama_response json with
  | Ok response -> response.stop_reason = Types.Unknown "provider_terminal"
  | Error _ -> false
;;

let%test "parse_ollama_response maps overflow done_reason to ContextWindowExceeded" =
  match
    parse_ollama_response
      {|{"model":"dashscope-3:8b","done":true,"done_reason":"model_context_window_exceeded","message":{"role":"assistant","content":""}}|}
  with
  | Ok response -> response.stop_reason = Types.ContextWindowExceeded
  | Error _ -> false
;;

let%test "parse_ollama_response returns Error on error field" =
  let json = {|{"error":"model \"nonexistent\" not found, try pulling it first"}|} in
  match parse_ollama_response json with
  | Error msg -> String.starts_with ~prefix:"model" msg
  | Ok _ -> false
;;

let%test "parse_ollama_response rejects a missing message" =
  match parse_ollama_response {|{"model":"dashscope-3:8b","done":true}|} with
  | Error "malformed_ollama_response:missing_message" -> true
  | Error _ | Ok _ -> false
;;

let%test "parse_ollama_response rejects a missing done reason" =
  match
    parse_ollama_response
      {|{"model":"dashscope-3:8b","done":true,"message":{"role":"assistant","content":"ok"}}|}
  with
  | Error "malformed_ollama_response:missing_done_reason" -> true
  | Error _ | Ok _ -> false
;;

let%test "parse_ollama_response rejects a non-object message" =
  match parse_ollama_response {|{"message":"not-an-object"}|} with
  | Error "malformed_ollama_response:message_not_object" -> true
  | Error _ | Ok _ -> false
;;

let%test "parse_ollama_response rejects malformed message content" =
  match parse_ollama_response {|{"message":{"content":["not","text"]}}|} with
  | Error "malformed_ollama_message:content_not_string" -> true
  | Error _ | Ok _ -> false
;;

let%test "parse_ollama_response extracts thinking block from message" =
  let json =
    {|{"model":"dashscope-3:8b","done":true,"done_reason":"stop",
       "message":{"role":"assistant","content":"The answer is 42.",
         "thinking":"Let me reason about this step by step."}}|}
  in
  match parse_ollama_response json with
  | Error _ -> false
  | Ok resp ->
    (match resp.content with
     | [ Types.Thinking { content = thinking }; Types.Text "The answer is 42." ] ->
       String.length thinking > 0
     | _ -> false)
;;
