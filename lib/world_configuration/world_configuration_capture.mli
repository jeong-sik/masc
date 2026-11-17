(** Read authored configuration documents for the serving workspace.

    The Runtime configuration lock excludes cooperating Runtime and Keeper
    declaration writers. Inside that scope the prompt mutation lock excludes
    this process's override writers. Raw bytes are copied under those scopes;
    hashing and strict document validation happen after they are released.

    This is a document export, not activation or a complete dependency/asset
    package. It does not serialize manual filesystem editors or another
    process's prompt writes. No runtime metadata, login or credential store is
    copied. The caller must not describe it as a full BasePath backup. *)

type error =
  | Invalid_base_path of Config_dir_resolver.canonical_base_path_error
  | Config_root_unavailable of string
  | Read_failed of { path : string; detail : string }
  | Configuration_lock_failed of string
  | Invalid_bundle of World_configuration_bundle.error

type receipt =
  { bundle : World_configuration_bundle.t
  ; lock_warnings : Runtime.config_lock_warning list
  }

val capture : base_path:string -> (receipt, error) result
(** Uses the resolved config root, including explicit MASC_CONFIG_DIR, and
    the explicit workspace's durable override file. Missing documents are
    recorded as absent; unreadable/malformed files fail rather than silently
    reducing the exported fleet. Does not modify or activate configuration.
    File-lock admission may create its ordinary lock file. *)

val error_to_string : error -> string
