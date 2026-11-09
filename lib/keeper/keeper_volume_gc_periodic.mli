(** One periodic report-only pass of {!Keeper_volume_gc}, and the value the
    dashboard tools envelope carries for the last one. The server writes it
    and the TUI reads it with this one module.

    A pass never deletes: {!observe} itself asks for
    {!Keeper_volume_gc.Report_only}, and its caller cannot hand it another
    request. *)

type outcome =
  | Reported of Keeper_volume_gc_answer.t
      (** The answer [masc_sandbox_volume_gc] gives without [execute]. *)
  | Skipped of string
      (** This host has no answering Apple Container, in the readiness
          check's words. No volume command ran. *)
  | Failed of string
      (** The claims image did not resolve, the volume listing failed, or
          the pass raised. Nothing was judged. *)

type t =
  { observed_at : float  (** Unix seconds when the pass ended. *)
  ; outcome : outcome
  }

(** ["sandbox_volume_gc_report"]: the envelope field. [null] until the
    server's first pass ends. *)
val envelope_field : string

(** One pass: [ready], then [resolve_claims_image], then [judge] with
    {!Keeper_volume_gc.Report_only}. The first step that fails ends the pass
    with its reason, and the steps after it do not run. An exception other
    than cancellation becomes [Failed]; cancellation is raised again. *)
val observe :
  now:(unit -> float)
  -> ready:(unit -> ('ready, string) result)
  -> resolve_claims_image:(unit -> (string option, string) result)
  -> judge:
       ('ready
        -> claims_image:string option
        -> request:Keeper_volume_gc.request
        -> (Keeper_volume_gc.report, string) result)
  -> t

val to_json : t -> Yojson.Safe.t

(** Refuses a missing, duplicate or unknown field, an unknown outcome, a
    blank reason, an answer {!Keeper_volume_gc_answer.of_json} refuses, and
    an answer that executed. *)
val of_json : Yojson.Safe.t -> (t, string) result
