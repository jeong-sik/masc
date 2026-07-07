(** Evidence-backed board claim gate (#23486).

    Resolves the artifacts a board post claims about (exists / missing /
    unknown, with content digests), classifies the claim kinds, and decides
    whether a post/comment write may proceed. This interface exposes only the
    surface consumed by {!Board_tool_post} (write gating) and the coverage
    tests; the parsing/normalization helpers stay module-private.

    Made a public module (mli required) in the fix that let
    [test_tool_board_coverage] exercise [resolve_file_path] directly. *)

type claim_kind =
  | Artifact_exists
  | Artifact_missing
  | Artifact_created
  | Artifact_endorsed
  | Verification_endorsement
  | Task_completion
  | Pr_state
  | Retraction_ack
  | Opinion_or_routing

type source_post_snapshot =
  { post_id : string
  ; post_updated_at : float
  ; body_sha256 : string
  ; body_excerpt : string
  ; read_at : float
  ; read_tool_call_id : string option
  }

(** Resolution of one claimed artifact reference. [Exists] carries the content
    [digest] when the file is readable. *)
type artifact_resolution =
  | Exists of
      { ref_ : string
      ; kind : string
      ; checked_at : float
      ; digest : string option
      }
  | Missing of
      { ref_ : string
      ; checked_at : float
      ; reason : string
      }
  | Unknown of
      { ref_ : string
      ; checked_at : float
      ; reason : string
      }

type gate_decision =
  | Allow
  | Reject of string

(** Outcome of a pre-write check: either nothing to record, or a resolved claim
    bundle to persist alongside the write. *)
type prechecked_write =
  | No_record
  | Record of
      { claims : claim_kind list
      ; snapshot : source_post_snapshot option
      ; artifact_refs : string list
      ; resolutions : artifact_resolution list
      ; decision : gate_decision
      }

val claim_kind_to_string : claim_kind -> string

(** [resolve_file_path raw] resolves a claimed artifact reference to its
    existence/digest, rejecting parent-directory escapes. *)
val resolve_file_path : string -> artifact_resolution

(** Snapshot a source post's identity+body digest for claim provenance. *)
val source_snapshot_of_post : Masc_board_handlers.Board.post -> Yojson.Safe.t

(** Gate a comment write; [Error] rejects with a human-readable reason. *)
val check_comment :
  tool_name:string ->
  author:string ->
  post_id:string ->
  content:string ->
  args:Yojson.Safe.t ->
  (unit, string) result

(** Gate a post-create write, returning the resolved claim bundle to record. *)
val check_post_create :
  tool_name:string ->
  author:string ->
  content:string ->
  args:Yojson.Safe.t ->
  (prechecked_write, string) result

(** Persist a [prechecked_write] produced by {!check_post_create}. *)
val record_post_create :
  tool_name:string ->
  author:string ->
  target_post_id:string ->
  content:string ->
  prechecked_write ->
  (unit, string) result
