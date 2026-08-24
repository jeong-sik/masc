(** The name of one spawned process.

    RFC spawn-a-process-that-outlives-the-call §3.2.

    A handle has to survive a round trip through a caller that holds it as
    text, come back, and still name the process it named before -- including
    after that process has ended, and including after the run that issued it
    has not. An index into a table does neither: a number that can be reissued
    names whatever started next, which is how openai/codex#34115 loses a
    process's identity.

    So a handle carries the run that issued it. A handle from an earlier run
    parses and then matches nothing, which is an answer; it does not
    accidentally match something. *)

type t

val to_string : t -> string
(** The wire form, [<run>-<n>]. Stable: a handle rendered and parsed is the
    same handle. *)

val of_string : string -> t option
(** [None] for text that is not a handle. Text arriving from a caller is a
    string until this says otherwise, and an unknown handle is an ordinary
    answer rather than an exception. *)

val equal : t -> t -> bool
val run : t -> string
(** Which run issued this handle. Two handles from different runs are never
    equal, whatever their numbers. *)

type issuer

val issuer : run:string -> issuer option
(** [None] when [run] is empty. The run is given by the caller rather than read
    from a global, so a test fixes it with the same argument production uses --
    there is no seam here that only tests take. *)

val issue : issuer -> t
(** A handle no other call to this issuer has returned or will return. *)
