(** Verification - Cross-agent task output verification for MASC

    Based on MAST taxonomy (Cemri et al., 2025, arXiv:2503.13657).
    Task verification is one of the three failure categories. *)

(** {1 Types} *)

type criterion =
  | Schema_match of Yojson.Safe.t
  | Contains of string
  | Not_contains of string
  | Custom of string

val show_criterion : criterion -> string
val equal_criterion : criterion -> criterion -> bool
val criterion_to_yojson : criterion -> Yojson.Safe.t
val criterion_of_yojson : Yojson.Safe.t -> (criterion, string) result

type verdict =
  | Pass
  | Fail of string
  | Partial of float * string

val show_verdict : verdict -> string
val equal_verdict : verdict -> verdict -> bool
val verdict_to_yojson : verdict -> Yojson.Safe.t
val verdict_of_yojson : Yojson.Safe.t -> (verdict, string) result

type request_status =
  | Pending
  | Assigned of string
  | Completed of verdict

type verification_request =
  { id : string
  ; task_id : string
  ; output : Yojson.Safe.t
  ; criteria : criterion list
  ; worker : string
  ; verifier : string option
  ; created_at : float
  ; status : request_status
  }

(** {1 Serialization} *)

val request_to_yojson : verification_request -> Yojson.Safe.t
val request_of_yojson : Yojson.Safe.t -> (verification_request, string) result

(** {1 Evaluation} *)

val evaluate_criterion : Yojson.Safe.t -> criterion -> verdict
val evaluate_all : Yojson.Safe.t -> criterion list -> verdict
val validate_cross_agent : worker:string -> verifier:string -> (unit, string) result

(** {1 Storage} *)

val generate_id : unit -> string
val save_request : string -> verification_request -> (string, string) result
val load_request : string -> string -> (verification_request, string) result
val list_requests : string -> verification_request list

(** {1 High-level API} *)

val create_request
  :  base_path:string
  -> task_id:string
  -> output:Yojson.Safe.t
  -> criteria:criterion list
  -> worker:string
  -> ?verifier:string
  -> ?request_id:string
  -> unit
  -> (verification_request, string) result

val assign_verifier
  :  base_path:string
  -> req_id:string
  -> verifier:string
  -> (verification_request, string) result

val submit_verdict
  :  base_path:string
  -> req_id:string
  -> verifier:string
  -> verdict:verdict
  -> (verification_request, string) result

val auto_verify
  :  base_path:string
  -> req_id:string
  -> (verification_request, string) result

val pending_for_agent : base_path:string -> agent:string -> verification_request list

(** {1 Attribution envelope (Layer 1)}

    Convert verification verdicts into the typed attribution envelope used
    by SSE emitters. Verification is hybrid: rule-based criteria
    ([Schema_match], [Contains], [Not_contains]) are [Det], while [Custom]
    invokes an LLM judge and is [NonDet]. Origin is derived from the
    criteria set. *)

(** [Det] when all criteria are rule-based, [NonDet] if any [Custom]
    criterion is present. *)
val origin_of_criteria : criterion list -> Attribution.origin

(** Count criteria by kind ({schema_match, contains, not_contains, custom}).
    Used as compact evidence payload — signals the Det/NonDet mix without
    dumping full criterion contents. *)
val criteria_counts : criterion list -> Yojson.Safe.t

(** Direct verdict → Attribution conversion. Caller supplies [origin]
    (typically via [origin_of_criteria]) and [evidence]. Mapping:
    - [Pass]                → [Attribution.Passed]
    - [Fail reason]         → [Attribution.Policy_failed { reason }]
    - [Partial (s, reason)] → [Attribution.Partial_pass { score = s;
                                 rationale = reason }] *)
val to_attribution
  :  origin:Attribution.origin
  -> evidence:Yojson.Safe.t
  -> verdict
  -> Attribution.t

(** Standard evidence shape for a verification request:
    [{ request_id, task_id, worker, verifier, criteria_counts }]. *)
val evidence_of_request : verification_request -> Yojson.Safe.t

(** Returns [Some attribution] when the request carries a [Completed]
    verdict (origin derived from criteria, standard evidence shape).
    [None] for [Pending] / [Assigned] — there is no verdict yet. *)
val attribution_of_request : verification_request -> Attribution.t option
