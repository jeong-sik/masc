(** What a package lists through [lane_host_requests] and what it answers
    through [lane_host_result] (RFC operator-quiz §4.4). The request kinds are
    a closed set. A listing with a kind this host does not have, a malformed
    request or a request id listed twice is refused whole: the host cannot
    tell which part the package meant. *)

type t =
  | Exact_output of Lane_addon_exact.request
  | Read_records of { request_id : string; source_id : string; after : string option }
      (** Records of a granted source after [after], a cursor the host gave in
          an earlier result. [None] reads from the beginning. *)

val request_id : t -> string

val listing_of_json : Yojson.Safe.t -> (t list, string) result
(** Exactly [{"requests": [...]}], in the package's order. *)

val result_arguments : request_id:string -> result:Yojson.Safe.t -> Yojson.Safe.t
(** The [lane_host_result] arguments for one delivered result. *)

val accepted_of_json : Yojson.Safe.t -> (bool, string) result
(** Exactly [{"accepted": bool}]. *)
