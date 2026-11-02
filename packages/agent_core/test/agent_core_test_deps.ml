(** Test-only dependency bundle for the imported agent core suites. *)

let admit_catalogs ~models ~providers =
  match Llm_provider.Catalog_snapshot.of_catalogs ~models ~providers with
  | Ok snapshot -> snapshot
  | Error error -> failwith (Llm_provider.Catalog_snapshot.error_to_string error)
