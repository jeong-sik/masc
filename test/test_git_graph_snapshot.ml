open Alcotest

module G = Masc_mcp.Git_graph_snapshot

let sample_outputs ?(status = []) ?(merge_state = false) () : G.git_outputs =
  { repo_root = "/tmp/masc-mcp"
  ; head = Some "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  ; short_head = Some "aaaaaaaaaa"
  ; current_branch = Some "feature/one"
  ; refs =
      [ "feature/one\taaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      ; "main\tbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
      ; "origin/main\tbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
      ]
  ; commits =
      [ "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\tbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\t2026-04-30T01:02:03+09:00\tfeature commit"
      ; "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\t\t2026-04-30T01:00:00+09:00\tbase commit"
      ]
  ; worktrees =
      [ "worktree /tmp/masc-mcp"
      ; "HEAD bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
      ; "branch refs/heads/main"
      ; ""
      ; "worktree /tmp/masc-mcp/.worktrees/feature-one"
      ; "HEAD aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      ; "branch refs/heads/feature/one"
      ]
  ; status
  ; merge_state
  }

let snapshot () =
  G.snapshot_of_outputs ~generated_at:"2026-04-30T00:00:00Z" (sample_outputs ())

let test_json_shape_round_trips () =
  let snap = snapshot () in
  let json = G.snapshot_to_yojson snap in
  match G.snapshot_of_yojson json with
  | Ok decoded ->
      check int "repo count" 1 decoded.stats.repo_count;
      check int "agent count" 2 decoded.stats.agent_count;
      check int "commit count" 2 decoded.stats.commit_count
  | Error msg -> fail msg

let test_commit_parent_and_ref_edges () =
  let snap = snapshot () in
  let has_parent =
    List.exists
      (fun (edge : G.graph_edge) ->
        edge.kind = "parent"
        && edge.source = "commit:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        && edge.target = "commit:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
      snap.edges
  in
  let has_ref =
    List.exists
      (fun (edge : G.graph_edge) ->
        edge.kind = "points_to"
        && edge.source = "commit:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        && edge.target = "ref:feature/one")
      snap.edges
  in
  check bool "commit parent edge" true has_parent;
  check bool "branch points to commit" true has_ref

let test_conflict_status_encoding () =
  let snap =
    G.snapshot_of_outputs ~generated_at:"2026-04-30T00:00:00Z"
      (sample_outputs ~status:[ "UU lib/a.ml"; " M lib/b.ml" ] ())
  in
  check int "one unmerged conflict" 1 snap.stats.conflict_count;
  check int "two dirty rows" 2 snap.stats.dirty_count;
  let current_branch =
    List.find_opt
      (fun (node : G.graph_node) -> node.id = "ref:feature/one")
      snap.nodes
  in
  match current_branch with
  | Some node ->
      check string "status" "conflict" node.status;
      check bool "conflict" true node.conflict
  | None -> fail "current branch node missing"

let () =
  run "git_graph_snapshot"
    [ ( "snapshot"
      , [ test_case "json shape round trips" `Quick test_json_shape_round_trips
        ; test_case "commit/ref edges" `Quick test_commit_parent_and_ref_edges
        ; test_case "conflict status encoding" `Quick test_conflict_status_encoding
        ] )
    ]
