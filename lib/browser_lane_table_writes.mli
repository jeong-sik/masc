(** The [runtime.toml] tables one [masc browser-lane-setup] run writes, in
    order: [\[browser.live.bidi\]], the automation table, then
    [\[browser.live.ego\]].

    Each table is committed on its own. A refusal leaves the tables before it
    written, so {!write} answers them together with the refusal, and the steps
    after a refusal do not run. *)

type ('bidi, 'automation, 'ego) written =
  { bidi : 'bidi option
  ; automation : 'automation option
  ; ego : 'ego option
  }

type ('bidi, 'automation, 'ego) outcome =
  { written : ('bidi, 'automation, 'ego) written
  ; refusal : string option  (** The first step that refused, in its own words. *)
  }

(** A table's step. [after_write] is true when a table before it was written
    in this run: its plan was made against the file before that write, so it
    has to be made again against the file as it is now. *)
type 'a step = after_write:bool -> ('a, string) result

(** Runs the steps that are there, in order, until one refuses. *)
val write
  :  bidi:(unit -> ('bidi, string) result) option
  -> automation:'automation step option
  -> ego:'ego step option
  -> ('bidi, 'automation, 'ego) outcome
