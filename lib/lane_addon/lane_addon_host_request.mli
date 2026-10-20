(** What a package lists through [lane_host_requests] and what it answers
    through [lane_host_result] (RFC operator-quiz §4.4). The request kinds are
    a closed set. A listing with a kind this host does not have, a malformed
    request or a request id listed twice is refused whole: the host cannot
    tell which part the package meant. *)

type t =
  | Exact_output of Lane_addon_exact.request
  | Read_records of { request_id : string; source_id : string; start : Lane_addon_records.start }
      (** Records of a granted source from [start]: the beginning, after a
          cursor the host gave in an earlier result ([after]), or since a Unix
          time ([since]). A request that names both [after] and [since] is
          malformed. *)
  | Read_file of { request_id : string; source_id : string; commit : string; path : string }
      (** One file's bytes at a commit of a granted repository. *)
  | Read_result of {
      request_id : string; original_request_id : string; source_id : string option;
      sha256 : string; offset : int;
    }
      (** A bounded slice of a result already retained for this same installation,
          original request and source. The advertised SHA alone grants no read. *)
  | Ask of { request_id : string; questions : Keeper_ask.question list; context : string option }
      (** Questions to the operator. The request id is the question's id. *)
  | Withdraw_ask of { request_id : string; ask_id : string; reason : string }
      (** The package no longer needs the answer to its question [ask_id]. *)

val request_id : t -> string
val to_json : t -> Yojson.Safe.t
(** Exact request identity retained with an oversized result. *)

val listing_of_json : Yojson.Safe.t -> (t list, string) result
(** Exactly [{"requests": [...]}], in the package's order. *)

val result_arguments : request_id:string -> result:Yojson.Safe.t -> Yojson.Safe.t
(** The [lane_host_result] arguments for one delivered result. *)

val accepted_of_json : Yojson.Safe.t -> (bool, string) result
(** Exactly [{"accepted": bool}]. *)

type availability = { revision : string; request_ids : string list }
val availability_to_json : availability -> Yojson.Safe.t
val availability_of_json : Yojson.Safe.t -> (availability, string) result
(** An opaque state token and the exact pending IDs of one original worker.
    A watcher waits for a different token; there is no periodic polling. *)
