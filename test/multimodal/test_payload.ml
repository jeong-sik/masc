(* Cycle 24 / Tier B8 — Multimodal.Payload JSON round-trip tests.

   Pins the explicit lossy contract documented in payload.mli:

   - [Lazy_payload _] serialises to [{"kind":"lazy"}] and the
     closure is *intentionally* dropped on round-trip; [of_json]
     reconstructs a stub closure that returns "".  This is not
     a bug — payload.mli §40 calls it out explicitly.
   - [Blob_ref s] round-trips the string verbatim.
   - [Streaming n] round-trips the byte counter verbatim.
   - Garbage / missing-field JSON returns [Error _]. *)

module P = Multimodal.Payload

(* ─── to_json shape ───────────────────────────────────────────── *)

let test_to_json_lazy_drops_closure () =
  let p = P.Lazy_payload (fun () -> "secret payload") in
  let j = P.to_json p in
  let kind =
    Yojson.Safe.Util.member "kind" j |> Yojson.Safe.Util.to_string
  in
  assert (kind = "lazy");
  (* The "secret payload" string must NOT appear anywhere in the
     serialised JSON — closures are intentionally dropped. *)
  let serialised = Yojson.Safe.to_string j in
  assert (
    not (Astring.String.is_infix ~affix:"secret payload" serialised))

let test_to_json_blob_ref () =
  let p = P.Blob_ref "blob://store/abc123" in
  let j = P.to_json p in
  let kind =
    Yojson.Safe.Util.member "kind" j |> Yojson.Safe.Util.to_string
  in
  let r =
    Yojson.Safe.Util.member "ref" j |> Yojson.Safe.Util.to_string
  in
  assert (kind = "blob_ref");
  assert (r = "blob://store/abc123")

let test_to_json_streaming () =
  let p = P.Streaming 4096 in
  let j = P.to_json p in
  let kind =
    Yojson.Safe.Util.member "kind" j |> Yojson.Safe.Util.to_string
  in
  let n =
    Yojson.Safe.Util.member "bytes" j |> Yojson.Safe.Util.to_int
  in
  assert (kind = "streaming");
  assert (n = 4096)

(* ─── of_json ─────────────────────────────────────────────────── *)

let test_of_json_lazy_returns_empty_closure () =
  let j = `Assoc [ ("kind", `String "lazy") ] in
  match P.of_json j with
  | Ok (P.Lazy_payload f) ->
      (* mli §40: the reconstructed closure always returns "". *)
      assert (f () = "")
  | Ok _ -> assert false
  | Error e ->
      Printf.eprintf "unexpected error: %s\n" e;
      assert false

let test_of_json_blob_ref () =
  let j =
    `Assoc
      [ ("kind", `String "blob_ref"); ("ref", `String "blob://x/1") ]
  in
  match P.of_json j with
  | Ok (P.Blob_ref s) -> assert (s = "blob://x/1")
  | Ok _ -> assert false
  | Error _ -> assert false

let test_of_json_streaming () =
  let j =
    `Assoc [ ("kind", `String "streaming"); ("bytes", `Int 8192) ]
  in
  match P.of_json j with
  | Ok (P.Streaming n) -> assert (n = 8192)
  | Ok _ -> assert false
  | Error _ -> assert false

(* ─── Round-trip for non-lazy variants ────────────────────────── *)

let test_round_trip_blob_ref () =
  let original = P.Blob_ref "blob://round/trip" in
  let restored = P.of_json (P.to_json original) in
  match restored with
  | Ok (P.Blob_ref s) -> assert (s = "blob://round/trip")
  | _ -> assert false

let test_round_trip_streaming () =
  let original = P.Streaming 1234 in
  let restored = P.of_json (P.to_json original) in
  match restored with
  | Ok (P.Streaming n) -> assert (n = 1234)
  | _ -> assert false

(* ─── Error paths ─────────────────────────────────────────────── *)

let test_of_json_unknown_kind () =
  let j = `Assoc [ ("kind", `String "unknown_variant") ] in
  match P.of_json j with
  | Error _ -> ()  (* expected *)
  | Ok _ -> assert false

let test_of_json_missing_kind () =
  let j = `Assoc [ ("ref", `String "x") ] in
  match P.of_json j with
  | Error _ -> ()
  | Ok _ -> assert false

let test_of_json_blob_ref_missing_ref () =
  let j = `Assoc [ ("kind", `String "blob_ref") ] in
  match P.of_json j with
  | Error _ -> ()
  | Ok _ -> assert false

let test_of_json_not_object () =
  let j = `String "scalar" in
  match P.of_json j with
  | Error _ -> ()
  | Ok _ -> assert false

(* ─── runner ──────────────────────────────────────────────────── *)

let () =
  test_to_json_lazy_drops_closure ();
  test_to_json_blob_ref ();
  test_to_json_streaming ();
  test_of_json_lazy_returns_empty_closure ();
  test_of_json_blob_ref ();
  test_of_json_streaming ();
  test_round_trip_blob_ref ();
  test_round_trip_streaming ();
  test_of_json_unknown_kind ();
  test_of_json_missing_kind ();
  test_of_json_blob_ref_missing_ref ();
  test_of_json_not_object ();
  print_endline "test_payload: all assertions passed"
