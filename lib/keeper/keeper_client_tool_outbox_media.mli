(** The text projection of binary media in retained tool-result receipts.

    The result-data carrier is one System text, so it cannot carry media as
    media. A base64 payload there is only characters: a screenshot of about
    84 KB became about 84,000 characters of prompt, and one hundred of them
    made a carrier larger than the model window (#49634). This projection
    shows each base64 payload a receipt response holds by its identity
    instead. The retained receipt file and its acknowledgement are not
    changed; only the carrier text is. *)

val carrier_row : Yojson.Safe.t -> Yojson.Safe.t
(** [carrier_row receipt] is [receipt] with its [response] base64 media
    replaced by
    [{"type":"media_omitted","kind":K,"media_type":M,"bytes":N,"content_sha256":D}],
    where [N] and [D] are the length and SHA-256 of the decoded bytes. A
    payload that is not valid base64 keeps [invalid_base64_characters] in
    place of [bytes] and [content_sha256].

    Two response shapes hold media:
    - a host receipt's [content_blocks] wire blocks
      ({!Agent_core.Checkpoint.wire_content_block_of_json}) whose source is
      base64;
    - a Codex receipt's [result.contentItems] [inputImage] whose [imageUrl] is
      a base64 [data:] URL.

    Every other value stays as it is, including a block that does not decode
    and media named by a URL or file id, which carry no bytes. *)

(** What one item of a Codex receipt's [result.contentItems] holds.
    [Runtime_official_client_tool.project_content] writes these items, and the
    receipt keeps the frame that was written to the vendor. *)
type codex_item =
  | Input_text of string  (** An [inputText] item: its [text]. *)
  | Data_url_image of
      { media_type : string
      ; payload : string
      }
      (** An [inputImage] item whose [imageUrl] is
          ["data:" ^ media_type ^ ";base64," ^ payload]. *)
  | Other_item
      (** An [inputImage] named by any other URL, or an item of another
          shape. It carries no bytes to move. *)

val codex_items : Yojson.Safe.t -> (Yojson.Safe.t * codex_item) list option
(** Each item of a Codex receipt [response]'s [result.contentItems], in order,
    with what it holds. [None] when [response] has no such list. *)

val with_codex_items : Yojson.Safe.t list -> Yojson.Safe.t -> Yojson.Safe.t
(** [with_codex_items items response] is [response] with [items] as its
    [result.contentItems]. *)

val with_input_text : string -> Yojson.Safe.t -> Yojson.Safe.t
(** [with_input_text text item] is the [inputText] [item] with [text] as its
    [text]; its other fields stay. *)
