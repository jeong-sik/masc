(** What moved between a retained review original and the review authority
    current before its dispatch.

    This is the evidence of a before-dispatch refusal. Such a refusal reaches
    no reviewer and has no verdict, so it carries no review result, receipt or
    evaluator runtime. The question did not move: a changed question is not an
    authority change and never produces this value. Only {!between} and
    {!of_json} build a value, so every value names something that moved. *)

type pair = private { before : string; after : string }
(** The retained digest first, then the current one. Both are canonical
    SHA-256 text and they differ. *)

type t = private
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
  retained_authority:string -> current_authority:string ->
  retained_format:string -> current_format:string -> (t option, string) result
(** The two lookup authority digests must be canonical SHA-256 text. The two
    answer format texts are recorded as their digests. [Ok None] when neither
    moved. *)

val begins_at : authority:string -> answer_format:string -> t -> bool
(** [true] when every moved value starts at this retained lookup authority
    digest and answer format text, so the change belongs to that original. *)

val to_json : t -> Yojson.Safe.t

val of_json : Yojson.Safe.t -> (t, string) result
(** Strict inverse of {!to_json}: the schema name, the exact key set, and only
    pairs of canonical SHA-256 text whose values differ. *)

val to_string : t -> string
(** One plain sentence naming what moved. *)
