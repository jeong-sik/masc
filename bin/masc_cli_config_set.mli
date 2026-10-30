(** [masc config set KEY=VALUE ...]: write keys of runtime.toml.

    A key is a dotted key the settings registry names, such as
    [autonomous.enabled]. The writer is {!Runtime_setting_set}; this module
    reads the arguments, seeds a workspace that has no runtime.toml yet and
    reports. *)

val run : base_path:string -> assignments:string list -> int
(** Writes every assignment in one commit, or none. The file is the one the
    server reads for [base_path], [MASC_CONFIG_DIR] included. A workspace with
    no runtime.toml is seeded the way server start seeds it, so a script can set
    a key before the first start; a workspace that has one is left as it is.
    The result is the process exit code: [0] when the file holds the requested
    values, [1] when nothing was written and the reason is on stderr. *)
