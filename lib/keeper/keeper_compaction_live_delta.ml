type error =
  | Source_superseded of
      { source_trace_id : Keeper_id.Trace_id.t
      ; source_generation : int
      ; current_trace_id : Keeper_id.Trace_id.t
      ; current_generation : int
      }
  | Current_turn_regressed of
      { source_turn_count : int
      ; current_turn_count : int
      }
  | Current_messages_prefix_mismatch of Keeper_replay_prefix.prefix_mismatch

let same_lineage (source_ref : Keeper_checkpoint_ref.t)
    (current_ref : Keeper_checkpoint_ref.t) =
  Keeper_id.Trace_id.equal source_ref.trace_id current_ref.trace_id
  && Int.equal source_ref.generation current_ref.generation
;;

let rebase ~source ~compacted_messages ~current =
  let source_checkpoint =
    Keeper_checkpoint_store.exact_snapshot_checkpoint source
  in
  let current_checkpoint =
    Keeper_checkpoint_store.exact_snapshot_checkpoint current
  in
  let source_ref = Keeper_checkpoint_store.exact_snapshot_reference source in
  let current_ref = Keeper_checkpoint_store.exact_snapshot_reference current in
  let candidate = { source_checkpoint with messages = compacted_messages } in
  if Keeper_checkpoint_ref.equal source_ref current_ref
  then Ok candidate
  else if not (same_lineage source_ref current_ref)
  then
    Error
      (Source_superseded
         { source_trace_id = source_ref.trace_id
         ; source_generation = source_ref.generation
         ; current_trace_id = current_ref.trace_id
         ; current_generation = current_ref.generation
         })
  else if current_ref.turn_count < source_ref.turn_count
  then
    Error
      (Current_turn_regressed
         { source_turn_count = source_ref.turn_count
         ; current_turn_count = current_ref.turn_count
         })
  else
    match
      Keeper_replay_prefix.split
        ~prefix:source_checkpoint.messages
        current_checkpoint.messages
    with
    | Error mismatch -> Error (Current_messages_prefix_mismatch mismatch)
    | Ok exact_suffix ->
      Ok
        { current_checkpoint with
          messages = compacted_messages @ exact_suffix
        }
;;
