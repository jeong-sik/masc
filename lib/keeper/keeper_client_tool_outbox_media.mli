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
