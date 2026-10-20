(** Standalone reports. Pure wire validation and projections; storage lives in
    [Published_artifact_store]. Revision bodies remain content-addressed. *)
type format = Markdown | Html
type update = Create | Revise of { id : string; expected_revision : int }
type request = private
  { update : update
  ; title : string
  ; summary : string
  ; format : format
  ; content : string
  ; task_id : string option
  ; goal_id : string option
  }
type revision =
  { revision : int
  ; title : string
  ; summary : string
  ; format : format
  ; author : string
  ; created_at : string
  ; body : Tool_output.artifact_ref
  ; task_id : string option
  ; goal_id : string option
  }
type t = { id : string; revisions : revision list }

val valid_id : string -> bool
val format_name : format -> string
val media_type : format -> string
val request_of_json : Yojson.Safe.t -> (request, string) result
val to_json : t -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> (t, string) result
val revision_to_json : revision -> Yojson.Safe.t
val revision_of_json : Yojson.Safe.t -> (revision, string) result
val summary_to_json : id:string -> revision -> Yojson.Safe.t
val publication_to_json : id:string -> revision -> Yojson.Safe.t
val url : ?revision:int -> string -> string
