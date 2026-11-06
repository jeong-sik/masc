(** #10297 — pin the dispatcher's identity-enforcement contract for
    [masc_board_post] / [masc_board_comment] /
    [masc_board_vote] / [masc_board_comment_vote].

    Pre-fix [ensure_board_post_author] only consulted the runtime
    contract's [agent_name] when the caller's [author] argument was
    blank.  Any non-blank caller-supplied [author] passed through
    canonicalisation without comparison, so an LLM running as
    keeper [xi-hammer] could write [author = "delta"] and
    impersonate a different principal on the public board.
    Board comment/vote paths also lacked an [agent_name] comparison
    point, so they could not have caught spoofing either.

    These tests pin the unified [enforce_caller_identity]
    contract — the 3-branch SSOT pattern from
    feedback memory [mcp-dispatcher-ctx-agent-name-ssot]:

    1. Empty / "anonymous" caller field → fill from ctx.
    2. Caller's field equals ctx → keep it as it stands.
    3. Caller's field disagrees with ctx → REWRITE to
       ctx, preserve the caller's claim under
       [meta.<field>_caller_claim] for forensics, and increment
       [masc_board_actor_identity_spoof_total{tool, field}]. *)

open Alcotest

module D = Masc.Mcp_tool_runtime_board
module Metrics = Masc.Otel_metric_store

(* --- helpers ----------------------------------------------------- *)

let json_field name = function
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None

let json_string_field name json =
  match json_field name json with
  | Some (`String value) -> Some value
  | _ -> None

let meta_string_field name = function
  | `Assoc fields -> (
      match List.assoc_opt "meta" fields with
      | Some (`Assoc meta_fields) -> (
          match List.assoc_opt name meta_fields with
          | Some (`String value) -> Some value
          | _ -> None)
      | _ -> None)
  | _ -> None

let counter_for ~tool ~field =
  Metrics.metric_value_or_zero
    "masc_board_actor_identity_spoof_total"
    ~labels:[ ("tool", tool); ("field", field) ]
    ()

let assoc fields = `Assoc fields

(* --- 1. blank field fills from ctx ------------------------------ *)

let test_blank_field_fills_from_ctx () =
  let result =
    D.enforce_caller_identity ~tool:"masc_board_post" ~field:"author"
      ~agent_name:"xi-hammer"
      (assoc [ ("body", `String "hi") ])
  in
  check (option string)
    "blank author rewritten to ctx"
    (Some "xi-hammer")
    (json_string_field "author" result);
  check (option string)
    "no caller_claim recorded for blank source"
    None
    (meta_string_field "author_caller_claim" result)

let test_anonymous_field_fills_from_ctx () =
  let result =
    D.enforce_caller_identity ~tool:"masc_board_post" ~field:"author"
      ~agent_name:"xi-hammer"
      (assoc [ ("author", `String "anonymous"); ("body", `String "hi") ])
  in
  check (option string)
    "anonymous author rewritten to ctx"
    (Some "xi-hammer")
    (json_string_field "author" result);
  check (option string)
    "no caller_claim recorded for anonymous source"
    None
    (meta_string_field "author_caller_claim" result)

(* --- 2. caller claim matches ctx --------------------------- *)

(* Names reach this gate from HTTP bodies and auth contexts, so stray
   whitespace on either side must not read as a different principal. *)
let test_padded_names_compare_trimmed () =
  let before = counter_for ~tool:"masc_board_post" ~field:"author" in
  let result =
    D.enforce_caller_identity ~tool:"masc_board_post" ~field:"author"
      ~agent_name:"  xi-hammer "
      (assoc [ ("author", `String " xi-hammer") ])
  in
  check (option string)
    "the stored author is the trimmed name"
    (Some "xi-hammer")
    (json_string_field "author" result);
  check (option string)
    "padding is not a spoof"
    None
    (meta_string_field "author_caller_claim" result);
  check (float 0.0001)
    "no spoof counter for padding"
    before
    (counter_for ~tool:"masc_board_post" ~field:"author")

let test_blank_claim_without_ctx_is_untouched () =
  let args = assoc [ ("author", `String "  ") ] in
  let result =
    D.enforce_caller_identity ~tool:"masc_board_post" ~field:"author"
      ~agent_name:"" args
  in
  check string "arguments returned as they came"
    (Yojson.Safe.to_string args)
    (Yojson.Safe.to_string result)

(* --- 5. empty ctx is a no-op (defensive) ------------------------ *)

let test_empty_ctx_reaches_no_verdict () =
  (* If [agent_name] is somehow empty (HTTP path with no auth, test
     fixture without ctx), there is no trusted identity to compare
     against.  The same [author] that would be rewritten and counted
     as a spoof under a ctx must instead be left exactly as it came,
     and must not move the counter: no ctx, no verdict. *)
  let before = counter_for ~tool:"masc_board_post" ~field:"author" in
  let result =
    D.enforce_caller_identity ~tool:"masc_board_post" ~field:"author"
      ~agent_name:""
      (assoc [ ("author", `String "delta") ])
  in
  check (option string)
    "caller's author survives an absent ctx"
    (Some "delta")
    (json_string_field "author" result);
  check (option string)
    "nothing is claimed on the caller's behalf"
    None
    (meta_string_field "author_caller_claim" result);
  check (float 0.0001)
    "an absent ctx cannot call anything a spoof"
    before
    (counter_for ~tool:"masc_board_post" ~field:"author")

(* --- 6. dispatch binds what the generated registry declares ------ *)

let test_bind_covers_every_declared_field () =
  (* The MCP path used to carry its own copy of the field list as a match
     on tool-name strings ending in [_ -> arguments] (#34157). Now it reads
     the same generated registry the Keeper path reads, so every declared
     field of every board tool is bound, and a tool that declares none is
     left byte-identical. *)
  List.iter
    (fun board ->
      let name = Tool_name.Board_name.to_string board in
      let fields = Board_tool_registry.identity_fields_for_board_name board in
      let spoofed =
        assoc
          (("body", `String "hi")
          :: List.map (fun field -> (field, `String "delta")) fields)
      in
      let bound =
        D.bind_caller_identity ~name ~agent_name:"xi-hammer" spoofed
      in
      List.iter
        (fun field ->
          check (option string)
            (Printf.sprintf "%s.%s bound to the caller" name field)
            (Some "xi-hammer")
            (json_string_field field bound))
        fields;
      if fields = [] then
        check string
          (Printf.sprintf "%s declares no identity field and is untouched" name)
          (Yojson.Safe.to_string spoofed)
          (Yojson.Safe.to_string bound))
    Tool_name.Board_name.all

let test_bind_leaves_non_board_tools_alone () =
  let args = assoc [ ("author", `String "delta") ] in
  let bound =
    D.bind_caller_identity ~name:"masc_status" ~agent_name:"xi-hammer" args
  in
  check string "non-board tool arguments unchanged"
    (Yojson.Safe.to_string args)
    (Yojson.Safe.to_string bound)

let () =
  run "board_author_identity_10297"
    [
      ( "blank-fills-from-ctx",
        [
          test_case "blank author -> ctx" `Quick
            test_blank_field_fills_from_ctx;
          test_case "anonymous author -> ctx" `Quick
            test_anonymous_field_fills_from_ctx;
        ] );
      ( "matching-claim",
        [
          test_case "padded names compare trimmed" `Quick
            test_padded_names_compare_trimmed;
          test_case "blank claim without ctx is untouched" `Quick
            test_blank_claim_without_ctx_is_untouched;
        ] );
      ( "empty-ctx",
        [
          test_case "empty ctx reaches no verdict" `Quick
            test_empty_ctx_reaches_no_verdict;
        ] );
      ( "registry-driven-binding",
        [
          test_case "every declared field of every board tool is bound" `Quick
            test_bind_covers_every_declared_field;
          test_case "a non-board tool is left alone" `Quick
            test_bind_leaves_non_board_tools_alone;
        ] );
    ]
