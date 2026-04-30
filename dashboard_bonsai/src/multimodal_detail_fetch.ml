(** Tier F2 — single-shot fetch of artifact detail + provenance.

    Triggered by [Multimodal_view] card on_click; not polling. The
    detail and provenance vars are reset to [None] before the fetch
    starts so the panel can render a "loading" state. Both endpoints
    are fetched in parallel and each callback writes only its own
    var (no shared peek).

    Failed fetches leave the corresponding var at [None]. *)

open! Core
open Brr_io

let detail_endpoint id = Printf.sprintf "/api/v1/multimodal/get/%s" id
let provenance_endpoint id =
  Printf.sprintf "/api/v1/multimodal/provenance/%s" id
;;

let parse_json_or_error (text : Jstr.t) : Yojson.Safe.t option =
  match Yojson.Safe.from_string (Jstr.to_string text) with
  | json ->
    (* Server returns a top-level error envelope on lookup failure;
       reject those by checking for an "error" field at the top
       level (artifact_response and provenance_response shapes never
       carry one). *)
    (match Yojson.Safe.Util.member "error" json with
     | `String _ -> None
     | _ -> Some json)
  | exception _ -> None
;;

let parse_detail (text : Jstr.t) : Multimodal_detail_types.detail option =
  Option.map (parse_json_or_error text) ~f:Multimodal_detail_types.detail_of_yojson
;;

let parse_provenance (text : Jstr.t)
  : Multimodal_detail_types.provenance option
  =
  Option.map (parse_json_or_error text)
    ~f:Multimodal_detail_types.provenance_of_yojson
;;

let fetch_text url =
  let open Fut.Result_syntax in
  let* response = Fetch.url (Jstr.v url) in
  Fetch.Body.text (Fetch.Response.as_body response)
;;

let fetch ~id : unit =
  Bonsai.Expert.Var.set
    Multimodal_detail_var.selected_id_var (Some id);
  Bonsai.Expert.Var.set Multimodal_detail_var.detail_var None;
  Bonsai.Expert.Var.set Multimodal_detail_var.provenance_var None;
  Fut.await (fetch_text (detail_endpoint id)) (function
    | Ok text ->
      Bonsai.Expert.Var.set
        Multimodal_detail_var.detail_var
        (parse_detail text)
    | Error _ -> ());
  Fut.await (fetch_text (provenance_endpoint id)) (function
    | Ok text ->
      Bonsai.Expert.Var.set
        Multimodal_detail_var.provenance_var
        (parse_provenance text)
    | Error _ -> ())
;;

let clear () : unit =
  Bonsai.Expert.Var.set Multimodal_detail_var.selected_id_var None;
  Bonsai.Expert.Var.set Multimodal_detail_var.detail_var None;
  Bonsai.Expert.Var.set Multimodal_detail_var.provenance_var None
;;
