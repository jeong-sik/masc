(** Leaf split for runtime model ids. See .mli for the contract. *)

let split_provider_model (s : string) : (string * string) option =
  match String.index_opt s ':' with
  | None -> None
  | Some idx ->
    if idx = 0 || idx >= String.length s - 1
    then None
    else (
      let provider_name =
        String.sub s 0 idx |> String.trim |> String.lowercase_ascii
      in
      let model_id =
        String.sub s (idx + 1) (String.length s - idx - 1) |> String.trim
      in
      if model_id = "" then None else Some (provider_name, model_id))
;;
