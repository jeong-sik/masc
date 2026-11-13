(** What moved between a retained review original and the review authority
    current before its dispatch.

    This is the evidence of a before-dispatch refusal. Such a refusal reaches
    no reviewer and has no verdict, so it carries no review result, receipt or
    evaluator runtime. The question did not move: a changed question is not an
    authority change and never produces this value. *)

type pair = { before : string; after : string }
(** The retained value first, then the current one. *)

type t =
  | Authority of pair
      (** The lookup authority digest moved. *)
  | Output_contract of pair
      (** The answer format sentence moved. *)
  | Both of { authority : pair; output_contract : pair }

val schema : string
(** The wire schema name carried by {!to_json}. *)

val between : authority:pair -> output_contract:pair -> t option
(** [None] when neither pair moved, so a change without a moved value cannot
    be built. *)

val to_json : t -> Yojson.Safe.t

val of_json : Yojson.Safe.t -> (t, string) result
(** Strict inverse of {!to_json}: the schema name, the exact key set, and only
    pairs whose values differ. An authority pair holds canonical SHA-256 text;
    an answer format pair holds non-blank text. *)

val to_string : t -> string
(** One plain sentence naming what moved. *)
