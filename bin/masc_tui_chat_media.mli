(** Pure projection of server-provided rich output. The canonical block codec
    owns decoding; this module neither fetches assets nor plays audio. *)
type t =
  | Image of Masc.Keeper_chat_blocks.image_block
  | Voice of Masc.Keeper_chat_blocks.voice_block
  | Attach of Masc.Keeper_chat_blocks.attach_block
  | Svg of Masc.Keeper_chat_blocks.svg_block

val of_json : Yojson.Safe.t -> t list
val append_text : text:string -> t list -> string
(** Retain original prose and whitespace, followed by visible media metadata.
    Inline payloads are never expanded into the terminal's text stream. *)
val newest_image : t list -> Masc_tui_image_preview.preview option
(** The last image output in producer order. Unsupported sources remain an
    explicit unavailable preview rather than exposing a local filesystem path. *)
