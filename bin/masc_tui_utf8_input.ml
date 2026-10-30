(* One character, assembled from bytes that may arrive across several reads.
   See the .mli for why a run that ends early is not a failure. *)

type outcome =
  | Complete of string
  | Incomplete of string
  | Malformed of { pushback : char option }

let is_continuation byte =
  let code = Char.code byte in
  code >= 0x80 && code <= 0xBF
;;

let read_scalar ~prefix ~expected_length ~next_byte =
  let buffer = Buffer.create expected_length in
  Buffer.add_string buffer prefix;
  let rec fill () =
    if Buffer.length buffer >= expected_length then begin
      let scalar = Buffer.contents buffer in
      (* The length came from the leading byte, so a full buffer is usually
         well-formed; an overlong encoding or a surrogate is not, and is a
         decoding failure with nothing to push back. *)
      if String.is_valid_utf_8 scalar then Complete scalar
      else Malformed { pushback = None }
    end
    else
      match next_byte () with
      | None -> Incomplete (Buffer.contents buffer)
      | Some byte when is_continuation byte ->
          Buffer.add_char buffer byte;
          fill ()
      | Some byte -> Malformed { pushback = Some byte }
  in
  fill ()
;;
