(** Terminal delivery from the canonical committed reply. The loader must
    select one persisted assistant row by exact turn and destination, never by
    text or timestamps. Provider events cannot authorize a send. *)
val deliver : events:Keeper_chat_events.t ->
  load_blocks:(Ids.Turn_ref.t -> (Keeper_chat_blocks.chat_block list option,string) result) ->
  send:(string list -> (unit,string) result) -> (unit,string) result
