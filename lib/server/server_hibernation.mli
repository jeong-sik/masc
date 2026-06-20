(** Server hibernation capability surface.

    MASC currently runs as a long-lived supervisor. This module exposes that
    fact explicitly so operators and keepers do not infer scale-to-zero support
    from pause/resume or graceful-shutdown primitives. *)

val status_json : unit -> Yojson.Safe.t
(** Return the current hibernation capability contract for health snapshots. *)
