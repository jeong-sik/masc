type error =
  | Incomplete_stream of string
  | Capture_failed of string
  | Persistence_failed of string

val error_to_string : error -> string
val error_code : error -> string
val capture_directory : base_path:string -> string

type publication =
  { fields : (string * Yojson.Safe.t) list
  ; compared_output_bytes : int
  ; release_sources : unit -> unit
  }

val publish :
  inline_ceiling_bytes:int ->
    (** Valid UTF-8 combined output up to this many bytes is returned inline;
        larger or non-UTF-8 output is stored byte-for-byte as blobs. The caller passes the ceiling of the
        projection its result crosses for the lane running the call, so the
        bound is the one that lane declares ([maxResultSizeChars]). *)
  base_path:string ->
  redaction:Keeper_secret_redaction.t ->
  Process_output_capture.files ->
  (publication, error) result
(** Publish only EOF-confirmed streams. Redaction uses separate bounded stream
    states, and the combined artifact is stdout followed by stderr. Sources
    are removed only when the caller invokes [release_sources] after its
    result manifest has been committed. Incomplete or failed
    captures remain private and do not produce a complete-output claim. *)
