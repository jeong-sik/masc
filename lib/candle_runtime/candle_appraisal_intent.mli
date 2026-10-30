(** Immutable Candle request snapshot for the existing Addon submission port.
    Creation is pure: it does not admit a worker, call a provider, persist data or
    authorize a payment. Only the rendered prompt becomes a model message. *)
type t
val make : identity:Candle_appraisal.identity -> prompt:string -> Candle_appraisal.request -> (t, string) result
(** Capture the original payout identity, stage, Relation task ID, model input,
    complete consumer schema and rendered prompt. Blank audit identifiers and
    prompts are refused. The same canonical snapshot has the same request ID;
    a changed input is a distinct snapshot, never an overwrite of the old one. *)
val request_id : t -> string
val request : t -> Candle_appraisal.request
(** The original request retained for full domain decoding of an answer. *)
val to_worker_request : t -> Yojson.Safe.t
val submit_arguments : t -> Yojson.Safe.t
val read_arguments : t -> Yojson.Safe.t
