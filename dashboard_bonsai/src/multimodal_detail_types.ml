(** Tier F2 — typed model of [/api/v1/multimodal/get/<id>] and
    [/api/v1/multimodal/provenance/<id>].

    Schema source: [lib/server/server_routes_http_routes_multimodal.ml]
    [artifact_response] (full artifact JSON) and [provenance_response]
    ([{id, origins[], descendants[]}]).

    F2 renders a detail panel when an artifact is selected: payload
    pretty-print, metadata, origins/descendants list. Lists are
    flat string ids; F2 does not yet render a provenance DAG. *)

open! Core

type detail =
  { id : string
  ; kind : string
  ; payload_pretty : string
      (* Whole [payload] sub-tree pretty-printed as JSON. Server
         returns this verbatim (lazy-decoded blobs are stringified
         server-side); F2 does not interpret kind-specific shapes. *)
  ; metadata_pretty : string
      (* Whole [metadata] sub-tree pretty-printed as JSON for
         operator inspection. *)
  ; created_by : string
  }

type provenance =
  { origins : string list
  ; descendants : string list
  }

let pretty_of json =
  Yojson.Safe.pretty_to_string ~std:true json

let detail_of_yojson (json : Yojson.Safe.t) : detail =
  let string_field name =
    match Yojson.Safe.Util.member name json with
    | `String s -> s
    | _ -> ""
  in
  let payload_pretty =
    pretty_of (Yojson.Safe.Util.member "payload" json)
  in
  let metadata_pretty =
    pretty_of (Yojson.Safe.Util.member "metadata" json)
  in
  let created_by =
    match Yojson.Safe.Util.member "provenance" json with
    | `Null -> ""
    | prov ->
      (match Yojson.Safe.Util.member "created_by" prov with
       | `String s -> s
       | _ -> "")
  in
  { id = string_field "id"
  ; kind = string_field "kind"
  ; payload_pretty
  ; metadata_pretty
  ; created_by
  }
;;

let string_list_of_yojson_member (json : Yojson.Safe.t) (name : string)
    : string list =
  match Yojson.Safe.Util.member name json with
  | `List xs ->
    List.filter_map xs ~f:(function
      | `String s -> Some s
      | _ -> None)
  | _ -> []
;;

let provenance_of_yojson (json : Yojson.Safe.t) : provenance =
  { origins = string_list_of_yojson_member json "origins"
  ; descendants = string_list_of_yojson_member json "descendants"
  }
;;
