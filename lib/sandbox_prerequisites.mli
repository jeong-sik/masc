(** User-selected prerequisite actions. Catalog inspection never installs or
    starts anything; successful action execution still requires readiness checks. *)
type distribution = Debian | Ubuntu | Other
type searxng_container =
  | Searxng_absent  (** No such container. *)
  | Searxng_stopped
      (** [created] or [exited]: [docker start] runs it. *)
  | Searxng_running
  | Searxng_paused
      (** [docker start] is refused for a paused container; [docker unpause]
          is the step, and no action here takes it. *)
  | Searxng_restarting
      (** Docker reports it running while it restarts, so [docker start] does
          nothing. Its logs say why it keeps stopping. *)
  | Searxng_unusable of string
      (** [removing], [dead], or a status word this code does not know; the
          word is Docker's own. No action starts it. *)
(** What Docker reports for the container [searxng_container_name]
    ([{{.State.Status}}]), as far as an action can tell. *)
type dependency = Sandbox of Sandbox_readiness.backend | Codex_cli | Claude_cli | Antigravity_cli
  | Muse_cli | Pdf_tools | Presentation_tools of {base_path:string} | Whisper_cli
  | Geckodriver | Firefox | Ego_browser
  (** The programs the browser lanes start: [\[browser.automation\]] names
      geckodriver by absolute path and starts it with the server;
      [\[browser.live.bidi\]] names Firefox; [\[browser.live.ego\]] names
      ego lite's [ego-browser]. None is installed with MASC, and no action here
      edits runtime.toml. *)
  | Searxng of { config_dir : string }
  (** A SearXNG instance in a Docker container, the one search provider that
      needs no key. [config_dir] is the directory mounted as the container's
      [/etc/searxng]; its [settings.yml] is written when absent. *)
type action_effect = Open_official_installer of { url : string; argv : string list }
  | Run_commands of string list list
  | Install_official_cli of Runtime_official_cli_install.client
  | Build_without_rosetta of { user_config : string }
      (** Set [build] rosetta = false in Apple Container's user configuration,
          then restart its service so the next image build reads it. *)
  | Run_searxng of { config_dir : string }
      (** No container exists: write [config_dir]/settings.yml unless it
          exists (a generated secret key, JSON output on, no limiter), then
          pull the pinned image and run it. *)
  | Start_existing_searxng
      (** A stopped container exists: [docker start] and nothing else, because
          the container keeps the publish address, mount and image it was
          created with. No other container state has an effect, so none can be
          written here. *)
type apple_builder =
  | Builder_unchecked
  | Needs_missing_rosetta of { user_config : string option }
  | Needs_default_kernel
      (** The service answered and the builder starts, but no default kernel is
          configured, so the first image build dies; installing the recommended
          kernel is the one action offered. *)
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
val searxng_container_name : string
val searxng_image : string
(** The image reference the run action pulls: a dated tag and the digest it
    resolved to when it was measured, so a re-pointed tag is not followed. *)

val searxng_settings : secret_key:string -> string
(** The text of the settings file for [secret_key]. Exposed so a test reads
    what the container will read. *)

val catalog :
  ?model_dir:string ->
  ?apple_builder:apple_builder ->
  ?searxng_container:searxng_container ->
  host:Sandbox_readiness.host -> distribution:distribution -> dependency -> action list
(** [apple_builder] defaults to [Builder_unchecked]. When it is
    [Needs_missing_rosetta], Apple Container offers the two ways past it --
    build without Rosetta, or install it -- instead of its installers. When it
    is [Needs_default_kernel], it offers installing the recommended kernel.
    [searxng_container] defaults to [Searxng_absent] and only [Searxng] reads
    it: an absent container is created and a stopped one is started. Running,
    paused, restarting and unusable ones have no action: the first has nothing
    left to do, and for the others the reason is in the readiness the caller
    reports. *)
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
