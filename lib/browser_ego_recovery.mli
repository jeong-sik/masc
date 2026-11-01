(** Native recovery on one already managed Ego Page. This script checks the
    bound Space and managed Page identity without Page reads; it never uses
    the document URL, info, snapshot, or download watcher as a precondition. *)
val script : string

(** Validate the exact Page identity and the native stopLoading command-return
    acknowledgement. This proves neither document readiness nor input release. *)
val receipt : space_id:int -> tab_id:int -> label:string -> Yojson.Safe.t ->
  (Yojson.Safe.t, string) result
