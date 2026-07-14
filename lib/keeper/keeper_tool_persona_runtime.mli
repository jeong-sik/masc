open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

val persona_summary_to_json : persona_summary -> Yojson.Safe.t
val read_jsonl_rows :
  string -> max_bytes:int -> max_lines:int -> Yojson.Safe.t list

val find_jsonl_row_by_action_id :
  Yojson.Safe.t list -> string -> Yojson.Safe.t option

val validate_resolved_keeper_create_json : Yojson.Safe.t -> string list

(** D-10a transition injection: set the legacy ["goal"] string to [goal_text]
    and, when [goal_id] is given, append it to ["active_goal_ids"] (dedup).
    Pure — the Goal_store mint stays at the handler boundary so dry_run can
    preview the injection effect-free. *)
val resolved_args_with_initial_goal :
  goal_text:string -> ?goal_id:string -> Yojson.Safe.t -> Yojson.Safe.t

val render_keeper_toml_from_resolved_args :
  Yojson.Safe.t -> (string, string) result

val persist_keeper_toml_from_resolved_args :
  Yojson.Safe.t -> (Yojson.Safe.t, string) result

(** Configured-only durable TOML write (create-without-boot):
    fresh-only (existing TOML is an explicit error), pins
    [autoboot_enabled = false] (an explicit [autoboot_enabled = true]
    input is a rejected conflict), resolves under [base_path]. Returns
    the written path. *)
val persist_new_keeper_toml_configured_only :
  base_path:string -> Yojson.Safe.t -> (string, string) result

(** Create-without-boot composition: fresh TOML write, then meta via the
    same parse + derivation as the boot path — no session, checkpoint,
    registry, or keepalive. Removes the freshly written TOML when a later
    step fails. Returns [{name; path; booted=false;
    autoboot_enabled=false}]. *)
val create_configured_only :
  _ Keeper_types_profile.context ->
  Yojson.Safe.t ->
  (Yojson.Safe.t, string) result

val resolved_keeper_args_from_persona :
  Yojson.Safe.t -> (persona_summary * Yojson.Safe.t, string) result
