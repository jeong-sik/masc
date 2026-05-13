(** Policy-derived keeper tool guidance.

    Prompts must not advertise tools outside the active keeper
    policy. The model already receives the real schema set from OAS;
    this module renders short human-readable hints by filtering
    curated affordances through that same allowed-name set. *)

type hint =
  { name : string
  ; call : string
  ; description : string
  }

(** Build a hashtable lookup of allowed tool names. Used internally
    by [allowed_hints] but exposed for callers that want to reuse the
    same allowed set. *)
val allowed_lookup : string list -> (string, unit) Hashtbl.t

(** Filter [hints] down to those whose [name] is in
    [allowed_tool_names]. *)
val allowed_hints : allowed_tool_names:string list -> hint list

(** Render a single [hint] as a bullet line for prompt embedding. *)
val line_of_hint : hint -> string

(** Render a "Preferred keeper tools" prompt section, falling back to
    a runtime-only schema notice when no hints match. *)
val render_preferred_tools :
  allowed_tool_names:string list -> string

(** Membership test on the allowed-tool-names list. *)
val has : string list -> string -> bool

(** Render an optional GitHub/code workflow guidance paragraph,
    chosen by which keeper tools are present in the allowlist. *)
val render_gh_workflow :
  allowed_tool_names:string list -> string option

(** Render the unknown-tool guard paragraph (always-on, no policy
    dependency). Reminds the model not to call masc_*/lifecycle tools
    that aren't in its runtime schema. *)
val render_unknown_tool_guard : unit -> string
