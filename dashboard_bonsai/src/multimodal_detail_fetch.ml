(** Tier F2-ux — single-shot fetch of artifact detail + provenance
    with explicit Loading/Loaded/NotFound/Error state transitions.

    Triggered by [Multimodal_view] card on_click; not polling. On
    each [fetch], both detail/provenance vars start at [Loading].
    Each parallel fetch independently transitions to [Loaded x],
    [NotFound] (server error envelope), or [Error msg] (network /
    parse failure).

    The two responses are independent — operator can see detail
    arrive while provenance is still loading or vice versa. *)

open! Core
open Brr_io

module T = Multimodal_detail_types

let detail_endpoint id = Printf.sprintf "/api/v1/multimodal/get/%s" id
let provenance_endpoint id =
  Printf.sprintf "/api/v1/multimodal/provenance/%s" id
;;

(** Parse one fetch body into a [_ fetch_state]. The deserializer
    [decode] is applied only when the body classifies as [Ok_json];
    error envelopes become [NotFound] (most common reason: id not
    resolvable on the server) and JSON-parse failures become
    [Error]. *)
let body_to_state
    (decode : Yojson.Safe.t -> 'a)
    (text : Jstr.t)
    : 'a T.fetch_state
  =
  match Yojson.Safe.from_string (Jstr.to_string text) with
  | json ->
    (match T.classify_json json with
     | T.Ok_json j -> T.Loaded (decode j)
     | T.Error_envelope_msg _ -> T.NotFound)
  | exception _ -> T.Error "invalid JSON response"
;;

let fetch_text url =
  let open Fut.Result_syntax in
  let* response = Fetch.url (Jstr.v url) in
  Fetch.Body.text (Fetch.Response.as_body response)
;;

let fetch ~id : unit =
  Bonsai.Expert.Var.set
    Multimodal_detail_var.selected_id_var (Some id);
  Bonsai.Expert.Var.set Multimodal_detail_var.detail_var T.Loading;
  Bonsai.Expert.Var.set Multimodal_detail_var.provenance_var T.Loading;
  Fut.await (fetch_text (detail_endpoint id)) (fun result ->
      let st =
        match result with
        | Ok text -> body_to_state T.detail_of_yojson text
        | Error _ -> T.Error "fetch failed"
      in
      Bonsai.Expert.Var.set Multimodal_detail_var.detail_var st);
  Fut.await (fetch_text (provenance_endpoint id)) (fun result ->
      let st =
        match result with
        | Ok text -> body_to_state T.provenance_of_yojson text
        | Error _ -> T.Error "fetch failed"
      in
      Bonsai.Expert.Var.set Multimodal_detail_var.provenance_var st)
;;

let clear () : unit =
  Bonsai.Expert.Var.set Multimodal_detail_var.selected_id_var None;
  Bonsai.Expert.Var.set Multimodal_detail_var.detail_var T.Idle;
  Bonsai.Expert.Var.set Multimodal_detail_var.provenance_var T.Idle
;;
