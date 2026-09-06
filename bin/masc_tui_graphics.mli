(** Drawing an image on a terminal that can hold one.

    The Kitty graphics protocol carries image bytes to the terminal inside APC
    escapes and asks it to place them at the cursor. Terminals that implement
    it (Ghostty, Kitty, WezTerm) draw the picture; terminals that do not
    ignore the escapes entirely, which is why the capability is asked about
    rather than assumed -- an unanswered query means no image is sent, instead
    of a screenful of base64.

    Pure: every function returns bytes for the caller to write, or reads bytes
    the caller collected. Nothing here touches a terminal or a file. *)

type placement = {
  columns : int;
  rows : int;
      (** The cell box the image is asked to fit inside. The terminal scales
          to it, so the caller sizes the box from the frame it is drawing and
          does not have to know the image's pixel dimensions. *)
}

val query : string
(** Ask the terminal whether it speaks the protocol. Sends a one-pixel image
    it is asked to receive but not draw, under a distinctive id. A terminal
    that implements the protocol answers; one that does not says nothing, so
    the caller needs its own deadline. *)

val query_id : int
(** The image id {!query} uses. Present in the reply, and chosen so a reply
    cannot be confused with an answer about a picture actually being drawn. *)

type query_reply =
  | Supported
  | Refused of string
      (** The terminal answered and said no, carrying its reason. This is a
          terminal that speaks the protocol and declined this request -- not
          the same as one that never answered, which produces no reply at
          all. *)

val parse_query_reply : string -> query_reply option
(** Read one APC reply body -- the bytes between [ESC _ G] and [ESC \\].
    [None] when the body is not an answer to {!query}: another image's
    response, or something that is not a graphics reply. *)

val payload_media_type : string
(** What {!place} encodes its payload as: it says [f=100], a PNG file's bytes,
    and [q=2], which tells the terminal not to answer. Bytes of any other
    format are sent, dropped by the decoder, and nothing says so. Ask whatever
    identifies bytes whether they are this, before placing -- after placing
    there is nobody to ask. *)

val place : data:string -> placement -> string
(** Bytes that put [data] -- the contents of a PNG file -- on the terminal at
    the cursor.

    Chunked: the protocol asks that a payload be split, and terminals do drop
    escapes past a certain length. The caller writes the whole string;
    splitting is this function's business, not the caller's.

    Asks the terminal not to answer. A reply would arrive on stdin, which is
    the key stream, and an unread reply is typed into whatever the operator
    was writing. {!query} is the one request that wants an answer. *)

val delete_all : string
(** Bytes that remove every image this process placed. Written before leaving
    a picture behind: the terminal holds images in its own layer, and text
    drawn over them does not necessarily erase them. *)

type graphics_protocol =
  | Kitty_protocol
  | ITerm2_protocol
  | Unsupported_protocol

val iterm2_place : data:string -> placement -> string
(** Bytes that put [data] on an iTerm2-compatible terminal at the cursor using OSC 1337. *)

val tmux_wrapped : string -> string
(** Wrap escapes so tmux forwards them to the terminal underneath instead of
    eating them. Only correct inside tmux, and only with
    [allow-passthrough on]; the caller decides whether it is in tmux. *)
