(** [masc browser-lane-setup]: connect this workspace's browser lane to an
    ego lite task space.

    Without a mode it writes nothing and says which task space runtime.toml
    names. [--mode ego] writes the [\[browser.live.ego\]] table, so the
    browser Add-on serves an ego lite task space
    ({!Masc.Browser_lane_ego_setup}). Besides asking [ego-browser] for its
    versions and for ego lite's list of task spaces, it starts no browser.

    [--mode addon] writes, for each browser source the workspace runs, the
    package this masc carries to [.masc/packages/browser-<source>] and
    declares it when the workspace has no declaration of that source
    ({!Masc.Browser_addon_setup}). A source runs when runtime.toml has its
    table or this run writes it. A declaration's [enabled] switches its source
    on or off. Every other mode does the same after its tables, and a source
    whose table the mode writes is declared only once that table is written.
    There a refusal of that step, including a runtime.toml that does not
    parse, is reported and the mode's own steps go on; only [--mode addon]
    fails on it. [--no-addon] skips the step for the other modes and
    contradicts [--mode addon].

    An option that the chosen modes do not use is refused, not ignored. *)

type mode = Addon | Ego

val all_modes : mode list

(** The value [--mode] takes. *)
val mode_name : mode -> string

val run
  :  base_path:string
  -> runtime_config_path:string
  -> server_port:(int, string) result
  -> agent:string
  -> agent_named:bool
  -> modes:mode list
  -> no_addon:bool
  -> ego_command:string option
  -> ego_space:string option
  -> int
(** The process exit code: [0] when it printed the state or finished the
    install, [1] when it refused and said why on stderr, and [3] when
    [--mode addon] found no config root in the workspace yet, so nothing was
    written: the first server start writes one. *)
