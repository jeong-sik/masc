(* Tier K1 — Multimodal.Workspace_holder unit tests. *)

module H = Multimodal.Workspace_holder
module W = Multimodal.Workspace
module A = Multimodal.Artifact

let make_artifact ~id_str ~kind ~now : A.any =
  match Shared_types.Artifact_id.of_string id_str with
  | Ok id ->
      let provenance =
        {
          A.origin_artifact_ids = [];
          created_by = "test";
          created_at = now;
        }
      in
      let artifact =
        {
          A.id;
          kind;
          payload = Multimodal.Payload.Lazy_payload (fun () -> "");
          metadata = `Null;
          provenance;
        }
      in
      A.Any artifact
  | Error msg ->
      failwith ("test fixture id parse failed: " ^ msg)

let test_initial_empty () =
  H.For_testing.reset ();
  let ws = H.get () in
  assert (W.size ws = 0);
  print_endline "  initial_empty: OK"

let test_replace () =
  H.For_testing.reset ();
  let ws = W.empty in
  let a =
    make_artifact
      ~id_str:"01900000-0000-7000-8000-000000000001"
      ~kind:A.Code ~now:1.0
  in
  let ws = W.add ws a in
  H.For_testing.replace ws;
  let snap = H.get () in
  assert (W.size snap = 1);
  print_endline "  replace: OK"

let test_update_atomic () =
  H.For_testing.reset ();
  let a =
    make_artifact
      ~id_str:"01900000-0000-7000-8000-000000000002"
      ~kind:A.Image ~now:2.0
  in
  H.update (fun ws -> W.add ws a, ());
  let snap = H.get () in
  assert (W.size snap = 1);
  print_endline "  update_atomic: OK"

let test_update_propagates_exception () =
  H.For_testing.reset ();
  let a =
    make_artifact
      ~id_str:"01900000-0000-7000-8000-000000000003"
      ~kind:A.Doc ~now:3.0
  in
  H.update (fun ws -> W.add ws a, ());
  let raised =
    match H.update (fun _ -> failwith "boom") with
    | exception Failure _ -> true
    | _ -> false
  in
  assert raised;
  let snap = H.get () in
  assert (W.size snap = 1);
  print_endline "  update_exception_keeps_state: OK"

let test_reset () =
  H.For_testing.reset ();
  let a =
    make_artifact
      ~id_str:"01900000-0000-7000-8000-000000000004"
      ~kind:A.Audio ~now:4.0
  in
  H.update (fun ws -> W.add ws a, ());
  assert (W.size (H.get ()) = 1);
  H.For_testing.reset ();
  assert (W.size (H.get ()) = 0);
  print_endline "  reset: OK"

let test_cross_domain_updates_are_lossless () =
  H.For_testing.reset ();
  let domain_count = 8 in
  let workers =
    List.init domain_count (fun index ->
      let artifact =
        make_artifact
          ~id_str:
            (Printf.sprintf
               "01900000-0000-7000-8000-%012d"
               (index + 10))
          ~kind:A.Code
          ~now:(Float.of_int index)
      in
      Domain.spawn (fun () ->
        H.update (fun workspace -> W.add workspace artifact, ())))
  in
  List.iter Domain.join workers;
  assert (W.size (H.get ()) = domain_count);
  H.For_testing.reset ();
  print_endline "  cross_domain_updates_are_lossless: OK"

let () =
  print_endline "=== Workspace_holder ===";
  test_initial_empty ();
  test_replace ();
  test_update_atomic ();
  test_update_propagates_exception ();
  test_reset ();
  test_cross_domain_updates_are_lossless ();
  print_endline "=== Workspace_holder: 6/6 OK ==="
