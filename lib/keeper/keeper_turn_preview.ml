(** Ephemeral activity for the running Keeper turn. Created at Task entry or
    standalone agent entry;
    the turns route reads only the writer bound to its actual Owner slot.
    Provider attempts, stream events, and tool hooks write this projection. *)

type activity = Preparing | Awaiting_response | Receiving_response | Tool_observed | Failed

type preparation_phase = Task_preparation | World_preparation | Context_preparation | Prompt_preparation
  | Tool_preparation | Skill_preparation
  | Lane_inputs_preparation | Workspace_memory_preparation | Wiki_preparation
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

type preparation_scope_id = int

type preparation_span =
  { scope_id : preparation_scope_id
  ; parent_scope_id : preparation_scope_id option
  ; preparation : preparation
  }

module Preparation_scopes = Map.Make (Int)
type preparation_timeline = preparation_span Preparation_scopes.t
let empty_preparation_timeline = Preparation_scopes.empty
let preparation_spans timeline = List.map snd (Preparation_scopes.bindings timeline)
let preparation_timeline_is_empty = Preparation_scopes.is_empty

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
  ; preparation_timeline : preparation_timeline
  ; execution_scope : Keeper_execution_scope_id.t option
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
  ; preparations : (unit ref * preparation_span) list
  ; next_preparation_scope_id : int
  ; owner : Keeper_interrupt_token.t option
  ; original_turn_ref : Ids.Turn_ref.t option
  }
type writer = entry ref

let preparation_parent_key : (writer * preparation_scope_id) Eio.Fiber.key = Eio.Fiber.create_key ()

(* The displayed preview points at the latest installed writer. Callbacks
   retain their own writer and never look it up in this table. *)
let table : (string, writer) Hashtbl.t = Hashtbl.create 16

let mutex = Mutex.create ()

let with_lock f =
  Mutex.lock mutex;
  Fun.protect ~finally:(fun () -> Mutex.unlock mutex) f

let empty ~execution_scope now =
  { text_position = {generation=0; start_byte=0}; text_tail = ""; last_tool = None; updated_at = now
  ; runtime_id = None; activity = Preparing; last_failure = None; preparation = None; preparation_timeline = empty_preparation_timeline; execution_scope }

let current ~keeper_name =
  with_lock (fun () ->
    Option.map (fun writer -> (!writer).preview) (Hashtbl.find_opt table keeper_name))

let snapshot writer = with_lock (fun () -> (!writer).preview)

let current_for_turn ~keeper_name ~interrupt_token =
  with_lock (fun () ->
    match Hashtbl.find_opt table keeper_name with
    | Some writer when Option.exists (Keeper_interrupt_token.equal interrupt_token) (!writer).owner ->
      Some (!writer).preview
    | Some _ | None -> None)

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

let observe_preparation ~returned ~writer ~turn_ref ~phase operation =
  match writer with
  | None -> operation ()
  | Some owned_writer ->
    let token = ref () in
    let started = Mtime_clock.now () in
    let started_at = Time_compat.now () in
    let preparation = {phase;turn_ref;started_at;state=Preparation_active} in
    let parent_binding = match Fs_compat.execution_context () with
      | Fs_compat.Non_eio -> None
      | Eio_fiber -> Eio.Fiber.get preparation_parent_key in
    let span = with_lock (fun () ->
      let entry = !owned_writer in
      let scope_id = entry.next_preparation_scope_id in
      let parent_scope_id = match parent_binding with
        | Some (parent_writer,parent_id) when parent_writer == owned_writer
            && List.exists (fun (_,span) -> span.scope_id=parent_id) entry.preparations -> Some parent_id
        | Some _ | None -> None in
      let span = {scope_id;parent_scope_id;preparation} in
      owned_writer := {entry with
        next_preparation_scope_id=scope_id + 1;
        preparations=(token,span)::entry.preparations;
        preview={entry.preview with preparation=Some preparation;activity=Preparing;
          updated_at=started_at;
          preparation_timeline=Preparation_scopes.add scope_id span entry.preview.preparation_timeline}};
      span) in
    let finish outcome =
      let elapsed_ns = Mtime.Span.to_uint64_ns (Mtime.span started (Mtime_clock.now ())) in
      let finished_at = Time_compat.now () in
      let completed = {preparation with state=Preparation_finished {outcome;elapsed_ns;finished_at}} in
      with_lock (fun () ->
        let entry = !owned_writer in
        let timeline = Preparation_scopes.add span.scope_id
            {span with preparation=completed} entry.preview.preparation_timeline in
        let preview = {entry.preview with preparation_timeline=timeline} in
        if not (List.exists (fun (owner,_) -> owner == token) entry.preparations) then
          (* Keep the completed span without reopening a superseded live phase
             or advancing provider/Tool activity's own observation clock. *)
          owned_writer := {entry with preview}
        else
          let preparations = List.filter (fun (owner,_) -> owner != token) entry.preparations in
          let preparation = match preparations with
            | (_,parent)::_ -> parent.preparation
            | [] -> completed in
          owned_writer := {entry with preparations;
            preview={preview with preparation=Some preparation;updated_at=finished_at}})
    in
    let run () = match Fs_compat.execution_context () with
      | Fs_compat.Non_eio -> operation ()
      | Eio_fiber -> Eio.Fiber.with_binding preparation_parent_key (owned_writer,span.scope_id) operation in
    match run () with
    | result -> finish (returned result); result
    | exception error ->
      let backtrace = Printexc.get_raw_backtrace () in
      finish (match error with Eio.Cancel.Cancelled _ -> Cancelled | _ -> Raised);
      Printexc.raise_with_backtrace error backtrace
;;

let with_preparation_result ~writer ~turn_ref ~phase operation =
  observe_preparation ~returned:(function Ok _ -> Prepared | Error _ -> Rejected)
    ~writer ~turn_ref ~phase operation
;;

let with_preparation ~writer ~turn_ref ~phase operation =
  observe_preparation ~returned:(fun _ -> Prepared) ~writer ~turn_ref ~phase operation
;;

let redacting redaction =
  { redaction; stream = Keeper_stream_text_redaction.create redaction }

let reset ~keeper_name ~execution_scope ~turn_ref ~now ~redaction =
  let writer = ref { preview = empty ~execution_scope now; text_intake = redacting redaction;
    released_bytes = 0; tools = Tool_indexes.empty; preparations = []; next_preparation_scope_id = 0;
    owner = Keeper_turn_preview_owner.current (); original_turn_ref = turn_ref } in
  with_lock (fun () -> Hashtbl.replace table keeper_name writer);
  writer

let original_turn_ref writer = with_lock (fun () -> (!writer).original_turn_ref)

let note_attempt ~writer ~now ~runtime_id =
  change_entry ~writer ~now (fun { preview; text_intake; owner; original_turn_ref; next_preparation_scope_id; _ } ->
    Some
      { preview =
          { preview with runtime_id = Some runtime_id; activity = Awaiting_response
          ; last_tool = None; text_tail = ""; preparation = None
          ; text_position = {generation=preview.text_position.generation + 1; start_byte=0} }
        (* A new attempt is a new provider stream. Text the previous stream
           still held belongs to the tail this clears. *)
      ; tools = Tool_indexes.empty
      ; preparations = []
      ; owner
      ; original_turn_ref
      ; next_preparation_scope_id
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
  | Agent_core.Types.ResponsesOutputItems _ | Agent_core.Types.Ping | Agent_core.Types.Connected | Agent_core.Types.ContentBlockStop _
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
      | Agent_core.Types.MessageStop | Agent_core.Types.ResponsesOutputItems _ | Agent_core.Types.Ping | Agent_core.Types.Connected
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
      | Agent_core.Types.MessageStop | Agent_core.Types.ResponsesOutputItems _ | Agent_core.Types.Ping
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
  | Task_preparation -> "task"
  | World_preparation -> "world"
  | Context_preparation -> "context"
  | Prompt_preparation -> "prompt"
  | Tool_preparation -> "tools"
  | Skill_preparation -> "skills"
  | Lane_inputs_preparation -> "lane_inputs"
  | Workspace_memory_preparation -> "workspace_memory"
  | Wiki_preparation -> "wiki"
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

let preparation_of_json json =
  let ( let* ) = Result.bind in
  let* fields = match json with
    | `Assoc fields when List.sort String.compare (List.map fst fields) =
        List.sort String.compare ["phase";"turn_ref";"started_at_unix";"state";"finished_at_unix";"elapsed_ns"] ->
      Ok fields
    | _ -> Error "preparation requires exactly its phase, identity, state and clock fields" in
  let field key = List.assoc key fields in
  let time key = match field key with
    | `Float value when Float.is_finite value -> Ok value
    | `Int value -> Ok (float_of_int value)
    | _ -> Error ("preparation " ^ key ^ " must be a finite number") in
  let* phase = match field "phase" with
    | `String "task" -> Ok Task_preparation
    | `String "world" -> Ok World_preparation
    | `String "context" -> Ok Context_preparation
    | `String "prompt" -> Ok Prompt_preparation
    | `String "tools" -> Ok Tool_preparation
    | `String "skills" -> Ok Skill_preparation
    | `String "lane_inputs" -> Ok Lane_inputs_preparation
    | `String "workspace_memory" -> Ok Workspace_memory_preparation
    | `String "wiki" -> Ok Wiki_preparation
    | _ -> Error "unknown preparation phase" in
  let* turn_ref = match field "turn_ref" with
    | `Null -> Ok None
    | `String raw -> (match Ids.Turn_ref.of_string raw with
        | Some value -> Ok (Some value) | None -> Error "invalid preparation turn_ref")
    | _ -> Error "preparation turn_ref must be text or null" in
  let* started_at = time "started_at_unix" in
  let* state = match field "state",field "elapsed_ns",field "finished_at_unix" with
    | `String "active",`Null,`Null -> Ok Preparation_active
    | `String state,`String raw,_ ->
      let* outcome = match state with
        | "prepared" -> Ok Prepared | "rejected" -> Ok Rejected
        | "raised" -> Ok Raised | "cancelled" -> Ok Cancelled
        | _ -> Error "unknown settled preparation state" in
      let* elapsed_ns = match Int64.of_string_opt raw with
        | Some value when value >= 0L -> Ok value
        | Some _ | None -> Error "preparation elapsed_ns must be nonnegative int64 text" in
      let* finished_at = time "finished_at_unix" in
      Ok (Preparation_finished {outcome;elapsed_ns;finished_at})
    | _ -> Error "preparation state has incomplete or conflicting clocks" in
  Ok {phase;turn_ref;started_at;state}
;;

let preparation_span_to_json span =
  `Assoc ["scope_id",`Int span.scope_id;
    "parent_scope_id",Option.fold ~none:`Null ~some:(fun id -> `Int id) span.parent_scope_id;
    "preparation",preparation_to_json span.preparation]
;;

let preparation_timeline_to_json timeline =
  `List (List.map preparation_span_to_json (preparation_spans timeline))
;;

let preparation_timeline_of_json json =
  let ( let* ) = Result.bind in
  let scope_id = function
    | `Int value when value >= 0 -> Ok value
    | _ -> Error "preparation scope ID must be a nonnegative integer" in
  let rec decode previous timeline = function
    | [] -> Ok timeline
    | `Assoc fields :: remaining when List.sort String.compare (List.map fst fields) =
        ["parent_scope_id";"preparation";"scope_id"] ->
      let* id = scope_id (List.assoc "scope_id" fields) in
      let* () = match previous with
        | Some previous when id <= previous -> Error "preparation scopes must have unique increasing IDs"
        | Some _ | None -> Ok () in
      let* parent_scope_id = match List.assoc "parent_scope_id" fields with
        | `Null -> Ok None
        | value -> let* parent = scope_id value in
          if Preparation_scopes.mem parent timeline then Ok (Some parent)
          else Error "preparation parent must be an earlier existing scope" in
      let* preparation = preparation_of_json (List.assoc "preparation" fields) in
      let span = {scope_id=id;parent_scope_id;preparation} in
      decode (Some id) (Preparation_scopes.add id span timeline) remaining
    | _ -> Error "preparation span requires exactly scope_id, parent_scope_id and preparation" in
  match json with
  | `List spans -> decode None empty_preparation_timeline spans
  | _ -> Error "preparation timeline must be an array"
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

let activity_to_json = function
  | Preparing -> `String "preparing"
  | Awaiting_response -> `String "waiting"
  | Receiving_response -> `String "streaming"
  | Tool_observed -> `String "tool"
  | Failed -> `String "failed"

let to_json ?(include_preparation_timeline = false) preview =
  `Assoc ["status_text", `String (status_text preview);
    "activity", activity_to_json preview.activity;
    "text_tail", `String preview.text_tail;
    "text_position", `Assoc ["generation", `Int preview.text_position.generation;
      "start_byte", `Int preview.text_position.start_byte];
    "last_tool", (match preview.last_tool with None -> `Null | Some name -> `String name);
    "updated_at_unix", `Float preview.updated_at;
    "preparation",Option.fold ~none:`Null ~some:preparation_to_json preview.preparation;
    "preparation_timeline",(if include_preparation_timeline then
      preparation_timeline_to_json preview.preparation_timeline else `Null);
    "execution_scope",Option.fold ~none:`Null ~some:Keeper_execution_scope_id.to_json preview.execution_scope]
