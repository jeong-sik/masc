(** Where [GET /api/v1/media/<sha256>] finds workspace media, for the readers
    that report a reference as present or missing. *)

val exists : base_path:string -> string -> (bool, string) result
(** [exists ~base_path sha256] answers in the order the media route serves.
    [Ok true] when the attachment store holds metadata for [sha256].
    [Error _] when that metadata cannot be read: the route then answers with
    an error and never reaches the legacy store. Otherwise whether the legacy
    keeper chat media store has a file for [sha256]. *)

val known_missing : base_path:string -> string list -> string list
(** The digests in [sha256s] that {!exists} answers [Ok false] for, in order.
    A digest whose metadata cannot be read is left out: it is not known to be
    missing. *)
