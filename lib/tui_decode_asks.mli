(** {1 Questions a Keeper put to the operator}

    Decoded from [GET /api/v1/keepers/asks]. The rows carry choice ids
    alongside labels and the answer POST takes ids back, so a surface built on
    these types never matches on label text: rewording a choice cannot orphan
    an answer already recorded. *)

type ask_choice = {
  ac_id : string;  (** what an answer names; never the label *)
  ac_label : string;
  ac_description : string option;
}

type ask_mode =
  | Ask_single
  | Ask_multi

type ask_free_text =
  | Ask_free_text_allowed of { aft_hint : string option }
  | Ask_choices_only

type ask_question = {
  aq_id : string;
  aq_header : string;  (** two or three words; what a narrow row shows *)
  aq_prompt : string;
  aq_mode : ask_mode;
  aq_free_text : ask_free_text;
  aq_choices : ask_choice list;
}

type ask_resolution =
  | Ask_open
  | Ask_answered of {
      aa_answered_at : float;
      aa_question_ids : string list;
    }
  | Ask_withdrawn of {
      aw_reason : string;
      aw_withdrawn_at : float;
    }

type ask_row = {
  ar_keeper : string;
  ar_id : string;
  ar_asked_at : float;
  ar_context : string option;
      (** why the Keeper is asking, in its own words. A row that hides this
          reads as a decision with no stakes. *)
  ar_questions : ask_question list;
  ar_resolution : ask_resolution;
}

type asks_snapshot = {
  asn_keeper : string option;
  asn_open_count : int;  (** the server's count, not [List.length asn_rows] *)
  asn_rows : ask_row list;
}

val decode_asks_snapshot : Yojson.Safe.t -> (asks_snapshot, string) result
(** A row whose mode or free-text shape is unknown fails the decode rather
    than defaulting: a surface that guessed would offer the operator a control
    the server will refuse. *)
