(** User-selected prerequisite actions. Catalog inspection never installs or
    starts anything; successful action execution still requires readiness checks. *)
type distribution = Debian | Ubuntu | Other
type dependency = Sandbox of Sandbox_readiness.backend | Codex_cli | Claude_cli | Antigravity_cli
  | Pdf_tools | Whisper_cli
type action_effect = Open_official_installer of { url : string; argv : string list }
  | Run_commands of string list list
  | Install_official_cli of Runtime_official_cli_install.client
type action = private { id : string; label : string; detail : string;
  source_url : string; requires_admin : bool; action_effect : action_effect }
type outcome = External_step_pending | Commands_completed_recheck_required
  | Failed of { step : int; reason : string }
val distribution_of_os_release : string -> distribution
(** [model_dir] is where a downloaded model should land. Absent, the actions
    that would need a path open the downloads page instead of offering a
    command that has nowhere to write. *)
val catalog :
  ?model_dir:string ->
  host:Sandbox_readiness.host -> distribution:distribution -> dependency -> action list
val to_json : action list -> Yojson.Safe.t
val execute : run:(string list -> (unit, string) result) -> action -> outcome
(** [run] belongs to the owner-authorized terminal/API edge. It receives argv,
    never a shell string, and must not silently acquire privilege. *)

val outcome_to_json : outcome -> Yojson.Safe.t
