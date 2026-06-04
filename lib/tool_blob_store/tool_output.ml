type t =
  | Inline of string
  | Stored of {
      sha256 : string;
      bytes : int;
      preview : string;
      mime : string;
    }

let marker_prefix = "[masc:blob "

let is_marker s = String.starts_with ~prefix:marker_prefix s

let encode_for_oas = function
  | Inline s -> s
  | Stored { sha256; bytes; preview; mime } ->
      Printf.sprintf "[masc:blob sha256=%s bytes=%d mime=%s preview=%S]"
        sha256 bytes mime preview

let decode_from_oas s =
  if not (is_marker s) then Inline s
  else
    try
      Scanf.sscanf s
        "[masc:blob sha256=%s@ bytes=%d mime=%s@ preview=%S]"
        (fun sha256 bytes mime preview ->
          Stored { sha256; bytes; preview; mime })
    with
    | Scanf.Scan_failure _ | Failure _ | Invalid_argument _ -> Inline s
