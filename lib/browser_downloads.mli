(** Download evidence comes only from BiDi events, never directory polling. *)
type completion = File of string | Path_unavailable
type status = Pending | Completed of completion | Canceled | Interrupted of string
type download = {
  id : string; context : string; url : string; filename : string option;
  status : status;
}
type t
val create : unit -> t
val event : t -> method_:string -> Yojson.Safe.t -> (unit, string) result
val add_tree : t -> Yojson.Safe.t -> (unit, string) result
val interrupt : t -> string -> unit
val for_context : t -> string -> download list
val to_json : verify:(string -> (string * int, string) result) -> download -> Yojson.Safe.t

(** A session-owned service. [read] remains available after interruption so
    callers can inspect the last evidence; [check] refuses further actions. *)
type connection = {
  read : context:string -> (Yojson.Safe.t, string) result;
  check : unit -> (unit, string) result;
  close : unit -> unit;
}
type start = session_id:string -> websocket_url:string -> (connection, string) result
