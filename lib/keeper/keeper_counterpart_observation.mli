(** Typed, host-authored evidence about one durable counterpart input.

    This is deliberately separate from persisted Memory OS facts.  It carries
    connector-attention provenance into Keeper world observation, so the
    model does not have to recover identity from prose. [content] is still
    untrusted speaker text; only the surrounding fields are host-owned. *)

type origin =
  | Connector_attention

(** Who the host says spoke. [Keeper] is another registered Keeper, matched
    against the registry where the line was produced; its id is [user_id]. *)
type authority =
  | Owner
  | External
  | Keeper

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
