(** Context declarations tied to an exact provider and exact model. Generic
    family rows are not evidence for a server's configured context window. *)
val find : provider_id:string -> model:string ->
  Llm_provider.Model_catalog.model_entry list -> int option
