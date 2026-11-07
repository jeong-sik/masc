open Printf

let default_pool_label = "local64"

let runtime_port base_url =
  try Uri.of_string base_url |> Uri.port with Failure _ -> None

let runtime_id_of_base_url base_url =
  match runtime_port base_url with
  | Some port -> sprintf "local-%d" port
  | None ->
      let digest = Digest.string base_url |> Digest.to_hex in
      sprintf "local-%s" (String.sub digest 0 8)
