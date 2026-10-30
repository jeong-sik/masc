(** One validated original report revision. No rendered or reconstructed text. *)
type t
val create : report:Masc_tui_resource_catalog.report -> source:string -> (t, string) result
val label : t -> string
val suggested_name : t -> string
val same : t -> t -> bool
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
val save : fs:Eio.Fs.dir_ty Eio.Path.t -> path:string -> t -> (string, string) result
(** Exclusive creation in an existing directory, mode 0600. Existing files are
    never replaced. The destination parent retains the shared publication recovery
    registry under the stable export owner. The shared writer preserves uncertain
    effects and reports failures; callers must not automatically retry a save. *)
