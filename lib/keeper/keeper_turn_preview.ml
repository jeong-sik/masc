(** Ephemeral activity for the running Keeper turn. Reset at turn entry;
    the turns route also rejects observations older than its running turn.
    Provider attempts, stream events, and tool hooks write this projection. *)

type activity = Preparing | Awaiting_response | Receiving_response | Tool_observed | Failed

type t =
  { text_tail : string
  ; last_tool : string option
  ; updated_at : float
  ; runtime_id : string option
  ; activity : activity
  ; last_failure : string option
  }

(* Enough to recognize the work ("ah, it is writing the PR body"), small
   enough that the turns poll stays a light projection. The tail is cut with
   [String_util.utf8_suffix] so a cut Hangul glyph never reaches a terminal. *)
let tail_bytes = 240

(* Every writer owns its stream redactor, including held partial lines. *)
type text_intake =
  { redaction : Keeper_secret_redaction.t
  ; stream : Keeper_stream_text_redaction.t
  }

module Tool_indexes = Map.Make (Int)

type entry =
  { preview : t
  ; text_intake : text_intake
  ; tools : string Tool_indexes.t
  }
type writer = entry ref

(* The displayed preview points at the latest installed writer. Callbacks
   retain their own writer and never look it up in this table. *)
let table : (string, writer) Hashtbl.t = Hashtbl.create 16

let mutex = Mutex.create ()

let with_lock f =
  Mutex.lock mutex;
  Fun.protect ~finally:(fun () -> Mutex.unlock mutex) f

let empty now =
  { text_tail = ""; last_tool = None; updated_at = now
  ; runtime_id = None; activity = Preparing; last_failure = None }

let current ~keeper_name =
  with_lock (fun () ->
    Option.map (fun writer -> (!writer).preview) (Hashtbl.find_opt table keeper_name))

(* [f] returns [None] when the note changes nothing, which leaves
   [updated_at] where it was. *)
let change_entry ~writer ~now f =
  Option.iter (fun writer ->
    with_lock (fun () ->
      match f !writer with
      | None -> ()
      | Some entry ->
        writer := { entry with preview = { entry.preview with updated_at = now } })) writer

let update ~writer ~now f =
  change_entry ~writer ~now (fun entry ->
    Some { entry with preview = f entry.preview })

let redacting redaction =
  { redaction; stream = Keeper_stream_text_redaction.create redaction }

let reset ~keeper_name ~now ~redaction =
  let writer = ref { preview = empty now; text_intake = redacting redaction; tools = Tool_indexes.empty } in
  with_lock (fun () -> Hashtbl.replace table keeper_name writer);
  writer

let note_attempt ~writer ~now ~runtime_id =
  change_entry ~writer ~now (fun { preview; text_intake; tools = _ } ->
    Some
      { preview =
          { preview with runtime_id = Some runtime_id; activity = Awaiting_response
          ; last_tool = None; text_tail = "" }
        (* A new attempt is a new provider stream. Text the previous stream
           still held belongs to the tail this clears. *)
      ; tools = Tool_indexes.empty
      ; text_intake =
          redacting text_intake.redaction
      })

let note_failure ~writer ~now ~runtime_id detail =
  let detail = Observability_redact.redact_preview ~max_len:tail_bytes detail in
  update ~writer ~now (fun old ->
    { old with runtime_id = Some runtime_id; activity = Failed
    ; last_tool = None; last_failure = Some detail })

(* The whole response text arrives here at once, so plain redaction sees
   every secret in it whole before the tail is cut. *)
let note_text ~writer ~now text =
  let text = String.trim text in
  if not (String.equal text "") then
    change_entry ~writer ~now (fun ({ preview; text_intake; tools = _ } as entry) ->
      let preview =
        let redaction = text_intake.redaction in
          { preview with
            text_tail =
              String_util.utf8_suffix ~max_bytes:tail_bytes
                (Keeper_secret_redaction.redact_text redaction text)
          ; activity = Receiving_response }
      in
      Some { entry with preview })

let note_tool ~writer ~now tool_name =
  update ~writer ~now (fun old ->
    { old with last_tool = Some tool_name; activity = Tool_observed })

(* What a provider event says about the turn apart from its text. It reads
   the event as it arrived, so the activity moves while the redactor still
   holds the first line back. *)
let activity_of_event preview (event : Agent_core.Types.sse_event) =
  match event with
  | Agent_core.Types.ContentBlockDelta { delta = TextDelta _; _ } ->
    Some { preview with activity = Receiving_response }
  | ContentBlockStart { tool_name = Some tool_name; _ } ->
    Some { preview with last_tool = Some tool_name; activity = Tool_observed }
  | ContentBlockDelta { delta = TextSnapshot text; _ }
    when not (String.equal (String.trim text) "") ->
    Some { preview with activity = Receiving_response }
  | MessageStart _ | ContentBlockDelta { delta = ThinkingDelta _ | ReasoningDetailsDelta _; _ } ->
    Some { preview with activity = Receiving_response }
  | _ -> None

(* The tail after one event the redactor released, or [None] when that
   event carries no response text. *)
let text_tail_after tail (event : Agent_core.Types.sse_event) =
  match event with
  | Agent_core.Types.ContentBlockDelta { delta = TextDelta text; _ } ->
    Some (String_util.utf8_suffix ~max_bytes:tail_bytes (tail ^ text))
  | ContentBlockDelta { delta = TextSnapshot text; _ } ->
    let text = String.trim text in
    if String.equal text "" then None else Some (String_util.utf8_suffix ~max_bytes:tail_bytes text)
  | _ -> None

let released_text_tail tail events =
  let released, changed =
    List.fold_left
      (fun (tail, changed) event ->
         match text_tail_after tail event with
         | Some tail -> tail, true
         | None -> tail, changed)
      (tail, false) events
  in
  if changed then Some released else None

(* Deltas pass through the turn's stream redactor, which releases a line once
   it is complete, so a secret split between two deltas is replaced before any
   part of it reaches the tail. *)
let note_stream ~writer ~now event =
  change_entry ~writer ~now (fun ({ preview; text_intake; tools = _ } as entry) ->
    let text_tail =
      released_text_tail preview.text_tail
        (Keeper_stream_text_redaction.on_event text_intake.stream event)
    in
    let tools, activity =
      match event with
      | Agent_core.Types.ContentBlockStart { index; tool_name = Some name; _ } ->
        Tool_indexes.add index name entry.tools, activity_of_event preview event
      | ContentBlockStop { index } ->
        Tool_indexes.remove index entry.tools,
        Option.map (fun name ->
          { preview with last_tool = Some name; activity = Tool_observed })
          (Tool_indexes.find_opt index entry.tools)
      | _ -> entry.tools, activity_of_event preview event
    in
    let entry = { entry with tools } in
    match activity, text_tail with
    | None, None -> None
    | Some preview, None -> Some { entry with preview }
    | None, Some text_tail -> Some { entry with preview = { preview with text_tail } }
    | Some preview, Some text_tail ->
      Some { entry with preview = { preview with text_tail } })

let status_text preview =
  let activity =
    match preview.activity with
    | Preparing -> "preparing turn"
    | Awaiting_response -> "waiting for provider response"
    | Receiving_response -> "receiving response"
    | Tool_observed -> "tool activity observed"
    | Failed -> "provider attempt failed"
  in
  String.concat " · "
    (List.filter_map Fun.id
       [ preview.runtime_id; Some activity
       ; Option.map (fun name -> "last observed tool: " ^ name) preview.last_tool
       ; Option.map (fun detail -> "last failure: " ^ detail) preview.last_failure ])
