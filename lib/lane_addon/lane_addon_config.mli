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

(** RFC server-carries-its-exact-worker-packages 3.2: the key that chose the
    package. [manifest_path] in {!declaration} is where either one resolved. *)
type package_source =
  | Carried of Lane_addon_carried.id
      (** [package = "<name>"]: the folder of the package this server carries. *)
  | Manifest_path  (** [manifest_path]: a package the operator placed. *)

type declaration = {
  id : string;
  enabled : bool;
  run_id : string;
  package_source : package_source;
  manifest_path : string;
  package : Lane_addon_types.package;
  binding : Yojson.Safe.t;
  revision : string;
  source_revision : string;
  (** SHA-256 of the exact declaration bytes, including enabled and comments.
      Matches the declaration editor's source_revision; never a worker key. *)
  source_path : string;
  max_exact_in_flight : exact_in_flight;
  (** {!one_exact_at_a_time} when the declaration has no such key. It is not a
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
    accepting deployment stage an absent key retains the current enabled behavior.

    A declaration names its package with exactly one of [package] or
    [manifest_path]. [package = "<name>"] names a package this server carries
    ({!Lane_addon_carried}); it resolves to [<packages>/<name>-<revision>]
    only when that folder holds exactly the carried files, and the declaration
    is refused otherwise. [packages] is [Config_dir_resolver.packages_dir] for
    the server's base path. *)
val load_file : packages:string -> path:string -> (declaration, string) result

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
  packages:string -> manifest_scope:manifest_scope -> source_path:string -> source_text:string ->
  (declaration, string) result

(** Read the immediate [.toml] children in deterministic filename order.
    Missing directories are an empty complete configuration. Read failures make
    [complete] false; callers must not infer deletions from that snapshot.
    Malformed files remain in [paths]. Duplicate declared IDs are all excluded
    from [declarations] and reported, without selecting an arbitrary winner. *)
val load : packages:string -> directory:string -> snapshot

val declared_carried : directory:string -> Lane_addon_carried.id list * issue list
(** The carried packages the declarations in [directory] name with [package],
    in {!Lane_addon_carried.all} order. Each declaration's package choice is
    read by the same rule as {!load}, without resolving it, so a package
    whose folder is not installed is named too. The issues are the
    declarations whose choice cannot be read, or [directory] when it cannot
    be listed. A missing [directory] names nothing. *)

val browser_source : declaration -> Browser_lane.Backend.t option
(** The browser source [declaration]'s worker serves, [None] for an MCP tool
    package. *)

val directory : config_root:string -> string
(** The Lane directory under a resolved config root: [<config_root>/lane-addons].
    The server, the declaration editor and [masc browser-lane-setup] all read
    declarations from here. *)
