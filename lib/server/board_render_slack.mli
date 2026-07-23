(** Board_render_slack — Slack send-side adapter for {!Board_render}
    documents (RFC-0000 §3.1: Slack block from one projection source).

    Converts the connector-agnostic projection into the payload pieces the
    existing Slack send function accepts
    ({!Keeper_chat_slack.send_message_with_blocks}): [content] is the
    complete plain-text fallback (Slack renders it in notifications and for
    screen readers), [blocks] carries the Block Kit projection of the
    attachments, built through {!Keeper_chat_slack}'s own block builders so
    redaction/mrkdwn-escaping/truncation stay single-sourced there.

    Pure: no send is performed here. *)

type payload = {
  content : string;
  blocks : Yojson.Safe.t list;
}

val payload_of_document : Board_render.document -> payload
(** [payload_of_document doc]:

    - [content] = {!Board_render.plain_text} of the whole document
      (attachments included — the Slack [text] field is the fallback).
    - Image attachments become Block Kit image blocks; video/youtube/
      external-link attachments become section blocks with an mrkdwn link;
      [Invalid_attachment] blocks become explicit section notices (never
      silently dropped). *)
