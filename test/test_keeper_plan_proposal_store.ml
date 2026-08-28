open Alcotest

module Descriptor = Masc.Keeper_tool_descriptor
module Plan = Masc.Keeper_plan_proposal
module Store = Masc.Keeper_plan_proposal_store
module Surface = Masc.Keeper_capability_surface

let descriptors () = Descriptor.all_descriptors ()
let surface_digest = String.make 64 'b'

let descriptor name =
  descriptors ()
  |> List.find_opt (fun descriptor ->
    Descriptor.keeper_model_names descriptor |> List.exists (String.equal name))
  |> function
  | Some descriptor -> descriptor
  | None -> failf "missing model-visible descriptor %S" name
;;

let reference name =
  let descriptor = descriptor name in
  Surface.ordinary_tool_reference_of_yojson
    (`Assoc
      [ "descriptor_id", `String descriptor.id
      ; "capability_id", `String descriptor.capability_id
      ])
  |> function
  | Ok reference -> reference
  | Error _ -> failf "descriptor %S did not form an exact reference" name
;;

let time_plan ?(node_id = "clock") () =
  `Assoc
    [ ( "nodes"
      , `List
          [ `Assoc
              [ "id", `String node_id
              ; "tool", `String "keeper_time_now"
              ]
          ] )
    ]
;;

let reordered_time_plan () =
  `Assoc
    [ ( "nodes"
      , `List
          [ `Assoc
              [ "tool", `String "keeper_time_now"
              ; "id", `String "clock"
              ]
          ] )
    ]
;;

let single_tool_plan tool =
  `Assoc
    [ ( "nodes"
      , `List
          [ `Assoc [ "id", `String "operation"; "tool", `String tool ] ] )
    ]
;;

let replace_assoc name replacement = function
  | `Assoc fields ->
    `Assoc
      (List.map
         (fun (field, value) ->
            if String.equal field name then field, replacement else field, value)
         fields)
  | value -> value
;;

let create
      ?(objective = "Observe current time")
      ?(execution = Plan.Inline)
      ?(references = [ reference "keeper_time_now" ])
      ?(plan_json = time_plan ())
      ()
  =
  Plan.create
    ~descriptors:(descriptors ())
    ~objective
    ~execution
    ~capability_surface_sha256:surface_digest
    ~ordinary_tool_references:references
    ~plan_json
  |> function
  | Ok proposal -> proposal
  | Error error ->
    failf "proposal rejected: %s" (Plan.error_to_yojson error |> Yojson.Safe.to_string)
;;

let proposal_id proposal = Plan.id proposal |> Plan.Proposal_id.to_string

let test_canonical_payload_has_stable_id () =
  let time = reference "keeper_time_now" in
  let tools = reference "keeper_tools_list" in
  let first = create ~references:[ time; tools ] () in
  let second =
    create ~references:[ time; tools ] ~plan_json:(reordered_time_plan ()) ()
  in
  check string "canonical id" (proposal_id first) (proposal_id second);
  check string "canonical bytes" (Plan.canonical_bytes first) (Plan.canonical_bytes second)
;;

let test_semantic_changes_change_id () =
  let base = create () in
  let objective = create ~objective:"Observe current time precisely" () in
  let execution = create ~execution:Plan.Async () in
  let changed_plan = create ~plan_json:(time_plan ~node_id:"clock-2" ()) () in
  let changed_refs =
    create ~references:[ reference "keeper_time_now"; reference "keeper_tools_list" ] ()
  in
  List.iter
    (fun (label, proposal) ->
       check bool label false (String.equal (proposal_id base) (proposal_id proposal)))
    [ "objective changes id", objective
    ; "execution changes id", execution
    ; "plan changes id", changed_plan
    ; "reference changes id", changed_refs
    ]
;;

let test_arbitrary_or_unreferenced_plan_is_rejected () =
  let arbitrary = `Assoc [ "nodes", `List [ `Assoc [ "id", `String "x"; "tool", `String "not-a-tool" ] ] ] in
  (match
     Plan.create
       ~descriptors:(descriptors ())
       ~objective:"invalid"
       ~execution:Plan.Inline
       ~capability_surface_sha256:surface_digest
       ~ordinary_tool_references:[ reference "keeper_time_now" ]
       ~plan_json:arbitrary
   with
   | Error (Plan.Plan_rejected _) -> ()
   | Error error ->
     failf "wrong invalid plan error: %s" (Plan.error_to_yojson error |> Yojson.Safe.to_string)
   | Ok _ -> fail "arbitrary plan bytes were accepted");
  (match
     Plan.create
       ~descriptors:(descriptors ())
       ~objective:"missing reference"
       ~execution:Plan.Inline
       ~capability_surface_sha256:surface_digest
       ~ordinary_tool_references:[]
       ~plan_json:(time_plan ())
   with
   | Error (Plan.Invalid_reference (Plan.Missing_plan_reference _)) -> ()
   | Error error ->
     failf "wrong missing reference error: %s" (Plan.error_to_yojson error |> Yojson.Safe.to_string)
   | Ok _ -> fail "plan without its exact Tool reference was accepted")
;;

let test_async_requires_every_descriptor_to_be_statically_read_only () =
  let expect_async_rejection tool =
    let exact_descriptor = descriptor tool in
    match
      Plan.create
        ~descriptors:(descriptors ())
        ~objective:"Reject an unsafe async proposal"
        ~execution:Plan.Async
        ~capability_surface_sha256:surface_digest
        ~ordinary_tool_references:[ reference tool ]
        ~plan_json:(single_tool_plan tool)
    with
    | Error
        (Plan.Async_tool_not_statically_read_only
          { descriptor_id; capability_id }) ->
      check string "descriptor id" exact_descriptor.id descriptor_id;
      check string "capability id" exact_descriptor.capability_id capability_id
    | Error error ->
      failf
        "wrong async rejection for %s: %s"
        tool
        (Plan.error_to_yojson error |> Yojson.Safe.to_string)
    | Ok _ -> failf "unsafe async descriptor %s was accepted" tool
  in
  check (option bool) "mutating fixture carries Some false" (Some false)
    (Descriptor.readonly_static_hint (descriptor "keeper_memory_write"));
  expect_async_rejection "keeper_memory_write";
  check (option bool) "input-dependent fixture carries None" None
    (Descriptor.readonly_static_hint (descriptor "Execute"));
  expect_async_rejection "Execute";
  let inline_mutation =
    create
      ~objective:"Inline mutation remains representable"
      ~execution:Plan.Inline
      ~references:[ reference "keeper_memory_write" ]
      ~plan_json:(single_tool_plan "keeper_memory_write")
      ()
  in
  let stored_async =
    Plan.to_yojson inline_mutation
    |> replace_assoc "execution" (`String "async")
  in
  (match
     Plan.of_stored_yojson
       ~descriptors:(descriptors ())
       ~expected_id:(Plan.id inline_mutation)
       stored_async
   with
   | Error (Plan.Async_tool_not_statically_read_only _) -> ()
   | Error error ->
     failf
       "stored async mutation returned wrong error: %s"
       (Plan.error_to_yojson error |> Yojson.Safe.to_string)
   | Ok _ -> fail "stored async mutation loaded");
  ignore
    inline_mutation
;;

let temp_dir () =
  let path = Filename.temp_file "keeper-plan-proposal" "" in
  Unix.unlink path;
  Unix.mkdir path 0o755;
  path
;;

let rec remove_tree path =
  match Unix.lstat path with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
  | stat when stat.Unix.st_kind = Unix.S_DIR ->
    Sys.readdir path
    |> Array.iter (fun name -> remove_tree (Filename.concat path name));
    Unix.rmdir path
  | _ -> Unix.unlink path
;;

let with_store f =
  let base = temp_dir () in
  Fun.protect
    ~finally:(fun () -> remove_tree base)
    (fun () ->
       let config = Masc.Workspace.default_config_uncached base in
       let masc_root = Masc.Workspace.masc_root_dir config in
       Fs_compat.mkdir_p masc_root;
       Eio_main.run (fun env ->
         Fs_compat.set_fs (Eio.Stdenv.fs env);
         f config masc_root))
;;

let read_file path =
  match Fs_compat.load_owned_regular_file ~ownership_root:(Filename.dirname path) path with
  | Ok (Some content) -> content
  | Ok None -> failf "missing file %s" path
  | Error error -> fail (Fs_compat.owned_regular_file_read_error_to_string error)
;;

let test_store_roundtrip_deduplicates_without_dispatch () =
  with_store (fun config masc_root ->
    let time = reference "keeper_time_now" in
    let tools = reference "keeper_tools_list" in
    let proposal = create ~references:[ time; tools ] () in
    let equivalent =
      create ~references:[ time; tools ] ~plan_json:(reordered_time_plan ()) ()
    in
    (match Store.save config equivalent with
     | Ok Store.Stored -> ()
     | Ok Already_present -> fail "first save was already present"
     | Error error -> fail (Store.error_to_yojson error |> Yojson.Safe.to_string));
    (match Store.save config proposal with
     | Ok Store.Already_present -> ()
     | Ok Stored -> fail "identical proposal was stored twice"
     | Error error -> fail (Store.error_to_yojson error |> Yojson.Safe.to_string));
    let files = Sys.readdir (Store.store_dir config) |> Array.to_list in
    check int "one content-addressed file" 1 (List.length files);
    (match Store.load ~descriptors:(descriptors ()) config (Plan.id proposal) with
     | Ok loaded ->
       check string "roundtrip id" (proposal_id proposal) (proposal_id loaded);
       check string "roundtrip bytes" (Plan.canonical_bytes proposal) (Plan.canonical_bytes loaded);
       (match Plan.plan loaded |> Masc.Keeper_tool_plan.nodes with
        | [ node ] ->
          check string "roundtrip typed plan node" "keeper_time_now" node.tool_name
        | nodes ->
          failf "roundtrip typed plan has %d nodes" (List.length nodes))
     | Error error -> fail (Store.error_to_yojson error |> Yojson.Safe.to_string));
    check bool "store did not dispatch an ordinary Tool" false
      (Sys.file_exists (Filename.concat masc_root "tool_calls")))
;;

let test_tampered_content_and_filename_are_rejected_without_repair () =
  with_store (fun config _masc_root ->
    let proposal = create () in
    (match Store.save config proposal with
     | Ok Store.Stored -> ()
     | Ok Already_present -> fail "fixture unexpectedly existed"
     | Error error -> fail (Store.error_to_yojson error |> Yojson.Safe.to_string));
    let path = Store.proposal_path config (Plan.id proposal) in
    let tampered =
      Plan.to_yojson proposal
      |> replace_assoc "objective" (`String "tampered")
      |> Yojson.Safe.to_string
    in
    Fs_compat.save_file path tampered;
    (match Store.load ~descriptors:(descriptors ()) config (Plan.id proposal) with
     | Error (Store.Invalid_proposal (Plan.Tampered_payload _)) -> ()
     | Error error -> failf "wrong tamper error: %s" (Store.error_to_yojson error |> Yojson.Safe.to_string)
     | Ok _ -> fail "tampered content loaded");
    check string "load did not repair tampered bytes" tampered (read_file path);
    (match Store.save config proposal with
     | Error (Store.Tampered_existing_file id)
       when Plan.Proposal_id.equal id (Plan.id proposal) -> ()
     | Error error -> failf "wrong pre-write tamper error: %s" (Store.error_to_yojson error |> Yojson.Safe.to_string)
     | Ok _ -> fail "save overwrote tampered existing bytes");
    check string "save rejected before write" tampered (read_file path);
    Fs_compat.save_file path (Plan.canonical_bytes proposal);
    let wrong_id =
      match Plan.Proposal_id.of_string (String.make 64 'a') with
      | Ok id -> id
      | Error _ -> fail "fixture digest invalid"
    in
    let wrong_path = Store.proposal_path config wrong_id in
    Fs_compat.save_file wrong_path (Plan.canonical_bytes proposal);
    (match Store.load ~descriptors:(descriptors ()) config wrong_id with
     | Error (Store.Invalid_proposal (Plan.Filename_digest_mismatch _)) -> ()
     | Error error -> failf "wrong filename error: %s" (Store.error_to_yojson error |> Yojson.Safe.to_string)
     | Ok _ -> fail "content under the wrong digest filename loaded"))
;;

let test_noncanonical_stored_bytes_are_rejected_as_tamper () =
  with_store (fun config _masc_root ->
    let proposal = create () in
    let path = Store.proposal_path config (Plan.id proposal) in
    Fs_compat.mkdir_p (Store.store_dir config);
    let noncanonical = Plan.to_yojson proposal |> Yojson.Safe.pretty_to_string in
    check bool "fixture bytes are noncanonical" false
      (String.equal noncanonical (Plan.canonical_bytes proposal));
    Fs_compat.save_file path noncanonical;
    match Store.load ~descriptors:(descriptors ()) config (Plan.id proposal) with
    | Error (Store.Tampered_existing_file id)
      when Plan.Proposal_id.equal id (Plan.id proposal) -> ()
    | Error error ->
      failf
        "wrong noncanonical tamper error: %s"
        (Store.error_to_yojson error |> Yojson.Safe.to_string)
    | Ok _ -> fail "semantically equivalent noncanonical bytes loaded")
;;

let test_exclusive_create_collision_never_clobbers () =
  with_store (fun config _masc_root ->
    let identical = create ~objective:"External identical publication" () in
    (match
       Store.For_testing.save_after_absence_observed
         ~before_exclusive_create:(fun ~path ->
           Fs_compat.save_file path (Plan.canonical_bytes identical))
         config
         identical
     with
     | Ok Store.Already_present -> ()
     | Ok Stored -> fail "collision was reported as this writer's publication"
     | Error error ->
       failf
         "identical collision failed: %s"
         (Store.error_to_yojson error |> Yojson.Safe.to_string));
    let conflicting = create ~objective:"External conflicting publication" () in
    let conflicting_path = Store.proposal_path config (Plan.id conflicting) in
    let external_bytes = "external-owner-bytes" in
    (match
       Store.For_testing.save_after_absence_observed
         ~before_exclusive_create:(fun ~path ->
           Fs_compat.save_file path external_bytes)
         config
         conflicting
     with
     | Error (Store.Tampered_existing_file id)
       when Plan.Proposal_id.equal id (Plan.id conflicting) -> ()
     | Error error ->
       failf
         "wrong conflicting collision error: %s"
         (Store.error_to_yojson error |> Yojson.Safe.to_string)
     | Ok _ -> fail "conflicting external publication was overwritten");
    check string "external bytes retained" external_bytes (read_file conflicting_path))
;;

let add_field field json =
  match json with
  | `Assoc fields -> `Assoc (field :: fields)
  | value -> value
;;

let test_closed_stored_schema_rejects_duplicate_unknown_and_version () =
  let proposal = create () in
  let expected_id = Plan.id proposal in
  let decode json =
    Plan.of_stored_yojson ~descriptors:(descriptors ()) ~expected_id json
  in
  (match add_field ("objective", `String "duplicate") (Plan.to_yojson proposal) |> decode with
   | Error (Plan.Invalid_payload (Plan.Json_not_canonicalizable _)) -> ()
   | Error error -> failf "wrong duplicate error: %s" (Plan.error_to_yojson error |> Yojson.Safe.to_string)
   | Ok _ -> fail "duplicate field loaded");
  (match add_field ("unknown", `Bool true) (Plan.to_yojson proposal) |> decode with
   | Error (Plan.Invalid_payload (Plan.Unknown_field "unknown")) -> ()
   | Error error -> failf "wrong unknown error: %s" (Plan.error_to_yojson error |> Yojson.Safe.to_string)
   | Ok _ -> fail "unknown field loaded");
  (match replace_assoc "schema_version" (`Int 2) (Plan.to_yojson proposal) |> decode with
   | Error (Plan.Unsupported_version 2) -> ()
   | Error error -> failf "wrong version error: %s" (Plan.error_to_yojson error |> Yojson.Safe.to_string)
   | Ok _ -> fail "unsupported schema version loaded")
;;

let json_kind json =
  match Yojson.Safe.Util.member "kind" json with
  | `String kind -> kind
  | _ -> failf "error JSON has no kind: %s" (Yojson.Safe.to_string json)
;;

let test_error_json_codecs_cover_every_top_level_sum () =
  let exact_reference = reference "keeper_time_now" in
  let proposal_errors =
    [ ( "invalid_payload"
      , Plan.Invalid_payload (Plan.Unknown_field "extra") )
    ; "unsupported_version", Plan.Unsupported_version 2
    ; ( "invalid_reference"
      , Plan.Invalid_reference (Plan.Duplicate_reference exact_reference) )
    ; ( "invalid_digest"
      , Plan.Invalid_digest
          { field = Plan.Capability_surface_sha256; value = "invalid" } )
    ; ( "plan_rejected"
      , Plan.Plan_rejected Masc.Keeper_tool_plan_request.Missing_nodes )
    ; ( "async_tool_not_statically_read_only"
      , Plan.Async_tool_not_statically_read_only
          { descriptor_id = "agent.execute"
          ; capability_id = "keeper.tool.execute"
          } )
    ; ( "tampered_payload"
      , Plan.Tampered_payload
          { stored_digest = String.make 64 'a'
          ; computed_digest = String.make 64 'b'
          } )
    ; ( "filename_digest_mismatch"
      , Plan.Filename_digest_mismatch
          { filename_digest = String.make 64 'c'
          ; content_digest = String.make 64 'd'
          } )
    ]
  in
  List.iter
    (fun (expected, error) ->
       check string expected expected (Plan.error_to_yojson error |> json_kind))
    proposal_errors;
  let proposal = create () in
  let proposal_id = Plan.id proposal in
  let read_error : Fs_compat.owned_regular_file_read_error =
    { failure =
        Fs_compat.Path_is_not_regular_file
          { path = "/owned/proposal"; kind = Unix.S_LNK }
    ; close_failure = None
    }
  in
  let directory_error =
    Masc.Keeper_fs_durable_directory.Directory_chain_failed
      (Masc.Keeper_fs_durable_directory.Missing_root { path = "/missing" })
  in
  let exclusive_error : Fs_compat.capability_write_error =
    { operation = Fs_compat.Create_exclusive_operation
    ; target_effect = Fs_compat.Target_unchanged
    ; primary_failure =
        Fs_compat.Write_primary_failure
          { stage = Fs_compat.Create_target_entry
          ; cause =
              Fs_compat.Operation_failed
                { exception_ = Failure "unavailable"
                ; backtrace = Printexc.get_callstack 0
                }
          }
    ; cleanup_failures = []
    }
  in
  let store_errors =
    [ "invalid_proposal", Store.Invalid_proposal (List.hd proposal_errors |> snd)
    ; "invalid_proposal_id", Store.Invalid_proposal_id "../escape"
    ; "proposal_not_found", Store.Proposal_not_found proposal_id
    ; "tampered_existing_file", Store.Tampered_existing_file proposal_id
    ; "read_failed", Store.Read_failed read_error
    ; "directory_prepare_failed", Store.Directory_prepare_failed directory_error
    ; "capability_filesystem_unavailable", Store.Capability_filesystem_unavailable
    ; "exclusive_write_failed", Store.Exclusive_write_failed exclusive_error
    ]
  in
  List.iter
    (fun (expected, error) ->
       check string expected expected (Store.error_to_yojson error |> json_kind))
    store_errors
;;

let test_nested_base_path_and_path_escape_contract () =
  let root = temp_dir () in
  Fun.protect
    ~finally:(fun () -> remove_tree root)
    (fun () ->
       let base = Filename.concat root "nested/workspace" in
       Fs_compat.mkdir_p base;
       let config = Masc.Workspace.default_config_uncached base in
       let masc_root = Masc.Workspace.masc_root_dir config in
       Fs_compat.mkdir_p masc_root;
       Eio_main.run (fun env ->
         Fs_compat.set_fs (Eio.Stdenv.fs env);
         let proposal = create () in
         (match Store.save config proposal with
          | Ok Store.Stored -> ()
          | Ok Already_present -> fail "nested fixture unexpectedly existed"
          | Error error -> fail (Store.error_to_yojson error |> Yojson.Safe.to_string));
         check string "store derives from nested masc_root"
           (Filename.concat masc_root "keeper-plan-proposals")
           (Store.store_dir config);
         (match Store.load_string_id ~descriptors:(descriptors ()) config "../escape" with
          | Error (Store.Invalid_proposal_id "../escape") -> ()
          | Error error -> failf "wrong escape error: %s" (Store.error_to_yojson error |> Yojson.Safe.to_string)
          | Ok _ -> fail "path-like proposal id loaded")))
;;

let test_symlink_proposal_is_rejected_by_owned_reader () =
  with_store (fun config masc_root ->
    let proposal = create () in
    Fs_compat.mkdir_p (Store.store_dir config);
    let outside = Filename.concat (Filename.dirname masc_root) "outside-proposal.json" in
    Fs_compat.save_file outside (Plan.canonical_bytes proposal);
    let path = Store.proposal_path config (Plan.id proposal) in
    Unix.symlink outside path;
    (match Store.load ~descriptors:(descriptors ()) config (Plan.id proposal) with
     | Error
         (Store.Read_failed
           { Fs_compat.failure =
               Fs_compat.Path_is_not_regular_file { kind = Unix.S_LNK; _ }
           ; _
           }) -> ()
     | Error error -> failf "wrong symlink error: %s" (Store.error_to_yojson error |> Yojson.Safe.to_string)
     | Ok _ -> fail "symlinked proposal loaded"))
;;

let test_missing_masc_root_returns_typed_write_failure () =
  let base = temp_dir () in
  Fun.protect
    ~finally:(fun () -> remove_tree base)
    (fun () ->
       let config = Masc.Workspace.default_config_uncached base in
       let masc_root = Masc.Workspace.masc_root_dir config in
       check bool "fixture masc_root is absent" false (Sys.file_exists masc_root);
       Eio_main.run (fun env ->
         Fs_compat.set_fs (Eio.Stdenv.fs env);
         match Store.save config (create ()) with
         | Error
             (Store.Directory_prepare_failed
               (Masc.Keeper_fs_durable_directory.Directory_chain_failed
                 (Masc.Keeper_fs_durable_directory.Missing_root _))) -> ()
         | Error error ->
           failf
             "wrong missing-root error: %s"
             (Store.error_to_yojson error |> Yojson.Safe.to_string)
         | Ok _ -> fail "save created an absent ownership root"))
;;

let test_missing_capability_filesystem_fails_before_mutation () =
  let base = temp_dir () in
  Fun.protect
    ~finally:(fun () -> remove_tree base)
    (fun () ->
       let config = Masc.Workspace.default_config_uncached base in
       let masc_root = Masc.Workspace.masc_root_dir config in
       Fs_compat.mkdir_p masc_root;
       Eio_main.run (fun _env ->
         Fs_compat.clear_fs ();
         match Store.save config (create ()) with
         | Error Store.Capability_filesystem_unavailable ->
           check bool "store directory was not created" false
             (Sys.file_exists (Store.store_dir config))
         | Error error ->
           failf
             "wrong missing capability fs error: %s"
             (Store.error_to_yojson error |> Yojson.Safe.to_string)
         | Ok _ -> fail "save proceeded without the installed capability filesystem"))
;;

let () =
  ignore (Masc_test_deps.init_unified_tool_registry ());
  run
    "keeper-plan-proposal-store"
    [ ( "proposal"
      , [ test_case "canonical payload has stable id" `Quick test_canonical_payload_has_stable_id
        ; test_case "semantic changes change id" `Quick test_semantic_changes_change_id
        ; test_case "arbitrary plans and missing references reject" `Quick test_arbitrary_or_unreferenced_plan_is_rejected
        ; test_case "async requires static readonly descriptors" `Quick test_async_requires_every_descriptor_to_be_statically_read_only
        ; test_case "stored schema is closed and versioned" `Quick test_closed_stored_schema_rejects_duplicate_unknown_and_version
        ; test_case "error JSON covers typed sums" `Quick test_error_json_codecs_cover_every_top_level_sum
        ] )
    ; ( "store"
      , [ test_case "roundtrip deduplicates without dispatch" `Quick test_store_roundtrip_deduplicates_without_dispatch
        ; test_case "tamper and filename mismatch reject before mutation" `Quick test_tampered_content_and_filename_are_rejected_without_repair
        ; test_case "noncanonical stored bytes reject as tamper" `Quick test_noncanonical_stored_bytes_are_rejected_as_tamper
        ; test_case "exclusive create collision never clobbers" `Quick test_exclusive_create_collision_never_clobbers
        ; test_case "nested base path and path escape" `Quick test_nested_base_path_and_path_escape_contract
        ; test_case "symlink proposal rejects" `Quick test_symlink_proposal_is_rejected_by_owned_reader
        ; test_case "missing masc root returns write failure" `Quick test_missing_masc_root_returns_typed_write_failure
        ; test_case "missing capability fs fails before mutation" `Quick test_missing_capability_filesystem_fails_before_mutation
        ] )
    ]
;;
