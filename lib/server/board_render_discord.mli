(** Board_render_discord — Discord send-side adapter for {!Board_render}
    documents (RFC-0000 §3.1: Discord embed from one projection source).

    Converts the connector-agnostic projection into the payload pieces the
    existing Discord send functions accept
    ({!Discord_rest_client.send_embed_message} / [build_embed_request]):
    [content] carries the header/body text plus explicit lines for
    attachments that cannot become embeds; [embeds] carries the rich
    attachment projection (images as image embeds, video/youtube/links as
    link embeds).

    Pure: no send is performed here and no new wire shape is introduced —
    the output types are exactly [Discord_rest_client]'s. *)

type payload = {
  content : string;
  embeds : Discord_rest_client.embed list;
}

val discord_embed_limit : int
(** Discord rejects a message carrying more than 10 embeds. *)

val payload_of_document : Board_render.document -> payload
(** [payload_of_document doc] splits [doc] into text and embeds:

    - [Header]/[Body] blocks stay in [content] via {!Board_render.plain_text}.
    - Valid attachments become embeds, up to {!discord_embed_limit}; any
      overflow falls back to explicit text lines in [content] (never
      dropped).
    - [Invalid_attachment] blocks stay in [content] as explicit
      ["[invalid attachment]"] lines. *)
