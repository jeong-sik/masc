(* task-1719 / #39331: the lifetime contract a prune policy must consult
   before evicting a store_kept vision handle. See
   lib/multimodal/vision_artifact_reference.mli for the module contract.
   This test defines the contract; nothing here caps or deletes anything. *)

open Alcotest

let fresh_dir () =
  let base = Filename.temp_file "masc-vision-artifact-reference-test-" "" in
  Sys.remove base;
  Fs_compat.mkdir_p base;
  base
;;

let write ~dir ~rel content =
  let path = Filename.concat dir rel in
  Fs_compat.mkdir_p (Filename.dirname path);
  let oc = open_out_bin path in
  output_string oc content;
  close_out oc
;;

(* A syntactically valid-looking 64-hex handle; this module never validates
   handle shape (that is Vision_artifact_store's job), so a fixed literal is
   enough to exercise the substring scan. *)
let handle = String.make 64 'a'

let referenced ~masc_dir =
  Multimodal.Vision_artifact_reference.is_referenced ~masc_dir ~handle
  |> Result.map_error Multimodal.Vision_artifact_reference.error_to_string
;;

let test_absent_masc_dir_is_unreferenced () =
  let masc_dir = Filename.concat (fresh_dir ()) "does-not-exist" in
  check (result bool string) "absent masc_dir has no references" (Ok false) (referenced ~masc_dir)
;;

let test_no_mention_is_unreferenced () =
  let masc_dir = fresh_dir () in
  write ~dir:masc_dir ~rel:"messages/turn1.json" {|{"tool": "noop"}|};
  check (result bool string) "no mention anywhere" (Ok false) (referenced ~masc_dir)
;;

let test_mention_in_messages_is_referenced () =
  let masc_dir = fresh_dir () in
  write ~dir:masc_dir ~rel:"messages/turn1.json" (Printf.sprintf {|{"artifact": "%s"}|} handle);
  check (result bool string) "mentioned under messages/" (Ok true) (referenced ~masc_dir)
;;

let test_own_vision_store_content_is_skipped () =
  let masc_dir = fresh_dir () in
  (* A regular content scan cannot self-match on the filename (only content is
     read), so this deliberately embeds the handle text INSIDE the payload --
     a degenerate case real image bytes will not produce, but the one case
     that actually exercises the keepers/*.vision skip below. Without the
     skip this would be Ok true; the next test proves that with a red run. *)
  write
    ~dir:masc_dir
    ~rel:(Filename.concat "keepers/some-keeper.vision" handle)
    (Printf.sprintf "raw-bytes-%s-embedded" handle);
  check
    (result bool string)
    "content under keepers/*.vision is not scanned"
    (Ok false)
    (referenced ~masc_dir)
;;

let test_keeper_state_sibling_is_referenced () =
  let masc_dir = fresh_dir () in
  write ~dir:masc_dir ~rel:(Filename.concat "keepers/some-keeper.vision" handle) "raw-bytes";
  write
    ~dir:masc_dir
    ~rel:(Filename.concat "keepers/some-keeper" "checkpoint.json")
    (Printf.sprintf {|{"pending_artifact": "%s"}|} handle);
  check
    (result bool string)
    "a sibling keeper-state file mentioning the handle is a real reference"
    (Ok true)
    (referenced ~masc_dir)
;;

let test_symlinked_tree_blocks_eviction () =
  (* The sole mention of [handle] sits behind a symlink. Silently skipping
     that symlink (the earlier version of this module) would read that as
     "no reference anywhere" -- exactly the case a future store_kept pruner
     must never see, since it would delete a live artifact. masc-pro-builder
     caught this in review (PR #39473, P2): is_referenced must not answer
     [Ok false] here. It answers [Error (Symlink_encountered _)] instead, so
     a caller that treats any [Error] as "do not evict" stays safe. *)
  let masc_dir = fresh_dir () in
  let real_target = fresh_dir () in
  write ~dir:real_target ~rel:"note.txt" (Printf.sprintf "artifact=%s" handle);
  Unix.symlink real_target (Filename.concat masc_dir "gate");
  match Multimodal.Vision_artifact_reference.is_referenced ~masc_dir ~handle with
  | Ok false -> failwith "a symlink hiding the sole reference must not read as unreferenced"
  | Ok true -> failwith "is_referenced should not silently resolve through a symlink either"
  | Error (Multimodal.Vision_artifact_reference.Symlink_encountered _) -> ()
  | Error other ->
    failwith
      ("expected Symlink_encountered, got: "
       ^ Multimodal.Vision_artifact_reference.error_to_string other)
;;

let () =
  run
    "vision_artifact_reference"
    [ ( "is_referenced"
      , [ test_case "absent masc_dir" `Quick test_absent_masc_dir_is_unreferenced
        ; test_case "no mention" `Quick test_no_mention_is_unreferenced
        ; test_case "mention in messages" `Quick test_mention_in_messages_is_referenced
        ; test_case
            "own vision store content skipped"
            `Quick
            test_own_vision_store_content_is_skipped
        ; test_case "keeper state sibling counts" `Quick test_keeper_state_sibling_is_referenced
        ; test_case "symlink blocks eviction" `Quick test_symlinked_tree_blocks_eviction
        ] )
    ]
;;
