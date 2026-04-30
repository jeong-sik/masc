(** Track 2 synchronization boundary policy.

    This module captures the small, typed contract for applying the
    multi-agent IDE Track 2 plan without changing transport or CRDT
    implementation code in the same slice. OCaml remains authoritative;
    CRDT/binary layers are admitted only as projections or transport
    envelopes. *)

type layer =
  | Authority
  | Projection
  | Ephemeral

type writer =
  | Ocaml_authority
  | Sync_sidecar
  | Dashboard_client

type rejection =
  | Not_authoritative
  | Projection_is_read_only
  | Ephemeral_only

type admission =
  | Accepted
  | Rejected of rejection

val layer_name : layer -> string
val writer_name : writer -> string
val rejection_name : rejection -> string
val admit_write : layer -> writer -> admission
val can_write : layer -> writer -> bool

(** Track 2 local collaboration cells target three to five active agents.
    For one or two agents, the single partial cell is preserved instead of
    padding with synthetic participants. *)
val cluster_sizes : int -> int list

(** [plan_clusters agents] preserves input ordering and partitions the list
    into deterministic Track 2 cells. *)
val plan_clusters : string list -> string list list

type frame_codec =
  | Json_text
  | Opaque_binary_frame
  | Native_binary_protocol

type frame_contract =
  { codec : frame_codec
  ; text_fallback : bool
  ; version_negotiated : bool
  ; semantics_preserved : bool
  ; collaboration_specific : bool
  }

val admits_frame_contract : frame_contract -> bool
