(** Pure declaration projection from one already interpreted Runtime source.
    No catalog, environment, credential or account observation is performed. *)
type context_source = Binding | Provider | Model

type binding = {
  model : string;
  provider : string;
  api_name : string;
  reasoning_effort : Llm_provider.Reasoning_effort.t option;
  temperature : float option;
  context : (context_source * int) option;
  model_context : int option;
  max_tokens : int option;
}

type t = private { provider_ids : string list; bindings : binding list }
(** Includes providers with no binding, so account-group references can be
    checked without interpreting the original source again. Absent context
    and output limits stay absent; no catalog value is invented. *)

val of_config : Runtime_schema.config -> (t, string) result
(** Every declared binding, including disabled providers; rejects dangling or
    duplicate declaration identities rather than silently dropping them. *)

val to_json : path:string -> source_revision:string -> (t, string) result -> Yojson.Safe.t
val of_json : path:string -> source_revision:string -> Yojson.Safe.t -> (t, string) result
(** The envelope must carry the exact expected path/revision before an available
    projection is accepted. Unavailable, malformed, unknown or mismatched input
    stays an error. This value grants no edit or read authority. *)
