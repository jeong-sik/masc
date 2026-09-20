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
   no completed first round on its bound lane and 78 on claude_code.

   Beside the figures, the layout: the same parts in the order the request
   carries them, so an operator reads what travels first and what last
   rather than which producer is largest. *)

type measured_parts =
  { reserved_turn : int
  ; reserved_bytes : int
  ; instructions_bytes : int
  ; schemas_bytes : int
  ; pinned_turn : int
  ; pinned_runtime_id : string
  ; pinned_bytes : int
  ; pinned_blocks : (Prompt_block_id.t * int) list
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
  ; preamble_bytes : int option
  ; origin : Keeper_carried_front.origin
  ; counted_tokens : int option
  }

type slot =
  | System_prompt of { bytes : int }
  | Tools of { bytes : int }
  | Preamble of { bytes : int }
  | History of { atoms : int; of_atoms : int; bytes : int }
  | Wake_line of { bytes : int }
  | System_context of { bytes : int; blocks : (Prompt_block_id.t * int) list }

type place =
  { walks_at : int
  ; declared_at : int option
  ; rest : Keeper_turn_driver.path_rest
  }

type walk =
  { lane_id : string
  ; declared : string list
  }

type walk_refusal = Keeper_turn_driver.assignment_refusal

let walk_refusal_to_string = Keeper_turn_driver.assignment_refusal_to_string

type candidate =
  { runtime_id : string
  ; lane : (unit, lane_refusal) result
  ; marks : Runtime_schema.context_marks option
  ; parts : (measured_parts, parts_refusal) result
  ; history_atoms : int
  ; carried : carried option
  ; assembly : slot list option
  ; place : place
  }

let declared_at ~declared runtime_id =
  let rec go index = function
    | [] -> None
    | id :: rest -> if String.equal id runtime_id then Some index else go (index + 1) rest
  in
  go 0 declared
;;

type t =
  { keeper : string
  ; trace_id : string
  ; checkpoint_messages : int
  ; wake_line_bytes : int
  ; walk : (walk, walk_refusal) result
  ; candidates : candidate list
  }


let measure (message : Agent_core.Types.message) =
  String.length
    (Yojson.Safe.to_string (Keeper_context_core.message_to_json message))
;;

let carry ~measure ~front ~counted_tokens messages =
  let _labelled, atom_count = Runtime_model_input_tail_window.annotate messages in
  let digest_at = Runtime_model_input_tail_window.atom_opening_digest messages in
  let first_atom, origin, counted_tokens =
    match Option.map (Keeper_carried_front.for_history ~digest_at) front with
    | Some (Ok (seed : Keeper_carried_front.seed)) ->
      ( Keeper_carried_front.clamp ~atom_count seed.first_atom
      , Keeper_carried_front.Carried seed.source
      , counted_tokens )
    | Some (Error (Keeper_carried_front.Front_atom_missing | Keeper_carried_front.Front_message_differs))
    | None -> 0, Keeper_carried_front.Whole_history, None
  in
  let projection, transmitted_bytes =
    Runtime_model_input_tail_window.project_from_atom
      ~measure_message_bytes:measure
      ~first_atom
      messages
  in
  (* The preamble is in the projected list only when the range opens on a
     message that cannot open a conversation; measured with the same encoder
     so it can be taken back out of [transmitted_bytes]. *)
  let preamble_bytes =
    List.find_map
      (fun message ->
        if Runtime_model_input_tail_window.is_synthetic_preamble message
        then Some (measure message)
        else None)
      projection.Runtime_model_input_tail_window.messages
  in
  { first_atom = projection.Runtime_model_input_tail_window.dropped_atoms
  ; kept_atoms =
      projection.Runtime_model_input_tail_window.atom_count
      - projection.Runtime_model_input_tail_window.dropped_atoms
  ; transmitted_bytes
  ; preamble_bytes
  ; origin
  ; counted_tokens
  }
;;

(* The request in travel order. The system prompt and the tool array are
   request fields beside the messages; among the messages the preamble comes
   first when the range prepended one, then the carried atoms oldest first,
   then the wake line as the newest atom, and last the "[system context]"
   message [Agent_turn.prepare_messages] appends so the conversation prefix
   stays byte-identical for provider caches. The wake line is the newest of
   the carried atoms and the range always carries it, so it is taken out of
   the history slot on both counts. *)
let assembly ~wake_bytes ~history_atoms (parts : measured_parts) (carried : carried) =
  let preamble, preamble_bytes =
    match carried.preamble_bytes with
    | Some bytes -> Some (Preamble { bytes }), bytes
    | None -> None, 0
  in
  [ Some (System_prompt { bytes = parts.instructions_bytes })
  ; Some (Tools { bytes = parts.schemas_bytes })
  ; preamble
  ; Some
      (History
         { atoms = carried.kept_atoms - 1
         ; of_atoms = history_atoms - 1
         ; bytes = carried.transmitted_bytes - preamble_bytes - wake_bytes
         })
  ; Some (Wake_line { bytes = wake_bytes })
  ; Some (System_context { bytes = parts.pinned_bytes; blocks = parts.pinned_blocks })
  ]
  |> List.filter_map Fun.id
;;

(* Whether the turn driver would compose a range for this runtime at all.
   An official-client runtime carries none: the spawned client owns its
   context. *)
let lane_for ~runtime_id (runtime : Runtime.t option) =
  match Keeper_carried_front.composer_of_runtime runtime with
  | Keeper_carried_front.Not_materialized -> Error (Not_materialized { runtime_id })
  | Keeper_carried_front.Hands_over_its_own_list -> Error (Not_agent_core { runtime_id })
  | Keeper_carried_front.Composes_from_the_history -> Ok ()
;;

type composition =
  { fixed_bytes : int
  ; instructions_bytes : int
  ; schemas_bytes : int
  ; first_round_pinned_bytes : int option
  ; pinned_blocks : (Prompt_block_id.t * int) list
  }

(* Keeper instructions ride in the system prompt and every other prompt
   block rides as pinned extra system context; the message kinds are the
   history the range decides about and belong to neither. A composition is a
   first round's when it carries a block the post-tool assembly drops; the
   predicate is the assembly's own, and so is the block order: the assembly
   stable-sorts by [Prompt_block_id.cache_rank]. *)
let read_composition (components : Turn_record.input_component list) =
  let instructions, schemas, blocks_reversed, first_round =
    List.fold_left
      (fun (instructions, schemas, blocks, first_round)
           (component : Turn_record.input_component) ->
        match component.Turn_record.component with
        | Turn_record.Tool_schemas ->
          instructions, schemas + component.bytes, blocks, first_round
        | Turn_record.Prompt_block Prompt_block_id.Keeper_instructions ->
          instructions + component.bytes, schemas, blocks, first_round
        | Turn_record.Prompt_block id ->
          ( instructions
          , schemas
          , (id, component.bytes) :: blocks
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
        | Turn_record.Message_audio -> instructions, schemas, blocks, first_round)
      (0, 0, [], false)
      components
  in
  let pinned_blocks =
    List.stable_sort
      (fun (left, _) (right, _) ->
        Int.compare (Prompt_block_id.cache_rank left) (Prompt_block_id.cache_rank right))
      (List.rev blocks_reversed)
  in
  let pinned = List.fold_left (fun sum (_, bytes) -> sum + bytes) 0 pinned_blocks in
  { fixed_bytes = instructions + schemas
  ; instructions_bytes = instructions
  ; schemas_bytes = schemas
  ; first_round_pinned_bytes = (if first_round then Some pinned else None)
  ; pinned_blocks = (if first_round then pinned_blocks else [])
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
           then Some (reading.turn, reading.composition)
           else newest_fixed)
        , match reading.composition.first_round_pinned_bytes with
          | Some pinned ->
            Some (reading.turn, reading.runtime_id, pinned, reading.composition.pinned_blocks)
          | None -> newest_pinned ))
      (None, None)
      readings
  in
  match newest_fixed, newest_pinned with
  | Some (reserved_turn, fixed), Some (pinned_turn, pinned_runtime_id, pinned_bytes, pinned_blocks)
    ->
    Ok
      { reserved_turn
      ; reserved_bytes = fixed.fixed_bytes
      ; instructions_bytes = fixed.instructions_bytes
      ; schemas_bytes = fixed.schemas_bytes
      ; pinned_turn
      ; pinned_runtime_id
      ; pinned_bytes
      ; pinned_blocks
      }
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
(* The records that parse, and how many lines were read for them: a
   refusal names the count read, a line that does not parse included. *)
let records_of_store ~config ~keeper_name =
  let store = Keeper_types_support.keeper_turn_record_store config keeper_name in
  let lines = Dated_jsonl.read_recent store recent_records_read in
  ( List.filter_map
      (fun json ->
        match Turn_record.of_json json with
        | Error _ -> None
        | Ok record -> Some record)
      lines
  , List.length lines )
;;

let readings_of_records (records : Turn_record.t list) =
  List.filter_map
    (fun (record : Turn_record.t) ->
      match record.Turn_record.input_components with
      | None -> None
      | Some components ->
        Some
          { turn = record.Turn_record.absolute_turn
          ; runtime_id = record_runtime record
          ; completed = Option.is_some record.Turn_record.finish_reason
          ; composition = read_composition components
          })
    records
;;

(* The wake line as the range's encoder counts it, the same figure the
   assembly subtracts from the transmitted bytes. *)
let wake_line () =
  let message =
    { Agent_core.Types.role = Agent_core.Types.User
    ; content = [ Agent_core.Types.Text Env_config_keeper.KeeperAutonomous.default_wake_prompt ]
    ; name = None
    ; tool_call_id = None
    ; metadata = []
    }
  in
  message, measure message
;;

let candidate
      ~keeper_name
      ~trace_id
      ~messages
      ~digest_at
      ~history_atoms
      ~wake_bytes
      ~readings
      ~records_read
      ~seed
      ~place
      runtime_id
  =
  let runtime = Runtime.get_runtime_by_id runtime_id in
  let lane = lane_for ~runtime_id runtime in
  let marks = Runtime.context_marks_of_runtime_id runtime_id in
  let parts = select_parts ~runtime_id ~records_read readings in
  let carried =
    match lane with
    | Error _ -> None
    | Ok () ->
      (* Apply the driver's boundary policy to a local value; the Table
         remains the observation the next real turn will read. If this
         history no longer holds its positions, use the seed the newest
         completed Agent Core record on the trace gives every candidate alike.
         The forecast only reads: a ledger that does not hold is passed over
         here and dropped by the turn driver's next composition. *)
      let front, counted_tokens =
        match
          Keeper_model_input_ledger.Table.lookup ~keeper_name ~runtime_id ~session_id:trace_id
        with
        | Some ledger when Keeper_model_input_ledger.holds ~digest_at ledger ->
          let projected =
            match marks with
            | None -> ledger
            | Some marks -> fst (Keeper_carried_range.apply_turn_boundary ~marks ledger)
          in
          Keeper_carried_front.of_ledger projected, ledger.Keeper_model_input_ledger.total_tokens
        | Some _ | None -> seed, None
      in
      Some
        (carry
           ~measure:(Keeper_context_core.message_measurer ())
           ~front
           ~counted_tokens
           messages)
  in
  let assembly =
    match parts, carried with
    | Ok parts, Some carried -> Some (assembly ~wake_bytes ~history_atoms parts carried)
    | Error _, _ | Ok _, None -> None
  in
  { runtime_id
  ; lane
  ; marks
  ; parts
  ; history_atoms
  ; carried
  ; assembly
  ; place
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
       let digest_at = Runtime_model_input_tail_window.atom_opening_digest messages in
       let assignment_id = Keeper_meta_contract.runtime_id_of_meta meta in
       (* NDT-OK: one wall-clock read at the boundary, compared with stored expiries. *)
       let now = Unix.gettimeofday () in
       let records, records_read = records_of_store ~config ~keeper_name in
       let readings = readings_of_records records in
       let seed =
         Keeper_carried_front.of_records
           ~composer:(fun runtime_id ->
             Keeper_carried_front.composer_of_runtime (Runtime.get_runtime_by_id runtime_id))
           ~trace_id
           records
       in
       let walk, candidates =
         match Keeper_turn_driver.assignment_walk_order ~now assignment_id with
         | Error refusal -> Error refusal, []
         | Ok { Keeper_turn_driver.lane_id; declared; order } ->
           ( Ok { lane_id; declared }
           , List.mapi
               (fun walks_at runtime_id ->
                  candidate
                    ~keeper_name
                    ~trace_id
                    ~messages
                    ~digest_at
                    ~history_atoms
                    ~wake_bytes:wake_line_bytes
                    ~readings
                    ~records_read
                    ~seed
                    ~place:
                      { walks_at
                      ; declared_at = declared_at ~declared runtime_id
                      ; rest = Keeper_turn_driver.path_rest ~now runtime_id
                      }
                    runtime_id)
               order )
       in
       Ok
         { keeper = keeper_name
         ; trace_id
         ; checkpoint_messages = List.length history
         ; wake_line_bytes
         ; walk
         ; candidates
         })
;;

let option_json to_json = function
  | None -> `Null
  | Some value -> to_json value
;;

let blocks_to_json blocks =
  `List
    (List.map
       (fun (id, bytes) ->
         `Assoc [ "block", `String (Prompt_block_id.to_string id); "bytes", `Int bytes ])
       blocks)
;;

let slot_to_json = function
  | System_prompt { bytes } -> `Assoc [ "slot", `String "system_prompt"; "bytes", `Int bytes ]
  | Tools { bytes } -> `Assoc [ "slot", `String "tools"; "bytes", `Int bytes ]
  | Preamble { bytes } -> `Assoc [ "slot", `String "preamble"; "bytes", `Int bytes ]
  | History { atoms; of_atoms; bytes } ->
    `Assoc
      [ "slot", `String "history"
      ; "atoms", `Int atoms
      ; "of_atoms", `Int of_atoms
      ; "bytes", `Int bytes
      ]
  | Wake_line { bytes } -> `Assoc [ "slot", `String "wake_line"; "bytes", `Int bytes ]
  | System_context { bytes; blocks } ->
    `Assoc
      [ "slot", `String "system_context"; "bytes", `Int bytes; "blocks", blocks_to_json blocks ]
;;

let carried_to_json (carried : carried) =
  `Assoc
    [ "first_atom", `Int carried.first_atom
    ; "kept_atoms", `Int carried.kept_atoms
    ; "transmitted_bytes", `Int carried.transmitted_bytes
    ; "preamble_bytes", option_json (fun n -> `Int n) carried.preamble_bytes
    ; "origin", Keeper_carried_front.origin_to_json carried.origin
    ; "counted_tokens", option_json (fun n -> `Int n) carried.counted_tokens
    ]
;;

let place_to_json (place : place) =
  `Assoc
    [ "walks_at", `Int place.walks_at
    ; "declared_at", option_json (fun n -> `Int n) place.declared_at
    ; ( "rest"
      , match place.rest with
        | Keeper_turn_driver.Path_serving -> `Assoc [ "kind", `String "serving" ]
        | Keeper_turn_driver.Path_resting { release_at; walk_promotes_at_release } ->
          `Assoc
            [ "kind", `String "resting"
            ; "release_at", `Float release_at
            ; "walk_promotes_at_release", `Bool walk_promotes_at_release
            ] )
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
        | Ok (parts : measured_parts) ->
          `Assoc
            [ "reserved_measured_on_turn", `Int parts.reserved_turn
            ; "reserved_bytes", `Int parts.reserved_bytes
            ; "instructions_bytes", `Int parts.instructions_bytes
            ; "schemas_bytes", `Int parts.schemas_bytes
            ; "pinned_measured_on_turn", `Int parts.pinned_turn
            ; "pinned_measured_on_runtime", `String parts.pinned_runtime_id
            ; "pinned_bytes", `Int parts.pinned_bytes
            ; "pinned_blocks", blocks_to_json parts.pinned_blocks
            ]
        | Error refusal -> `Assoc [ "error", `String (parts_refusal_to_string refusal) ] )
    ; "history_atoms", `Int candidate.history_atoms
    ; "carried", option_json carried_to_json candidate.carried
    ; ( "assembly"
      , option_json (fun slots -> `List (List.map slot_to_json slots)) candidate.assembly )
    ; "place", place_to_json candidate.place
    ]
;;

let walk_to_json (walk : walk) =
  `Assoc
    [ "lane_id", `String walk.lane_id
    ; "declared", `List (List.map (fun id -> `String id) walk.declared)
    ]
;;

let to_json forecast =
  `Assoc
    [ "schema", `String "masc.keeper.next-request-forecast.v5"
    ; "keeper", `String forecast.keeper
    ; "trace_id", `String forecast.trace_id
    ; "checkpoint_messages", `Int forecast.checkpoint_messages
    ; "wake_line_bytes", `Int forecast.wake_line_bytes
    ; ( "walk"
      , match forecast.walk with
        | Ok walk -> walk_to_json walk
        | Error refusal -> `Assoc [ "refusal", `String (walk_refusal_to_string refusal) ] )
    ; "candidates", `List (List.map candidate_to_json forecast.candidates)
    ]
;;
