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
  (* irreversible (also risk-floored): Denied *)
  check "pr merge" (verb ~sub:"pr" ~act:"merge" ()) Pol.Denied;
  check "repo delete" (verb ~sub:"repo" ~act:"delete" ()) Pol.Denied;
  check "discussion delete" (verb ~sub:"discussion" ~act:"delete" ()) Pol.Denied;
  (* W4 target divergence: repo-create / discussion-create are Denied TODAY
     because #23362 keeps them in the irreversible risk table. W4/G-9 moves
     them to R1, at which point (durable-remote + R1) -> Requires_approval.
     Pinned as Denied here so the W4 table change produces a visible delta. *)
  check "repo create (W4->requires_approval)" (verb ~sub:"repo" ~act:"create" ())
    Pol.Denied;
  check "discussion create (W4->requires_approval)"
    (verb ~sub:"discussion" ~act:"create" ()) Pol.Denied;
  (* durable-remote R1 mutation -> Requires_approval *)
  check "repo edit" (verb ~sub:"repo" ~act:"edit" ()) Pol.Requires_approval;
  check "repo sync" (verb ~sub:"repo" ~act:"sync" ()) Pol.Requires_approval;
  (* W3 per-action refinement: repo clone is a LOCAL op (copies to disk), not a
     durable-remote mutation, so it stays Allowed — no over-approval of routine
     work. *)
  check "repo clone (local -> Allowed)" (verb ~sub:"repo" ~act:"clone" ())
    Pol.Allowed;
  (* unrecognized area: a human adjudicates *)
  check "unknown verb" (verb ~sub:"frobnicate" ~act:"now" ()) Pol.Requires_approval;
  check "unknown action in known family"
    (verb ~sub:"repo" ~act:"upsert-magic" ()) Pol.Allowed
    (* known family + table-absent action -> R0 (read) -> Allowed; the
       unknown-action gap is deferred to W3, same as the risk axis. *)
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
        ] );
    ]
;;
