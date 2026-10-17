(** Ephemeral activity for the running Keeper turn. Reset at turn entry;
    the turns route also rejects observations older than its running turn.
    Provider attempts, stream events, and tool hooks write this projection. *)

type activity = Preparing | Awaiting_response | Receiving_response | Tool_observed | Failed

type preparation_phase = Context_preparation | Tool_preparation | Skill_preparation
type preparation_outcome = Prepared | Rejected | Raised | Cancelled
type preparation_state =
  | Preparation_active
  | Preparation_finished of
      { outcome : preparation_outcome; elapsed_ns : int64; finished_at : float }
type preparation =
  { phase : preparation_phase
  ; turn_ref : Ids.Turn_ref.t option
  ; started_at : float
  ; state : preparation_state
  }

type source_position = { generation : int; start_byte : int }

type t =
  { text_position : source_position
  ; text_tail : string
  ; last_tool : string option
  ; updated_at : float
  ; runtime_id : string option
  ; activity : activity
  ; last_failure : string option
  ; preparation : preparation option
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
  ; released_bytes : int
  ; tools : string Tool_indexes.t
  ; preparations : (unit ref * preparation) list
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
  { text_position = {generation=0; start_byte=0}; text_tail = ""; last_tool = None; updated_at = now
  ; runtime_id = None; activity = Preparing; last_failure = None; preparation = None }

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
    Some { entry with preparations = [];
      preview = { (f entry.preview) with preparation = None } })

let with_preparation_result ~writer ~turn_ref ~phase operation =
  match writer with
  | None -> operation ()
  | Some _ ->
    let token = ref () in
    let started = Mtime_clock.now () in
    let started_at = Time_compat.now () in
    let preparation = {phase;turn_ref;started_at;state=Preparation_active} in
    change_entry ~writer ~now:started_at (fun entry ->
      Some {entry with preparations=(token,preparation)::entry.preparations;
        preview={entry.preview with preparation=Some preparation;activity=Preparing}});
    let finish outcome =
      let elapsed_ns = Mtime.Span.to_uint64_ns (Mtime.span started (Mtime_clock.now ())) in
      let finished_at = Time_compat.now () in
      change_entry ~writer ~now:finished_at (fun entry ->
        if not (List.exists (fun (owner,_) -> owner == token) entry.preparations) then None
        else
          let preparations = List.filter (fun (owner,_) -> owner != token) entry.preparations in
          let preparation = match preparations with
            | (_,parent)::_ -> parent
            | [] -> {preparation with state=Preparation_finished {outcome;elapsed_ns;finished_at}} in
          Some {entry with preparations;
            preview={entry.preview with preparation=Some preparation}})
    in
    match operation () with
    | result -> finish (match result with Ok _ -> Prepared | Error _ -> Rejected); result
    | exception error ->
      let backtrace = Printexc.get_raw_backtrace () in
      finish (match error with Eio.Cancel.Cancelled _ -> Cancelled | _ -> Raised);
      Printexc.raise_with_backtrace error backtrace
;;

let redacting redaction =
  { redaction; stream = Keeper_stream_text_redaction.create redaction }

let reset ~keeper_name ~now ~redaction =
  let writer = ref { preview = empty now; text_intake = redacting redaction;
    released_bytes = 0; tools = Tool_indexes.empty; preparations = [] } in
  with_lock (fun () -> Hashtbl.replace table keeper_name writer);
  writer

let note_attempt ~writer ~now ~runtime_id =
  change_entry ~writer ~now (fun { preview; text_intake; _ } ->
    Some
      { preview =
          { preview with runtime_id = Some runtime_id; activity = Awaiting_response
          ; last_tool = None; text_tail = ""; preparation = None
          ; text_position = {generation=preview.text_position.generation + 1; start_byte=0} }
        (* A new attempt is a new provider stream. Text the previous stream
           still held belongs to the tail this clears. *)
      ; tools = Tool_indexes.empty
      ; preparations = []
      ; released_bytes = 0
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
    change_entry ~writer ~now (fun ({ preview; text_intake; _ } as entry) ->
      let text = Keeper_secret_redaction.redact_text text_intake.redaction text in
      let text_tail = String_util.utf8_suffix ~max_bytes:tail_bytes text in
      let released_bytes = String.length text in
      let text_position = {generation=preview.text_position.generation + 1;
        start_byte=released_bytes - String.length text_tail} in
      Some { entry with released_bytes; text_intake=redacting text_intake.redaction;
        preparations=[];
        preview={preview with text_tail; text_position; activity=Receiving_response;preparation=None} })


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
  | Agent_core.Types.ContentBlockDelta { delta = (Agent_core.Types.ThinkingSignatureDelta _ | (Agent_core.Types.RedactedThinkingSnapshot _ | (Agent_core.Types.InputJsonDelta _ | (Agent_core.Types.InputJsonSnapshot _ | Agent_core.Types.MediaDelta _))));_}
  | Agent_core.Types.ContentBlockStart { tool_name = None;_} | Agent_core.Types.MessageStop
  | Agent_core.Types.Ping | Agent_core.Types.Connected | Agent_core.Types.ContentBlockStop _
  | Agent_core.Types.MessageDelta _ | Agent_core.Types.SSEError _ | Agent_core.Types.NDJSONError _
  | Agent_core.Types.SSEParseFailed _ | Agent_core.Types.NDJSONParseFailed _
  | Agent_core.Types.SSEUnknownEventType _ | Agent_core.Types.SSEUnsupportedPart _
  | Agent_core.Types.SSEUnsupportedResponse _ | Agent_core.Types.Timeout _
  | Agent_core.Types.StreamIncomplete _ | Agent_core.Types.StreamRepeating _
  | ContentBlockDelta {delta=TextSnapshot _; _ } -> None

(* Positions count only bytes actually emitted by this writer's redactor.
   A replacement starts a new source generation, even if its text repeats. *)
let released_text entry events =
  List.fold_left (fun (entry, changed) (event : Agent_core.Types.sse_event) ->
    let replace, text = match event with
      | ContentBlockDelta {delta=TextDelta text; _} -> false, Some text
      | ContentBlockDelta {delta=TextSnapshot text; _} ->
          true, Some (String.trim text)
      | Agent_core.Types.ContentBlockDelta { delta = (Agent_core.Types.ThinkingDelta _ | (Agent_core.Types.ThinkingSignatureDelta _ | (Agent_core.Types.RedactedThinkingSnapshot _ | (Agent_core.Types.ReasoningDetailsDelta _ | (Agent_core.Types.InputJsonDelta _ | (Agent_core.Types.InputJsonSnapshot _ | Agent_core.Types.MediaDelta _))))));_}
      | Agent_core.Types.MessageStop | Agent_core.Types.Ping | Agent_core.Types.Connected
      | Agent_core.Types.MessageStart _ | Agent_core.Types.ContentBlockStart _
      | Agent_core.Types.ContentBlockStop _ | Agent_core.Types.MessageDelta _
      | Agent_core.Types.SSEError _ | Agent_core.Types.NDJSONError _
      | Agent_core.Types.SSEParseFailed _ | Agent_core.Types.NDJSONParseFailed _
      | Agent_core.Types.SSEUnknownEventType _ | Agent_core.Types.SSEUnsupportedPart _
      | Agent_core.Types.SSEUnsupportedResponse _ | Agent_core.Types.Timeout _
      | Agent_core.Types.StreamIncomplete _ | Agent_core.Types.StreamRepeating _ -> false, None in
    match text with
    | None -> entry, changed
    | Some text ->
        let preview = entry.preview in
        let released_bytes = if replace then String.length text
          else entry.released_bytes + String.length text in
        let generation = preview.text_position.generation + (if replace then 1 else 0) in
        let text_tail = String_util.utf8_suffix ~max_bytes:tail_bytes
          (if replace then text else preview.text_tail ^ text) in
        let text_position = {generation; start_byte=released_bytes - String.length text_tail} in
        {entry with released_bytes; preview={preview with text_tail; text_position}}, true)
    (entry, false) events

(* Deltas pass through the turn's stream redactor, which releases a line once
   it is complete, so a secret split between two deltas is replaced before any
   part of it reaches the tail. *)
let note_stream ~writer ~now event =
  change_entry ~writer ~now (fun ({ preview; text_intake; _ } as entry) ->
    let released_entry, text_changed =
      released_text entry
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
      | Agent_core.Types.ContentBlockStart _
      | Agent_core.Types.MessageStop | Agent_core.Types.Ping
      | Agent_core.Types.Connected | Agent_core.Types.MessageStart _
      | Agent_core.Types.ContentBlockDelta _ | Agent_core.Types.MessageDelta _
      | Agent_core.Types.SSEError _ | Agent_core.Types.NDJSONError _
      | Agent_core.Types.SSEParseFailed _ | Agent_core.Types.NDJSONParseFailed _
      | Agent_core.Types.SSEUnknownEventType _
      | Agent_core.Types.SSEUnsupportedPart _
      | Agent_core.Types.SSEUnsupportedResponse _ | Agent_core.Types.Timeout _
      | Agent_core.Types.StreamIncomplete _
      | Agent_core.Types.StreamRepeating _ ->
        entry.tools, activity_of_event preview event
    in
    let entry = { released_entry with tools } in
    match activity, text_changed with
    | None, false -> None
    | Some activity_preview, _ -> Some {entry with preparations=[];preview={activity_preview with
        text_tail=entry.preview.text_tail; text_position=entry.preview.text_position;preparation=None}}
    | None, true -> Some {entry with preparations=[];preview={entry.preview with preparation=None}})

let preparation_phase_name = function
  | Context_preparation -> "context"
  | Tool_preparation -> "tools"
  | Skill_preparation -> "skills"
;;

let preparation_outcome_name = function
  | Prepared -> "prepared" | Rejected -> "rejected" | Raised -> "raised" | Cancelled -> "cancelled"
;;

let preparation_to_json preparation =
  let state,finished_at,elapsed_ns = match preparation.state with
    | Preparation_active -> "active",`Null,`Null
    | Preparation_finished {outcome;finished_at;elapsed_ns} ->
      preparation_outcome_name outcome,`Float finished_at,`String (Int64.to_string elapsed_ns) in
  `Assoc ["phase",`String (preparation_phase_name preparation.phase);
    "turn_ref",Option.fold ~none:`Null ~some:Ids.Turn_ref.to_yojson preparation.turn_ref;
    "started_at_unix",`Float preparation.started_at;"state",`String state;
    "finished_at_unix",finished_at;"elapsed_ns",elapsed_ns]
;;

let status_text preview =
  let activity =
    match preview.preparation, preview.activity with
    | Some preparation, _ ->
      let phase = preparation_phase_name preparation.phase in
      (match preparation.state with
       | Preparation_active -> "preparing " ^ phase
       | Preparation_finished {outcome=Prepared;_} -> phase ^ " prepared; next activity unobserved"
       | Preparation_finished {outcome=(Rejected | Raised | Cancelled) as outcome;_} -> phase ^ " preparation " ^ preparation_outcome_name outcome)
    | None, Preparing -> "preparing turn"
    | None, Awaiting_response -> "waiting for provider response"
    | None, Receiving_response -> "receiving response"
    | None, Tool_observed -> "tool activity observed"
    | None, Failed -> "provider attempt failed"
  in
  String.concat " · "
    (List.filter_map Fun.id
       [ preview.runtime_id; Some activity
       ; Option.map (fun name -> "last observed tool: " ^ name) preview.last_tool
       ; Option.map (fun detail -> "last failure: " ^ detail) preview.last_failure ])

let to_json preview =
  `Assoc ["status_text", `String (status_text preview);
    "text_tail", `String preview.text_tail;
    "text_position", `Assoc ["generation", `Int preview.text_position.generation;
      "start_byte", `Int preview.text_position.start_byte];
    "last_tool", (match preview.last_tool with None -> `Null | Some name -> `String name);
    "updated_at_unix", `Float preview.updated_at;
    "preparation",Option.fold ~none:`Null ~some:preparation_to_json preview.preparation]
