(* RFC-0378 §5.3 — the anchor contract is the co-view contract.

   Feature under test: the exact loop the 2026-08-11 owner probe ran.
   The IDE co-view hands the keeper [(codebase slug, repo-root-relative
   path, line)]; the keeper hands it back verbatim; the annotation must
   land in that codebase's store at that line — retrievable by the
   same repo-scoped read the IDE uses — and never in the orphan store.
   The probe's actual burial (delta's annotation filed under its
   sandbox root, id 528e6fd6-…) is the regression this suite pins shut.

   The failure half: a missing codebase and an out-of-tree path are
   typed rejects, not ok:true burials. *)

open Alcotest

let rec rm_rf path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Sys.readdir path |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path)
    else Sys.remove path
;;

let with_temp_base_path f =
  let dir = Filename.temp_file "keeper-ide-annotate-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  Unix.mkdir (Filename.concat dir ".masc") 0o755;
  Unix.mkdir (Filename.concat (Filename.concat dir ".masc") "config") 0o755;
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)
;;

let make_meta name =
  let json =
    `Assoc
      [ "name", `String name
      ; "trace_id", `String ("trace-" ^ name)
      ]
  in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok m -> m
  | Error e -> Alcotest.fail e
;;

let annotate ~config ~meta args =
  Masc.Keeper_tool_ide_runtime.handle_ide_annotate ~config ~meta ~args
;;

let probe_slug = "github.com_jeong-sik_masc"
let probe_path = "lib/ide/ide_annotations.ml"

let test_owner_probe_round_trip () =
  with_temp_base_path (fun base_path ->
    (* The ide sink installs via Ide_bridge's module initializer, which
       only runs if the module is linked — reference it explicitly so
       the annotation sink exists in this binary. *)
    Agent_observation.reset_for_testing ();
    Ide_bridge.install_agent_observation_sinks ();
    let config = Masc.Workspace.default_config (Filename.concat base_path ".masc") in
    let meta = make_meta "delta" in
    let raw =
      annotate
        ~config
        ~meta
        (`Assoc
           [ "codebase", `String probe_slug
           ; "file_path", `String probe_path
           ; "line_start", `Int 39
           ; "content", `String "wall-clock audit probe"
           ])
    in
    let json = Yojson.Safe.from_string raw in
    (match Yojson.Safe.Util.member "ok" json with
     | `Bool true -> ()
     | _ -> failf "expected ok:true, got %s" raw);
    (* The IDE reads with the same repo-scoped vocabulary it handed out. *)
    let filter : Ide_annotation_types.annotation_filter =
      { file_path = Some probe_path; keeper_id = Some "delta"; goal_id = None; task_id = None }
    in
    (match
       Ide_annotations.list
         ~base_dir:base_path
         ~codebase:(probe_slug)
         ~filter
         ()
     with
     | [ annotation ] ->
       check string "path is the co-view path" probe_path annotation.file_path;
       check int "line is the co-view line" 39 annotation.line_start
     | rows -> failf "expected the probe annotation in the codebase store, got %d" (List.length rows));
    (* And nothing was buried where repo-scoped reads cannot see it. *)
    check
      int
      "orphan store stays empty"
      0
      (List.length
         (Ide_annotations.list
            ~base_dir:base_path
            ~codebase:"github.com_other_repo"
            ~filter:{ file_path = None; keeper_id = None; goal_id = None; task_id = None }
            ())))
;;

let expect_reject ~needle raw =
  let json = Yojson.Safe.from_string raw in
  match Yojson.Safe.Util.member "error" json with
  | `String message ->
    check
      bool
      (Printf.sprintf "reject mentions %S (got %S)" needle message)
      true
      (let len_n = String.length needle in
       let len_m = String.length message in
       let rec scan i =
         if i + len_n > len_m
         then false
         else String.sub message i len_n = needle || scan (i + 1)
       in
       scan 0)
  | _ -> failf "expected a typed reject, got %s" raw
;;

let test_missing_codebase_is_a_typed_reject () =
  with_temp_base_path (fun base_path ->
    let config = Masc.Workspace.default_config (Filename.concat base_path ".masc") in
    let meta = make_meta "delta" in
    annotate
      ~config
      ~meta
      (`Assoc
         [ "file_path", `String probe_path
         ; "line_start", `Int 1
         ; "content", `String "no codebase"
         ])
    |> expect_reject ~needle:"codebase is required")
;;

let test_out_of_tree_path_is_a_typed_reject () =
  with_temp_base_path (fun base_path ->
    let config = Masc.Workspace.default_config (Filename.concat base_path ".masc") in
    let meta = make_meta "delta" in
    annotate
      ~config
      ~meta
      (`Assoc
         [ "codebase", `String probe_slug
         ; "file_path", `String "../outside.ml"
         ; "line_start", `Int 1
         ; "content", `String "escape attempt"
         ])
    |> expect_reject ~needle:"anchor rejected")
;;

let () =
  run
    "keeper_ide_annotate_contract"
    [ ( "co-view anchor"
      , [ test_case "owner probe round trip" `Quick test_owner_probe_round_trip
        ; test_case
            "missing codebase is a typed reject"
            `Quick
            test_missing_codebase_is_a_typed_reject
        ; test_case
            "out-of-tree path is a typed reject"
            `Quick
            test_out_of_tree_path_is_a_typed_reject
        ] )
    ]
;;
