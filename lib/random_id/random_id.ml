(** Cryptographically random identifier helper.

    See [random_id.mli] for API rationale. Implementation is the
    canonical form of the pattern that was duplicated across
    verification/board/autoresearch/coord/streamable_http — every
    site did [Mirage_crypto_rng.generate N |> hex encode] with
    slight formatting variance. *)

let hex_char n = Char.chr (if n < 10 then Char.code '0' + n else Char.code 'a' + n - 10)

let hex ~bytes =
  let rnd = Mirage_crypto_rng.generate bytes in
  let len = String.length rnd in
  let buf = Bytes.create (len * 2) in
  for i = 0 to len - 1 do
    let b = Char.code (String.get rnd i) in
    Bytes.set buf (i * 2) (hex_char (b lsr 4));
    Bytes.set buf (i * 2 + 1) (hex_char (b land 0x0f))
  done;
  Bytes.to_string buf

let prefixed ~prefix ~bytes =
  prefix ^ hex ~bytes
