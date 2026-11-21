module Types = Keeper_memory_os_types
module Current = Keeper_memory_os_current_types
module Read_unit = Librarian_read_unit
module Turn_log = Keeper_turn_log
module Chat = Keeper_chat_types
module Names = Set_util.StringMap
module Sha256 = Agent_core_sha256

type made =
  | Made of
      { question : Librarian_read_result.question
      ; text : string
      ; schema : Yojson.Safe.t
      }
  | Nothing_readable of
      { reach : Librarian_read_result.reach
      ; missing : Librarian_unit.missing_at list
      }

(* The labels of the lines after the prompt (RFC §6.1). *)
let label_question = "question: "
let label_memory = "memory: "
let label_working_state = "working_state: "
let label_units = "units: "
let label_make_room = "make_room: "
let label_question_end = "question-end: "

(* The one sentence a question that makes room shows where a reading
   question shows its units (§6.1). It states what happened and sets no
   target: no count, no size. *)
let make_room_sentence =
  "방금 읽은 항목 하나는 이 Memory 와 함께 묻는 질문으로는 선언한 어느 slot 에도 들어가지 \
   않아서, Memory 와 하던 일 없이 그 항목만 읽었습니다."
let newline = "\n"

(* A fact shows the snapshot's field names, so an answer writes what it read. *)
let f_kind = Types.wire_field_kind
let f_claim = Types.wire_field_claim
let f_category = Types.wire_field_category
let f_basis = Types.wire_field_basis
let f_derivations = Types.wire_field_derivations
let f_first_seen = Types.wire_field_first_seen
let f_last_seen = Types.wire_field_last_seen

(* The rest name what only a question shows. *)
let f_name = "name"
let f_closed_at = "closed_at"
let f_turn = "turn"
let f_runtime = "runtime"
let f_outcome = "outcome"
let f_task = "task"
let f_goals = "goals"
let f_goal = "goal"
let f_shown = "shown"
let f_stimuli = "stimuli"
let f_unattributed = "unattributed"
let f_own = "own"
let f_closed_after_admission = "closed_after_admission"
let f_cause = "cause"
let f_items = "items"
let f_missing = "missing"
let f_index = "index"
let f_role = "role"
let f_speaker = "speaker"
let f_content = "content"
let f_text = "text"
let f_id = "id"
let f_source = "source"
let f_tool_call = "tool_call"
let f_tool_name = "tool_name"
let f_actor = "actor"
let f_urgency = "urgency"
let f_runtime_context = "runtime_context"
let f_messages = "messages"
let f_bytes = "bytes"
let f_rows = "rows"
let f_prompt = "prompt"
let f_answer_schema = "answer_schema"
let f_max_output_tokens = "max_output_tokens"
let f_thinking = "thinking"
(* Words two writers below share: a message item from either store, and a
   tool outcome from either the history or the fragment store. *)
let kind_message = "message"
let succeeded = "succeeded"
let failed = "failed"
let tagged kind fields = `Assoc ((f_kind, `String kind) :: fields)
let text_or_null value = Option.fold ~none:`Null ~some:(fun text -> `String text) value
let time seconds = `String (Masc_domain.iso8601_of_unix_seconds seconds)
let memory_name index = "m" ^ Int.to_string (index + 1)
let unit_name index = "u" ^ Int.to_string (index + 1)

(* {1 Memory} *)

(* A derived fact names each proof's premises by the names Memory gave them,
   so no 71-character id reaches the model. Proofs that differ only in their
   rule show once. *)
let basis_json names : Types.basis -> Yojson.Safe.t = function
  | Observed _ as basis -> Types.basis_to_json basis
  | Derived derivations ->
    let premise id = text_or_null (Names.find_opt id names) in
    let proofs =
      List.map
        (fun derivation -> (Types.normalize_derivation derivation).premise_ids)
        derivations
      |> List.sort_uniq (List.compare String.compare)
    in
    tagged
      "derived"
      [ f_derivations, `List (List.map (fun ids -> `List (List.map premise ids)) proofs) ]
;;

let fact_json names index (fact : Types.fact) =
  `Assoc
    [ f_name, `String (memory_name index)
    ; f_claim, `String fact.claim
    ; f_category, `String (Types.category_to_string fact.category)
    ; f_basis, basis_json names fact.basis
    ; f_first_seen, time fact.first_seen
    ; f_last_seen, time fact.last_seen
    ]
;;

let working_state : Librarian_log.line -> string option = function
  | Started _ -> None
  | Committed commit -> commit.working_state
;;

(* {1 Units} *)

let outcome_token : Turn_log.outcome -> string = function
  | Completed -> "completed"
  | Errored -> "errored"
  | Cancelled -> "cancelled"
  | Save_failed -> "save_failed"
  | Stale_save -> "stale_save"
  | Close_missing -> "close_missing"
  | Process_exited -> "process_exited"
;;

(* RFC §5.3: a turn the next admission or the next process closed did not
   close its own items. They were closed after it was admitted. *)
let own_field : Turn_log.outcome -> string = function
  | Completed | Errored | Cancelled | Save_failed | Stale_save -> f_own
  | Close_missing | Process_exited -> f_closed_after_admission
;;

let announced_token : Turn_log.announced -> string = function
  | Cleared -> "cleared"
  | Recovered -> "recovered"
;;

let task_json : Turn_log.task_evidence -> Yojson.Safe.t = function
  | No_task -> tagged "no_task" []
  | Task_source_unavailable -> tagged "task_source_unavailable" []
  | Task { task; goals } ->
    let goal_json ({ goal; shown } : Turn_log.goal_shown) =
      `Assoc [ f_goal, `String goal; f_shown, `String shown ]
    in
    tagged
      "task"
      [ f_task, `String (Keeper_id.Task_id.to_string task)
      ; (f_goals, match goals with None -> `Null | Some goals -> `List (List.map goal_json goals))
      ]
;;

(* Who sent a row, as its store typed it. A row written before its store
   recorded senders says so and is not given a guessed kind. *)
let sender ~authority ~id ~name =
  tagged (Chat.authority_label authority) [ f_id, text_or_null id; f_name, text_or_null name ]
;;

let unknown_sender : Yojson.Safe.t = tagged "unknown" []

let input_speaker : Keeper_input_speaker.classification -> Yojson.Safe.t = function
  | Absent -> unknown_sender
  | Present speaker -> Keeper_input_speaker.to_json speaker
  | Invalid _ -> tagged "invalid" []
  | Duplicate -> tagged "duplicate" []
;;

let tool_result_token : Agent_core.Types.tool_result_outcome -> string = function
  | Tool_succeeded -> succeeded
  | Tool_failed _ -> failed
;;

(* §5.5: a tool call is its id and name, a tool result its id and its kind.
   Thinking is the model's reasoning, not something the Keeper saw. *)
let block_json : Agent_core.Types.content_block -> Yojson.Safe.t option = function
  | Text text -> Some (tagged "text" [ f_text, `String text ])
  | ToolUse { id; name; input = _ } ->
    Some (tagged "tool_use" [ f_id, `String id; f_name, `String name ])
  | ToolResult { tool_use_id; outcome; _ } ->
    Some
      (tagged
         "tool_result"
         [ f_id, `String tool_use_id; f_outcome, `String (tool_result_token outcome) ])
  | Image _ -> Some (tagged "image" [])
  | Document _ -> Some (tagged "document" [])
  | Audio _ -> Some (tagged "audio" [])
  | Thinking _ | ReasoningDetails _ | RedactedThinking _ -> None
;;

(* What the runtime puts before the model (recalled Memory, outside text,
   instructions, recovery cues) is not an observation of this unit. Its
   content is left out, so Memory is not read back as an observation. *)
let message_fields (message : Agent_core.Types.message) =
  let role = f_role, `String (Agent_core.Types.role_to_string message.role) in
  match message.origin with
  | Conversation ->
    let speaker =
      match message.role with
      | User -> [ f_speaker, input_speaker (Keeper_input_speaker.classify message.metadata) ]
      | System | Assistant | Tool -> []
    in
    (role :: speaker) @ [ f_content, `List (List.filter_map block_json message.content) ]
  | System_context
  | Historical_system_context
  | Recovery_instruction
  | Tool_result_followup
  | Agent_instruction
  | Outside_context ->
    [ role
    ; f_runtime_context, `String (Agent_core.Types.message_origin_to_string message.origin)
    ]
;;

let chat_speaker : Chat.speaker option -> Yojson.Safe.t = function
  | None -> unknown_sender
  | Some { speaker_id; speaker_name; speaker_authority } ->
    sender ~authority:speaker_authority ~id:speaker_id ~name:speaker_name
;;

let chat_fields (line : Keeper_chat_store_line_decode.parsed_line) =
  match line.message with
  | None -> [ f_kind, `String "chat_unreadable" ]
  | Some message ->
    let shown =
      match message.role with
      | User -> [ f_speaker, chat_speaker message.speaker; f_content, `String message.content ]
      | Assistant | System -> [ f_content, `String message.content ]
      | Tool ->
        (* The row a tool call left. Its content is the call's arguments. *)
        [ ( f_tool_call
          , `Assoc
              [ f_id, text_or_null message.tool_call_id
              ; f_name, text_or_null message.tool_call_name
              ] )
        ]
      | Request_failure -> []
    in
    (f_kind, `String "chat") :: (f_role, `String (Chat.Role.to_label message.role)) :: shown
;;

let external_fields (item : Keeper_external_attention.item) =
  [ f_kind, `String "external"
  ; ( f_actor
    , sender
        ~authority:item.actor.authority
        ~id:item.actor.actor_id
        ~name:item.actor.display_name )
  ; f_source, `String item.source_label
  ; f_urgency, `String (Keeper_external_attention.urgency_to_string item.urgency)
  ; f_content, `String item.content_preview
  ]
;;

let observation_token : Keeper_librarian.tool_observation_outcome -> string = function
  | Succeeded -> succeeded
  | Failed -> failed
  | Unknown -> "unknown"
;;

let fragment_fields : Keeper_turn_fragments.line -> (string * Yojson.Safe.t) list = function
  | Untagged -> [ f_kind, `String "untagged" ]
  | Fragment (Message { source; message; turn_ref = _; recorded_at = _ }) ->
    (f_kind, `String kind_message) :: (f_source, text_or_null source) :: message_fields message
  | Fragment (Tool_observation { observation; turn_ref = _; recorded_at = _ }) ->
    [ f_kind, `String "tool_observation"
    ; f_tool_name, `String observation.tool_name
    ; f_outcome, `String (observation_token observation.outcome)
    ]
;;

let body_fields : Read_unit.body -> (string * Yojson.Safe.t) list = function
  | Chat_row line -> chat_fields line
  | External_row item -> external_fields item
  | Message message -> (f_kind, `String kind_message) :: message_fields message
  | Fragment { file = _; line } -> fragment_fields line
;;

let item_json ({ index; body; name = (_ : Librarian_unit.item_name) } : Read_unit.item) =
  `Assoc ((f_index, `Int index) :: body_fields body)
;;

let items_json items = `List (List.map item_json items)

let missing_part_json : Librarian_unit.missing_part -> Yojson.Safe.t = function
  | Bundle { take; bundle = _; skip = _ } -> tagged "bundle" [ f_messages, `Int take ]
  | History_bytes { from; until } -> tagged "history_bytes" [ f_bytes, `Int (until - from) ]
  | Internal_bytes { from; until } -> tagged "internal_bytes" [ f_bytes, `Int (until - from) ]
  | Chat_bytes { from; until } -> tagged "chat_bytes" [ f_bytes, `Int (until - from) ]
  | External_rows { from; until } -> tagged "external_rows" [ f_rows, `Int (until - from) ]
  | Undecodable_history_line { offset = _ } -> tagged "undecodable_history_line" []
  | Undecodable_internal_line { offset = _ } -> tagged "undecodable_internal_line" []
  | Undecodable_external_row { row = _ } -> tagged "undecodable_external_row" []
;;

let unit_json index ({ line = _; at; kind; missing } : Read_unit.t) =
  let shown =
    match kind with
    | Turn { turn; outcome; opened; unattributed; own } ->
      [ f_kind, `String "turn"
      ; f_closed_at, time at
      ; f_turn, `Int turn
      ; f_runtime, `String opened.runtime
      ; f_outcome, `String (outcome_token outcome)
      ; f_task, task_json opened.task
      ; f_stimuli, `List (List.map Keeper_turn_log_stimulus_codec.to_json opened.stimuli)
      ; f_unattributed, items_json unattributed
      ; own_field outcome, items_json own
      ]
    | Reset { cause; items } ->
      [ f_kind, `String "reset"
      ; f_closed_at, time at
      ; f_cause, `String (announced_token cause)
      ; f_items, items_json items
      ]
  in
  `Assoc
    (((f_name, `String (unit_name index)) :: shown)
     @ [ f_missing, `List (List.map missing_part_json missing) ])
;;

let has_item ({ kind; _ } : Read_unit.t) =
  match kind with
  | Turn { unattributed; own; _ } -> not (List.is_empty unattributed && List.is_empty own)
  | Reset { items; _ } -> not (List.is_empty items)
;;

(* {1 The id} *)

let declaration
      ~schema
      ({ prompt; answer_schemas = (_ : Librarian_memory_lane.answer_schemas); max_output_tokens; thinking } :
        Librarian_memory_lane.question_side)
  =
  `Assoc
    [ f_prompt, `String prompt
    ; f_answer_schema, schema
    ; f_max_output_tokens, `Int max_output_tokens
    ; f_thinking, Option.fold ~none:`Null ~some:(fun on -> `Bool on) thinking
    ]
;;

let digest parts =
  Sha256.get (List.fold_left (fun ctx part -> Sha256.feed_string ctx part) (Sha256.init ()) parts)
;;

let line label value = label ^ value ^ newline
let json_line label json = line label (Yojson.Safe.to_string json)

(* The declaration is compact JSON, so the line break after it ends it. *)
let front ~lane ~schema memory_lines =
  digest (Yojson.Safe.to_string (declaration ~schema lane) :: newline :: memory_lines)
;;

(* Memory as [from] holds it, each fact under its short name, and the
   working state of [from]. *)
let memory_and_working_state ~from (memory : Current.t) =
  let table = List.mapi (fun index fact -> memory_name index, Types.memory_id fact) memory.facts in
  (* The first name of each id: [fold_right] adds the earlier names last. *)
  let names =
    List.fold_right (fun (name, id) names -> Names.add id name names) table Names.empty
  in
  ( table
  , [ json_line label_memory (`List (List.mapi (fact_json names) memory.facts))
    ; json_line label_working_state (text_or_null (working_state from))
    ] )
;;

let text ~(lane : Librarian_memory_lane.question_side) (id : Librarian_question_id.t) body =
  String.concat
    ""
    ([ lane.prompt; newline; line label_question id.front ]
     @ body
     @ [ line label_question_end id.back ])
;;

type shows =
  | With_memory of Current.t
  | Item_alone

let make ~(lane : Librarian_memory_lane.question_side) ~from ~shows ~reach ~trace ~offered units =
  let missing = Read_unit.missing_at units in
  if not (List.exists has_item units)
  then Nothing_readable { reach; missing }
  else (
    let units_line = json_line label_units (`List (List.mapi unit_json units)) in
    let names = List.mapi (fun index (read : Read_unit.t) -> unit_name index, read.line) units in
    (* A question of the item alone has neither Memory line, so its front
       half is the question side's alone and Memory changing leaves its id
       as it was (§7.4). *)
    let schema, memory_lines, (shown : Librarian_plan.read) =
      match shows with
      | Item_alone -> lane.answer_schemas.item_alone, [], Item_alone { units = names }
      | With_memory memory ->
        let table, lines = memory_and_working_state ~from memory in
        lane.answer_schemas.range, lines, Range { memory = table; units = names }
    in
    let id =
      Librarian_question_id.of_digests
        ~front:(front ~lane ~schema memory_lines)
        ~back:(digest [ units_line ])
    in
    Made
      { question =
          { id; shown; basis = Librarian_log.snapshot_after from; reach; trace; missing; offered }
      ; text = text ~lane id (memory_lines @ [ units_line ])
      ; schema
      })
;;

type room =
  { question : Librarian_room_result.question
  ; text : string
  ; schema : Yojson.Safe.t
  }

let make_room ~(lane : Librarian_memory_lane.question_side) ~from ~memory ~trace =
  let schema = lane.answer_schemas.room in
  let table, memory_lines = memory_and_working_state ~from memory in
  let sentence_line = json_line label_make_room (`String make_room_sentence) in
  let id =
    Librarian_question_id.of_digests
      ~front:(front ~lane ~schema memory_lines)
      ~back:(digest [ sentence_line ])
  in
  { question = { id; memory = table; basis = Librarian_log.snapshot_after from; trace }
  ; text = text ~lane id (memory_lines @ [ sentence_line ])
  ; schema
  }
;;
