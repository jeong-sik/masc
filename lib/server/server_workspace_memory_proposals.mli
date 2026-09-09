val get : base_path:string -> id:string option -> Httpun.Status.t * Yojson.Safe.t
val post : base_path:string -> string -> Httpun.Status.t * Yojson.Safe.t
