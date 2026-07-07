(** Board_claim_gate — claim/evidence gate for board writes (#23486).

    Board posts and comments that carry claims (artifact existence, task
    completion, PR state, …) are checked against the referenced artifacts and
    a source-post snapshot before the write is accepted; accepted or rejected,
    the decision is appended to the claim-evidence sidecar.

    This interface exposes the surface consumed by [Board_tool_post] and
    [test_tool_board_coverage] (#23525); parsing and sidecar internals stay
    private. *)

open Masc_board_handlers

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

type artifact_resolution =
  | Exists of { ref_ : string; kind : string; checked_at : float; digest : string option }
  | Missing of { ref_ : string; checked_at : float; reason : string }
  | Unknown of { ref_ : string; checked_at : float; reason : string }

type gate_decision =
  | Allow
  | Reject of string

type prechecked_write =
  | No_record
  | Record of
      { claims : claim_kind list
      ; snapshot : source_post_snapshot option
      ; artifact_refs : string list
      ; resolutions : artifact_resolution list
      ; decision : gate_decision
      }

val source_snapshot_of_post : Board.post -> Yojson.Safe.t
(** Render the snapshot fields a subsequent claim-carrying write must echo
    back as its [source_post_snapshot] argument. *)

val resolve_file_path : string -> artifact_resolution
(** Resolve an artifact ref against the board base path. Rejects empty refs
    and parent-path segments as [Unknown]. *)

val check_comment
  :  tool_name:string
  -> author:string
  -> post_id:string
  -> content:string
  -> args:Yojson.Safe.t
  -> (unit, string) result
(** Gate a comment write on [post_id]. Claim-free writes pass without a
    sidecar record; claim-carrying writes are resolved, recorded, and rejected
    with a reason on gate failure. *)

val check_post_create
  :  tool_name:string
  -> author:string
  -> content:string
  -> args:Yojson.Safe.t
  -> (prechecked_write, string) result
(** Pre-check a post-create write. The returned [prechecked_write] must be
    passed to {!record_post_create} once the post id is known; a rejected
    precheck is recorded immediately and surfaces as [Error]. *)

val record_post_create
  :  tool_name:string
  -> author:string
  -> target_post_id:string
  -> content:string
  -> prechecked_write
  -> (unit, string) result
(** Append the precheck outcome for the created post to the claim-evidence
    sidecar. [Error] on gate rejection or sidecar write failure. *)
