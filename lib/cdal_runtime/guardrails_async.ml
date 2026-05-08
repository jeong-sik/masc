(** Async guardrail validator types — see [.mli] for docs. *)

type input_validator =
  { name : string
  ; validate : Types.message list -> (unit, string) result
  }

type output_validator =
  { name : string
  ; validate : Types.api_response -> (unit, string) result
  }
