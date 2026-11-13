(** What moved between a retained review original and the review authority
    current before its dispatch.

    This is the evidence of a before-dispatch refusal. Such a refusal reaches
    no reviewer and has no verdict, so it carries no review result, receipt or
    evaluator runtime. The question did not move: a changed question is not an
    authority change and never produces this value. *)

type pair = { before : string; after : string }
(** The retained digest first, then the current one. Both are canonical
    SHA-256 text. *)

type t =
  | Authority of pair
      (** The lookup authority digest moved. *)
  | Output_contract of pair
      (** The answer format moved; the pair holds the digests of the two
          answer format texts. *)
  | Both of { authority : pair; output_contract : pair }

val schema : string
(** The wire schema name carried by {!to_json}. *)

val answer_format_digest : string -> string
(** The digest an answer format pair records for one answer format text. *)

val between :
  authority:pair -> retained_format:string -> current_format:string -> t option
(** [authority] holds the retained and current lookup authority digests. The
    two answer format texts are recorded as their digests. [None] when neither
    moved, so a change without a moved value cannot be built. *)

val to_json : t -> Yojson.Safe.t

val of_json : Yojson.Safe.t -> (t, string) result
(** Strict inverse of {!to_json}: the schema name, the exact key set, and only
    pairs of canonical SHA-256 text whose values differ. *)

val to_string : t -> string
(** One plain sentence naming what moved. *)
