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

(* ── Provenance record + JSON ─────────────────────────────────── *)

type provenance = {
  origin_artifact_ids : Shared_types.Artifact_id.t list;
  created_by : string;
  created_at : float;
}

let provenance_empty ~created_by ~created_at =
  { origin_artifact_ids = []; created_by; created_at }

let kind_name_of_json : Yojson.Safe.t -> string = function
  | `Null -> "null"
  | `Bool _ -> "bool"
  | `Int _ -> "int"
  | `Intlit _ -> "intlit"
  | `Float _ -> "float"
  | `String _ -> "string"
  | `Assoc _ -> "object"
  | `List _ -> "array"

let provenance_to_json p =
  `Assoc
    [
      ( "origin_artifact_ids",
        `List
          (List.map Shared_types.Artifact_id.to_json p.origin_artifact_ids)
      );
      ("created_by", `String p.created_by);
      ("created_at", `Float p.created_at);
    ]

let provenance_of_json = function
  | `Assoc kv ->
      let origin_result =
        match List.assoc_opt "origin_artifact_ids" kv with
        | Some (`List xs) ->
            List.fold_right
              (fun j acc ->
                match (Shared_types.Artifact_id.of_json j, acc) with
                | Ok id, Ok rest -> Ok (id :: rest)
                | Error e, _ -> Error e
                | _, Error e -> Error e)
              xs (Ok [])
        | None -> Ok []
        | Some other ->
            Error
              (Printf.sprintf
                 "origin_artifact_ids must be a JSON list (got %s)"
                 (kind_name_of_json other))
      in
      let created_by_result =
        match List.assoc_opt "created_by" kv with
        | Some (`String s) -> Ok s
        | None -> Error "created_by is required"
        | Some other ->
            Error
              (Printf.sprintf
                 "created_by must be a JSON string (got %s)"
                 (kind_name_of_json other))
      in
      let created_at_result =
        match List.assoc_opt "created_at" kv with
        | Some (`Float f) -> Ok f
        | Some (`Int i) -> Ok (float_of_int i)
        | None -> Error "created_at is required"
        | Some other ->
            Error
              (Printf.sprintf
                 "created_at must be a JSON number (got %s)"
                 (kind_name_of_json other))
      in
      (match origin_result, created_by_result, created_at_result with
       | Ok ids, Ok name, Ok ts ->
           Ok
             {
               origin_artifact_ids = ids;
               created_by = name;
               created_at = ts;
             }
       | Error e, _, _ | _, Error e, _ | _, _, Error e -> Error e)
  | other ->
      Error
        (Printf.sprintf "provenance must be a JSON object (got %s)"
           (kind_name_of_json other))

(* ── Artifact record + existential ────────────────────────────── *)

type 'a t = {
  id : Shared_types.Artifact_id.t;
  kind : 'a kind;
  payload : Payload.t;
  metadata : Yojson.Safe.t;
  provenance : provenance;
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
      ("provenance", provenance_to_json a.provenance);
    ]

let any_to_json (Any a) = to_json a
