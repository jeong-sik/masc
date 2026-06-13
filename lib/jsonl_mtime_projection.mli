(** Mtime+size-gated projection cache for dashboard read paths.

    Caches a caller-built projection per [key] and rebuilds it only when one of
    its [sources] files changes, detected by a [(mtime, size)] signature stat
    per call. Size catches same-second appends to append-only files that a
    coarse mtime clock would miss; mtime catches rewrites. See the
    implementation header for the concurrency contract (single Eio domain;
    races only repeat idempotent work). *)

type 'a t
(** A cache of projections of type ['a], keyed by string. Not thread-safe across
    domains; intended for the single serving domain. *)

val create : unit -> 'a t
(** A fresh, empty cache. Typically created once at module load. *)

val file_signature : string -> float * int
(** [(mtime, size)] for [path]; [(0., -1)] marker components for a missing
    file so that its appearance or removal invalidates a dependent entry. *)

val get :
  'a t -> key:string -> sources:string list -> build:(unit -> 'a) -> 'a
(** [get t ~key ~sources ~build] returns the cached projection for [key] when
    every file in [sources] has an unchanged signature since it was built;
    otherwise it runs [build ()], caches the result against the current
    signatures, and returns it. [build] must be a pure function of the
    [sources] contents (and any value folded into [key]) for the cache to be
    behaviour-preserving — fold request parameters that change the output into
    [key]. *)
