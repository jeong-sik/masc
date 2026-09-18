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

type block_lifecycle =
  | Open
  | Closed

type block =
  { header : block_header
  ; lifecycle : block_lifecycle
  ; text_chunks_rev : string list
  ; input_pieces_rev : input_piece list
  ; input_piece_count : int
  ; signature_chunks_rev : string list
  ; reasoning_details_rev : Types.reasoning_detail list
  ; media : media option
  ; repeat_checked_bytes : int
        (** Text bytes the block held when the reasoning repeat rule last ran. *)
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

type message_lifecycle =
  | Accepting_content
  | Stop_reason_seen
  | Message_stopped

type disposition =
  | Natural
  | Incomplete of string

type t =
  { id : string
  ; model : string
  ; message_started : bool
  ; message_start : (string * string * Types.api_usage option) option
  ; usage : usage
  ; completion : completion
  ; message_lifecycle : message_lifecycle
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
  ; message_started = false
  ; message_start = None
  ; usage = empty_usage
  ; completion = Awaiting_stop
  ; message_lifecycle = Accepting_content
  ; disposition = Natural
  ; failure = None
  ; blocks = Blocks.empty
  }
;;

let empty_block =
  { header = Unannounced
  ; lifecycle = Open
  ; text_chunks_rev = []
  ; input_pieces_rev = []
  ; input_piece_count = 0
  ; signature_chunks_rev = []
  ; reasoning_details_rev = []
  ; media = None
  ; repeat_checked_bytes = 0
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

let block_kind_equal left right =
  match left, right with
  | Text_block, Text_block
  | Thinking_block, Thinking_block
  | Reasoning_details_block, Reasoning_details_block
  | Redacted_thinking_block, Redacted_thinking_block
  | Tool_use_block, Tool_use_block
  | Image_block, Image_block
  | Document_block, Document_block
  | Audio_block, Audio_block -> true
  | Tool_result_block left, Tool_result_block right ->
    Bool.equal left.is_error right.is_error
  | Unknown_block left, Unknown_block right -> String.equal left right
  | _ -> false
;;

let block_header_equal left right =
  match left, right with
  | Unannounced, Unannounced -> true
  | Announced left, Announced right ->
    block_kind_equal left.kind right.kind
    && Option.equal String.equal left.tool_id right.tool_id
    && Option.equal String.equal left.tool_name right.tool_name
  | Unannounced, Announced _ | Announced _, Unannounced -> false
;;

let text_of_block block = String.concat "" (List.rev block.text_chunks_rev)

(* A generation that starts repeating one paragraph does not stop on its own;
   it runs to the token ceiling. Measured on a live collapse (29,788 bytes, 234
   paragraphs, 11 distinct): the third occurrence of a repeated paragraph
   landed at 1,691 bytes — 5% of what the provider was eventually paid for.
   The remaining 95% wrote the same eleven paragraphs 221 more times.

   Three is the same threshold the Keeper turn loop already uses for repeated
   assistant text between rounds; this is that rule one layer in, where a
   single generation can be stopped before it is finished.

   Only whole paragraphs count. A repeated word or line is ordinary prose —
   lists, tables and code all repeat short strings — and the collapse this
   catches repeats units large enough to be a paragraph. Blank and very short
   paragraphs are skipped for the same reason. *)
let repeat_threshold = 3
let repeat_min_paragraph_bytes = 40

let repeating_paragraph text =
  let paragraphs =
    String.split_on_char '\n' text
    |> List.filter_map (fun line ->
      let trimmed = String.trim line in
      if String.length trimmed < repeat_min_paragraph_bytes then None else Some trimmed)
  in
  let counts = Hashtbl.create 64 in
  List.fold_left
    (fun found paragraph ->
       match found with
       | Some _ -> found
       | None ->
         let seen = (try Hashtbl.find counts paragraph with Not_found -> 0) + 1 in
         Hashtbl.replace counts paragraph seen;
         if seen >= repeat_threshold then Some (paragraph, seen) else None)
    None
    paragraphs
;;

let block_has_payload block =
  block.text_chunks_rev <> []
  || block.input_piece_count > 0
  || block.signature_chunks_rev <> []
  || block.reasoning_details_rev <> []
  || Option.is_some block.media
;;

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

(* A reasoning block is guarded by a different rule from a text block. The
   paragraph count above is for an answer: whole paragraphs recurring anywhere
   in the block, which prose does not do. A model thinking is allowed to come
   back to a line — a plan header, "let me check the file again" — and cutting
   it there would end a turn that was about to answer. What ends a reasoning
   block is the shape of a generation that has stopped moving: its tail is one
   unit written verbatim over and over, whatever the unit is ("!!!!", "the the
   the ", a five-line chant). Only the newest bytes are examined, so the cost
   per delta is bounded by the window, not by the block.

   Measured 2026-09-14 on every thinking stream in keeper_chat_events since
   2026-08-29 (1,385 blocks, 6.4 MB), with the window and stride below. Nine
   were loops: verbatim cycles of 35 to 2,491 bytes repeated 6.5 to 1,872
   times, periodic tails of 15 KB to the full window. The longest periodic
   tail in the other 1,376 blocks was 5 bytes (a run of one byte), so 1,024
   is the bound the paragraph-scale loops clear by 15x and prose never
   approaches. The window is 64 KB rather than the 8 KB it started at: the
   rule reads units up to a third of the window, the sangsu loops' units of
   2,330 to 2,491 bytes sat within 10% of the old 2,730-byte ceiling, and a
   601,318-byte thinking block on 2026-09-14 08:50Z (geek-scout,
   deepseek-v4.1-flash) ran to the token ceiling under it unseen. The rule
   runs once per 1,024 new bytes: checking more often than the span can grow
   into a verdict buys nothing, and each run reads the whole window. Three
   copies is the same count the paragraph rule and the Keeper turn loop use. *)
let reasoning_repeat_window_bytes = 65536
let reasoning_repeat_min_span_bytes = 1024
let reasoning_repeat_min_copies = 3
let reasoning_repeat_check_stride_bytes = 1024

(* The newest [bytes] of the block's text, assembled from as few of its
   reversed chunks as reach that many bytes. *)
let block_tail ~bytes block =
  let rec newest acc collected = function
    | [] -> acc
    | chunk :: rest ->
      if collected >= bytes
      then acc
      else newest (chunk :: acc) (collected + String.length chunk) rest
  in
  let joined = String.concat "" (newest [] 0 block.text_chunks_rev) in
  let length = String.length joined in
  if length <= bytes then joined else String.sub joined (length - bytes) bytes
;;

let block_text_bytes block =
  List.fold_left (fun total chunk -> total + String.length chunk) 0 block.text_chunks_rev
;;

let repeating_reasoning_cycle block =
  let tail = block_tail ~bytes:reasoning_repeat_window_bytes block in
  match
    Periodic_suffix.find
      tail
      ~max_period:(reasoning_repeat_window_bytes / reasoning_repeat_min_copies)
      ~min_copies:reasoning_repeat_min_copies
  with
  | Some ({ Periodic_suffix.span; period } as suffix)
    when span >= reasoning_repeat_min_span_bytes ->
    Some (Periodic_suffix.cycle tail suffix, span / period)
  | Some _ | None -> None
;;

(* The kind the provider announced for block [index], whether the block is
   still open or already closed; [None] for a block never announced. *)
let block_kind_at state index =
  match Blocks.find_opt index state.blocks with
  | Some { header = Announced { kind; _ }; _ } -> Some kind
  | Some { header = Unannounced; _ } | None -> None
;;

let guard_repeating_generation ~index state =
  match Blocks.find_opt index state.blocks with
  | None -> state
  | Some block ->
    (match block.header with
     | Announced { kind = Text_block; _ } ->
       let text = text_of_block block in
       (match repeating_paragraph text with
        | None -> state
        | Some (paragraph, occurrences) ->
          capture_failure
            (Types.Stream_repeating
               { repeated = paragraph
               ; occurrences
               ; bytes_seen = String.length text
               ; shape = Types.Repeated_paragraph
               })
            state)
     | Announced { kind = Thinking_block | Reasoning_details_block; _ } ->
       let text_bytes = block_text_bytes block in
       if text_bytes - block.repeat_checked_bytes < reasoning_repeat_check_stride_bytes
       then state
       else (
         let state =
           update_block index (fun block -> { block with repeat_checked_bytes = text_bytes }) state
         in
         match repeating_reasoning_cycle block with
         | None -> state
         | Some (cycle, occurrences) ->
           capture_failure
             (Types.Stream_repeating
                { repeated = cycle
                ; occurrences
                ; bytes_seen = text_bytes
                ; shape = Types.Repeated_reasoning_cycle
                })
             state)
     (* An unannounced block has no declared kind yet; a repeat there is
        indistinguishable from a provider that has not said what it is
        sending. Redacted thinking carries no text to compare. *)
     | Unannounced
     | Announced { kind = Redacted_thinking_block; _ }
     | Announced { kind = Tool_use_block; _ }
     | Announced { kind = Tool_result_block _; _ }
     | Announced { kind = Image_block; _ }
     | Announced { kind = Document_block; _ }
     | Announced { kind = Audio_block; _ }
     | Announced { kind = Unknown_block _; _ } -> state)
;;


let close_all_blocks state =
  { state with
    blocks = Blocks.map (fun block -> { block with lifecycle = Closed }) state.blocks
  }
;;

let message_start_equal
    (left_id, left_model, left_usage)
    (right_id, right_model, right_usage) =
  String.equal left_id right_id
  && String.equal left_model right_model
  && Option.equal ( = ) left_usage right_usage
;;

let terminal_event_failure reason state =
  capture_failure
    (Types.Stream_parse_failed { reason; raw = "" })
    state
;;

let delta_kind_name = function
  | Types.TextDelta _ -> "text"
  | Types.TextSnapshot _ -> "text_snapshot"
  | Types.ThinkingDelta _ -> "thinking"
  | Types.ThinkingSignatureDelta _ -> "thinking_signature"
  | Types.RedactedThinkingSnapshot _ -> "redacted_thinking_snapshot"
  | Types.ReasoningDetailsDelta _ -> "reasoning_details"
  | Types.InputJsonDelta _ -> "input_json_delta"
  | Types.InputJsonSnapshot _ -> "input_json_snapshot"
  | Types.MediaDelta _ -> "media"
;;

let block_kind_name = function
  | Text_block -> "text"
  | Thinking_block -> "thinking"
  | Reasoning_details_block -> "reasoning_details"
  | Redacted_thinking_block -> "redacted_thinking"
  | Tool_use_block -> "tool_use"
  | Tool_result_block { is_error = false } -> "tool_result"
  | Tool_result_block { is_error = true } -> "tool_result_error"
  | Image_block -> "image"
  | Document_block -> "document"
  | Audio_block -> "audio"
  | Unknown_block kind -> kind
;;

let block_kind_accepts_delta kind delta =
  match kind, delta with
  | Text_block, (Types.TextDelta _ | Types.TextSnapshot _)
  | Tool_result_block _, (Types.TextDelta _ | Types.TextSnapshot _)
  | Thinking_block, Types.ThinkingDelta _
  | Thinking_block, Types.ThinkingSignatureDelta _
  | Thinking_block, Types.RedactedThinkingSnapshot _
  | Reasoning_details_block, Types.ReasoningDetailsDelta _
  | Tool_use_block, Types.InputJsonDelta _
  | Tool_use_block, Types.InputJsonSnapshot _
  | Image_block, Types.MediaDelta _
  | Document_block, Types.MediaDelta _
  | Audio_block, Types.MediaDelta _ -> true
  | Redacted_thinking_block, _
  | Unknown_block _, _
  | Text_block, _
  | Thinking_block, _
  | Reasoning_details_block, _
  | Tool_use_block, _
  | Tool_result_block _, _
  | Image_block, _
  | Document_block, _
  | Audio_block, _ -> false
;;

let normalize_text_snapshot ~accumulated snapshot =
  let accumulated_length = String.length accumulated in
  let snapshot_length = String.length snapshot in
  if String.equal accumulated snapshot
  then Ok None
  else if String.starts_with ~prefix:accumulated snapshot
  then
    Ok
      (Some
         (String.sub snapshot accumulated_length (snapshot_length - accumulated_length)))
  else if String.starts_with ~prefix:snapshot accumulated
  then Ok None
  else Error "text_snapshot_conflict"
;;

let normalize_event state event =
  match event with
  | Types.ContentBlockDelta { index; delta = Types.TextSnapshot snapshot } ->
    (match Blocks.find_opt index state.blocks with
     | Some
         ({ header = Announced { kind = (Text_block | Tool_result_block _); _ }
          ; lifecycle = Open
          ; _
          } as block) ->
       let accumulated = text_of_block block in
       (match normalize_text_snapshot ~accumulated snapshot with
        | Ok (Some suffix) ->
          Ok
            (Some
               (Types.ContentBlockDelta
                  { index; delta = Types.TextDelta suffix }))
        | Ok None -> Ok None
        | Error reason ->
          Error
            (Types.Stream_parse_failed
               { reason = Printf.sprintf "%s:index:%d" reason index; raw = "" }))
     | Some _ | None -> Ok (Some event))
  | Types.MessageStart _
  | Types.ContentBlockStart _
  | Types.ContentBlockDelta _
  | Types.ContentBlockStop _
  | Types.MessageDelta _
  | Types.MessageStop
  | Types.Ping
  | Types.SSEError _
  | Types.NDJSONError _
  | Types.SSEParseFailed _
  | Types.NDJSONParseFailed _
  | Types.SSEUnknownEventType _
  | Types.SSEUnsupportedPart _
  | Types.SSEUnsupportedResponse _
  | Types.Connected
  | Types.Timeout _
  | Types.StreamIncomplete _ | Types.StreamRepeating _ -> Ok (Some event)
;;

let transition_open state = function
  | Types.MessageStart { id; model; usage } ->
    let incoming_start = id, model, usage in
    if state.message_lifecycle <> Accepting_content
    then terminal_event_failure "message_start_after_terminal" state
    else if not state.message_started && Blocks.is_empty state.blocks
    then
      let usage =
        match usage with
        | None -> state.usage
        | Some wire -> usage_from_message_start wire
      in
      { state with
        id
      ; model
      ; message_started = true
      ; message_start = Some incoming_start
      ; usage
      }
    else if
      state.message_started
      && state.completion = Awaiting_stop
      && Option.equal message_start_equal (Some incoming_start) state.message_start
    then
      (* A repeated prelude for the same provider message does not reset block
         assembly. Block-level replay ambiguity is handled at its own header. *)
      let usage =
        match usage with
        | None -> state.usage
        | Some wire -> usage_from_message_start wire
      in
      { state with usage }
    else
      capture_failure
        (Types.Stream_parse_failed
           { reason = "message_start_conflict"; raw = "" })
        state
  | Types.ContentBlockStart { index; content_type; tool_id; tool_name } ->
    if state.message_lifecycle <> Accepting_content
    then terminal_event_failure "content_block_start_after_terminal" state
    else
      let kind = block_kind_of_string content_type in
      let tool_identity_missing =
        match kind with
        | Tool_use_block ->
          (match tool_id, tool_name with
           | Some id, Some name ->
             String.trim id = "" || String.trim name = ""
           | None, _ | _, None -> true)
        | Text_block
        | Thinking_block
        | Reasoning_details_block
        | Redacted_thinking_block
        | Tool_result_block _
        | Image_block
        | Document_block
        | Audio_block
        | Unknown_block _ -> false
      in
      if
        match kind with
        | Unknown_block _ -> true
        | Text_block
        | Thinking_block
        | Reasoning_details_block
        | Redacted_thinking_block
        | Tool_use_block
        | Tool_result_block _
        | Image_block
        | Document_block
        | Audio_block -> false
      then
        terminal_event_failure
          (Printf.sprintf "unsupported_content_block_kind:%s:index:%d" content_type index)
          state
      else if tool_identity_missing
      then
        terminal_event_failure
          (Printf.sprintf "malformed_tool_use:index:%d:missing_identity" index)
          state
      else
      let header = Announced { kind; tool_id; tool_name } in
      (match Blocks.find_opt index state.blocks with
     | Some block when block_header_equal block.header header ->
       (match block.lifecycle with
        | Open when not (block_has_payload block) ->
          (* A duplicate header before payload is idempotent: preserve/reset
             are byte-identical, so all stream consumers can accept it. *)
          state
        | Open ->
          capture_failure
            (Types.Stream_parse_failed
               { reason =
                   Printf.sprintf
                     "content_block_start_after_payload:index:%d"
                     index
               ; raw = ""
               })
            state
        | Closed ->
          capture_failure
            (Types.Stream_parse_failed
               { reason =
                   Printf.sprintf "content_block_start_after_stop:index:%d" index
               ; raw = ""
               })
            state)
     | Some _ ->
       capture_failure
         (Types.Stream_parse_failed
            { reason = Printf.sprintf "content_block_start_conflict:index:%d" index
            ; raw = ""
            })
         state
     | None ->
       let block = { empty_block with header } in
       { state with blocks = Blocks.add index block state.blocks })
  | Types.ContentBlockDelta { index; delta } ->
    if state.message_lifecycle <> Accepting_content
    then terminal_event_failure "content_block_delta_after_terminal" state
    else
      (match Blocks.find_opt index state.blocks, delta with
     | Some { lifecycle = Closed; _ }, _ ->
       capture_failure
         (Types.Stream_parse_failed
            { reason = Printf.sprintf "content_block_delta_after_stop:index:%d" index
            ; raw = ""
            })
         state
     | None, _ ->
       capture_failure
         (Types.Stream_parse_failed
            { reason = Printf.sprintf "content_block_delta_without_start:index:%d" index
            ; raw = ""
            })
         state
     | Some { header = Unannounced; _ }, _ ->
       capture_failure
         (Types.Stream_parse_failed
            { reason = Printf.sprintf "content_block_delta_without_start:index:%d" index
            ; raw = ""
            })
         state
     | Some { header = Announced { kind; _ }; _ }, delta
       when not (block_kind_accepts_delta kind delta) ->
       capture_failure
         (Types.Stream_parse_failed
            { reason =
                Printf.sprintf
                  "content_block_delta_kind_mismatch:index:%d:block:%s:delta:%s"
                  index
                  (block_kind_name kind)
                  (delta_kind_name delta)
            ; raw = ""
            })
         state
     | Some block, Types.RedactedThinkingSnapshot data
       when String.trim data = "" || block.signature_chunks_rev <> [] ->
       terminal_event_failure
         (Printf.sprintf "invalid_redacted_thinking_snapshot:index:%d" index)
         state
     | ( Some { media = Some media; _ }
       , Types.MediaDelta { media_type; source_type; _ } )
       when not
              (String.equal media.media_type media_type && media.source_type = source_type)
       ->
       capture_failure
         (Types.Stream_parse_failed
            { reason = Printf.sprintf "media_delta_metadata_conflict:index:%d" index
            ; raw = ""
            })
         state
     | _ ->
       guard_repeating_generation
         ~index
         (update_block
            index
            (fun block ->
               match delta with
         | Types.TextDelta text | Types.ThinkingDelta text ->
           (* Incremental deltas append unconditionally. Whole text values have
              the distinct [TextSnapshot] constructor, so repeated tokens are
              never guessed to be transport replays. *)
           { block with text_chunks_rev = text :: block.text_chunks_rev }
         | Types.TextSnapshot text ->
           (* Valid snapshots are normalized to [TextDelta] before transition.
              Retain totality for any future internal caller. *)
           { block with text_chunks_rev = [ text ] }
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
           }
         | Types.RedactedThinkingSnapshot data ->
           (* The producer explicitly authorizes this final carrier. Generic
              repeated/conflicting starts remain rejected above. *)
           { empty_block with
             header =
               Announced
                 { kind = Redacted_thinking_block
                 ; tool_id = Some data
                 ; tool_name = None
                 }
           })
            state))
  | Types.ContentBlockStop { index } ->
    if state.message_lifecycle = Message_stopped
    then terminal_event_failure "content_block_stop_after_message_stop" state
    else
      (match Blocks.find_opt index state.blocks with
     | None -> state
     | Some block ->
       { state with
         blocks = Blocks.add index { block with lifecycle = Closed } state.blocks
       })
  | Types.MessageDelta { stop_reason; usage } ->
    if state.message_lifecycle = Message_stopped
    then terminal_event_failure "message_delta_after_message_stop" state
    else
      let usage =
        match usage with
        | None -> state.usage
        | Some delta -> overlay_delta_usage state.usage delta
      in
      (match state.completion, stop_reason with
       | Awaiting_stop, None -> { state with usage }
       | Awaiting_stop, Some stop_reason ->
         close_all_blocks
           { state with
             completion = Stopped stop_reason
           ; message_lifecycle = Stop_reason_seen
           ; usage
           }
       | Stopped _, None -> { state with usage }
       | Stopped recorded, Some replay when recorded = replay ->
         { state with usage }
       | Stopped _, Some _ ->
         terminal_event_failure "stop_reason_conflict" state
       | Terminal_without_stop_reason, None
       | Terminal_without_stop_reason, Some _ ->
         terminal_event_failure "message_delta_after_message_stop" state)
  | Types.SSEError { message; error_type; provider_status; report; raw } ->
    capture_failure
      (Types.Stream_provider_error { message; error_type; provider_status; report; raw })
      state
  | Types.NDJSONError { message; error_type; raw } ->
    capture_failure
      (Types.Stream_provider_error
         { message
         ; error_type
         ; provider_status = None
         ; report = Types.Provider_stated
         ; raw
         })
      state
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
  (* An inbound repeat event is the transport telling us what this module
     already decides for itself; it is captured as the same sticky failure so
     both paths end one way. *)
  | Types.StreamRepeating { repeated; occurrences; bytes_seen; shape } ->
    capture_failure
      (Types.Stream_repeating { repeated; occurrences; bytes_seen; shape })
      state
  | Types.MessageStop ->
    (match state.message_lifecycle with
     | Message_stopped -> state
     | Accepting_content | Stop_reason_seen ->
       let completion =
         match state.completion with
         | Awaiting_stop -> Terminal_without_stop_reason
         | Terminal_without_stop_reason | Stopped _ as completion -> completion
       in
       close_all_blocks
         { state with completion; message_lifecycle = Message_stopped })
  | Types.Ping | Types.Connected | Types.Timeout _ -> state
;;

let transition_with_resolution state event =
  match state.failure with
  | Some _ -> state, Types.Stream_event_suppressed
  | None ->
    (match normalize_event state event with
     | Ok None -> state, Types.Stream_event_suppressed
     | Error failure ->
       let next = capture_failure failure state in
       next, Types.Stream_event_rejected failure
     | Ok (Some normalized_event) ->
       let next = transition_open state normalized_event in
       (match next.failure with
        | Some failure -> next, Types.Stream_event_rejected failure
        | None -> next, Types.Stream_event_accepted normalized_event))
;;

let transition state event = fst (transition_with_resolution state event)

let has_failed state = Option.is_some state.failure
let failure state = state.failure

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
    | Ok (input, _dropped) -> Ok input
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

(* An OpenAI-compatible stream sends a reasoning.text detail per token: one
   object carrying a few characters of text and the same type, format and
   index as its neighbours. Kept one per token, a block's details are about
   twelve times its text (one live checkpoint: 772,693 details for 3,048
   blocks, 64 MB beside 5.4 MB of reasoning_content). Adjacent fragments of
   one detail are joined when the block closes. A detail with any other field
   (signature, id, data) or another type, format or index starts a new run
   and is kept as it arrived. *)
let detail_type_key = "type"
let detail_text_key = "text"
let detail_format_key = "format"
let detail_index_key = "index"
let text_detail_type = "reasoning.text"

type detail_field =
  | Type_field
  | Text_field
  | Format_field
  | Index_field
  | Other_field

let detail_field_of_key key =
  if String.equal key detail_type_key
  then Type_field
  else if String.equal key detail_text_key
  then Text_field
  else if String.equal key detail_format_key
  then Format_field
  else if String.equal key detail_index_key
  then Index_field
  else Other_field
;;

type text_fragment =
  { fields : (string * Yojson.Safe.t) list
  ; attributes : (string * Yojson.Safe.t) list
        (** Every field but the text, in the provider's order. *)
  ; text : string
  }

let text_fragment_of_detail (detail : Types.reasoning_detail) =
  match detail.raw with
  | `Assoc fields ->
    let rec classify ~typed ~text attributes = function
      | [] ->
        (match typed, text with
         | true, Some text -> Some { fields; attributes = List.rev attributes; text }
         | true, None | false, (Some _ | None) -> None)
      | ((key, value) as field) :: rest ->
        (match detail_field_of_key key with
         | Type_field ->
           (match value with
            | `String kind when (not typed) && String.equal kind text_detail_type ->
              classify ~typed:true ~text (field :: attributes) rest
            | `String _ | `Assoc _ | `List _ | `Int _ | `Intlit _ | `Float _ | `Bool _
            | `Null -> None)
         | Text_field ->
           (match value, text with
            | `String piece, None -> classify ~typed ~text:(Some piece) attributes rest
            | `String _, Some _
            | (`Assoc _ | `List _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null), _ ->
              None)
         | Format_field | Index_field -> classify ~typed ~text (field :: attributes) rest
         | Other_field -> None)
    in
    classify ~typed:false ~text:None [] fields
  | `List _ | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null -> None
;;

let same_attributes left right =
  List.equal
    (fun (left_key, left_value) (right_key, right_value) ->
       String.equal left_key right_key && Yojson.Safe.equal left_value right_value)
    left.attributes
    right.attributes
;;

type text_run =
  { first : Types.reasoning_detail
  ; fragment : text_fragment
  ; pieces_rev : string list
  }

let detail_of_run run =
  match run.pieces_rev with
  | [] | [ _ ] -> run.first
  | _ :: _ :: _ ->
    let text = String.concat "" (List.rev run.pieces_rev) in
    let raw =
      `Assoc
        (List.map
           (fun ((key, _) as field) ->
              match detail_field_of_key key with
              | Text_field -> key, `String text
              | Type_field | Format_field | Index_field | Other_field -> field)
           run.fragment.fields)
    in
    (* The same rule the stream parser applies to one fragment's text. *)
    { Types.raw; text = (if String.trim text = "" then None else Some text) }
;;

let coalesce_text_details details =
  let close run acc =
    match run with
    | Some run -> detail_of_run run :: acc
    | None -> acc
  in
  let rec walk run acc = function
    | [] -> List.rev (close run acc)
    | detail :: rest ->
      (match text_fragment_of_detail detail, run with
       | Some fragment, Some open_run when same_attributes open_run.fragment fragment ->
         walk
           (Some { open_run with pieces_rev = fragment.text :: open_run.pieces_rev })
           acc
           rest
       | Some fragment, (Some _ | None) ->
         walk
           (Some { first = detail; fragment; pieces_rev = [ fragment.text ] })
           (close run acc)
           rest
       | None, (Some _ | None) -> walk None (detail :: close run acc) rest)
  in
  walk None [] details
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
    let details = coalesce_text_details (List.rev block.reasoning_details_rev) in
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
      (Types.SSEError
         { message = "second"
         ; error_type = None
         ; provider_status = None
         ; report = Types.Provider_stated
         ; raw = "second-raw"
         })
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
