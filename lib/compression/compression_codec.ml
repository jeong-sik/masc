(** Shared compression codec surface.

    This module owns the raw zstd compression/decompression policy so transport
    and backend layers depend on a neutral codec rather than backend-local
    helpers. *)

type encoding =
  | Standard
  | Dictionary

type compressed = {
  payload: string;
  encoding: encoding;
}

type compress_result =
  | Unchanged of string
  | Compressed of compressed

let min_size = 32
let uses_dict = function
  | Dictionary -> true
  | Standard -> false

let content_encoding = function
  | Dictionary -> "zstd-dict"
  | Standard -> "zstd"

let compress ?(level = 3) (data : string) : compress_result =
  let orig_size = String.length data in
  if orig_size < min_size then
    Unchanged data
  else
    try
      let compressed = Zstd.compress ~level data in
      if String.length compressed < orig_size then
        Compressed { payload = compressed; encoding = Standard }
      else
        Unchanged data
    with Failure msg | Zstd.Error msg ->
      Log.Misc.error "compression failed: %s" msg;
      Unchanged data

let decompress ~(orig_size : int) (data : string) : (string, string) Stdlib.result =
  try
    Ok (Zstd.decompress orig_size data)
  with Failure msg | Zstd.Error msg ->
    Error msg
