(** Board_render — connector-agnostic projection of a board post.

    RFC-0000 §3.1 boundary contract: rich board rendering is a MASC-owned
    surface projection owned by this single module (Discord embed / Slack
    block / plain-text fallback from one source).  Connector send-side
    adapters ([Board_render_discord] / [Board_render_slack] in the gateway
    layer) consume {!document} and convert it to their wire payloads; no
    connector type appears here.

    Pure: no I/O, no wall clock, no connector imports.

    Attachments are decoded from [post.meta_json] through
    {!Board_attachment_meta}.  An entry that fails the typed decode becomes
    an explicit {!Invalid_attachment} block — never silently skipped — so
    every surface shows the producer's metadata failure instead of dropping
    the attachment. *)

(** One attachment as a connector-agnostic block.  Constructors mirror
    {!Board_attachment_meta.kind} one-to-one, plus the explicit decode-failure
    carrier. *)
type attachment_block =
  | Image of {
      url : string;
      name : string;
      width : int option;
      height : int option;
    }
  | Video of {
      url : string;
      name : string;
      mime_type : string;
    }
  | Youtube of {
      url : string;
      name : string;
    }
  | External_link of {
      url : string;
      name : string;
    }
  | Invalid_attachment of { detail : string }
[@@deriving show, eq]

type block =
  | Header of {
      title : string;
      author : string;
      hearth : string option;
    }
  | Body of string
  | Attachment of attachment_block
[@@deriving show, eq]

type document = {
  post_id : string;
  blocks : block list;
}
[@@deriving show, eq]

val document_of_post : Board.post -> document
(** [document_of_post post] projects [post] into the ordered block list:
    [Header], then [Body] (omitted when the body is blank), then one
    [Attachment] block per entry in [meta_json.attachments] (in stored
    order). *)

val plain_text : document -> string
(** [plain_text doc] is the plain-text fallback projection: one line per
    block part, joined with ["\n"].  Attachment lines use the
    ["[kind] name (url)"] shape (["[kind] url"] when the name is blank);
    invalid attachments render as ["[invalid attachment] <detail>"]. *)
