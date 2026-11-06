(** The operator's reclamation of retired Keepers' Apple volumes.

    [masc_sandbox_volume_gc] needs [CanAdmin]. The TUI calls it with the
    operator's own credential. Neither a Claude session (a worker token) nor a
    Keeper (the tool is operator-only) can call it.

    The first press asks for a report, and nothing is deleted. The report
    names each retired Keeper's volumes and why they stay or can go. When it
    lists reclaim candidates, a second press asks the server to reclaim. The
    server judges again at that moment and confirms each build-only volume
    right before it deletes it. So the answer to the second press, not the
    report, says what was reclaimed. *)

(** ["masc_sandbox_volume_gc"]. *)
val tool : string

(** The sandbox image catalog name the claims-read helper runs on.
    [config/sandbox-images.toml] defines [base] as the general image; the
    helper only reads a marker file from the mounted work volume. Without an
    image the server reads no marker and reclaims nothing. *)
val claims_image : string

val arguments : execute:bool -> (string * Yojson.Safe.t) list

type answer =
  | Report of Masc.Keeper_volume_gc_answer.t
  | Refused of string  (** The tool answered with an error, in its words. *)
  | Unreadable of string  (** The answer did not decode, and why. *)

val answer_of_text : is_error:bool -> string -> answer

(** The reclaim candidates of a report that only reported, in report order.
    [None] for an answer that a second press must not act on: a refusal, an
    unreadable answer, an executed report, or a report with no candidate. *)
val reclaimable : answer -> string list option

(** One line: ["N kept · M reclaim candidates · R reclaimed · F failed"]. *)
val summary_line : Masc.Keeper_volume_gc_answer.t -> string

(** The line shown under a report that has candidates. *)
val confirm_prompt : confirm_key:string -> string list -> string

(** The sections of the reading that shows an answer: the summary, one line
    per Keeper, and the volumes that are not a Keeper's. Text from the server
    is made single-line for the terminal. *)
val sections : answer -> (string * string) list
