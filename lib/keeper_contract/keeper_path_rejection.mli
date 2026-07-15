(** Typed keeper path rejection contract and user-facing prefixes. *)

type keeper_path_rejection =
  | Path_required
  | Invalid_lexical_endpoint
  | Invalid_normalized_path_projection of { path : string }
  | Allowed_paths_normalized_empty of { count : int }
  | Outside_sandbox of { raw : string }

(** LLM-facing opaque message derived from the rejection variant. *)
val rejection_to_user_message : keeper_path_rejection -> string
