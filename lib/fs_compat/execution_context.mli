(** Whether the caller runs inside an Eio fiber.

    Used to pick between running blocking syscalls inline (no Eio: tests,
    CLI paths) and on a systhread ([Eio_unix.run_in_systhread]) so the
    domain keeps scheduling other fibers while the kernel works. *)

type t =
  | Eio_fiber
  | Non_eio

val current : unit -> t
(** Probes with a fiber-local effect; outside Eio the effect is unhandled.
    A systhread started by Eio's thread pool has no handler either, so it
    reports [Non_eio]. *)
