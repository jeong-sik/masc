(** Keeper_identity — Trace ID generation, git identity, and keeper-name
    normalization for keeper operations. *)

val generate_trace_id : unit -> string
val keeper_git_author : keeper_name:string -> string
val keeper_git_email : keeper_name:string -> string
val git_env_for_keeper : keeper_name:string -> string array
val keeper_name_from_agent_name : string -> string option
val canonical_keeper_name_from_agent_name : string -> string option
val canonical_keeper_name : string -> string option

type parsed_identity =
  { keeper_name : string
  ; agent_name : string
  ; trace_id : string option
  }

val parse_json_identity : Yojson.Safe.t -> parsed_identity

(** {1 SSOT identity bundle (RFC P1)} *)

type name_bundle =
  { persona_name : string
  ; keeper_name : string
  ; agent_name : string
  ; credential_stem : string
  }

type validation_error =
  | Empty_input
  | Persona_not_found of
      { input : string
      ; resolved : string
      ; searched : string
      }
  | Credential_missing of
      { input : string
      ; resolved : string
      ; searched : string
      }
  | Name_ambiguous of
      { input : string
      ; candidates : string list
      }
  | Ephemeral_suffix_rejected of
      { input : string
      ; stripped : string
      }

(** [normalize_all_names ~input_agent_name ?base_path ?check_persona
    ?check_credential ()] resolves the four canonical name fields of a
    keeper from any of its accepted input shapes (bare name, [keeper-X-agent]
    wrapper, generated nickname like [executor-warm-raven], or wrapper +
    nickname combination).

    P1 default: [check_persona = false], [check_credential = false] —
    pure normalization without filesystem lookups. P3 preflight enables
    both.

    [base_path] defaults to the empty string, which makes
    [Common.masc_dir_from_base_path] resolve relative to the current
    working directory. Tests must always pass an explicit [~base_path]. *)
val normalize_all_names
  :  input_agent_name:string
  -> ?base_path:string
  -> ?check_persona:bool
  -> ?check_credential:bool
  -> unit
  -> (name_bundle, validation_error) result

val pp_validation_error : Format.formatter -> validation_error -> unit
val show_validation_error : validation_error -> string

(** Stable snake_case label for Prometheus metric outcome labels
    ([masc_coord_join_normalize_outcome_total] in RFC P3-a). The
    pattern match is exhaustive so a new [validation_error] variant
    forces an update here rather than silently aggregating to an
    "unknown" bucket. *)
val validation_error_outcome_label : validation_error -> string
