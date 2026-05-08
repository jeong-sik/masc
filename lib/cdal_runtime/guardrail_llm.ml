(** LLM-powered content guardrails via judge closure injection.

    @since 0.102.0 *)

open Types

type judge = string -> (bool * string, string) result

(* ── Text extraction helpers ─────────────────────────────────── *)

let messages_to_text (messages : message list) =
  List.filter_map
    (fun (msg : message) ->
       let texts =
         List.filter_map
           (function
             | Text s -> Some s
             | _ -> None)
           msg.content
       in
       match texts with
       | [] -> None
       | _ -> Some (String.concat "\n" texts))
    messages
  |> String.concat "\n\n"
;;

let response_to_text (resp : api_response) =
  List.filter_map
    (function
      | Text s -> Some s
      | _ -> None)
    resp.content
  |> String.concat "\n"
;;

(* ── Parse "PASS" / "FAIL: reason" format ────────────────────── *)

let parse_judge_response text =
  let trimmed = String.trim text in
  if String.uppercase_ascii trimmed = "PASS"
  then Ok (true, "pass")
  else (
    let prefix = "FAIL" in
    let plen = String.length prefix in
    if
      String.length trimmed >= plen
      && String.uppercase_ascii (String.sub trimmed 0 plen) = prefix
    then (
      let reason =
        if String.length trimmed > plen + 1
        then
          String.trim (String.sub trimmed (plen + 1) (String.length trimmed - plen - 1))
          |> fun s ->
          if String.length s > 0 && s.[0] = ':'
          then String.trim (String.sub s 1 (String.length s - 1))
          else s
        else "policy violation"
      in
      Ok (false, reason))
    else Error (Printf.sprintf "unexpected judge response: %S" trimmed))
;;

(* ── Validator constructors ──────────────────────────────────── *)

let make_input_validator ~name ~policy_prompt ~judge : Guardrails_async.input_validator =
  { name
  ; validate =
      (fun messages ->
        let content = messages_to_text messages in
        let prompt = policy_prompt ^ "\n\n---\nContent to evaluate:\n" ^ content in
        match judge prompt with
        | Error reason -> Error (Printf.sprintf "judge error: %s" reason)
        | Ok (true, _) -> Ok ()
        | Ok (false, reason) -> Error reason)
  }
;;

let make_output_validator ~name ~policy_prompt ~judge : Guardrails_async.output_validator =
  { name
  ; validate =
      (fun response ->
        let content = response_to_text response in
        let prompt = policy_prompt ^ "\n\n---\nContent to evaluate:\n" ^ content in
        match judge prompt with
        | Error reason -> Error (Printf.sprintf "judge error: %s" reason)
        | Ok (true, _) -> Ok ()
        | Ok (false, reason) -> Error reason)
  }
;;

[@@@coverage off]
(* === Inline tests === *)

let%test "parse_judge_response PASS" = parse_judge_response "PASS" = Ok (true, "pass")

let%test "parse_judge_response pass lowercase" =
  parse_judge_response "pass" = Ok (true, "pass")
;;

let%test "parse_judge_response PASS with whitespace" =
  parse_judge_response "  PASS  " = Ok (true, "pass")
;;

let%test "parse_judge_response FAIL with reason" =
  match parse_judge_response "FAIL: contains PII" with
  | Ok (false, reason) -> reason = "contains PII"
  | _ -> false
;;

let%test "parse_judge_response FAIL no reason" =
  match parse_judge_response "FAIL" with
  | Ok (false, reason) -> reason = "policy violation"
  | _ -> false
;;

let%test "parse_judge_response unexpected" =
  match parse_judge_response "MAYBE" with
  | Error _ -> true
  | _ -> false
;;

let%test "messages_to_text extracts text blocks" =
  let msgs =
    [ { role = User
      ; content = [ Text "hello" ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ; { role = Assistant
      ; content = [ Text "world" ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ]
  in
  messages_to_text msgs = "hello\n\nworld"
;;

let%test "response_to_text extracts text" =
  let resp =
    { id = ""
    ; model = ""
    ; stop_reason = EndTurn
    ; content = [ Text "line1"; Text "line2" ]
    ; usage = None
    ; telemetry = None
    }
  in
  response_to_text resp = "line1\nline2"
;;
