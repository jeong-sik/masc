(** Durable checkpoint operation evidence. Each call owns and closes its SQLite
    connection; call only on an IO worker. Terminal records are retained and
    immutable, so a duplicate operation ID never starts another effect. *)
type action = Save | Restore

type binding = {
  operation_id : Keeper_operation_id.t;
  action : action;
  slot : string;
}

type completion = {
  mark : Msx_lane.change_mark;
  checkpoint_sha256 : string;
}

type state = Pending | Committed of completion | Refused of string | Unknown of string

type receipt = { binding : binding; epoch : string; state : state }
type admission = Accepted | Existing of receipt

type error = Invalid_binding of string | Binding_conflict | Store_unavailable of string
val error_to_string : error -> string
val admit : path:string -> epoch:string -> binding -> (admission, error) result
val inspect : path:string -> binding -> (receipt option, error) result
(** Missing is unknown, never proof that an original request cannot still arrive.
    This read does not create a database or settle pending records after restart. *)
val settle : path:string -> epoch:string -> binding -> state -> (unit, error) result
(** Only this epoch's pending operation can settle. The caller publishes this
    inside the worker, after the effect, independently of HTTP response delivery.
    A persistence failure must remain unknown to the client. *)
