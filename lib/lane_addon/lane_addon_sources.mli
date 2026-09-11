(** Source adapters reuse existing lane owners. They acquire observations only;
    packages decide what those observations mean. Files are explicitly bound by
    the installer, never dereferenced from package output. *)
val validate : Yojson.Safe.t -> (unit, string) result
val acquire : store:Lane_addon_store.t -> package:Lane_addon_types.package ->
  binding:Yojson.Safe.t -> (Yojson.Safe.t, string) result
(** The complete returned source array fits the package's ingress envelope.
    Unavailable sources retain explicit coverage entries. Bound file snapshots
    retain their exact bytes and hash in [store], independently of file rotation;
    evidence declared by a producer is never dereferenced by acquisition. *)
