val json : config:Workspace.config -> ?me:string -> limit:int -> unit -> Yojson.Safe.t

val mentions_of_message : Masc_domain.message -> string list
(** Every agent name this message mentions: the typed [mention] field first,
    then [@word] tokens parsed from the body, deduplicated in order. The one
    mention extractor for dashboard read models — consumers must not grow
    their own content scanners (#27324). *)
