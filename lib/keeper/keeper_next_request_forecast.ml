(* Keeper_next_request_forecast — what the next Agent Core request would
   carry, computed from the same values a turn uses, without a turn.

   The arithmetic is the turn driver's (RFC keeper-context-window-in-tokens
   §10.3): capacity B = W × density, history room A = B − R − pinned, and the
   cut is [Runtime_model_input_tail_window.project_target] on the durable
   history with the wake line appended as the newest atom. W, the density
   and the request-body cap are read live; R (tool schemas + keeper
   instructions) and the pinned blocks (memory recall, dynamic context, ...)
   are taken from the newest turn record on the same runtime whose
   composition is a first round's, because a turn measures them with the
   encoder the cut uses and nothing outside a turn assembles them without
   side effects (a preview would consume the operator note and advance
   nothing else it should). A record describes the turn's latest request; a
   post-tool round drops every block [Prompt_block_id.injected_on_post_tool_round]
   refuses, so such a record shows the pinned blocks as absent when the next
   first round will carry them. The record's turn number rides along so a
   reader knows how old those two figures are. *)

type measured_parts =
  { turn : int
  ; reserved_bytes : int
  ; pinned_bytes : int
  }

type parts_refusal =
  | No_composition_on_runtime of { records_read : int }
  | No_first_round_composition of { records_read : int; newest_turn : int }

let parts_refusal_to_string = function
  | No_composition_on_runtime { records_read } ->
    Printf.sprintf
      "no turn record on this runtime carried a composition in the newest %d records"
      records_read
  | No_first_round_composition { records_read; newest_turn } ->
    Printf.sprintf
      "the newest %d turn records on this runtime carry only post-tool compositions \
       (newest turn #%d); the pinned blocks ride the first round only"
      records_read
      newest_turn
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
  ; window : (Keeper_context_window.t, string) result
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
   named rather than clamped. *)
let window_for ~runtime_id =
  let window_tokens = Keeper_runtime_resolved.context_window_tokens () in
  match Runtime.max_context_of_runtime_id runtime_id with
  | Some max_context when window_tokens > max_context ->
    Error
      (Printf.sprintf
         "turn.context_window_tokens %d exceeds the %d-token max-context of %s"
         window_tokens
         max_context
         runtime_id)
  | Some _ -> Ok (Keeper_context_window.declared ~window_tokens)
  | None -> Error (Printf.sprintf "runtime %s resolves no context window" runtime_id)
;;

(* The cap the driver judges the body against, read from the materialized
   runtime the way [Runtime.keeper_dispatch_readiness] reads it. Only an
   Agent Core runtime builds the request this bounds. *)
let request_cap_for ~runtime_id =
  match Runtime.get_runtime_by_id runtime_id with
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

(* A composition is a first round's when it carries a block the post-tool
   assembly drops; the predicate is the assembly's own. *)
let is_first_round (components : Turn_record.input_component list) =
  List.exists
    (fun (component : Turn_record.input_component) ->
      match component.Turn_record.component with
      | Turn_record.Prompt_block id -> not (Prompt_block_id.injected_on_post_tool_round id)
      | Turn_record.Tool_schemas
      | Turn_record.Message_user
      | Turn_record.Message_system
      | Turn_record.Message_assistant_text
      | Turn_record.Message_thinking
      | Turn_record.Message_redacted_thinking
      | Turn_record.Message_tool_use
      | Turn_record.Message_tool_result
      | Turn_record.Message_image
      | Turn_record.Message_document
      | Turn_record.Message_audio -> false)
    components
;;

(* R and the pinned blocks as one first-round composition measured them.
   Keeper instructions ride in the system prompt and every other prompt
   block rides as pinned extra system context; the message kinds are the
   history the cut decides about and belong to neither. *)
let first_round_parts ~turn (components : Turn_record.input_component list) =
  if not (is_first_round components)
  then None
  else (
    let reserved, pinned =
      List.fold_left
        (fun (reserved, pinned) (component : Turn_record.input_component) ->
          match component.Turn_record.component with
          | Turn_record.Tool_schemas -> reserved + component.bytes, pinned
          | Turn_record.Prompt_block Prompt_block_id.Keeper_instructions ->
            reserved + component.bytes, pinned
          | Turn_record.Prompt_block _ -> reserved, pinned + component.bytes
          | Turn_record.Message_user
          | Turn_record.Message_system
          | Turn_record.Message_assistant_text
          | Turn_record.Message_thinking
          | Turn_record.Message_redacted_thinking
          | Turn_record.Message_tool_use
          | Turn_record.Message_tool_result
          | Turn_record.Message_image
          | Turn_record.Message_document
          | Turn_record.Message_audio -> reserved, pinned)
        (0, 0)
        components
    in
    Some { turn; reserved_bytes = reserved; pinned_bytes = pinned })
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

let newest_parts_for ~config ~keeper_name ~runtime_id =
  let store = Keeper_types_support.keeper_turn_record_store config keeper_name in
  let records = Dated_jsonl.read_recent store recent_records_read in
  let records_read = List.length records in
  (* Oldest first; each fold step keeps the newer answer. *)
  let found, newest_composed_turn =
    List.fold_left
      (fun (found, newest_composed_turn) json ->
        match Turn_record.of_json json with
        | Error _ -> found, newest_composed_turn
        | Ok record ->
          if not (String.equal (record_runtime record) runtime_id)
          then found, newest_composed_turn
          else (
            match record.Turn_record.input_components with
            | None -> found, newest_composed_turn
            | Some components ->
              let turn = record.Turn_record.absolute_turn in
              ( (match first_round_parts ~turn components with
                 | Some parts -> Some parts
                 | None -> found)
              , Some turn )))
      (None, None)
      records
  in
  match found, newest_composed_turn with
  | Some parts, _ -> Ok parts
  | None, Some newest_turn -> Error (No_first_round_composition { records_read; newest_turn })
  | None, None -> Error (No_composition_on_runtime { records_read })
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
  let window = window_for ~runtime_id in
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
  ; request_cap_bytes = request_cap_for ~runtime_id
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
        | Error message -> `Assoc [ "error", `String message ] )
    ; "capacity", option_json Keeper_context_window.capacity_to_json candidate.capacity
    ; "request_cap_bytes", option_json (fun n -> `Int n) candidate.request_cap_bytes
    ; ( "parts"
      , match candidate.parts with
        | Ok parts ->
          `Assoc
            [ "measured_on_turn", `Int parts.turn
            ; "reserved_bytes", `Int parts.reserved_bytes
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
