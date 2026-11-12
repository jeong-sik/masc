(** Declarative installations from TOML. This module reads configuration only;
    it never starts workers, acquires observation sources or changes Keepers.
    Callers on a server fiber must offload these filesystem reads. *)
type exact_in_flight = private int
(** How many exact requests of one installation the host may run at once. It
    is at least 1 by construction. *)

val exact_in_flight : int -> exact_in_flight option
(** [None] for a count below 1. *)

val one_exact_at_a_time : exact_in_flight
(** The host waits for each exact request before it starts the next. *)

type declaration = {
  id : string;
  enabled : bool;
  run_id : string;
  manifest_path : string;
  package : Lane_addon_types.package;
  binding : Yojson.Safe.t;
  revision : string;
  source_revision : string;
  (** SHA-256 of the exact declaration bytes, including enabled and comments.
      Matches the declaration editor's source_revision; never a worker key. *)
  source_path : string;
  max_exact_in_flight : exact_in_flight;
  (** RFC host-cycle-runs-exact-requests-side-by-side 3.2.
      {!one_exact_at_a_time} when the declaration has no such key. It is not a
      worker input, so it is outside [revision]. *)
}

type issue = { source_path : string; id : string option; message : string }

type snapshot = {
  declarations : declaration list;
  issues : issue list;
  paths : string list;
  complete : bool;
}

(** Resolve relative manifest and snapshot-file paths from the declaration's
    directory. The semantic revision excludes comments and the source filename,
    and UI-only [package.ui_category], but includes every other resolved package
    field, selected [tool_hooks] and [exact_outputs]
    overrides and ordered binding values. Omitted hooks use the package default;
    [] disables both optional tool-contract hooks. Omitted [exact_outputs] keeps
    every package-declared output; [] disables model-generation outputs for this
    installation. An explicit list selects only unique declared names, in the
    package's canonical order, without supplying schemas or provider settings.
    [declaration.package.exact_outputs] is the effective selection. These two
    choices are independent. [enabled] is
    desired worker activity, separate from this payload revision. During the
    accepting deployment stage an absent key retains the current enabled behavior. *)
val load_file : path:string -> (declaration, string) result

(** Who wrote the source bytes [load_source] reads. *)
type manifest_scope =
  | Operator_declared
  (** Operator configuration, or a declaration file already on disk:
      [manifest_path] is read where it points. [load] and [load_file] read
      this way. *)
  | Within_workspace of string
  (** A save from a Keeper or an unauthenticated caller: the resolved
      [manifest_path] has to stay inside this workspace
      ([Lane_addon_manifest.resolve_in_workspace]) before it is opened. *)

(** Validate edited source bytes using the same contract as [load_file].
    Relative paths resolve from the final declaration path; no declaration is
    written. Package manifest reads remain effects owned by the caller. *)
val load_source :
  manifest_scope:manifest_scope -> source_path:string -> source_text:string ->
  (declaration, string) result

(** Read the immediate [.toml] children in deterministic filename order.
    Missing directories are an empty complete configuration. Read failures make
    [complete] false; callers must not infer deletions from that snapshot.
    Malformed files remain in [paths]. Duplicate declared IDs are all excluded
    from [declarations] and reported, without selecting an arbitrary winner. *)
val load : directory:string -> snapshot

val browser_source : declaration -> Browser_lane.Backend.t option
(** The browser source [declaration]'s worker serves, [None] for an MCP tool
    package. *)

val directory : config_root:string -> string
(** The Lane directory under a resolved config root: [<config_root>/lane-addons].
    The server, the declaration editor and [masc browser-lane-setup] all read
    declarations from here. *)
