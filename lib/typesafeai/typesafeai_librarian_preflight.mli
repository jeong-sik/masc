(** A semantic no-change judgment. Text generation and commit authority stay
    with the existing Librarian pipeline. *)
type decision = Keep_current | Needs_generation | Uncertain
val decision_label : decision -> string
val decode_judgment : Yojson.Safe.t -> (decision Typesafeai_types.decoded_choice, string) result
type outcome =
  | Awaiting_answer
  | Skipped of Typesafeai_config.unavailable_reason
  | Ineligible of string
  | Question_unavailable of string
  | Failed of Typesafeai_client.failure
  | Invalid_answer of Typesafeai_client.evaluated * string
  | Judged of Typesafeai_client.evaluated * decision Typesafeai_types.decoded_choice
type t = { outcome : outcome; elapsed_s : float option }
(** [request] renders the [librarian_request] JEV reads: the Librarian's
    Memory-pass request with the current memories left out, so the judgment
    is about the new evidence alone. It is called only for an eligible pass
    whose preflight is configured; a rendering error is
    [Question_unavailable]. *)
val assess :
  ?observe:(t -> unit) ->
  clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  keeper_id:string -> eligible:bool -> request:(unit -> (string, string) result) -> unit -> t
val keeps_current : t -> bool
val to_yojson : t -> Yojson.Safe.t
