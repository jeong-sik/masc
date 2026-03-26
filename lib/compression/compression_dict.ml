(** Compression for Small Messages - Simplified

    Compatibility facade for callers that still expect Compression_dict.
    The actual codec now lives in Compression_codec. *)

(** {1 Size Thresholds} *)

let min_dict_size = Compression_codec.min_size
let max_dict_size = Compression_codec.max_dict_size
let should_use_dict = Compression_codec.should_use_dict

(** {1 Dictionary Stubs} *)

let get_dict = Compression_codec.get_dict
let has_dict = Compression_codec.has_dict

(** {1 Compression} *)

let compress ?(level = 3) (data : string) : string * bool * bool =
  match Compression_codec.compress ~level data with
  | Compression_codec.Unchanged payload -> (payload, false, false)
  | Compression_codec.Compressed { payload; encoding } ->
      (payload, Compression_codec.uses_dict encoding, true)

let decompress ~orig_size ~(used_dict : bool) (data : string) : string =
  match Compression_codec.decompress
          ~orig_size
          ~encoding:(Compression_codec.of_used_dict used_dict)
          data
  with
  | Ok decompressed -> decompressed
  | Error msg ->
      Log.Misc.error "decompression failed: %s" msg;
      data

(** {1 Content-Encoding Headers} *)

let encoding_with_dict =
  Compression_codec.content_encoding Compression_codec.Dictionary

let encoding_standard =
  Compression_codec.content_encoding Compression_codec.Standard

(** {1 Version Info} *)

let version = "6.0.0"
let version_string = "MASC Compression v6.0 (simplified)"
