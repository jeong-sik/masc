(** Tier F1 — typed model of [/api/v1/multimodal/list].

    Schema source: [lib/server/server_routes_http_routes_multimodal.ml]
    [list_response]. Response contains a [count] (int) and an
    [artifacts] array; each artifact carries [id], [kind], [payload],
    [metadata], and [provenance].

    F1 only renders id/kind/metadata-summary on cards. [payload] is
    deliberately ignored here — it can be large and is fetched
    on-demand via [/api/v1/multimodal/get/<id>] (deferred to F2). *)

open! Core

type artifact =
  { id : string
  ; kind : string  (* "code" | "image" | "audio" | "doc" — see lib/multimodal/artifact.ml *)
  ; metadata_keys : string list  (* short summary: top-level keys of metadata object *)
  ; created_by : string  (* from provenance.created_by, "" if absent *)
  }

type response =
  { count : int
  ; artifacts : artifact list
  }

let empty_response : response = { count = 0; artifacts = [] }

let string_field json name : string =
  match Yojson.Safe.Util.member name json with
  | `String s -> s
  | _ -> ""
;;

let metadata_keys_of json : string list =
  match json with
  | `Assoc kv -> List.map kv ~f:fst
  | _ -> []
;;

let artifact_of_yojson (json : Yojson.Safe.t) : artifact =
  let id = string_field json "id" in
  let kind = string_field json "kind" in
  let metadata_keys =
    metadata_keys_of (Yojson.Safe.Util.member "metadata" json)
  in
  let created_by =
    match Yojson.Safe.Util.member "provenance" json with
    | `Null -> ""
    | prov -> string_field prov "created_by"
  in
  { id; kind; metadata_keys; created_by }
;;

let response_of_yojson (json : Yojson.Safe.t) : response =
  let count =
    match Yojson.Safe.Util.member "count" json with
    | `Int n -> n
    | _ -> 0
  in
  let artifacts =
    match Yojson.Safe.Util.member "artifacts" json with
    | `List xs -> List.map xs ~f:artifact_of_yojson
    | _ -> []
  in
  { count; artifacts }
;;
