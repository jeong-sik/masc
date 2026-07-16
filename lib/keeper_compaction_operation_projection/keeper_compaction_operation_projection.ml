module Operation = Keeper_compaction_operation
module Reducer = Keeper_compaction_operation_reducer
module Event = Keeper_operation_event
module Record = Keeper_operation_record
module Cursor = Record.Cursor

type operation_entry =
  { snapshot : Reducer.snapshot
  ; requested_at : float
  ; request_cursor : Cursor.t
  }

type rejection =
  | Cursor_mismatch of
      { expected : Cursor.t
      ; actual : Cursor.t
      }
  | Transition_rejected of Reducer.transition_error
  | Keeper_mismatch of
      { expected : Keeper_id.Keeper_name.t
      ; actual : Keeper_id.Keeper_name.t
      }
  | Producer_already_bound of
      { producer : Operation.producer_ref
      ; existing_operation_id : Operation.Operation_id.t
      }

type replay_error =
  | Rejected_row of
      { row_number : int
      ; start_cursor : Cursor.t
      ; end_cursor : Cursor.t
      ; rejection : rejection
      }

module Operation_map = Map.Make (struct
    type t = Operation.Operation_id.t
    let compare = Operation.Operation_id.compare
  end)

type operation_state =
  { reducer : Reducer.state
  ; requested_at : float
  ; request_cursor : Cursor.t
  }

type t =
  { keeper_name : Keeper_id.Keeper_name.t
  ; operations : operation_state Operation_map.t
  ; producers : (Operation.producer_ref * Operation.Operation_id.t) list
  ; end_cursor : Cursor.t
  }

let empty ~keeper_name =
  { keeper_name
  ; operations = Operation_map.empty
  ; producers = []
  ; end_cursor = Cursor.zero
  }
;;

let ( let* ) = Result.bind

let producer_of_event event =
  match Operation.view event with
  | Operation.Requested { producer; _ } -> producer
  | _ -> None
;;

let find_producer producer =
  List.find_map (fun (candidate, operation_id) ->
    if Operation.producer_ref_equal producer candidate then Some operation_id else None)
;;

let apply state (row : Record.row) =
  if Cursor.to_int row.start_cursor <> Cursor.to_int state.end_cursor
  then Error (Cursor_mismatch { expected = state.end_cursor; actual = row.start_cursor })
  else
    let event =
      match row.event with
      | Event.Compaction event -> event
    in
    let operation_id = Operation.operation_id event in
    let current = Operation_map.find_opt operation_id state.operations in
    let* next =
      Reducer.apply (Option.map (fun value -> value.reducer) current) event
      |> Result.map_error (fun error -> Transition_rejected error)
    in
    let actual = (Reducer.snapshot next).keeper_name in
    if not (Keeper_id.Keeper_name.equal state.keeper_name actual)
    then Error (Keeper_mismatch { expected = state.keeper_name; actual })
    else
      let operation =
        match current with
        | Some value -> { value with reducer = next }
        | None ->
          { reducer = next
          ; requested_at = row.recorded_at
          ; request_cursor = row.end_cursor
          }
      in
      let operations = Operation_map.add operation_id operation state.operations in
      match producer_of_event event with
      | Some producer ->
        (match find_producer producer state.producers with
         | Some existing_operation_id
           when not (Operation.Operation_id.equal existing_operation_id operation_id) ->
           Error (Producer_already_bound { producer; existing_operation_id })
         | Some _ -> Ok { state with operations; end_cursor = row.end_cursor }
         | None ->
           Ok
             { state with
               operations
             ; producers = (producer, operation_id) :: state.producers
             ; end_cursor = row.end_cursor
             })
      | None -> Ok { state with operations; end_cursor = row.end_cursor }
;;

let replay ~keeper_name rows =
  let rec loop row_number state = function
    | [] -> Ok state
    | (row : Record.row) :: rest ->
      (match apply state row with
       | Ok state -> loop (row_number + 1) state rest
       | Error rejection ->
         Error
           (Rejected_row
              { row_number
              ; start_cursor = row.start_cursor
              ; end_cursor = row.end_cursor
              ; rejection
              }))
  in
  loop 1 (empty ~keeper_name) rows
;;

let end_cursor state = state.end_cursor

let operations state =
  Operation_map.bindings state.operations
  |> List.map (fun (_, value) ->
    { snapshot = Reducer.snapshot value.reducer
    ; requested_at = value.requested_at
    ; request_cursor = value.request_cursor
    })
  |> List.sort (fun (left : operation_entry) right ->
    Int.compare
      (Cursor.to_int left.request_cursor)
      (Cursor.to_int right.request_cursor))
;;
