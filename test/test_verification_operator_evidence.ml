(* The operator projection of submitted evidence: what an image artifact looks
   like on the wire, and that nothing else about the evidence changes. *)

module Store = Workspace_verification_store
module Operator = Workspace_verification_operator_evidence

let ceiling = Store.verification_evidence_max_bytes
let budget = Tool_shard_limits.verification_operator_preview_budget_bytes

let with_base_path_env f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = Filename.temp_dir "operator_evidence_test" "" in
  Fun.protect
    ~finally:(fun () ->
      Fs_compat.clear_fs ();
      Masc_test_deps.cleanup_test_workspace dir)
    (fun () -> f env dir)

let with_base_path f = with_base_path_env (fun _env base -> f base)

let png_signature = "\x89PNG\r\n\x1a\n"

(* PNG-signed bytes of an exact length. The projection does not decode the
   picture, so the signature and the length are what the fixture must get
   right. *)
let png_of_length length = png_signature ^ String.make (length - String.length png_signature) 'p'

let sha256_of data = Agent_core_sha256.(digest_string data |> to_hex)

(* A binary item as the capture path files it, so the body is read back from
   disk rather than assumed. *)
let filed_binary ~base_path ~request_id ~index ~format data =
  let body = Store.persist_binary_body ~base_path ~request_id ~index data in
  Store.Evidence_artifact_binary
    { reference = Printf.sprintf "artifact:shot-%d.%s" index format
    ; bytes = String.length data
    ; sha256 = sha256_of data
    ; format
    ; body
    }

let preview_testable =
  let pp formatter = function
    | Operator.Inline { body_base64 } ->
      Format.fprintf formatter "Inline(%d chars)" (String.length body_base64)
    | Operator.Withheld Operator.Not_image_format -> Format.pp_print_string formatter "Not_image_format"
    | Operator.Withheld Operator.Body_not_filed -> Format.pp_print_string formatter "Body_not_filed"
    | Operator.Withheld Operator.Body_unreadable -> Format.pp_print_string formatter "Body_unreadable"
    | Operator.Withheld (Operator.Body_identity_mismatch _) ->
      Format.pp_print_string formatter "Body_identity_mismatch"
    | Operator.Withheld (Operator.Over_delivery_ceiling { bytes; ceiling }) ->
      Format.fprintf formatter "Over_delivery_ceiling(%d, %d)" bytes ceiling
    | Operator.Withheld Operator.Over_response_budget ->
      Format.pp_print_string formatter "Over_response_budget"
  in
  Alcotest.testable pp ( = )

let previews_of ~base_path items =
  Operator.previews ~base_path items |> List.map (function
    | Some preview -> preview
    | None -> Alcotest.fail "a binary item carried no preview")

let test_an_image_under_the_ceiling_is_inline () =
  with_base_path (fun base_path ->
    let data = png_of_length 1000 in
    let item = filed_binary ~base_path ~request_id:"vr-a" ~index:0 ~format:"png" data in
    Alcotest.(check (list preview_testable))
      "inline with the bytes themselves"
      [ Operator.Inline { body_base64 = Base64.encode_string data } ]
      (previews_of ~base_path [ item ]))

let test_the_ceiling_is_inclusive_and_one_more_byte_is_withheld () =
  with_base_path (fun base_path ->
    let at = png_of_length ceiling in
    let over = png_of_length (ceiling + 1) in
    let items =
      [ filed_binary ~base_path ~request_id:"vr-b" ~index:0 ~format:"png" at
      ; filed_binary ~base_path ~request_id:"vr-b" ~index:1 ~format:"png" over
      ]
    in
    Alcotest.(check (list preview_testable))
      "an image of exactly the ceiling is sent, one byte more is named"
      [ Operator.Inline { body_base64 = Base64.encode_string at }
      ; Operator.Withheld (Operator.Over_delivery_ceiling { bytes = ceiling + 1; ceiling })
      ]
      (previews_of ~base_path items))

let test_a_missing_or_unfiled_body_is_named () =
  with_base_path (fun base_path ->
    let data = png_of_length 100 in
    let unfiled =
      Store.Evidence_artifact_binary
        { reference = "artifact:a.png"; bytes = 100; sha256 = sha256_of data
        ; format = "png"; body = None }
    in
    let vanished =
      Store.Evidence_artifact_binary
        { reference = "artifact:b.png"; bytes = 100; sha256 = sha256_of data
        ; format = "png"; body = Some "evidence/vr-c/9.bin" }
    in
    Alcotest.(check (list preview_testable))
      "each missing body has its own cause"
      [ Operator.Withheld Operator.Body_not_filed
      ; Operator.Withheld Operator.Body_unreadable
      ]
      (previews_of ~base_path [ unfiled; vanished ]))

let test_a_body_path_outside_the_evidence_directory_is_not_read () =
  with_base_path (fun base_path ->
    (* A real file next to the evidence directory and one at an absolute path:
       the paths that would reach them are refused, and the bytes never reach
       the response. *)
    let masc_dir = Common.masc_dir_from_base_path ~base_path in
    let data = png_of_length 100 in
    Fs_compat.mkdir_p masc_dir;
    Fs_compat.save_file (Filename.concat masc_dir "secret.bin") data;
    let outside = Filename.concat base_path "outside.bin" in
    Fs_compat.save_file outside data;
    let with_body body =
      Store.Evidence_artifact_binary
        { reference = "artifact:p.png"; bytes = 100; sha256 = sha256_of data
        ; format = "png"; body = Some body }
    in
    let refused =
      [ "evidence/../secret.bin"; "evidence/vr-e/../../secret.bin"; outside
      ; "secret.bin"; "evidence/vr-e/0.png"; "evidence//0.bin"; "evidence/vr-e/0.bin/x" ]
    in
    Alcotest.(check (list preview_testable))
      "every path that is not evidence/<request>/<n>.bin is unreadable"
      (List.map (fun _ -> Operator.Withheld Operator.Body_unreadable) refused)
      (previews_of ~base_path (List.map with_body refused)))

let test_formats_that_never_show_are_not_read () =
  with_base_path (fun base_path ->
    (* The body is never filed: a format that cannot show must be decided
       before any read, so it is [Not_image_format] and not a missing body. *)
    let pdf =
      Store.Evidence_artifact_binary
        { reference = "artifact:r.pdf"; bytes = 5; sha256 = "x"; format = "pdf"; body = None }
    in
    let bare =
      Store.Evidence_artifact_binary
        { reference = "artifact:r"; bytes = 5; sha256 = "x"; format = "unknown"; body = None }
    in
    Alcotest.(check (list preview_testable))
      "only the four image formats are candidates"
      [ Operator.Withheld Operator.Not_image_format
      ; Operator.Withheld Operator.Not_image_format
      ]
      (previews_of ~base_path [ pdf; bare ]))

let test_the_response_budget_is_spent_in_item_order_and_counts_exact_bytes () =
  with_base_path (fun base_path ->
    let images = budget / ceiling in
    let full index =
      filed_binary ~base_path ~request_id:"vr-d" ~index ~format:"png" (png_of_length ceiling)
    in
    let items = List.init (images + 1) full in
    let verdicts = previews_of ~base_path items in
    let inline = function Operator.Inline _ -> true | Operator.Withheld _ -> false in
    Alcotest.(check (list bool))
      "the budget admits exactly its images and then withholds"
      (List.init (images + 1) (fun index -> index < images))
      (List.map inline verdicts);
    Alcotest.(check preview_testable) "the first image past the budget is named"
      (Operator.Withheld Operator.Over_response_budget)
      (List.nth verdicts images))

let test_a_withheld_image_does_not_spend_the_budget () =
  with_base_path (fun base_path ->
    let images = budget / ceiling in
    let full index =
      filed_binary ~base_path ~request_id:"vr-e" ~index ~format:"png" (png_of_length ceiling)
    in
    let too_big =
      filed_binary ~base_path ~request_id:"vr-e" ~index:100 ~format:"png"
        (png_of_length (ceiling + 1))
    in
    let items = (too_big :: List.init images full) in
    let inline = function Operator.Inline _ -> true | Operator.Withheld _ -> false in
    Alcotest.(check (list bool)) "an oversize image ahead of them costs the rest nothing"
      (false :: List.init images (fun _ -> true))
      (List.map inline (previews_of ~base_path items)))

let test_other_kinds_have_no_preview_and_json_is_the_persisted_json () =
  with_base_path (fun base_path ->
    let binary =
      filed_binary ~base_path ~request_id:"vr-f" ~index:0 ~format:"png" (png_of_length 64)
    in
    let others =
      [ Store.Evidence_note "tests green"
      ; Store.Evidence_artifact
          { reference = "artifact:p.json"; content = "{}"; bytes = 2; truncated = false }
      ; Store.Evidence_invalid_reference
      ; Store.Evidence_artifact_unreadable
          { reference = "artifact:gone"; reason = Store.Evidence_missing }
      ; Store.Evidence_collaboration
          { reference = "board:p1"; content = "{}"; sha256 = sha256_of "{}" }
      ]
    in
    let items = binary :: others in
    Alcotest.(check (list bool)) "only the binary item has a preview"
      [ true; false; false; false; false; false ]
      (List.map Option.is_some (Operator.previews ~base_path items));
    let request : Store.request_header =
      { id = "vr-f"; task_id = "task-1"; worker = "w"; created_at = 1.0 }
    in
    let access = Store.Evidence_available { request; items } in
    let operator = Operator.access_to_yojson ~base_path access in
    let persisted = Store.submitted_evidence_access_to_yojson access in
    let items_of json = Yojson.Safe.Util.(json |> member "items" |> to_list) in
    let without_preview = function
      | `Assoc fields -> `Assoc (List.remove_assoc "preview" fields)
      | other -> other
    in
    Alcotest.(check (list string)) "every item is the persisted item once its preview is removed"
      (List.map Yojson.Safe.to_string (items_of persisted))
      (List.map (fun item -> Yojson.Safe.to_string (without_preview item)) (items_of operator));
    List.iter2
      (fun persisted_item operator_item ->
         match persisted_item with
         | `Assoc fields when List.assoc_opt "kind" fields <> Some (`String "artifact_binary") ->
           Alcotest.(check string) "a non-binary item is untouched"
             (Yojson.Safe.to_string persisted_item) (Yojson.Safe.to_string operator_item)
         | _ -> ())
      (items_of persisted) (items_of operator);
    Alcotest.(check string) "the request header is the persisted one"
      (Yojson.Safe.to_string Yojson.Safe.Util.(persisted |> member "request"))
      (Yojson.Safe.to_string Yojson.Safe.Util.(operator |> member "request")))

let test_an_unavailable_access_is_the_persisted_json () =
  with_base_path (fun base_path ->
    let access =
      Store.Evidence_unavailable { request_id = "vr-g"; reason = Store.Request_not_found }
    in
    Alcotest.(check string) "no items, no preview"
      (Yojson.Safe.to_string (Store.submitted_evidence_access_to_yojson access))
      (Yojson.Safe.to_string (Operator.access_to_yojson ~base_path access)))

(* The route's JSON must be what the TUI decodes: same bytes, same media type
   read from the bytes, withheld causes with their numbers. *)
let test_changed_bytes_are_withheld_and_the_tui_retains_the_identity_mismatch () =
  with_base_path (fun base_path ->
    let original = png_of_length 100 in
    let replacement = png_signature ^ String.make (100 - String.length png_signature) 'q' in
    let item = filed_binary ~base_path ~request_id:"vr-changed" ~index:0 ~format:"png" original in
    let path = Filename.concat (Common.masc_dir_from_base_path ~base_path) "evidence/vr-changed/0.bin" in
    Fs_compat.save_file path replacement;
    let mismatch : Store.binary_body_identity_mismatch =
      { expected_bytes = 100; actual_bytes = 100
      ; expected_sha256 = sha256_of original; actual_sha256 = sha256_of replacement } in
    Alcotest.(check (list preview_testable)) "the server withholds the changed body"
      [ Operator.Withheld (Operator.Body_identity_mismatch mismatch) ]
      (previews_of ~base_path [ item ]);
    let request : Store.request_header =
      { id = "vr-changed"; task_id = "task-1"; worker = "w"; created_at = 1.0 } in
    let wire = `Assoc [ "result", `Assoc [ "evidence",
      Operator.access_to_yojson ~base_path (Store.Evidence_available { request; items = [item] }) ] ] in
    match Masc.Tui_decode.decode_verification_evidence wire with
    | Ok (Masc.Tui_decode.Evidence_items
        [ Masc.Tui_decode.Ev_binary
            { ev_b_preview = Masc.Tui_decode.Preview_withheld
                (Masc.Tui_decode.Withheld_body_identity_mismatch
                  { expected_bytes; actual_bytes; expected_sha256; actual_sha256 }); _ } ]) ->
      Alcotest.(check (pair int int)) "the decoder retains both sizes" (100, 100)
        (expected_bytes, actual_bytes);
      Alcotest.(check (pair string string)) "the decoder retains both digests"
        (mismatch.expected_sha256, mismatch.actual_sha256) (expected_sha256, actual_sha256)
    | Ok _ -> Alcotest.fail "the mismatch must remain withheld on the wire"
    | Error detail -> Alcotest.fail detail)

let test_the_tui_decodes_what_the_server_writes () =
  with_base_path (fun base_path ->
    let data = png_of_length 300 in
    let items =
      [ filed_binary ~base_path ~request_id:"vr-h" ~index:0 ~format:"png" data
      ; filed_binary ~base_path ~request_id:"vr-h" ~index:1 ~format:"png" (png_of_length (ceiling + 1))
      ; Store.Evidence_artifact_binary
          { reference = "artifact:r.pdf"; bytes = 5; sha256 = "x"; format = "pdf"; body = None }
      ]
    in
    let request : Store.request_header =
      { id = "vr-h"; task_id = "task-1"; worker = "w"; created_at = 1.0 }
    in
    let wire =
      `Assoc
        [ "result"
        , `Assoc
            [ "evidence"
            , Operator.access_to_yojson ~base_path (Store.Evidence_available { request; items }) ] ]
    in
    match Masc.Tui_decode.decode_verification_evidence wire with
    | Ok
        (Masc.Tui_decode.Evidence_items
          [ Masc.Tui_decode.Ev_binary { ev_b_preview = Masc.Tui_decode.Preview_image { ev_media; ev_data }; _ }
          ; Masc.Tui_decode.Ev_binary
              { ev_b_preview =
                  Masc.Tui_decode.Preview_withheld
                    (Masc.Tui_decode.Withheld_over_delivery_ceiling { bytes; ceiling = wire_ceiling })
              ; _ }
          ; Masc.Tui_decode.Ev_binary
              { ev_b_preview = Masc.Tui_decode.Preview_withheld Masc.Tui_decode.Withheld_not_image_format; _ }
          ]) ->
      Alcotest.(check string) "same bytes" data ev_data;
      Alcotest.(check string) "media type read from the bytes" "image/png"
        (Masc.Keeper_vision_downscale.media_type_to_string ev_media);
      Alcotest.(check int) "over-ceiling size" (ceiling + 1) bytes;
      Alcotest.(check int) "over-ceiling limit" ceiling wire_ceiling
    | Ok _ -> Alcotest.fail "the TUI decoded the items into other shapes"
    | Error detail -> Alcotest.fail detail)

let access items = Store.Evidence_available {
  request={id="vr-download";task_id="task-download";worker="producer";created_at=1.};items}

let test_download_preserves_original_bytes () =
  with_base_path (fun base_path ->
    let pdf = "%PDF-1.7\n\000original binary\255" in
    let binary = filed_binary ~base_path ~request_id:"vr-download" ~index:1 ~format:"pdf" pdf in
    let text = "한글\r\nsecond line\r\n" in
    let items = [Store.Evidence_artifact {reference="artifact:report.txt";
      content=text;bytes=String.length text;truncated=false};binary] in
    List.iteri (fun index expected ->
      match Operator.file_to_yojson ~base_path ~index (access items) with
      | Error detail -> Alcotest.fail detail
      | Ok result ->
        let wire=`Assoc ["ok",`Bool true;"result",result] in
        match Masc_tui_evidence_file.decode ~task_id:"task-download" ~verification_id:"vr-download" ~index wire with
        | Error detail -> Alcotest.fail detail
        | Ok file ->
          ignore file;
          let encoded=Yojson.Safe.Util.(member "body_base64" result |> to_string) in
          Alcotest.(check string) "original bytes" expected (Base64.decode_exn encoded))
      [text;pdf])

let test_download_saves_a_private_local_copy () =
  Eio_main.run (fun env ->
    let directory=Filename.temp_dir "masc-evidence-save-test" "" in
    Fun.protect ~finally:(fun () -> Masc_test_deps.cleanup_test_workspace directory) (fun () ->
      let content="original\r\n한글\n" in
      let result=Operator.file_to_yojson ~base_path:directory ~index:0 (access [Store.Evidence_note content]) in
      let result=match result with Ok value -> value | Error detail -> Alcotest.fail detail in
      let file=match Masc_tui_evidence_file.decode ~task_id:"task-download" ~verification_id:"vr-download" ~index:0
        (`Assoc ["ok",`Bool true;"result",result]) with Ok file -> file | Error detail -> Alcotest.fail detail in
      match Masc_tui_evidence_file.export ~fs:env#fs ~registry_root:directory ~directory ~progress:(Atomic.make Masc_tui_evidence_file.Not_started)
        ~admitted:(fun () -> Ok ()) ~open_file:None file with
      | Error detail -> Alcotest.fail detail
      | Ok path ->
        Alcotest.(check bool) "absolute path" false (Filename.is_relative path);
        Alcotest.(check string) "saved bytes" content (Eio.Path.load Eio.Path.(env#fs / path));
        Alcotest.(check int) "private directory" 0o700 (Unix.stat (Filename.dirname path)).Unix.st_perm;
        Alcotest.(check int) "private file" 0o600 (Unix.stat path).Unix.st_perm))

let test_export_preserves_long_original_filename () =
  with_base_path_env (fun env base_path ->
    let name=String.make 240 'x' ^ ".txt" in
    let content="retained long-named artifact" in
    let item=Store.Evidence_artifact {reference="artifact:reports/" ^ name;
      content;bytes=String.length content;truncated=false} in
    let wire=match Operator.file_to_yojson ~base_path ~index:0 (access [item]) with
      | Ok result -> `Assoc ["ok",`Bool true;"result",result]
      | Error detail -> Alcotest.fail detail in
    let file=match Masc_tui_evidence_file.decode ~task_id:"task-download" ~verification_id:"vr-download" ~index:0 wire with
      | Ok file -> file | Error detail -> Alcotest.fail detail in
    match Masc_tui_evidence_file.export ~fs:env#fs ~registry_root:base_path ~directory:base_path
      ~progress:(Atomic.make Masc_tui_evidence_file.Not_started)
      ~admitted:(fun () -> Ok ()) ~open_file:None file with
    | Error detail -> Alcotest.fail detail
    | Ok path ->
      Alcotest.(check string) "original basename fits unchanged" name (Filename.basename path);
      Alcotest.(check string) "long-named file contains original bytes" content (Eio.Path.load Eio.Path.(env#fs / path)))

let test_download_refuses_missing_or_partial_items () =
  with_base_path (fun base_path ->
    let artifact content bytes truncated = Store.Evidence_artifact {
      reference="artifact:report.txt";content;bytes;truncated} in
    let items=[artifact "prefix" 100 true;artifact "prefix" 100 false;
      Store.Evidence_artifact_unreadable {reference="artifact:missing";reason=Store.Evidence_missing}] in
    List.iter (fun index ->
      match Operator.file_to_yojson ~base_path ~index (access items) with
      | Error _ -> () | Ok _ -> Alcotest.fail "incomplete evidence became a complete file") [-1;0;1;2;3])

let test_download_refuses_wrong_identity_and_corrupt_bytes () =
  with_base_path (fun base_path ->
    let result=match Operator.file_to_yojson ~base_path ~index:0 (access [Store.Evidence_note "exact note"]) with
      | Ok (`Assoc fields) -> fields | Ok _ -> Alcotest.fail "not an object" | Error detail -> Alcotest.fail detail in
    let refuse fields ~task_id ~verification_id ~index =
      let wire=`Assoc ["ok",`Bool true;"result",`Assoc fields] in
      match Masc_tui_evidence_file.decode ~task_id ~verification_id ~index wire with
      | Error _ -> () | Ok _ -> Alcotest.fail "wrong item or corrupt download accepted" in
    refuse result ~task_id:"another-task" ~verification_id:"vr-download" ~index:0;
    refuse result ~task_id:"task-download" ~verification_id:"another-request" ~index:0;
    refuse result ~task_id:"task-download" ~verification_id:"vr-download" ~index:1;
    List.iter (fun (key,value) ->
      refuse ((key,value)::List.remove_assoc key result)
        ~task_id:"task-download" ~verification_id:"vr-download" ~index:0)
      ["bytes",`Int 100;"sha256",`String (String.make 64 '0');"name",`String "../outside.txt";
       "body_base64",`String (Base64.encode_string "other note")])

let download_fixture ~base_path content =
  let wire=match Operator.file_to_yojson ~base_path ~index:0 (access [Store.Evidence_note content]) with
    | Ok result -> `Assoc ["ok",`Bool true;"result",result]
    | Error detail -> Alcotest.fail detail in
  match Masc_tui_evidence_file.decode ~task_id:"task-download" ~verification_id:"vr-download" ~index:0 wire with
  | Ok file -> file | Error detail -> Alcotest.fail detail

let test_export_preserves_destination_and_saved_effects () =
  with_base_path_env (fun env base ->
    let module File=Masc_tui_evidence_file in
    let content="selected original\r\n한글\n" in
    let file=download_fixture ~base_path:base content in
    let progress=Atomic.make File.Not_started in
    let calls=ref 0 in
    let result=File.export ~fs:env#fs ~registry_root:base ~directory:base ~progress ~admitted:(fun () -> Ok ())
      ~open_file:(Some (fun path ->
        incr calls;
        Alcotest.(check string) "viewer receives the actual downloaded file" content (Eio.Path.load Eio.Path.(env#fs / path));
        Error "no desktop viewer")) file in
    Alcotest.(check bool) "viewer failure is not success" true (Result.is_error result);
    Alcotest.(check int) "viewer is never replayed" 1 !calls;
    (match Atomic.get progress with
     | File.Saved path -> Alcotest.(check string) "confirmed copy survives viewer failure" content (Eio.Path.load Eio.Path.(env#fs / path))
     | File.Not_started | File.Writing _ | File.Aborted _ -> Alcotest.fail "saved path was lost");
    let denied=Atomic.make File.Not_started in
    let before=Array.length (Sys.readdir base) in
    ignore (File.export ~fs:env#fs ~registry_root:base ~directory:base ~progress:denied
      ~admitted:(fun () -> Error "workspace changed") ~open_file:None file);
    Alcotest.(check bool) "withdrawn admission never starts a write" true (Atomic.get denied=File.Not_started);
    Alcotest.(check int) "no file created on admission refusal" before (Array.length (Sys.readdir base));
    let failed=Atomic.make File.Not_started in
    let result=File.export ~fs:env#fs ~registry_root:base ~directory:(Filename.concat base "missing-directory")
      ~progress:failed ~admitted:(fun () -> Ok ()) ~open_file:None file in
    Alcotest.(check bool) "failed write is not saved" true (Result.is_error result);
    (match Atomic.get failed with
     | File.Aborted path -> Alcotest.(check bool) "failed destination is still known" false (Filename.is_relative path)
     | File.Writing _ -> Alcotest.fail "failed write still reports active progress"
     | File.Not_started | File.Saved _ -> Alcotest.fail "failed write lost or certified its destination"))

let test_export_lock_refusal_ends_progress () =
  with_base_path_env (fun env base ->
    let module File=Masc_tui_evidence_file in
    let lock_failure : File_lock_eio.durable_lock_error =
      { lock_path=Filename.concat base "tui-evidence-export.lock"
      ; phase=File_lock_eio.Acquire_process_lock
      ; cause={error=Unix.EAGAIN;operation="injected_lock_refusal";argument=base}
      ; cleanup_failure=None } in
    let progress=Atomic.make File.Not_started in
    let file=download_fixture ~base_path:base "unpublished lock refusal bytes" in
    let result=File.For_testing.export
      ~with_lock:(fun ~lock_path:_ _publish -> File_lock_eio.Lock_not_acquired lock_failure)
      ~fs:env#fs ~registry_root:base ~directory:base ~progress
      ~admitted:(fun () -> Ok ()) ~open_file:None file in
    Alcotest.(check bool) "lock refusal is not success" true (Result.is_error result);
    match Atomic.get progress with
    | File.Aborted path -> Alcotest.(check bool) "refused destination is still known" false (Filename.is_relative path)
    | File.Writing _ -> Alcotest.fail "refused lock still reports active progress"
    | File.Not_started | File.Saved _ -> Alcotest.fail "refused lock lost or certified its destination")

let test_export_exception_before_confirmation_ends_progress () =
  let exception Injected_publication_failure in
  with_base_path_env (fun env base ->
    let module File=Masc_tui_evidence_file in
    let progress=Atomic.make File.Not_started in
    let file=download_fixture ~base_path:base "exception before publication" in
    (match File.For_testing.export
      ~with_lock:(fun ~lock_path:_ _publish -> raise Injected_publication_failure)
      ~fs:env#fs ~registry_root:base ~directory:base ~progress
      ~admitted:(fun () -> Ok ()) ~open_file:None file with
     | _ -> Alcotest.fail "ordinary exception was swallowed"
     | exception Injected_publication_failure -> ());
    match Atomic.get progress with
    | File.Aborted path ->
      Alcotest.(check bool) "exception destination is still known" false (Filename.is_relative path)
    | File.Writing _ -> Alcotest.fail "ordinary exception still reports active progress"
    | File.Not_started | File.Saved _ -> Alcotest.fail "ordinary exception lost or certified its destination")

let test_export_rechecks_authority_and_propagates_cancellation () =
  with_base_path_env (fun env base ->
    let module File=Masc_tui_evidence_file in
    let file=download_fixture ~base_path:base "cancelled viewer retains downloaded bytes" in
    let progress=Atomic.make File.Not_started in
    let admissions=ref 0 and opened=ref false in
    let result=File.export ~fs:env#fs ~registry_root:base ~directory:base ~progress
      ~admitted:(fun () -> incr admissions; if !admissions=1 then Ok () else Error "workspace withdrawn after save")
      ~open_file:(Some (fun _ -> opened:=true;Ok ())) file in
    Alcotest.(check bool) "withdrawn opener refused" true (Result.is_error result);
    Alcotest.(check bool) "no viewer launched after authority withdrawal" false !opened;
    (match Atomic.get progress with File.Saved _ -> () | File.Not_started | File.Writing _ | File.Aborted _ -> Alcotest.fail "write receipt lost on later withdrawal");
    let cancelled=Atomic.make File.Not_started in
    (match File.export ~fs:env#fs ~registry_root:base ~directory:base ~progress:cancelled ~admitted:(fun () -> Ok ())
      ~open_file:(Some (fun _ -> raise (Eio.Cancel.Cancelled Exit))) file with
     | _ -> Alcotest.fail "cancellation was swallowed"
     | exception Eio.Cancel.Cancelled Exit -> ());
    match Atomic.get cancelled with
    | File.Saved path -> Alcotest.(check bool) "cancelled viewer retains confirmed local path" true (Sys.file_exists path)
    | File.Not_started | File.Writing _ | File.Aborted _ -> Alcotest.fail "cancelled viewer lost confirmed save")

let test_export_uses_local_registry_not_shared_temp () =
  with_base_path_env (fun env base ->
    let module File=Masc_tui_evidence_file in
    let module Recovery=Fs_compat.Publication_recovery in
    let first_export=Filename.concat base "shared-export-one" in
    let second_export=Filename.concat base "shared-export-two" in
    let registry_root=Filename.concat base "local-masc" in
    List.iter (fun directory -> Unix.mkdir directory 0o700)
      [first_export;second_export;registry_root];
    let collision=Filename.concat first_export "fs-publication-recovery" in
    Fs_compat.save_file collision "foreign recovery sentinel";
    let export_file directory content =
      let file=download_fixture ~base_path:base content in
      match File.export ~fs:env#fs ~registry_root ~directory
        ~progress:(Atomic.make File.Not_started) ~admitted:(fun () -> Ok ()) ~open_file:None file with
      | Error detail -> Alcotest.fail detail
      | Ok path ->
        Alcotest.(check string) "shared recovery collision cannot block the export"
          content (Eio.Path.load Eio.Path.(env#fs / path))
    in
    export_file first_export "first local registry export";
    export_file second_export "second local registry export";
    Alcotest.(check string) "foreign shared recovery entry is not replaced"
      "foreign recovery sentinel" (Eio.Path.load Eio.Path.(env#fs / collision));
    Eio.Switch.run @@ fun sw ->
    (match Recovery.open_registry ~sw ~fs:env#fs
      ~registry_root:Eio.Path.(env#fs / registry_root) with
     | Error error -> Alcotest.fail (Recovery.registry_error_to_string error)
     | Ok registry ->
       (match Recovery.discover_owners registry with
        | Error error -> Alcotest.fail (Recovery.discovery_error_to_string error)
        | Ok owners ->
          Alcotest.(check bool) "stable owner is registered under the local root" true
            (List.exists (function
              | Recovery.Discovered_owner owner ->
                Recovery.owner_to_string owner="tui-evidence-export"
              | Recovery.Invalid_owner_name _ -> false) owners))))

let test_export_serializes_owner_reconciliation_and_publication () =
  with_base_path_env (fun env base ->
    let module File=Masc_tui_evidence_file in
    let module Recovery=Fs_compat.Publication_recovery in
    let module Writer=Fs_compat_test_support.Capability_write_for_testing in
    let first_export=Filename.concat base "first-export" in
    let second_export=Filename.concat base "second-export" in
    let registry_root=Filename.concat base "local-masc" in
    List.iter (fun directory -> Unix.mkdir directory 0o700)
      [first_export;second_export;registry_root];
    let lock_path=Filename.concat registry_root "tui-evidence-export.lock" in
    let first_prepared,resolve_first_prepared=Eio.Promise.create () in
    let release_first,resolve_release_first=Eio.Promise.create () in
    let before_stage = function
      | Fs_compat.Create_staging_directory ->
        Eio.Promise.resolve resolve_first_prepared ();
        Eio.Promise.await release_first
      | _ -> () in
    let first_write () =
      let ( let* ) = Result.bind in
      Eio.Path.with_open_dir Eio.Path.(env#fs / first_export) (fun parent ->
        let root=Eio.Path.stat ~follow:true parent in
        let* target=Fs_compat.capability_publication_target
          ~allowed_root_path:first_export ~allowed_root_device:root.dev ~allowed_root_inode:root.ino
          ~parent_components:[] ~target_leaf:"first.txt" ~permissions:0o600
          |> Result.map_error Fs_compat.capability_publication_target_error_to_string in
        Eio.Switch.run @@ fun sw ->
        let* registry=Recovery.open_registry ~sw ~fs:env#fs
          ~registry_root:Eio.Path.(env#fs / registry_root)
          |> Result.map_error Recovery.registry_error_to_string in
        match Recovery.with_lane ~registry ~owner:"tui-evidence-export" (fun recovery ->
          Writer.create_capability_file_exclusive ~before_stage ~recovery ~parent ~target "first bytes"
          |> Result.map_error Fs_compat.capability_write_error_to_string) with
        | Error error -> Error (Recovery.lane_open_error_to_string error)
        | Ok (Recovery.Lane_released result) -> result
        | Ok (Recovery.Lane_release_failed {value;release_failure}) ->
          let detail=Recovery.lane_release_failure_to_string release_failure in
          Error (match value with Ok () -> detail | Error primary -> primary ^ "; " ^ detail)) in
    let first_writer () =
      match File_lock_eio.with_durable_lock_observed ~lock_path first_write with
      | File_lock_eio.Lock_not_acquired error ->
        Error (File_lock_eio.durable_lock_error_to_string error)
      | File_lock_eio.Body_completed {value;release_error=None} -> value
      | File_lock_eio.Body_completed {value;release_error=Some error} ->
        let detail=File_lock_eio.durable_lock_error_to_string error in
        Error (match value with Ok () -> detail | Error primary -> primary ^ "; " ^ detail) in
    Eio.Switch.run @@ fun sw ->
    let first_result,resolve_first_result=Eio.Promise.create () in
    Eio.Fiber.fork ~sw (fun () -> Eio.Promise.resolve resolve_first_result (first_writer ()));
    Eio.Promise.await first_prepared;
    let second_result,resolve_second_result=Eio.Promise.create () in
    Eio.Fiber.fork ~sw (fun () ->
      let file=download_fixture ~base_path:base "second bytes" in
      let result=File.export ~fs:env#fs ~registry_root ~directory:second_export
        ~progress:(Atomic.make File.Not_started) ~admitted:(fun () -> Ok ()) ~open_file:None file in
      Eio.Promise.resolve resolve_second_result result);
    let rec observe_second () =
      match Eio.Promise.peek second_result with
      | Some _ -> `Completed
      | None ->
        if File_lock_eio.For_testing.holders_and_waiters ~lock_path >= 2 then `Blocked
        else (Eio.Fiber.yield (); observe_second ()) in
    let second_state=observe_second () in
    Eio.Promise.resolve resolve_release_first ();
    let first=Eio.Promise.await first_result in
    let second=Eio.Promise.await second_result in
    Alcotest.(check bool) "the second export cannot reconcile the active first writer" true
      (second_state=`Blocked);
    (match first with Ok () -> () | Error detail -> Alcotest.fail detail);
    match second with
    | Error detail -> Alcotest.fail detail
    | Ok path -> Alcotest.(check string) "both exports retain their exact payload"
      "second bytes" (Eio.Path.load Eio.Path.(env#fs / path)))

let test_export_cancellation_after_lock_admission_is_not_success () =
  with_base_path_env (fun env base ->
    let module File=Masc_tui_evidence_file in
    let directory=Filename.concat base "cancel-export" in
    let registry_root=Filename.concat base "local-masc" in
    List.iter (fun path -> Unix.mkdir path 0o700) [directory;registry_root];
    let file=download_fixture ~base_path:base (String.make (4 * 1024 * 1024) 'x') in
    let progress=Atomic.make File.Not_started in
    let lock_acquired,resolve_lock_acquired=Eio.Promise.create () in
    let previous=Atomic.get File_lock_eio.on_lock_attempt_fn in
    Fun.protect ~finally:(fun () -> Atomic.set File_lock_eio.on_lock_attempt_fn previous) (fun () ->
      Atomic.set File_lock_eio.on_lock_attempt_fn (fun ~caller:_ ~retries:_ ~elapsed_s:_ ~outcome ->
        if outcome="acquired" then Eio.Promise.resolve resolve_lock_acquired ());
      Eio.Switch.run @@ fun sw ->
      let outcome,resolve_outcome=Eio.Promise.create () in
      let context,resolve_context=Eio.Promise.create () in
      Eio.Fiber.fork ~sw (fun () ->
        Eio.Cancel.sub (fun cancellation ->
          Eio.Promise.resolve resolve_context cancellation;
          match File.export ~fs:env#fs ~registry_root ~directory ~progress
            ~admitted:(fun () -> Ok ()) ~open_file:None file with
          | result -> Eio.Promise.resolve resolve_outcome (`Returned result)
          | exception Eio.Cancel.Cancelled Exit ->
            Eio.Promise.resolve resolve_outcome `Cancelled
          | exception exn -> Eio.Promise.resolve resolve_outcome (`Unexpected exn)));
      Eio.Promise.await lock_acquired;
      Eio.Fiber.yield ();
      (match Eio.Promise.peek outcome with
       | Some _ -> Alcotest.fail "export completed before lock-admitted cancellation"
       | None -> ());
      Eio.Cancel.cancel (Eio.Promise.await context) Exit;
      match Eio.Promise.await outcome with
      | `Cancelled ->
        (match Atomic.get progress with
         | File.Saved path ->
           Alcotest.(check int) "cancelled export retains the complete saved bytes"
             (4 * 1024 * 1024) (String.length (Eio.Path.load Eio.Path.(env#fs / path)))
         | File.Not_started | File.Writing _ | File.Aborted _ ->
           Alcotest.fail "cancelled export lost its confirmed save")
      | `Returned (Ok path) -> Alcotest.failf "lock-admitted cancellation returned success: %s" path
      | `Returned (Error detail) -> Alcotest.failf "lock-admitted cancellation returned an error: %s" detail
      | `Unexpected exn -> Alcotest.fail (Printexc.to_string exn)))

let test_export_lane_release_failure_preserves_saved () =
  with_base_path_env (fun env base ->
    let module File=Masc_tui_evidence_file in
    let module Recovery_test=Fs_compat_test_support.Publication_recovery_for_testing in
    let directory=Filename.concat base "lane-release-export" in
    let registry_root=Filename.concat base "local-masc" in
    List.iter (fun path -> Unix.mkdir path 0o700) [directory;registry_root];
    let fault=Recovery_test.lane_scope_release_fault ~owner:"tui-evidence-export"
      ~exception_:(Failure "injected lane release") |> Result.get_ok in
    let progress=Atomic.make File.Not_started in
    let file=download_fixture ~base_path:base "lane release bytes" in
    let result=Recovery_test.with_lane_scope_release_fault fault (fun () ->
      File.For_testing.export ~fs:env#fs ~registry_root ~directory ~progress
        ~admitted:(fun () -> Ok ()) ~open_file:None file) in
    (match Atomic.get progress with
     | File.Saved path ->
       Alcotest.(check string) "lane release failure retains complete bytes"
         "lane release bytes" (Eio.Path.load Eio.Path.(env#fs / path))
     | File.Not_started | File.Writing _ | File.Aborted _ ->
       Alcotest.fail "lane release failure lost confirmed save");
    match result with
    | Error _ -> ()
    | Ok path -> Alcotest.failf "lane release failure returned success: %s" path)

let test_export_lock_release_failure_preserves_saved () =
  with_base_path_env (fun env base ->
    let module File=Masc_tui_evidence_file in
    let directory=Filename.concat base "lock-release-export" in
    let registry_root=Filename.concat base "local-masc" in
    List.iter (fun path -> Unix.mkdir path 0o700) [directory;registry_root];
    let lock_path=Filename.concat registry_root "tui-evidence-export.lock" in
    let release_failure =
      { File_lock_eio.lock_path
      ; phase=File_lock_eio.Release_process_lock
      ; cause={File_lock_eio.error=Unix.EIO;operation="injected_release_after_body";argument=lock_path}
      ; cleanup_failure=None } in
    let with_lock ~lock_path publish =
      File_lock_eio.For_testing.with_durable_lock_observed_with_release_failure
        ~release_failure ~lock_path publish in
    let progress=Atomic.make File.Not_started in
    let file=download_fixture ~base_path:base "lock release bytes" in
    let result=File.For_testing.export ~with_lock ~fs:env#fs ~registry_root ~directory ~progress
      ~admitted:(fun () -> Ok ()) ~open_file:None file in
    (match Atomic.get progress with
     | File.Saved path ->
       Alcotest.(check string) "lock release failure retains complete bytes"
         "lock release bytes" (Eio.Path.load Eio.Path.(env#fs / path))
     | File.Not_started | File.Writing _ | File.Aborted _ ->
       Alcotest.fail "lock release failure lost confirmed save");
    match result with
    | Error _ -> ()
    | Ok path -> Alcotest.failf "lock release failure returned success: %s" path)

let http_get_evidence ~router ?token target =
  let output=Buffer.create 1024 in
  let connection=Httpun.Server_connection.create (fun reqd ->
    Masc.Http_server_eio.Router.dispatch router (Httpun.Reqd.request reqd) reqd) in
  let auth=match token with None -> "" | Some token -> "Authorization: Bearer " ^ token ^ "\r\n" in
  let wire="GET " ^ target ^ " HTTP/1.1\r\nHost: localhost\r\n" ^ auth ^ "\r\n" in
  let input=Bigstringaf.of_string ~off:0 ~len:(String.length wire) wire in
  ignore (Httpun.Server_connection.read_eof connection input ~off:0 ~len:(Bigstringaf.length input));
  let rec drain () = match Httpun.Server_connection.next_write_operation connection with
    | `Write iovecs ->
      let bytes=List.fold_left (fun count (iov:Bigstringaf.t Httpun.IOVec.t) ->
        Buffer.add_string output (Bigstringaf.substring iov.buffer ~off:iov.off ~len:iov.len);count+iov.len) 0 iovecs in
      Httpun.Server_connection.report_write_result connection (`Ok bytes);drain ()
    | `Yield | `Close _ -> () in
  drain ();
  let lines=String.split_on_char '\n' (Buffer.contents output) in
  let status=match lines with
    | first::_ -> (match String.split_on_char ' ' first with _::code::_ -> int_of_string code | _ -> Alcotest.fail "invalid HTTP status")
    | [] -> Alcotest.fail "missing HTTP status" in
  let rec body = function "\r"::rest -> String.concat "\n" rest | _::rest -> body rest | [] -> Alcotest.fail "missing HTTP body" in
  status,Yojson.Safe.from_string (body lines)

let test_actual_download_route_and_local_export () =
  let open Masc in
  with_base_path_env (fun env base ->
    ignore (Server_startup_state.mark_state_ready ());
    let state=Mcp_server.For_testing.create_state ~base_path:base in
    Auth.save_auth_config base {Masc_domain.default_auth_config with enabled=true;require_token=true};
    let token agent_name role = match Auth.create_token base ~agent_name ~role with
      | Ok (raw,_) -> raw | Error error -> Alcotest.fail (Masc_domain.masc_error_to_string error) in
    let admin=token "download-admin" Masc_domain.Admin and worker=token "download-worker" Masc_domain.Worker in
    let prior=Server_auth.For_testing.snapshot_server_state () in
    Fun.protect ~finally:(fun () -> Server_auth.For_testing.restore_server_state prior) (fun () ->
      Server_auth.publish_server_state state;
      let router=Server_routes_http_routes_verification.add_routes (Masc.Http_server_eio.Router.create ()) in
      let pdf="%PDF-1.7\n" ^ String.make ceiling 'p' in
      let binary=filed_binary ~base_path:base ~request_id:"vr-http-body" ~index:0 ~format:"pdf" pdf in
      let png=png_of_length (ceiling+1) in
      let image=filed_binary ~base_path:base ~request_id:"vr-http-body" ~index:1 ~format:"png" png in
      let output=`Assoc ["task_title",`String "download selected evidence";"required_artifacts",`List [];
        "submitted_evidence",`List (List.map Store.submitted_evidence_item_to_yojson [binary;image])] in
      let request=match Verification.create_request ~base_path:base ~task_id:"task-http-download" ~worker:"producer" ~output ~criteria:[] () with
        | Ok value -> value | Error detail -> Alcotest.fail detail in
      let target ?(task_id=request.task_id) ?(index="0") ?(expected_base=base) () =
        Uri.to_string (Uri.make ~path:"/api/v1/verification/evidence" ~query:[
          "task_id",[task_id];"verification_id",[request.id];"item_index",[index];
          "expected_base_path",[expected_base];"expected_masc_root",[Common.masc_dir_from_base_path ~base_path:base]] ()) in
      let get ?token target=http_get_evidence ~router ?token target in
      let denied status ?token target =
        let actual,body=get ?token target in
        Alcotest.(check int) "HTTP boundary refusal" status actual;
        Alcotest.(check bool) "no binary payload on refusal" false
          (match Yojson.Safe.Util.member "result" body with `Null -> false | _ -> true) in
      denied 401 (target ());
      denied 403 ~token:worker (target ());
      denied 409 ~token:admin (target ~expected_base:(Filename.concat base "another-workspace") ());
      denied 400 ~token:admin (target ~task_id:"another-task" ());
      denied 400 ~token:admin (target ~index:"-1" ());
      denied 400 ~token:admin (target ~index:"2" ());
      List.iteri (fun index (original,name) ->
        let status,wire=get ~token:admin (target ~index:(string_of_int index) ()) in
        Alcotest.(check int) "large retained file is downloadable" 200 status;
        let file=match Masc_tui_evidence_file.decode ~task_id:request.task_id ~verification_id:request.id ~index wire with
          | Ok file -> file | Error detail -> Alcotest.fail detail in
        let progress=Atomic.make Masc_tui_evidence_file.Not_started in
        match Masc_tui_evidence_file.export ~fs:env#fs ~registry_root:base ~directory:base ~progress
          ~admitted:(fun () -> Ok ()) ~open_file:None file with
        | Error detail -> Alcotest.fail detail
        | Ok path ->
          Alcotest.(check string) "real HTTP to local file preserves original binary" original (Eio.Path.load Eio.Path.(env#fs / path));
          Alcotest.(check bool) "original filename retained" true (String.ends_with ~suffix:name path))
        [pdf,"shot-0.pdf";png,"shot-1.png"];
      (match Operator.previews ~base_path:base [binary;image] with
      | [Some (Operator.Withheld Operator.Not_image_format);
         Some (Operator.Withheld (Operator.Over_delivery_ceiling _))] -> ()
      | _ -> Alcotest.fail "operator download changed model-facing preview rules");
      let path=match binary with
        | Store.Evidence_artifact_binary {body=Some relative;_} ->
          Filename.concat (Common.masc_dir_from_base_path ~base_path:base) relative
        | _ -> Alcotest.fail "binary was not retained" in
      let changed=Bytes.of_string pdf in
      Bytes.set changed (Bytes.length changed-1) 'q';
      Fs_compat.save_file path (Bytes.to_string changed);
      denied 400 ~token:admin (target ());
      Fs_compat.save_file path (pdf ^ "extra");
      denied 400 ~token:admin (target ())))

let () =
  Alcotest.run "Verification operator evidence"
    [ ( "download", [
        Alcotest.test_case "actual HTTP permissions, identity and large binary download to local file" `Quick test_actual_download_route_and_local_export;
        Alcotest.test_case "viewer and write failures retain their destinations" `Quick test_export_preserves_destination_and_saved_effects;
        Alcotest.test_case "authority withdrawal and cancellation preserve actual effects" `Quick test_export_rechecks_authority_and_propagates_cancellation;
        Alcotest.test_case "local recovery registry ignores shared temp collisions" `Quick test_export_uses_local_registry_not_shared_temp;
        Alcotest.test_case "concurrent exports serialize owner recovery" `Quick test_export_serializes_owner_reconciliation_and_publication;
        Alcotest.test_case "lock-admitted cancellation is not a successful export" `Quick test_export_cancellation_after_lock_admission_is_not_success;
        Alcotest.test_case "lane release failure preserves confirmed save" `Quick test_export_lane_release_failure_preserves_saved;
        Alcotest.test_case "lock release failure preserves confirmed save" `Quick test_export_lock_release_failure_preserves_saved;
        Alcotest.test_case "lock refusal ends active progress" `Quick test_export_lock_refusal_ends_progress;
        Alcotest.test_case "ordinary exception ends active progress" `Quick test_export_exception_before_confirmation_ends_progress;
        Alcotest.test_case "saving creates a private local copy with original bytes" `Quick test_download_saves_a_private_local_copy;
        Alcotest.test_case "long original filenames remain usable" `Quick test_export_preserves_long_original_filename;
        Alcotest.test_case "original text and non-image binary bytes round trip" `Quick test_download_preserves_original_bytes;
        Alcotest.test_case "partial and missing snapshots cannot be saved as complete files" `Quick test_download_refuses_missing_or_partial_items;
        Alcotest.test_case "identity and content integrity are required" `Quick test_download_refuses_wrong_identity_and_corrupt_bytes;
      ] )
    ; ( "preview"
      , [ Alcotest.test_case "an image under the ceiling is inline" `Quick
            test_an_image_under_the_ceiling_is_inline
        ; Alcotest.test_case "the ceiling is inclusive" `Quick
            test_the_ceiling_is_inclusive_and_one_more_byte_is_withheld
        ; Alcotest.test_case "a missing or unfiled body is named" `Quick
            test_a_missing_or_unfiled_body_is_named
        ; Alcotest.test_case "a body path outside the evidence directory is not read" `Quick
            test_a_body_path_outside_the_evidence_directory_is_not_read
        ; Alcotest.test_case "formats that never show are not read" `Quick
            test_formats_that_never_show_are_not_read
        ; Alcotest.test_case "the budget is spent in item order on exact bytes" `Quick
            test_the_response_budget_is_spent_in_item_order_and_counts_exact_bytes
        ; Alcotest.test_case "a withheld image does not spend the budget" `Quick
            test_a_withheld_image_does_not_spend_the_budget
        ] )
    ; ( "wire"
      , [ Alcotest.test_case "other kinds and persisted json are untouched" `Quick
            test_other_kinds_have_no_preview_and_json_is_the_persisted_json
        ; Alcotest.test_case "an unavailable access is the persisted json" `Quick
            test_an_unavailable_access_is_the_persisted_json
        ; Alcotest.test_case "the TUI decodes what the server writes" `Quick
            test_the_tui_decodes_what_the_server_writes
        ; Alcotest.test_case "changed bytes are withheld through the TUI decoder" `Quick
            test_changed_bytes_are_withheld_and_the_tui_retains_the_identity_mismatch
        ] )
    ]
