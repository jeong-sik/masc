(** Download evidence comes from the Ego connection's native download events
    or its Page.fetch save receipt, never directory polling. The Ego adapter
    keeps these sources distinct in its public rows. *)
type status = Pending | Completed of string | Interrupted of string
type download = {
  id : string; context : string; url : string; filename : string option;
  status : status;
}
(** One row as a read answers it. A completed file that
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

(** [verify_file ~root path] is [path]'s canonical name and size when it is a
    regular file inside [root]. A symlink, a directory or a file outside
    [root] is an [Error]. *)
val verify_file : root:string -> string -> (string * int, string) result
