(** Current declaration observations for Apple guest sweep. This module never
    starts/stops/deletes a guest or mutates a declaration. *)

type t
(** Opaque coherent roster, including invalid declaration names that must be
    preserved. Bound to the workspace used by [read], not a reusable lease. *)

type unavailable =
  | Directory_unavailable of Fs_compat.owned_regular_file_read_error
  | Roster_changed
  | Filesystem_unavailable

val read : base_path:string -> (t, unavailable) result
(** Resolve the actual configured keeper directory, bind its owned no-follow
    identity, read exact declaration bytes and use the canonical TOML loader.
    A successfully read empty directory differs from missing/unreadable roster.
    Unreadable/unparseable declarations leave their loaded Keeper names unknown,
    so preserve all otherwise-delete candidates. Semantically unresolved loaded
    declarations preserve stem and loaded name while unrelated orphans remain
    selectable. An original roster-root symlink is unavailable.
    Refuse changes to roster identity, entries, file metadata or bytes. *)

val revalidate : t -> (unit, unavailable) result
(** Reobserve the same configured directory and exact files. Required immediately
    before each actual deletion. This detects stale observations; it does not
    claim atomic exclusion of an external configuration writer. *)

type preservation =
  | Roster_unavailable
  | Other_workspace
  | Unscoped_guest
  | Foreign_scope
  | Invalid_keeper_label
  | Declared_guest
  | Invalid_declaration

type candidate = { guest_name : string; keeper_name : string }
type selection = Preserve of preservation | Delete of candidate

val select :
  base_path:string -> declarations:(t, unavailable) result ->
  Keeper_microvm_guest_inventory.row -> selection
(** Pure candidate selection only. An unavailable roster preserves all rows.
    Match actual component/base/kind exactly. Current Apple guest names survive
    independently of owner PID. Foreign, malformed and uncertain rows preserve.
    A [Delete] value is not guest/snapshot mutation authority: the caller still
    needs lifecycle ownership, [revalidate] and actual deletion/absence checks. *)

val unavailable_message : unavailable -> string
(** Does not include declaration contents or parser diagnostics. *)
