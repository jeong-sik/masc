type t = private string
(** The sha256 an export returns. It names the exported bytes in the
    workspace blob store, which holds everything else about them. *)

val of_blob : Tool_output.artifact_ref -> t
(** The reference an export hands out: the stored blob's own address. *)

val of_json : Yojson.Safe.t -> (t, string) result
(** Accept exactly the string an export returned. The blob store's sha256 rule
    decides what a valid address is. *)

val to_json : t -> Yojson.Safe.t
