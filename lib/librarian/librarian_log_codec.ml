open Keeper_memory_os_types
open Keeper_turn_log_wire
open Librarian_log
module Effects = Librarian_effects
module Direct = Librarian_direct
module Digest = Agent_core.Checkpoint_objects
module Log_id = Keeper_turn_log.Log_id
module Turn_codec = Keeper_turn_log_codec

let f_line = "line"
let f_kind = wire_field_kind
let f_at = "at"
let f_turn_log = "turn_log"
let f_snapshot = "snapshot"
let f_revision = "revision"
let f_turn_log_offset = "turn_log_offset"
let f_covered = "covered"
let f_seq = "seq"
let f_basis = wire_field_basis
let f_after = "after"
let f_cause = "cause"
let f_effects = "effects"
let f_covers_through = "covers_through"
let f_working_state = "working_state"
let f_by = "by"
let f_write = "write"
let f_trace = "trace"
let f_observed = "observed"
let f_name = "name"
let f_claim = wire_field_claim
let f_category = wire_field_category
let f_reason = wire_field_reason
let f_old = "old"
let f_id = "id"
let f_within = "within"
let f_store = "store"
let f_added = "added"
let f_touched = "touched"
let f_removed = "removed"
let f_not_applied = "not_applied"
let f_sources = "sources"
let f_fact = "fact"
let f_removal = "removal"
let f_into = "into"
let f_missing = "missing"
let f_op = "op"
let f_why = "why"
let f_stated = "stated"
let f_lines = "lines"
let f_question = "question"
let f_front = "front"
let f_back = "back"
let f_shown = "shown"
let f_slot = "slot"
let f_hole = "hole"
let f_before = "before"
let f_parts = "parts"
let f_slice = "slice"
let f_from = "from"
let f_until = "until"
let f_offset = "offset"
let f_sha = "sha"
let f_to = "to"
let f_length = "length"
let f_row = "row"
let f_trigger = "trigger"
let f_compacted_lines = "compacted_lines"
let f_archived_entries = "archived_entries"
let f_promotions = "promotions"

type line_kind =
  | Kind_started
  | Kind_committed

let line_kind_token = function
  | Kind_started -> "started"
  | Kind_committed -> "committed"
;;

let line_kinds = [ Kind_started; Kind_committed ]

type cause_kind =
  | Kind_direct
  | Kind_adopt
  | Kind_read
  | Kind_make_room
  | Kind_skip
  | Kind_molt_and_synthesize
  | Kind_checkpoint

let cause_kind_token = function
  | Kind_direct -> "direct"
  | Kind_adopt -> "adopt"
  | Kind_read -> "read"
  | Kind_make_room -> "make_room"
  | Kind_skip -> "skip"
  | Kind_molt_and_synthesize -> "molt_and_synthesize"
  | Kind_checkpoint -> "checkpoint"
;;

let cause_kinds =
  [ Kind_direct
  ; Kind_adopt
  ; Kind_read
  ; Kind_make_room
  ; Kind_skip
  ; Kind_molt_and_synthesize
  ; Kind_checkpoint
  ]
;;

type shown_kind =
  | Kind_shown_memory
  | Kind_shown_item_alone

let shown_kind_token = function
  | Kind_shown_memory -> "memory"
  | Kind_shown_item_alone -> "item_alone"
;;

let shown_kinds = [ Kind_shown_memory; Kind_shown_item_alone ]

let alone_working_state_token = function
  | Untouched -> "untouched"
  | Not_valid_alone -> "not_valid_alone"
;;

let alone_working_states = [ Untouched; Not_valid_alone ]

type hole_kind =
  | Kind_content_missing
  | Kind_unknown_span
  | Kind_item_exceeds_window
  | Kind_turn_log_replaced
  | Kind_position_lost
  | Kind_line_unreadable
  | Kind_operator_skipped

let hole_kind_token = function
  | Kind_content_missing -> "content_missing"
  | Kind_unknown_span -> "unknown_span"
  | Kind_item_exceeds_window -> "item_exceeds_window"
  | Kind_turn_log_replaced -> "turn_log_replaced"
  | Kind_position_lost -> "position_lost"
  | Kind_line_unreadable -> "line_unreadable"
  | Kind_operator_skipped -> "operator_skipped"
;;

let hole_kinds =
  [ Kind_content_missing
  ; Kind_unknown_span
  ; Kind_item_exceeds_window
  ; Kind_turn_log_replaced
  ; Kind_position_lost
  ; Kind_line_unreadable
  ; Kind_operator_skipped
  ]
;;

type part_kind =
  | Kind_bundle
  | Kind_history_bytes
  | Kind_internal_bytes
  | Kind_chat_bytes
  | Kind_external_rows
  | Kind_undecodable_history_line
  | Kind_undecodable_internal_line
  | Kind_undecodable_external_row

let part_kind_token = function
  | Kind_bundle -> "bundle"
  | Kind_history_bytes -> "history_bytes"
  | Kind_internal_bytes -> "internal_bytes"
  | Kind_chat_bytes -> "chat_bytes"
  | Kind_external_rows -> "external_rows"
  | Kind_undecodable_history_line -> "undecodable_history_line"
  | Kind_undecodable_internal_line -> "undecodable_internal_line"
  | Kind_undecodable_external_row -> "undecodable_external_row"
;;

let part_kinds =
  [ Kind_bundle
  ; Kind_history_bytes
  ; Kind_internal_bytes
  ; Kind_chat_bytes
  ; Kind_external_rows
  ; Kind_undecodable_history_line
  ; Kind_undecodable_internal_line
  ; Kind_undecodable_external_row
  ]
;;

type actor_kind =
  | Kind_keeper
  | Kind_operator

let actor_kind_token = function
  | Kind_keeper -> "keeper"
  | Kind_operator -> "operator"
;;

let actor_kinds = [ Kind_keeper; Kind_operator ]

type write_kind =
  | Kind_remember
  | Kind_supersede
  | Kind_retract

let write_kind_token = function
  | Kind_remember -> "remember"
  | Kind_supersede -> "supersede"
  | Kind_retract -> "retract"
;;

let write_kinds = [ Kind_remember; Kind_supersede; Kind_retract ]

type position_kind =
  | Kind_before_first
  | Kind_through

let position_kind_token = function
  | Kind_before_first -> "before_first"
  | Kind_through -> "through"
;;

let position_kinds = [ Kind_before_first; Kind_through ]

type within_kind =
  | Kind_whole
  | Kind_item

let within_kind_token = function
  | Kind_whole -> "whole"
  | Kind_item -> "item"
;;

let within_kinds = [ Kind_whole; Kind_item ]

let store_token : Librarian_unit.store -> string = function
  | Chat -> "chat"
  | External -> "external"
  | Agent_core -> "agent_core"
  | History -> "history"
  | Internal -> "internal"
;;

let store_of_token token =
  List.find_opt (fun store -> String.equal (store_token store) token) Librarian_unit.stores
;;

type removal_kind =
  | Kind_dropped
  | Kind_merged_into
  | Kind_revised_into
  | Kind_superseded_by
  | Kind_retracted
  | Kind_support_lost
  | Kind_molted

let removal_kind_token = function
  | Kind_dropped -> "dropped"
  | Kind_merged_into -> "merged_into"
  | Kind_revised_into -> "revised_into"
  | Kind_superseded_by -> "superseded_by"
  | Kind_retracted -> "retracted"
  | Kind_support_lost -> "support_lost"
  | Kind_molted -> "molted"
;;

let removal_kinds =
  [ Kind_dropped
  ; Kind_merged_into
  ; Kind_revised_into
  ; Kind_superseded_by
  ; Kind_retracted
  ; Kind_support_lost
  ; Kind_molted
  ]
;;

type why_kind =
  | Kind_unknown_ref
  | Kind_ref_used_twice
  | Kind_source_outside_question
  | Kind_removed_during_flight
  | Kind_not_valid_alone
  | Kind_not_valid_in_room
  | Kind_successor_unsupported
  | Kind_promotion_refused

let why_kind_of : Effects.why_not -> why_kind = function
  | Unknown_ref -> Kind_unknown_ref
  | Ref_used_twice -> Kind_ref_used_twice
  | Source_outside_question -> Kind_source_outside_question
  | Removed_during_flight { seq = (_ : int) } -> Kind_removed_during_flight
  | Not_valid_alone -> Kind_not_valid_alone
  | Not_valid_in_room -> Kind_not_valid_in_room
  | Successor_unsupported -> Kind_successor_unsupported
  | Promotion_refused -> Kind_promotion_refused
;;

(* The token a line carries is the one a metric label carries. *)
let why_kind_token = function
  | Kind_unknown_ref -> Effects.why_not_kind Unknown_ref
  | Kind_ref_used_twice -> Effects.why_not_kind Ref_used_twice
  | Kind_source_outside_question -> Effects.why_not_kind Source_outside_question
  | Kind_removed_during_flight -> Effects.why_not_kind (Removed_during_flight { seq = 0 })
  | Kind_not_valid_alone -> Effects.why_not_kind Not_valid_alone
  | Kind_not_valid_in_room -> Effects.why_not_kind Not_valid_in_room
  | Kind_successor_unsupported -> Effects.why_not_kind Successor_unsupported
  | Kind_promotion_refused -> Effects.why_not_kind Promotion_refused
;;

let why_kinds =
  [ Kind_unknown_ref
  ; Kind_ref_used_twice
  ; Kind_source_outside_question
  ; Kind_removed_during_flight
  ; Kind_not_valid_alone
  ; Kind_not_valid_in_room
  ; Kind_successor_unsupported
  ; Kind_promotion_refused
  ]
;;

let kind token = f_kind, `String token
let digest_json (digest : Digest.digest) = `String (digest :> string)
let ids_json ids = `List (List.map (fun id -> `String id) ids)

let actor_to_json : Effects.actor -> Yojson.Safe.t = function
  | Keeper -> `Assoc [ kind (actor_kind_token Kind_keeper) ]
  | Operator name -> `Assoc [ kind (actor_kind_token Kind_operator); f_name, `String name ]
;;

let stated_fields ~claim ~category ~basis =
  [ f_claim, `String claim
  ; f_category, `String (category_to_string category)
  ; f_basis, basis_to_json basis
  ]
;;

let write_to_json : Direct.write -> Yojson.Safe.t = function
  | Remember { claim; category; basis } ->
    `Assoc (kind (write_kind_token Kind_remember) :: stated_fields ~claim ~category ~basis)
  | Supersede { old; claim; category; basis } ->
    `Assoc
      (kind (write_kind_token Kind_supersede)
       :: (f_old, `String old)
       :: stated_fields ~claim ~category ~basis)
  | Retract { id; reason } ->
    `Assoc [ kind (write_kind_token Kind_retract); f_id, `String id; f_reason, `String reason ]
;;

let question_to_json (question : Librarian_question_id.t) =
  `Assoc [ f_front, `String question.front; f_back, `String question.back ]
;;

let range_fields ({ from; until } : Librarian_unit.range) =
  [ f_from, `Int from; f_until, `Int until ]
;;

let part_to_json : Librarian_unit.missing_part -> Yojson.Safe.t = function
  | Bundle slice ->
    `Assoc [ kind (part_kind_token Kind_bundle); f_slice, Turn_codec.slice_to_json slice ]
  | History_bytes range -> `Assoc (kind (part_kind_token Kind_history_bytes) :: range_fields range)
  | Internal_bytes range ->
    `Assoc (kind (part_kind_token Kind_internal_bytes) :: range_fields range)
  | Chat_bytes range -> `Assoc (kind (part_kind_token Kind_chat_bytes) :: range_fields range)
  | External_rows range -> `Assoc (kind (part_kind_token Kind_external_rows) :: range_fields range)
  | Undecodable_history_line { offset } ->
    `Assoc [ kind (part_kind_token Kind_undecodable_history_line); f_offset, `Int offset ]
  | Undecodable_internal_line { offset } ->
    `Assoc [ kind (part_kind_token Kind_undecodable_internal_line); f_offset, `Int offset ]
  | Undecodable_external_row { row } ->
    `Assoc [ kind (part_kind_token Kind_undecodable_external_row); f_row, `Int row ]
;;

let missing_to_json missing =
  `List
    (List.map
       (fun ({ line; parts } : Librarian_unit.missing_at) ->
          `Assoc [ f_line, `Int line; f_parts, `List (List.map part_to_json parts) ])
       missing)
;;

let hole_to_json = function
  | Content_missing missing ->
    `Assoc [ kind (hole_kind_token Kind_content_missing); f_missing, missing_to_json missing ]
  | Unknown_span { before; after } ->
    `Assoc
      [ kind (hole_kind_token Kind_unknown_span)
      ; f_before, Turn_codec.mark_to_json before
      ; f_after, Turn_codec.mark_to_json after
      ]
  | Item_exceeds_window missing ->
    `Assoc [ kind (hole_kind_token Kind_item_exceeds_window); f_missing, missing_to_json missing ]
  | Turn_log_replaced { from; to_ } ->
    `Assoc
      [ kind (hole_kind_token Kind_turn_log_replaced)
      ; f_from, `String (Log_id.to_string from)
      ; f_to, `String (Log_id.to_string to_)
      ]
  | Position_lost { offset; length } ->
    `Assoc
      [ kind (hole_kind_token Kind_position_lost); f_offset, `Int offset; f_length, `Int length ]
  | Line_unreadable { offset; sha } ->
    `Assoc
      [ kind (hole_kind_token Kind_line_unreadable); f_offset, `Int offset; f_sha, digest_json sha ]
  | Operator_skipped { by; missing } ->
    `Assoc
      [ kind (hole_kind_token Kind_operator_skipped)
      ; f_by, `String by
      ; f_missing, missing_to_json missing
      ]
;;

let shown_to_json = function
  | With_memory -> `Assoc [ kind (shown_kind_token Kind_shown_memory) ]
  | Item_alone working_state ->
    `Assoc
      [ kind (shown_kind_token Kind_shown_item_alone)
      ; f_working_state, `String (alone_working_state_token working_state)
      ]
;;

let cause_to_json = function
  | Direct { by; trace; write } ->
    `Assoc
      [ kind (cause_kind_token Kind_direct)
      ; f_by, actor_to_json by
      ; f_trace, `String trace
      ; f_write, write_to_json write
      ]
  | Adopt { by; observed } ->
    `Assoc
      [ kind (cause_kind_token Kind_adopt); f_by, `String by; f_observed, digest_json observed ]
  | Read { question; shown; slot; trace; missing } ->
    `Assoc
      [ kind (cause_kind_token Kind_read)
      ; f_question, question_to_json question
      ; f_shown, shown_to_json shown
      ; f_slot, `String slot
      ; f_trace, `String trace
      ; f_missing, missing_to_json missing
      ]
  | Make_room { question; slot; trace } ->
    `Assoc
      [ kind (cause_kind_token Kind_make_room)
      ; f_question, question_to_json question
      ; f_slot, `String slot
      ; f_trace, `String trace
      ]
  | Skip { hole } -> `Assoc [ kind (cause_kind_token Kind_skip); f_hole, hole_to_json hole ]
  | Molt_and_synthesize { question; slot; trace; trigger } ->
    `Assoc
      [ kind (cause_kind_token Kind_molt_and_synthesize)
      ; f_question, question_to_json question
      ; f_slot, `String slot
      ; f_trace, `String trace
      ; f_trigger, Librarian_lifecycle.molt_trigger_to_json trigger
      ]
  | Checkpoint { compacted_lines; archived_entries } ->
    `Assoc
      [ kind (cause_kind_token Kind_checkpoint)
      ; f_compacted_lines, `Int compacted_lines
      ; f_archived_entries, `Int archived_entries
      ]
;;

let within_to_json = function
  | Whole -> `Assoc [ kind (within_kind_token Kind_whole) ]
  | Item { store; at } ->
    `Assoc
      [ kind (within_kind_token Kind_item); f_store, `String (store_token store); f_at, `Int at ]
;;

let position_to_json = function
  | Before_first -> `Assoc [ kind (position_kind_token Kind_before_first) ]
  | Through { line; within } ->
    `Assoc
      [ kind (position_kind_token Kind_through)
      ; f_line, `Int line
      ; f_within, within_to_json within
      ]
;;

let removal_to_json : Effects.removal -> Yojson.Safe.t = function
  | Dropped { reason } ->
    `Assoc [ kind (removal_kind_token Kind_dropped); f_reason, `String reason ]
  | Merged_into successor ->
    `Assoc [ kind (removal_kind_token Kind_merged_into); f_into, `String successor ]
  | Revised_into successor ->
    `Assoc [ kind (removal_kind_token Kind_revised_into); f_into, `String successor ]
  | Superseded_by successor ->
    `Assoc [ kind (removal_kind_token Kind_superseded_by); f_by, `String successor ]
  | Retracted { by; reason } ->
    `Assoc
      [ kind (removal_kind_token Kind_retracted)
      ; f_by, actor_to_json by
      ; f_reason, `String reason
      ]
  | Support_lost { missing } ->
    `Assoc [ kind (removal_kind_token Kind_support_lost); f_missing, ids_json missing ]
  | Molted { reason } ->
    `Assoc [ kind (removal_kind_token Kind_molted); f_reason, `String reason ]
;;

let why_to_json (why : Effects.why_not) =
  let token = kind (why_kind_token (why_kind_of why)) in
  match why with
  | Removed_during_flight { seq } -> `Assoc [ token; f_seq, `Int seq ]
  | Unknown_ref | Ref_used_twice | Source_outside_question | Not_valid_alone | Not_valid_in_room
  | Successor_unsupported | Promotion_refused -> `Assoc [ token ]
;;

let effects_to_json (effects : Effects.t) =
  `Assoc
    ([ f_added, `List (List.map fact_to_json effects.added)
    ; f_touched, ids_json effects.touched
    ; ( f_removed
      , `List
          (List.map
             (fun (fact, removal) ->
                `Assoc [ f_fact, fact_to_json fact; f_removal, removal_to_json removal ])
             effects.removed) )
    ; ( f_not_applied
      , `List
          (List.map
             (fun (op, why, stated) ->
                `Assoc
                  [ f_op, `Int op
                  ; f_why, why_to_json why
                  ; ( f_stated
                    , match stated with
                      | None -> `Null
                      | Some fact -> Librarian_answer.new_fact_to_json fact )
                  ])
             effects.not_applied) )
    ; ( f_sources
      , `List
          (List.map
             (fun (id, lines) ->
                `Assoc
                  [ f_fact, `String id
                  ; f_lines, `List (List.map (fun line -> `Int line) lines)
                  ])
             effects.sources) )
    ]
    @
    match effects.promotions with
    | [] -> []
    | promos ->
      [ f_promotions, `List (List.map Librarian_lifecycle.world_promotion_to_json promos) ])
;;

let to_json = function
  | Started { at; turn_log; snapshot; revision; turn_log_offset; covered } ->
    `Assoc
      [ f_line, `String (line_kind_token Kind_started)
      ; f_at, `Float at
      ; f_turn_log, `String (Log_id.to_string turn_log)
      ; f_snapshot, digest_json snapshot
      ; f_revision, `Int revision
      ; f_turn_log_offset, `Int turn_log_offset
      ; f_covered, Turn_codec.mark_to_json covered
      ]
  | Committed commit ->
    `Assoc
      [ f_line, `String (line_kind_token Kind_committed)
      ; f_seq, `Int commit.seq
      ; f_at, `Float commit.at
      ; f_basis, digest_json commit.basis
      ; f_after, digest_json commit.after
      ; f_revision, `Int commit.revision
      ; f_cause, cause_to_json commit.cause
      ; f_effects, effects_to_json commit.effects
      ; f_turn_log, `String (Log_id.to_string commit.turn_log)
      ; f_turn_log_offset, `Int commit.turn_log_offset
      ; f_covers_through, position_to_json commit.covers_through
      ; f_covered, Turn_codec.mark_to_json commit.covered
      ; ( f_working_state
        , match commit.working_state with
          | None -> `Null
          | Some text -> `String text )
      ]
;;

let ( let* ) = Result.bind

let count_field field fields =
  let* value = wire_int_field field fields in
  if value < 0 then wire_fail [ Wire_field field ] Negative else Ok value
;;

let object_field field fields decode =
  let* json = wire_json_field field fields in
  wire_at (Wire_field field) (decode json)
;;

let digest_field field fields =
  let* hex = wire_string_field field fields in
  match Digest.digest_of_hex hex with
  | Ok digest -> Ok digest
  | Error (_ : string) -> wire_fail [ Wire_field field ] (Unknown_token hex)
;;

let log_id_field field fields =
  let* text = wire_string_field field fields in
  match Log_id.of_string text with
  | Some id -> Ok id
  | None -> wire_fail [ Wire_field field ] (Unknown_token text)
;;

let memory_id_field field fields =
  let* text = wire_string_field field fields in
  if is_memory_id text then Ok text else wire_fail [ Wire_field field ] (Not_a_memory_id text)
;;

let memory_id_of_json = function
  | `String text -> if is_memory_id text then Ok text else wire_here (Not_a_memory_id text)
  | `Assoc _ | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null ->
    wire_here Expected_string
;;

let offset_of_json = function
  | `Int value -> if value < 0 then wire_here Negative else Ok value
  | `Assoc _ | `Bool _ | `Float _ | `Intlit _ | `List _ | `Null | `String _ ->
    wire_here Expected_int
;;

let actor_of_json json : (Effects.actor, wire_error) result =
  let* fields = object_fields json in
  let* actor = of_token ~token_of:actor_kind_token actor_kinds f_kind fields in
  match actor with
  | Kind_keeper ->
    let* () = exact_field_names_result [ f_kind ] fields in
    Ok Effects.Keeper
  | Kind_operator ->
    let* () = exact_field_names_result [ f_kind; f_name ] fields in
    let* name = wire_string_field f_name fields in
    Ok (Effects.Operator name)
;;

let category_field fields =
  let* token = wire_string_field f_category fields in
  match category_of_string token with
  | Some category -> Ok category
  | None -> wire_fail [ Wire_field f_category ] (Unknown_token token)
;;

let write_of_json json : (Direct.write, wire_error) result =
  let* fields = object_fields json in
  let* write = of_token ~token_of:write_kind_token write_kinds f_kind fields in
  match write with
  | Kind_remember ->
    let* () = exact_field_names_result [ f_kind; f_claim; f_category; f_basis ] fields in
    let* claim = wire_string_field f_claim fields in
    let* category = category_field fields in
    let* basis = object_field f_basis fields basis_of_json in
    Ok (Direct.Remember { claim; category; basis })
  | Kind_supersede ->
    let* () =
      exact_field_names_result [ f_kind; f_old; f_claim; f_category; f_basis ] fields
    in
    let* old = memory_id_field f_old fields in
    let* claim = wire_string_field f_claim fields in
    let* category = category_field fields in
    let* basis = object_field f_basis fields basis_of_json in
    Ok (Direct.Supersede { old; claim; category; basis })
  | Kind_retract ->
    let* () = exact_field_names_result [ f_kind; f_id; f_reason ] fields in
    let* id = memory_id_field f_id fields in
    let* reason = wire_string_field f_reason fields in
    Ok (Direct.Retract { id; reason })
;;

(* A half that is not one names no question; the halves are checked
   together, so the refusal names the object. *)
let question_of_json json =
  let* fields = object_fields json in
  let* () = exact_field_names_result [ f_front; f_back ] fields in
  let* front = wire_string_field f_front fields in
  let* back = wire_string_field f_back fields in
  match Librarian_question_id.of_halves ~front ~back with
  | Some question -> Ok question
  | None -> wire_here (Unknown_token (front ^ " " ^ back))
;;

let part_of_json json : (Librarian_unit.missing_part, wire_error) result =
  let* fields = object_fields json in
  let* part = of_token ~token_of:part_kind_token part_kinds f_kind fields in
  let ranged make =
    let* () = exact_field_names_result [ f_kind; f_from; f_until ] fields in
    let* from = count_field f_from fields in
    let* until = count_field f_until fields in
    Ok (make ({ from; until } : Librarian_unit.range))
  in
  let at_offset make =
    let* () = exact_field_names_result [ f_kind; f_offset ] fields in
    let* offset = count_field f_offset fields in
    Ok (make offset)
  in
  match part with
  | Kind_bundle ->
    let* () = exact_field_names_result [ f_kind; f_slice ] fields in
    let* slice = object_field f_slice fields Turn_codec.slice_of_json in
    Ok (Librarian_unit.Bundle slice)
  | Kind_history_bytes -> ranged (fun range -> Librarian_unit.History_bytes range)
  | Kind_internal_bytes -> ranged (fun range -> Librarian_unit.Internal_bytes range)
  | Kind_chat_bytes -> ranged (fun range -> Librarian_unit.Chat_bytes range)
  | Kind_external_rows -> ranged (fun range -> Librarian_unit.External_rows range)
  | Kind_undecodable_history_line ->
    at_offset (fun offset -> Librarian_unit.Undecodable_history_line { offset })
  | Kind_undecodable_internal_line ->
    at_offset (fun offset -> Librarian_unit.Undecodable_internal_line { offset })
  | Kind_undecodable_external_row ->
    let* () = exact_field_names_result [ f_kind; f_row ] fields in
    let* row = count_field f_row fields in
    Ok (Librarian_unit.Undecodable_external_row { row })
;;

let missing_at_of_json json : (Librarian_unit.missing_at, wire_error) result =
  let* fields = object_fields json in
  let* () = exact_field_names_result [ f_line; f_parts ] fields in
  let* line = count_field f_line fields in
  let* parts = list_field f_parts fields part_of_json in
  Ok { Librarian_unit.line; parts }
;;

let hole_of_json json =
  let* fields = object_fields json in
  let* hole = of_token ~token_of:hole_kind_token hole_kinds f_kind fields in
  match hole with
  | Kind_content_missing ->
    let* () = exact_field_names_result [ f_kind; f_missing ] fields in
    let* missing = list_field f_missing fields missing_at_of_json in
    Ok (Content_missing missing)
  | Kind_unknown_span ->
    let* () = exact_field_names_result [ f_kind; f_before; f_after ] fields in
    let* before = object_field f_before fields Turn_codec.mark_of_json in
    let* after = object_field f_after fields Turn_codec.mark_of_json in
    Ok (Unknown_span { before; after })
  | Kind_item_exceeds_window ->
    let* () = exact_field_names_result [ f_kind; f_missing ] fields in
    let* missing = list_field f_missing fields missing_at_of_json in
    Ok (Item_exceeds_window missing)
  | Kind_turn_log_replaced ->
    let* () = exact_field_names_result [ f_kind; f_from; f_to ] fields in
    let* from = log_id_field f_from fields in
    let* to_ = log_id_field f_to fields in
    Ok (Turn_log_replaced { from; to_ })
  | Kind_position_lost ->
    let* () = exact_field_names_result [ f_kind; f_offset; f_length ] fields in
    let* offset = count_field f_offset fields in
    let* length = count_field f_length fields in
    Ok (Position_lost { offset; length })
  | Kind_line_unreadable ->
    let* () = exact_field_names_result [ f_kind; f_offset; f_sha ] fields in
    let* offset = count_field f_offset fields in
    let* sha = digest_field f_sha fields in
    Ok (Line_unreadable { offset; sha })
  | Kind_operator_skipped ->
    let* () = exact_field_names_result [ f_kind; f_by; f_missing ] fields in
    let* by = wire_string_field f_by fields in
    let* missing = list_field f_missing fields missing_at_of_json in
    Ok (Operator_skipped { by; missing })
;;

let shown_of_json json =
  let* fields = object_fields json in
  let* shown = of_token ~token_of:shown_kind_token shown_kinds f_kind fields in
  match shown with
  | Kind_shown_memory ->
    let* () = exact_field_names_result [ f_kind ] fields in
    Ok With_memory
  | Kind_shown_item_alone ->
    let* () = exact_field_names_result [ f_kind; f_working_state ] fields in
    let* working_state =
      of_token ~token_of:alone_working_state_token alone_working_states f_working_state fields
    in
    Ok (Item_alone working_state)
;;

let cause_of_json json =
  let* fields = object_fields json in
  let* cause = of_token ~token_of:cause_kind_token cause_kinds f_kind fields in
  match cause with
  | Kind_direct ->
    let* () = exact_field_names_result [ f_kind; f_by; f_trace; f_write ] fields in
    let* by = object_field f_by fields actor_of_json in
    let* trace = wire_string_field f_trace fields in
    let* write = object_field f_write fields write_of_json in
    Ok (Direct { by; trace; write })
  | Kind_adopt ->
    let* () = exact_field_names_result [ f_kind; f_by; f_observed ] fields in
    let* by = wire_string_field f_by fields in
    let* observed = digest_field f_observed fields in
    Ok (Adopt { by; observed })
  | Kind_read ->
    let* () =
      exact_field_names_result [ f_kind; f_question; f_shown; f_slot; f_trace; f_missing ] fields
    in
    let* question = object_field f_question fields question_of_json in
    let* shown = object_field f_shown fields shown_of_json in
    let* slot = wire_string_field f_slot fields in
    let* trace = wire_string_field f_trace fields in
    let* missing = list_field f_missing fields missing_at_of_json in
    Ok (Read { question; shown; slot; trace; missing })
  | Kind_make_room ->
    let* () = exact_field_names_result [ f_kind; f_question; f_slot; f_trace ] fields in
    let* question = object_field f_question fields question_of_json in
    let* slot = wire_string_field f_slot fields in
    let* trace = wire_string_field f_trace fields in
    Ok (Make_room { question; slot; trace })
  | Kind_skip ->
    let* () = exact_field_names_result [ f_kind; f_hole ] fields in
    let* hole = object_field f_hole fields hole_of_json in
    Ok (Skip { hole })
  | Kind_molt_and_synthesize ->
    let* () = exact_field_names_result [ f_kind; f_question; f_slot; f_trace; f_trigger ] fields in
    let* question = object_field f_question fields question_of_json in
    let* slot = wire_string_field f_slot fields in
    let* trace = wire_string_field f_trace fields in
    let* trigger = object_field f_trigger fields Librarian_lifecycle.molt_trigger_of_json in
    Ok (Molt_and_synthesize { question; slot; trace; trigger })
  | Kind_checkpoint ->
    let* () = exact_field_names_result [ f_kind; f_compacted_lines; f_archived_entries ] fields in
    let* compacted_lines = count_field f_compacted_lines fields in
    let* archived_entries = count_field f_archived_entries fields in
    Ok (Checkpoint { compacted_lines; archived_entries })
;;

let within_of_json json =
  let* fields = object_fields json in
  let* within = of_token ~token_of:within_kind_token within_kinds f_kind fields in
  match within with
  | Kind_whole ->
    let* () = exact_field_names_result [ f_kind ] fields in
    Ok Whole
  | Kind_item ->
    let* () = exact_field_names_result [ f_kind; f_store; f_at ] fields in
    let* store = of_token ~token_of:store_token Librarian_unit.stores f_store fields in
    let* at = count_field f_at fields in
    Ok (Item { store; at })
;;

let position_of_json json =
  let* fields = object_fields json in
  let* position = of_token ~token_of:position_kind_token position_kinds f_kind fields in
  match position with
  | Kind_before_first ->
    let* () = exact_field_names_result [ f_kind ] fields in
    Ok Before_first
  | Kind_through ->
    let* () = exact_field_names_result [ f_kind; f_line; f_within ] fields in
    let* line = count_field f_line fields in
    let* within = object_field f_within fields within_of_json in
    Ok (Through { line; within })
;;

let removal_of_json json : (Effects.removal, wire_error) result =
  let* fields = object_fields json in
  let* removal = of_token ~token_of:removal_kind_token removal_kinds f_kind fields in
  match removal with
  | Kind_dropped ->
    let* () = exact_field_names_result [ f_kind; f_reason ] fields in
    let* reason = wire_string_field f_reason fields in
    Ok (Effects.Dropped { reason })
  | Kind_merged_into ->
    let* () = exact_field_names_result [ f_kind; f_into ] fields in
    let* successor = memory_id_field f_into fields in
    Ok (Effects.Merged_into successor)
  | Kind_revised_into ->
    let* () = exact_field_names_result [ f_kind; f_into ] fields in
    let* successor = memory_id_field f_into fields in
    Ok (Effects.Revised_into successor)
  | Kind_superseded_by ->
    let* () = exact_field_names_result [ f_kind; f_by ] fields in
    let* successor = memory_id_field f_by fields in
    Ok (Effects.Superseded_by successor)
  | Kind_retracted ->
    let* () = exact_field_names_result [ f_kind; f_by; f_reason ] fields in
    let* by = object_field f_by fields actor_of_json in
    let* reason = wire_string_field f_reason fields in
    Ok (Effects.Retracted { by; reason })
  | Kind_support_lost ->
    let* () = exact_field_names_result [ f_kind; f_missing ] fields in
    let* missing = list_field f_missing fields memory_id_of_json in
    Ok (Effects.Support_lost { missing })
  | Kind_molted ->
    let* () = exact_field_names_result [ f_kind; f_reason ] fields in
    let* reason = wire_string_field f_reason fields in
    Ok (Effects.Molted { reason })
;;

let why_of_json json : (Effects.why_not, wire_error) result =
  let* fields = object_fields json in
  let* why = of_token ~token_of:why_kind_token why_kinds f_kind fields in
  let alone why =
    let* () = exact_field_names_result [ f_kind ] fields in
    Ok why
  in
  match why with
  | Kind_unknown_ref -> alone Effects.Unknown_ref
  | Kind_ref_used_twice -> alone Effects.Ref_used_twice
  | Kind_source_outside_question -> alone Effects.Source_outside_question
  | Kind_not_valid_alone -> alone Effects.Not_valid_alone
  | Kind_not_valid_in_room -> alone Effects.Not_valid_in_room
  | Kind_successor_unsupported -> alone Effects.Successor_unsupported
  | Kind_promotion_refused -> alone Effects.Promotion_refused
  | Kind_removed_during_flight ->
    let* () = exact_field_names_result [ f_kind; f_seq ] fields in
    let* seq = count_field f_seq fields in
    Ok (Effects.Removed_during_flight { seq })
;;

let removed_of_json json =
  let* fields = object_fields json in
  let* () = exact_field_names_result [ f_fact; f_removal ] fields in
  let* fact = object_field f_fact fields fact_of_json in
  let* removal = object_field f_removal fields removal_of_json in
  Ok (fact, removal)
;;

let not_applied_of_json json =
  let* fields = object_fields json in
  let* () = exact_field_names_result [ f_op; f_why; f_stated ] fields in
  let* op = count_field f_op fields in
  let* why = object_field f_why fields why_of_json in
  let* stated_json = wire_json_field f_stated fields in
  let* stated =
    match stated_json with
    | `Null -> Ok None
    | (`Assoc _ | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `String _) as json ->
      wire_at (Wire_field f_stated)
        (Result.map Option.some (Librarian_answer.new_fact_of_json json))
  in
  Ok (op, why, stated)
;;

let source_of_json json =
  let* fields = object_fields json in
  let* () = exact_field_names_result [ f_fact; f_lines ] fields in
  let* id = memory_id_field f_fact fields in
  let* lines = list_field f_lines fields offset_of_json in
  Ok (id, lines)
;;

let effects_of_json json : (Effects.t, wire_error) result =
  let* fields = object_fields json in
  let has_promotions = List.mem_assoc f_promotions fields in
  let expected_fields =
    if has_promotions
    then [ f_added; f_touched; f_removed; f_not_applied; f_sources; f_promotions ]
    else [ f_added; f_touched; f_removed; f_not_applied; f_sources ]
  in
  let* () = exact_field_names_result expected_fields fields in
  let* added = list_field f_added fields fact_of_json in
  let* touched = list_field f_touched fields memory_id_of_json in
  let* removed = list_field f_removed fields removed_of_json in
  let* not_applied = list_field f_not_applied fields not_applied_of_json in
  let* sources = list_field f_sources fields source_of_json in
  let* promotions =
    if has_promotions
    then list_field f_promotions fields Librarian_lifecycle.world_promotion_of_json
    else Ok []
  in
  Ok { Effects.added; touched; removed; not_applied; sources; promotions }
;;

let working_state_field fields =
  let* json = wire_json_field f_working_state fields in
  match json with
  | `Null -> Ok None
  | `String text -> Ok (Some text)
  | `Assoc _ | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ ->
    wire_fail [ Wire_field f_working_state ] Expected_string
;;

(* A line's time becomes the [updated_at] of the snapshot written from it,
   and the snapshot codec reads only a finite one. *)
let time_field field fields =
  let* at = wire_number_field field fields in
  if Float.is_finite at then Ok at else wire_fail [ Wire_field field ] Not_finite
;;

let of_json json =
  let* fields = object_fields json in
  let* line = of_token ~token_of:line_kind_token line_kinds f_line fields in
  match line with
  | Kind_started ->
    let* () =
      exact_field_names_result
        [ f_line; f_at; f_turn_log; f_snapshot; f_revision; f_turn_log_offset; f_covered ]
        fields
    in
    let* at = time_field f_at fields in
    let* turn_log = log_id_field f_turn_log fields in
    let* snapshot = digest_field f_snapshot fields in
    let* revision = count_field f_revision fields in
    let* turn_log_offset = count_field f_turn_log_offset fields in
    let* covered = object_field f_covered fields Turn_codec.mark_of_json in
    Ok (Started { at; turn_log; snapshot; revision; turn_log_offset; covered })
  | Kind_committed ->
    let* () =
      exact_field_names_result
        [ f_line
        ; f_seq
        ; f_at
        ; f_basis
        ; f_after
        ; f_revision
        ; f_cause
        ; f_effects
        ; f_turn_log
        ; f_turn_log_offset
        ; f_covers_through
        ; f_covered
        ; f_working_state
        ]
        fields
    in
    let* seq = count_field f_seq fields in
    let* at = time_field f_at fields in
    let* basis = digest_field f_basis fields in
    let* after = digest_field f_after fields in
    let* revision = count_field f_revision fields in
    let* cause = object_field f_cause fields cause_of_json in
    let* effects = object_field f_effects fields effects_of_json in
    let* turn_log = log_id_field f_turn_log fields in
    let* turn_log_offset = count_field f_turn_log_offset fields in
    let* covers_through = object_field f_covers_through fields position_of_json in
    let* covered = object_field f_covered fields Turn_codec.mark_of_json in
    let* working_state = working_state_field fields in
    Ok
      (Committed
         { seq
         ; at
         ; basis
         ; after
         ; revision
         ; cause
         ; effects
         ; turn_log
         ; turn_log_offset
         ; covers_through
         ; covered
         ; working_state
         })
;;
