(** Durable projection for request-local Gate evidence.

    The exact current user/dynamic context, operation input, and completed tool
    calls remain inline. Historical Keeper messages are already durable in the
    Keeper checkpoint, and executing-agent system prompts are code-owned policy
    rather than request evidence. Both are represented by metadata plus SHA-256
    so the Gate queue does not duplicate them in every pending request. *)

val project : Yojson.Safe.t -> Yojson.Safe.t
