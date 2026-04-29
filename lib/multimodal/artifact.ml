(* Artifact — Cycle 24 / Tier B8.
   See artifact.mli for design rationale. *)

(* ── Phantom witnesses ────────────────────────────────────────── *)

type code = |
type image = |
type audio = |
type doc = |

(* ── Kind GADT ────────────────────────────────────────────────── *)

type _ kind =
  | Code : code kind
  | Image : image kind
  | Audio : audio kind
  | Doc : doc kind

type any_kind = Any_kind : 'a kind -> any_kind

(* ── Kind tag (structural mirror) ─────────────────────────────── *)

type kind_tag =
  | Tag_code [@tla.symbol "code"]
  | Tag_image [@tla.symbol "image"]
  | Tag_audio [@tla.symbol "audio"]
  | Tag_doc [@tla.symbol "doc"]
[@@deriving tla]

let all_kind_tags = [ Tag_code; Tag_image; Tag_audio; Tag_doc ]

let kind_tag_to_string = to_tla_symbol

let kind_to_tag : type a. a kind -> kind_tag = function
  | Code -> Tag_code
  | Image -> Tag_image
  | Audio -> Tag_audio
  | Doc -> Tag_doc

let any_kind_to_tag (Any_kind k) = kind_to_tag k

let kind_to_string : type a. a kind -> string =
 fun k -> kind_tag_to_string (kind_to_tag k)

let any_kind_to_string (Any_kind k) = kind_to_string k

(* ── Artifact record + existential ────────────────────────────── *)

type 'a t = {
  id : Shared_types.Artifact_id.t;
  kind : 'a kind;
  payload : Payload.t;
  metadata : Yojson.Safe.t;
  provenance : Provenance_stub.t;
}

type any = Any : 'a t -> any

let any_id (Any a) = a.id
let any_kind_of (Any a) = Any_kind a.kind

let to_json : type a. a t -> Yojson.Safe.t =
 fun a ->
  `Assoc
    [
      ("id", Shared_types.Artifact_id.to_json a.id);
      ("kind", `String (kind_to_string a.kind));
      ("payload", Payload.to_json a.payload);
      ("metadata", a.metadata);
      ("provenance", Provenance_stub.to_json a.provenance);
    ]

let any_to_json (Any a) = to_json a
