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

type pull_request_locator =
  { owner : string
  ; repo : string
  ; number : int
  }

type pull_request_snapshot =
  { url : string
  ; state : string
  ; merged : bool
  ; draft : bool
  ; head_sha : string
  ; title : string
  ; diff : string
  ; diff_bytes : int
  ; diff_truncated : bool
  }
(** Facts this store fetched from the forge itself at the submit boundary —
    independently inspected evidence, not the producer's narrative. [diff] is
    bounded by the same cap as artifact content; [diff_bytes] reports the
    fetched size before capping. *)

type pull_request_fetch_failure =
  | Pull_request_inspector_uninstalled
  | Pull_request_transport of string
  | Pull_request_http_status of int
  | Pull_request_payload_invalid of string

type submitted_evidence_item =
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
  | Evidence_pull_request of
      { reference : string
      ; snapshot : pull_request_snapshot
      }
  | Evidence_pull_request_unreadable of
      { reference : string
      ; reason : pull_request_fetch_failure
      }

val install_pull_request_inspector :
  (pull_request_locator ->
   (pull_request_snapshot, pull_request_fetch_failure) result) ->
  unit
(** Install the forge reader once at process startup (the composition root
    owns the HTTP client; this store stays free of transport dependencies).
    Without an installed inspector a [pull-request:] reference snapshots as
    [Evidence_pull_request_unreadable] with
    [Pull_request_inspector_uninstalled] — typed absence, never a silent
    pass (masc#28989). *)

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

val submitted_evidence_item_of_yojson :
  Yojson.Safe.t -> (submitted_evidence_item, string) result
(** Decode one persisted snapshot item. This module writes the snapshot and
    owns the shape; exposed so tests and authority surfaces decode through
    the same reader instead of re-deriving the JSON fields. *)

val submitted_evidence_access_metadata_to_yojson :
  submitted_evidence_access -> Yojson.Safe.t

val evidence_read_failure_code : evidence_read_failure -> string
(** Stable bounded code for diagnostics and metadata. Error detail is carried
    only by the structured durable reason object. *)
val evidence_access_failure_to_string :
  request_id:string -> evidence_access_failure -> string
val evidence_read_failure_of_owned_read_failure :
  Fs_compat.owned_regular_file_read_failure -> evidence_read_failure

val project_root_of_base_path : string -> string
(** The project root a BasePath names, whether the caller passed the project
    root itself or its [.masc] directory. Exposed so a producer's ownership
    root is derived by this function everywhere rather than re-derived beside
    it. *)

val read_regular_file_prefix :
  ownership_root:string ->
  string ->
  (string * int * bool, evidence_read_failure) result
(** Read a bounded UTF-8 prefix of an owned regular file, returning
    [(content, file_size, truncated)]. This is the reader that materializes an
    [artifact:] evidence reference. {!Verification_authority_tools} reuses it so
    a live read and its snapshot cannot disagree about the same file: one byte
    cap, one policy for a multi-byte sequence cut by that cap, one failure
    vocabulary. *)
(** The reference shapes this store can read, decided without touching the
    filesystem. *)
type reference_form =
  | Artifact_reference of string
  | Note_reference of string
  | Pull_request_reference of pull_request_locator
  | Unresolvable_reference

val classify_evidence_reference : string -> reference_form
(** Shape of an evidence reference as {!snapshot_submitted_evidence_json} will
    read it. This module is the only producer of evidence snapshots, so the
    submit boundaries call this rather than restating the accepted prefixes:
    a reference cannot be admitted at submit and then be unreadable at review,
    and a new form added here reaches every caller. *)

val note_reference_form : string
(** The accepted form for narrative evidence, spelled from the prefix this
    module matches on, so an error message naming it cannot drift from the
    classifier. The artifact form has no such caller: a message that has to
    name both uses {!resolvable_reference_forms}. *)

val pull_request_reference_form : string
(** The accepted form for forge evidence:
    [pull-request:https://github.com/<owner>/<repo>/pull/<number>]. *)

val pull_request_locator_url : pull_request_locator -> string
(** The canonical web URL a locator names — the inverse of the reference
    parser, so the fetcher and the snapshot spell the same URL. *)

val verification_evidence_max_bytes : int
(** One byte cap for every materialized evidence payload — artifact content
    and pull-request diff alike — so no evidence form can smuggle a larger
    snapshot than another. *)

val resolvable_reference_forms : string list
(** The accepted forms, spelled for an error message that has to tell a caller
    what to write instead. *)

val snapshot_submitted_evidence_json :
  base_path:string ->
  worker:string ->
  string list ->
  Yojson.Safe.t
(** Materialize submitted evidence once at the producer's submit boundary.
    ["artifact:<relative-path>"] is rooted at the producer's declared sandbox;
    ["note:<text>"] preserves non-file evidence explicitly. [bytes] reports the
    source size, which exceeds the persisted [content] length when [truncated]
    is set by the projection cap. Bare and absolute references are persisted as
    a payload-free typed invalid-reference item. *)

val submitted_evidence_identity_lines :
  Yojson.Safe.t -> (string list, string) result
(** Project a persisted [submitted_evidence] snapshot into one identity line
    per item, for surfaces that name evidence without reading its payload —
    artifacts project to their reference, notes to their prefixed text, and
    unreadable items carry the typed reason code so an operator sees the
    failure rather than a silent gap. Payloads are served separately by the
    authority-scoped evidence route.

    This module writes the snapshot, so it owns the shape: a caller must not
    re-derive it. Returns [Error] on any item this module did not write and
    never partially projects a malformed array. *)

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