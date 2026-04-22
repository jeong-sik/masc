(** Cryptographically random identifier helper.

    See [random_id.mli] for API rationale. Implementation is the
    canonical form of the pattern that was duplicated across
    verification/board/autoresearch/coord/streamable_http — every
    site did [Mirage_crypto_rng.generate N |> hex encode] with
    slight formatting variance. *)

let hex ~bytes =
  let rnd = Mirage_crypto_rng.generate bytes in
  List.fold_left (fun acc s -> acc ^ s) "" (List.init (String.length rnd) (fun i -> Printf.sprintf "%02x" (Char.code (String.get rnd i))))

let prefixed ~prefix ~bytes =
  prefix ^ hex ~bytes
