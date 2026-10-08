(* HIGH-RISK-UNREVIEWED: decides which streamed model text reaches the chat
   journal, chat adapters and the turn preview, and when. *)

type channel =
  | Text
  | Thinking
  | Tool_arguments

let channel_equal left right =
  match left, right with
  | Text, Text | Thinking, Thinking | Tool_arguments, Tool_arguments -> true
  | (Text | Thinking | Tool_arguments), _ -> false
;;

type held =
  { index : int
  ; channel : channel
  ; stream : Keeper_secret_redaction.stream_state
  ; mutable next_byte : int
  ; mutable consumed : int
  ; awaiting : chunk Queue.t
  }

and chunk =
  { owner : held
  ; first_byte : int
  ; past_byte : int
  ; output : Buffer.t
  }

type pending =
  | Content of chunk
  | Boundary of Agent_core.Types.sse_event

module Indexes = Set.Make (Int)

(* Buffers belong to a channel, while authored chunks retain their arrival
   positions across channels. Redaction may consume a secret spanning several
   chunks; it may not move the surrounding speech across Thinking. *)
type t =
  { redaction : Keeper_secret_redaction.t
  ; mutable held : held list
  ; pending : pending Queue.t
  ; mutable authored_indexes : Indexes.t
  ; mutable announced_indexes : Indexes.t
  }

let create redaction =
  { redaction; held = []; pending = Queue.create (); authored_indexes = Indexes.empty;
    announced_indexes = Indexes.empty }

let delta_event ~index channel text =
  let delta =
    match channel with
    | Text -> Agent_core.Types.TextDelta text
    | Thinking -> Agent_core.Types.ThinkingDelta text
    | Tool_arguments -> Agent_core.Types.InputJsonDelta text
  in
  Agent_core.Types.ContentBlockDelta { index; delta }
;;

(* The redactor returns [""] while it holds a whole chunk back; an empty delta
   carries nothing for a reader, so none is forwarded. *)
let emitted ~index channel text =
  if String.equal text "" then [] else [ delta_event ~index channel text ]
;;

let drain t =
  let rec loop reversed =
    match Queue.peek_opt t.pending with
    | None -> List.rev reversed
    | Some (Boundary event) ->
      ignore (Queue.take t.pending);
      loop (event :: reversed)
    | Some (Content slot) ->
      let released = emitted ~index:slot.owner.index slot.owner.channel
        (Buffer.contents slot.output) in
      Buffer.clear slot.output;
      let reversed = List.rev_append released reversed in
      if slot.owner.consumed >= slot.past_byte then begin
        ignore (Queue.take t.pending);
        loop reversed
      end else List.rev reversed
  in
  loop []
;;

(* A codepoint split between provider chunks belongs to the chunk containing
   its first byte. Never serialize the continuation bytes as another string. *)
let following_char_boundary text offset =
  let before = String_util.utf8_char_boundary text offset in
  if before = offset then offset
  else before + Uchar.utf_decode_length (String.get_utf_8_uchar text before)

let accept_release owner (release : Keeper_secret_redaction.stream_release) =
  owner.consumed <- release.consumed;
  match owner.channel with
  | Tool_arguments ->
    emitted ~index:owner.index Tool_arguments (Secret_patterns.render_pieces release.pieces)
  | Text | Thinking ->
    List.iter (fun piece ->
      let source = match piece with
        | Secret_patterns.Copied {source; _} | Masked {source; _} -> source in
      (* Mapped ranges are contiguous and monotone. Retire each attributed
         chunk once; completed chunks waiting behind a different channel are
         never scanned again. The global queue controls publication only. *)
      let rec distribute () =
        match Queue.peek_opt owner.awaiting with
        | None -> ()
        | Some slot when slot.first_byte >= source.past_byte -> ()
        | Some slot ->
          (match piece with
           | Secret_patterns.Copied {source; text} ->
             let first = max source.first_byte slot.first_byte in
             let past = min source.past_byte slot.past_byte in
             if first < past then begin
               let first = following_char_boundary text (first - source.first_byte) in
               let past = following_char_boundary text (past - source.first_byte) in
               Buffer.add_substring slot.output text first (past - first)
             end
           | Secret_patterns.Masked {source; replacement} ->
             if slot.first_byte <= source.first_byte && source.first_byte < slot.past_byte
             then Buffer.add_string slot.output replacement);
          if slot.past_byte <= source.past_byte then begin
            ignore (Queue.take owner.awaiting);
            distribute ()
          end
      in
      distribute ()) release.pieces;
    []

let flush_where t owns =
  let released, kept = List.partition owns t.held in
  t.held <- kept;
  let arguments = List.concat_map (fun held ->
    accept_release held (Keeper_secret_redaction.redact_stream_finish_mapped held.stream)) released in
  drain t @ arguments

let flush t =
  let released = flush_where t (fun _ -> true) in
  t.authored_indexes <- Indexes.empty;
  t.announced_indexes <- Indexes.empty;
  released

let announce_content t ~index channel =
  let content_type = match channel with
    | Text -> Some "text" | Thinking -> Some "thinking" | Tool_arguments -> None in
  match content_type with
  | None -> []
  | Some content_type ->
    t.authored_indexes <- Indexes.add index t.authored_indexes;
    if Indexes.mem index t.announced_indexes then []
    else begin
      t.announced_indexes <- Indexes.add index t.announced_indexes;
      [ Agent_core.Types.ContentBlockStart
          {index; content_type; tool_id=None; tool_name=None} ]
    end

let owns_channel ~index channel held =
  Int.equal held.index index && channel_equal held.channel channel

let feed t ~index channel text =
  (* The typed delta establishes index occupancy even while its text is held.
     A later malformed tool header cannot acquire this model-content index. *)
  let header = announce_content t ~index channel in
  let owner =
    match List.find_opt (owns_channel ~index channel) t.held with
    | Some held -> held
    | None ->
      let stream = Keeper_secret_redaction.create_stream_state t.redaction in
      let held = {index; channel; stream; next_byte=0; consumed=0; awaiting=Queue.create ()} in
      t.held <- t.held @ [ held ];
      held
  in
  let first_byte = owner.next_byte in
  owner.next_byte <- first_byte + String.length text;
  (match channel with
   | Tool_arguments -> ()
   | Text | Thinking ->
     if not (String.equal text "") then begin
       let slot = {owner; first_byte; past_byte=owner.next_byte;
         output=Buffer.create (String.length text)} in
       Queue.add slot owner.awaiting;
       Queue.add (Content slot) t.pending
     end);
  let arguments = accept_release owner
    (Keeper_secret_redaction.redact_stream_chunk_mapped owner.stream text) in
  header @ drain t @ arguments
;;

let whole t text = Keeper_secret_redaction.redact_text t.redaction text

let replace_snapshot t ~index channel event =
  (* Snapshot values replace their channel, rather than appending to its
     unpublished partial value. Never publish the superseded tail. *)
  let header = announce_content t ~index channel in
  let discarded, kept = List.partition (owns_channel ~index channel) t.held in
  t.held <- kept;
  List.iter (fun owner ->
    owner.consumed <- owner.next_byte;
    Queue.clear owner.awaiting;
    Queue.iter (function
      | Content slot when slot.owner == owner -> Buffer.clear slot.output
      | Content _ | Boundary _ -> ()) t.pending) discarded;
  match channel with
  | Tool_arguments -> drain t @ [ event ]
  | Text | Thinking ->
    Queue.add (Boundary event) t.pending;
    header @ drain t

let on_event t (event : Agent_core.Types.sse_event) =
  let open Agent_core.Types in
  match event with
  | ContentBlockDelta { index; delta = TextDelta text } -> feed t ~index Text text
  | ContentBlockDelta { index; delta = ThinkingDelta text } -> feed t ~index Thinking text
  | ContentBlockDelta
      { index; delta = ReasoningDetailsDelta { reasoning_content; details } } ->
    feed t ~index Thinking (reasoning_details_text ~reasoning_content ~details)
  | ContentBlockDelta { index; delta = InputJsonDelta text } ->
    feed t ~index Tool_arguments text
  | ContentBlockDelta { index; delta = TextSnapshot text } ->
    replace_snapshot t ~index Text
      (ContentBlockDelta { index; delta = TextSnapshot (whole t text) })
  | ContentBlockDelta { index; delta = InputJsonSnapshot text } ->
    replace_snapshot t ~index Tool_arguments
      (ContentBlockDelta { index; delta = InputJsonSnapshot (whole t text) })
  | ContentBlockStop { index } ->
    let released = flush_where t (fun held -> Int.equal held.index index) in
    if Indexes.mem index t.authored_indexes then begin
      Queue.add (Boundary event) t.pending;
      released @ drain t
    end else released @ [event]
  | ContentBlockStart {index; _} ->
    t.announced_indexes <- Indexes.add index t.announced_indexes;
    [event]
  | MessageDelta { stop_reason = Some _; _ }
  | MessageStop
  | SSEError _
  | NDJSONError _
  | SSEParseFailed _
  | NDJSONParseFailed _
  | SSEUnknownEventType _
  | SSEUnsupportedPart _
  | SSEUnsupportedResponse _
  | Timeout _
  | StreamIncomplete _
  | StreamRepeating _ -> flush t @ [ event ]
  | ContentBlockDelta
      { delta = ThinkingSignatureDelta _ | RedactedThinkingSnapshot _ | MediaDelta _; _ }
  | MessageStart _
  | Ping | Connected | MessageDelta { stop_reason = None; _ } -> [ event ]
;;

module Scoped = struct
  type nonrec t =
    { text : t
    ; mutable scope : int option
          (* The scope of the latest event fed; the held text, if any, is
             from it. *)
    }

  let create redaction = { text = create redaction; scope = None }
  let tag scope events = List.map (fun event -> scope, event) events

  let flush t =
    match t.scope with
    | Some scope -> tag scope (flush t.text)
    | None -> (* Nothing has been fed, so nothing is held. *) []
  ;;

  let on_event t ~stream_scope event =
    let released =
      match t.scope with
      | Some scope when not (Int.equal scope stream_scope) -> flush t
      | Some _ | None -> []
    in
    t.scope <- Some stream_scope;
    released @ tag stream_scope (on_event t.text event)
  ;;
end
