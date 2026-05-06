module Format = Stdlib.Format
module Map = Stdlib.Map
module Set = Stdlib.Set
module Queue = Stdlib.Queue
module Hashtbl = Stdlib.Hashtbl
module Mutex = Stdlib.Mutex
module Option = Stdlib.Option
module Result = Stdlib.Result
module Sys = Stdlib.Sys
module Filename = Stdlib.Filename
module List = Stdlib.List
module Array = Stdlib.Array
module String = Stdlib.String
module Char = Stdlib.Char
module Int = Stdlib.Int
module Float = Stdlib.Float

(** Board_curation — AI curation projection surface for the board.

    See board_curation.mli for the full contract. *)

(** {1 Types} *)

type curation_snapshot = {
  id : string;
  generated_at : float;
  submitted_by : string;
  model : string option;
  summary : string option;
  ordering : string list;
  highlights : string list;
  tag_suggestions : curation_tag_suggestion list;
  answer_matches : curation_answer_match list;
  health_score : float option;
  health_components : curation_health_component list;
  rationale : string;
  provenance : Yojson.Safe.t;
}

and curation_tag_suggestion = {
  post_id : string;
  tags : string list;
  rationale : string;
}

and curation_answer_match = {
  question_post_id : string;
  answer_post_id : string;
  score : float;
  rationale : string;
}

and curation_health_component = {
  name : string;
  score : float;
  weight : float;
  rationale : string;
}

(** {1 ID generation} *)

(* Caller must ensure [Mirage_crypto_rng] is seeded before the first call,
   following the same contract as board post/comment ID generation in
   board_types/board_types.ml. *)
let generate_id () =
  Random_id.prefixed ~prefix:"cu-" ~bytes:16

(** {1 JSON serialisation} *)

let snapshot_to_yojson (s : curation_snapshot) : Yojson.Safe.t =
  let tag_suggestion_to_yojson (t : curation_tag_suggestion) =
    `Assoc [
      ("post_id", `String t.post_id);
      ("tags", `List (List.map (fun tag -> `String tag) t.tags));
      ("rationale", `String t.rationale);
    ]
  in
  let answer_match_to_yojson (m : curation_answer_match) =
    `Assoc [
      ("question_post_id", `String m.question_post_id);
      ("answer_post_id", `String m.answer_post_id);
      ("score", `Float m.score);
      ("rationale", `String m.rationale);
    ]
  in
  let health_component_to_yojson (c : curation_health_component) =
    `Assoc [
      ("name", `String c.name);
      ("score", `Float c.score);
      ("weight", `Float c.weight);
      ("rationale", `String c.rationale);
    ]
  in
  `Assoc [
    ("id", `String s.id);
    ("generated_at", `Float s.generated_at);
    ("submitted_by", `String s.submitted_by);
    ("model", match s.model with Some m -> `String m | None -> `Null);
    ("summary", match s.summary with Some v -> `String v | None -> `Null);
    ("ordering", `List (List.map (fun id -> `String id) s.ordering));
    ("highlights", `List (List.map (fun id -> `String id) s.highlights));
    ("tag_suggestions", `List (List.map tag_suggestion_to_yojson s.tag_suggestions));
    ("answer_matches", `List (List.map answer_match_to_yojson s.answer_matches));
    ("health_score", match s.health_score with Some score -> `Float score | None -> `Null);
    ("health_components", `List (List.map health_component_to_yojson s.health_components));
    ("rationale", `String s.rationale);
    ("provenance", s.provenance);
  ]

(** {1 In-memory store} *)

(* Single-slot in-memory store.  Not thread-safe — see .mli contract. *)
let current : curation_snapshot option Atomic.t = Atomic.make None

let submit_snapshot snap =
  Atomic.set current (Some snap)

let latest_snapshot () =
  Atomic.get current

let reset_for_test () =
  Atomic.set current None
