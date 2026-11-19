open Keeper_memory_os_types
open Keeper_turn_log
module Digest = Agent_core.Checkpoint_objects

(* Field names. *)
let f_line = "line"
let f_id = "id"
let f_at = "at"
let f_mark = "mark"
let f_turn_ref = "turn_ref"
let f_runtime = "runtime"
let f_task = "task"
let f_baseline = "baseline"
let f_turn = "turn"
let f_outcome = "outcome"
let f_after = "after"
let f_before = "before"
let f_unattributed = "unattributed"
let f_own = "own"
let f_cause = "cause"
let f_closed_before = "closed_before"
let f_trace = "trace"
let f_closed_messages = "closed_messages"
let f_session = "session"
let f_history_bytes = "history_bytes"
let f_internal_bytes = "internal_bytes"
let f_chat_bytes = "chat_bytes"
let f_external_rows = "external_rows"
let f_bundle = "bundle"
let f_skip = "skip"
let f_take = "take"
let f_kind = wire_field_kind
let f_goals = "goals"
let f_goal = "goal"
let f_shown = "shown"

(* A closed set of tokens, read back through the same table it is written
   from. *)
let token_of table value = List.assoc value (List.map (fun (token, value) -> value, token) table)

let of_token table field fields =
  let ( let* ) = Result.bind in
  let* token = wire_string_field field fields in
  match List.assoc_opt token table with
  | Some value -> Ok value
  | None -> wire_fail [ Wire_field field ] (Unknown_token token)
;;

let outcomes =
  [ "completed", Completed
  ; "errored", Errored
  ; "cancelled", Cancelled
  ; "save_failed", Save_failed
  ; "stale_save", Stale_save
  ; "close_missing", Close_missing
  ; "process_exited", Process_exited
  ]
;;

let causes =
  [ "cleared", Announced Cleared; "recovered", Announced Recovered; "unannounced", Unannounced ]
;;

type line_kind =
  | Kind_log_started
  | Kind_opened
  | Kind_closed
  | Kind_reset

let line_kinds =
  [ "log_started", Kind_log_started
  ; "opened", Kind_opened
  ; "closed", Kind_closed
  ; "reset", Kind_reset
  ]
;;

type task_kind =
  | Kind_no_task
  | Kind_task_source_unavailable
  | Kind_task

let task_kinds =
  [ "no_task", Kind_no_task
  ; "task_source_unavailable", Kind_task_source_unavailable
  ; "task", Kind_task
  ]
;;

let mark_fields =
  [ f_trace
  ; f_closed_messages
  ; f_session
  ; f_history_bytes
  ; f_internal_bytes
  ; f_chat_bytes
  ; f_external_rows
  ]
;;

let mark_to_json mark =
  `Assoc
    [ f_trace, `String mark.trace
    ; f_closed_messages, `Int mark.closed_messages
    ; f_session, `String mark.session
    ; f_history_bytes, `Int mark.history_bytes
    ; f_internal_bytes, `Int mark.internal_bytes
    ; f_chat_bytes, `Int mark.chat_bytes
    ; f_external_rows, `Int mark.external_rows
    ]
;;

let slice_to_json slice =
  `Assoc
    [ f_bundle, `String (slice.bundle :> string)
    ; f_skip, `Int slice.skip
    ; f_take, `Int slice.take
    ]
;;

let slices_to_json slices = `List (List.map slice_to_json slices)

let task_to_json = function
  | No_task -> `Assoc [ f_kind, `String (token_of task_kinds Kind_no_task) ]
  | Task_source_unavailable ->
    `Assoc [ f_kind, `String (token_of task_kinds Kind_task_source_unavailable) ]
  | Task { task; goals } ->
    `Assoc
      [ f_kind, `String (token_of task_kinds Kind_task)
      ; f_task, `String (Keeper_id.Task_id.to_string task)
      ; ( f_goals
        , match goals with
          | None -> `Null
          | Some goals ->
            `List
              (List.map
                 (fun { goal; shown } -> `Assoc [ f_goal, `String goal; f_shown, `String shown ])
                 goals) )
      ]
;;

let to_json line =
  let kind kind = f_line, `String (token_of line_kinds kind) in
  match line with
  | Log_started { id; at; mark } ->
    `Assoc
      [ kind Kind_log_started
      ; f_id, `String (Log_id.to_string id)
      ; f_at, `Float at
      ; f_mark, mark_to_json mark
      ]
  | Opened { at; turn_ref; runtime; task; baseline } ->
    `Assoc
      [ kind Kind_opened
      ; f_at, `Float at
      ; f_turn_ref, `String (Ids.Turn_ref.to_string turn_ref)
      ; f_runtime, `String runtime
      ; f_task, task_to_json task
      ; f_baseline, mark_to_json baseline
      ]
  | Closed { turn; at; outcome; after; unattributed; own } ->
    `Assoc
      [ kind Kind_closed
      ; f_turn, `Int turn
      ; f_at, `Float at
      ; f_outcome, `String (token_of outcomes outcome)
      ; f_after, mark_to_json after
      ; f_unattributed, slices_to_json unattributed
      ; f_own, slices_to_json own
      ]
  | Reset { at; cause; before; after; closed_before } ->
    `Assoc
      [ kind Kind_reset
      ; f_at, `Float at
      ; f_cause, `String (token_of causes cause)
      ; f_before, mark_to_json before
      ; f_after, mark_to_json after
      ; f_closed_before, slices_to_json closed_before
      ]
;;

let ( let* ) = Result.bind

let object_fields = function
  | `Assoc fields -> Ok fields
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
    wire_here Expected_object
;;

let count_field field fields =
  let* value = wire_int_field field fields in
  if value < 0 then wire_fail [ Wire_field field ] Negative else Ok value
;;

let object_field field fields decode =
  let* json = wire_json_field field fields in
  wire_at (Wire_field field) (decode json)
;;

let mark_of_json json =
  let* fields = object_fields json in
  let* () = exact_field_names_result mark_fields fields in
  let* trace = wire_string_field f_trace fields in
  let* closed_messages = count_field f_closed_messages fields in
  let* session = wire_string_field f_session fields in
  let* history_bytes = count_field f_history_bytes fields in
  let* internal_bytes = count_field f_internal_bytes fields in
  let* chat_bytes = count_field f_chat_bytes fields in
  let* external_rows = count_field f_external_rows fields in
  Ok
    { trace
    ; closed_messages
    ; session
    ; history_bytes
    ; internal_bytes
    ; chat_bytes
    ; external_rows
    }
;;

let slice_of_json json =
  let* fields = object_fields json in
  let* () = exact_field_names_result [ f_bundle; f_skip; f_take ] fields in
  let* hex = wire_string_field f_bundle fields in
  let* bundle =
    match Digest.digest_of_hex hex with
    | Ok digest -> Ok digest
    | Error (_ : string) -> wire_fail [ Wire_field f_bundle ] (Unknown_token hex)
  in
  let* skip = count_field f_skip fields in
  let* take = count_field f_take fields in
  if take = 0 then wire_fail [ Wire_field f_take ] Not_positive else Ok { bundle; skip; take }
;;

let list_field field fields decode =
  let* items = wire_list_field field fields in
  let rec collect index decoded = function
    | [] -> Ok (List.rev decoded)
    | item :: rest ->
      let* value = wire_at_element field index (decode item) in
      collect (index + 1) (value :: decoded) rest
  in
  collect 0 [] items
;;

let goal_of_json json =
  let* fields = object_fields json in
  let* () = exact_field_names_result [ f_goal; f_shown ] fields in
  let* goal = wire_string_field f_goal fields in
  let* shown = wire_string_field f_shown fields in
  Ok { goal; shown }
;;

let task_of_json json =
  let* fields = object_fields json in
  let* kind = of_token task_kinds f_kind fields in
  match kind with
  | Kind_no_task ->
    let* () = exact_field_names_result [ f_kind ] fields in
    Ok No_task
  | Kind_task_source_unavailable ->
    let* () = exact_field_names_result [ f_kind ] fields in
    Ok Task_source_unavailable
  | Kind_task ->
    let* () = exact_field_names_result [ f_kind; f_task; f_goals ] fields in
    let* text = wire_string_field f_task fields in
    let* task =
      match Keeper_id.Task_id.of_string text with
      | Ok task -> Ok task
      | Error (_ : string) -> wire_fail [ Wire_field f_task ] (Unknown_token text)
    in
    let* goals_json = wire_json_field f_goals fields in
    let* goals =
      match goals_json with
      | `Null -> Ok None
      | `List _ ->
        let* goals = list_field f_goals fields goal_of_json in
        Ok (Some goals)
      | `Assoc _ | `Bool _ | `Float _ | `Int _ | `Intlit _ | `String _ ->
        wire_fail [ Wire_field f_goals ] Expected_array
    in
    Ok (Task { task; goals })
;;

let of_json json =
  let* fields = object_fields json in
  let* kind = of_token line_kinds f_line fields in
  match kind with
  | Kind_log_started ->
    let* () = exact_field_names_result [ f_line; f_id; f_at; f_mark ] fields in
    let* text = wire_string_field f_id fields in
    let* id =
      match Log_id.of_string text with
      | Some id -> Ok id
      | None -> wire_fail [ Wire_field f_id ] (Unknown_token text)
    in
    let* at = wire_number_field f_at fields in
    let* mark = object_field f_mark fields mark_of_json in
    Ok (Log_started { id; at; mark })
  | Kind_opened ->
    let* () =
      exact_field_names_result
        [ f_line; f_at; f_turn_ref; f_runtime; f_task; f_baseline ]
        fields
    in
    let* at = wire_number_field f_at fields in
    let* text = wire_string_field f_turn_ref fields in
    let* turn_ref =
      match Ids.Turn_ref.of_string text with
      | Some turn_ref -> Ok turn_ref
      | None -> wire_fail [ Wire_field f_turn_ref ] (Not_a_turn_ref text)
    in
    let* runtime = wire_string_field f_runtime fields in
    let* task = object_field f_task fields task_of_json in
    let* baseline = object_field f_baseline fields mark_of_json in
    Ok (Opened { at; turn_ref; runtime; task; baseline })
  | Kind_closed ->
    let* () =
      exact_field_names_result
        [ f_line; f_turn; f_at; f_outcome; f_after; f_unattributed; f_own ]
        fields
    in
    let* turn = count_field f_turn fields in
    let* at = wire_number_field f_at fields in
    let* outcome = of_token outcomes f_outcome fields in
    let* after = object_field f_after fields mark_of_json in
    let* unattributed = list_field f_unattributed fields slice_of_json in
    let* own = list_field f_own fields slice_of_json in
    Ok (Closed { turn; at; outcome; after; unattributed; own })
  | Kind_reset ->
    let* () =
      exact_field_names_result [ f_line; f_at; f_cause; f_before; f_after; f_closed_before ] fields
    in
    let* at = wire_number_field f_at fields in
    let* cause = of_token causes f_cause fields in
    let* before = object_field f_before fields mark_of_json in
    let* after = object_field f_after fields mark_of_json in
    let* closed_before = list_field f_closed_before fields slice_of_json in
    Ok (Reset { at; cause; before; after; closed_before })
;;
