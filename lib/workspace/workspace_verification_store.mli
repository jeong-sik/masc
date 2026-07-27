type verdict =
  [ `Pass
  | `Fail of string
  | `Partial of float * string ]

type request_status =
  [ `Pending
  | `Assigned of string
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
  | Evidence_read_error of string

type submitted_evidence_item =
  | Evidence_note of string
  | Evidence_artifact of
      { reference : string
      ; content : string
      ; bytes : int
      ; truncated : bool
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
val inspect_submitted_evidence :
  base_path:string ->
  request_id:string ->
  viewer:string ->
  submitted_evidence_access
val verifications_dir : string -> string
val request_path : string -> string -> string
val list_request_headers : string -> request_header list
