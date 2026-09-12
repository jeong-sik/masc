(** One request identity belongs to one worker incarnation. A package's confirmed
    result is explicitly distinct from the host merely queuing or dispatching it. *)
type state = Queued | Running | Confirmed | Failed_before_effect | Outcome_unknown
type receipt = {
  instance_id : string;
  incarnation : string;
  request_id : string;
  requester : string;
  executor : string option;
  input_sha256 : string;
  action : Yojson.Safe.t;
  state : state;
  result : Yojson.Safe.t option;
  detail : string option;
}
type package_status = Package_confirmed | Package_failed_before_effect | Package_outcome_unknown
type package_result = { status : package_status; result : Yojson.Safe.t; output : Lane_addon_types.output }
val to_json : receipt -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> (receipt, string) result
val canonical : Yojson.Safe.t -> (Yojson.Safe.t, string) result
val arguments : instance_id:string -> request_id:string -> action:Yojson.Safe.t -> Yojson.Safe.t
val context : string -> Yojson.Safe.t
val validate_schema : Yojson.Safe.t -> (unit, string) result
val validate : schema:Yojson.Safe.t -> name:string -> Yojson.Safe.t -> (Yojson.Safe.t, string) result
val input_digest : Yojson.Safe.t -> string
val decode_result : store:Lane_addon_store.t -> max_bytes:int -> Yojson.Safe.t -> (package_result, string) result
