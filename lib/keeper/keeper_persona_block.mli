(** Single source of truth for rendering persona text into the [<persona>]
    system-prompt block shared by the chat lane ([Keeper_prompt]) and the
    unified autonomous lane ([Keeper_unified_prompt]).

    Returns [None] when the trimmed persona text is empty so call sites omit
    the block entirely instead of emitting an empty element. The inner bytes
    (trim, XML escape, tag layout) are owned here; surrounding layout
    whitespace stays site-local because the chat lane's historical prompt
    bytes are frozen for KV-cache stability. *)

val render : persona_extended:string -> string option
