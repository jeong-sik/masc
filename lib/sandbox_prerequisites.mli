(** User-selected prerequisite actions. Catalog inspection never installs or
    starts anything; successful action execution still requires readiness checks. *)
type distribution = Debian | Ubuntu | Other
type dependency = Sandbox of Sandbox_readiness.backend | Codex_cli | Claude_cli | Antigravity_cli
  | Pdf_tools | Presentation_tools of {base_path:string} | Whisper_cli
type action_effect = Open_official_installer of { url : string; argv : string list }
  | Run_commands of string list list
  | Install_official_cli of Runtime_official_cli_install.client
  | Build_without_rosetta of { user_config : string }
      (** Set [build] rosetta = false in Apple Container's user configuration,
          then restart its service so the next image build reads it. *)
type apple_builder =
  | Builder_unchecked
  | Needs_missing_rosetta of { user_config : string option }
(** What setup found about Apple Container's image builder.
    [Needs_missing_rosetta]: the service answered, the builder uses Rosetta,
    and Rosetta is not installed. [user_config] is the file Apple Container
    reads a user's settings from; without one, only installing Rosetta is
    offered. *)
type action = private { id : string; label : string; detail : string;
  source_url : string; requires_admin : bool; action_effect : action_effect;
  writes : string option
  (** The file this action leaves behind once it completes, where one does --
      for a download, the final path rather than any temporary one it fetches
      to. Published as [writes] ([null] when there is none) so a reader that
      needs the path does not recover it from argv. *) }
type outcome = External_step_pending | Commands_completed_recheck_required
  | Failed of { step : int; reason : string }
val distribution_of_os_release : string -> distribution
(** [model_dir] is where a downloaded model should land. Absent, the actions
    that would need a path open the downloads page instead of offering a
    command that has nowhere to write. *)
val catalog :
  ?model_dir:string ->
  ?apple_builder:apple_builder ->
  host:Sandbox_readiness.host -> distribution:distribution -> dependency -> action list
(** [apple_builder] defaults to [Builder_unchecked]. When it is
    [Needs_missing_rosetta], Apple Container offers the two ways past it --
    build without Rosetta, or install it -- instead of its installers. *)
val to_json : action list -> Yojson.Safe.t
type run_failure =
  | Program_not_found  (** argv's program is not on PATH; nothing ran *)
  | Could_not_start  (** the program exists and could not be started *)
  | Did_not_finish  (** it ran and did not succeed; its output was on the terminal *)
(** Why a step did not complete. Carries no text: a receipt's reason is built
    from this and from argv the catalog wrote, so a child's diagnostics have
    no path into it. *)

val execute : run:(string list -> (unit, run_failure) result) -> action -> outcome
(** [run] belongs to the owner-authorized terminal/API edge. It receives argv,
    never a shell string, and must not silently acquire privilege. *)

val outcome_to_json : outcome -> Yojson.Safe.t
