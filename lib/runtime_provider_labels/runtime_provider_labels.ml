(** Runtime-boundary projection for provider labels. *)

let canonical_provider_label raw =
  let trimmed = String.trim raw in
  if String.equal trimmed ""
  then None
  else (
    match Llm_provider.Provider_config.provider_kind_of_string trimmed with
    | Some kind -> Some (Llm_provider.Provider_config.string_of_provider_kind kind)
    | None -> Some (String.lowercase_ascii trimmed))
;;
