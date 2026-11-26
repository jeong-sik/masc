(** Ephemeral activity for the running Keeper turn. Created at Task entry or
    standalone agent entry;
    the turns route reads only the writer bound to its actual Owner slot.
    Provider attempts, stream events, and tool hooks write this projection. *)

type activity = Preparing | Awaiting_response | Receiving_response | Tool_observed | Failed

type response_channel = No_content | Thinking | Text

type tool_stage = Tool_requested | Tool_executing

type open_response = { channel : response_channel; started_at : float; since : float }

type open_tool =
  { tool_use_id : string option
  ; tool_name : string
  ; stage : tool_stage
  ; started_at : float
  ; since : float
  }

(** Work that began in the running turn and has not ended. An event is a point
    ("a tool was called"); an open activity lasts from its start to its end.
    [started_at] is when the work began. [since] is when its channel or stage
    last changed, and does not move while content keeps arriving. *)
type open_activity =
  | Response_open of open_response
  | Tool_open of open_tool

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

type work_context = { task_id : string option; start_reasons : string list }

type t =
  { text_position : source_position
  ; text_tail : string
  ; last_tool : string option
  ; updated_at : float
  ; revision : int
  ; runtime_id : string option
  ; activity : activity
  ; open_activities : open_activity list
  ; attempt_failed : bool
  ; last_failure : string option
  ; preparation : preparation option
  ; preparation_timeline : preparation_timeline
  ; execution_scope : Keeper_execution_scope_id.t option
  ; work_context : work_context option
  }

(* The one place that says what the turn is doing. It reads what is open, so
   no writer sets [activity] on its own and two sources cannot disagree. *)
let activity_of_head = function
  | Tool_open _ -> Tool_observed
  | Response_open { channel = No_content; _ } -> Awaiting_response
  | Response_open { channel = Thinking; _ } | Response_open { channel = Text; _ } ->
      Receiving_response

let activity_of (preview : t) =
  match preview.preparation with
  | Some _ -> Preparing
  | None -> (
      if List.exists (function Tool_open _ -> true | Response_open _ -> false)
           preview.open_activities
      then Tool_observed
      else
        match preview.open_activities with
        | [] -> if preview.attempt_failed then Failed else Awaiting_response
        | first :: _ -> activity_of_head first)

let open_response ~channel ~now = { channel; started_at = now; since = now }

(* [drop] hands back the list itself when nothing matches, so a write can
   tell that nothing changed and keep its revision. *)
let drop (f : open_activity -> bool) work =
  if List.exists f work then List.filter (fun activity -> not (f activity)) work
  else work

(* Applies [f] to the first activity it accepts. The result is the same list
   when [f] accepted none or asked for no change. *)
let change_first (f : open_activity -> open_activity option) work =
  let rec loop before = function
    | [] -> work
    | activity :: rest ->
        (match f activity with
         | Some changed when changed == activity -> work
         | Some changed -> List.rev_append before (changed :: rest)
         | None -> loop (activity :: before) rest)
  in
  loop [] work

(* Removes the first activity [f] accepts. The result is the same list when
   [f] accepts none. *)
let remove_first (f : open_activity -> bool) work =
  let rec loop before = function
    | [] -> work
    | activity :: rest when f activity -> List.rev_append before rest
    | activity :: rest -> loop (activity :: before) rest
  in
  loop [] work

(* The response stays at the head of the list: every path puts it there. *)
let note_channel ~now channel work =
  match work with
  | Response_open response :: rest when response.channel <> channel ->
      Response_open { response with channel; since = now } :: rest
  | Response_open _ :: _ -> work
  | Tool_open _ :: _ | [] -> Response_open (open_response ~channel ~now) :: work

(* A stream tool block and the tool hooks of one call carry the same id. When
   the stream had no id, the name tells the calls apart. *)
let same_tool ~tool_use_id ~tool_name (tool : open_tool) =
  match tool_use_id, tool.tool_use_id with
  | Some wanted, Some have -> String.equal wanted have
  | Some _, None | None, Some _ | None, None -> String.equal tool_name tool.tool_name

let open_tool_of ~tool_use_id ~tool_name work =
  match
    List.find_opt
      (function
        | Tool_open tool -> same_tool ~tool_use_id ~tool_name tool
        | Response_open _ -> false)
      work
  with
  | Some (Tool_open tool) -> Some tool
  | Some (Response_open _) | None -> None

(* The model started calling the tool. Nothing says it runs yet. *)
let tool_requested ~now ~tool_use_id ~tool_name work =
  match open_tool_of ~tool_use_id ~tool_name work with
  | Some _ -> work
  | None ->
      work @ [ Tool_open { tool_use_id; tool_name; stage = Tool_requested; started_at = now; since = now } ]

(* The before-tool hook runs once the gates before it said yes, so this is
   where execution starts. Hearing it twice for one call changes nothing. *)
let has_tool_id id (tool : open_tool) =
  Option.equal String.equal (Some id) tool.tool_use_id

let tool_executing ~now ~tool_use_id ~tool_name work =
  let already_started id =
    List.exists
      (function
        | Tool_open ({ stage = Tool_executing; _ } as tool) -> has_tool_id id tool
        | Tool_open { stage = Tool_requested; _ } | Response_open _ -> false)
      work
  in
  let promote accepts =
    change_first
      (function
        | Tool_open ({ stage = Tool_requested; _ } as current) when accepts current ->
            let tool_use_id =
              match tool_use_id with Some _ -> tool_use_id | None -> current.tool_use_id
            in
            Some (Tool_open { current with tool_use_id; stage = Tool_executing; since = now })
        | Tool_open { stage = Tool_requested; _ }
        | Tool_open { stage = Tool_executing; _ }
        | Response_open _ -> None)
      work
  in
  let by_name (tool : open_tool) = String.equal tool_name tool.tool_name in
  match tool_use_id with
  | Some id when already_started id -> work
  | Some _ | None ->
      let promoted =
        match tool_use_id with
        | None -> promote by_name
        | Some id ->
            let exact = promote (has_tool_id id) in
            if exact != work then exact
            else promote (fun tool -> Option.is_none tool.tool_use_id && by_name tool)
      in
      if promoted != work then promoted
      else
        (* The stream never showed this call, so the hook is the first word of it. *)
        work @ [ Tool_open { tool_use_id; tool_name; stage = Tool_executing; started_at = now; since = now } ]

(* Match an identified return before trying the oldest anonymous call. *)
let tool_ended ~tool_use_id ~tool_name work =
  let end_first accepts =
    remove_first (function Tool_open tool -> accepts tool | Response_open _ -> false) work
  in
  match tool_use_id with
  | None -> end_first (same_tool ~tool_use_id ~tool_name)
  | Some id ->
      let exact = end_first (has_tool_id id) in
      if exact != work then exact
      else end_first (same_tool ~tool_use_id ~tool_name)

(* The host is running a call, so the model's message that called it is over.
   An official client's turn is one long message boundary around many model
   messages, so nothing else says where each of them ends. A call that was
   already running hands the list back itself, and then nothing closes: words
   that arrived meanwhile belong to a response opened after the call started. *)
let tool_running ~now ~tool_use_id ~tool_name work =
  let moved = tool_executing ~now ~tool_use_id ~tool_name work in
  if moved == work then work
  else drop (function Response_open _ -> true | Tool_open _ -> false) moved

(* The result goes back to the model, so the next response is what the turn
   waits on from here. Only an official client's turn needs this: it announces
   a model message's boundaries once per turn, so nothing else says when the
   next one began. The agent loop announces its next request itself, and that
   request's clock starts there. The response opens only when a call really
   ended here ([work] is not [before]) and nothing else is left: a call still
   running is what the turn waits on, and a response that opened while the
   call ran is the one to keep. *)
let response_after_return ~now ~loop before work =
  if work != before then
    match loop with
    | Some Runtime_execution.Official_client -> (
        match work with
        | [] -> [ Response_open (open_response ~channel:No_content ~now) ]
        | Tool_open _ :: _ | Response_open _ :: _ -> work)
    | Some Runtime_execution.Masc_agent_core | None -> work
  else work

(* A native block is the official client's own run: it opens as running with
   its own clock, after the message that called it is over. The run's entry
   is handed back so the block table keeps it: its stop ends that run and no
   other of the same name. *)
let native_started ~now ~tool_use_id ~tool_name work =
  let run = { tool_use_id; tool_name; stage = Tool_executing; started_at = now; since = now } in
  let work = drop (function Response_open _ -> true | Tool_open _ -> false) work in
  (work @ [ Tool_open run ], run)

(* Ends one run, the one the block table kept. Two runs that look the same
   (one name, no id, one clock) are still two runs: each block ends its own. *)
let ended_run run work =
  remove_first (function Tool_open tool -> tool = run | Response_open _ -> false) work

(* Ends the MASC call a tool block named, however far it got: in an official
   client's attempt the block is the host's whole call. *)
let call_ended_with_block ~tool_use_id ~tool_name work =
  remove_first
    (function
      | Tool_open call -> same_tool ~tool_use_id ~tool_name call
      | Response_open _ -> false)
    work

(* A MASC tool block stopped in an official client's attempt. When the call
   was still open, the hooks did not end it: a gate settled it without a run.
   The message that called it is over as well, so the response under the call
   ends too and the next one is counted from here. *)
let block_stopped ~tool_use_id ~tool_name before =
  let ended = call_ended_with_block ~tool_use_id ~tool_name before in
  if ended == before then ended
  else drop (function Response_open _ -> true | Tool_open _ -> false) ended

(* What one provider event changes in the open work. A native block's start
   and stop are settled in [note_stream], which knows the block table. *)
let open_of_event ~now (preview : t) (event : Agent_core.Types.sse_event) =
  let work = preview.open_activities in
  match event with
  | Agent_core.Types.MessageStart _ ->
      (match work with
       | Response_open _ :: _ -> work
       | Tool_open _ :: _ | [] ->
           Response_open (open_response ~channel:No_content ~now) :: work)
  | Agent_core.Types.ContentBlockDelta { delta = TextDelta _; _ } ->
      note_channel ~now Text work
  | ContentBlockDelta { delta = TextSnapshot text; _ }
    when not (String.equal (String.trim text) "") ->
      note_channel ~now Text work
  | ContentBlockDelta { delta = (ThinkingDelta _ | ThinkingSnapshot _) | ReasoningDetailsDelta _; _ } ->
      note_channel ~now Thinking work
  | ContentBlockStart { tool_id; tool_name = Some tool_name; _ } ->
      tool_requested ~now ~tool_use_id:tool_id ~tool_name work
  | Agent_core.Types.MessageStop ->
      (* The response ended. A call the model made in it stays open until the
         before-tool hook moves it on, or the next provider request ends it:
         every earlier call settles before a new request goes out. *)
      drop (function Response_open _ -> true | Tool_open _ -> false) work
  | Agent_core.Types.ContentBlockStart { tool_name = None; _ }
  | Agent_core.Types.ContentBlockStop _
  | Agent_core.Types.ContentBlockDelta
      { delta =
          ( Agent_core.Types.ThinkingSignatureDelta _
          | Agent_core.Types.RedactedThinkingSnapshot _
          | Agent_core.Types.InputJsonDelta _
          | Agent_core.Types.InputJsonSnapshot _
          | Agent_core.Types.MediaDelta _ ); _ }
  | ContentBlockDelta { delta = TextSnapshot _; _ }
  | Agent_core.Types.MessageDelta _ | Agent_core.Types.SSEError _
  | Agent_core.Types.NDJSONError _ | Agent_core.Types.SSEParseFailed _
  | Agent_core.Types.NDJSONParseFailed _ | Agent_core.Types.SSEUnknownEventType _
  | Agent_core.Types.SSEUnsupportedPart _ | Agent_core.Types.SSEUnsupportedResponse _
  | Agent_core.Types.Timeout _ | Agent_core.Types.StreamIncomplete _
  | Agent_core.Types.InlineContentReplay _ | Agent_core.Types.ResponsesOutputItems _
  | Agent_core.Types.Ping | Agent_core.Types.Connected -> work

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

(* What the stream said about a tool block it opened. A model's call of a MASC
   tool is a "tool_use" block: in the agent loop it ends when the model
   finishes the call and says nothing about the run. A native block is the
   official client running its own tool: it ends when that run ends, and no
   tool hook comes for it. [run] is that run's open activity, for a native
   block. [tool_use_id] names a MASC call at its stop when the stream gave one. *)
type tool_block =
  { tool_name : string
  ; tool_use_id : string option
  ; native_run : bool
  ; run : open_tool option
  }

(* The workspace and Keeper whose turns answer can show this writer. *)
type shown_as = { base_path : string; keeper_name : string }

type entry =
  { preview : t
  ; text_intake : text_intake
  ; released_bytes : int
  ; tools : tool_block Tool_indexes.t
  ; preparations : (unit ref * preparation_span) list
  ; next_preparation_scope_id : int
  ; owner : Keeper_interrupt_token.t option
  ; original_turn_ref : Ids.Turn_ref.t option
  ; shown_as : shown_as
  ; loop : Runtime_execution.checkpoint_owner option
    (** Which loop runs the attempt, [None] until its first one. An official
        client's tool block wraps the host's whole call, and it announces a
        model message's boundaries once per turn. The agent loop's tool block
        is only the model's call, and it announces every request. *)
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

(* The same lock orders reads and writes, even when a writer is replaced. *)
let revision = ref 0

let next_revision () =
  incr revision;
  !revision

(* Under the lock: whether the turns answer can read [writer]. It reads the
   installed writer only, and only for the Owner slot that owns it
   ([current_for_turn]), so a writer installed without an owner shows
   nothing. *)
let displayed writer =
  match Hashtbl.find_opt table (!writer).shown_as.keeper_name with
  | Some shown -> shown == writer && Option.is_some (!writer).owner
  | None -> false

(* After the lock, for a write [displayed] saw. *)
let announce = function
  | Some { base_path; keeper_name } -> Keeper_turn_preview_signal.changed ~base_path ~keeper_name
  | None -> ()

let shown_after_write writer = if displayed writer then Some (!writer).shown_as else None

let empty ~execution_scope ~revision now =
  { text_position = {generation=0; start_byte=0}; text_tail = ""; last_tool = None; updated_at = now; revision
  ; runtime_id = None; activity = Preparing; open_activities = []; attempt_failed = false
  ; last_failure = None; preparation = None; preparation_timeline = empty_preparation_timeline; execution_scope; work_context = None }

let note_work_context ~writer work_context =
  announce (with_lock (fun () ->
    let entry = !writer in
    writer :=
      { entry with
        preview =
          { entry.preview with
            work_context = Some work_context
          ; revision = next_revision ()
          }
      };
    shown_after_write writer))

let current ~keeper_name =
  with_lock (fun () ->
    Option.map (fun writer -> (!writer).preview) (Hashtbl.find_opt table keeper_name))

let snapshot writer = with_lock (fun () -> (!writer).preview)

let current_for_turn_with_revision ~keeper_name ~interrupt_token =
  with_lock (fun () ->
    let preview =
      match Hashtbl.find_opt table keeper_name with
      | Some writer when Option.exists (Keeper_interrupt_token.equal interrupt_token) (!writer).owner ->
        Some (!writer).preview
      | Some _ | None -> None
    in
    let observed_through =
      match preview with Some snapshot -> snapshot.revision | None -> !revision
    in
    observed_through, preview)

let current_for_turn ~keeper_name ~interrupt_token =
  snd (current_for_turn_with_revision ~keeper_name ~interrupt_token)

(* [f] returns [None] when the note changes nothing, which leaves
   [updated_at] where it was. Every write takes its [activity] from what is
   open, so no writer can leave the two apart. *)
let change_entry ~writer ~now f =
  Option.iter (fun writer ->
    announce
      (with_lock (fun () ->
         match f !writer with
         | None -> None
         | Some entry ->
           let preview = entry.preview in
           writer :=
             { entry with
               preview =
                 { preview with
                   updated_at = now
                 ; revision = next_revision ()
                 ; activity = activity_of preview
                 }
             };
           shown_after_write writer))) writer

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
    let span, shown = with_lock (fun () ->
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
          updated_at=started_at; revision = next_revision ();
          preparation_timeline=Preparation_scopes.add scope_id span entry.preview.preparation_timeline}};
      span, shown_after_write owned_writer) in
    announce shown;
    let finish outcome =
      let elapsed_ns = Mtime.Span.to_uint64_ns (Mtime.span started (Mtime_clock.now ())) in
      let finished_at = Time_compat.now () in
      let completed = {preparation with state=Preparation_finished {outcome;elapsed_ns;finished_at}} in
      announce @@ with_lock (fun () ->
        let entry = !owned_writer in
        let timeline = Preparation_scopes.add span.scope_id
            {span with preparation=completed} entry.preview.preparation_timeline in
        let preview = {entry.preview with preparation_timeline=timeline; revision = next_revision ()} in
        if not (List.exists (fun (owner,_) -> owner == token) entry.preparations) then
          (* Keep the completed span without reopening a superseded live phase
             or advancing provider/Tool activity's own observation clock. *)
          owned_writer := {entry with preview}
        else begin
          let preparations = List.filter (fun (owner,_) -> owner != token) entry.preparations in
          let preparation = match preparations with
            | (_,parent)::_ -> parent.preparation
            | [] -> completed in
          owned_writer := {entry with preparations;
            preview={preview with preparation=Some preparation;updated_at=finished_at}}
        end;
        shown_after_write owned_writer)
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

let reset ~base_path ~keeper_name ~execution_scope ~turn_ref ~now ~redaction =
  let shown_as = { base_path; keeper_name } in
  let text_intake = redacting redaction in
  let owner = Keeper_turn_preview_owner.current () in
  let writer, shown =
    with_lock (fun () ->
      let preview = empty ~execution_scope ~revision:(next_revision ()) now in
      let writer = ref { preview; text_intake; released_bytes = 0;
        tools = Tool_indexes.empty; preparations = []; next_preparation_scope_id = 0;
        owner; original_turn_ref = turn_ref; shown_as; loop = None } in
      Hashtbl.replace table keeper_name writer;
      writer, shown_after_write writer)
  in
  announce shown;
  writer

let original_turn_ref writer = with_lock (fun () -> (!writer).original_turn_ref)

let note_attempt ~writer ~now ~runtime_id ~checkpoint_owner =
  change_entry ~writer ~now (fun { preview; text_intake; owner; original_turn_ref; next_preparation_scope_id; shown_as; _ } ->
    Some
      { preview =
          { preview with runtime_id = Some runtime_id
          ; last_tool = None; text_tail = ""; preparation = None
          ; open_activities = []; attempt_failed = false
          ; text_position = {generation=preview.text_position.generation + 1; start_byte=0} }
        (* A new attempt is a new provider stream. Text the previous stream
           still held belongs to the tail this clears, and any work it left
           open ended with it. *)
      ; tools = Tool_indexes.empty
      ; preparations = []
      ; owner
      ; original_turn_ref
      ; next_preparation_scope_id
      ; shown_as
      ; loop = Some checkpoint_owner
      ; released_bytes = 0
      ; text_intake =
          redacting text_intake.redaction
      })

let note_failure ~writer ~now ~runtime_id detail =
  Option.iter (fun writer ->
    let redaction =
      with_lock (fun () -> (!writer).text_intake.redaction)
      |> Keeper_secret_redaction.copy_for_current_domain
    in
    let detail =
      Keeper_secret_redaction.redact_text redaction detail
      |> Observability_redact.redact_preview ~max_len:tail_bytes
    in
    update ~writer:(Some writer) ~now (fun old ->
      { old with runtime_id = Some runtime_id
      ; last_tool = None; last_failure = Some detail
      ; open_activities = []; attempt_failed = true })) writer

(* [after_turn] calls this with the whole visible text of the model's turn, so
   plain redaction sees every secret in it whole before the tail is cut. The
   model's turn is over by then, so the response ends here even when the turn
   showed no text. *)
let note_text ~writer ~now text =
  let text = String.trim text in
  change_entry ~writer ~now (fun ({ preview; text_intake; _ } as entry) ->
    let open_activities =
      drop (function Response_open _ -> true | Tool_open _ -> false) preview.open_activities in
    if String.equal text "" then
      (* Blank text keeps the last visible words: a tool-only turn must not
         erase them. *)
      if open_activities == preview.open_activities then None
      else Some { entry with preparations=[]; preview={preview with preparation=None; open_activities} }
    else
      let text = Keeper_secret_redaction.redact_text text_intake.redaction text in
      let text_tail = String_util.utf8_suffix ~max_bytes:tail_bytes text in
      let released_bytes = String.length text in
      let text_position = {generation=preview.text_position.generation + 1;
        start_byte=released_bytes - String.length text_tail} in
      Some { entry with released_bytes; text_intake=redacting text_intake.redaction;
        preparations=[];
        preview={preview with text_tail; text_position; preparation=None; open_activities} })


(* The before-tool hook. It runs once the gates before it said yes. *)
let note_tool_started ~writer ~now ~tool_use_id ~tool_name =
  update ~writer ~now (fun old ->
    { old with last_tool = Some tool_name
    ; open_activities = tool_running ~now ~tool_use_id ~tool_name old.open_activities })

(* The after-tool hook, for a result and for a failure alike. *)
let note_tool_finished ~writer ~now ~tool_use_id ~tool_name =
  change_entry ~writer ~now (fun ({ preview; _ } as entry) ->
    let before = preview.open_activities in
    Some
      { entry with preparations = []
      ; preview =
          { preview with
              last_tool = Some tool_name
            ; open_activities =
                response_after_return ~now ~loop:entry.loop before
                  (tool_ended ~tool_use_id ~tool_name before)
            ; preparation = None } })

(* The run of this turn is over at a tool boundary: the loop yields there and
   no later model response or turn text comes to close what the last tool
   return opened. *)
let note_turn_over ~writer ~now =
  update ~writer ~now (fun old -> { old with open_activities = [] })

let note_request ~writer ~now =
  update ~writer ~now (fun old ->
    let work =
      drop (function Tool_open _ -> true | Response_open _ -> false) old.open_activities in
    { old with
        open_activities =
          Response_open (open_response ~channel:No_content ~now)
          :: drop (function Response_open _ -> true | Tool_open _ -> false) work
    ; attempt_failed = false })

(* Positions count only bytes actually emitted by this writer's redactor.
   A replacement starts a new source generation, even if its text repeats. *)
let released_text entry events =
  List.fold_left (fun (entry, changed) (event : Agent_core.Types.sse_event) ->
    let replace, text = match event with
      | ContentBlockDelta {delta=TextDelta text; _} -> false, Some text
      | ContentBlockDelta {delta=TextSnapshot text; _} ->
          true, Some (String.trim text)
      | Agent_core.Types.ContentBlockDelta { delta = ((Agent_core.Types.ThinkingDelta _ | Agent_core.Types.ThinkingSnapshot _) | (Agent_core.Types.ThinkingSignatureDelta _ | (Agent_core.Types.RedactedThinkingSnapshot _ | (Agent_core.Types.ReasoningDetailsDelta _ | (Agent_core.Types.InputJsonDelta _ | (Agent_core.Types.InputJsonSnapshot _ | Agent_core.Types.MediaDelta _))))));_}
      | Agent_core.Types.MessageStop | Agent_core.Types.InlineContentReplay _ | Agent_core.Types.ResponsesOutputItems _ | Agent_core.Types.Ping | Agent_core.Types.Connected
      | Agent_core.Types.MessageStart _ | Agent_core.Types.ContentBlockStart _
      | Agent_core.Types.ContentBlockStop _ | Agent_core.Types.MessageDelta _
      | Agent_core.Types.SSEError _ | Agent_core.Types.NDJSONError _
      | Agent_core.Types.SSEParseFailed _ | Agent_core.Types.NDJSONParseFailed _
      | Agent_core.Types.SSEUnknownEventType _ | Agent_core.Types.SSEUnsupportedPart _
      | Agent_core.Types.SSEUnsupportedResponse _ | Agent_core.Types.Timeout _
      | Agent_core.Types.StreamIncomplete _ -> false, None in
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
   part of it reaches the tail. The same event says what opened, moved or
   ended in the turn's work. *)
let note_stream ~writer ~now event =
  change_entry ~writer ~now (fun ({ preview; text_intake; _ } as entry) ->
    let released_entry, text_changed =
      released_text entry
        (Keeper_stream_text_redaction.on_event text_intake.stream event)
    in
    let is_native_block index =
      match Tool_indexes.find_opt index entry.tools with
      | Some block -> block.native_run
      | None -> false
    in
    let tools, last_tool, open_activities =
      match event with
      | Agent_core.Types.ContentBlockStart { index; content_type; tool_id; tool_name = Some tool_name; _ }
        when String.equal content_type Runtime_native_tools.stream_content_type -> (
          (* The client's own run starts with its block. A start heard again
             for a block that is still open says nothing new: Antigravity
             announces an active step more than once under one index. *)
          match Tool_indexes.find_opt index entry.tools with
          | Some { native_run = true; _ } -> entry.tools, preview.last_tool, preview.open_activities
          | Some _ | None ->
              let open_activities, run =
                native_started ~now ~tool_use_id:tool_id ~tool_name preview.open_activities in
              ( Tool_indexes.add index
                  { tool_name; tool_use_id = tool_id; native_run = true; run = Some run }
                  entry.tools
              , Some tool_name
              , open_activities ))
      | ContentBlockStop { index } when is_native_block index ->
          (* The client's own run ends with its block. *)
          let block = Tool_indexes.find index entry.tools in
          let ended =
            match block.run with
            | Some run -> ended_run run preview.open_activities
            | None -> preview.open_activities
          in
          ( Tool_indexes.remove index entry.tools
          , Some block.tool_name
          , response_after_return ~now ~loop:entry.loop preview.open_activities ended )
      | Agent_core.Types.ContentBlockStart { index; tool_id; tool_name = Some tool_name; _ } ->
          (* The model started calling a MASC tool. *)
          ( Tool_indexes.add index
              { tool_name; tool_use_id = tool_id; native_run = false; run = None }
              entry.tools
          , Some tool_name
          , open_of_event ~now preview event )
      | ContentBlockStop { index } ->
          (* The call the model finished making is the latest one the turn
             made, so it is the last observed tool. In an official client's
             attempt the block is the host's whole call, so the call ended
             here. In the agent loop the block is only the model's call: the
             gates before the run may still be holding it. *)
          let stopped, ended =
            match Tool_indexes.find_opt index entry.tools with
            | Some block ->
                let ended =
                  match entry.loop with
                  | Some Runtime_execution.Official_client ->
                      block_stopped
                        ~tool_use_id:block.tool_use_id
                        ~tool_name:block.tool_name
                        preview.open_activities
                  | Some Runtime_execution.Masc_agent_core | None -> preview.open_activities
                in
                Some block.tool_name, ended
            | None -> preview.last_tool, preview.open_activities
          in
          ( Tool_indexes.remove index entry.tools
          , stopped
          , response_after_return ~now ~loop:entry.loop preview.open_activities ended )
      | Agent_core.Types.ContentBlockStart _
      | Agent_core.Types.MessageStop | Agent_core.Types.InlineContentReplay _ | Agent_core.Types.ResponsesOutputItems _ | Agent_core.Types.Ping
      | Agent_core.Types.Connected | Agent_core.Types.MessageStart _
      | Agent_core.Types.ContentBlockDelta _ | Agent_core.Types.MessageDelta _
      | Agent_core.Types.SSEError _ | Agent_core.Types.NDJSONError _
      | Agent_core.Types.SSEParseFailed _ | Agent_core.Types.NDJSONParseFailed _
      | Agent_core.Types.SSEUnknownEventType _
      | Agent_core.Types.SSEUnsupportedPart _
      | Agent_core.Types.SSEUnsupportedResponse _ | Agent_core.Types.Timeout _
      | Agent_core.Types.StreamIncomplete _ -> entry.tools, preview.last_tool, open_of_event ~now preview event
    in
    let open_changed = not (open_activities == preview.open_activities) in
    let tool_changed = not (Option.equal String.equal last_tool preview.last_tool) in
    if (not open_changed) && (not text_changed) && (not tool_changed) then None
    else
      Some
        { released_entry with tools; preparations = [];
          preview =
            { preview with
                last_tool
              ; open_activities
              ; preparation = None
              ; text_tail = released_entry.preview.text_tail
              ; text_position = released_entry.preview.text_position } })

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
  let open Result.Syntax in
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
  let open Result.Syntax in
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

(* What is open comes first. [last observed tool] stays a fact about the turn,
   not a claim that the tool runs. *)
let open_activity_text = function
  | Response_open { channel = No_content; _ } -> "waiting for provider response"
  | Response_open { channel = Thinking; _ } -> "receiving reasoning"
  | Response_open { channel = Text; _ } -> "receiving response"
  | Tool_open { tool_name; stage = Tool_requested; _ } -> "tool called: " ^ tool_name
  | Tool_open { tool_name; stage = Tool_executing; _ } -> "tool running: " ^ tool_name

let status_text preview =
  let activity =
    match preview.preparation with
    | Some preparation ->
        let phase = preparation_phase_name preparation.phase in
        (match preparation.state with
         | Preparation_active -> "preparing " ^ phase
         | Preparation_finished {outcome=Prepared;_} -> phase ^ " prepared; next activity unobserved"
         | Preparation_finished {outcome=(Rejected | Raised | Cancelled) as outcome;_} -> phase ^ " preparation " ^ preparation_outcome_name outcome)
    | None when preview.activity = Preparing -> "preparing turn"
    | None -> (
        match preview.open_activities with
        | [] ->
            if preview.attempt_failed then "provider attempt failed"
            else "waiting for provider response"
        | first :: rest -> String.concat " · " (List.map open_activity_text (first :: rest)))
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

let open_activity_to_json = function
  | Response_open { channel; started_at; since } ->
    let channel =
      match channel with
      | No_content -> "none" | Thinking -> "thinking" | Text -> "text"
    in
    `Assoc
      [ "kind", `String "response"
      ; "channel", `String channel
      ; "started_at_unix", `Float started_at
      ; "since_unix", `Float since
      ]
  | Tool_open { tool_use_id; tool_name; stage; started_at; since } ->
    let stage = match stage with Tool_requested -> "requested" | Tool_executing -> "executing" in
    `Assoc
      [ "kind", `String "tool"
      ; "tool_use_id", Option.fold ~none:`Null ~some:(fun id -> `String id) tool_use_id
      ; "name", `String tool_name
      ; "stage", `String stage
      ; "started_at_unix", `Float started_at
      ; "since_unix", `Float since
      ]

let work_context_to_json { task_id; start_reasons } =
  `Assoc
    [ "task_id", Option.fold ~none:`Null ~some:(fun id -> `String id) task_id
    ; "start_reasons", `List (List.map (fun reason -> `String reason) start_reasons)
    ]

let to_json ?(include_preparation_timeline = false) preview =
  `Assoc ["status_text", `String (status_text preview);
    "activity", activity_to_json preview.activity;
    "open_activities", `List (List.map open_activity_to_json preview.open_activities);
    "text_tail", `String preview.text_tail;
    "text_position", `Assoc ["generation", `Int preview.text_position.generation;
      "start_byte", `Int preview.text_position.start_byte];
    "last_tool", (match preview.last_tool with None -> `Null | Some name -> `String name);
    "updated_at_unix", `Float preview.updated_at;
    "revision", `Int preview.revision;
    "preparation",Option.fold ~none:`Null ~some:preparation_to_json preview.preparation;
    "preparation_timeline",(if include_preparation_timeline then
      preparation_timeline_to_json preview.preparation_timeline else `Null);
    "execution_scope",Option.fold ~none:`Null ~some:Keeper_execution_scope_id.to_json preview.execution_scope;
    "work_context",Option.fold ~none:`Null ~some:work_context_to_json preview.work_context]
