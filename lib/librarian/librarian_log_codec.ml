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
let f_index = "index"
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

let cause_kind_token = function
  | Kind_direct -> "direct"
  | Kind_adopt -> "adopt"
;;

let cause_kinds = [ Kind_direct; Kind_adopt ]

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

type removal_kind =
  | Kind_dropped
  | Kind_merged_into
  | Kind_revised_into
  | Kind_superseded_by
  | Kind_retracted
  | Kind_support_lost

let removal_kind_token = function
  | Kind_dropped -> "dropped"
  | Kind_merged_into -> "merged_into"
  | Kind_revised_into -> "revised_into"
  | Kind_superseded_by -> "superseded_by"
  | Kind_retracted -> "retracted"
  | Kind_support_lost -> "support_lost"
;;

let removal_kinds =
  [ Kind_dropped
  ; Kind_merged_into
  ; Kind_revised_into
  ; Kind_superseded_by
  ; Kind_retracted
  ; Kind_support_lost
  ]
;;

type why_kind =
  | Kind_unknown_ref
  | Kind_ref_used_twice
  | Kind_source_outside_question
  | Kind_removed_during_flight
  | Kind_not_valid_alone
  | Kind_successor_unsupported

let why_kind_of : Effects.why_not -> why_kind = function
  | Unknown_ref -> Kind_unknown_ref
  | Ref_used_twice -> Kind_ref_used_twice
  | Source_outside_question -> Kind_source_outside_question
  | Removed_during_flight { seq = (_ : int) } -> Kind_removed_during_flight
  | Not_valid_alone -> Kind_not_valid_alone
  | Successor_unsupported -> Kind_successor_unsupported
;;

(* The token a line carries is the one a metric label carries. *)
let why_kind_token = function
  | Kind_unknown_ref -> Effects.why_not_kind Unknown_ref
  | Kind_ref_used_twice -> Effects.why_not_kind Ref_used_twice
  | Kind_source_outside_question -> Effects.why_not_kind Source_outside_question
  | Kind_removed_during_flight -> Effects.why_not_kind (Removed_during_flight { seq = 0 })
  | Kind_not_valid_alone -> Effects.why_not_kind Not_valid_alone
  | Kind_successor_unsupported -> Effects.why_not_kind Successor_unsupported
;;

let why_kinds =
  [ Kind_unknown_ref
  ; Kind_ref_used_twice
  ; Kind_source_outside_question
  ; Kind_removed_during_flight
  ; Kind_not_valid_alone
  ; Kind_successor_unsupported
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
;;

let within_to_json = function
  | Whole -> `Assoc [ kind (within_kind_token Kind_whole) ]
  | Item index -> `Assoc [ kind (within_kind_token Kind_item); f_index, `Int index ]
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
;;

let why_to_json (why : Effects.why_not) =
  let token = kind (why_kind_token (why_kind_of why)) in
  match why with
  | Removed_during_flight { seq } -> `Assoc [ token; f_seq, `Int seq ]
  | Unknown_ref | Ref_used_twice | Source_outside_question | Not_valid_alone
  | Successor_unsupported -> `Assoc [ token ]
;;

let effects_to_json (effects : Effects.t) =
  `Assoc
    [ f_added, `List (List.map fact_to_json effects.added)
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
;;

let within_of_json json =
  let* fields = object_fields json in
  let* within = of_token ~token_of:within_kind_token within_kinds f_kind fields in
  match within with
  | Kind_whole ->
    let* () = exact_field_names_result [ f_kind ] fields in
    Ok Whole
  | Kind_item ->
    let* () = exact_field_names_result [ f_kind; f_index ] fields in
    let* index = count_field f_index fields in
    Ok (Item index)
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
  | Kind_successor_unsupported -> alone Effects.Successor_unsupported
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
  let* () =
    exact_field_names_result [ f_added; f_touched; f_removed; f_not_applied; f_sources ] fields
  in
  let* added = list_field f_added fields fact_of_json in
  let* touched = list_field f_touched fields memory_id_of_json in
  let* removed = list_field f_removed fields removed_of_json in
  let* not_applied = list_field f_not_applied fields not_applied_of_json in
  let* sources = list_field f_sources fields source_of_json in
  Ok { Effects.added; touched; removed; not_applied; sources }
;;

let working_state_field fields =
  let* json = wire_json_field f_working_state fields in
  match json with
  | `Null -> Ok None
  | `String text -> Ok (Some text)
  | `Assoc _ | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ ->
    wire_fail [ Wire_field f_working_state ] Expected_string
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
    let* at = wire_number_field f_at fields in
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
    let* at = wire_number_field f_at fields in
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
