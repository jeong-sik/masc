(** Gh_capability_policy contract (RFC-0309 §3.3, W2).

    Pins the capability disposition for representative gh verbs. This is the
    executable specification W3 (approval routing) and W4 (repo-create/discussion
    enablement) implement against. It records BOTH the current disposition and,
    in comments, the W4 target where the two differ because PR #23362 still
    places repo-create/discussion in the irreversible risk table.

    Two properties an inert spec must keep honest:
    - the externality axis ([creates_durable_remote_surface]) is exactly
      {Repo, Discussion};
    - no verb is silently [Allowed] that the RFC intends to gate — unrecognized
      verbs are [Requires_approval]. *)

module Gh_verb = Masc_exec.Gh_verb
module Pol = Masc_exec.Gh_capability_policy
module Exec_program = Masc_exec.Exec_program
module Sandbox_target = Masc_exec.Sandbox_target
module Shell_ir = Masc_exec.Shell_ir

let verb ~sub ?act () = Gh_verb.of_fields ~subcommand:sub ~action:act

let dstr = Pol.string_of_disposition

let check label v expected =
  let actual = Pol.disposition_of v in
  if actual <> expected then
    Alcotest.failf "%s: disposition %s, expected %s" label (dstr actual)
      (dstr expected)
;;

(* --- externality axis (G-4): per-action durable-remote (W3 refinement) ---- *)
let test_durable_remote_surface () =
  (* mutating actions on a durable-remote family -> true *)
  let yes =
    [ ("repo", "create"); ("repo", "fork"); ("repo", "edit"); ("repo", "sync")
    ; ("repo", "rename"); ("discussion", "create"); ("discussion", "comment")
    ; ("discussion", "edit"); ("discussion", "delete") ]
  in
  (* local / read actions on the SAME families, and any non-durable family,
     and bare invocations -> false *)
  let no =
    [ ("repo", "clone"); ("repo", "view"); ("repo", "list")
    ; ("discussion", "view"); ("discussion", "list")
    ; ("pr", "merge"); ("issue", "create"); ("release", "create")
    ; ("api", "graphql"); ("frobnicate", "now") ]
  in
  List.iter
    (fun (sub, act) ->
       let v = verb ~sub ~act () in
       if not (Pol.creates_durable_remote_surface v) then
         Alcotest.failf "gh %s %s should be durable-remote" sub act)
    yes;
  List.iter
    (fun (sub, act) ->
       let v = verb ~sub ~act () in
       if Pol.creates_durable_remote_surface v then
         Alcotest.failf "gh %s %s should NOT be durable-remote" sub act)
    no;
  (* bare families (no action) are reads -> false *)
  if Pol.creates_durable_remote_surface (verb ~sub:"repo" ()) then
    Alcotest.fail "bare 'gh repo' should NOT be durable-remote"
;;

(* --- current dispositions (with #23362 tables in force) ------------------- *)
let test_current_dispositions () =
  (* reads: Allowed *)
  check "pr view" (verb ~sub:"pr" ~act:"view" ()) Pol.Allowed;
  check "repo view" (verb ~sub:"repo" ~act:"view" ()) Pol.Allowed;
  check "discussion view" (verb ~sub:"discussion" ~act:"view" ()) Pol.Allowed;
  check "api graphql" (verb ~sub:"api" ~act:"graphql" ()) Pol.Allowed;
  (* local / in-repo reversible mutations: Allowed *)
  check "pr create" (verb ~sub:"pr" ~act:"create" ()) Pol.Allowed;
  check "pr comment" (verb ~sub:"pr" ~act:"comment" ()) Pol.Allowed;
  check "issue create" (verb ~sub:"issue" ~act:"create" ()) Pol.Allowed;
  check "release create" (verb ~sub:"release" ~act:"create" ()) Pol.Allowed;
  (* genuinely irreversible (also risk-floored): Denied *)
  check "pr merge" (verb ~sub:"pr" ~act:"merge" ()) Pol.Denied;
  check "repo delete" (verb ~sub:"repo" ~act:"delete" ()) Pol.Denied;
  check "discussion delete" (verb ~sub:"discussion" ~act:"delete" ()) Pol.Denied;
  (* W4/G-9 ENABLED: repo-create / discussion-create are now R1 (reversible) +
     durable-remote -> Requires_approval. Was Denied under #23362; the risk axis
     no longer lies about reversibility and the capability axis carries the
     decision. This is the active-keeper enablement. *)
  check "repo create -> Requires_approval" (verb ~sub:"repo" ~act:"create" ())
    Pol.Requires_approval;
  check "repo fork -> Requires_approval" (verb ~sub:"repo" ~act:"fork" ())
    Pol.Requires_approval;
  check "discussion create -> Requires_approval"
    (verb ~sub:"discussion" ~act:"create" ()) Pol.Requires_approval;
  check "discussion comment -> Requires_approval"
    (verb ~sub:"discussion" ~act:"comment" ()) Pol.Requires_approval;
  (* durable-remote R1 mutation -> Requires_approval *)
  check "repo edit" (verb ~sub:"repo" ~act:"edit" ()) Pol.Requires_approval;
  check "repo sync" (verb ~sub:"repo" ~act:"sync" ()) Pol.Requires_approval;
  (* W3 per-action refinement: repo clone is a LOCAL op (copies to disk), not a
     durable-remote mutation, so it stays Allowed — no over-approval of routine
     work. *)
  check "repo clone (local -> Allowed)" (verb ~sub:"repo" ~act:"clone" ())
    Pol.Allowed;
  (* unrecognized top-level area: a human adjudicates *)
  check "unknown verb" (verb ~sub:"frobnicate" ~act:"now" ()) Pol.Requires_approval;
  (* GAP CLOSED: an unrecognized action on a known mutating-capable family no
     longer auto-runs as a read — it asks. (Was Allowed while the gap was open.) *)
  check "unknown action in known family -> Requires_approval"
    (verb ~sub:"repo" ~act:"upsert-magic" ()) Pol.Requires_approval;
  check "unknown action under pr -> Requires_approval"
    (verb ~sub:"pr" ~act:"teleport" ()) Pol.Requires_approval;
  (* Known reads on the same families stay Allowed — no over-block of routine
     work. This is the reads-set guard that keeps the gap fix from flooring
     legitimate reads. *)
  check "repo view (known read)" (verb ~sub:"repo" ~act:"view" ()) Pol.Allowed;
  check "pr diff (known read)" (verb ~sub:"pr" ~act:"diff" ()) Pol.Allowed;
  check "pr checks (known read)" (verb ~sub:"pr" ~act:"checks" ()) Pol.Allowed;
  check "run list (known read)" (verb ~sub:"run" ~act:"list" ()) Pol.Allowed
;;

(* --- W4 axis symmetry: string-borne graphql vs typed (disposition_of_words) --
   [gh api graphql ...] lowers to the body-blind [Gh_verb.Api]; [disposition_of]
   alone would [Allow] a durable-remote create because it cannot see the body.
   [disposition_of_words] inspects the parsed graphql body so the string form
   matches the typed [gh repo create] -> Requires_approval decision. *)
let graphql_words body =
  [ "gh"; "api"; "graphql"; "-f"; "query=" ^ body ]

let lit s = Shell_ir.Lit (s, Shell_ir.default_meta)
let var s = Shell_ir.Var (s, Shell_ir.default_meta)
let concat parts = Shell_ir.Concat parts

let gh_bin =
  match Exec_program.of_string "gh" with
  | Ok bin -> bin
  | Error _ -> assert false

let gh_simple args : Shell_ir.simple =
  { bin = gh_bin
  ; args
  ; env = []
  ; cwd = None
  ; redirects = []
  ; sandbox = Sandbox_target.host ()
  }

let test_graphql_durable_remote_words () =
  let ask =
    [ ("createRepository", "mutation { createRepository(input:{name:\"x\"}){ repository { id } } }")
    ; ("createDiscussion", "mutation { createDiscussion(input:{title:\"t\"}){ discussion { id } } }")
    ; ("addDiscussionComment", "mutation { addDiscussionComment(input:{body:\"b\"}){ comment { id } } }")
    ]
  in
  (* graphql reads and non-durable mutations must NOT be over-approved *)
  let allow =
    [ ("query repo", "query { repository(owner:\"o\", name:\"r\"){ id } }")
    ; ("addComment (issue, not durable-remote)", "mutation { addComment(input:{body:\"b\"}){ clientMutationId } }")
    ]
  in
  List.iter
    (fun (label, body) ->
       let words = graphql_words body in
       let v = Gh_verb.classify words in
       let d = Pol.disposition_of_words words v in
       if d <> Pol.Requires_approval then
         Alcotest.failf "graphql %s: %s, expected requires_approval" label
           (dstr d))
    ask;
  List.iter
    (fun (label, body) ->
       let words = graphql_words body in
       let v = Gh_verb.classify words in
       let d = Pol.disposition_of_words words v in
       if d = Pol.Requires_approval then
         Alcotest.failf "graphql %s must not be over-approved (%s)" label (dstr d))
    allow;
  (* disposition_of_words agrees with disposition_of for every non-Api verb *)
  List.iter
    (fun (sub, act) ->
       let v = verb ~sub ~act () in
       let words = [ "gh"; sub; act ] in
       if Pol.disposition_of_words words v <> Pol.disposition_of v then
         Alcotest.failf "gh %s %s: disposition_of_words diverged from disposition_of"
           sub act)
    [ ("repo", "create"); ("repo", "view"); ("pr", "merge"); ("issue", "create") ]
;;

let test_graphql_opaque_query_simple () =
  let ask =
    [ ( "query=$MUTATION concat"
      , [ lit "api"; lit "graphql"; lit "-f"; concat [ lit "query="; var "MUTATION" ] ]
      )
    ; "opaque field", [ lit "api"; lit "graphql"; lit "-f"; var "FIELD" ]
    ; ( "attached query"
      , [ lit "api"; lit "graphql"; concat [ lit "--raw-field=query="; var "MUTATION" ] ]
      )
    ]
  in
  List.iter
    (fun (label, args) ->
       match Pol.disposition_of_simple (gh_simple args) with
       | Some Pol.Requires_approval -> ()
       | Some d ->
         Alcotest.failf "%s: expected requires_approval, got %s" label (dstr d)
       | None -> Alcotest.failf "%s: expected gh disposition" label)
    ask;
  match
    Pol.disposition_of_simple
      (gh_simple
         [ lit "api"
         ; lit "graphql"
         ; lit "-F"
         ; concat [ lit "owner="; var "OWNER" ]
         ; lit "-f"
         ; lit "query=query { viewer { login } }"
         ])
  with
  | Some Pol.Requires_approval ->
    Alcotest.fail "opaque non-query graphql variables must not require approval"
  | Some (Pol.Allowed | Pol.Denied) -> ()
  | None -> Alcotest.fail "expected gh disposition"
;;

let () =
  Alcotest.run "gh_capability_policy"
    [
      ( "capability",
        [
          Alcotest.test_case "durable-remote surface axis" `Quick
            test_durable_remote_surface;
          Alcotest.test_case "current dispositions" `Quick
            test_current_dispositions;
          Alcotest.test_case "graphql durable-remote (words)" `Quick
            test_graphql_durable_remote_words;
          Alcotest.test_case "graphql opaque query (simple)" `Quick
            test_graphql_opaque_query_simple;
        ] );
    ]
;;
