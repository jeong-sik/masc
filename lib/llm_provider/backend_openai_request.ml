(** OpenAI-compatible request body building.

    Extracted from {!Backend_openai} so the top-level backend module can stay
    a compatibility facade over request construction, response parsing, and
    message serialization. *)

open Types

type request_assoc_artifact = Yojson.Safe.t Request_artifact_internal.t
type request_artifact = string Request_artifact_internal.t

let request_assoc_payload = Request_artifact_internal.payload
let request_assoc_output_token_receipt = Request_artifact_internal.output_token_receipt
let request_payload = Request_artifact_internal.payload
let request_output_token_receipt = Request_artifact_internal.output_token_receipt

(* ── Capability-drop WARN dedup ────────────────────────── *)

(** One-shot stderr WARN table, keyed by ([model_id], [field_name]).
    Reached from the capability-gated drop branches in {!build_request}
    so operators see exactly which sampling field their config was
    trying to send for which model, without the per-request WARN spam
    that would otherwise fire on every automated turn. Double-warning on
    a race is harmless and only happens once per key. *)
let capability_drop_warned : (string * string, unit) Hashtbl.t = Hashtbl.create 16

let dialect_ignored_warned : (string * string, unit) Hashtbl.t = Hashtbl.create 16

let warn_capability_drop ~model_id ~field =
  let key = model_id, field in
  if not (Hashtbl.mem capability_drop_warned key)
  then (
    Hashtbl.replace capability_drop_warned key ();
    (Metrics.get_global ()).on_capability_drop ~model_id ~field;
    Diag.warn
      "backend_openai"
      "dropping request field %s for model %s: capability record reports supports_%s = \
       false. Update Capabilities.for_model_id if this model actually supports it, \
       otherwise remove the field from your request config."
      field
      model_id
      field)
;;

let warn_dialect_ignored ~model_id ~parameter =
  let field = Capabilities.sampling_parameter_to_string parameter in
  let key = model_id, field in
  if not (Hashtbl.mem dialect_ignored_warned key)
  then (
    Hashtbl.replace dialect_ignored_warned key ();
    Diag.warn
      "backend_openai"
      "dropping request field %s for model %s: the selected reasoning dialect suppresses \
       this sampling parameter."
      field
      model_id)
;;

let add_sampling_field dialect (config : Provider_config.t) parameter value body =
  let field = Capabilities.sampling_parameter_to_string parameter in
  if
    Reasoning_dialect.ignores_sampling_param
      dialect
      ~enable_thinking:config.enable_thinking
      parameter
  then (
    warn_dialect_ignored ~model_id:config.model_id ~parameter;
    body)
  else (field, value) :: body
;;

(* ── Request building ──────────────────────────────────── *)

let effective_tool_choice (config : Provider_config.t) =
  match config.kind, config.tool_choice with
  | _, Some None_ | _, None -> None
  | Provider_config.Glm, Some Any ->
    Some (Backend_openai_serialize.tool_choice_to_openai_json Any)
  | _, Some choice ->
    (match Provider_config.validate_tool_choice_request config with
     | Error reason ->
       invalid_arg
         (Printf.sprintf "Backend_openai_request.effective_tool_choice: %s" reason)
     | Ok () -> Some (Backend_openai_serialize.tool_choice_to_openai_json choice))
;;

let effective_tools (config : Provider_config.t) tools =
  match config.tool_choice with
  | Some None_ -> []
  | _ -> tools
;;

let structured_schema_of_config (config : Provider_config.t) =
  match config.response_format with
  | JsonSchema schema -> Some schema
  | JsonMode | Off -> None
;;

let openai_json_schema_payload (schema : Yojson.Safe.t) : Yojson.Safe.t =
  match schema with
  | `Assoc fields when List.mem_assoc "name" fields && List.mem_assoc "schema" fields ->
    schema
  | _ ->
    `Assoc
      [ "name", `String (Provider_config.structured_output_name_of_schema schema)
      ; "schema", schema
      ; "strict", `Bool true
      ]
;;

let response_format_to_openai_json = function
  | Types.Off -> None
  | Types.JsonMode -> Some (`Assoc [ "type", `String "json_object" ])
  | Types.JsonSchema schema ->
    Some
      (`Assoc
          [ "type", `String "json_schema"
          ; "json_schema", openai_json_schema_payload schema
          ])
;;

(** Build Openai Chat Completions request body from {!Provider_config.t}.
    Returns a JSON string ready for HTTP POST. *)
let response_format_of_config (config : Provider_config.t) =
  match structured_schema_of_config config with
  | Some schema -> response_format_to_openai_json (Types.JsonSchema schema)
  | None when config.response_format = JsonMode ->
    response_format_to_openai_json Types.JsonMode
  | None -> None
;;

let capabilities_of_config (config : Provider_config.t) =
  match config.kind with
  | Provider_config.DashScope -> Capabilities.dashscope_capabilities
  | Provider_config.Anthropic
  | Provider_config.Kimi
  | Provider_config.OpenAI_compat
  | Provider_config.Ollama
  | Provider_config.Glm
  | Provider_config.Gemini ->
    (match Provider_config.capabilities_for_config_model config with
     | Some caps -> caps
     | None ->
       (match config.kind with
        | Provider_config.Ollama -> Capabilities.ollama_capabilities
        | Provider_config.Kimi -> Capabilities.kimi_capabilities
        | Provider_config.Glm -> Capabilities.glm_capabilities
        | Provider_config.Gemini -> Capabilities.gemini_capabilities
        | Provider_config.Anthropic -> Capabilities.anthropic_capabilities
        | Provider_config.OpenAI_compat -> Capabilities.openai_compat_chat_capabilities
        | Provider_config.DashScope -> Capabilities.dashscope_capabilities))
;;

(* Resolve the output-token budget for optional request envelopes (#2517).

   [Capabilities.max_output_tokens] is a VALIDATION CEILING — the maximum
   the provider accepts — not a request default. The two roles must not
   conflate: injecting the ceiling whenever the caller sends [None] turns
   "use the provider's default policy" into "always request the maximum
   output", and on providers whose context window bounds
   input + reasoning + output jointly (e.g. Z.AI GLM: 200K context,
   default max_tokens 65536, maximum 131072) a long prompt plus a
   ceiling-sized output request can exceed the context contract even
   though each half is individually legal.

   Policy, single-sourced here for Chat Completions ([max_tokens]),
   Responses ([max_output_tokens]), Ollama ([num_predict]) and Gemini
   ([maxOutputTokens]) — all optional fields:
   - caller [None]  -> [None]: the field is omitted and the provider
     applies its own default sized to the model's real limits. The
     catalog ceiling is never injected as a request value.
   - caller [Some n] with n above the catalog ceiling -> clamped to the
     ceiling with a one-shot WARN (avoids 400s that corrupt
     partial-commit state).
   - caller [Some n] otherwise -> emitted as-is.

   Anthropic Messages REQUIRES the field on the wire; that envelope
   resolves through [Backend_anthropic.required_max_output_tokens],
   which applies an explicit OAS required-envelope fallback (the
   catalog-declared model maximum, not a provider default) and fails loudly
   when no value is declared anywhere — no invented constants. *)
let output_token_ceiling (config : Provider_config.t) =
  (* [model_capabilities_override] is the typed declaration boundary documented
     by [Provider_config.t]: it includes caller declarations and provider/runtime
     catalog binding declarations.  It is intentionally distinct from the model
     catalog lookup below.  Do not infer provenance by comparing capability
     records or model/provider strings. *)
  match config.model_capabilities_override with
  | Some caps ->
    Option.map
      (fun value ->
         Types.output_token_ceiling ~value ~source:Types.Declared_capability_override)
      caps.max_output_tokens
  | None ->
    let caps, source =
      match Provider_config.capabilities_for_config_model config with
      | Some caps -> caps, Types.Catalog_model
      | None -> capabilities_of_config config, Types.Provider_default
    in
    Option.map
      (fun value -> Types.output_token_ceiling ~value ~source)
      caps.max_output_tokens
;;

let output_token_receipt ~envelope (config : Provider_config.t) =
  let receipt =
    Types.optional_output_token_receipt
      ~envelope
      ~requested:config.max_tokens
      ~ceiling:(output_token_ceiling config)
  in
  (match Types.output_token_receipt_policy receipt with
   | Types.Explicit_clamped ->
     warn_capability_drop ~model_id:config.model_id ~field:"max_tokens:clamp"
   | Omitted
   | Explicit
   | Required_catalog_fallback
   | Required_capability_override_fallback -> ());
  receipt
;;

let effective_max_output_tokens (config : Provider_config.t) =
  output_token_receipt ~envelope:Types.Openai_chat_max_tokens config
  |> Types.output_token_receipt_effective
;;

(* Shared tool_choice emission gate for the Chat and Responses envelopes.
   Explicit forcing ([Any] / [Tool _]) is caller intent and always reaches
   [effective_tool_choice], which fails closed on unsupported forcing.
   Advisory [Auto] is emitted only when the model supports tool_choice
   ([supports_tool_choice_override] wins over the capability record).
   [None_] / absent tool_choice resolve to [None] in
   [effective_tool_choice], so the gate value is irrelevant for them. *)
let should_emit_tool_choice (config : Provider_config.t) =
  match config.tool_choice with
  | Some (Any | Tool _) -> true
  | Some (Auto | None_) | None ->
    (match config.supports_tool_choice_override with
     | Some v -> v
     | None -> (capabilities_of_config config).supports_tool_choice)
;;

(** Build Openai Chat Completions request body from {!Provider_config.t}.
    Returns a JSON string ready for HTTP POST. *)
let build_request_assoc_artifact
      ?(stream = false)
      ~(config : Provider_config.t)
      ~(messages : message list)
      ?(tools : Yojson.Safe.t list = [])
      ()
  =
  let tools = effective_tools config tools in
  let dialect = Reasoning_dialect.for_provider_config config in
  let caps = capabilities_of_config config in
  let replay_capability =
    match Reasoning_dialect.replay_capability_for_provider_config config with
    | Ok capability -> capability
    | Error detail ->
      invalid_arg ("Backend_openai_request: invalid reasoning target: " ^ detail)
  in
  let output_token_receipt =
    output_token_receipt ~envelope:Types.Openai_chat_max_tokens config
  in
  let assistant_tool_content_format = caps.Capabilities.assistant_tool_content_format in
  (* oas#2744 — degrade an unrepresentable document to a named text placeholder
     before serialization, rather than relabelling it [image_url] (the audit's
     defect) or rejecting the whole request. Rejection retroactively broke every
     later turn of any conversation that already held a document in its history
     against a model without the capability; degrading keeps the turn live while
     still refusing to send a document as some other modality. A row that
     declares [supports_document_input] and whose wire has a document part keeps
     its native block. Image and audio blocks are untouched. *)
  let messages, _documents_degraded =
    Api_common.degrade_document_messages
      ~wire_form:Api_common.Document_chat_file_part
      ~supports_document_input:caps.Capabilities.supports_document_input
      messages
  in
  let provider_messages =
    let history =
      match
        Backend_openai_serialize.dialect_messages_of_history
          ~assistant_tool_content_format
          ~replay_capability
          dialect
          messages
      with
      | Ok history -> history
      | Error error ->
        invalid_arg
          ("Backend_openai_request: " ^ Reasoning_history_projection.error_to_string error)
    in
    (* oas#2483: inject the chat-template thinking token into the system turn for
       [Chat_template_token] rows, mirroring [backend_ollama]. Without this the
       toggle is a silent no-op on the OpenAI-compat wire ([request_control_fields]
       emits no JSON field for this format) and the model can return a
       blank-content 200 that parses as an empty turn. Caps-gated, so non-token
       models produce byte-identical wire bytes. *)
    let thinking_requested =
      Backend_openai_serialize.thinking_requested ~default:false config
    in
    let system_prompt =
      Backend_openai_serialize.system_prompt_with_thinking_token
        ~thinking_requested
        ~config
        ~caps
    in
    (match system_prompt with
     | Some s when not (Api_common.string_is_blank s) ->
       [ `Assoc
           [ "role", `String "system"; "content", `String (Utf8_sanitize.sanitize s) ]
       ]
     | _ -> [])
    @ history
  in
  (* Per-model capabilities ([caps] above) drive the [top_k] / [min_p]
     sampling-field gates further down; the output-token budget (clamp
     WARN included) is resolved by the shared
     [effective_max_output_tokens] policy and emitted here under the
     Chat Completions [max_tokens] field name — omitted entirely when
     neither caller nor catalog declares a value. *)
  let body = [ "model", `String config.model_id; "messages", `List provider_messages ] in
  let body =
    match Types.output_token_receipt_effective output_token_receipt with
    | Some mt -> body @ [ "max_tokens", `Int mt ]
    | None -> body
  in
  let body =
    match config.temperature with
    | Some t -> add_sampling_field dialect config Capabilities.Temperature (`Float t) body
    | None -> body
  in
  let body =
    match config.top_p with
    | Some p -> add_sampling_field dialect config Capabilities.Top_p (`Float p) body
    | None -> body
  in
  (* Silent drops of user-supplied sampling params are a debugging
     hazard (Glm review on #830), so emit a ONE-SHOT stderr WARN per
     (model_id, field) combination the first time a drop fires. Per-
     request WARN would spam under high-throughput agents - hence
     the dedup table. The cell is best-effort: Eio cooperative
     scheduling means two fibers racing [mem_opt]/[replace] can
     double-warn at most once per key, which is harmless. *)
  let body =
    match config.top_k with
    | Some k when caps.supports_top_k ->
      add_sampling_field dialect config Capabilities.Top_k (`Int k) body
    | Some _ ->
      warn_capability_drop ~model_id:config.model_id ~field:"top_k";
      body
    | None -> body
  in
  let body =
    match config.min_p with
    | Some p when caps.supports_min_p ->
      add_sampling_field dialect config Capabilities.Min_p (`Float p) body
    | Some _ ->
      warn_capability_drop ~model_id:config.model_id ~field:"min_p";
      body
    | None -> body
  in
  let body =
    (* Gated on the declared preserve wire (SSOT:
       [Provider_config.clear_thinking_object_request_field]), so the request
       body and the reasoning-replay gate read the same typed capability. *)
    let clear_thinking_object =
      Provider_config.clear_thinking_object_request_field
        ~preserve_thinking_control_format:caps.preserve_thinking_control_format
        ~clear_thinking:config.clear_thinking
        ~preserve_thinking:config.preserve_thinking
    in
    (match Provider_config.validate_reasoning_effort_request config with
     | Ok () -> ()
     | Error reason ->
       invalid_arg
         (Printf.sprintf "Backend_openai_request.normalized_reasoning_effort: %s" reason));
    let request_control =
      match
        Reasoning_dialect.request_control_fields
          Reasoning_dialect.Chat_completions
          dialect
          ~enable_thinking:config.enable_thinking
          ~preserve_thinking:config.preserve_thinking
          ~thinking_budget:config.thinking_budget
          ~reasoning_effort:config.reasoning_effort
          ?clear_thinking_object
          ()
      with
      | Ok artifact -> artifact
      | Error rejection ->
        invalid_arg (Reasoning_dialect.request_control_rejection_to_message rejection)
    in
    request_control.fields @ body
  in
  let body =
    if should_emit_tool_choice config
    then (
      match effective_tool_choice config with
      | Some choice_json -> ("tool_choice", choice_json) :: body
      | None -> body)
    else body
  in
  let body =
    match tools with
    | [] -> body
    | ts ->
      ("tools", `List (List.map Backend_openai_serialize.build_openai_tool_json ts))
      :: body
  in
  let body =
    let tools_present = tools <> [] in
    let disable_parallel =
      Capabilities.effective_disable_parallel_tool_use
        ~caller_disabled:config.disable_parallel_tool_use
        ~supports_parallel_tool_calls:caps.supports_parallel_tool_calls
        ~tools_present
    in
    Backend_openai_serialize.parallel_tool_calls_fields ~disable_parallel ~tools_present
    @ body
  in
  let body =
    match response_format_of_config config with
    | Some response_format -> ("response_format", response_format) :: body
    | None -> body
  in
  let body = if stream then ("stream", `Bool true) :: body else body in
  let body =
    match caps.supports_seed, config.seed with
    | true, Some seed -> ("seed", `Int seed) :: body
    | false, Some _ ->
      invalid_arg
        (Printf.sprintf
           "Backend_openai_request.build_request: model %S does not support seed"
           config.model_id)
    | true, None | false, None -> body
  in
  Request_artifact_internal.create ~payload:(`Assoc body) ~output_token_receipt
;;

let build_request_assoc ?stream ~config ~messages ?tools () =
  build_request_assoc_artifact ?stream ~config ~messages ?tools ()
  |> request_assoc_payload
;;

(** [build_request] serializes [build_request_assoc] to a JSON string.
    Keeping the Assoc-producing variant separate lets sibling backends (e.g.
    {!Backend_glm}) mutate the request Assoc directly instead of parsing the
    serialized string back — one fewer full [Yojson.Safe.from_string] +
    [Yojson.Safe.to_string] of the message body per turn. *)
let build_request_artifact
      ?(stream = false)
      ~(config : Provider_config.t)
      ~(messages : message list)
      ?(tools : Yojson.Safe.t list = [])
      ()
  =
  let assoc_artifact = build_request_assoc_artifact ~stream ~config ~messages ~tools () in
  Request_artifact_internal.create
    ~payload:(Yojson.Safe.to_string (request_assoc_payload assoc_artifact))
    ~output_token_receipt:(request_assoc_output_token_receipt assoc_artifact)
;;

let build_request ?stream ~config ~messages ?tools () =
  build_request_artifact ?stream ~config ~messages ?tools () |> request_payload
;;
