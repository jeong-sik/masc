(** Canonical closed codec for the durable provider response authority. *)

val to_yojson : Llm_provider.Types.api_response -> Yojson.Safe.t
val of_yojson : Yojson.Safe.t -> (Llm_provider.Types.api_response, string) result
val validate : Llm_provider.Types.api_response -> (unit, string) result
