(** Backend compression — zstd compression with dictionary support.

    Compact Protocol v4: Transparent zstd compression with Dictionary
    - Uses trained multi-format dictionary for 32-2048 byte messages
    - Dictionary achieves ~70% compression vs ~6% standard zstd on small data
    - Automatically compresses data >32 bytes on save
    - Automatically decompresses on load (ZSTD/ZSTDD header detection) *)

(** Minimum size for dictionary compression *)
let min_size = Compression_codec.min_size  (* 32 bytes *)

(** Default compression level *)
let default_level = 3

(** ZSTD header magic (standard compression) *)
let magic = "ZSTD"

(** ZSTDD header magic (dictionary compression) *)
let magic_dict = "ZSTDD"

(** Header frame length: 5-byte magic + 4-byte big-endian original size *)
let header_len = 9

(** Compress with zstd + optional dictionary *)
let compress ?(level = default_level) (data : string) : (string * bool * bool) =
  match Compression_codec.compress ~level data with
  | Compression_codec.Unchanged payload -> (payload, false, false)
  | Compression_codec.Compressed { payload; encoding } ->
      (payload, Compression_codec.uses_dict encoding, true)

(** Encode with size header: MAGIC (5) + orig_size (4 BE) + compressed
    MAGIC = "ZSTD\x00" for standard, "ZSTDD" for dictionary *)
let encode_with_header ~(used_dict : bool) (orig_size : int) (compressed : string) : string =
  let header = Bytes.create header_len in
  if used_dict then
    Bytes.blit_string magic_dict 0 header 0 5  (* "ZSTDD" = 5 chars *)
  else begin
    Bytes.blit_string magic 0 header 0 4;      (* "ZSTD" = 4 chars *)
    Bytes.set header 4 '\x00'                   (* + null = 5 chars *)
  end;
  Bytes.set header 5 (Char.chr ((orig_size lsr 24) land 0xFF));
  Bytes.set header 6 (Char.chr ((orig_size lsr 16) land 0xFF));
  Bytes.set header 7 (Char.chr ((orig_size lsr 8) land 0xFF));
  Bytes.set header 8 (Char.chr (orig_size land 0xFF));
  Bytes.to_string header ^ compressed

(** Decode header, returns (orig_size, compressed_data, used_dict) if valid.
    Accepts exactly the two 9-byte frames [encode_with_header] writes:
    - ZSTD\x00 + 4-byte size (standard compression)
    - ZSTDD + 4-byte size (dictionary compression)
    Anything else, including "ZSTD" followed by a byte other than NUL or
    'D', is not a header. *)
let decode_header (data : string) : (int * string * bool) option =
  if String.length data < header_len then None
  else
    let used_dict =
      if String.starts_with data ~prefix:magic_dict then Some true
      else if String.starts_with data ~prefix:magic && data.[4] = '\x00' then
        Some false
      else None
    in
    match used_dict with
    | None -> None
    | Some used_dict ->
      let orig_size =
        (Char.code data.[5] lsl 24) lor
        (Char.code data.[6] lsl 16) lor
        (Char.code data.[7] lsl 8) lor
        Char.code data.[8]
      in
      let compressed =
        String.sub data header_len (String.length data - header_len)
      in
      Some (orig_size, compressed, used_dict)

(** Decompress with known original size *)
let decompress ~(orig_size : int) (compressed : string) : string option =
  match Compression_codec.decompress ~orig_size compressed with
  | Ok decompressed -> Some decompressed
  | Error msg ->
      Log.Misc.error "decompress failed: %s" msg;
      None

(** Auto-decompress if ZSTD/ZSTDD header present *)
let decompress_auto (data : string) : string =
  match decode_header data with
  | Some (orig_size, compressed, _) ->
      (match decompress ~orig_size compressed with
       | Some decompressed -> decompressed
       | None -> data)  (* Return original on failure *)
  | None -> data

(** Compress and add header if beneficial.
    Compression disabled: 4TB SSD makes ZSTD savings negligible, and corrupt
    ZSTD headers in PG caused server-wide decompress storms (2026-03-28).
    Kept as passthrough so callers need no changes. *)
let compress_with_header ?(level = default_level) (data : string) : string =
  let _ = level in
  data
