(* Keeper_next_request_forecast — what the next Agent Core request would
   carry, computed from the same values a turn uses, without a turn.

   The arithmetic is the turn driver's (RFC keeper-context-window-in-tokens
   §10.4): the carried range from the pair's front, over the durable history
   with the wake line appended as the newest atom. The front, the marks and
   the request-body cap are read live; R (tool schemas + keeper
   instructions) and the pinned blocks (memory recall, dynamic context, ...)
   are taken from the turn records of completed turns on the same runtime,
   because a turn measures them with the encoder the composition uses and
   nothing outside a turn assembles them without side effects (a preview
   would consume the operator note and advance nothing else it should).

   Two readings, two turns: a record describes the turn's latest request.
   The schemas and the instructions are the lane's and ride every round, so
   R comes from the newest record of a completed turn on the same runtime;
   an errored turn's record names the requested runtime ([settled_runtime_id]
   falls back to it) while its composition may be a failed attempt's on
   another lane, and [finish_reason] is [None] on exactly that path. The
   pinned blocks are the keeper's, the same content whichever lane runs, and
   a post-tool round drops every block
   [Prompt_block_id.injected_on_post_tool_round] refuses, so a first-round
   composition is recorded mostly by single-request turns: official-client
   turns (one request each) and turns that errored on their first request.
   Pinned therefore comes from the newest first-round composition on any
   lane, completed or not; a composition is real once it was measured, since
   the record carries none when no request reached the wire. Keepers walk
   three or four lanes, and on 2026-09-16 analyst's newest 200 records held
   no completed first round on its bound lane and 78 on claude_code. *)

type measured_parts =
  { reserved_turn : int
  ; reserved_bytes : int
  ; pinned_turn : int
  ; pinned_runtime_id : string
  ; pinned_bytes : int
  }

type parts_refusal =
  | No_composition_on_runtime of { records_read : int }
  | No_first_round_composition of { records_read : int; newest_turn : int }

let parts_refusal_to_string = function
  | No_composition_on_runtime { records_read } ->
    Printf.sprintf
      "no completed turn on this runtime carried a composition in the newest %d records"
      records_read
  | No_first_round_composition { records_read; newest_turn } ->
    Printf.sprintf
      "the newest %d turn records hold no first-round composition on any lane (newest \
       completed turn on this runtime #%d); only a first round carries the pinned blocks"
      records_read
      newest_turn
;;

type lane_refusal =
  | Not_materialized of { runtime_id : string }
  | Not_agent_core of { runtime_id : string }

let lane_refusal_to_string = function
  | Not_materialized { runtime_id } ->
    Printf.sprintf "runtime %s is not materialized" runtime_id
  | Not_agent_core { runtime_id } ->
    Printf.sprintf
      "%s is an official-client runtime: the spawned client owns its context and masc \
       carries no range for it"
      runtime_id
;;

type carried =
  { first_atom : int
  ; kept_atoms : int
  ; transmitted_bytes : int
  ; origin : Keeper_carried_front.origin
  ; counted_tokens : int option
  }

type candidate =
  { runtime_id : string
  ; lane : (unit, lane_refusal) result
  ; marks : Runtime_schema.context_marks option
  ; parts : (measured_parts, parts_refusal) result
  ; history_atoms : int
  ; carried : carried option
  }

type t =
  { keeper : string
  ; trace_id : string
  ; checkpoint_messages : int
  ; wake_line_bytes : int
  ; candidates : candidate list
  }


let carry ~measure ~front ~counted_tokens messages =
  let _labelled, atom_count = Runtime_model_input_tail_window.annotate messages in
  let first_atom, origin, counted_tokens =
    match Option.bind front (Keeper_carried_front.for_history ~atom_count) with
    | Some (seed : Keeper_carried_front.seed) ->
      ( Keeper_carried_front.clamp ~atom_count seed.first_atom
      , Keeper_carried_front.Carried seed.source
      , counted_tokens )
    | None -> 0, Keeper_carried_front.Whole_history, None
  in
  let projection, transmitted_bytes =
    Runtime_model_input_tail_window.project_from_atom
      ~measure_message_bytes:measure
      ~first_atom
      messages
  in
  { first_atom = projection.Runtime_model_input_tail_window.dropped_atoms
  ; kept_atoms =
      projection.Runtime_model_input_tail_window.atom_count
      - projection.Runtime_model_input_tail_window.dropped_atoms
  ; transmitted_bytes
  ; origin
  ; counted_tokens
  }
;;

(* Whether the turn driver would compose a range for this runtime at all.
   An official-client runtime carries none: the spawned client owns its
   context. *)
let lane_for ~runtime_id (runtime : Runtime.t option) =
  match runtime with
  | None -> Error (Not_materialized { runtime_id })
  | Some runtime ->
    (match runtime.Runtime.execution with
     | Runtime_execution.Codex_app_server _
     | Runtime_execution.Claude_code _
     | Runtime_execution.Antigravity_cli _ -> Error (Not_agent_core { runtime_id })
     | Runtime_execution.Agent_core _ -> Ok ())
;;

type composition =
  { fixed_bytes : int
  ; first_round_pinned_bytes : int option
  }

(* Keeper instructions ride in the system prompt and every other prompt
   block rides as pinned extra system context; the message kinds are the
   history the cut decides about and belong to neither. A composition is a
   first round's when it carries a block the post-tool assembly drops; the
   predicate is the assembly's own. *)
let read_composition (components : Turn_record.input_component list) =
  let fixed, pinned, first_round =
    List.fold_left
      (fun (fixed, pinned, first_round) (component : Turn_record.input_component) ->
        match component.Turn_record.component with
        | Turn_record.Tool_schemas -> fixed + component.bytes, pinned, first_round
        | Turn_record.Prompt_block Prompt_block_id.Keeper_instructions ->
          fixed + component.bytes, pinned, first_round
        | Turn_record.Prompt_block id ->
          ( fixed
          , pinned + component.bytes
          , first_round || not (Prompt_block_id.injected_on_post_tool_round id) )
        | Turn_record.Message_user
        | Turn_record.Message_system
        | Turn_record.Message_assistant_text
        | Turn_record.Message_thinking
        | Turn_record.Message_redacted_thinking
        | Turn_record.Message_tool_use
        | Turn_record.Message_tool_result
        | Turn_record.Message_image
        | Turn_record.Message_document
        | Turn_record.Message_audio -> fixed, pinned, first_round)
      (0, 0, false)
      components
  in
  { fixed_bytes = fixed
  ; first_round_pinned_bytes = (if first_round then Some pinned else None)
  }
;;

type record_reading =
  { turn : int
  ; runtime_id : string
  ; completed : bool
  ; composition : composition
  }

(* Oldest first; each step keeps the newer answer. *)
let select_parts ~runtime_id ~records_read (readings : record_reading list) =
  let newest_fixed, newest_pinned =
    List.fold_left
      (fun (newest_fixed, newest_pinned) reading ->
        ( (if reading.completed && String.equal reading.runtime_id runtime_id
           then Some (reading.turn, reading.composition.fixed_bytes)
           else newest_fixed)
        , match reading.composition.first_round_pinned_bytes with
          | Some pinned -> Some (reading.turn, reading.runtime_id, pinned)
          | None -> newest_pinned ))
      (None, None)
      readings
  in
  match newest_fixed, newest_pinned with
  | Some (reserved_turn, reserved_bytes), Some (pinned_turn, pinned_runtime_id, pinned_bytes) ->
    Ok { reserved_turn; reserved_bytes; pinned_turn; pinned_runtime_id; pinned_bytes }
  | Some (newest_turn, _), None ->
    Error (No_first_round_composition { records_read; newest_turn })
  | None, _ -> Error (No_composition_on_runtime { records_read })
;;

let record_runtime (record : Turn_record.t) =
  match record.Turn_record.request_wire_observation with
  | Some observation -> observation.Turn_record.runtime_profile
  | None -> record.Turn_record.runtime_profile
;;

(* A keeper that calls tools on most turns leaves mostly post-tool records
   (lane-smith: one first-round record in thirteen on 2026-09-16), so the
   read reaches back as far as the carried front's seed does, for the same
   reason: most records are another lane's. *)
let recent_records_read = Keeper_carried_front.records_read

(* Every record with an exact composition is read; [select_parts] decides
   which lane and which completion each figure may come from. [finish_reason]
   is the stop reason the receipt recorded and is [None] on the error path,
   the path on which the record's runtime is the requested one rather than
   the one whose composition it holds (analyst turn #4031: named glm-coding,
   held claude_code's schemas). *)
let newest_parts_for ~config ~keeper_name ~runtime_id =
  let store = Keeper_types_support.keeper_turn_record_store config keeper_name in
  let records = Dated_jsonl.read_recent store recent_records_read in
  let readings =
    List.filter_map
      (fun json ->
        match Turn_record.of_json json with
        | Error _ -> None
        | Ok record ->
          (match record.Turn_record.input_components with
           | None -> None
           | Some components ->
             Some
               { turn = record.Turn_record.absolute_turn
               ; runtime_id = record_runtime record
               ; completed = Option.is_some record.Turn_record.finish_reason
               ; composition = read_composition components
               }))
      records
  in
  select_parts ~runtime_id ~records_read:(List.length records) readings
;;

let wake_line () =
  let text = Env_config_keeper.KeeperAutonomous.default_wake_prompt in
  ( { Agent_core.Types.role = Agent_core.Types.User
    ; content = [ Agent_core.Types.Text text ]
    ; name = None
    ; tool_call_id = None
    ; metadata = []
    }
  , String.length text )
;;

let candidate ~config ~keeper_name ~trace_id ~messages ~history_atoms runtime_id =
  let runtime = Runtime.get_runtime_by_id runtime_id in
  let lane = lane_for ~runtime_id runtime in
  let parts = newest_parts_for ~config ~keeper_name ~runtime_id in
  let carried =
    match lane with
    | Error _ -> None
    | Ok () ->
      (* The same front the turn driver composes from: the pair's ledger,
         else the newest completed record on the runtime. *)
      let front, counted_tokens =
        match
          Keeper_model_input_ledger.Table.lookup ~keeper_name ~runtime_id ~session_id:trace_id
        with
        | Some ledger ->
          Some (Keeper_carried_front.of_ledger ledger), ledger.Keeper_model_input_ledger.total_tokens
        | None ->
          Keeper_carried_front.read_seed ~config ~keeper_name ~runtime_id ~trace_id, None
      in
      Some
        (carry
           ~measure:(Keeper_context_core.message_measurer ())
           ~front
           ~counted_tokens
           messages)
  in
  { runtime_id
  ; lane
  ; marks = Runtime.context_marks_of_runtime_id runtime_id
  ; parts
  ; history_atoms
  ; carried
  }
;;

let forecast ~config ~keeper_name =
  match Keeper_meta_store.read_meta config keeper_name with
  | Error message -> Error message
  | Ok None -> Error (Printf.sprintf "keeper %S not found" keeper_name)
  | Ok (Some meta) ->
    let trace_id = Keeper_id.Trace_id.to_string meta.Keeper_meta_contract.runtime.trace_id in
    let session_dir = Keeper_types_support.keeper_session_dir config trace_id in
    (match
       Keeper_checkpoint_store.load_agent_core ~session_dir ~session_id:trace_id
     with
     | Error error ->
       Error (Keeper_checkpoint_store.checkpoint_load_error_to_string error)
     | Ok checkpoint ->
       let history = checkpoint.Agent_core.Checkpoint.messages in
       let wake, wake_line_bytes = wake_line () in
       let messages = history @ [ wake ] in
       let _labelled, history_atoms =
         Runtime_model_input_tail_window.annotate messages
       in
       let runtime_id = Keeper_meta_contract.runtime_id_of_meta meta in
       Ok
         { keeper = keeper_name
         ; trace_id
         ; checkpoint_messages = List.length history
         ; wake_line_bytes
         ; candidates =
             [ candidate ~config ~keeper_name ~trace_id ~messages ~history_atoms runtime_id ]
         })
;;

let option_json to_json = function
  | None -> `Null
  | Some value -> to_json value
;;

let carried_to_json (carried : carried) =
  `Assoc
    [ "first_atom", `Int carried.first_atom
    ; "kept_atoms", `Int carried.kept_atoms
    ; "transmitted_bytes", `Int carried.transmitted_bytes
    ; "origin", Keeper_carried_front.origin_to_json carried.origin
    ; "counted_tokens", option_json (fun n -> `Int n) carried.counted_tokens
    ]
;;

let candidate_to_json (candidate : candidate) =
  `Assoc
    [ "runtime_id", `String candidate.runtime_id
    ; ( "lane"
      , match candidate.lane with
        | Ok () -> `Assoc [ "agent_core", `Bool true ]
        | Error refusal ->
          `Assoc [ "not_applicable", `String (lane_refusal_to_string refusal) ] )
    ; ( "marks"
      , option_json
          (fun (marks : Runtime_schema.context_marks) ->
             `Assoc
               [ "high_water_tokens", `Int marks.high_water_tokens
               ; "low_water_tokens", `Int marks.low_water_tokens
               ])
          candidate.marks )
    ; ( "parts"
      , match candidate.parts with
        | Ok parts ->
          `Assoc
            [ "reserved_measured_on_turn", `Int parts.reserved_turn
            ; "reserved_bytes", `Int parts.reserved_bytes
            ; "pinned_measured_on_turn", `Int parts.pinned_turn
            ; "pinned_measured_on_runtime", `String parts.pinned_runtime_id
            ; "pinned_bytes", `Int parts.pinned_bytes
            ]
        | Error refusal -> `Assoc [ "error", `String (parts_refusal_to_string refusal) ] )
    ; "history_atoms", `Int candidate.history_atoms
    ; "carried", option_json carried_to_json candidate.carried
    ]
;;

let to_json forecast =
  `Assoc
    [ "schema", `String "masc.keeper.next-request-forecast.v2"
    ; "keeper", `String forecast.keeper
    ; "trace_id", `String forecast.trace_id
    ; "checkpoint_messages", `Int forecast.checkpoint_messages
    ; "wake_line_bytes", `Int forecast.wake_line_bytes
    ; "candidates", `List (List.map candidate_to_json forecast.candidates)
    ]
;;
