(** Download evidence comes from native browser download events or an Ego
    Page.fetch save receipt, never directory polling. The Ego adapter keeps
    these sources distinct in its public rows. *)
type completion = File of string | Path_unavailable
type status = Pending | Completed of completion | Canceled | Interrupted of string
type download = {
  id : string; context : string; url : string; filename : string option;
  status : status;
}
type t
val create : unit -> t

(** BiDi event kinds this model handles, with the wire method names to pass
    to [session.subscribe]. [event] fails with the method name on any other. *)
type subscribed = Context_created | Download_will_begin | Download_end
val subscribed_methods : (subscribed * string) list
val event : t -> method_:string -> Yojson.Safe.t -> (unit, string) result
val add_tree : t -> Yojson.Safe.t -> (unit, string) result
val interrupt : t -> string -> unit
val for_context : t -> string -> download list
val to_json : verify:(string -> (string * int, string) result) -> download -> Yojson.Safe.t

(** [to_json] of one row as a read answers it. A completed file that
    [verify] still finds is handed to [publish] once; the marker it answers
    is kept in [published] by download id and carried as [artifact] on this
    and later reads. A failed publication is answered as [artifactError]
    and tried again on the next read. *)
val published_json
  :  verify:(string -> (string * int, string) result)
  -> publish:(string -> (Yojson.Safe.t, string) result)
  -> published:(string, Yojson.Safe.t) Hashtbl.t
  -> download
  -> Yojson.Safe.t

(** A session-owned service. [console] reads the tab's console entries ({!Browser_console}) from the
    same event stream. [read] remains available after interruption so
    callers can inspect the last evidence; [check] refuses further actions.
    [block] makes every request of a top-level [context] and its frames to one
    of [hosts] fail and returns the intercept doing it; [unblock] removes one.
    The connection fails every request held on its session, so intercepts are
    added through [block] only, never through [command]. *)
type connection = {
  read : context:string -> (Yojson.Safe.t, string) result;
  console : context:string -> (Yojson.Safe.t, string) result;
  network : context:string -> (Yojson.Safe.t, string) result;
  check : unit -> (unit, string) result;
  command : string -> Yojson.Safe.t -> (Yojson.Safe.t, string) result;
  block : context:string -> hosts:string list -> (string, string) result;
  unblock : intercept:string -> (unit, string) result;
  close : unit -> unit;
}
type start = session_id:string -> websocket_url:string -> (connection, string) result
