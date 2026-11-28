type error =
  | Incomplete_stream of string
  | Capture_failed of string
  | Persistence_failed of string

val error_to_string : error -> string
val error_code : error -> string
val capture_directory : base_path:string -> string

type placed =
  | Returned_inline  (** [fields] holds the output itself, as [output]. *)
  | Stored_as_artifacts
  (** [fields] holds the references {!stream_artifact_fields} writes. *)

type publication =
  { fields : (string * Yojson.Safe.t) list
  ; placed : placed
  (** Where this publication put the output. A caller reads it here and not
      from the names in [fields]. *)
  ; compared_output_bytes : int
  ; release_sources : unit -> unit
  }

type placement =
  | Inline_when_at_most of int
  (** Valid UTF-8 combined output up to this many bytes is returned inline;
      larger or non-UTF-8 output is stored byte-for-byte as blobs. The caller
      passes the ceiling of the projection its result crosses for the lane
      running the call, so the bound is the one that lane declares
      ([maxResultSizeChars]). *)
  | Stored
  (** The output is stored as blobs whatever its size. The caller names this
      after it found that the result carrying the output inline does not fit
      its lane (#55433). *)

val publish :
  placement:placement ->
  base_path:string ->
  redaction:Keeper_secret_redaction.t ->
  Process_output_capture.files ->
  (publication, error) result
(** Publish only EOF-confirmed streams. Redaction uses separate bounded stream
    states, and the combined artifact is stdout followed by stderr. Sources
    are removed only when the caller invokes [release_sources] after its
    result manifest has been committed. Incomplete or failed
    captures remain private and do not produce a complete-output claim.

    The same files may be published again with another [placement] before
    any publication is released: a publication reads the sources and removes
    only its own temporary files, and [Inline_when_at_most] stores nothing
    when it returns the output inline. Each publication's [release_sources]
    removes the same sources, so the caller invokes the one it keeps and
    drops the other. *)

val stream_artifact_fields :
  output:Tool_output.artifact_ref ->
  stdout:Tool_output.artifact_ref ->
  stderr:Tool_output.artifact_ref ->
  (string * Yojson.Safe.t) list
(** The [output_artifact], [stdout_artifact] and [stderr_artifact] fields of
    an output too large to return inline. [output] is stdout followed by
    stderr, so when one stream is empty the other holds the same bytes as
    [output] and has its address. That stream's reference carries an empty
    preview: its reader has the same preview in [output_artifact], under the
    same [sha256]. An empty preview beside [bytes] above zero therefore means
    "the same as [output_artifact]", not "no output". *)

val capture_dirname : string
(** The directory {!capture_directory} names below [<base>/.masc]. *)
