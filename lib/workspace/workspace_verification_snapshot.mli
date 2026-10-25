(** Immutable submitted evidence and its persistence, judge-transport and
    metadata representations. Acquisition and storage stay with the store. *)

type request_header = {
  id : string;
  task_id : string;
  worker : string;
  created_at : float;
}

type evidence_read_failure =
  | Evidence_missing
  | Evidence_not_regular_file
  | Evidence_outside_worker_playground
  | Evidence_invalid_utf8
  | Evidence_symbolic_link
  | Evidence_changed_during_read
  | Evidence_read_error of string

type collaboration_kind = Board_source | Fusion_source | Task_source

type submitted_evidence_item =
  | Evidence_collaboration of { reference : string; content : string; sha256 : string }
  | Evidence_note of string
  | Evidence_artifact of
      { reference : string
      ; content : string
      ; bytes : int
      ; truncated : bool
      }
  | Evidence_invalid_reference
  | Evidence_artifact_unreadable of
      { reference : string
      ; reason : evidence_read_failure
      }
  | Evidence_artifact_binary of
      { reference : string
      ; bytes : int
      ; sha256 : string
      ; format : string
      ; body : string option
      }

type evidence_access_failure =
  | Completion_authority_identity_missing
  | Request_not_found
  | Request_header_invalid of string
  | Evidence_snapshot_invalid of string
  | Request_load_error of string
  | Request_scope_mismatch

type submitted_evidence_access =
  | Evidence_available of
      { request : request_header
      ; items : submitted_evidence_item list
      }
  | Evidence_unavailable of
      { request_id : string
      ; reason : evidence_access_failure
      }

val request_header_of_yojson :
  Yojson.Safe.t -> (request_header, string) result
val request_header_to_yojson : request_header -> Yojson.Safe.t

val submitted_evidence_item_fields :
  submitted_evidence_item -> (string * Yojson.Safe.t) list
val submitted_evidence_item_to_yojson : submitted_evidence_item -> Yojson.Safe.t
val submitted_evidence_item_of_yojson :
  Yojson.Safe.t -> (submitted_evidence_item, string) result
val submitted_evidence_item_metadata_to_yojson :
  submitted_evidence_item -> Yojson.Safe.t

val submitted_evidence_access_to_yojson :
  submitted_evidence_access -> Yojson.Safe.t
val submitted_evidence_access_transport_to_yojson :
  submitted_evidence_access -> Yojson.Safe.t
val submitted_evidence_access_metadata_to_yojson :
  submitted_evidence_access -> Yojson.Safe.t

val submitted_evidence_snapshot_of_request_json :
  Yojson.Safe.t -> (submitted_evidence_item list, string) result
(** Decode the request's stored snapshot in order, stopping at the first
    malformed item. Header validation belongs to the caller. *)

val submitted_evidence_identity_lines :
  Yojson.Safe.t -> (string list, string) result
val truncated_snapshot_items : Yojson.Safe.t -> (string * int) list

val evidence_read_failure_code : evidence_read_failure -> string
val evidence_access_failure_to_string :
  request_id:string -> evidence_access_failure -> string

val collaboration_reference : string -> (collaboration_kind * string) option
val note_reference_prefix : string
(** Shared by identity rendering and the store's reference classifier. *)

val verification_evidence_max_bytes : int
(** The shared Tool_shard_limits ceiling used for snapshot content and delivery. *)
