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
  | Evidence_invalid_reference
  | Evidence_invalid_utf8
  | Evidence_symbolic_link
  | Evidence_changed_during_read
  | Evidence_read_error of string

type submitted_evidence_item =
  | Evidence_note of string
  | Evidence_artifact of
      { reference : string
      ; content : string
      ; bytes : int
      ; truncated : bool
      ; content_sha256 : string
      }
  | Evidence_artifact_unreadable of
      { reference : string
      ; reason : evidence_read_failure
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

val submitted_evidence_access_to_yojson :
  submitted_evidence_access -> Yojson.Safe.t

val submitted_evidence_access_metadata_to_yojson :
  submitted_evidence_access -> Yojson.Safe.t

val evidence_read_failure_to_string : evidence_read_failure -> string
val evidence_access_failure_to_string :
  request_id:string -> evidence_access_failure -> string
val evidence_read_failure_of_owned_read_failure :
  Fs_compat.owned_regular_file_read_failure -> evidence_read_failure
val snapshot_submitted_evidence_json :
  base_path:string ->
  worker:string ->
  string list ->
  Yojson.Safe.t
(** Materialize submitted evidence once at the producer's submit boundary.
    ["artifact:<relative-path>"] is rooted at the producer's declared sandbox;
    ["note:<text>"] preserves non-file evidence explicitly.
    [content_sha256] covers the bounded UTF-8 content persisted in the
    snapshot, not bytes omitted beyond the projection cap. Bare and absolute
    references are persisted as typed invalid references. *)
val inspect_submitted_evidence_for_authority :
  base_path:string ->
  request_id:string ->
  task_id:string ->
  task_worker:string ->
  authority:Masc_domain.completion_authority ->
  submitted_evidence_access
(** Read submitted evidence after a trusted boundary has produced a completion
    authority. The task id and producer must still match the durable request. *)
val verifications_dir : string -> string
val request_path : string -> string -> string
val list_request_headers : string -> request_header list
