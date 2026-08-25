(** Pure stream assembly state machine. *)

let ( let* ) = Result.bind

module Blocks = Map.Make (Int)

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

type block_header =
  | Unannounced
  | Announced of
      { kind : block_kind
      ; tool_id : string option
      ; tool_name : string option
      }

type media =
  { media_type : string
  ; source_type : Types.media_source_kind
  }

type input_piece =
  | Delta_bytes of int
  | Snapshot_bytes of int

type block =
  { header : block_header
  ; text_chunks_rev : string list
  ; input_pieces_rev : input_piece list
  ; input_piece_count : int
  ; signature_chunks_rev : string list
  ; reasoning_details_rev : Types.reasoning_detail list
  ; media : media option
  }

type usage =
  { input_tokens : int
  ; output_tokens : int
  ; cache_creation : int
  ; cache_read : int
  }

type completion =
  | Awaiting_stop
  | Terminal_without_stop_reason
  | Stopped of Types.stop_reason

type disposition =
  | Natural
  | Incomplete of string

type t =
  { id : string
  ; model : string
  ; usage : usage
  ; completion : completion
  ; disposition : disposition
  ; failure : Types.stream_error option
  ; blocks : block Blocks.t
  }

type receipt =
  | Completed of Types.api_response
  | Failed of Types.stream_error

let empty_usage =
  { input_tokens = 0; output_tokens = 0; cache_creation = 0; cache_read = 0 }
;;

let empty =
  { id = ""
  ; model = ""
  ; usage = empty_usage
  ; completion = Awaiting_stop
  ; disposition = Natural
  ; failure = None
  ; blocks = Blocks.empty
  }
;;

let empty_block =
  { header = Unannounced
  ; text_chunks_rev = []
  ; input_pieces_rev = []
  ; input_piece_count = 0
  ; signature_chunks_rev = []
  ; reasoning_details_rev = []
  ; media = None
  }
;;

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

let text_of_block block = String.concat "" (List.rev block.text_chunks_rev)

let max_input_trace_pieces = 32

let rec take count = function
  | _ when count <= 0 -> []
  | [] -> []
  | item :: rest -> item :: take (count - 1) rest
;;

let record_input_piece piece block =
  { block with
    input_pieces_rev = take max_input_trace_pieces (piece :: block.input_pieces_rev)
  ; input_piece_count = block.input_piece_count + 1
  }
;;

let input_trace_suffix block =
  match block.input_piece_count with
  | 0 -> ""
  | count ->
    let retained = List.rev block.input_pieces_rev in
    let omitted = count - List.length retained in
    let pieces =
      retained
      |> List.map (function
        | Delta_bytes bytes -> Printf.sprintf "delta:%d" bytes
        | Snapshot_bytes bytes -> Printf.sprintf "snapshot:%d" bytes)
      |> String.concat ","
    in
    let pieces =
      if omitted = 0 then pieces else Printf.sprintf "omitted:%d,%s" omitted pieces
    in
    Printf.sprintf ":assembly=%s" pieces
;;

let signature_of_block block =
  match block.signature_chunks_rev with
  | [] -> None
  | chunks ->
    let signature = String.concat "" (List.rev chunks) in
    if signature = "" then None else Some signature
;;

let update_block index f state =
  let block = Option.value ~default:empty_block (Blocks.find_opt index state.blocks) in
  { state with blocks = Blocks.add index (f block) state.blocks }
;;

let usage_from_message_start (wire : Types.api_usage) =
  { input_tokens = wire.input_tokens
  ; output_tokens = wire.output_tokens
  ; cache_creation = wire.cache_creation_input_tokens
  ; cache_read = wire.cache_read_input_tokens
  }
;;

(* Delta counters are wire-cumulative running totals (#28903): a reported
   field replaces the seeded value, an unreported field keeps it. Nothing is
   ever added — addition double-counts whenever the final delta repeats a
   counter the start event already carried. *)
let overlay_delta_usage current (delta : Types.delta_usage) =
  { input_tokens = Option.value delta.input_tokens ~default:current.input_tokens
  ; output_tokens = Option.value delta.output_tokens ~default:current.output_tokens
  ; cache_creation =
      Option.value delta.cache_creation_input_tokens ~default:current.cache_creation
  ; cache_read =
      Option.value delta.cache_read_input_tokens ~default:current.cache_read
  }
;;

let capture_failure failure state =
  match state.failure with
  | Some _ -> state
  | None -> { state with failure = Some failure }
;;

let transition_open state = function
  | Types.MessageStart { id; model; usage } ->
    let usage =
      match usage with
      | None -> state.usage
      | Some wire -> usage_from_message_start wire
    in
    { state with id; model; usage }
  | Types.ContentBlockStart { index; content_type; tool_id; tool_name } ->
    let block =
      { empty_block with
        header =
          Announced { kind = block_kind_of_string content_type; tool_id; tool_name }
      }
    in
    { state with blocks = Blocks.add index block state.blocks }
  | Types.ContentBlockDelta { index; delta } ->
    update_block
      index
      (fun block ->
         match delta with
         | Types.TextDelta text | Types.ThinkingDelta text ->
           (* Incremental deltas append unconditionally. A whole-value re-emit
              has its own [InputJsonSnapshot] constructor below, so no string
              heuristic guesses whether an object-shaped fragment replaces. *)
           { block with text_chunks_rev = text :: block.text_chunks_rev }
         | Types.InputJsonDelta text ->
           { block with text_chunks_rev = text :: block.text_chunks_rev }
           |> record_input_piece (Delta_bytes (String.length text))
         | Types.InputJsonSnapshot text ->
           { block with text_chunks_rev = [ text ] }
           |> record_input_piece (Snapshot_bytes (String.length text))
         | Types.ReasoningDetailsDelta { reasoning_content; details } ->
           { block with
             text_chunks_rev =
               (match reasoning_content with
                | None -> block.text_chunks_rev
                | Some content -> content :: block.text_chunks_rev)
           ; reasoning_details_rev =
               List.rev_append details block.reasoning_details_rev
           }
         | Types.MediaDelta { media_type; source_type; data } ->
           { block with
             text_chunks_rev = data :: block.text_chunks_rev
           ; media = Some { media_type; source_type }
           }
         | Types.ThinkingSignatureDelta signature ->
           { block with
             signature_chunks_rev = signature :: block.signature_chunks_rev
           })
      state
  | Types.ContentBlockStop _ -> state
  | Types.MessageDelta { stop_reason; usage } ->
    let completion =
      match stop_reason with
      | None -> state.completion
      | Some stop_reason -> Stopped stop_reason
    in
    let usage =
      match usage with
      | None -> state.usage
      | Some delta -> overlay_delta_usage state.usage delta
    in
    { state with completion; usage }
  | Types.SSEError { message; error_type; raw }
  | Types.NDJSONError { message; error_type; raw } ->
    capture_failure (Types.Stream_provider_error { message; error_type; raw }) state
  | Types.SSEParseFailed { raw; reason } ->
    capture_failure (Types.Stream_parse_failed { reason; raw }) state
  | Types.NDJSONParseFailed { raw; reason } ->
    capture_failure (Types.Stream_ndjson_parse_failed { reason; raw }) state
  | Types.SSEUnknownEventType { event_type; raw } ->
    capture_failure (Types.Stream_unknown_event { event_type; raw }) state
  | Types.SSEUnsupportedPart { provider_kind; part; raw } ->
    capture_failure (Types.Stream_unsupported_part { provider_kind; part; raw }) state
  | Types.SSEUnsupportedResponse { provider_kind; response; raw } ->
    capture_failure
      (Types.Stream_unsupported_response { provider_kind; response; raw })
      state
  | Types.StreamIncomplete { reason } ->
    { state with disposition = Incomplete reason }
  | Types.MessageStop ->
    let completion =
      match state.completion with
      | Awaiting_stop -> Terminal_without_stop_reason
      | Terminal_without_stop_reason | Stopped _ as completion -> completion
    in
    { state with completion }
  | Types.Ping | Types.Connected | Types.Timeout _ -> state
;;

let transition state event =
  match state.failure with
  | Some _ -> state
  | None -> transition_open state event
;;

let has_failed state = Option.is_some state.failure

let stream_parse_failed ~reason ?(raw = "") () =
  Error (Types.Stream_parse_failed { reason; raw })
;;

let required_nonblank ~reason = function
  | Some value when not (Api_common.string_is_blank value) -> Ok value
  | Some _ | None -> stream_parse_failed ~reason ()
;;

let media_content ~index ~kind ~make block text =
  if String.trim text = ""
  then Ok None
  else (
    match block.media with
    | Some { media_type; source_type } when String.trim media_type <> "" ->
      Ok (Some (make ~media_type ~data:text ~source_type))
    | Some _ | None ->
      stream_parse_failed
        ~reason:(Printf.sprintf "malformed_media_block:%s:index:%d" kind index)
        ())
;;

let tool_input ~index ~trace text =
  if String.trim text = ""
  then Ok (`Assoc [])
  else (
    match Tool_call_input.parse_object text with
    | Ok input -> Ok input
    | Error Tool_call_input.Not_object ->
      stream_parse_failed
        ~reason:(Printf.sprintf "malformed_tool_use_arguments:index:%d:not_object" index)
        ~raw:text
        ()
    | Error (Tool_call_input.Invalid_json reason) ->
      stream_parse_failed
        ~reason:
          (Printf.sprintf
             "malformed_tool_use_arguments:index:%d:%s%s"
             index
             reason
             (input_trace_suffix trace))
        ~raw:text
        ())
;;

let tool_block_is_incomplete disposition stop_reason =
  match disposition with
  | Incomplete _ -> true
  | Natural -> stop_reason = Types.MaxTokens
;;

let content_of_block ~disposition ~stop_reason (index, block) =
  let text = text_of_block block in
  match block.header with
  | Unannounced -> Ok None
  | Announced { kind = Text_block; _ } -> Ok (Some (Types.Text text))
  | Announced { kind = Thinking_block; _ } ->
    Ok
      (Some
         (Types.Thinking { content = text; signature = signature_of_block block }))
  | Announced { kind = Reasoning_details_block; _ } ->
    let details = List.rev block.reasoning_details_rev in
    let reasoning_content = if String.trim text = "" then None else Some text in
    (match reasoning_content, details with
     | None, [] -> Ok None
     | Some _, _ | None, _ :: _ ->
       Ok (Some (Types.ReasoningDetails { reasoning_content; details })))
  | Announced { kind = Redacted_thinking_block; tool_id; _ } ->
    (match tool_id with
     | Some data when data <> "" -> Ok (Some (Types.RedactedThinking data))
     | Some _ | None -> Ok None)
  | Announced { kind = Tool_use_block; _ }
    when tool_block_is_incomplete disposition stop_reason ->
    (* A cut-off tool block is not executable even when its partial argument
       buffer happens to parse. Projection drops it before it can enter
       assistant history. *)
    Ok None
  | Announced { kind = Tool_use_block; tool_id; tool_name } ->
    let* name =
      required_nonblank
        ~reason:(Printf.sprintf "malformed_tool_use:index:%d:missing_name" index)
        tool_name
    in
    let* input = tool_input ~index ~trace:block text in
    let* id =
      required_nonblank
        ~reason:(Printf.sprintf "malformed_tool_use:index:%d:missing_id" index)
        tool_id
    in
    Ok (Some (Types.ToolUse { id; name; input }))
  | Announced { kind = Tool_result_block { is_error }; tool_id; _ } ->
    let* tool_use_id =
      required_nonblank
        ~reason:(Printf.sprintf "malformed_tool_result:index:%d:missing_id" index)
        tool_id
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
  | Announced { kind = Image_block; _ } ->
    media_content
      ~index
      ~kind:"image"
      ~make:(fun ~media_type ~data ~source_type ->
        Types.Image { media_type; data; source_type })
      block
      text
  | Announced { kind = Document_block; _ } ->
    media_content
      ~index
      ~kind:"document"
      ~make:(fun ~media_type ~data ~source_type ->
        Types.Document { media_type; data; source_type })
      block
      text
  | Announced { kind = Audio_block; _ } ->
    media_content
      ~index
      ~kind:"audio"
      ~make:(fun ~media_type ~data ~source_type ->
        Types.Audio { media_type; data; source_type })
      block
      text
  | Announced { kind = Unknown_block kind; _ } ->
    (* Unknown wire semantics are not assistant text. Fail closed without
       copying the provider payload into the diagnostic carrier. *)
    stream_parse_failed
      ~reason:(Printf.sprintf "unsupported_content_block_kind:%s:index:%d" kind index)
      ()
;;

let collect_content state stop_reason =
  let rec loop content = function
    | [] -> Ok (List.rev content)
    | block :: rest ->
      let* item = content_of_block ~disposition:state.disposition ~stop_reason block in
      loop (Option.fold ~none:content ~some:(fun item -> item :: content) item) rest
  in
  loop [] (Blocks.bindings state.blocks)
;;

let has_tool_block =
  List.exists (function
    | Types.ToolUse _ -> true
    | Types.Text _
    | Types.Thinking _
    | Types.ReasoningDetails _
    | Types.RedactedThinking _
    | Types.ToolResult _
    | Types.Image _
    | Types.Document _
    | Types.Audio _ -> false)
;;

let finalize_completed state stop_reason =
  let* content = collect_content state stop_reason in
  let stop_reason =
    Stop_reason_wire.reconcile stop_reason ~has_tool_blocks:(has_tool_block content)
  in
  Ok
    { Types.id = state.id
    ; model = state.model
    ; stop_reason
    ; content
    ; usage =
        Some
          { input_tokens = state.usage.input_tokens
          ; output_tokens = state.usage.output_tokens
          ; cache_creation_input_tokens = state.usage.cache_creation
          ; cache_read_input_tokens = state.usage.cache_read
          ; cost_usd = None
          }
    ; telemetry = None
    }
;;

let finalize state =
  let result =
    match state.failure, state.completion with
    | Some failure, _ -> Error failure
    | None, Awaiting_stop ->
      Error
        (Types.Stream_incomplete
           { reason = "stream_terminated_without_stop_reason" })
    | None, Terminal_without_stop_reason ->
      Error
        (Types.Stream_incomplete
           { reason = "stream_terminal_without_stop_reason" })
    | None, Stopped stop_reason -> finalize_completed state stop_reason
  in
  match result with
  | Ok response -> Completed response
  | Error failure -> Failed failure
;;

[@@@coverage off]

let%test "transition is deterministic for the same snapshot and event" =
  let event =
    Types.MessageStart { id = "message"; model = "model"; usage = None }
  in
  transition empty event = transition empty event
;;

let%test "first terminal failure is sticky" =
  let first =
    Types.Stream_parse_failed { reason = "first"; raw = "first-raw" }
  in
  let state =
    empty
    |> fun state ->
    transition state (Types.SSEParseFailed { reason = "first"; raw = "first-raw" })
    |> fun state ->
    transition
      state
      (Types.SSEError { message = "second"; error_type = None; raw = "second-raw" })
  in
  match finalize state with
  | Failed failure -> failure = first
  | Completed _ -> false
;;

let%test "snapshot delta replaces an earlier complete tool input" =
  let state =
    empty
    |> fun state ->
    transition
      state
      (Types.ContentBlockStart
         { index = 0
         ; content_type = "tool_use"
         ; tool_id = Some "call"
         ; tool_name = Some "lookup"
         })
    |> fun state ->
    transition
      state
      (Types.ContentBlockDelta
         { index = 0; delta = Types.InputJsonSnapshot {|{"old":1}|} })
    |> fun state ->
    transition
      state
      (Types.ContentBlockDelta
         { index = 0; delta = Types.InputJsonSnapshot {|{"limit":10}|} })
    |> fun state ->
    (* Settling is a MessageDelta carrying the stop reason; naming the event
       keeps the test honest about what "finishing" is. *)
    transition
      state
      (Types.MessageDelta { stop_reason = Some Types.StopToolUse; usage = None })
  in
  match finalize state with
  | Completed { content = [ Types.ToolUse { input; _ } ]; _ } ->
    input = `Assoc [ "limit", `Int 10 ]
  | Completed _ | Failed _ -> false
;;

let%test "terminal sentinel without stop semantics remains incomplete" =
  match finalize (transition empty Types.MessageStop) with
  | Failed (Types.Stream_incomplete { reason }) ->
    reason = "stream_terminal_without_stop_reason"
  | Failed _ | Completed _ -> false
;;
