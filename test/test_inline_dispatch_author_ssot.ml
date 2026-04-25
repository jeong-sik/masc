(** Identity SSOT for [keeper_board_post] dispatcher.

    Regression for masc-mcp #10297: a non-empty caller-supplied [author]
    must not bypass [ctx.agent_name].  When the two disagree (after
    canonicalisation), the dispatcher rewrites [author] to the trusted
    ctx name and preserves the LLM's claim under
    [meta.author_claim_overridden]. *)

open Alcotest

let canonical = Server_utils.board_actor_author_for_write

let lookup_string fields key =
  match List.assoc_opt key fields with
  | Some (`String s) -> Some s
  | _ -> None

let lookup_meta_string fields key =
  match List.assoc_opt "_meta" fields with
  | Some (`Assoc meta) -> lookup_string meta key
  | _ -> None

let dispatch_author ~ctx ~caller_author =
  let args =
    match caller_author with
    | None -> `Assoc [ ("body", `String "test") ]
    | Some a ->
        `Assoc [ ("body", `String "test"); ("author", `String a) ]
  in
  match Tool_inline_dispatch_extra.ensure_board_post_author ~agent_name:ctx args with
  | `Assoc fields -> fields
  | _ -> failwith "expected `Assoc"

let test_blank_author_uses_ctx () =
  let ctx = "keeper-velvet-hammer-agent" in
  let fields = dispatch_author ~ctx ~caller_author:None in
  check (option string) "author = canonical(ctx)"
    (Some (canonical ctx))
    (lookup_string fields "author");
  check (option string) "no override claim recorded"
    None
    (lookup_meta_string fields "author_claim_overridden")

let test_anonymous_author_uses_ctx () =
  let ctx = "keeper-velvet-hammer-agent" in
  let fields = dispatch_author ~ctx ~caller_author:(Some "anonymous") in
  check (option string) "author = canonical(ctx)"
    (Some (canonical ctx))
    (lookup_string fields "author");
  check (option string) "no override claim for anonymous"
    None
    (lookup_meta_string fields "author_claim_overridden")

let test_matching_canonical_author_kept () =
  (* LLM names itself with the same canonical identity (just a different raw
     form) — keep its choice and record the raw form for forensics. *)
  let ctx = "keeper-velvet-hammer-agent" in
  let fields = dispatch_author ~ctx ~caller_author:(Some "velvet-hammer") in
  check (option string) "author = canonical (matches ctx canonical)"
    (Some (canonical ctx))
    (lookup_string fields "author");
  check (option string) "no override claim when canonicals match"
    None
    (lookup_meta_string fields "author_claim_overridden")

let test_foreign_author_rewritten_to_ctx () =
  (* The bug: velvet-hammer claimed [author = "analyst"]. The dispatcher
     must reject the claim and rewrite to the trusted ctx. *)
  let ctx = "keeper-velvet-hammer-agent" in
  let fields = dispatch_author ~ctx ~caller_author:(Some "analyst") in
  check (option string) "author rewritten to canonical(ctx)"
    (Some (canonical ctx))
    (lookup_string fields "author");
  check (option string) "LLM claim preserved in meta"
    (Some "analyst")
    (lookup_meta_string fields "author_claim_overridden")

let test_empty_ctx_keeps_caller_value () =
  (* Defensive: if ctx is somehow empty (no agent_name), fall through to
     the caller-supplied value rather than producing a blank author.
     This preserves prior behaviour for HTTP surfaces that authenticate
     via tokens not yet bound to a keeper identity. *)
  let fields = dispatch_author ~ctx:"" ~caller_author:(Some "analyst") in
  check (option string) "caller value retained when ctx blank"
    (Some "analyst")
    (lookup_string fields "author")

let () =
  run "inline_dispatch_author_ssot"
    [
      ("ensure_board_post_author", [
           test_case "blank author falls back to ctx" `Quick
             test_blank_author_uses_ctx;
           test_case "anonymous author falls back to ctx" `Quick
             test_anonymous_author_uses_ctx;
           test_case "matching canonical author is kept" `Quick
             test_matching_canonical_author_kept;
           test_case "foreign author is rewritten to ctx and claim preserved"
             `Quick test_foreign_author_rewritten_to_ctx;
           test_case "empty ctx leaves caller value alone" `Quick
             test_empty_ctx_keeps_caller_value;
         ]);
    ]
