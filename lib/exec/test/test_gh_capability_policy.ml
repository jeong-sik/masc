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

(* --- externality axis (G-4): exactly Repo + Discussion ------------------- *)
let test_durable_remote_surface () =
  let yes = [ Gh_verb.Repo; Gh_verb.Discussion ] in
  let no =
    [ Gh_verb.Pr; Gh_verb.Issue; Gh_verb.Release; Gh_verb.Secret
    ; Gh_verb.Ssh_key; Gh_verb.Workflow; Gh_verb.Auth; Gh_verb.Gist
    ; Gh_verb.Ruleset; Gh_verb.Label; Gh_verb.Run; Gh_verb.Cache
    ; Gh_verb.Project; Gh_verb.Api; Gh_verb.Other "x" ]
  in
  List.iter
    (fun f ->
       if not (Pol.creates_durable_remote_surface f) then
         Alcotest.failf "%s should be durable-remote" (Gh_verb.string_of_family f))
    yes;
  List.iter
    (fun f ->
       if Pol.creates_durable_remote_surface f then
         Alcotest.failf "%s should NOT be durable-remote"
           (Gh_verb.string_of_family f))
    no
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
  (* durable-remote R1 that already exists today -> Requires_approval. NOTE
     coarseness: this is family-level, so a local-only op like [repo clone]
     (R1, Repo) also lands here. W3 refines the externality to per-action; for
     an unenforced spec, conservative over-approval is safe. *)
  check "repo edit" (verb ~sub:"repo" ~act:"edit" ()) Pol.Requires_approval;
  check "repo clone (coarse: local op, refine in W3)"
    (verb ~sub:"repo" ~act:"clone" ()) Pol.Requires_approval;
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
