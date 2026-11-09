let () = print_endline (String.concat "," (List.map (function `XOR -> "XOR" | `AES -> "AES" | `GHASH -> "GHASH") Mirage_crypto.accelerated))
