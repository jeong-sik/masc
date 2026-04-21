(** Keeper_sandbox — Keeper-facing sandbox contract.

    Keeper tools expose exactly one logical sandbox. The current
    local-storage implementation lives at
    [.masc/playground/<keeper>], but that path is an implementation
    detail of the local / docker backends. *)

(** {1 Types} *)

type backend =
  | Local
  | Docker

type t = {
  keeper_name : string;
  sandbox_id : string;
  backend : backend;
  sandbox_profile : string;
  network_mode : string;
  host_root_rel : string;
  host_root_abs : string;
  container_root : string option;
  root_arg : string;
  mind_arg : string;
  repos_arg : string;
  task_overlay_pattern : string;
}

(** {1 Backend helpers} *)

val backend_to_string : backend -> string

(** {1 Path resolution} *)

(** [host_root_abs ~config name] returns the absolute host-side
    sandbox root for [name] rooted at [config.base_path]. *)
val host_root_abs : config:Coord.config -> string -> string

(** [container_root name] returns the in-container path used by the
    hardened Docker backend. *)
val container_root : string -> string

(** {1 Construction} *)

(** [of_meta ~config ~meta] derives the full sandbox record from a
    keeper meta entry. Backend is chosen from [meta.sandbox_profile]. *)
val of_meta :
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  t

(** {1 Access control hints} *)

(** Relative roots that tools may touch inside the keeper's
    sandbox. Currently a single-element list. *)
val allowed_path_roots : name:string -> string list

(** Single relative root for [name] (convenience). *)
val allowed_root_rel : name:string -> string

(** {1 Dashboard / status output} *)

(** Key-value fields describing the sandbox shape (id, backend,
    profile, network mode, lifetime, root/mind/repos args, overlay
    pattern). Suitable for splicing into a JSON [Assoc]. *)
val context_status_fields :
  t -> (string * Yojson.Safe.t) list
