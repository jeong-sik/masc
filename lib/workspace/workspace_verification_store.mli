type verdict =
  [ `Pass
  | `Fail of string
  | `Partial of float * string ]

type request_status =
  [ `Pending
  | `Completed of verdict ]

type request_header = {
  id : string;
  task_id : string;
  worker : string;
  verifier : string option;
  created_at : float;
  status : request_status;
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

type submitted_evidence_access =
  | Evidence_available of
      { request : request_header
      ; items : submitted_evidence_item list
      }
  | Evidence_metadata_only of
      { request : request_header
      ; viewer : string
      }
  | Evidence_unavailable of
      { request_id : string
      ; reason : string
      }

val evidence_read_failure_to_string : evidence_read_failure -> string
val evidence_read_failure_of_owned_read_failure :
  Fs_compat.owned_regular_file_read_failure -> evidence_read_failure
val snapshot_submitted_evidence_json :
  base_path:string ->
  worker:string ->
  string list ->
  Yojson.Safe.t
(** Materialize submitted evidence once at the producer's submit boundary.
    ["artifact:<relative-path>"] is rooted at the producer's declared sandbox;
    absolute paths remain accepted only when contained by that same playground.
    [content_sha256] covers the bounded UTF-8 content persisted in the
    snapshot, not bytes omitted beyond the projection cap. Bare and absolute
    references are persisted as typed invalid references. *)
val inspect_submitted_evidence :
  base_path:string ->
  request_id:string ->
  task_id:string ->
  task_worker:string ->
  task_verifier:string option ->
  viewer:string ->
  submitted_evidence_access
val verifications_dir : string -> string
val request_path : string -> string -> string
val list_request_headers : string -> request_header list
