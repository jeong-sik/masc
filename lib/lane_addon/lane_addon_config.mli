(** Declarative installations from TOML. This module reads configuration only;
    it never starts workers, acquires observation sources or changes Keepers.
    Callers on a server fiber must offload these filesystem reads. *)
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
    but includes the resolved package, selected [tool_hooks] and [exact_outputs]
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

(** Validate edited source bytes using the same contract as [load_file].
    Relative paths resolve from the final declaration path; no declaration is
    written. Package manifest reads remain effects owned by the caller. *)
val load_source : source_path:string -> source_text:string -> (declaration, string) result

(** Read the immediate [.toml] children in deterministic filename order.
    Missing directories are an empty complete configuration. Read failures make
    [complete] false; callers must not infer deletions from that snapshot.
    Malformed files remain in [paths]. Duplicate declared IDs are all excluded
    from [declarations] and reported, without selecting an arbitrary winner. *)
val load : directory:string -> snapshot

val directory : config_root:string -> string
(** The Lane directory under a resolved config root: [<config_root>/lane-addons].
    The server, the declaration editor and [masc browser-lane-setup] all read
    declarations from here. *)
