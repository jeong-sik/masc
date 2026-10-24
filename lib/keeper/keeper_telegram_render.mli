(** Exhaustive Telegram projection of committed public chat blocks. Each HTML
    chunk is independently balanced and contains at most 4096 UTF-16 units after
    entity parsing. Thinking and tool traces never become connector output.
    A visible reply without public content is an error, not a delivered reply. *)
val render : reply:string -> blocks:Keeper_chat_blocks.chat_block list option ->
  (string list, string) result
