(** Resolve explicit model labels to an AGENT_CORE runtime binding.
    The selected binding is carried to config construction; provider identity,
    endpoint and declared default are not rediscovered from label/URL strings. *)

type resolution =
  | Registered of
      { binding : Agent_core.Provider_runtime_binding.t
      ; model_id : string
      }
  | Custom_url of { model_id : string; base_url : string }
      (** Explicit [custom:model@url] selects the OpenAI-compatible wire. *)
  | Unknown of string
      (** Malformed input or unknown provider; no default wire is inferred. *)

val resolve : string -> resolution
