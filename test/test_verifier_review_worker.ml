module AR = Masc.Task.Anti_rationalization
module V = Masc.Verifier_review_original
module O = Masc.Verifier_review_owner
module W = Masc.Verifier_review_worker

let sample_image : AR.evidence_image =
  { image_reference = "artifact:shot.png"
  ; image_sha256 = "abc"
  ; image_bytes = 1
  ; image_media_type = "image/png"
  ; image_body_base64 = "aGk="
  }

let sample_request : AR.review_request =
  { task_title = "T"
  ; task_description = "D"
  ; completion_notes = "N"
  ; agent_name = "a"
  ; task_id = "task-1"
  ; evidence_refs = []
  ; evidence_images = [ sample_image ]
  }

let sample_question : AR.verdict_question =
  { completion_contract = None
  ; required_evidence = []
  ; evidence_posture = AR.Note_only
  ; few_shot_block = ""
  }

let sample_root : AR.lookup_root = AR.Producer_tree []

let with_workspace f =
  let base_path = Filename.temp_dir "verifier-worker-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base_path) f

let test_original_not_found () =
  with_workspace @@ fun base_path ->
  let store = Masc.Lane_addon_store.create ~root:(Filename.concat base_path "request-ownership") in
  let lookup : AR.lookup_surface =
    { schemas = []
    ; dispatch = (fun ~name:_ ~args:_ -> Tool_result.error ~failure_class:Tool_result.Policy_rejection ~tool_name:"none" ~start_time:(Tool_timing.start ()) "no lookup in test")
    }
  in
  match
    W.run_attempt
      ~store
      ~verification_id:"vrf-missing"
      ~attempt:0
      ~installation_id:"masc.verifier"
      ~package_id:"masc.verifier.review"
      ~question:sample_question
      ~lookup
      ~lookup_root:sample_root
      ~provider_rest:(fun _ -> AR.No_stated_rest)
      ~base_path
  with
  | Error W.Original_not_found -> ()
  | Error err -> failwith ("expected Original_not_found, got: " ^ match err with
      | W.Original_not_found -> "not_found"
      | W.Original_corrupt d -> "corrupt: " ^ d
      | W.Review_failed d -> "failed: " ^ d)
  | Ok _ -> failwith "review must not run when no original is retained"

let () =
  test_original_not_found ();
  print_endline "test_verifier_review_worker: all tests passed"
