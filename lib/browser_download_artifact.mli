(** Publish a previously verified, session-owned download into the existing
    durable blob store. The reader accepts the returned sha256 on every runtime. *)
val publish : base_path:string -> string -> (Yojson.Safe.t, string) result
