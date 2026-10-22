(** Pure projection of server-provided rich output. The canonical block codec
    owns decoding; this module neither fetches assets nor plays audio. *)
type t =
  | Image of Masc.Keeper_chat_blocks.image_block
  | Voice of Masc.Keeper_chat_blocks.voice_block
  | Attach of Masc.Keeper_chat_blocks.attach_block
  | Svg of Masc.Keeper_chat_blocks.svg_block
  | Mermaid of Masc.Keeper_chat_blocks.mermaid_block

val of_json : Yojson.Safe.t -> t list
val append_text : text:string -> t list -> string
(** Retain original prose and whitespace, followed by visible media metadata.
    Inline payloads are never expanded into the terminal's text stream. *)
val newest_image : t list -> Masc_tui_image_preview.preview option
(** The last image or Mermaid output in producer order. Unsupported sources remain an
    explicit unavailable preview rather than exposing a local filesystem path. *)

val images : t list -> Masc_tui_image_preview.preview list
(** Every image/diagram in producer order, including explicitly unavailable
    image sources. Filenames remain labels, not local filesystem paths. *)

val without_drawn_diagrams : sources:string list -> t list ->
  Masc_tui_image_preview.preview list -> t list * Masc_tui_image_preview.preview list
(** Remove only diagram occurrences covered by the same execution's drawn,
    unsuperseded speech. Each exact closed-fence source covers one occurrence
    in each representation. Other media and uncovered repetitions survive;
    inputs and source bytes remain unchanged. *)

type playable = {
  name : string;
  kind : [ `Audio | `Midi ];
  source : [ `Data of string  (** base64, optionally data-URI wrapped *)
           | `Server_path of string  (** fetched from the MASC peer, e.g. [/api/v1/media/…] *)
           | `Local_path of string  (** read from this machine *) ];
}
(** What /listen can play: an [Attach] with an audio or MIDI extension whose
    bytes are at hand, or a [Voice] block, which is audio by definition. *)

val newest_playable : t list -> playable option
(** The last playable block in producer order — the same newest-wins rule as
    {!newest_image}. External http(s) sources are not playable here. *)
