(** Service-host presentation dependencies. The parser environment belongs to
    this workspace, outside immutable installed release files and producer guests. *)
val environment_dir : base_path:string -> string
val parser_python : base_path:string -> string
val parser_install_commands : base_path:string -> string list list

type t
val observe : base_path:string -> unit -> t
(** Import python-pptx and open its bundled empty presentation with the exact
    managed interpreter; start LibreOffice's version command in the current host
    environment. Never installs dependencies or reads a submitted document. *)
val available : t -> bool
val parser_available : t -> bool
val renderer_available : t -> bool
val to_json : t -> Yojson.Safe.t
