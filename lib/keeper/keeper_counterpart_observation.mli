(** Typed, host-authored evidence about one durable counterpart input.

    This is deliberately separate from persisted Memory OS facts.  It carries
    direct-chat or connector-attention provenance to the Librarian without
    asking the model to recover identity from prose embedded in an AGENT_CORE
    checkpoint. [content] is still untrusted speaker text; only the surrounding
    fields are host-owned. *)

type origin =
  | Connector_attention
  | Durable_chat

type authority =
  | Owner
  | External

type t = {
  origin : origin;
  channel : string;
  workspace_id : string option;
  user_id : string option;
  user_name : string option;
  authority : authority;
  content : string;
}

val origin_to_string : origin -> string
val authority_to_string : authority -> string

val of_external_attention : Keeper_external_attention.item -> t
(** Preserve the connector-owned actor coordinates and stored content
    projection from one durable external-attention item. *)

val of_chat_message : Keeper_chat_store.chat_message -> t option
(** Project a durable user transcript row when it carries structural speaker
    authority.  Assistant/tool rows and legacy user rows without a typed
    speaker are not guessed. *)

val to_yojson : t -> Yojson.Safe.t

val render_for_prompt : t list -> string
(** Render a JSON array.  JSON quoting keeps speaker content inside the
    [content] field even when it contains prompt-like markers or newlines. *)
