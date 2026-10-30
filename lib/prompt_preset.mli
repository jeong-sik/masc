(** Prompt presets (#32777): a named snapshot of prompt overrides, keeper
    instructions, and runtime.toml routing (keeper assignments and the
    exact-output lanes), saved under [<base>/.masc/presets/<name>/] and
    restored from there.

    Prompt overrides are the surface a preset carries, not the managed
    prompt files: boot re-syncs those from the binary. *)

type 'a saved_setting =
  | Unrecorded
      (** The snapshot did not record this setting. Restore keeps the current
          declaration, including its absence, and does not invent a value. *)
  | Recorded of 'a option
      (** [Recorded None] explicitly removes the declaration; [Recorded (Some v)]
          restores [v]. Newly captured snapshots always record both settings. *)

type lane_owner =
  | Current_lane of Runtime_schema.exact_lane_owner
  | Unavailable_lane of string
      (** Preserved for inspection and re-saving, never written to runtime.toml. *)

val lane_key : lane_owner -> string

type lane =
  { owner : lane_owner
  ; enabled : bool
  ; slots : string list
  ; cli_slots : string list
  ; max_output_tokens : int saved_setting
  ; thinking : bool saved_setting
  }

type snapshot =
  { name : string
  ; description : string
  ; created_at : string
  ; prompt_overrides : Prompt_override_persistence.entry list
  ; instructions : (string * string) list  (** keeper TOML file name, instructions *)
  ; assignments : (string * string) list  (** keeper name, runtime id *)
  ; lanes : lane list
  ; default_revisions : (string * string) list option
      (** Default body SHA-256 by prompt key. [None] means no recorded baseline. *)
  }

type manifest =
  { preset_name : string
  ; preset_description : string
  ; preset_created_at : string
  ; override_count : int
  ; override_keys : string list  (** Which prompts the preset overrides. *)
  ; keepers : string list
  ; assignment_count : int
  ; lane_count : int
  }

type listing =
  { presets : manifest list
  ; unreadable : (string * string) list
        (** Directory name, and why {!load} could not read that preset. *)
  }

type part_result =
  { applied : string list
  ; skipped : (string * string) list  (** key, reason *)
  }

type runtime_result =
  | Runtime_unchanged  (** No accepted routing change; the file was not touched.
                          Exclusions may still make this a partial restore. *)
  | Runtime_committed of Runtime.config_commit_receipt
      (** The replacement is visible. Retains durability, lock warnings and
          exact-output registry application; it is not a request to retry. *)
  | Runtime_failed of string

type default_comparison =
  | Defaults_unknown
  | Defaults_match
  | Defaults_differ of (string * string option * string option) list
      (** Prompt key, saved revision, current revision; absent means no default body. *)

val compare_defaults : snapshot -> default_comparison
val default_comparison_to_json : default_comparison -> Yojson.Safe.t

type restore_report =
  { restored : string
  ; autosave : string  (** the preset holding the state from before the restore *)
  ; prompt_overrides_result : part_result  (** takes effect at once *)
  ; instructions_result : part_result  (** takes effect at each keeper's next up *)
  ; runtime_result : runtime_result
  ; default_comparison : default_comparison
  ; preserved_lane_settings : (string * string) list
      (** Lane id and setting not recorded in the target, kept as currently declared. *)
  ; skipped_lanes : (string * string) list
      (** Lanes unavailable or refused by the runtime writer. Their current
          declarations and saved contents remain intact. *)
  ; skipped_assignments : (string * string) list
      (** Keeper assignments unavailable under the current capability catalog
          or refused by the runtime writer. The current
          assignment, including its absence, is preserved. *)
  }

val autosave_name : string
(** The one preset a restore writes the live state into before applying.
    Each restore replaces it, so it holds the state from before the latest
    restore and nothing older. *)

val is_valid_name : string -> bool
(** [[A-Za-z0-9._-]+], and neither "." nor "..". *)

val capture :
  base_path:string -> name:string -> description:string -> (snapshot, string) result
(** The live state as a snapshot. Fails when the name is invalid or the
    runtime.toml under [base_path] does not parse. A keeper TOML that does not
    load, or declares no instructions, contributes no entry. *)

val save : base_path:string -> snapshot -> (unit, string) result
(** Writes the preset directory, replacing a preset of the same name. *)

type create_error =
  | Invalid_name of string
  | Already_exists of string
  | Failed of { name : string; reason : string }

val create : base_path:string -> snapshot -> (unit, create_error) result
(** Publishes a new complete preset atomically only when its name is absent.
    An existing path, including an empty directory or dangling symlink, is
    preserved and reported as [Already_exists]. Does not replace a preset
    that appeared after a caller listed names or captured its snapshot. *)

val create_error_to_string : create_error -> string

val load : base_path:string -> string -> (snapshot, string) result
val list : base_path:string -> listing

val restore : base_path:string -> string -> (restore_report, string) result
(** Loads the named preset, saves the current state as {!autosave_name}
    over the previous one, then applies the loaded preset surface by surface.
    Restoring {!autosave_name} undoes the latest restore for the prompt
    overrides and the runtime assignments, which a restore sets exactly.
    Keeper instructions and exact-output lanes are written only for the
    keepers and lanes a preset holds, so a keeper that had no instructions
    keeps what the latest restore gave it, and a lane that restore added
    stays. The autosave then holds the state the undo replaced.
    Only the load and the autosave can fail the whole call; each surface
    reports what it applied and what it skipped. An override that no
    longer renders under the prompt's current contract is skipped with that
    reason, as the boot-time restore would refuse it. One written against an
    older default body is applied. Runtime assignments and lane declarations
    that the current runtime writer refuses, and assignments unavailable under
    the current capability catalog, are reported separately and keep
    their current values. Accepted declarations still restore; no replacement
    runtime is inferred. *)

module For_testing : sig
  val restore_with_config_commit :
    commit:(runtime_config_path:string -> string ->
      (Runtime.config_commit_receipt, string) result) ->
    base_path:string -> string -> (restore_report, string) result
  (** The production restore path with an injected runtime writer. Tests use
      the real writer with an injected parent-directory sync failure. *)
end

type delete_error =
  | Delete_invalid_name of string
  | Delete_not_found of string  (** no preset directory by that name *)
  | Delete_failed of { name : string; reason : string }
      (** the directory is there and removing it failed *)

val delete : base_path:string -> string -> (unit, delete_error) result
(** Removes the named preset directory without loading it first, so a preset
    listed as unreadable is removed the same way as one that loads.
    {!autosave_name} is a preset like any other here. *)

val delete_error_to_string : delete_error -> string

val runtime_text_with :
  current_assignments:(string * string) list ->
  current_lanes:lane list ->
  assignments:(string * string) list ->
  lanes:lane list ->
  string ->
  string
(** The runtime.toml text with [\[runtime.assignments\]] set to
    [assignments] (rows for keepers in [current_assignments] but not in
    [assignments] are removed) and the [enabled] / [slots] / [cli_slots] /
    [max_output_tokens] / [thinking] of every lane whose values differ from
    [current_lanes] rewritten. A request setting the preset declares none of is
    removed from the lane table; an [Unrecorded] setting is kept unchanged.
    Unavailable lanes are skipped. A setting that already holds is not rewritten. Every other line is
    kept, including comment lines inside the arrays of lanes left alone.
    Exposed for tests. *)

val runtime_of_text : string -> ((string * string) list * lane list, string) result
(** [\[runtime.assignments\]] and the exact-output lanes of a runtime.toml
    text, or the parse errors joined. Exposed for tests. *)

val manifest_of_snapshot : snapshot -> manifest
val manifest_to_json : manifest -> Yojson.Safe.t

val snapshot_to_json : snapshot -> Yojson.Safe.t
(** Everything a preset would change, named rather than counted.

    A manifest says "one override, ten keepers". That is not enough to decide
    whether to apply it: which override, and which ten. Restoring is the only
    way to find out, and restoring is the thing being decided. *)
val report_to_json : restore_report -> Yojson.Safe.t

val same_settings : snapshot -> snapshot -> bool
(** [same_settings saved current] compares the saved restore intent on the left
    with the current captured declarations on the right. An [Unrecorded]
    setting in [saved] accepts the current declaration; all other settings,
    including the complete set of currently supported lanes, must match.
    Unavailable lanes are excluded from comparison and reported as skipped.
    This is directional when
    the saved snapshot contains unrecorded settings. Snapshot metadata is ignored. *)
val source_directory : base_path:string -> snapshot -> string
val matches_saved_settings : base_path:string -> snapshot -> (bool, string) result
(** Compare fresh durable override, Keeper TOML and runtime files. An unreadable
    input makes the comparison unavailable. Does not change the live registry. *)
