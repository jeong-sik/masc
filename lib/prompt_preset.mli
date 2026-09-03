(** Prompt presets (#32777): a named snapshot of prompt overrides, keeper
    instructions, and runtime.toml routing (keeper assignments and the
    exact-output lanes), saved under [<base>/.masc/presets/<name>/] and
    restored from there.

    Prompt overrides are the surface a preset carries, not the managed
    prompt files: boot re-syncs those from the binary. *)

type lane =
  { id : string
  ; slots : string list
  ; cli_slots : string list
  }

type snapshot =
  { name : string
  ; description : string
  ; created_at : string
  ; prompt_overrides : Prompt_override_persistence.entry list
  ; instructions : (string * string) list  (** keeper TOML file name, instructions *)
  ; assignments : (string * string) list  (** keeper name, runtime id *)
  ; lanes : lane list
  }

type manifest =
  { preset_name : string
  ; preset_description : string
  ; preset_created_at : string
  ; override_count : int
  ; keepers : string list
  ; assignment_count : int
  ; lane_count : int
  }

type listing =
  { presets : manifest list
  ; unreadable : (string * string) list  (** directory name, why its manifest did not read *)
  }

type part_result =
  { applied : string list
  ; skipped : (string * string) list  (** key, reason *)
  }

type runtime_result =
  | Runtime_unchanged  (** the parsed routing already matched; the file was not touched *)
  | Runtime_committed  (** runtime.toml committed through [Runtime.save_config_text] *)
  | Runtime_failed of string

type restore_report =
  { restored : string
  ; autosave : string  (** the preset holding the state from before the restore *)
  ; prompt_overrides_result : part_result  (** takes effect at once *)
  ; instructions_result : part_result  (** takes effect at each keeper's next up *)
  ; runtime_result : runtime_result
  }

val autosave_prefix : string

val is_valid_name : string -> bool
(** [[A-Za-z0-9._-]+], and neither "." nor "..". *)

val presets_dir : base_path:string -> string

val capture :
  base_path:string -> name:string -> description:string -> (snapshot, string) result
(** The live state as a snapshot. Fails when the name is invalid or the
    runtime.toml under [base_path] does not parse. A keeper TOML that does not
    load, or declares no instructions, contributes no entry. *)

val save : base_path:string -> snapshot -> (unit, string) result
(** Writes the preset directory, replacing a preset of the same name. *)

val load : base_path:string -> string -> (snapshot, string) result
val list : base_path:string -> listing

val restore : base_path:string -> string -> (restore_report, string) result
(** Saves the current state as [_autosave-<stamp>] (a free name is picked
    if the stamp is taken), then applies the named preset surface by surface.
    Only the load and the autosave can fail the whole call; each surface
    reports what it applied and what it skipped. An override whose saved
    contract revision no longer matches the prompt's current body is skipped
    with that reason, as the boot-time restore would refuse it. *)

val runtime_text_with :
  current_assignments:(string * string) list ->
  assignments:(string * string) list ->
  lanes:lane list ->
  string ->
  string
(** The runtime.toml text with [\[runtime.assignments\]] set to
    [assignments] (rows for keepers in [current_assignments] but not in
    [assignments] are removed) and each lane's [slots] / [cli_slots]
    rewritten. Every other line is kept. Exposed for tests. *)

val runtime_of_text : string -> ((string * string) list * lane list, string) result
(** [\[runtime.assignments\]] and the exact-output lanes of a runtime.toml
    text, or the parse errors joined. Exposed for tests. *)

val manifest_of_snapshot : snapshot -> manifest
val manifest_to_json : manifest -> Yojson.Safe.t
val report_to_json : restore_report -> Yojson.Safe.t
