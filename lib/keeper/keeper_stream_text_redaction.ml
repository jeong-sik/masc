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
  }

(* At most one block is held: a content event of any other block releases it
   first (see the .mli), so the next held block starts empty. *)
type t =
  { redaction : Keeper_secret_redaction.t
  ; mutable held : held option
  }

let create redaction = { redaction; held = None }

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

let flush t =
  match t.held with
  | None -> []
  | Some { index; channel; stream } ->
    t.held <- None;
    emitted ~index channel (Keeper_secret_redaction.redact_stream_finish stream)
;;

let feed t ~index channel text =
  let released, stream =
    match t.held with
    | Some held when Int.equal held.index index && channel_equal held.channel channel ->
      [], held.stream
    | Some _ | None ->
      let released = flush t in
      let stream = Keeper_secret_redaction.create_stream_state t.redaction in
      t.held <- Some { index; channel; stream };
      released, stream
  in
  released @ emitted ~index channel (Keeper_secret_redaction.redact_stream_chunk stream text)
;;

let whole t text = Keeper_secret_redaction.redact_text t.redaction text

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
    flush t @ [ ContentBlockDelta { index; delta = TextSnapshot (whole t text) } ]
  | ContentBlockDelta { index; delta = InputJsonSnapshot text } ->
    flush t @ [ ContentBlockDelta { index; delta = InputJsonSnapshot (whole t text) } ]
  | ContentBlockDelta
      { delta = ThinkingSignatureDelta _ | RedactedThinkingSnapshot _ | MediaDelta _; _ }
  | ContentBlockStart _
  | ContentBlockStop _
  | MessageStart _
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
