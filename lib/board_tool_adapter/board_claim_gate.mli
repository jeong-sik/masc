(** Evidence-backed write gate for board tool claims.

    This module is part of the board-tool adapter boundary: it knows both board
    persistence state and tool-call argument shapes, while the neutral tool
    substrate stays unaware of board semantics. *)

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

type prechecked_write

val source_snapshot_of_post : Masc_board_handlers.Board.post -> Yojson.Safe.t
(** [source_snapshot_of_post post] captures the post identity, update timestamp,
    body digest, and current excerpt for later stale-source validation. *)

val resolve_file_path : string -> artifact_resolution
(** [resolve_file_path ref_] resolves a board-local artifact reference and, for
    existing files, binds it to a content digest. *)

val check_post_create :
  tool_name:string ->
  author:string ->
  content:string ->
  args:Yojson.Safe.t ->
  (prechecked_write, string) result
(** [check_post_create] validates high-risk post-create claims before the post
    id exists. Call {!record_post_create} with the created post id to persist
    the prechecked decision. *)

val record_post_create :
  tool_name:string ->
  author:string ->
  target_post_id:string ->
  content:string ->
  prechecked_write ->
  (unit, string) result
(** Persist the prechecked post-create decision against [target_post_id]. *)

val check_comment :
  tool_name:string ->
  author:string ->
  post_id:string ->
  content:string ->
  args:Yojson.Safe.t ->
  (unit, string) result
(** Validate and record high-risk comment claims against an existing post. *)
