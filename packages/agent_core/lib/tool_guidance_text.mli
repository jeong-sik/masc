(** Model-facing text for the tool loop, installed by the host.

    agent_core is config-free by layering: it cannot read
    [config/prompts/agent_core.md] itself. The host (MASC prompt init)
    renders the managed templates and installs the text here once at
    startup; {!current} returns the last installed value.

    The defaults are the last-resort copy of the same sentences so that
    agent_core's own tests and standalone consumers behave identically
    without any host wiring. *)

type t =
  { unknown_tool_not_found : requested:string -> string
    (** ["Tool not found: <requested>"] when other tools are registered. *)
  ; unknown_tool_not_found_no_tools : requested:string -> string
    (** Same miss with an empty registry. *)
  ; unknown_tool_closest_registered : name:string -> string
  ; unknown_tool_extra_characters : prefix:string -> string
    (** The requested name carries a trailing payload after a registered
        prefix; [prefix] is quoted by the implementation. *)
  ; unknown_tool_not_bare_with_closest : name:string -> string
  ; unknown_tool_not_bare : string
  ; handoff_description : name:string -> description:string -> string
  ; handoff_prompt_param_description : string
  ; agent_tool_prompt_param_description : string
  }

(** The last-resort copy of the same sentences, byte-identical to what the
    host's managed templates render. *)
val defaults : t

(** Install the host-rendered text. Called once from the host's prompt init;
    a later call replaces the earlier value. *)
val configure : t -> unit

(** The currently installed text, [defaults] until the host configures. *)
val current : unit -> t
