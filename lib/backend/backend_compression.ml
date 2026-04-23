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

(** Compress with zstd + optional dictionary *)
let compress ?(level = default_level) (data : string) : (string * bool * bool) =
  match Compression_codec.compress ~level data with
  | Compression_codec.Unchanged payload -> (payload, false, false)
  | Compression_codec.Compressed { payload; encoding } ->
      (payload, Compression_codec.uses_dict encoding, true)

(** Encode with size header: MAGIC (5) + orig_size (4 BE) + compressed
    MAGIC = "ZSTD\x00" for standard, "ZSTDD" for dictionary *)
let encode_with_header ~(used_dict : bool) (orig_size : int) (compressed : string) : string =
  let header = Bytes.create 9 in
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

(** Decode header, returns (orig_size, compressed_data, used_dict) if valid
    Supports:
    - Legacy 8-byte: ZSTD + 4-byte size (backwards compat)
    - New 9-byte: ZSTD\x00 + 4-byte size (standard compression)
    - New 9-byte: ZSTDD + 4-byte size (dictionary compression)

    IMPORTANT: Check ZSTDD first because "ZSTDD" starts with "ZSTD" *)
let decode_header (data : string) : (int * string * bool) option =
  if String.length data < 8 then None
  (* Check dictionary header FIRST (ZSTDD) *)
  else if Base.String.is_prefix data ~prefix:magic_dict then begin
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
  else
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

(** Compress and add header if beneficial.
    Compression disabled: 4TB SSD makes ZSTD savings negligible, and corrupt
    ZSTD headers in PG caused server-wide decompress storms (2026-03-28).
    Kept as passthrough so callers need no changes. *)
let compress_with_header ?(level = default_level) (data : string) : string =
  let _ = level in
  data
