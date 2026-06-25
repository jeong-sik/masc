(* Keeper_vision_ingest tests — RFC-keeper-vision-delegation-tool §2.3 site-1
   transform contract. Locks: Delegate-path Image -> Text placeholder (carrying
   the store handle); fail-open (store error / bad base64 -> image kept inline);
   non-image pass-through; should_delegate gating. The store fn is injected, so
   no filesystem I/O. *)

module I = Masc.Keeper_vision_ingest
module P = Masc.Keeper_multimodal_policy

let ok_store bytes = Ok (Printf.sprintf "H_%d" (String.length bytes))
let fail_store _ = Error "store boom"

let img ~data =
  Agent_sdk.Types.image_block ~source_type:"base64" ~media_type:"image/png" ~data ()

let placeholder handle =
  Printf.sprintf
    "[image artifact:%s — call analyze_image with this artifact to read it]"
    handle

(* Delegate image, valid base64 -> Text placeholder with the store handle.
   handle = ok_store(decode(b64 of "rawbytes")) = ok_store("rawbytes") = "H_8". *)
let test_delegate_image_to_placeholder () =
  let raw = "rawbytes" in
  let b64 = Base64.encode_string raw in
  match I.intercept_image_blocks ~store:ok_store [ img ~data:b64 ] with
  | [ Agent_sdk.Types.Text s ] ->
    assert (String.equal s (placeholder "H_8"))
  | _ -> assert false

(* text + image: text passes through, image becomes a placeholder. *)
let test_mixed_blocks () =
  let b64 = Base64.encode_string "x" in
  match
    I.intercept_image_blocks ~store:ok_store
      [ Agent_sdk.Types.text_block "hi"; img ~data:b64 ]
  with
  | [ Agent_sdk.Types.Text "hi"; Agent_sdk.Types.Text _ ] -> ()
  | _ -> assert false

(* store error -> image kept inline (fail-open). *)
let test_store_error_keeps_image () =
  let b64 = Base64.encode_string "x" in
  match I.intercept_image_blocks ~store:fail_store [ img ~data:b64 ] with
  | [ Agent_sdk.Types.Image _ ] -> ()
  | _ -> assert false

(* invalid base64 -> image kept inline (fail-open). *)
let test_bad_base64_keeps_image () =
  match I.intercept_image_blocks ~store:ok_store [ img ~data:"@@ not base64 @@" ] with
  | [ Agent_sdk.Types.Image _ ] -> ()
  | _ -> assert false

(* should_delegate gating: only Delegate; Reroute/Inherit/None -> false. *)
let test_should_delegate () =
  assert (I.should_delegate (Some P.Delegate) = true);
  assert (I.should_delegate (Some P.Reroute) = false);
  assert (I.should_delegate (Some P.Inherit) = false);
  assert (I.should_delegate None = false)

(* multimodal_policy parse/default contract (no Unknown collapse). *)
let test_policy_of_string () =
  assert (P.of_string "delegate" = Some P.Delegate);
  assert (P.of_string "  REROUTE " = Some P.Reroute);
  assert (P.of_string "inherit" = Some P.Inherit);
  assert (P.of_string "nonsense" = None);
  assert (P.of_string "" = None);
  assert (String.equal (P.to_string P.Delegate) "delegate");
  assert (P.default = P.Reroute)

let () =
  test_policy_of_string ();
  test_delegate_image_to_placeholder ();
  test_mixed_blocks ();
  test_store_error_keeps_image ();
  test_bad_base64_keeps_image ();
  test_should_delegate ();
  print_endline "test_keeper_vision_ingest: all assertions passed"
