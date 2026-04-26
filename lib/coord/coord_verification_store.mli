type verdict =
  [ `Pass
  | `Fail of string
  | `Partial of float * string
  ]

type request_status =
  [ `Pending
  | `Assigned of string
  | `Completed of verdict
  ]

type request_header =
  { id : string
  ; task_id : string
  ; worker : string
  ; verifier : string option
  ; created_at : float
  ; status : request_status
  }

val verifications_dir : string -> string
val request_path : string -> string -> string
val list_request_headers : string -> request_header list
