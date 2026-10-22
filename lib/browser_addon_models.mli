(** The browser worker's model requests. All calls belong to its Eio owner
    domain. No provider, credential or route resolution occurs here. *)
type configuration = {
  store_root : string;
  outputs : Lane_addon_types.exact_output list;
}
val configuration_to_json : configuration -> Yojson.Safe.t
val configuration_of_json : Yojson.Safe.t -> (configuration, string) result
type t
type error = Retired | Output_disabled of string | Request_in_use
  | Receipt_failed of string | Invalid_result of string
val error_to_string : error -> string
type outcome = Final of Lane_addon_exact.final
  | Exceeds_frame of { sha256 : string; bytes : int }
val create : incarnation:string -> configuration:configuration -> (t, string) result
val incarnation : t -> string
val request : t -> Lane_addon_exact.request -> (outcome, error) result
(** Publishes one request and waits. Completion/cancellation withdraws only
    this waiter and signals a new availability revision. No input is replayed. *)
val listing : t -> (Yojson.Safe.t, error) result
val deliver : t -> arguments:Yojson.Safe.t -> (bool, error) result
(** Persist the original request, result digest and result-received disposition
    before waking the original waiter. A conflicting duplicate is refused.
    Acceptance is receipt of a model result, never browser action completion. *)
val wait : t -> after:string option ->
  (Lane_addon_host_request.availability, error) result
(** Return current state, or suspend until it changes/retirement. Holds no
    owner admission lock and has no clock-driven wake or retry. *)
val retire : t -> unit
(** Fences new requests/results, withdraws pending work and wakes watchers. *)
