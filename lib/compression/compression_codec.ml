(** Shared compression codec surface.

    This module owns the raw zstd compression/decompression policy so transport
    and backend layers depend on a neutral codec rather than backend-local
    helpers. *)

type encoding =
  | Standard
  | Dictionary

type compressed =
  { payload : string
  ; encoding : encoding
  }

type compress_result =
  | Unchanged of string
  | Compressed of compressed

let min_size = 32
let max_dict_size = 2048
let should_use_dict (size : int) : bool = size >= min_size
let get_dict () : string = ""
let has_dict () : bool = false

let uses_dict = function
  | Dictionary -> true
  | Standard -> false
;;

let of_used_dict used_dict = if used_dict then Dictionary else Standard

let content_encoding = function
  | Dictionary -> "zstd-dict"
  | Standard -> "zstd"
;;

let compress ?(level = 3) (data : string) : compress_result =
  let orig_size = String.length data in
  if orig_size < min_size
  then Unchanged data
  else (
    try
      let compressed = Zstd.compress ~level data in
      if String.length compressed < orig_size
      then Compressed { payload = compressed; encoding = Standard }
      else Unchanged data
    with
    | Failure msg | Zstd.Error msg ->
      Log.Misc.error "compression failed: %s" msg;
      Unchanged data)
;;

let decompress ~(orig_size : int) ~encoding (data : string)
  : (string, string) Stdlib.result
  =
  let _ = encoding in
  try Ok (Zstd.decompress orig_size data) with
  | Failure msg | Zstd.Error msg -> Error msg
;;
