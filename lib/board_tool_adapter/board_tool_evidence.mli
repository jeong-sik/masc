(** Small producer-owned Board write facts, independent of model output text.
    These facts describe a committed write, never the cause of a Keeper's
    decision, a queue acknowledgement, or a no-action verdict. *)

type t = private
  | Comment_added of
      { post_id : string
      ; comment_id : string
      ; parent_id : string option
      ; author : string
      }
  | Reaction_changed of
      { post_id : string
      ; target_type : Board.reaction_target_type
      ; target_id : string
      ; user_id : string
      ; emoji : string
      ; reacted : bool
      }

val comment : Board.comment -> t
val reaction : post_id:Board.Post_id.t -> Board.reaction_toggle_result -> t
(** Construct from the actual successful Board writer result. A removed
    reaction retains [reacted=false]; no separate reaction id is invented. *)

val schema : string
val to_yojson : t -> Yojson.Safe.t
val of_yojson : Yojson.Safe.t -> (t, string) result
(** Strict decoder for the bounded durable facts. Unknown fields, duplicate
    fields, invalid identities, and inconsistent post targets are errors. *)

val metadata : t -> Yojson.Safe.t
val with_metadata : (t, string) result -> Yojson.Safe.t option -> Yojson.Safe.t
(** Preserve the invocation carrier in a result, including a post-commit
    projection or schema failure. Existing metadata fields remain intact. *)
val of_metadata : Yojson.Safe.t option -> (t, string) result option
(** [None] means this producer supplied no Board evidence. [Some (Error _)]
    preserves malformed evidence as unavailable rather than treating it as
    absence. Gate metadata is read through its existing [producer] envelope. *)

val for_tool : tool_name:string -> (t, string) result -> (t, string) result
(** Accept a fact only from its reserved host Board writer and matching kind.
    An Add-on's arbitrary MCP metadata cannot become a Board write fact. *)
