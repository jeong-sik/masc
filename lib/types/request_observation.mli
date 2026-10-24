(** Read-only native execution evidence copied from its authoritative journal.
    A resumed call can include earlier turns in that same call; [turn] and
    [node_id] keep those occurrences distinct. This is not dispatch authority. *)
type provider_request =
  { node_id : string
  ; turn : int
  ; ordinal : int
  ; provenance : Llm_provider.Completion_outcome.request_provenance option
  }

type evidence =
  | Not_dispatched
  | No_durable_scope
  | No_matching_call
  | Read_failed of string
  | Recorded of { call_id : string; requests : provider_request list }

type t = { runtime_profile : string; attempt : int; evidence : evidence }

val to_json : t -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> (t, string) result
