(** Shared helpers, constants, and content-block serialization for API modules.

    Extracted from agent_sdk for shared use by consumers.
    All types are from {!Llm_provider.Types}. *)

open Types

let default_base_url = "https://api.anthropic.com"
let api_version = "2023-06-01"

(** Maximum HTTP response body size (10 MB).
    Used for LLM API responses, MCP HTTP, and agent registry. *)
let max_response_body = 10 * 1024 * 1024

(** Maximum stdio process buffer size (16 MB).
    Larger than HTTP because stdio carries full JSON-RPC frames. *)
let max_stdio_buffer = 16 * 1024 * 1024

(** Process-scoped entropy for OAS-allocated tool-use identities.

    The identity must not depend on model-generated names or arguments: those
    values are incomplete at streaming block start and repeated calls may have
    identical payloads.  [Random.State.make_self_init] obtains an independent
    system-seeded state, while the atomic sequence makes allocation unique
    within this process even when several OCaml 5 domains open streams at the
    same time.  The process id prevents a post-[fork] child from sharing the
    parent's namespace. *)
let tool_use_id_process_scope =
  let state = Random.State.make_self_init () in
  Printf.sprintf "%016Lx%016Lx" (Random.State.bits64 state) (Random.State.bits64 state)
;;

let tool_use_id_sequence = Atomic.make 0

let fresh_tool_use_id () =
  let sequence = Atomic.fetch_and_add tool_use_id_sequence 1 in
  Printf.sprintf "call_oas_%s_%x_%x" tool_use_id_process_scope (Unix.getpid ()) sequence
;;

let string_is_blank s = String.trim s = ""

let text_blocks_to_string blocks =
  blocks
  |> List.filter_map (function
    | Text s -> Some (Utf8_sanitize.sanitize s)
    | Thinking { content = s; _ } -> Some (Utf8_sanitize.sanitize s)
    | ReasoningDetails _ -> None
    | RedactedThinking _ -> None
    | ToolUse _ | ToolResult _ | Image _ | Document _ | Audio _ -> None)
  |> String.concat "\n"
;;

let json_of_string_or_raw s =
  try Yojson.Safe.from_string s with
  | Yojson.Json_error _ -> `Assoc [ "raw", `String s ]
;;

let unsupported_media_source ~backend ~block source_type =
  invalid_arg
    (Printf.sprintf
       "%s does not support %s media source kind %s"
       backend
       block
       (Types.media_source_kind_to_string source_type))
;;

let base64_media_data_url ~backend ~block ~media_type ~data = function
  | Base64 -> Printf.sprintf "data:%s;base64,%s" media_type data
  | (Url | File_id) as source_type -> unsupported_media_source ~backend ~block source_type
;;

let base64_media_payload ~backend ~block ~data = function
  | Base64 -> data
  | (Url | File_id) as source_type -> unsupported_media_source ~backend ~block source_type
;;

(* ── Document admission (oas#2744) ───────────────────────────────────────

   A [Document] block used to be re-labelled as an [image_url] part on the
   OpenAI-compatible Chat Completions wire. Serializing the same typed block
   differently per wire is the legitimate serialization boundary; changing
   *which modality it is* is not — the model received a picture where the
   caller sent a file, and nothing reported it.

   The two facts that decide whether a document may go out are now separate and
   both typed: [document_wire_form] says which native part the wire has (there
   is no wildcard: a wire with no document part says so), and
   [Capabilities.supports_document_input] says whether the resolved model row
   accepts one. Admission runs before serialization, so each serializer arm has
   exactly one native form and never needs a fallback. *)

type document_wire_form =
  | Document_source_block (** Anthropic Messages: [{"type":"document","source":{…}}]. *)
  | Document_inline_data (** Gemini: [inlineData] carrying the document MIME. *)
  | Document_input_file_part
  (** OpenAI Responses: [{"type":"input_file","file_data":…}]. *)
  | Document_chat_file_part
  (** OpenAI Chat Completions: [{"type":"file","file":{"file_data":…}}]. *)
  | Document_unrepresentable
  (** The wire has no document part. Ollama's native [/api/chat] carries only
        a scalar [content] plus an [images] array; a document placed in
        [images] is an image as far as the server is concerned. *)

let document_wire_form_to_string = function
  | Document_source_block -> "an Anthropic document source block"
  | Document_inline_data -> "a Gemini inlineData part"
  | Document_input_file_part -> "an OpenAI Responses input_file part"
  | Document_chat_file_part -> "an OpenAI Chat Completions file part"
  | Document_unrepresentable -> "no document part"
;;

type document_admission_error =
  | Document_wire_has_no_representation of
      { wire_form : document_wire_form
      ; media_type : string
      }
  | Document_input_not_declared of
      { model_id : string
      ; media_type : string
      }

let document_admission_error_to_string = function
  | Document_wire_has_no_representation { wire_form; media_type } ->
    Printf.sprintf
      "document block (media_type %S) cannot be placed on this wire: it has %s"
      media_type
      (document_wire_form_to_string wire_form)
  | Document_input_not_declared { model_id; media_type } ->
    Printf.sprintf
      "document block (media_type %S) rejected: model %S does not declare \
       supports_document_input"
      media_type
      model_id
;;

let admit_document_blocks ~wire_form ~model_id ~supports_document_input blocks =
  let rec loop = function
    | [] -> Ok ()
    | Document { media_type; _ } :: rest ->
      (match wire_form with
       | Document_unrepresentable ->
         Error (Document_wire_has_no_representation { wire_form; media_type })
       | Document_source_block
       | Document_inline_data
       | Document_input_file_part
       | Document_chat_file_part ->
         if supports_document_input
         then loop rest
         else Error (Document_input_not_declared { model_id; media_type }))
    | ( Text _
      | Thinking _
      | ReasoningDetails _
      | RedactedThinking _
      | ToolUse _
      | ToolResult _
      | Image _
      | Audio _ )
      :: rest -> loop rest
  in
  loop blocks
;;

let admit_document_messages ~wire_form ~model_id ~supports_document_input messages =
  let rec loop = function
    | [] -> Ok ()
    | (message : Types.message) :: rest ->
      (match
         admit_document_blocks
           ~wire_form
           ~model_id
           ~supports_document_input
           message.content
       with
       | Error _ as error -> error
       | Ok () -> loop rest)
  in
  loop messages
;;

(* oas#2744 — degrade, not reject.
   [admit_document_*] answers "may this document reach the wire"; when it may
   not, the earlier design raised [Invalid_argument], which
   [Complete.complete]'s wrapper turned into a rejected turn. That is right for
   a document the caller is introducing now, but the same functions walk the
   ENTIRE message history every turn, so a document resident in an
   already-answered turn permanently sank every later turn of that conversation
   against a model without the capability — retroactively, for state written
   before this behaviour existed.

   The wire still must not carry a document as some other modality (the audit's
   actual defect: a PDF relabelled [image_url]). So instead of relabelling or
   rejecting, an unrepresentable document is replaced with a visible text block
   that names what was dropped. This is not silent: the model — and through it
   the user — sees that a document was omitted and why, which is the honest
   degraded outcome for a conversation whose model cannot read documents. A
   model that CAN carry the document (capability declared, wire has a document
   part) keeps its native block untouched. *)
let document_omitted_placeholder ~media_type =
  Text
    (Printf.sprintf
       "[document omitted: this model does not accept document input (media_type %s)]"
       media_type)
;;

let degrade_document_block ~wire_form ~supports_document_input block =
  match block with
  | Document { media_type; _ } ->
    let representable =
      match wire_form with
      | Document_unrepresentable -> false
      | Document_source_block
      | Document_inline_data
      | Document_input_file_part
      | Document_chat_file_part -> supports_document_input
    in
    if representable then block else document_omitted_placeholder ~media_type
  | Text _
  | Thinking _
  | ReasoningDetails _
  | RedactedThinking _
  | ToolUse _
  | ToolResult _
  | Image _
  | Audio _ -> block
;;

(* Replace every unrepresentable document across the whole history with the
   placeholder, leaving all other blocks (and representable documents) intact.
   Returns the rewritten messages and the count of documents degraded, so a
   caller may log or surface the degradation without re-walking. *)
let degrade_document_messages ~wire_form ~supports_document_input messages =
  let degraded = ref 0 in
  let rewrite (message : Types.message) =
    let content =
      List.map
        (fun block ->
           let block' =
             degrade_document_block ~wire_form ~supports_document_input block
           in
           (match block, block' with
            | Document _, Text _ -> incr degraded
            | _ -> ());
           block')
        message.content
    in
    { message with content }
  in
  let messages = List.map rewrite messages in
  messages, !degraded
;;

type tool_result_content_style =
  | Tool_result_content_string
  | Tool_result_content_text_blocks

(** Content block <-> JSON *)
let rec content_block_to_json_with
          ~(tool_result_content_style : tool_result_content_style)
  = function
  | Text s ->
    `Assoc [ "type", `String "text"; "text", `String (Utf8_sanitize.sanitize s) ]
  | Thinking { content; signature } ->
    (* Anthropic verifies [signature] against the exact thinking text, so a
       signed block is serialized byte-exact (no sanitize); unsigned provider
       reasoning is sanitized defensively. A block without a signature omits the
       field rather than emitting a fabricated one. *)
    let thinking_text =
      match signature with
      | Some _ -> content
      | None -> Utf8_sanitize.sanitize content
    in
    let fields =
      match signature with
      | Some s ->
        [ "type", `String "thinking"
        ; "signature", `String s
        ; "thinking", `String thinking_text
        ]
      | None -> [ "type", `String "thinking"; "thinking", `String thinking_text ]
    in
    `Assoc fields
  | ReasoningDetails { reasoning_content; details } ->
    let fields =
      [ ( "details"
        , `List (List.map (fun (detail : reasoning_detail) -> detail.raw) details) )
      ]
    in
    let fields =
      match reasoning_content with
      | Some content ->
        ("reasoning_content", `String (Utf8_sanitize.sanitize content)) :: fields
      | None -> fields
    in
    `Assoc (("type", `String "reasoning_details") :: fields)
  | RedactedThinking data ->
    `Assoc [ "type", `String "redacted_thinking"; "data", `String data ]
  | ToolUse { id; name; input } ->
    `Assoc
      [ "type", `String "tool_use"
      ; "id", `String id
      ; "name", `String name
      ; "input", input
      ]
  | ToolResult { tool_use_id; content; outcome; content_blocks; _ } ->
    let content_json =
      match content_blocks with
      | Some blocks ->
        (* Structured result: emit the blocks (text/image/...) as the
           tool_result content array. *)
        `List (List.map (content_block_to_json_with ~tool_result_content_style) blocks)
      | None ->
        (match tool_result_content_style with
         | Tool_result_content_string -> `String (Utf8_sanitize.sanitize content)
         | Tool_result_content_text_blocks ->
           `List
             [ `Assoc
                 [ "type", `String "text"
                 ; "text", `String (Utf8_sanitize.sanitize content)
                 ]
             ])
    in
    `Assoc
      [ "type", `String "tool_result"
      ; "tool_use_id", `String tool_use_id
      ; "content", content_json
      ; "is_error", `Bool (tool_result_outcome_is_error outcome)
      ]
  | Image { media_type; data; source_type } ->
    `Assoc
      [ "type", `String "image"
      ; ( "source"
        , `Assoc
            [ "type", `String (media_source_kind_to_string source_type)
            ; "media_type", `String media_type
            ; "data", `String data
            ] )
      ]
  | Document { media_type; data; source_type } ->
    `Assoc
      [ "type", `String "document"
      ; ( "source"
        , `Assoc
            [ "type", `String (media_source_kind_to_string source_type)
            ; "media_type", `String media_type
            ; "data", `String data
            ] )
      ]
  | Audio { media_type; data; source_type } ->
    `Assoc
      [ "type", `String "audio"
      ; ( "source"
        , `Assoc
            [ "type", `String (media_source_kind_to_string source_type)
            ; "media_type", `String media_type
            ; "data", `String data
            ] )
      ]
;;

let content_block_to_json =
  content_block_to_json_with ~tool_result_content_style:Tool_result_content_string
;;

type content_block_decode_error =
  | Missing_content_block_type
  | Unsupported_content_block_type of string
  | Missing_content_block_field of
      { block_type : string
      ; field : string
      }
  | Unsupported_media_source_kind of
      { block_type : string
      ; source_type : string
      }

let content_block_decode_error_to_string = function
  | Missing_content_block_type -> "missing_content_block_type"
  | Unsupported_content_block_type block_type ->
    "unsupported_content_block_type:" ^ block_type
  | Missing_content_block_field { block_type; field } ->
    Printf.sprintf "missing_content_block_field:%s:%s" block_type field
  | Unsupported_media_source_kind { block_type; source_type } ->
    Printf.sprintf "unsupported_media_source_kind:%s:%s" block_type source_type
;;

let required_string_field ~block_type ~field json =
  let open Yojson.Safe.Util in
  match json |> member field |> to_string_option with
  | Some value -> Ok value
  | None -> Error (Missing_content_block_field { block_type; field })
;;

let reasoning_detail_of_json json =
  let open Yojson.Safe.Util in
  match json with
  | `Assoc _ ->
    let text =
      match json |> member "text" |> to_string_option with
      | Some text when not (string_is_blank text) -> Some text
      | Some _ | None -> None
    in
    Ok { raw = json; text }
  | `List _ | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null ->
    Error
      (Missing_content_block_field
         { block_type = "reasoning_details"; field = "details[]" })
;;

let parse_media_block ~block_type ~make json =
  let open Yojson.Safe.Util in
  let source = json |> member "source" in
  match source |> member "type" |> to_string_option with
  | None -> Error (Missing_content_block_field { block_type; field = "source.type" })
  | Some raw_source_type ->
    (match media_source_kind_of_string raw_source_type with
     | None ->
       Error (Unsupported_media_source_kind { block_type; source_type = raw_source_type })
     | Some source_type ->
       let ( let* ) = Result.bind in
       let* media_type = required_string_field ~block_type ~field:"media_type" source in
       let* data = required_string_field ~block_type ~field:"data" source in
       Ok (make ~media_type ~data ~source_type))
;;

let rec content_block_of_json_result json =
  let open Yojson.Safe.Util in
  match json |> member "type" |> to_string_option with
  | Some "text" ->
    Result.map
      (fun text -> Text text)
      (required_string_field ~block_type:"text" ~field:"text" json)
  | Some "thinking" ->
    let signature = json |> member "signature" |> to_string_option in
    Result.map
      (fun content -> Thinking { content; signature })
      (required_string_field ~block_type:"thinking" ~field:"thinking" json)
  | Some "reasoning_details" ->
    let ( let* ) = Result.bind in
    let details_json = json |> member "details" in
    let* details =
      match details_json with
      | `List details -> Ok details
      | `Assoc _ | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null ->
        Error
          (Missing_content_block_field
             { block_type = "reasoning_details"; field = "details" })
    in
    let* details = result_all (List.map reasoning_detail_of_json details) in
    let reasoning_content =
      match json |> member "reasoning_content" |> to_string_option with
      | Some content when not (string_is_blank content) -> Some content
      | Some _ | None -> None
    in
    Ok (ReasoningDetails { reasoning_content; details })
  | Some "redacted_thinking" ->
    Result.map
      (fun data -> RedactedThinking data)
      (required_string_field ~block_type:"redacted_thinking" ~field:"data" json)
  | Some "tool_use" ->
    let ( let* ) = Result.bind in
    let* id = required_string_field ~block_type:"tool_use" ~field:"id" json in
    let* name = required_string_field ~block_type:"tool_use" ~field:"name" json in
    let input = json |> member "input" in
    Ok (ToolUse { id; name; input })
  | Some "tool_result" ->
    let ( let* ) = Result.bind in
    let* tool_use_id =
      required_string_field ~block_type:"tool_result" ~field:"tool_use_id" json
    in
    let content_json = json |> member "content" in
    let* content, content_blocks =
      match content_json with
      | `String content -> Ok (content, None)
      | `List blocks ->
        let* blocks = content_blocks_of_json_result blocks in
        Ok (text_blocks_to_string blocks, Some blocks)
      | other -> Ok (Yojson.Safe.to_string other, None)
    in
    let outcome =
      if Cli_common_json.member_bool "is_error" json
      then Tool_failed { failure_kind = Reported_tool_error; error_class = None }
      else Tool_succeeded
    in
    let json = Types.try_parse_json content in
    Ok (ToolResult { tool_use_id; content; outcome; json; content_blocks })
  | Some "image" ->
    parse_media_block
      ~block_type:"image"
      ~make:(fun ~media_type ~data ~source_type ->
        Image { media_type; data; source_type })
      json
  | Some "document" ->
    parse_media_block
      ~block_type:"document"
      ~make:(fun ~media_type ~data ~source_type ->
        Document { media_type; data; source_type })
      json
  | Some "audio" ->
    parse_media_block
      ~block_type:"audio"
      ~make:(fun ~media_type ~data ~source_type ->
        Audio { media_type; data; source_type })
      json
  | Some other -> Error (Unsupported_content_block_type other)
  | None -> Error Missing_content_block_type

and content_blocks_of_json_result blocks =
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | block :: rest ->
      (match content_block_of_json_result block with
       | Ok parsed -> loop (parsed :: acc) rest
       | Error _ as error -> error)
  in
  loop [] blocks
;;

let content_block_of_json json =
  match content_block_of_json_result json with
  | Ok block -> Some block
  | Error _ -> None
;;

let message_has_tool_result (msg : message) =
  List.exists
    (function
      | ToolResult _ -> true
      | Text _
      | Thinking _
      | ReasoningDetails _
      | RedactedThinking _
      | ToolUse _
      | Image _
      | Document _
      | Audio _ -> false)
    msg.content
;;

let merge_tool_result_followup_user_messages messages =
  let mergeable_followup (msg : message) =
    msg.role = User
    && msg.name = None
    && msg.tool_call_id = None
    && Conversation_metadata.is_mergeable_followup msg.metadata
  in
  let rec aux acc = function
    | ({ role = Tool; _ } as tool_msg) :: (followup : message) :: rest
      when message_has_tool_result tool_msg && mergeable_followup followup ->
      let merged =
        { tool_msg with
          content = tool_msg.content @ followup.content
        ; metadata = tool_msg.metadata @ followup.metadata
        }
      in
      aux (merged :: acc) rest
    | msg :: rest -> aux (msg :: acc) rest
    | [] -> List.rev acc
  in
  aux [] messages
;;

let message_to_json (msg : message) =
  let role_str =
    match msg.role with
    | User | System | Tool -> "user"
    | Assistant -> "assistant"
  in
  `Assoc
    [ "role", `String role_str
    ; "content", `List (List.map content_block_to_json msg.content)
    ]
;;

let kimi_message_to_json (msg : message) =
  let role_str =
    match msg.role with
    | User | System | Tool -> "user"
    | Assistant -> "assistant"
  in
  `Assoc
    [ "role", `String role_str
    ; ( "content"
      , `List
          (List.map
             (content_block_to_json_with
                ~tool_result_content_style:Tool_result_content_text_blocks)
             msg.content) )
    ]
;;

(** Create HTTPS upgrade function using tls-eio *)
type https_init_error =
  | Ca_certs_unavailable of string
  | Tls_config_unavailable of string

let https_init_error_to_string = function
  | Ca_certs_unavailable msg -> "CA certificates unavailable: " ^ msg
  | Tls_config_unavailable msg -> "TLS client configuration unavailable: " ^ msg
;;

(* Process-wide cache for the TLS client configuration.

   [Ca_certs.authenticator ()] loads the system trust store on every call:
   on macOS it spawns one [security find-certificate] subprocess per
   keychain and parses the multi-hundred-KB PEM dump (X509 decode +
   fingerprints for the whole anchor set). Rebuilding it per connection
   dominated a consuming server's main event loop under sustained LLM
   traffic (~73% of the loop thread across two 10s `sample` profiles,
   2026-07-17).

   The authenticator validates certificate time with a clock closure
   evaluated at each handshake, so a process-lifetime cache does not
   freeze time-based validation.

   Errors are deliberately not cached: a transient failure (e.g. fork
   EAGAIN under load) must not wedge TLS for the process lifetime.
   Concurrent first calls may compute the config more than once; the
   results are equivalent and the last write wins. *)
let tls_client_config_cache : Tls.Config.client option Atomic.t = Atomic.make None

let tls_client_config () : (Tls.Config.client, https_init_error) result =
  match Atomic.get tls_client_config_cache with
  | Some config -> Ok config
  | None ->
    (match Ca_certs.authenticator () with
     | Error (`Msg msg) -> Error (Ca_certs_unavailable msg)
     | Ok authenticator ->
       (match Tls.Config.client ~authenticator () with
        | Error (`Msg msg) -> Error (Tls_config_unavailable msg)
        | Ok config ->
          Atomic.set tls_client_config_cache (Some config);
          Ok config))
;;

let make_https_result () : (Uri.t -> _ -> _, https_init_error) result =
  match tls_client_config () with
  | Error _ as e -> e
  | Ok tls_config ->
    Ok
      (fun uri flow ->
        let host =
          match Uri.host uri with
          | None -> None
          | Some h ->
            (match Domain_name.of_string h with
             | Error _ -> None
             | Ok dn -> Some (Domain_name.host_exn dn))
        in
        Tls_eio.client_of_flow tls_config ?host flow)
;;

let make_https () =
  match make_https_result () with
  | Ok wrap -> Some wrap
  | Error _ -> None
;;
