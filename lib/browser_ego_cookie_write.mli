(** Cookie writes on an ego Page through its CDP session
    (RFC-browser-ego-cdp-capabilities §3.3 write_storage). They change the
    operator's ego profile, and an answer never carries a cookie value. *)

val script : string
(** [async function(page, args, reason)] answering the step's emit object:
    with [args.kind] ["set"] it sets one host-only cookie for the page's top
    document and reads it back; with ["delete"] it deletes each cookie of
    [args.name] the page sees by its name, domain and path, and reads again. *)

val set_args : label:string -> tab:int -> Browser_lane.Action.cookie -> Yojson.Safe.t
val delete_args : label:string -> tab:int -> name:string -> Yojson.Safe.t

val unknown_set : tab:int -> name:string -> string
val unknown_delete : tab:int -> name:string -> string
(** What a caller does about an outcome that is not known. *)

val set_receipt : tab:int -> cookie:Browser_lane.Action.cookie -> Yojson.Safe.t -> (Yojson.Safe.t, string) result
(** Refuses a cookie of another name or path, a domain cookie, or another
    shape. *)

val delete_receipt : tab:int -> name:string -> Yojson.Safe.t -> (Yojson.Safe.t, string) result
