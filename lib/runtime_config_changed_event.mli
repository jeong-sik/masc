(** The runtime.toml text was committed and is visible on disk. It carries no
    text: a reader that shows the file ([GET /api/v1/runtime/config/raw]) reads
    it again. *)

val event_type : string

val json : ts_unix:float -> Yojson.Safe.t
