(** The runtime capabilities of the plugins the operator installed in Muse.

    A Muse host loads the operator's installed plugins, and a plugin's hooks,
    reminders and MCP servers run in every session the host serves. In MASC's
    Keeper sessions on 2026-11-26/27 the hooks of one installed plugin ran
    8,013 times in a day and failed every time, because the command they call
    is not installed. [muse acp] 1.4.25 has no switch that leaves all plugins
    out; it turns one capability off for one process with
    [-c runtime_capabilities.<stable id>.enabled=false]. This module reads the
    stable ids the host would load, so the host can be started with each of
    them off.

    [muse plugins list --json] names the installed plugins in
    [plugins[].record.id]. [muse plugins inspect <id> --json] names one
    plugin's runtime capabilities in
    [runtime_capabilities[].candidate.stable_id]. The capabilities Muse
    bundles ([tbh-reminders]) are not installed plugins and are not listed. *)

type error =
  | Command_failed of
      { argv : string list
      ; detail : string
      }
      (** The command did not start, did not exit 0, or ran past its
          deadline. [detail] says which, with its stderr when it wrote any. *)
  | Unreadable_output of
      { argv : string list
      ; detail : string
      }
      (** The command exited 0 but its output was not the JSON shape above. *)

val error_to_string : error -> string

val plugin_ids_of_list : string -> (string list, string) result
(** The plugin ids in the output of [muse plugins list --json]. *)

val capability_ids_of_inspect : string -> (string list, string) result
(** The runtime capability stable ids in the output of
    [muse plugins inspect <id> --json]. *)

val installed_capability_ids
  :  proc_mgr:[> [> `Generic ] Eio.Process.mgr_ty ] Eio.Resource.t
  -> clock:[> float Eio.Time.clock_ty ] Eio.Resource.t
  -> ?cwd:Eio.Fs.dir_ty Eio.Path.t
  -> env:string array
  -> cli_path:string
  -> unit
  -> (string list, error) result
(** Every runtime capability stable id of every installed plugin, in the
    order the host lists them. [cli_path], [cwd] and [env] are the host's, so
    the commands read the plugin store the host will load. *)
