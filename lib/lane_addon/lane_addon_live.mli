(** Spectating: the current screen of the workspace machine behind a source
    kind that has one. A live read is not an observation and needs no Lane
    instance. It takes no store, so it writes no blob, no observation and no
    input ledger, and it never advances the machine. *)

type machine_time =
  | Msx_frame of int  (** frames stepped since power-on *)
  | Dos_steps of int  (** instructions run since load *)

type screen = {
  width : int;
  height : int;
  rgb : string;  (** [width * height] pixels, three bytes each *)
  time : machine_time;  (** the machine time this picture was taken at *)
  incarnation : string;  (** fresh on every load or restore *)
  counter : int;
      (** the machine's change counter, read with the picture. One counter
          per machine kind per process, never reset. *)
}

type reading =
  | Not_loaded
  | Unchanged of int  (** the counter still equals the caller's [since] *)
  | Loaded of screen

type error = Capture_failed of string  (** the machine refused a capture *)

val error_to_string : error -> string

type capture = Lane_addon_sources.live_reader -> since:int option -> (reading, error) result

val machine_capture : capture
(** Reads the workspace machine's change counter and, when it differs from
    [since], its picture through [capture_with_identity], which reads the
    counter, frame and incarnation under one lock. Both reads take the
    machine's stdlib [Mutex]: call it only through {!on_systhread}. *)

val on_systhread : capture -> capture
(** Runs the capture on a system thread with [Eio_unix.run_in_systhread], so
    the calling fiber's domain is never blocked on a machine lock. *)

val default_capture : capture
(** [on_systhread machine_capture]: the capture the HTTP route uses. *)

val reader_of_kind : string -> (Lane_addon_sources.live_reader, string) result
(** A source kind name as a binding spells it. [msx_capture] and
    [dos_capture] have a screen; every other kind, known or not, is an
    error. *)

val read : reader:Lane_addon_sources.live_reader -> since:int option ->
  capture:capture -> (Yojson.Safe.t, error) result
(** [{"loaded":false}] with no machine; [{"changed":false,"counter"}] when
    the counter equals [since]; otherwise [{"loaded":true,"changed":true,
    format,width,height,rgb_base64,"counter","incarnation"}] plus ["frame"]
    for MSX or ["steps"] for DOS. *)
