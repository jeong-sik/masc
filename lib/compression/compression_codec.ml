(** Shared compression codec surface.

    This module owns the raw zstd compression/decompression policy shared by
    the HTTP response path and machine checkpoints. *)

type compress_result =
  | Unchanged of string
  | Compressed of string

let min_size = 32
let content_encoding = "zstd"

let compress ?(level = 3) (data : string) : compress_result =
  let orig_size = String.length data in
  if orig_size < min_size then
    Unchanged data
  else
    try
      let compressed = Zstd.compress ~level data in
      if String.length compressed < orig_size then
        Compressed compressed
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
