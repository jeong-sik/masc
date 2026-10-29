(** Pure config-snapshot projection for {!Env_config_snapshot}.

    This module consumes already-collected observations. It neither reads the
    environment nor retains reader closures. *)

type spec

type effective_source =
  | Default
  | Environment

type observation =
  | Raw_environment of string option
  | Runtime_file of string option
      (** The value [runtime.toml] gave a name the file alone feeds. *)
  | Applied_value of
      { value : string
      ; source : effective_source
      }

val make_spec :
  ?sensitive:bool -> default:string -> string -> string -> spec

val to_json : spec -> observation -> Yojson.Safe.t
