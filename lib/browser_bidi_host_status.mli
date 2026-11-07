(** Who starts the live Firefox of a workspace: the [\[browser.live.bidi\]]
    table of [runtime.toml] beside the Lane Add-on declarations. [masc
    doctor] and [masc browser-lane-setup] answer from this one observation. *)

(** The live Firefox configuration. This is configuration, not an Addon
    readiness observation. *)
type keeper =
  | Addon_managed of
      { port : int
      ; profile : string
      }
      (** [runtime.toml] has [\[browser.live.bidi\]] and an enabled
          declaration runs the [browser-firefox] source: the Browser Addon
          owns its Firefox and BiDi connection. Existing Firefox processes
          are not adopted or restarted. *)
  | Addon_off
      (** [runtime.toml] has [\[browser.live.bidi\]], but no enabled
          declaration runs the [browser-firefox] source: the Browser Addon
          does not start that Firefox. *)
  | Not_configured  (** No [\[browser.live.bidi\]]. *)
  | Not_known
      (** No configuration was given to read it from, or the declarations
          could not all be read. *)

(** [configuration]: [None] when none was loaded or read. [firefox]: whether
    an enabled declaration runs the [browser-firefox] source, [None] when the
    declarations could not all be read. It is asked only when
    [configuration] has [\[browser.live.bidi\]]. *)
val keeper :
  configuration:Browser_configuration.t option -> firefox:(unit -> bool option) -> keeper

(** [configuration] is the one this process loaded, or the workspace's
    [runtime.toml] read for it. When it has [\[browser.live.bidi\]], the
    workspace's Lane Add-on declarations are read from disk to say whether
    [browser-firefox] runs. *)
val observe : base_path:string -> configuration:Browser_configuration.t option -> keeper

(** One operator paragraph: who starts the live Firefox, and for
    {!Addon_managed} where its readiness is observed. *)
val message : keeper -> string
