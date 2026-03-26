(** Backend compression — zstd compression with dictionary support.

    Compact Protocol v4: Transparent zstd compression with Dictionary
    - Uses trained multi-format dictionary for 32-2048 byte messages
    - Dictionary achieves ~70% compression vs ~6% standard zstd on small data
    - Automatically compresses data >32 bytes on save
    - Automatically decompresses on load (ZSTD/ZSTDD header detection)

    IMPORTANT: backend values are stored in PostgreSQL TEXT columns, so the
    persisted representation must stay ASCII-safe. Older binary headers could
    be truncated at embedded NUL bytes, leaving values like "ZSTD". *)

(** Minimum size for dictionary compression *)
let min_size = Compression_codec.min_size  (* 32 bytes *)

(** Default compression level *)
let default_level = 3

(** ZSTD header magic (standard compression) *)
let magic = "ZSTD"

(** ZSTDD header magic (dictionary compression) *)
let magic_dict = "ZSTDD"

(** Text-safe headers for TEXT-backed persistence.
    Format:
    - standard: ZSTD:<orig_size>:<base64 payload>
    - dictionary: ZSTDD:<orig_size>:<base64 payload> *)
let text_magic = "ZSTD:"
let text_magic_dict = "ZSTDD:"

(** Compress with zstd + optional dictionary *)
let compress ?(level = default_level) (data : string) : (string * bool * bool) =
  match Compression_codec.compress ~level data with
  | Compression_codec.Unchanged payload -> (payload, false, false)
  | Compression_codec.Compressed { payload; encoding } ->
      (payload, Compression_codec.uses_dict encoding, true)

(** Encode with a text-safe header so PostgreSQL TEXT storage cannot truncate
    the payload at embedded binary bytes. *)
let encode_with_header ~(used_dict : bool) (orig_size : int) (compressed : string) : string =
  let prefix = if used_dict then text_magic_dict else text_magic in
  prefix ^ string_of_int orig_size ^ ":" ^ Base64.encode_string compressed

let decode_text_header (data : string) : (int * string * bool) option =
  let decode_with_prefix prefix used_dict =
    let prefix_len = String.length prefix in
    if String.length data <= prefix_len || String.sub data 0 prefix_len <> prefix then
      None
    else
      let rest = String.sub data prefix_len (String.length data - prefix_len) in
      match String.index_opt rest ':' with
      | None -> None
      | Some idx -> begin
          let size_str = String.sub rest 0 idx in
          let payload_b64 =
            String.sub rest (idx + 1) (String.length rest - idx - 1)
          in
          match int_of_string_opt size_str, Base64.decode payload_b64 with
          | Some orig_size, Ok compressed -> Some (orig_size, compressed, used_dict)
          | _ -> None
        end
  in
  match decode_with_prefix text_magic_dict true with
  | Some decoded -> Some decoded
  | None -> decode_with_prefix text_magic false

(** Decode header, returns (orig_size, compressed_data, used_dict) if valid
    Supports:
    - Text-safe: ZSTD:<size>:<base64>, ZSTDD:<size>:<base64>
    - Legacy 8-byte: ZSTD + 4-byte size (backwards compat)
    - New 9-byte: ZSTD\x00 + 4-byte size (standard compression)
    - New 9-byte: ZSTDD + 4-byte size (dictionary compression)

    IMPORTANT: Check ZSTDD first because "ZSTDD" starts with "ZSTD" *)
let decode_header (data : string) : (int * string * bool) option =
  match decode_text_header data with
  | Some decoded -> Some decoded
  | None when String.length data < 8 -> None
  (* Check dictionary header FIRST (ZSTDD) *)
  | None when String.length data >= 9 && String.sub data 0 5 = magic_dict -> begin
    (* Dictionary header: ZSTDD *)
    let orig_size =
      (Char.code data.[5] lsl 24) lor
      (Char.code data.[6] lsl 16) lor
      (Char.code data.[7] lsl 8) lor
      Char.code data.[8]
    in
    let compressed = String.sub data 9 (String.length data - 9) in
    Some (orig_size, compressed, true)
    end
  (* Then check standard headers *)
  | None ->
      let header4 = String.sub data 0 4 in
      if header4 = magic then begin
        (* Could be legacy 8-byte or new 9-byte with ZSTD\x00 *)
        if String.length data >= 9 && data.[4] = '\x00' then begin
          (* New 9-byte header: ZSTD\x00 *)
          let orig_size =
            (Char.code data.[5] lsl 24) lor
            (Char.code data.[6] lsl 16) lor
            (Char.code data.[7] lsl 8) lor
            Char.code data.[8]
          in
          let compressed = String.sub data 9 (String.length data - 9) in
          Some (orig_size, compressed, false)
        end else begin
          (* Legacy 8-byte header *)
          let orig_size =
            (Char.code data.[4] lsl 24) lor
            (Char.code data.[5] lsl 16) lor
            (Char.code data.[6] lsl 8) lor
            Char.code data.[7]
          in
          let compressed = String.sub data 8 (String.length data - 8) in
          Some (orig_size, compressed, false)
        end
      end else
        None

(** Decompress with known original size and dict flag *)
let decompress ~(orig_size : int) ~(used_dict : bool) (compressed : string) : string option =
  match Compression_codec.decompress
          ~orig_size
          ~encoding:(Compression_codec.of_used_dict used_dict)
          compressed
  with
  | Ok decompressed -> Some decompressed
  | Error msg ->
      Log.Misc.error "decompress failed: %s" msg;
      None

(** Auto-decompress if ZSTD/ZSTDD header present *)
let decompress_auto (data : string) : string =
  match decode_header data with
  | Some (orig_size, compressed, used_dict) ->
      (match decompress ~orig_size ~used_dict compressed with
       | Some decompressed -> decompressed
       | None -> data)  (* Return original on failure *)
  | None -> data

(** Compress and add header if beneficial *)
let compress_with_header ?(level = default_level) (data : string) : string =
  let (compressed, used_dict, did_compress) = compress ~level data in
  if did_compress then
    encode_with_header ~used_dict (String.length data) compressed
  else
    data
