(** One validated original report revision. No rendered or reconstructed text. *)
type t
val create : report:Masc_tui_resource_catalog.report -> source:string -> (t, string) result
val label : t -> string
val suggested_name : t -> string
val same : t -> t -> bool
val key : t -> Masc_tui_resource_catalog.key
val matches_key : t -> Masc_tui_resource_catalog.key -> bool
(** Exact original report key, including revision and body bytes/hash. An MCP
    URI or another original report cannot acquire this saved receipt. *)
val dashboard_url : host:string -> port:int -> t -> string
(** A normal Dashboard deep link with an explicit revision, without credentials.
    The browser uses its own authentication. *)
val public_url : base_url:string option -> report:Masc_tui_resource_catalog.report -> (string, string) result
(** Build a fixed-revision link from an explicitly configured HTTP(S) origin.
    Reject invalid origins, local or wildcard literals and noncanonical numeric
    hosts. This does not verify reachability or that sharing is enabled. *)
val path_input : string -> (string, string) result
(** Preserve UTF-8 and spaces exactly. Refuse control bytes and malformed text
    instead of silently changing the destination. Empty text is valid editing. *)
type save_error =
  | Invalid_destination of string
  | Create_failed of Fs_compat.create_file_error
val error_target_effect : save_error -> Fs_compat.capability_write_target_effect option
(** [None] means unobserved, not unchanged. [Invalid_destination] is rejected
    before filesystem entry and therefore returns [Some Target_unchanged]. *)
val refused_existing_target : save_error -> bool
(** Only typed [Target_already_exists] with [Target_unchanged], including a
    preserved original write result under a later cleanup/release failure. *)
val error_to_string : save_error -> string

type cancellation = Fs_compat.create_file_cancellation
val cancellation : exn -> cancellation option
(** Structural classification only, including plain [Eio.Cancel.Cancelled] with
    an unknown effect and typed recovery/cleanup wrappers. The caller must
    re-raise its original exception and backtrace; this helper does not consume it. *)
val cancellation_effect : cancellation -> Fs_compat.capability_write_target_effect option
val cancellation_to_string : cancellation -> string

val save : fs:Eio.Fs.dir_ty Eio.Path.t -> path:string -> t -> (unit, save_error) result
(** Exclusive creation in an existing directory, mode 0600. Existing files are
    never replaced. The destination parent retains the shared publication recovery
    registry under the stable export owner. The shared writer preserves uncertain
    effects and reports failures; callers must not automatically retry a save. *)
