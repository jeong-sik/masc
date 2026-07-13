(** test_persona_crud_profile_shape — persona create/update write the profile
    shape the loaders read.

    Regression guard for the layer-boundary bug: [masc_persona_create] /
    [masc_persona_update] used to write [display_name] and the keeper-template
    fields at the top level, but the loaders read the display name from
    ["name"] and every keeper-template field from the nested ["keeper"] object.
    The result was a persona whose display name showed the directory name and
    whose [goal]/[instructions]/[mention_targets] were dropped, so a keeper
    spawned from a tool-created persona failed with "goal is required".

    These tests write what the create/update helpers produce and read it back
    through the two real loaders — [load_persona_summary_from_path] (identity)
    and [load_from_dirs] (keeper defaults) — so the two layers stay aligned. *)

open Masc

let write_profile ~dir ~name (json : Yojson.Safe.t) : string =
  let persona_dir = Filename.concat dir name in
  if not (Sys.file_exists persona_dir) then Sys.mkdir persona_dir 0o755;
  let path = Filename.concat persona_dir "profile.json" in
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc (Yojson.Safe.to_string ~std:true json));
  path

let load_defaults ~dir ~name : Keeper_types_profile_defaults.keeper_profile_defaults =
  match
    Keeper_types_profile_persona_defaults.load_from_dirs ~persona_dirs:[ dir ] ~name
  with
  | Ok defaults -> defaults
  | Error (err : Keeper_types_profile_persona_defaults.load_error) ->
      Alcotest.failf "keeper defaults should load, got error at %s" err.path

let test_create_roundtrip () =
  let dir = Filename.temp_dir "masc_persona_crud_create" "" in
  let name = "code-reviewer" in
  let args =
    `Assoc
      [
        ("persona_name", `String name);
        ("display_name", `String "코드 리뷰어");
        ("role", `String "reviewer");
        ("trait", `String "꼼꼼한 검증가");
        ("goal", `String "PR의 결함을 찾는다");
        ("instructions", `String "너는 리뷰어다");
        ("mention_targets", `List [ `String "reviewer"; `String "리뷰어" ]);
        ("proactive_enabled", `Bool true);
      ]
  in
  let profile = Keeper_tool_persona_crud.profile_from_create_args args in
  let path = write_profile ~dir ~name profile in
  (* Identity layer: the loader reads the display name from ["name"]. *)
  (match Keeper_types_profile_persona.load_persona_summary_from_path name path with
   | None -> Alcotest.fail "persona summary should load"
   | Some (s : Keeper_types_profile_persona.persona_summary) ->
       Alcotest.(check string)
         "display name persists (not the directory name)" "코드 리뷰어" s.display_name;
       Alcotest.(check (option string)) "role persists" (Some "reviewer") s.role;
       Alcotest.(check (option string)) "trait persists" (Some "꼼꼼한 검증가") s.trait;
       Alcotest.(check bool) "keeper defaults detected" true s.has_keeper_defaults);
  (* Keeper-template layer: read from the nested ["keeper"] object. *)
  let d = load_defaults ~dir ~name in
  Alcotest.(check (option string))
    "goal reaches keeper defaults" (Some "PR의 결함을 찾는다") d.goal;
  Alcotest.(check (option string))
    "instructions reach keeper defaults" (Some "너는 리뷰어다") d.instructions;
  Alcotest.(check (list string))
    "mention_targets reach keeper defaults" [ "reviewer"; "리뷰어" ] d.mention_targets

let test_create_omits_dead_fields () =
  (* Fields no reader consumes must not be persisted. Pure shape check — no I/O. *)
  let args =
    `Assoc
      [
        ("persona_name", `String "minimal");
        ("display_name", `String "미니멀");
        ("auto_handoff", `Bool true);
      ]
  in
  let profile = Keeper_tool_persona_crud.profile_from_create_args args in
  match profile with
  | `Assoc fields ->
      let has k = List.mem_assoc k fields in
      Alcotest.(check bool) "top-level name written" true (has "name");
      Alcotest.(check bool) "dead display_name key not written" false (has "display_name");
      Alcotest.(check bool) "dead persona_name key not written" false (has "persona_name");
      Alcotest.(check bool) "dead created_at key not written" false (has "created_at");
      Alcotest.(check bool) "dead auto_handoff key not written" false (has "auto_handoff");
      (* No keeper-template fields provided -> no empty keeper object. *)
      Alcotest.(check bool) "no keeper object when no defaults given" false (has "keeper")
  | _ -> Alcotest.fail "profile should be a JSON object"

let test_update_routes_to_layers () =
  let dir = Filename.temp_dir "masc_persona_crud_update" "" in
  let name = "oracle" in
  (* Seed a profile already in the real shape. *)
  let seed =
    `Assoc
      [
        ("name", `String "오라클");
        ("role", `String "예측");
        ("trait", `String "느리지만 멀리 본다");
        ("keeper", `Assoc [ ("goal", `String "old goal"); ("proactive_enabled", `Bool true) ]);
      ]
  in
  let path = write_profile ~dir ~name seed in
  let existing = Yojson.Safe.from_file path in
  let update_args =
    `Assoc
      [
        ("persona_name", `String name);
        ("display_name", `String "오라클 v2");
        (* -> top-level name *)
        ("goal", `String "new goal");
        (* -> keeper.goal (overwrite) *)
        ("instructions", `String "누적 효과를 추적한다");
        (* -> keeper.instructions (new key inside keeper) *)
      ]
  in
  (match Keeper_tool_persona_crud.merge_update_args_into_profile existing update_args with
   | Error e -> Alcotest.failf "merge failed: %s" e
   | Ok merged -> ignore (write_profile ~dir ~name merged));
  (match Keeper_types_profile_persona.load_persona_summary_from_path name path with
   | None -> Alcotest.fail "updated persona summary should load"
   | Some (s : Keeper_types_profile_persona.persona_summary) ->
       Alcotest.(check string) "display name updated" "오라클 v2" s.display_name;
       Alcotest.(check (option string)) "role preserved" (Some "예측") s.role;
       Alcotest.(check (option string))
         "trait preserved" (Some "느리지만 멀리 본다") s.trait);
  let d = load_defaults ~dir ~name in
  Alcotest.(check (option string)) "goal overwritten in keeper layer" (Some "new goal") d.goal;
  Alcotest.(check (option string))
    "instructions added to keeper layer" (Some "누적 효과를 추적한다") d.instructions;
  Alcotest.(check bool)
    "pre-existing keeper.proactive_enabled preserved" true
    (Option.value ~default:false d.proactive_enabled)

let test_delete_removes_persona () =
  let dir = Filename.temp_dir "masc_persona_crud_delete" "" in
  (* handle_persona_delete_json resolves the persona location from
     MASC_PERSONAS_DIR; point it at the temp dir we seed. *)
  Unix.putenv "MASC_PERSONAS_DIR" dir;
  let name = "disposable" in
  let profile =
    Keeper_tool_persona_crud.profile_from_create_args
      (`Assoc [ ("persona_name", `String name); ("display_name", `String "폐기용") ])
  in
  let path = write_profile ~dir ~name profile in
  Alcotest.(check bool)
    "persona exists before delete" true
    (Keeper_types_profile_persona.load_persona_summary_from_path name path <> None);
  (match Keeper_tool_persona_crud.handle_persona_delete_json (`Assoc [ ("persona_name", `String name) ]) with
   | Ok _ -> ()
   | Error e -> Alcotest.failf "delete should succeed: %s" (Yojson.Safe.to_string e));
  Alcotest.(check bool)
    "persona directory removed" false
    (Sys.file_exists (Filename.concat dir name));
  (* Deleting a persona that no longer exists is an error, not a silent no-op. *)
  (match Keeper_tool_persona_crud.handle_persona_delete_json (`Assoc [ ("persona_name", `String name) ]) with
   | Error _ -> ()
   | Ok _ -> Alcotest.fail "second delete must report an error")

(* Minimal substring check: [contains ~affix s] is true when [affix] occurs
   anywhere in [s]. Stdlib-only (the test stanza does not depend on astring). *)
let contains ~affix s =
  let n = String.length affix and m = String.length s in
  let rec go i = i + n <= m && (String.sub s i n = affix || go (i + 1)) in
  n = 0 || go 0

let test_personas_root_unresolved () =
  (* WO-A1-2: an empty resolver root list must refuse loudly — never invent a
     fallback location the loaders would not read. *)
  (match Keeper_tool_persona_crud.personas_dir_of_roots [] with
   | Error msg ->
       Alcotest.(check bool)
         "error names the unresolved root" true
         (contains ~affix:"persona root unresolved" msg)
   | Ok dir -> Alcotest.failf "empty roots must not resolve, got %s" dir);
  match Keeper_tool_persona_crud.personas_dir_of_roots [ "/a"; "/b" ] with
  | Ok dir -> Alcotest.(check string) "first root wins" "/a" dir
  | Error e -> Alcotest.failf "non-empty roots must resolve: %s" e

let test_create_rejects_removed_keys () =
  (* WO-A1-1b: tool_denylist in create args is rejected loudly (the on-disk
     loader fail-closes on it), never silently persisted. *)
  let args =
    `Assoc
      [
        ("persona_name", `String "denylisted");
        ("display_name", `String "거부 대상");
        ("tool_denylist", `List [ `String "exec_shell_command" ]);
      ]
  in
  match Keeper_tool_persona_crud.handle_persona_create_json args with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "create with tool_denylist must be rejected, not persisted"

let test_merge_rejects_legacy_removed_fields () =
  (* A legacy profile still carrying top-level tool_access/tool_denylist must
     fail the update loudly rather than silently rewriting around it. *)
  let existing =
    `Assoc
      [
        ("name", `String "레거시");
        ("tool_denylist", `List [ `String "exec_shell_command" ]);
      ]
  in
  let update_args =
    `Assoc [ ("persona_name", `String "legacy"); ("display_name", `String "새 이름") ]
  in
  match Keeper_tool_persona_crud.merge_update_args_into_profile existing update_args with
  | Error msg ->
      Alcotest.(check bool)
        "error names the removed field" true
        (contains ~affix:"tool_denylist" msg)
  | Ok _ -> Alcotest.fail "legacy removed fields must fail the merge loudly"

let () =
  Alcotest.run "persona_crud_profile_shape"
    [
      ( "layer_boundary",
        [
          Alcotest.test_case "create round-trips identity and keeper layers" `Quick
            test_create_roundtrip;
          Alcotest.test_case "create omits fields no reader consumes" `Quick
            test_create_omits_dead_fields;
          Alcotest.test_case "update routes fields to the correct layer" `Quick
            test_update_routes_to_layers;
        ] );
      ( "fail_loud",
        [
          Alcotest.test_case "empty resolver roots refuse to resolve" `Quick
            test_personas_root_unresolved;
          Alcotest.test_case "create rejects removed keys (tool_denylist)" `Quick
            test_create_rejects_removed_keys;
          Alcotest.test_case "update rejects legacy removed profile fields" `Quick
            test_merge_rejects_legacy_removed_fields;
        ] );
      ( "delete",
        [
          Alcotest.test_case "delete removes the persona and re-delete errors" `Quick
            test_delete_removes_persona;
        ] );
    ]
