(** Structural guard for the adversarial re-review of PR #24364 (P1-1).

    [handle_keeper_create_from_persona] in
    [lib/keeper/keeper_tool_surface_ops.ml] used to mint the initial_goal
    Goal entity ([Goal_store.upsert_goal]) BEFORE the validate gate
    ([validate_resolved_keeper_create_json]). Every rejected create
    (missing mention_targets, TOML render failure, boot failure) then left
    an unlinked Goal on disk, one more per retry.

    This test pins the fix:

    - (a) the validate gate must appear before the mint in the source, so
          a validation reject can never observe a minted goal
    - (b) a compensation path ([Goal_store.delete_goal]) must exist for the
          failure branches that run after the mint (toml render / boot)

    Structural (source scan) rather than behavioural because the handler
    needs a full Eio ctx + persona fixture to exercise; the semantic
    assumption that makes the reorder valid (the pre-mint injected shape
    passes the gate) is pinned behaviourally in
    [test_keeper_create_validate.ml]. *)

open Alcotest

let target_file = "lib/keeper/keeper_tool_surface_ops.ml"

let load_source rel =
  let source_root =
    match Sys.getenv_opt "DUNE_SOURCEROOT" with
    | Some root -> root
    | None -> Sys.getcwd ()
  in
  let path = Filename.concat source_root rel in
  if not (Sys.file_exists path) then
    failwith (Printf.sprintf "source file not found: %s" path)
  else
    let ic = open_in path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () -> In_channel.input_all ic)

let index_of haystack re =
  try Some (Str.search_forward re haystack 0) with Not_found -> None

let validate_re = Str.regexp_string "validate_resolved_keeper_create_json"
let mint_re = Str.regexp_string "Goal_store.upsert_goal"
let release_re = Str.regexp_string "Goal_store.delete_goal"

let test_validate_before_mint () =
  let src = load_source target_file in
  let validate_idx = index_of src validate_re in
  let mint_idx = index_of src mint_re in
  match (validate_idx, mint_idx) with
  | None, _ ->
      fail "validate_resolved_keeper_create_json call disappeared from the \
            create-from-persona handler"
  | _, None ->
      fail "Goal_store.upsert_goal mint disappeared from the \
            create-from-persona handler"
  | Some v, Some m ->
      check bool
        "validate gate must run before the Goal mint (orphan-Goal guard)"
        true (v < m)

let test_compensation_present () =
  let src = load_source target_file in
  check bool
    "post-mint failure branches must keep a Goal_store.delete_goal \
     compensation"
    true
    (index_of src release_re <> None)

let () =
  run "keeper_create_mint_order"
    [
      ( "orphan_goal_guard",
        [
          test_case "validate before mint" `Quick test_validate_before_mint;
          test_case "compensation delete present" `Quick
            test_compensation_present;
        ] );
    ]
