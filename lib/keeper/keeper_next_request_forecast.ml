(* Keeper_next_request_forecast — what the next Agent Core request would
   carry, computed from the same values a turn uses, without a turn.

   The arithmetic is the turn driver's (RFC keeper-context-window-in-tokens
   §10.3): capacity B = W × density, history room A = B − R − pinned, and the
   cut is [Runtime_model_input_tail_window.project_target] on the durable
   history with the wake line appended as the newest atom. W, the density
   and the request-body cap are read live; R (tool schemas + keeper
   instructions) and the pinned blocks (memory recall, dynamic context, ...)
   are taken from the turn records of completed turns on the same runtime,
   because a turn measures them with the encoder the cut uses and nothing
   outside a turn assembles them without side effects (a preview would
   consume the operator note and advance nothing else it should).

   Two readings, two turns: a record describes the turn's latest request. The
   schemas and the instructions ride every round, so the newest record has
   the current surface. A post-tool round drops every block
   [Prompt_block_id.injected_on_post_tool_round] refuses, so only a record
   carrying such a block says what the next first round pins. An errored
   turn's record names the requested runtime ([settled_runtime_id] falls back
   to it) while its composition may be a failed attempt's on another lane;
   [finish_reason] is [None] on exactly that path, so such records are not
   read. *)

type measured_parts =
  { reserved_turn : int
  ; reserved_bytes : int
  ; pinned_turn : int
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
      "the newest %d turn records on this runtime hold compositions only from post-tool \
       rounds (newest turn #%d), which carry no pinned block"
      records_read
      newest_turn
;;

type window_refusal =
  | Contradiction of string
  | Not_agent_core of { runtime_id : string }

let window_refusal_to_string = function
  | Contradiction reason -> reason
  | Not_agent_core { runtime_id } ->
    Printf.sprintf
      "%s is an official-client runtime: the spawned client owns its context window and \
       masc applies no Agent Core cut"
      runtime_id
;;

type history_cut =
  | Cut of
      { kept_atoms : int
      ; transmitted_bytes : int
      ; fit : Runtime_model_input_tail_window.target_fit
      }
  | Newest_atom_only of { transmitted_bytes : int }

type candidate =
  { runtime_id : string
  ; window : (Keeper_context_window.t, window_refusal) result
  ; capacity : Keeper_context_window.capacity option
  ; request_cap_bytes : int option
  ; parts : (measured_parts, parts_refusal) result
  ; history_atoms : int
  ; cut : history_cut option
  }

type t =
  { keeper : string
  ; trace_id : string
  ; checkpoint_messages : int
  ; wake_line_bytes : int
  ; candidates : candidate list
  }

let measure (message : Agent_core.Types.message) =
  String.length
    (Yojson.Safe.to_string (Keeper_context_core.message_to_json message))
;;

let cut_history ~measure ~capacity ~reserved_bytes ~pinned_bytes messages =
  match capacity with
  | Keeper_context_window.Unmeasured _ ->
    let _projection, transmitted_bytes =
      Runtime_model_input_tail_window.project_newest_atom
        ~measure_message_bytes:measure
        messages
    in
    Newest_atom_only { transmitted_bytes }
  | Keeper_context_window.Measured { capacity_bytes; _ } ->
    let target =
      Runtime_model_input_tail_window.project_target
        ~measure_message_bytes:measure
        ~target_bytes:capacity_bytes
        ~reserved_bytes:(reserved_bytes + pinned_bytes)
        messages
    in
    let projection = target.Runtime_model_input_tail_window.projection in
    Cut
      { kept_atoms =
          projection.Runtime_model_input_tail_window.atom_count
          - projection.Runtime_model_input_tail_window.dropped_atoms
      ; transmitted_bytes = target.Runtime_model_input_tail_window.transmitted_bytes
      ; fit = target.Runtime_model_input_tail_window.fit
      }
;;

(* The window the turn driver would declare for this runtime, with the same
   refusal: a window the model cannot carry is a configuration contradiction,
   named rather than clamped. An official-client runtime declares none: the
   spawned client owns its window and no Agent Core cut applies. *)
let window_for ~runtime_id (runtime : Runtime.t option) =
  match runtime with
  | None -> Error (Contradiction (Printf.sprintf "runtime %s is not materialized" runtime_id))
  | Some runtime ->
    (match runtime.Runtime.execution with
     | Runtime_execution.Codex_app_server _
     | Runtime_execution.Claude_code _
     | Runtime_execution.Antigravity_cli _ -> Error (Not_agent_core { runtime_id })
     | Runtime_execution.Agent_core _ ->
       let window_tokens = Keeper_runtime_resolved.context_window_tokens () in
       (match Runtime.max_context_of_runtime_id runtime_id with
        | Some max_context when window_tokens > max_context ->
          Error
            (Contradiction
               (Printf.sprintf
                  "turn.context_window_tokens %d exceeds the %d-token max-context of %s"
                  window_tokens
                  max_context
                  runtime_id))
        | Some _ -> Ok (Keeper_context_window.declared ~window_tokens)
        | None ->
          Error
            (Contradiction
               (Printf.sprintf "runtime %s resolves no context window" runtime_id))))
;;

(* The cap the driver judges the body against, read from the materialized
   runtime the way [Runtime.keeper_dispatch_readiness] reads it. Only an
   Agent Core runtime builds the request this bounds. *)
let request_cap_for ~runtime_id (runtime : Runtime.t option) =
  match runtime with
  | None -> None
  | Some runtime ->
    (match runtime.Runtime.execution with
     | Runtime_execution.Agent_core provider_config ->
       (match Runtime.validate_request_body_cap ~runtime_id provider_config with
        | Ok cap -> cap
        | Error _ -> None)
     | Runtime_execution.Codex_app_server _
     | Runtime_execution.Claude_code _
     | Runtime_execution.Antigravity_cli _ -> None)
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

(* Oldest first; each step keeps the newer answer. *)
let select_parts ~records_read (compositions : (int * composition) list) =
  let newest_fixed, newest_pinned =
    List.fold_left
      (fun (_newest_fixed, newest_pinned) (turn, composition) ->
        ( Some (turn, composition.fixed_bytes)
        , match composition.first_round_pinned_bytes with
          | Some pinned -> Some (turn, pinned)
          | None -> newest_pinned ))
      (None, None)
      compositions
  in
  match newest_fixed, newest_pinned with
  | Some (reserved_turn, reserved_bytes), Some (pinned_turn, pinned_bytes) ->
    Ok { reserved_turn; reserved_bytes; pinned_turn; pinned_bytes }
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
   read reaches back far enough to meet one. *)
let recent_records_read = 200

(* A record is read when it is a completed turn on this runtime with an
   exact composition. [finish_reason] is the stop reason the receipt
   recorded and is [None] on the error path, the path on which the record's
   runtime is the requested one rather than the one whose composition it
   holds (analyst turn #4031: named glm-coding, held claude_code's schemas). *)
let newest_parts_for ~config ~keeper_name ~runtime_id =
  let store = Keeper_types_support.keeper_turn_record_store config keeper_name in
  let records = Dated_jsonl.read_recent store recent_records_read in
  let compositions =
    List.filter_map
      (fun json ->
        match Turn_record.of_json json with
        | Error _ -> None
        | Ok record ->
          (match
             ( String.equal (record_runtime record) runtime_id
             , record.Turn_record.finish_reason
             , record.Turn_record.input_components )
           with
           | true, Some _, Some components ->
             Some (record.Turn_record.absolute_turn, read_composition components)
           | true, None, _ | true, _, None | false, _, _ -> None))
      records
  in
  select_parts ~records_read:(List.length records) compositions
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

let candidate ~config ~keeper_name ~messages ~history_atoms runtime_id =
  let runtime = Runtime.get_runtime_by_id runtime_id in
  let window = window_for ~runtime_id runtime in
  let capacity =
    match window with
    | Error _ -> None
    | Ok window ->
      Some
        (Keeper_context_window.capacity
           window
           (Keeper_context_window.Density.lookup ~runtime_id))
  in
  let parts = newest_parts_for ~config ~keeper_name ~runtime_id in
  let cut =
    match capacity, parts with
    | Some capacity, Ok parts ->
      Some
        (cut_history
           ~measure
           ~capacity
           ~reserved_bytes:parts.reserved_bytes
           ~pinned_bytes:parts.pinned_bytes
           messages)
    | Some _, Error _ | None, Ok _ | None, Error _ -> None
  in
  { runtime_id
  ; window
  ; capacity
  ; request_cap_bytes = request_cap_for ~runtime_id runtime
  ; parts
  ; history_atoms
  ; cut
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
             [ candidate ~config ~keeper_name ~messages ~history_atoms runtime_id ]
         })
;;

let history_cut_to_json = function
  | Cut { kept_atoms; transmitted_bytes; fit } ->
    `Assoc
      [ "kind", `String "cut"
      ; "kept_atoms", `Int kept_atoms
      ; "transmitted_bytes", `Int transmitted_bytes
      ; ( "fit"
        , match fit with
          | Runtime_model_input_tail_window.Within_target ->
            `Assoc [ "kind", `String "within_target" ]
          | Runtime_model_input_tail_window.Overrun { by_bytes; cause } ->
            `Assoc
              [ "kind", `String "overrun"
              ; "by_bytes", `Int by_bytes
              ; ( "cause"
                , `String
                    (match cause with
                     | Runtime_model_input_tail_window.Fixed_parts_exceed_target ->
                       "fixed_parts_exceed_target"
                     | Runtime_model_input_tail_window.Newest_atom_exceeds_target ->
                       "newest_atom_exceeds_target") )
              ] )
      ]
  | Newest_atom_only { transmitted_bytes } ->
    `Assoc
      [ "kind", `String "newest_atom_only"
      ; "kept_atoms", `Int 1
      ; "transmitted_bytes", `Int transmitted_bytes
      ]
;;

let option_json to_json = function
  | None -> `Null
  | Some value -> to_json value
;;

let candidate_to_json candidate =
  `Assoc
    [ "runtime_id", `String candidate.runtime_id
    ; ( "window"
      , match candidate.window with
        | Ok window -> Keeper_context_window.to_json window
        | Error (Contradiction _ as refusal) ->
          `Assoc [ "error", `String (window_refusal_to_string refusal) ]
        | Error (Not_agent_core _ as refusal) ->
          `Assoc [ "not_applicable", `String (window_refusal_to_string refusal) ] )
    ; "capacity", option_json Keeper_context_window.capacity_to_json candidate.capacity
    ; "request_cap_bytes", option_json (fun n -> `Int n) candidate.request_cap_bytes
    ; ( "parts"
      , match candidate.parts with
        | Ok parts ->
          `Assoc
            [ "reserved_measured_on_turn", `Int parts.reserved_turn
            ; "reserved_bytes", `Int parts.reserved_bytes
            ; "pinned_measured_on_turn", `Int parts.pinned_turn
            ; "pinned_bytes", `Int parts.pinned_bytes
            ]
        | Error refusal -> `Assoc [ "error", `String (parts_refusal_to_string refusal) ] )
    ; "history_atoms", `Int candidate.history_atoms
    ; "cut", option_json history_cut_to_json candidate.cut
    ]
;;

let to_json forecast =
  `Assoc
    [ "schema", `String "masc.keeper.next-request-forecast.v1"
    ; "keeper", `String forecast.keeper
    ; "trace_id", `String forecast.trace_id
    ; "checkpoint_messages", `Int forecast.checkpoint_messages
    ; "wake_line_bytes", `Int forecast.wake_line_bytes
    ; "candidates", `List (List.map candidate_to_json forecast.candidates)
    ]
;;
