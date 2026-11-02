val html_response :
  status_code:int -> headers:(string * string) list -> body:string -> string option
(** Summarize an explicitly declared HTML error response. JSON, non-HTML
    responses, and unsupported or ambiguous encodings without a usable BOM
    return [None] so the caller's existing decoder retains its error and
    credential handling. *)
