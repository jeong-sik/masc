(** Typed keeper path rejection contract and user-facing prefixes. *)

type keeper_path_rejection =
  | Path_required
  | Absolute_path_rejected of { raw : string }
  | Outside_project_root of { raw : string }
  | Allowed_paths_normalized_empty of { count : int }
  | Outside_sandbox of { raw : string }
  | Not_found_relative of { raw : string }
  | Ambiguous_relative_read_path of { raw : string; candidate_count : int }
  | Task_state_file_path_blocked of { raw : string }

(** LLM-facing opaque message derived from the rejection variant. *)
val rejection_to_user_message : keeper_path_rejection -> string

(** Stable lowercase prefix token for [rejection_to_user_message]. *)
val rejection_message_prefix : keeper_path_rejection -> string

(** Parse only the typed rejection tag from a user-facing rejection
    message. Payload fields are intentionally left empty / zero because
    the parser is for classification, not message reconstruction. *)
val parse_rejection_prefix : string -> keeper_path_rejection option
