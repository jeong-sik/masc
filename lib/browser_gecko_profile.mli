(** Gecko profiles that masc creates for its automation sessions.

    Each automation instance owns [<root>/<instance_id>/], and each session
    runs Firefox with [-profile] on a fresh [<instance_id>/<uuid>]. The root
    lives under the Lane Add-on store, not in the instance's temporary
    allocation, so a browser that relaunches itself after its instance ended
    is still found there. masc removes a profile only while it holds the
    profile's lock itself, so a browser that starts on it meanwhile finds it in
    use. *)

val lock_name : string
(** [.parentlock], the file Firefox write-locks while it runs a profile. *)

val root : lane_addon_root:string -> string
(** [<lane_addon_root>/gecko-profiles]. *)

val prepare_instance : root:string -> instance_id:string -> (string, string) result
(** Creates or checks [root] and [root]/[instance_id] as private directories
    with canonical paths, and returns the instance directory. [root] itself
    must not be a symbolic link. [instance_id] must be a canonical UUID. *)

val is_masc_name : string -> bool
(** Whether an instance or profile directory name is a canonical UUID, the only
    names masc gives them. *)

val existing_root : string -> (string option, string) result
(** The canonical [root], or [None] when it does not exist. A root that is a
    symbolic link or not a private directory is refused. *)

val check_instance : string -> (unit, string) result
(** Refuses a directory that is not a private directory with a canonical path. *)

val resource_guard_prefs : (string * Yojson.Safe.t) list
(** Production Firefox resource-management preferences that
    [RecommendedPreferences.sys.mjs] otherwise disables under WebDriver BiDi /
    Marionette unless a user value is already present:
    - [browser.tabs.unloadOnLowMemory = true]
    - [dom.ipc.processPriorityManager.enabled = true]
    - [dom.ipc.reportProcessHangs = true]
    - [dom.max_chrome_script_run_time = 20]
    - [dom.max_script_run_time = 20]
    - [threads.lower_mainthread_priority_in_background.enabled = true]
    - [widget.windows.window_occlusion_tracking.enabled = true] *)

val ensure_resource_guards : profile:string -> (unit, string) result
(** Ensures [<profile>/user.js] pins {!resource_guard_prefs} (preserving any
    other lines in [user.js]) and strips [remote.prefs.recommended.applied] and
    {!resource_guard_prefs} overrides from [<profile>/prefs.js] if present so
    profiles left dirty by an earlier [SIGTERM] or crash do not stay
    permanently unthrottled. [profile] must be a canonical private directory. *)

val create : instance:string -> (string, string) result
(** Creates a fresh private profile directory named by a new UUID, pre-seeded
    with {!ensure_resource_guards}. *)

type removal =
  | Removed
  | In_use  (** A process holds the profile's lock; the profile is kept. *)

val remove_locked : string -> (unit, string) result
(** Removes a profile whose lock this process holds through an open
    [Private_browser_profile.lock_file], keeping the lock file until last. *)

val remove_if_free : string -> (removal, string) result
(** Takes the profile's lock and removes the profile under it. A profile
    another process holds is kept and reported as [In_use]; this never signals
    that process. *)
