(** Tool_input_validation — Pre-dispatch validation via OAS Tool_middleware.

    Delegates to [Oas.Tool_middleware.make_validation_hook] for type
    coercion and structured error feedback.

    @since 2.220.0 — OAS delegation
    @since 2.221.0 — use Tool_middleware.make_validation_hook *)

(** Register input validation as a Tool_dispatch pre-hook.
    Must be called after all tool schemas are registered (server init).

    Tools without a registered schema are allowed through (permissive). *)
let normalize_transition_token (raw : string) : string =
  raw
  |> String.trim
  |> String.lowercase_ascii
  |> String.map (function
       | ' ' | '-' -> '_'
       | c -> c)

let canonical_transition_action_string (raw : string) : string option =
  match normalize_transition_token raw with
  | "claim" | "claimed" -> Some "claim"
  | "start" | "started" | "in_progress" | "inprogress" | "working" ->
      Some "start"
  | "done" | "complete" | "completed" | "finish" | "finished" ->
      Some "done"
  | "cancel" | "cancelled" | "canceled" -> Some "cancel"
  | "release" | "released" | "todo" | "pending" | "backlog" | "open"
    | "unclaimed" ->
      Some "release"
  | "submit_for_verification" | "awaiting_verification"
    | "needs_verification" | "verification_requested" ->
      Some "submit_for_verification"
  | "approve" | "approved" | "verified" -> Some "approve"
  | "reject" | "rejected" | "changes_requested" | "changesrequested" ->
      Some "reject"
  | _ -> None

let upsert_assoc key value fields =
  (key, value) :: List.remove_assoc key fields

let strip_internal_marker_args (args : Yojson.Safe.t) : Yojson.Safe.t =
  match args with
  | `Assoc fields ->
      `Assoc
        (List.filter
           (fun (key, _) -> String.length key = 0 || key.[0] <> '_')
           fields)
  | _ -> args

let normalize_transition_args (args : Yojson.Safe.t) : Yojson.Safe.t =
  match args with
  | `Assoc fields ->
      let action_override, consume_to =
        match List.assoc_opt "action" fields with
        | Some (`String raw) -> (
            match canonical_transition_action_string raw with
            | Some canonical when not (String.equal canonical raw) ->
                (Some (`String canonical), false)
            | _ -> (None, false))
        | Some _ -> (None, false)
        | None -> (
            match List.assoc_opt "to" fields with
            | Some (`String raw) -> (
                match canonical_transition_action_string raw with
                | Some canonical -> (Some (`String canonical), true)
                | None -> (None, false))
            | _ -> (None, false))
      in
      let notes_override, consume_note =
        if List.mem_assoc "notes" fields then
          (None, false)
        else
          match List.assoc_opt "note" fields with
          | Some (`String value) -> (Some (`String value), true)
          | _ -> (None, false)
      in
      if action_override = None && notes_override = None then
        args
      else
        let filtered =
          List.filter
            (fun (key, _) ->
              not
                ((consume_to && String.equal key "to")
                 || (consume_note && String.equal key "note")))
            fields
        in
        let with_action =
          match action_override with
          | Some value -> upsert_assoc "action" value filtered
          | None -> filtered
        in
        let with_notes =
          match notes_override with
          | Some value -> upsert_assoc "notes" value with_action
          | None -> with_action
        in
        `Assoc with_notes
  | _ -> args

(* #9785: OAS validation messages list missing required fields as
   `  "<field>": MISSING (required: <type>)`. When the LLM emitted a
   similarly-named key (e.g. sent "name" while the schema requires
   "tool_name"), surface the closest match so the next turn can self-
   correct in one shot. Pure string transformation over the OAS-emitted
   message — no OAS API change needed. *)
let missing_field_re =
  Re.Pcre.re {|"([^"]+)":\s*MISSING|} |> Re.compile

(* Substring containment in either direction is a strong signal for
   parameter-name confusion ("name" ⊂ "tool_name"). For short identifiers
   pure Jaccard underweights this case (tool_name ↔ name ≈ 0.36) so we
   blend the two with a containment bonus. *)
let string_contains haystack needle =
  let nlen = String.length needle in
  let hlen = String.length haystack in
  if nlen = 0 || nlen > hlen then false
  else
    let rec scan i =
      if i + nlen > hlen then false
      else if String.sub haystack i nlen = needle then true
      else scan (i + 1)
    in
    scan 0

let param_name_similarity a b =
  let la = String.lowercase_ascii a and lb = String.lowercase_ascii b in
  if la = lb then 1.0
  else if string_contains la lb || string_contains lb la then
    (* one contained in the other — very likely the LLM confusion case *)
    0.8
  else Text_similarity.jaccard_similarity a b

let augment_missing_param_hint ~(args : Yojson.Safe.t) (oas_message : string) =
  let arg_keys =
    match args with
    | `Assoc fields -> List.map fst fields
    | _ -> []
  in
  if arg_keys = [] then oas_message
  else
    let suggestions =
      Re.all missing_field_re oas_message
      |> List.filter_map (fun g ->
        let missing = Re.Group.get g 1 in
        if List.mem missing arg_keys then None
        else
          let scored =
            List.filter_map
              (fun k ->
                let s = param_name_similarity missing k in
                if s >= 0.4 then Some (s, k) else None)
              arg_keys
          in
          let sorted =
            List.sort (fun (a, _) (b, _) -> Float.compare b a) scored
          in
          match sorted with
          | (_, closest) :: _ ->
            Some
              (Printf.sprintf
                 "  hint: you sent \"%s\"; rename it to \"%s\""
                 closest missing)
          | [] -> None)
    in
    if suggestions = [] then oas_message
    else oas_message ^ "\n\nDid you mean:\n" ^ String.concat "\n" suggestions

let register_pre_hook () =
  let lookup name =
    Option.map
      (Oas.Tool_middleware.tool_schema_of_json ~name)
      (Tool_dispatch.lookup_schema name)
  in
  let hook = Oas.Tool_middleware.make_validation_hook ~lookup in
  Tool_dispatch.register_pre_hook (fun ~name ~args ->
    let compat_args =
      let args = strip_internal_marker_args args in
      if String.equal name "masc_transition" then
        normalize_transition_args args
      else
        args
    in
    match hook ~name ~args:compat_args with
    | Oas.Tool_middleware.Pass
      when not (Yojson.Safe.equal compat_args args) ->
      Log.debug "tool_input_validation coerced args for %s" name;
      Proceed compat_args
    | Oas.Tool_middleware.Pass -> Pass
    | Oas.Tool_middleware.Proceed coerced ->
      Log.debug "tool_input_validation coerced args for %s" name;
      Proceed coerced
    | Oas.Tool_middleware.Reject { message; _ } ->
      let augmented = augment_missing_param_hint ~args:compat_args message in
      Log.info "tool_input_validation rejected %s: %s" name augmented;
      Reject {
        Tool_result.success = false;
        data = `Assoc [
          ("error", `String augmented);
          ("validation", `String "oas_tool_middleware");
        ];
        tool_name = name;
        duration_ms = 0.0;
      })
