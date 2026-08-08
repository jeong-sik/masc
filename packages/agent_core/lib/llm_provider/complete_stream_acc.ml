(** Stream accumulator: gather SSE events into a {!Types.api_response}.

    Extracts the stream_acc type and its operations from [Complete].
    Depends only on [Types] and shared API helpers -- no
    provider/backend/transport references.

    @since 0.79.0 *)

(** Internal: accumulate SSE events into content blocks. *)
let ( let* ) = Result.bind

type stream_acc =
  { id : string ref
  ; model : string ref
  ; input_tokens : int ref
  ; output_tokens : int ref
  ; cache_creation : int ref
  ; cache_read : int ref
  ; stop_reason : Types.stop_reason ref
  ; stop_reason_received : bool ref
  ; done_sentinel_seen : bool ref
    (** Set on {!Types.MessageStop}: an explicit terminal sentinel was seen
        ([data: [DONE]] for OpenAI-compatible streams, [message_stop] for
        Anthropic). Lets the finalizer tell a clean completion-without-stop_reason
        apart from a truncated stream. *)
  ; terminal_incomplete : bool ref
  ; sse_error : Types.stream_error option ref
  ; block_texts : (int, Buffer.t) Hashtbl.t
  ; block_types : (int, string) Hashtbl.t
  ; block_tool_ids : (int, string) Hashtbl.t
  ; block_tool_names : (int, string) Hashtbl.t
  ; block_thinking_signatures : (int, Buffer.t) Hashtbl.t
  ; block_reasoning_details : (int, Types.reasoning_detail list ref) Hashtbl.t
  ; block_media_types : (int, string) Hashtbl.t
    (** Per-block media MIME type from {!Types.MediaDelta}. *)
  ; block_media_sources : (int, Types.media_source_kind) Hashtbl.t
    (** Per-block media source kind from {!Types.MediaDelta}. *)
  }

let create_stream_acc () =
  { id = ref ""
  ; model = ref ""
  ; input_tokens = ref 0
  ; output_tokens = ref 0
  ; cache_creation = ref 0
  ; cache_read = ref 0
  ; stop_reason = ref Types.EndTurn
  ; stop_reason_received = ref false
  ; done_sentinel_seen = ref false
  ; terminal_incomplete = ref false
  ; sse_error = ref None
  ; block_texts = Hashtbl.create 4
  ; block_types = Hashtbl.create 4
  ; block_tool_ids = Hashtbl.create 4
  ; block_tool_names = Hashtbl.create 4
  ; block_thinking_signatures = Hashtbl.create 4
  ; block_reasoning_details = Hashtbl.create 4
  ; block_media_types = Hashtbl.create 4
  ; block_media_sources = Hashtbl.create 4
  }
;;

let stream_failed acc = Option.is_some !(acc.sse_error)

let accumulate_event (acc : stream_acc) = function
  | Types.MessageStart { id; model; usage } ->
    acc.id := id;
    acc.model := model;
    (match usage with
     | Some u ->
       acc.input_tokens := u.input_tokens;
       acc.cache_creation := u.cache_creation_input_tokens;
       acc.cache_read := u.cache_read_input_tokens
     | None -> ())
  | Types.ContentBlockStart { index; content_type; tool_id; tool_name } ->
    Hashtbl.replace acc.block_types index content_type;
    Hashtbl.replace acc.block_texts index (Buffer.create 64);
    (match tool_id with
     | Some id -> Hashtbl.replace acc.block_tool_ids index id
     | None -> ());
    (match tool_name with
     | Some n -> Hashtbl.replace acc.block_tool_names index n
     | None -> ())
  | Types.ContentBlockDelta { index; delta } ->
    let buf =
      match Hashtbl.find_opt acc.block_texts index with
      | Some b -> b
      | None ->
        let b = Buffer.create 64 in
        Hashtbl.replace acc.block_texts index b;
        b
    in
    (match delta with
     | Types.TextDelta s | Types.ThinkingDelta s | Types.InputJsonDelta s ->
       (* [InputJsonDelta] is an incremental tool-argument fragment by
          definition, so it appends unconditionally. A whole-value re-emit
          arrives as the typed [InputJsonSnapshot] arm below, which replaces.
          Replace-vs-concat derives solely from the typed event tag, never from
          buffer contents.

          A buffer-content "re-emit guard" once lived here (#2344): if the
          buffer already parsed as one complete JSON value and the next delta
          started with '{', it cleared and replaced. It could not tell a genuine
          re-emit apart from ONE tool call whose arguments are two concatenated
          JSON objects (deepseek-v4-flash emitting [list_tasks] as
          {"include_done":false}{"exclude_automation":true,"limit":5} in a single
          call). When the second object's '{' was buffer-aligned, the guard
          silently dropped the first object and dispatched the tool with wrong
          arguments; the empty case {}{} it "fixed" was the same model bug, not a
          provider re-emit (Gemini re-emits via InputJsonSnapshot, not Delta).
          Concatenating instead surfaces multi-object arguments as a typed
          [malformed_tool_use_arguments] at finalize -- RFC-OAS-029 S8: reject on
          read, never silently coerce or drop. *)
       Buffer.add_string buf s
     | Types.ReasoningDetailsDelta { reasoning_content; details } ->
       (match reasoning_content with
        | Some content -> Buffer.add_string buf content
        | None -> ());
       let details_ref =
         match Hashtbl.find_opt acc.block_reasoning_details index with
         | Some details_ref -> details_ref
         | None ->
           let details_ref = ref [] in
           Hashtbl.replace acc.block_reasoning_details index details_ref;
           details_ref
       in
       details_ref := List.rev_append details !details_ref
     | Types.InputJsonSnapshot s ->
       (* A complete tool-call arguments value replaces the block buffer rather
          than appending, so a provider that re-emits the same whole value over
          multiple chunks does not concatenate it into invalid JSON (e.g.
          [{"limit":10}{"limit":10}]). *)
       Buffer.clear buf;
       Buffer.add_string buf s
     | Types.MediaDelta { media_type; source_type; data } ->
       Hashtbl.replace acc.block_media_types index media_type;
       Hashtbl.replace acc.block_media_sources index source_type;
       Buffer.add_string buf data
     | Types.ThinkingSignatureDelta s ->
       let sig_buf =
         match Hashtbl.find_opt acc.block_thinking_signatures index with
         | Some b -> b
         | None ->
           let b = Buffer.create 256 in
           Hashtbl.replace acc.block_thinking_signatures index b;
           b
       in
       Buffer.add_string sig_buf s)
  | Types.ContentBlockStop _ -> ()
  | Types.MessageDelta { stop_reason; usage } ->
    (match stop_reason with
     | Some sr ->
       acc.stop_reason := sr;
       acc.stop_reason_received := true
     | None -> ());
    (match usage with
     | Some u ->
       (* Additive so token totals are not lost when they arrive in a
          MessageDelta rather than MessageStart. Anthropic carries input_tokens
          in MessageStart and reports input_tokens/cache fields as 0 in its
          message_delta, so [+= 0] preserves that value. OpenAI-compatible
          streaming and Responses streaming deliver final usage only in a
          terminal MessageDelta, so this is the only place those tokens and
          cached-token fields are captured. *)
       acc.input_tokens := !(acc.input_tokens) + u.input_tokens;
       acc.output_tokens := !(acc.output_tokens) + u.output_tokens;
       acc.cache_creation := !(acc.cache_creation) + u.cache_creation_input_tokens;
       acc.cache_read := !(acc.cache_read) + u.cache_read_input_tokens
     | None -> ())
  | Types.SSEError { message; error_type; raw } ->
    acc.sse_error := Some (Types.Stream_provider_error { message; error_type; raw })
  | Types.NDJSONError { message; error_type; raw } ->
    acc.sse_error := Some (Types.Stream_provider_error { message; error_type; raw })
  | Types.SSEParseFailed { raw; reason } ->
    acc.sse_error := Some (Types.Stream_parse_failed { reason; raw })
  | Types.NDJSONParseFailed { raw; reason } ->
    acc.sse_error := Some (Types.Stream_ndjson_parse_failed { reason; raw })
  | Types.SSEUnknownEventType { event_type; raw } ->
    acc.sse_error := Some (Types.Stream_unknown_event { event_type; raw })
  | Types.SSEUnsupportedPart { provider_kind; part; raw } ->
    acc.sse_error := Some (Types.Stream_unsupported_part { provider_kind; part; raw })
  | Types.SSEUnsupportedResponse { provider_kind; response; raw } ->
    acc.sse_error
    := Some (Types.Stream_unsupported_response { provider_kind; response; raw })
  | Types.StreamIncomplete _ -> acc.terminal_incomplete := true
  | Types.MessageStop ->
    (* Explicit terminal sentinel from the provider ([data: [DONE]] for
       OpenAI-compatible streams, [message_stop] for Anthropic). It carries no
       stop_reason. Its presence distinguishes a provider contract violation
       from a truncated transport, but cannot synthesize completion semantics. *)
    acc.done_sentinel_seen := true
  | Types.Ping | Types.Connected | Types.Timeout _ -> ()
;;

(* Closed set of streamed content-block kinds. The wire [content_type] string
   is converted to this variant exactly once (parse, don't validate) and the
   finalizer below matches it exhaustively, so adding a kind breaks this compile
   site rather than slipping through the prior [_ -> None] catch-all that
   silently dropped any unrecognized block (RFC-OAS-029 S6.1). An unmodeled wire
   kind becomes [Unknown_block] — handled explicitly as an unsupported stream
   surface (S8.3), never silently or as assistant-visible text. *)
type block_kind =
  | Text_block
  | Thinking_block
  | Reasoning_details_block
  | Redacted_thinking_block
  | Tool_use_block
  | Tool_result_block of { is_error : bool }
  | Image_block
  | Document_block
  | Audio_block
  | Unknown_block of string

let block_kind_of_string = function
  | "text" -> Text_block
  | "thinking" -> Thinking_block
  | "reasoning_details" -> Reasoning_details_block
  | "redacted_thinking" -> Redacted_thinking_block
  | "tool_use" -> Tool_use_block
  | "tool_result" -> Tool_result_block { is_error = false }
  | "tool_result_error" -> Tool_result_block { is_error = true }
  | "image" -> Image_block
  | "document" -> Document_block
  | "audio" -> Audio_block
  | other -> Unknown_block other
;;

let finalize_stream_acc (acc : stream_acc) =
  match !(acc.sse_error) with
  | Some serr -> Error serr
  | None when not !(acc.stop_reason_received) ->
    (* A terminal sentinel proves transport closure, not why the model stopped.
       Missing provider semantics stay typed as incomplete instead of being
       silently promoted to [EndTurn]. *)
    Error
      (Types.Stream_incomplete
         { reason =
             (if !(acc.done_sentinel_seen)
              then "stream_terminal_without_stop_reason"
              else "stream_terminated_without_stop_reason")
         })
  | None ->
    let indices =
      Hashtbl.fold (fun k _ acc -> k :: acc) acc.block_types [] |> List.sort compare
    in
    let content_of_index idx =
      let text =
        match Hashtbl.find_opt acc.block_texts idx with
        | Some buf -> Buffer.contents buf
        | None -> ""
      in
      let media_block kind make =
        if String.trim text = ""
        then Ok None
        else (
          match
            ( Hashtbl.find_opt acc.block_media_types idx
            , Hashtbl.find_opt acc.block_media_sources idx )
          with
          | Some media_type, Some source_type when String.trim media_type <> "" ->
            Ok (Some (make ~media_type ~data:text ~source_type))
          | _ ->
            Error
              (Types.Stream_parse_failed
                 { reason = Printf.sprintf "malformed_media_block:%s:index:%d" kind idx
                 ; raw = ""
                 }))
      in
      match Option.map block_kind_of_string (Hashtbl.find_opt acc.block_types idx) with
      | None -> Ok None
      | Some Text_block -> Ok (Some (Types.Text text))
      | Some Thinking_block ->
        let signature =
          match Hashtbl.find_opt acc.block_thinking_signatures idx with
          | Some buf when Buffer.length buf > 0 -> Some (Buffer.contents buf)
          | Some _ | None -> None
        in
        Ok (Some (Types.Thinking { content = text; signature }))
      | Some Reasoning_details_block ->
        let details =
          match Hashtbl.find_opt acc.block_reasoning_details idx with
          | Some details_ref -> List.rev !details_ref
          | None -> []
        in
        let reasoning_content = if String.trim text = "" then None else Some text in
        (match reasoning_content, details with
         | None, [] -> Ok None
         | Some _, _ | None, _ :: _ ->
           Ok (Some (Types.ReasoningDetails { reasoning_content; details })))
      | Some Redacted_thinking_block ->
        (match Hashtbl.find_opt acc.block_tool_ids idx with
         | Some data when data <> "" -> Ok (Some (Types.RedactedThinking data))
         | Some _ | None -> Ok None)
      | Some Tool_use_block
        when !(acc.terminal_incomplete) || !(acc.stop_reason) = Types.MaxTokens ->
        (* A tool call only belongs to a turn the model finished at a tool
                boundary. When the turn was cut off, the accumulated tool block is
                partial: its argument buffer may be empty (cut off before the first
                delta) or even parse as JSON yet be incomplete. Drop it so the
                pipeline does not store a dangling assistant ToolUse that a later
                turn repairs with a synthetic error ToolResult. Mirrors the
                non-streaming parser Backend_openai_responses.parse_response_result,
                which drops ToolUse for incomplete/failed Responses statuses.
                Two cut-off signals:
                - [terminal_incomplete]: an OpenAI Responses [response.incomplete]
                  for ANY reason (max_output_tokens, content_filter, ...), carried
                  via the [StreamIncomplete] event.
                - [stop_reason = MaxTokens]: a token-limit truncation from any
                  provider (e.g. Anthropic/OpenAI streaming) that does not emit a
                  Responses incomplete terminal.
                (#2073 streaming follow-up.) [response.failed]/[error] terminals
                set [sse_error] instead, so finalize returns [Error] before content
                assembly and never reaches this branch. *)
        Ok None
      | Some Tool_use_block ->
        let* name =
          match Hashtbl.find_opt acc.block_tool_names idx with
          | Some s when not (Api_common.string_is_blank s) -> Ok s
          | Some _ | None ->
            Error
              (Types.Stream_parse_failed
                 { reason = Printf.sprintf "malformed_tool_use:index:%d:missing_name" idx
                 ; raw = ""
                 })
        in
        (* Tool arguments must parse. An empty argument buffer is the
           legitimate "no arguments" case and becomes the empty object; a
           non-empty buffer that fails to parse is a malformed tool call —
           fail closed with a typed [Stream_parse_failed] rather than coercing
           to [`Assoc []], which would silently dispatch the tool with empty
           arguments (RFC-OAS-029 S8: no silent permissive default). Mirrors
           the [Unknown_block] fail-closed arm and the typed-absence policy of
           the sibling [Tool_result_block] branch (which carries [json = None]
           rather than fabricating an object). *)
        let* input =
          if String.trim text = ""
          then Ok (`Assoc [])
          else (
            match Tool_call_input.parse_object text with
            | Ok input -> Ok input
            | Error Tool_call_input.Not_object ->
              Error
                (Types.Stream_parse_failed
                   { reason =
                       Printf.sprintf
                         "malformed_tool_use_arguments:index:%d:not_object"
                         idx
                   ; raw = text
                   })
            | Error (Tool_call_input.Invalid_json reason) ->
              (* Preserve the offending accumulated buffer in [raw] so the rare,
               provider-specific malformed tool-arg wire is diagnosable from the
               operator-facing diagnostic log (the [Complete_stream] renderer
               bounds it to 256 bytes).
               [raw] reaches operator-facing logs only, never replayed into
               conversation history. It may hold model-generated tool-argument
               values, so it carries the same sensitivity as any logged request
               payload -- not a new exposure surface, but not leak-free either.
               The deliberately-empty [Unknown_block] arm below stays empty
               because an unrecognized block payload has neither this bound nor a
               known shape. *)
              Error
                (Types.Stream_parse_failed
                   { reason =
                       Printf.sprintf
                         "malformed_tool_use_arguments:index:%d:%s"
                         idx
                         reason
                   ; raw = text
                   }))
        in
        let* id =
          match Hashtbl.find_opt acc.block_tool_ids idx with
          | Some s when not (Api_common.string_is_blank s) -> Ok s
          | Some _ | None ->
            Error
              (Types.Stream_parse_failed
                 { reason = Printf.sprintf "malformed_tool_use:index:%d:missing_id" idx
                 ; raw = ""
                 })
        in
        Ok (Some (Types.ToolUse { id; name; input }))
      | Some (Tool_result_block { is_error }) ->
        let* tool_use_id =
          match Hashtbl.find_opt acc.block_tool_ids idx with
          | Some s when not (Api_common.string_is_blank s) -> Ok s
          | Some _ | None ->
            Error
              (Types.Stream_parse_failed
                 { reason = Printf.sprintf "malformed_tool_result:index:%d:missing_id" idx
                 ; raw = ""
                 })
        in
        Ok
          (Some
             (Types.ToolResult
                { tool_use_id
                ; content = text
                ; outcome =
                    (if is_error
                     then
                       Types.Tool_failed
                         { failure_kind = Types.Reported_tool_error; error_class = None }
                     else Types.Tool_succeeded)
                ; json = (if is_error then None else Types.try_parse_json text)
                ; content_blocks = None
                }))
      | Some Image_block ->
        media_block "image" (fun ~media_type ~data ~source_type ->
          Types.Image { media_type; data; source_type })
      | Some Document_block ->
        media_block "document" (fun ~media_type ~data ~source_type ->
          Types.Document { media_type; data; source_type })
      | Some Audio_block ->
        media_block "audio" (fun ~media_type ~data ~source_type ->
          Types.Audio { media_type; data; source_type })
      | Some (Unknown_block kind) ->
        (* RFC-OAS-029 S6.1/S8.3: an unmodeled content-block kind is handled
           explicitly and fail-closed. Unknown wire semantics are not safely
           equivalent to assistant-visible text, and surfacing [text] here can
           leak future server/tool/control blocks into conversation history. Keep
           the provider payload out of [raw]; the block index and kind identify
           the unsupported surface without replaying its content. *)
        Error
          (Types.Stream_parse_failed
             { reason =
                 Printf.sprintf "unsupported_content_block_kind:%s:index:%d" kind idx
             ; raw = ""
             })
    in
    let rec collect_content acc = function
      | [] -> Ok (List.rev acc)
      | idx :: rest ->
        (match content_of_index idx with
         | Error _ as e -> e
         | Ok None -> collect_content acc rest
         | Ok (Some item) -> collect_content (item :: acc) rest)
    in
    (match collect_content [] indices with
     | Error _ as e -> e
     | Ok content ->
       (* Reasoning stays typed as [Thinking]: a reasoning-only stream is never
          promoted into a [Text] block. Promotion erased the type distinction so
          the request serializer re-fed reasoning as the assistant answer on the
          next turn (#2236 CoT re-injection loop). Surfacing reasoning-only
          replies for display is a read-side projection concern, not an
          accumulation-time mutation that also pollutes replay. *)
       let has_tool =
         List.exists
           (function
             | Types.ToolUse _ -> true
             | Types.Text _
             | Types.Thinking _
             | Types.ReasoningDetails _
             | Types.RedactedThinking _
             | Types.ToolResult _
             | Types.Image _
             | Types.Document _
             | Types.Audio _ -> false)
           content
       in
       (* Enforce the StopToolUse => has-tool-block invariant now that the full
       block set (including dropped partial tool calls above) is known. A
       reasoning-only or dropped-partial-tool stream that the provider tagged
       finish_reason="tool_calls" must NOT reach the driver as a tool-use turn
       with zero tools -- the pipeline re-issues that forever (infinite Thinking
       loop). SSOT: Stop_reason_wire.reconcile (same rule as the non-streaming
       parser via Stop_reason_wire.of_finish). *)
       let stop_reason =
         Stop_reason_wire.reconcile !(acc.stop_reason) ~has_tool_blocks:has_tool
       in
       Ok
         { Types.id = !(acc.id)
         ; model = !(acc.model)
         ; stop_reason
         ; content
         ; usage =
             Some
               { input_tokens = !(acc.input_tokens)
               ; output_tokens = !(acc.output_tokens)
               ; cache_creation_input_tokens = !(acc.cache_creation)
               ; cache_read_input_tokens = !(acc.cache_read)
               ; cost_usd = None
               }
         ; telemetry = None
         })
;;

[@@@coverage off]
(* === Inline tests === *)

let%test "create_stream_acc has sensible defaults" =
  let acc = create_stream_acc () in
  !(acc.id) = ""
  && !(acc.model) = ""
  && !(acc.input_tokens) = 0
  && !(acc.output_tokens) = 0
  && !(acc.stop_reason) = Types.EndTurn
  && !(acc.sse_error) = None
;;

let%test "accumulate_event MessageStart sets id and model" =
  let acc = create_stream_acc () in
  accumulate_event
    acc
    (Types.MessageStart { id = "msg-1"; model = "gpt-4"; usage = None });
  !(acc.id) = "msg-1" && !(acc.model) = "gpt-4"
;;

let%test "accumulate_event MessageStart with usage" =
  let acc = create_stream_acc () in
  accumulate_event
    acc
    (Types.MessageStart
       { id = "msg-2"
       ; model = "m"
       ; usage =
           Some
             { input_tokens = 100
             ; output_tokens = 0
             ; cache_creation_input_tokens = 5
             ; cache_read_input_tokens = 10
             ; cost_usd = None
             }
       });
  !(acc.input_tokens) = 100 && !(acc.cache_creation) = 5 && !(acc.cache_read) = 10
;;

let%test "accumulate_event ContentBlockStart + Delta + Stop" =
  let acc = create_stream_acc () in
  accumulate_event
    acc
    (Types.ContentBlockStart
       { index = 0; content_type = "text"; tool_id = None; tool_name = None });
  accumulate_event
    acc
    (Types.ContentBlockDelta { index = 0; delta = Types.TextDelta "Hello " });
  accumulate_event
    acc
    (Types.ContentBlockDelta { index = 0; delta = Types.TextDelta "world" });
  accumulate_event acc (Types.ContentBlockStop { index = 0 });
  let buf = Hashtbl.find acc.block_texts 0 in
  Buffer.contents buf = "Hello world"
;;

let%test "accumulate_event MessageDelta sets stop_reason" =
  let acc = create_stream_acc () in
  accumulate_event
    acc
    (Types.MessageDelta
       { stop_reason = Some Types.StopToolUse
       ; usage =
           Some
             { input_tokens = 0
             ; output_tokens = 50
             ; cache_creation_input_tokens = 0
             ; cache_read_input_tokens = 0
             ; cost_usd = None
             }
       });
  !(acc.stop_reason) = Types.StopToolUse && !(acc.output_tokens) = 50
;;

let%test "finalize_stream_acc assembles text block" =
  let acc = create_stream_acc () in
  acc.id := "test-id";
  acc.model := "test-model";
  Hashtbl.replace acc.block_types 0 "text";
  let buf = Buffer.create 16 in
  Buffer.add_string buf "Hello world";
  Hashtbl.replace acc.block_texts 0 buf;
  match
    acc.stop_reason_received := true;
    finalize_stream_acc acc
  with
  | Error _ -> false
  | Ok result ->
    result.id = "test-id"
    && result.model = "test-model"
    && result.content = [ Types.Text "Hello world" ]
;;

let%test "finalize_stream_acc assembles tool_use block" =
  let acc = create_stream_acc () in
  Hashtbl.replace acc.block_types 0 "tool_use";
  Hashtbl.replace acc.block_tool_ids 0 "tool-id-1";
  Hashtbl.replace acc.block_tool_names 0 "my_tool";
  let buf = Buffer.create 16 in
  Buffer.add_string buf "{\"key\":\"val\"}";
  Hashtbl.replace acc.block_texts 0 buf;
  match
    acc.stop_reason_received := true;
    finalize_stream_acc acc
  with
  | Error _ -> false
  | Ok result ->
    (match result.content with
     | [ Types.ToolUse { id = "tool-id-1"; name = "my_tool"; input } ] ->
       input = `Assoc [ "key", `String "val" ]
     | _ -> false)
;;

let%test "finalize_stream_acc assembles thinking block" =
  let acc = create_stream_acc () in
  Hashtbl.replace acc.block_types 0 "thinking";
  let buf = Buffer.create 16 in
  Buffer.add_string buf "reasoning...";
  Hashtbl.replace acc.block_texts 0 buf;
  match
    acc.stop_reason_received := true;
    finalize_stream_acc acc
  with
  | Error _ -> false
  | Ok result ->
    (match result.content with
     | [ Types.Thinking { content = "reasoning..."; signature = None } ] -> true
     | _ -> false)
;;

(* Drift guard for the infinite-Thinking fix: a reasoning-only stream that the
   provider tagged finish_reason="tool_calls" (provisional StopToolUse) must be
   reconciled to the typed UnmatchedToolCalls outcome when no tool block was
   assembled, so the driver does not
   re-issue the identical Thinking turn forever. Reverting the reconcile in
   finalize_stream_acc turns this RED. *)
let%test "finalize downgrades StopToolUse with no tool block to typed outcome" =
  let acc = create_stream_acc () in
  Hashtbl.replace acc.block_types 0 "thinking";
  let buf = Buffer.create 16 in
  Buffer.add_string buf "reasoning...";
  Hashtbl.replace acc.block_texts 0 buf;
  acc.stop_reason := Types.StopToolUse;
  acc.stop_reason_received := true;
  match finalize_stream_acc acc with
  | Error _ -> false
  | Ok result -> result.stop_reason = Types.UnmatchedToolCalls
;;

let%test "finalize keeps StopToolUse when a tool block is present" =
  let acc = create_stream_acc () in
  Hashtbl.replace acc.block_types 0 "tool_use";
  Hashtbl.replace acc.block_tool_ids 0 "tool-id-1";
  Hashtbl.replace acc.block_tool_names 0 "my_tool";
  let buf = Buffer.create 16 in
  Buffer.add_string buf "{\"key\":\"val\"}";
  Hashtbl.replace acc.block_texts 0 buf;
  acc.stop_reason := Types.StopToolUse;
  acc.stop_reason_received := true;
  match finalize_stream_acc acc with
  | Error _ -> false
  | Ok result -> result.stop_reason = Types.StopToolUse
;;

let%test "finalize_stream_acc multiple blocks ordered by index" =
  let acc = create_stream_acc () in
  Hashtbl.replace acc.block_types 0 "thinking";
  Hashtbl.replace acc.block_types 1 "text";
  let buf0 = Buffer.create 16 in
  Buffer.add_string buf0 "think";
  let buf1 = Buffer.create 16 in
  Buffer.add_string buf1 "say";
  Hashtbl.replace acc.block_texts 0 buf0;
  Hashtbl.replace acc.block_texts 1 buf1;
  match
    acc.stop_reason_received := true;
    finalize_stream_acc acc
  with
  | Error _ -> false
  | Ok result -> List.length result.content = 2
;;

let%test "finalize_stream_acc separates interleaved thinking and tool deltas" =
  let acc = create_stream_acc () in
  List.iter
    (accumulate_event acc)
    [ Types.MessageStart { id = "msg"; model = "model"; usage = None }
    ; Types.ContentBlockStart
        { index = 0; content_type = "thinking"; tool_id = None; tool_name = None }
    ; Types.ContentBlockDelta { index = 0; delta = Types.ThinkingDelta "plan-" }
    ; Types.ContentBlockStart
        { index = 1
        ; content_type = "tool_use"
        ; tool_id = Some "call-1"
        ; tool_name = Some "lookup"
        }
    ; Types.ContentBlockDelta { index = 1; delta = Types.InputJsonDelta {|{"city":|} }
    ; Types.ContentBlockDelta { index = 0; delta = Types.ThinkingDelta "done" }
    ; Types.ContentBlockDelta { index = 1; delta = Types.InputJsonDelta {|"Seoul"}|} }
    ; Types.ContentBlockStart
        { index = 2; content_type = "text"; tool_id = None; tool_name = None }
    ; Types.ContentBlockDelta { index = 2; delta = Types.TextDelta "visible" }
    ; Types.MessageDelta { stop_reason = Some Types.StopToolUse; usage = None }
    ];
  match finalize_stream_acc acc with
  | Ok
      { stop_reason = Types.StopToolUse
      ; content =
          [ Types.Thinking { content = "plan-done"; _ }
          ; Types.ToolUse { id = "call-1"; name = "lookup"; input }
          ; Types.Text "visible"
          ]
      ; _
      } -> input = `Assoc [ "city", `String "Seoul" ]
  | Ok _ | Error _ -> false
;;

let%test "finalize_stream_acc includes usage" =
  let acc = create_stream_acc () in
  acc.input_tokens := 100;
  acc.output_tokens := 50;
  acc.cache_creation := 10;
  acc.cache_read := 20;
  match
    acc.stop_reason_received := true;
    finalize_stream_acc acc
  with
  | Error _ -> false
  | Ok result ->
    (match result.usage with
     | Some u ->
       u.input_tokens = 100
       && u.output_tokens = 50
       && u.cache_creation_input_tokens = 10
       && u.cache_read_input_tokens = 20
     | None -> false)
;;

(* --- accumulate_event edge cases --- *)

let%test "accumulate_event ContentBlockDelta on unknown index creates buffer" =
  let acc = create_stream_acc () in
  accumulate_event
    acc
    (Types.ContentBlockDelta { index = 99; delta = Types.TextDelta "orphan" });
  match Hashtbl.find_opt acc.block_texts 99 with
  | Some buf -> Buffer.contents buf = "orphan"
  | None -> false
;;

let%test "accumulate_event ContentBlockStart with tool_id and tool_name" =
  let acc = create_stream_acc () in
  accumulate_event
    acc
    (Types.ContentBlockStart
       { index = 0
       ; content_type = "tool_use"
       ; tool_id = Some "tid-1"
       ; tool_name = Some "my_fn"
       });
  Hashtbl.find acc.block_tool_ids 0 = "tid-1"
  && Hashtbl.find acc.block_tool_names 0 = "my_fn"
;;

let%test "accumulate_event ThinkingDelta appends to buffer" =
  let acc = create_stream_acc () in
  accumulate_event
    acc
    (Types.ContentBlockStart
       { index = 0; content_type = "thinking"; tool_id = None; tool_name = None });
  accumulate_event
    acc
    (Types.ContentBlockDelta { index = 0; delta = Types.ThinkingDelta "step1" });
  accumulate_event
    acc
    (Types.ContentBlockDelta { index = 0; delta = Types.ThinkingDelta " step2" });
  let buf = Hashtbl.find acc.block_texts 0 in
  Buffer.contents buf = "step1 step2"
;;

let%test "accumulate_event ThinkingSignatureDelta preserves opaque signature" =
  let acc = create_stream_acc () in
  accumulate_event
    acc
    (Types.ContentBlockStart
       { index = 0; content_type = "thinking"; tool_id = None; tool_name = None });
  accumulate_event
    acc
    (Types.ContentBlockDelta
       { index = 0; delta = Types.ThinkingSignatureDelta "sig_opaque" });
  match Hashtbl.find_opt acc.block_thinking_signatures 0 with
  | Some buf -> Buffer.contents buf = "sig_opaque"
  | None -> false
;;

let%test "finalize_stream_acc preserves omitted thinking signature" =
  let acc = create_stream_acc () in
  List.iter
    (accumulate_event acc)
    [ Types.MessageStart { id = "m"; model = "m"; usage = None }
    ; Types.ContentBlockStart
        { index = 0; content_type = "thinking"; tool_id = None; tool_name = None }
    ; Types.ContentBlockDelta
        { index = 0; delta = Types.ThinkingSignatureDelta "sig_opaque" }
    ; Types.MessageDelta { stop_reason = Some Types.EndTurn; usage = None }
    ];
  match finalize_stream_acc acc with
  | Ok { content = [ Types.Thinking { content; signature } ]; _ } ->
    signature = Some "sig_opaque" && content = ""
  | Ok _ | Error _ -> false
;;

let%test "finalize_stream_acc preserves redacted thinking carrier" =
  let acc = create_stream_acc () in
  List.iter
    (accumulate_event acc)
    [ Types.MessageStart { id = "m"; model = "m"; usage = None }
    ; Types.ContentBlockStart
        { index = 0
        ; content_type = "redacted_thinking"
        ; tool_id = Some "opaque_data"
        ; tool_name = None
        }
    ; Types.MessageDelta { stop_reason = Some Types.StopToolUse; usage = None }
    ];
  match finalize_stream_acc acc with
  | Ok { content = [ Types.RedactedThinking data ]; _ } -> data = "opaque_data"
  | Ok _ | Error _ -> false
;;

let%test "accumulate_event InputJsonDelta appends to buffer" =
  let acc = create_stream_acc () in
  accumulate_event
    acc
    (Types.ContentBlockStart
       { index = 0; content_type = "tool_use"; tool_id = None; tool_name = None });
  accumulate_event
    acc
    (Types.ContentBlockDelta { index = 0; delta = Types.InputJsonDelta "{\"k\":" });
  accumulate_event
    acc
    (Types.ContentBlockDelta { index = 0; delta = Types.InputJsonDelta "\"v\"}" });
  let buf = Hashtbl.find acc.block_texts 0 in
  Buffer.contents buf = "{\"k\":\"v\"}"
;;

let%test "accumulate_event InputJsonSnapshot replaces buffer (no concat on repeat)" =
  let acc = create_stream_acc () in
  accumulate_event
    acc
    (Types.ContentBlockStart
       { index = 0; content_type = "tool_use"; tool_id = None; tool_name = None });
  accumulate_event
    acc
    (Types.ContentBlockDelta { index = 0; delta = Types.InputJsonSnapshot {|{"old":1}|} });
  (* A provider that re-emits the same (or an updated) complete arguments value
     must replace, not append, so the buffer never becomes invalid JSON. *)
  accumulate_event
    acc
    (Types.ContentBlockDelta
       { index = 0; delta = Types.InputJsonSnapshot {|{"limit":10}|} });
  let buf = Hashtbl.find acc.block_texts 0 in
  Buffer.contents buf = {|{"limit":10}|}
;;

let%test "finalize_stream_acc repeated tool-arg snapshot stays valid JSON" =
  (* Regression: an OpenAI-compatible/Ollama/Gemini provider that streams a
     whole tool-call arguments object and re-emits it on a later chunk used to
     append into [{"limit":10}{"limit":10}], which finalize rejected as
     [malformed_tool_use_arguments]. With InputJsonSnapshot the second emit
     replaces the first, so the tool input parses cleanly. *)
  let acc = create_stream_acc () in
  List.iter
    (accumulate_event acc)
    [ Types.MessageStart { id = "m"; model = "m"; usage = None }
    ; Types.ContentBlockStart
        { index = 0
        ; content_type = "tool_use"
        ; tool_id = Some "call_1"
        ; tool_name = Some "list"
        }
    ; Types.ContentBlockDelta
        { index = 0; delta = Types.InputJsonSnapshot {|{"limit":10}|} }
    ; Types.ContentBlockDelta
        { index = 0; delta = Types.InputJsonSnapshot {|{"limit":10}|} }
    ; Types.MessageDelta { stop_reason = Some Types.StopToolUse; usage = None }
    ];
  match finalize_stream_acc acc with
  | Ok { content = [ Types.ToolUse { input; name; _ } ]; _ } ->
    name = "list" && input = `Assoc [ "limit", `Int 10 ]
  | Ok _ | Error _ -> false
;;

let%test
    "accumulate_event InputJsonDelta concatenates fragments (no content-based replace)"
  =
  (* [InputJsonDelta] is incremental and concatenates unconditionally: two
     object-shaped deltas accumulate into "{}{}". The removed #2344 buffer-content
     guard replaced here to coerce a re-emit, but it could not distinguish a
     re-emit from one tool call serialized as two objects, silently dropping the
     first object for distinct {a}{b} args. Replace is now reachable only via the
     typed [InputJsonSnapshot] arm; multi-object [InputJsonDelta] reaches finalize
     and fails closed. *)
  let acc = create_stream_acc () in
  accumulate_event
    acc
    (Types.ContentBlockStart
       { index = 0; content_type = "tool_use"; tool_id = None; tool_name = None });
  accumulate_event
    acc
    (Types.ContentBlockDelta { index = 0; delta = Types.InputJsonDelta {|{}|} });
  accumulate_event
    acc
    (Types.ContentBlockDelta { index = 0; delta = Types.InputJsonDelta {|{}|} });
  let buf = Hashtbl.find acc.block_texts 0 in
  Buffer.contents buf = {|{}{}|}
;;

let%test "finalize_stream_acc fails closed on InputJsonDelta multi-object args (empty)" =
  (* The live malformed_tool_use_arguments raw="{}{}" case: a model emitted one
     tool call whose arguments were two concatenated JSON objects. #2344 coerced
     this to a single "{}" via the content-based re-emit guard, and the same guard
     silently dropped the FIRST object for distinct {a}{b} args. OAS now fails
     closed with a typed malformed_tool_use_arguments (RFC-OAS-029 S8) -- the model
     bug is surfaced to operators, never silently coerced to empty args nor
     dropped. *)
  let acc = create_stream_acc () in
  List.iter
    (accumulate_event acc)
    [ Types.MessageStart { id = "m"; model = "m"; usage = None }
    ; Types.ContentBlockStart
        { index = 0
        ; content_type = "tool_use"
        ; tool_id = Some "call_1"
        ; tool_name = Some "noop"
        }
    ; Types.ContentBlockDelta { index = 0; delta = Types.InputJsonDelta {|{}|} }
    ; Types.ContentBlockDelta { index = 0; delta = Types.InputJsonDelta {|{}|} }
    ; Types.MessageDelta { stop_reason = Some Types.StopToolUse; usage = None }
    ];
  match finalize_stream_acc acc with
  | Error (Types.Stream_parse_failed { reason; raw }) ->
    raw = {|{}{}|}
    && String.starts_with ~prefix:"malformed_tool_use_arguments:index:0" reason
  | Error
      ( Types.Stream_provider_error _
      | Types.Stream_unknown_event _
      | Types.Stream_incomplete _
      | Types.Stream_ndjson_parse_failed _
      | Types.Stream_unsupported_part _
      | Types.Stream_unsupported_response _ )
  | Ok _ -> false
;;

let%test "finalize_stream_acc fails closed on live multi-object tool args" =
  (* Exact reproduction of the reported tool-argument failure:
     deepseek-v4-flash (Ollama Cloud, OpenAI-compatible) opened a reasoning
     block (OAS block index 0) then emitted ONE list_tasks call whose arguments
     string was two concatenated
     objects -- {"include_done":false} then {"exclude_automation":true,"limit":5}
     (together a single valid arg set the model wrongly split). The tool block is
     index 1 (after thinking), matching the observed
     malformed_tool_use_arguments:index:1. Asserts the turn fails closed with both
     objects preserved in [raw] -- never silently dispatching list_tasks with
     only the second object's params. *)
  let acc = create_stream_acc () in
  List.iter
    (accumulate_event acc)
    [ Types.MessageStart { id = "m"; model = "deepseek-v4-flash"; usage = None }
    ; Types.ContentBlockStart
        { index = 0; content_type = "thinking"; tool_id = None; tool_name = None }
    ; Types.ContentBlockDelta { index = 0; delta = Types.ThinkingDelta "checking tasks" }
    ; Types.ContentBlockStart
        { index = 1
        ; content_type = "tool_use"
        ; tool_id = Some "call_1"
        ; tool_name = Some "list_tasks"
        }
    ; Types.ContentBlockDelta
        { index = 1; delta = Types.InputJsonDelta {|{"include_done":false}|} }
    ; Types.ContentBlockDelta
        { index = 1
        ; delta = Types.InputJsonDelta {|{"exclude_automation":true,"limit":5}|}
        }
    ; Types.MessageDelta { stop_reason = Some Types.StopToolUse; usage = None }
    ];
  match finalize_stream_acc acc with
  | Error (Types.Stream_parse_failed { reason; raw }) ->
    raw = {|{"include_done":false}{"exclude_automation":true,"limit":5}|}
    && String.starts_with ~prefix:"malformed_tool_use_arguments:index:1" reason
  | Error
      ( Types.Stream_provider_error _
      | Types.Stream_unknown_event _
      | Types.Stream_incomplete _
      | Types.Stream_ndjson_parse_failed _
      | Types.Stream_unsupported_part _
      | Types.Stream_unsupported_response _ )
  | Ok _ -> false
;;

let%test "accumulate_event MessageDelta None stop_reason keeps default" =
  let acc = create_stream_acc () in
  accumulate_event acc (Types.MessageDelta { stop_reason = None; usage = None });
  !(acc.stop_reason) = Types.EndTurn
;;

let%test "accumulate_event MessageDelta None usage does not change tokens" =
  let acc = create_stream_acc () in
  acc.output_tokens := 10;
  accumulate_event acc (Types.MessageDelta { stop_reason = None; usage = None });
  !(acc.output_tokens) = 10
;;

let%test "accumulate_event MessageStop is no-op" =
  let acc = create_stream_acc () in
  acc.id := "keep";
  accumulate_event acc Types.MessageStop;
  !(acc.id) = "keep"
;;

let%test "accumulate_event Ping is no-op" =
  let acc = create_stream_acc () in
  accumulate_event acc Types.Ping;
  !(acc.id) = ""
;;

let%test "accumulate_event SSEError records typed provider error" =
  let acc = create_stream_acc () in
  accumulate_event
    acc
    (Types.SSEError
       { message = "bad"; error_type = Some "rate_limit_exceeded"; raw = "{}" });
  match !(acc.sse_error) with
  | Some (Types.Stream_provider_error { message; error_type; _ }) ->
    message = "bad" && error_type = Some "rate_limit_exceeded"
  | Some
      ( Types.Stream_parse_failed _
      | Types.Stream_unknown_event _
      | Types.Stream_incomplete _
      | Types.Stream_ndjson_parse_failed _
      | Types.Stream_unsupported_part _
      | Types.Stream_unsupported_response _ )
  | None -> false
;;

(* SSEParseFailed and SSEUnknownEventType replace the previous silent [None]
   discard in [parse_sse_event]. They MUST mark [sse_error] so that
   [finalize_stream_acc] yields [Error _] and the caller can route to
   another provider instead of presenting a phantom completion (a partial
   response with no MessageStop, treated as success by downstream consumers). *)

let%test "accumulate_event SSEParseFailed marks typed parse failure with reason" =
  let acc = create_stream_acc () in
  accumulate_event
    acc
    (Types.SSEParseFailed { raw = "{not json"; reason = "json_error: Line 1, bytes 0-9" });
  match !(acc.sse_error) with
  | Some (Types.Stream_parse_failed { reason; raw }) ->
    reason = "json_error: Line 1, bytes 0-9" && raw = "{not json"
  | Some
      ( Types.Stream_provider_error _
      | Types.Stream_unknown_event _
      | Types.Stream_incomplete _
      | Types.Stream_ndjson_parse_failed _
      | Types.Stream_unsupported_part _
      | Types.Stream_unsupported_response _ )
  | None -> false
;;

let%test "accumulate_event SSEUnknownEventType marks typed unknown event with type" =
  let acc = create_stream_acc () in
  accumulate_event
    acc
    (Types.SSEUnknownEventType
       { event_type = "future_event_v3"; raw = "{\"type\":\"future_event_v3\"}" });
  match !(acc.sse_error) with
  | Some (Types.Stream_unknown_event { event_type; _ }) -> event_type = "future_event_v3"
  | Some
      ( Types.Stream_provider_error _
      | Types.Stream_parse_failed _
      | Types.Stream_incomplete _
      | Types.Stream_ndjson_parse_failed _
      | Types.Stream_unsupported_part _
      | Types.Stream_unsupported_response _ )
  | None -> false
;;

let%test "accumulate_event SSEUnsupportedPart preserves capability fact" =
  let raw = {|{"candidates":[{"content":{"parts":[{"executableCode":{}}]}}]}|} in
  let acc = create_stream_acc () in
  accumulate_event
    acc
    (Types.SSEUnsupportedPart
       { provider_kind = Provider_kind.Gemini; part = "executableCode"; raw });
  match !(acc.sse_error) with
  | Some
      (Types.Stream_unsupported_part
         { provider_kind = Provider_kind.Gemini; part; raw = observed_raw }) ->
    part = "executableCode" && observed_raw = raw
  | Some _ | None -> false
;;

let%test "accumulate_event SSEUnsupportedResponse preserves capability fact" =
  let raw = {|{"candidates":[{},{}]}|} in
  let acc = create_stream_acc () in
  accumulate_event
    acc
    (Types.SSEUnsupportedResponse
       { provider_kind = Provider_kind.Gemini; response = "candidates"; raw });
  match !(acc.sse_error) with
  | Some
      (Types.Stream_unsupported_response
         { provider_kind = Provider_kind.Gemini; response; raw = observed_raw }) ->
    response = "candidates" && observed_raw = raw
  | Some _ | None -> false
;;

let%test "accumulate_event NDJSONParseFailed preserves wire-specific error" =
  let acc = create_stream_acc () in
  accumulate_event
    acc
    (Types.NDJSONParseFailed { raw = "{not json"; reason = "bad_json" });
  match !(acc.sse_error) with
  | Some (Types.Stream_ndjson_parse_failed { reason; raw }) ->
    reason = "bad_json" && raw = "{not json"
  | Some
      ( Types.Stream_provider_error _
      | Types.Stream_parse_failed _
      | Types.Stream_unknown_event _
      | Types.Stream_incomplete _
      | Types.Stream_unsupported_part _
      | Types.Stream_unsupported_response _ )
  | None -> false
;;

let%test
    "accumulate_event SSEParseFailed carries raw chunk verbatim (no lossy truncation)"
  =
  let acc = create_stream_acc () in
  let big = String.make 5000 'x' in
  accumulate_event acc (Types.SSEParseFailed { raw = big; reason = "test" });
  (* The typed carrier preserves [raw] whole; any truncation is a display-layer
     concern, not a data-loss point in the accumulator. *)
  match !(acc.sse_error) with
  | Some (Types.Stream_parse_failed { raw; _ }) -> String.length raw = 5000
  | Some
      ( Types.Stream_provider_error _
      | Types.Stream_unknown_event _
      | Types.Stream_incomplete _
      | Types.Stream_ndjson_parse_failed _
      | Types.Stream_unsupported_part _
      | Types.Stream_unsupported_response _ )
  | None -> false
;;

(* --- finalize_stream_acc edge cases --- *)

let%test "finalize_stream_acc empty produces empty content" =
  let acc = create_stream_acc () in
  match
    acc.stop_reason_received := true;
    finalize_stream_acc acc
  with
  | Error _ -> false
  | Ok result -> result.content = []
;;

let%test "finalize_stream_acc fails closed for unknown block kind with text" =
  (* RFC-OAS-029 S6.1/S8.3: unmodeled content-block kinds are not silently
     dropped and are not coerced into assistant-visible Text. Revert this fix to
     the old branch -> [Ok { content = [Types.Text "data"]; _ }] (red). *)
  let acc = create_stream_acc () in
  Hashtbl.replace acc.block_types 0 "server_tool_use";
  let buf = Buffer.create 16 in
  Buffer.add_string buf "data";
  Hashtbl.replace acc.block_texts 0 buf;
  match
    acc.stop_reason_received := true;
    finalize_stream_acc acc
  with
  | Error (Types.Stream_parse_failed { reason; raw }) ->
    raw = ""
    && String.starts_with
         ~prefix:"unsupported_content_block_kind:server_tool_use:index:0"
         reason
  | Error
      ( Types.Stream_provider_error _
      | Types.Stream_unknown_event _
      | Types.Stream_incomplete _
      | Types.Stream_ndjson_parse_failed _
      | Types.Stream_unsupported_part _
      | Types.Stream_unsupported_response _ )
  | Ok _ -> false
;;

let%test "finalize_stream_acc fails closed for empty unknown block kind" =
  (* Empty unknown blocks are still unsupported wire semantics. Returning [Ok []]
     would silently erase a future server/tool/control surface. *)
  let acc = create_stream_acc () in
  Hashtbl.replace acc.block_types 0 "container_upload";
  match
    acc.stop_reason_received := true;
    finalize_stream_acc acc
  with
  | Error (Types.Stream_parse_failed { reason; raw }) ->
    raw = ""
    && String.starts_with
         ~prefix:"unsupported_content_block_kind:container_upload:index:0"
         reason
  | Error
      ( Types.Stream_provider_error _
      | Types.Stream_unknown_event _
      | Types.Stream_incomplete _
      | Types.Stream_ndjson_parse_failed _
      | Types.Stream_unsupported_part _
      | Types.Stream_unsupported_response _ )
  | Ok _ -> false
;;

let%test "finalize_stream_acc assembles a streamed image block (multimodal)" =
  let acc = create_stream_acc () in
  accumulate_event
    acc
    (Types.ContentBlockStart
       { index = 0; content_type = "image"; tool_id = None; tool_name = None });
  accumulate_event
    acc
    (Types.ContentBlockDelta
       { index = 0
       ; delta =
           Types.MediaDelta
             { media_type = "image/png"
             ; source_type = Types.Base64
             ; data = "iVBORw0KGgo="
             }
       });
  accumulate_event
    acc
    (Types.MessageDelta { stop_reason = Some Types.EndTurn; usage = None });
  match finalize_stream_acc acc with
  | Error _ -> false
  | Ok result ->
    result.content
    = [ Types.Image
          { media_type = "image/png"; data = "iVBORw0KGgo="; source_type = Types.Base64 }
      ]
;;

let%test "finalize_stream_acc concatenates multi-chunk media payload" =
  let acc = create_stream_acc () in
  accumulate_event
    acc
    (Types.ContentBlockStart
       { index = 0; content_type = "audio"; tool_id = None; tool_name = None });
  let chunk data =
    accumulate_event
      acc
      (Types.ContentBlockDelta
         { index = 0
         ; delta =
             Types.MediaDelta
               { media_type = "audio/mp3"; source_type = Types.Base64; data }
         })
  in
  chunk "AAAA";
  chunk "BBBB";
  accumulate_event
    acc
    (Types.MessageDelta { stop_reason = Some Types.EndTurn; usage = None });
  match finalize_stream_acc acc with
  | Error _ -> false
  | Ok result ->
    result.content
    = [ Types.Audio
          { media_type = "audio/mp3"; data = "AAAABBBB"; source_type = Types.Base64 }
      ]
;;

let%test "finalize_stream_acc drops a media block with no payload" =
  let acc = create_stream_acc () in
  accumulate_event
    acc
    (Types.ContentBlockStart
       { index = 0; content_type = "document"; tool_id = None; tool_name = None });
  accumulate_event
    acc
    (Types.MessageDelta { stop_reason = Some Types.EndTurn; usage = None });
  match finalize_stream_acc acc with
  | Error _ -> false
  | Ok result -> result.content = []
;;

let%test "finalize_stream_acc fails closed for media payload without metadata" =
  let acc = create_stream_acc () in
  accumulate_event
    acc
    (Types.ContentBlockStart
       { index = 0; content_type = "image"; tool_id = None; tool_name = None });
  accumulate_event
    acc
    (Types.ContentBlockDelta { index = 0; delta = Types.TextDelta "payload" });
  accumulate_event
    acc
    (Types.MessageDelta { stop_reason = Some Types.EndTurn; usage = None });
  match finalize_stream_acc acc with
  | Error (Types.Stream_parse_failed { reason; raw }) ->
    raw = "" && reason = "malformed_media_block:image:index:0"
  | Error
      ( Types.Stream_provider_error _
      | Types.Stream_unknown_event _
      | Types.Stream_incomplete _
      | Types.Stream_ndjson_parse_failed _
      | Types.Stream_unsupported_part _
      | Types.Stream_unsupported_response _ )
  | Ok _ -> false
;;

let%test "finalize_stream_acc fails closed on malformed tool_use arguments" =
  (* Non-truncated turn: a non-empty argument buffer that fails to parse is a
     malformed tool call and surfaces a typed [Stream_parse_failed] rather than
     silently coercing to empty arguments (RFC-OAS-029 S8: no silent permissive
     default). Truncation is handled by the MaxTokens guard, below. *)
  let acc = create_stream_acc () in
  Hashtbl.replace acc.block_types 0 "tool_use";
  Hashtbl.replace acc.block_tool_ids 0 "tool-id-1";
  Hashtbl.replace acc.block_tool_names 0 "broken_tool";
  let buf = Buffer.create 16 in
  Buffer.add_string buf "not valid json";
  Hashtbl.replace acc.block_texts 0 buf;
  match
    acc.stop_reason_received := true;
    finalize_stream_acc acc
  with
  | Error (Types.Stream_parse_failed { reason; raw }) ->
    (* [raw] now preserves the offending buffer so the malformed wire is
       diagnosable from the operator-facing diagnostic log instead of being
       discarded. *)
    raw = "not valid json"
    && String.starts_with ~prefix:"malformed_tool_use_arguments:index:0" reason
  | Error
      ( Types.Stream_provider_error _
      | Types.Stream_unknown_event _
      | Types.Stream_incomplete _
      | Types.Stream_ndjson_parse_failed _
      | Types.Stream_unsupported_part _
      | Types.Stream_unsupported_response _ )
  | Ok _ -> false
;;

let%test "finalize_stream_acc keeps empty tool_use arguments as empty object" =
  (* An empty argument buffer is the legitimate no-arguments call and must
     remain [`Assoc []] (not be treated as malformed). *)
  let acc = create_stream_acc () in
  Hashtbl.replace acc.block_types 0 "tool_use";
  Hashtbl.replace acc.block_tool_ids 0 "tool-id-1";
  Hashtbl.replace acc.block_tool_names 0 "now";
  match
    acc.stop_reason_received := true;
    finalize_stream_acc acc
  with
  | Error _ -> false
  | Ok result ->
    (match result.content with
     | [ Types.ToolUse { input = `Assoc []; _ } ] -> true
     | _ -> false)
;;

let%test "finalize_stream_acc drops tool_use on truncated turn (MaxTokens)" =
  (* A truncated turn (Responses response.incomplete -> MaxTokens) must not surface
     a partial tool call, even when the arguments happen to parse as JSON. #2073. *)
  let acc = create_stream_acc () in
  Hashtbl.replace acc.block_types 0 "tool_use";
  Hashtbl.replace acc.block_tool_ids 0 "tool-id-1";
  Hashtbl.replace acc.block_tool_names 0 "get_weather";
  let buf = Buffer.create 16 in
  Buffer.add_string buf "{\"city\":\"Paris\"}";
  Hashtbl.replace acc.block_texts 0 buf;
  acc.stop_reason := Types.MaxTokens;
  match
    acc.stop_reason_received := true;
    finalize_stream_acc acc
  with
  | Error _ -> false
  | Ok result -> result.content = []
;;

let%test "finalize_stream_acc drops tool_use on incomplete non-token reason" =
  (* A Responses [response.incomplete] for a non-max_output_tokens reason (e.g.
     content_filter) carries [terminal_incomplete] via StreamIncomplete; the tool
     block must drop even though stop_reason is not MaxTokens. #2073. *)
  let acc = create_stream_acc () in
  Hashtbl.replace acc.block_types 0 "tool_use";
  Hashtbl.replace acc.block_tool_ids 0 "tool-id-1";
  Hashtbl.replace acc.block_tool_names 0 "get_weather";
  let buf = Buffer.create 16 in
  Buffer.add_string buf "{\"city\":\"Paris\"}";
  Hashtbl.replace acc.block_texts 0 buf;
  acc.stop_reason := Types.Unknown "content_filter";
  acc.terminal_incomplete := true;
  match
    acc.stop_reason_received := true;
    finalize_stream_acc acc
  with
  | Error _ -> false
  | Ok result -> result.content = []
;;

let%test "finalize_stream_acc keeps tool_use on StopToolUse (no over-drop)" =
  (* A normal tool-call turn keeps its tool block; the MaxTokens guard must not
     drop tools from a turn that finished at a tool boundary. *)
  let acc = create_stream_acc () in
  Hashtbl.replace acc.block_types 0 "tool_use";
  Hashtbl.replace acc.block_tool_ids 0 "tool-id-1";
  Hashtbl.replace acc.block_tool_names 0 "get_weather";
  let buf = Buffer.create 16 in
  Buffer.add_string buf "{\"city\":\"Paris\"}";
  Hashtbl.replace acc.block_texts 0 buf;
  acc.stop_reason := Types.StopToolUse;
  match
    acc.stop_reason_received := true;
    finalize_stream_acc acc
  with
  | Error _ -> false
  | Ok result ->
    (match result.content with
     | [ Types.ToolUse
           { name = "get_weather"; input = `Assoc [ ("city", `String "Paris") ]; _ }
       ] -> true
     | _ -> false)
;;

let%test "finalize_stream_acc tool_use missing name fails closed" =
  let acc = create_stream_acc () in
  Hashtbl.replace acc.block_types 0 "tool_use";
  Hashtbl.replace acc.block_tool_ids 0 "tool-id-1";
  let buf = Buffer.create 16 in
  Buffer.add_string buf "{}";
  Hashtbl.replace acc.block_texts 0 buf;
  match
    acc.stop_reason_received := true;
    finalize_stream_acc acc
  with
  | Error (Types.Stream_parse_failed { reason; raw }) ->
    reason = "malformed_tool_use:index:0:missing_name" && raw = ""
  | Error err ->
    let (_ : Types.stream_error) = err in
    false
  | Ok result ->
    let (_ : Types.api_response) = result in
    false
;;

let%test "finalize_stream_acc tool_use missing id fails closed" =
  let acc = create_stream_acc () in
  Hashtbl.replace acc.block_types 0 "tool_use";
  Hashtbl.replace acc.block_tool_names 0 "get_weather";
  let buf = Buffer.create 16 in
  Buffer.add_string buf "{}";
  Hashtbl.replace acc.block_texts 0 buf;
  match
    acc.stop_reason_received := true;
    finalize_stream_acc acc
  with
  | Error (Types.Stream_parse_failed { reason; raw }) ->
    reason = "malformed_tool_use:index:0:missing_id" && raw = ""
  | Error
      ( Types.Stream_provider_error _
      | Types.Stream_unknown_event _
      | Types.Stream_incomplete _
      | Types.Stream_ndjson_parse_failed _
      | Types.Stream_unsupported_part _
      | Types.Stream_unsupported_response _ )
  | Ok _ -> false
;;

let%test "finalize_stream_acc tool_use blank id fails closed" =
  let acc = create_stream_acc () in
  Hashtbl.replace acc.block_types 0 "tool_use";
  Hashtbl.replace acc.block_tool_ids 0 " ";
  Hashtbl.replace acc.block_tool_names 0 "get_weather";
  let buf = Buffer.create 16 in
  Buffer.add_string buf "{}";
  Hashtbl.replace acc.block_texts 0 buf;
  match
    acc.stop_reason_received := true;
    finalize_stream_acc acc
  with
  | Error (Types.Stream_parse_failed { reason; raw }) ->
    reason = "malformed_tool_use:index:0:missing_id" && raw = ""
  | Error
      ( Types.Stream_provider_error _
      | Types.Stream_unknown_event _
      | Types.Stream_incomplete _
      | Types.Stream_ndjson_parse_failed _
      | Types.Stream_unsupported_part _
      | Types.Stream_unsupported_response _ )
  | Ok _ -> false
;;

let%test "finalize_stream_acc assembles tool_result block" =
  let acc = create_stream_acc () in
  Hashtbl.replace acc.block_types 0 "tool_result";
  Hashtbl.replace acc.block_tool_ids 0 "tu_1";
  let buf = Buffer.create 16 in
  Buffer.add_string buf "{\"ok\":true}";
  Hashtbl.replace acc.block_texts 0 buf;
  match
    acc.stop_reason_received := true;
    finalize_stream_acc acc
  with
  | Error _ -> false
  | Ok result ->
    (match result.content with
     | [ Types.ToolResult
           { tool_use_id = "tu_1"
           ; content = "{\"ok\":true}"
           ; json = Some (`Assoc [ ("ok", `Bool true) ])
           ; _
           }
       ] -> true
     | _ -> false)
;;

let%test "finalize_stream_acc tool_result missing id fails closed" =
  let acc = create_stream_acc () in
  Hashtbl.replace acc.block_types 0 "tool_result";
  let buf = Buffer.create 16 in
  Buffer.add_string buf "done";
  Hashtbl.replace acc.block_texts 0 buf;
  match
    acc.stop_reason_received := true;
    finalize_stream_acc acc
  with
  | Error (Types.Stream_parse_failed { reason; raw }) ->
    reason = "malformed_tool_result:index:0:missing_id" && raw = ""
  | Error
      ( Types.Stream_provider_error _
      | Types.Stream_unknown_event _
      | Types.Stream_incomplete _
      | Types.Stream_ndjson_parse_failed _
      | Types.Stream_unsupported_part _
      | Types.Stream_unsupported_response _ )
  | Ok _ -> false
;;

let%test "finalize_stream_acc assembles a streamed image block" =
  let acc = create_stream_acc () in
  List.iter
    (accumulate_event acc)
    [ Types.MessageStart { id = "m"; model = "m"; usage = None }
    ; Types.ContentBlockStart
        { index = 0; content_type = "image"; tool_id = None; tool_name = None }
    ; Types.ContentBlockDelta
        { index = 0
        ; delta =
            Types.MediaDelta
              { media_type = "image/png"
              ; source_type = Types.Base64
              ; data = "iVBORw0KGgo="
              }
        }
    ; Types.MessageDelta { stop_reason = Some Types.EndTurn; usage = None }
    ];
  match finalize_stream_acc acc with
  | Ok
      { content =
          [ Types.Image
              { media_type = "image/png"
              ; source_type = Types.Base64
              ; data = "iVBORw0KGgo="
              }
          ]
      ; _
      } -> true
  | Ok _ | Error _ -> false
;;

let%test "finalize_stream_acc concatenates multi-chunk media payload" =
  let acc = create_stream_acc () in
  List.iter
    (accumulate_event acc)
    [ Types.MessageStart { id = "m"; model = "m"; usage = None }
    ; Types.ContentBlockStart
        { index = 0; content_type = "audio"; tool_id = None; tool_name = None }
    ; Types.ContentBlockDelta
        { index = 0
        ; delta =
            Types.MediaDelta
              { media_type = "audio/mpeg"; source_type = Types.Base64; data = "AAA" }
        }
    ; Types.ContentBlockDelta
        { index = 0
        ; delta =
            Types.MediaDelta
              { media_type = "audio/mpeg"; source_type = Types.Base64; data = "BBB" }
        }
    ; Types.MessageDelta { stop_reason = Some Types.EndTurn; usage = None }
    ];
  match finalize_stream_acc acc with
  | Ok
      { content =
          [ Types.Audio
              { media_type = "audio/mpeg"; source_type = Types.Base64; data = "AAABBB" }
          ]
      ; _
      } -> true
  | Ok _ | Error _ -> false
;;

let%test "finalize_stream_acc fails closed for media payload without metadata" =
  let acc = create_stream_acc () in
  List.iter
    (accumulate_event acc)
    [ Types.MessageStart { id = "m"; model = "m"; usage = None }
    ; Types.ContentBlockStart
        { index = 0; content_type = "image"; tool_id = None; tool_name = None }
    ; Types.ContentBlockDelta { index = 0; delta = Types.TextDelta "payload" }
    ; Types.MessageDelta { stop_reason = Some Types.EndTurn; usage = None }
    ];
  match finalize_stream_acc acc with
  | Error (Types.Stream_parse_failed { reason; raw }) ->
    reason = "malformed_media_block:image:index:0" && raw = ""
  | Error
      ( Types.Stream_provider_error _
      | Types.Stream_unknown_event _
      | Types.Stream_incomplete _
      | Types.Stream_ndjson_parse_failed _
      | Types.Stream_unsupported_part _
      | Types.Stream_unsupported_response _ )
  | Ok _ -> false
;;

let%test "finalize_stream_acc drops a media block with no payload" =
  let acc = create_stream_acc () in
  List.iter
    (accumulate_event acc)
    [ Types.MessageStart { id = "m"; model = "m"; usage = None }
    ; Types.ContentBlockStart
        { index = 0; content_type = "document"; tool_id = None; tool_name = None }
    ; Types.MessageDelta { stop_reason = Some Types.EndTurn; usage = None }
    ];
  match finalize_stream_acc acc with
  | Ok { content = []; _ } -> true
  | Ok _ | Error _ -> false
;;

let%test "finalize_stream_acc block with no text buffer produces empty text" =
  let acc = create_stream_acc () in
  Hashtbl.replace acc.block_types 0 "text";
  (* No buffer added for index 0 *)
  match
    acc.stop_reason_received := true;
    finalize_stream_acc acc
  with
  | Error _ -> false
  | Ok result ->
    (match result.content with
     | [ Types.Text "" ] -> true
     | _ -> false)
;;

let%test "finalize_stream_acc returns Error when sse_error is set" =
  let acc = create_stream_acc () in
  acc.id := "partial-id";
  Hashtbl.replace acc.block_types 0 "text";
  let buf = Buffer.create 16 in
  Buffer.add_string buf "partial content";
  Hashtbl.replace acc.block_texts 0 buf;
  acc.sse_error
  := Some
       (Types.Stream_provider_error
          { message = "server overloaded"
          ; error_type = Some "overloaded_error"
          ; raw = "{}"
          });
  match
    acc.stop_reason_received := true;
    finalize_stream_acc acc
  with
  | Error (Types.Stream_provider_error { message; _ }) -> message = "server overloaded"
  | Error
      ( Types.Stream_parse_failed _
      | Types.Stream_unknown_event _
      | Types.Stream_incomplete _
      | Types.Stream_ndjson_parse_failed _
      | Types.Stream_unsupported_part _
      | Types.Stream_unsupported_response _ )
  | Ok _ -> false
;;

(* Phantom completion prevention: a stream that ends without a terminal
   MessageDelta carrying a stop_reason must not produce Ok with the
   default EndTurn — that would make a truncated stream look like a
   successful completion. *)
let%test "finalize_stream_acc returns Error when stream has no stop_reason" =
  let acc = create_stream_acc () in
  acc.id := "msg-partial";
  Hashtbl.replace acc.block_types 0 "text";
  let buf = Buffer.create 16 in
  Buffer.add_string buf "Hello";
  Hashtbl.replace acc.block_texts 0 buf;
  (* No accumulate_event with MessageDelta { stop_reason = Some _; _ } *)
  match finalize_stream_acc acc with
  | Error (Types.Stream_incomplete { reason }) ->
    reason = "stream_terminated_without_stop_reason"
  | Error _ | Ok _ -> false
;;

let%test "finalize_stream_acc returns Ok after proper stop_reason received" =
  let acc = create_stream_acc () in
  acc.id := "msg-ok";
  Hashtbl.replace acc.block_types 0 "text";
  let buf = Buffer.create 16 in
  Buffer.add_string buf "Hello";
  Hashtbl.replace acc.block_texts 0 buf;
  accumulate_event
    acc
    (Types.MessageDelta { stop_reason = Some Types.EndTurn; usage = None });
  match finalize_stream_acc acc with
  | Ok resp -> resp.stop_reason = Types.EndTurn
  | Error _ -> false
;;

let%test "accumulate_event multiple MessageDelta accumulates tokens" =
  let acc = create_stream_acc () in
  accumulate_event
    acc
    (Types.MessageDelta
       { stop_reason = None
       ; usage =
           Some
             { input_tokens = 0
             ; output_tokens = 30
             ; cache_creation_input_tokens = 0
             ; cache_read_input_tokens = 0
             ; cost_usd = None
             }
       });
  accumulate_event
    acc
    (Types.MessageDelta
       { stop_reason = None
       ; usage =
           Some
             { input_tokens = 0
             ; output_tokens = 20
             ; cache_creation_input_tokens = 0
             ; cache_read_input_tokens = 0
             ; cost_usd = None
             }
       });
  !(acc.output_tokens) = 50
;;
