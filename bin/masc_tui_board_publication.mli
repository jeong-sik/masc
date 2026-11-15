(** One ordinary Board publication and its session-retained observation.
    Requests and outcomes are immutable; this module performs no I/O. *)

type board_upload_kind = Uk_image | Uk_audio | Uk_score | Uk_midi | Uk_file
val board_upload_kind_to_wire : board_upload_kind -> string
val upload_kind_of_path : string -> board_upload_kind

type board_staged_attachment = {
  sa_path : string;
  sa_name : string;
  sa_kind : board_upload_kind;
}

type board_outbound_attachment = {
  oa_kind : board_upload_kind;
  oa_sha256 : string;
  oa_name : string;
}
val board_outbound_attachments_field :
  board_outbound_attachment list -> (string * Yojson.Safe.t) option

type request_id
type 'authority request = private {
  id : request_id;
  authority : 'authority;
  host : string;
  port : int;
  expected_workspace : Masc.Tui_decode.server_identity option;
  sent_draft : string;
  staged : board_staged_attachment list;
  title : string;
  body : string;
  hearth : string option;
}
val capture :
  authority:'authority -> host:string -> port:int ->
  expected_workspace:Masc.Tui_decode.server_identity option ->
  sent_draft:string -> staged:board_staged_attachment list ->
  title:string -> body:string -> hearth:string option -> unit -> 'authority request
val same_request : 'authority request -> 'authority request -> bool
(** Exact original request identity, independent of equal contents or a later
    return to the same workspace. Staged objects retain physical identity. *)

type 'authority prepared = private {
  request : 'authority request;
  body : string;
}
val bind_body : 'authority request -> body:string -> 'authority prepared
(** The HTTP payload owner calls this once after ordered uploads and immediately
    before transport. [body] is the exact serialized string supplied to HTTP,
    including the admitted workspace and returned attachment digests. *)

type committed = private {
  post_id : Board_types.Post_id.t;
  canonical_result : Yojson.Safe.t;
}
type failure = private {
  effect_disposition : Failure_effect.t;
  committed_post_id : Board_types.Post_id.t option;
  class_ : Tool_result.tool_failure_class;
  message : string;
  canonical_result : Yojson.Safe.t;
}
(** A committed ID exists exactly for [Proven_post_effect]. This is an
    observation of the Board result, not a reconstruction of retained tool
    artifacts or model-visible content omitted by the wire encoder. *)

type acknowledgement =
  (committed, Yojson.Safe.t, failure) Tool_result.disposition
type response = private
  | Answered of acknowledgement
  | Unanswered of { detail : string; raw_response : (int * string) option }

val decode_response : status_code:int -> body:string -> response
(** Decode the nested canonical Board result before generic HTTP status
    reduction. Root [ok]/[message] and status classes establish no effect
    proof. Unknown or malformed fields retain an unanswered observation. *)
val unanswered : string -> response
val committed_post_id : response -> Board_types.Post_id.t option
val response_diagnostic : ko:bool -> response -> string option
(** What to say about a response beyond whether it took: the server's own
    message for a failure, or why no readable answer came back. *)

val outcome_unknown : ko:bool -> string
(** A post that may or may not have been created. The Board row that asks
    for a look before retrying and the diagnostic that says why name it in
    these words. *)
val response_effect : response -> Failure_effect.t

type 'authority outcome = private
  | Not_attempted of { request : 'authority request; detail : string }
  | Returned of { prepared : 'authority prepared; response : response }
val not_attempted : 'authority request -> detail:string -> 'authority outcome
(** No Board publication call began. Earlier content-addressed artifact uploads
    may already exist; this is not a claim that no external effect happened. *)
val returned : 'authority prepared -> response -> 'authority outcome
val outcome_request : 'authority outcome -> 'authority request

type 'authority entry = Pending of 'authority request | Finished of 'authority outcome
type 'authority history
val empty : 'authority history
val register : 'authority history -> 'authority request -> 'authority history
type 'authority recording =
  | Recorded of 'authority history
  | Already_recorded
  | Not_registered
val record : 'authority history -> 'authority outcome -> 'authority recording
(** Settle only an originally registered exact request. The first terminal
    observation wins; duplicate or foreign deliveries cannot replace it. *)
val entries : 'authority history -> 'authority entry list
(** Original submission order. This session history does not grant current
    workspace, draft or replay authority and does not survive process exit. *)
