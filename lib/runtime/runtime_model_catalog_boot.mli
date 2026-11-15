(** Runtime_model_catalog_boot — the model catalog a process reads runtime.toml
    against, selected once before the read.

    The server and every standalone executable (probes, preflight, harnesses,
    [masc] subcommands) select the catalog here. An executable that reads
    runtime.toml through {!Runtime} directly judges it against the embedded
    catalog even when the operator named a replacement, while
    {!Runtime.exact_output_target_source} already answers from the
    replacement. *)

val replacement_catalog_path : ?env:(string -> string option) -> unit -> string option
(** The file [AGENT_CORE_MODEL_CATALOG] names as a full replacement, as
    {!Runtime.exact_output_target_source} answers it. A blank value names no
    file. *)

val configure_agent_core_model_catalog_env :
  ?env:(string -> string option) ->
  ?agent_core_catalog:(unit -> Llm_provider.Model_catalog.t option) ->
  ?load_catalog:(string -> (Llm_provider.Model_catalog.t, string) result) ->
  ?publish_catalog:(Llm_provider.Catalog_snapshot.t -> unit) ->
  unit ->
  string option
(** Admit and publish only an operator-supplied [AGENT_CORE_MODEL_CATALOG] as a
    complete replacement without a JSON provider overlay. Failed admission
    retains the previous publication. Without it, require the selected catalog.
    Config-root and executable-parent full catalogs are deliberately not
    discovered. Raises [Env_config_core.Config_error] when the named file does
    not load or is not admitted, and when no catalog is selected at all. *)

(** {1 Standalone executables}

    One call selects the catalog and then reads runtime.toml, so the read
    cannot happen against a catalog the operator did not choose. A named
    catalog that does not load is an [Error] carrying its path; the embedded
    catalog is not used in its place. *)

(** Which check the runtime table passes before it becomes the active one. *)
type standalone_gate =
  | Routing_only
      (** {!Runtime.init_default}: routing validation, no catalog-membership
          gate. *)
  | Catalog_required
      (** {!Runtime.init_default_strict}: a binding whose model the catalog
          does not carry, and which declares no capabilities, is refused. *)

val init_standalone :
  gate:standalone_gate -> config_path:string -> (unit, string) result
(** Select the catalog, then load [config_path] as the active runtime table. *)

val load_standalone_config_observation :
  runtime_config_path:string -> (Runtime.config_observation, string) result
(** Select the catalog, then read one immutable observation of
    [runtime_config_path] for {!Runtime.init_default_degraded_observation}
    and the sibling readers of the same bytes. *)

val load_standalone_list :
  config_path:string
  -> ( Runtime_instance.t list
       * Runtime_instance.t
       * (string * string) list
       * string list
       * Runtime_lane.t list
     , string )
     result
(** Select the catalog, then {!Runtime.load_list}. Activates nothing. The
    error is the diagnostic text of the load failure. *)
