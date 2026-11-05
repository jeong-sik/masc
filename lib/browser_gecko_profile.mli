(** The resource guards masc pins in a Firefox profile it starts over
    WebDriver BiDi. *)

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
