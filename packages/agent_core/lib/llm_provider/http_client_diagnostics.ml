(* Diagnostics for requests that a provider edge rejects without a cause.
   A 4xx answer with no readable cause leaves the request as the only
   evidence, so [profile_opaque_client_error] logs the request's header sizes
   and body shape. Header values and message text are never logged. *)

(* Empirically measured (2026-05-31) against RunPod's *.proxy.runpod.net edge:
   a single request header LINE >= 8192 bytes is rejected by the cloudflare edge
   with an opaque "400 Bad Request" (server: cloudflare, empty body, cf-ray)
   BEFORE the request reaches the origin. The binding limit is per-header-line,
   NOT the header total — 20 x 500B headers (10 KB total) passed, while one
   8192B header did not. Body size (up to 2 MB) and malformed header values did
   not reproduce it. *)
let cdn_per_header_limit_bytes = 8192

(* key + ": " + value + CRLF — the on-wire size of one header line. *)
let header_line_bytes (key, value) = String.length key + String.length value + 4

(* Request header size profile (name + on-wire bytes, largest first). VALUES ARE
   OMITTED: header values may carry credentials (Authorization, tokens), so only
   sizes are logged. *)
let header_size_profile headers =
  headers
  |> List.map (fun ((k, _) as h) -> k, header_line_bytes h)
  |> List.sort (fun (_, a) (_, b) -> compare b a)
  |> List.map (fun (k, n) -> `Assoc [ "name", `String k; "bytes", `Int n ])
;;

let max_single_header_bytes headers =
  List.fold_left (fun acc h -> max acc (header_line_bytes h)) 0 headers
;;

(* On a 4xx, the response body from a provider edge is frequently an opaque
   "Bad Request" with no field-level cause (observed 2026-07-18 against
   ollama.com/v1 deepseek-v4-flash: ~78% of turns rejected, empty-detail body).
   The request that provoked it is then lost, because [HttpError] only carries
   the RESPONSE body. This logs a STRUCTURAL profile of the REQUEST body so a
   recurring provider 4xx can be attributed to a request shape without a repro
   harness or a full-body dump.

   Only structural facts are emitted — field presence, counts, message role
   sequence, and enumerable option values (response_format type, reasoning
   effort). Prompt/message TEXT and tool argument values are never logged: they
   may carry user content and do not distinguish an accepted shape from a
   rejected one. A body that is not JSON is reported as such rather than
   parsed. *)
(* Exhaustive over the closed [Yojson.Safe.t] variant — no catch-all, so a
   future Yojson constructor forces a compile update rather than silently
   mislabelling. The label helpers take a [Yojson.Safe.t option] so an ABSENT
   top-level field is distinguished from a present field whose value is [`Null]
   or the wrong type: a missing field and a malformed field are separate
   diagnostic facts, and reporting one as the other makes the profile lie. *)
let string_field_label : Yojson.Safe.t option -> Yojson.Safe.t = function
  | None -> `String "<absent>"
  | Some (`String s) -> `String s
  | Some `Null -> `String "<null>"
  | Some (`Bool _ | `Int _ | `Intlit _ | `Float _ | `Assoc _ | `List _) ->
    `String "<non-string>"
;;

(* Tri-state length of an optional top-level list field. An empty list and an
   absent field are separate facts (a body with no [messages] key differs from
   one with [messages: []]); a present non-list value is a third. *)
let list_len_field_label : Yojson.Safe.t option -> Yojson.Safe.t = function
  | None -> `String "<absent>"
  | Some (`List xs) -> `Int (List.length xs)
  | Some (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _) ->
    `String "<non-list>"
;;

(* Some providers wrap every function declaration in a single top-level [tools]
   element (Gemini nests them under [functionDeclarations]), so [tool_count] is
   1 regardless of how many declarations it holds. Reveal the nested count
   generically: if the first [tools] element is an object with a list-valued
   field, report that list's length. No provider key is named — any object with
   an inner list qualifies; anything else is [<n/a>]. *)
let first_inner_list_len : Yojson.Safe.t option -> Yojson.Safe.t =
  let inner_len fields =
    List.find_map
      (function
        | _key, `List inner -> Some (List.length inner)
        | _key, (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _)
          -> None)
      fields
  in
  function
  | Some (`List (`Assoc first :: _)) ->
    (match inner_len first with
     | Some n -> `Int n
     | None -> `String "<n/a>")
  | Some (`List [])
  | Some
      (`List ((`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _) :: _))
  | Some (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _)
  | None -> `String "<n/a>"
;;

let json_is_present : Yojson.Safe.t -> bool = function
  | `Null -> false
  | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _ | `List _ -> true
;;

(* A rejected POST body can embed base64 media; parsing it whole on the 4xx
   failure path adds allocation and latency for no diagnostic gain. Above this
   size the parse is skipped and only the byte count is reported. 64 KiB holds a
   text-only chat request (messages, tools, options) while excluding
   media-laden bodies. *)
let max_profiled_body_bytes = 64 * 1024

let request_body_shape_profile (body : string) : Yojson.Safe.t =
  if String.length body > max_profiled_body_bytes
  then
    (* Oversized: skip the full parse. [parseable] is [false] because no parse
       was attempted; [skipped_oversized] records the reason so a consumer does
       not read it as a malformed body. *)
    `Assoc
      [ "parseable", `Bool false
      ; "body_bytes", `Int (String.length body)
      ; "skipped_oversized", `Bool true
      ]
  else (
    match Yojson.Safe.from_string body with
    | exception (Yojson.Json_error _ | Yojson.Safe.Util.Type_error _) ->
      `Assoc [ "parseable", `Bool false; "body_bytes", `Int (String.length body) ]
    | `Assoc fields ->
      let has key = List.mem_assoc key fields in
      (* [field] collapses absent-or-null; [List.assoc_opt] is used directly
         where absent must be told apart from present-null (see the label
         helpers above). *)
      let field key = if has key then List.assoc key fields else `Null in
      let messages_field = List.assoc_opt "messages" fields in
      let role_of_message : Yojson.Safe.t -> Yojson.Safe.t = function
        | `Assoc mfields ->
          (match List.assoc_opt "role" mfields with
           | Some (`String r) -> `String r
           | Some (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `Assoc _ | `List _)
             -> `String "<non-string-role>"
           | None -> `String "<no-role>")
        | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
          `String "<non-object>"
      in
      (* Roles are reported only when [messages] is a real list; an absent or
         non-list [messages] carries no role sequence to report. *)
      let message_roles_field =
        match messages_field with
        | Some (`List ms) -> [ "message_roles", `List (List.map role_of_message ms) ]
        | Some (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _)
        | None -> []
      in
      let response_format_type =
        match field "response_format" with
        | `Assoc rf ->
          (match List.assoc_opt "type" rf with
           | Some (`String t) -> `String t
           | Some (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `Assoc _ | `List _)
             -> `String "<non-string-type>"
           | None -> `String "<no-type>")
        | `Null -> `Null
        | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
          `String "<non-object>"
      in
      let stream =
        match field "stream" with
        | `Bool b -> `Bool b
        | `Null | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _ | `List _ -> `Null
      in
      (* [List.assoc]/[List.mem_assoc] keep only the first binding, so a body
         with duplicate top-level keys — itself a rejection class — would profile
         as if deduped. Report every key that occurs more than once. *)
      let duplicate_keys =
        let names = List.map fst fields in
        `List
          (List.filter_map
             (fun name ->
                let count = List.length (List.filter (String.equal name) names) in
                if count > 1
                then Some (`Assoc [ "name", `String name; "count", `Int count ])
                else None)
             (List.sort_uniq String.compare names))
      in
      (* Every top-level key NAME present, so a rejection caused by an
         unrecognised or misspelled field is diagnosable even though it is not
         one of the typed fields below. Key names are our own serialisation
         vocabulary (schema), not request TEXT, so this leaks no user content.
         Reporting the full key set also makes the profile schema-agnostic
         rather than a curated per-provider key list: the typed fields are
         richer detail on commonly-relevant keys, not the limit of what is
         seen. *)
      let top_level_keys =
        `List
          (List.map
             (fun name -> `String name)
             (List.sort_uniq String.compare (List.map fst fields)))
      in
      `Assoc
        ([ "parseable", `Bool true
         ; "body_bytes", `Int (String.length body)
         ; "top_level_keys", top_level_keys
         ; "model", string_field_label (List.assoc_opt "model" fields)
         ; "message_count", list_len_field_label messages_field
         ]
         @ message_roles_field
         @ [ "contents_count", list_len_field_label (List.assoc_opt "contents" fields)
           ; "input_count", list_len_field_label (List.assoc_opt "input" fields)
           ; "tool_count", list_len_field_label (List.assoc_opt "tools" fields)
           ; ( "tool_first_inner_count"
             , first_inner_list_len (List.assoc_opt "tools" fields) )
           ; "response_format_type", response_format_type
           ; ( "reasoning_effort"
             , string_field_label (List.assoc_opt "reasoning_effort" fields) )
           ; "thinking_present", `Bool (json_is_present (field "thinking"))
           ; "max_tokens_present", `Bool (has "max_tokens")
           ; "stream", stream
           ; "duplicate_keys", duplicate_keys
           ])
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
      `Assoc
        [ "parseable", `Bool true
        ; "body_bytes", `Int (String.length body)
        ; "top_level", `String "<non-object>"
        ])
;;

(* A 4xx whose body names its cause needs no request diagnostics: the body is
   the diagnosis, and [Retry.classify_error] carries it to the caller. This
   profile is for the other 4xx, where the request is the only evidence: an
   edge in front of the origin answering with an empty or non-JSON body
   (cloudflare in front of RunPod on a header line over
   [cdn_per_header_limit_bytes], 2026-05-31; ollama.com/v1 "Bad Request" with
   no detail, 2026-07-18). It names the header sizes (values omitted: they may
   carry credentials) and the request body's shape (message and tool-argument
   text omitted: it may carry user content and does not distinguish an
   accepted shape from a rejected one). Header contents are runtime-dependent,
   so this names the offending header when a real failure recurs rather than
   guessing a size before send.

   Firing on every 4xx put two WARN lines and a fixed explanation paragraph
   under each rate limit, a 429 saying "weekly usage limit" in its own body
   (2026-09-09), which repeated what the body already said. The gate is the
   body, not the status: a 429 with an empty body still profiles, a 400 with a
   structured message does not. A 4xx whose body cannot be read at all (over
   [Api_common.max_response_body], or the transport dropped mid-body) leaves
   no profile: that failure is reported on its own path, and without the body
   there is nothing to gate on. *)
let response_body_is_opaque response_body =
  Option.is_none (Api_common.error_message_of_body response_body)
;;

let profile_opaque_client_error
      ~url
      ~code
      ~resp_headers
      ~request_headers
      ~request_body
      ~response_body
  =
  if code >= 400 && code < 500 && response_body_is_opaque response_body
  then (
    let opt = function
      | Some s -> `String s
      | None -> `Null
    in
    let total =
      List.fold_left (fun acc h -> acc + header_line_bytes h) 0 request_headers
    in
    let json =
      `Assoc
        [ "event", `String "http_client_4xx_opaque_response"
        ; "url", `String url
        ; "status", `Int code
        ; "response_server", opt (Http.Header.get resp_headers "server")
        ; "cf_ray", opt (Http.Header.get resp_headers "cf-ray")
        ; "response_body_bytes", `Int (String.length response_body)
        ; "request_header_count", `Int (List.length request_headers)
        ; "total_request_header_bytes", `Int total
        ; "max_single_header_bytes", `Int (max_single_header_bytes request_headers)
        ; "cdn_per_header_limit_bytes", `Int cdn_per_header_limit_bytes
        ; "header_sizes", `List (header_size_profile request_headers)
        ; "request_shape", request_body_shape_profile request_body
        ]
    in
    Diag.warn "http_client" "%s" (Yojson.Safe.to_string json))
;;

let%test_module "profile_opaque_client_error" =
  (module struct
    (* [Yojson.Safe.to_string] keeps field order, so the event name is the
       line's prefix; no substring search is needed to recognise it. *)
    let event_prefix = {|{"event":"http_client_4xx_opaque_response"|}

    let profiles_emitted ~code ~response_body =
      let captured = ref [] in
      Diag.with_sink
        (fun _level ~ctx:_ message -> captured := message :: !captured)
        (fun () ->
           profile_opaque_client_error
             ~url:"https://example.test/v1/chat/completions"
             ~code
             ~resp_headers:(Http.Header.of_list [ "server", "cloudflare" ])
             ~request_headers:
               [ "authorization", "Bearer x"; "content-type", "application/json" ]
             ~request_body:{|{"model":"m","messages":[]}|}
             ~response_body);
      List.length
        (List.filter (String.starts_with ~prefix:event_prefix) !captured)
    ;;

    let%test "a 429 whose body names the limit is not profiled" =
      profiles_emitted
        ~code:429
        ~response_body:{|{"error":"Rate limited: weekly usage limit reached"}|}
      = 0
    ;;

    let%test "a 400 with a nested error message is not profiled" =
      profiles_emitted
        ~code:400
        ~response_body:{|{"error":{"message":"invalid tool schema","code":400}}|}
      = 0
    ;;

    let%test "an empty-body 400 is profiled once" =
      profiles_emitted ~code:400 ~response_body:"" = 1
    ;;

    let%test "a non-JSON 400 body is profiled once" =
      profiles_emitted ~code:400 ~response_body:"Bad Request" = 1
    ;;

    let%test "an empty-body 429 is still profiled: the gate is the body" =
      profiles_emitted ~code:429 ~response_body:"" = 1
    ;;

    let%test "JSON without an error key is opaque" =
      profiles_emitted ~code:400 ~response_body:{|{"detail":null}|} = 1
    ;;

    let%test "a blank error message names no cause and is profiled" =
      profiles_emitted ~code:400 ~response_body:{|{"error":""}|} = 1
      && profiles_emitted ~code:400 ~response_body:{|{"error":{"message":" "}}|} = 1
    ;;

    let%test "a 5xx is never profiled" = profiles_emitted ~code:502 ~response_body:"" = 0
    let%test "a 2xx is never profiled" = profiles_emitted ~code:200 ~response_body:"" = 0
  end)
;;

let%test "request_body_shape_profile reports non-json bodies without raising" =
  (* Result is always an [`Assoc]; [member] yields [`Null] for a missing key,
     so no catch-all is needed to read a field. *)
  Yojson.Safe.Util.member "parseable" (request_body_shape_profile "Bad Request")
  = `Bool false
;;

let%test "request_body_shape_profile extracts shape without message text" =
  let body =
    {|{"model":"deepseek-v4-flash","messages":[{"role":"system","content":"secret prompt"},{"role":"user","content":"private"}],"tools":[{"type":"function"}],"response_format":{"type":"json_schema"},"reasoning_effort":"high","thinking":{"type":"enabled"}}|}
  in
  let profile = request_body_shape_profile body in
  let s = Yojson.Safe.to_string profile in
  let contains ~needle haystack =
    let nl = String.length needle
    and hl = String.length haystack in
    let rec loop i =
      if i + nl > hl
      then false
      else if String.sub haystack i nl = needle
      then true
      else loop (i + 1)
    in
    nl = 0 || loop 0
  in
  let field key = Yojson.Safe.Util.member key profile in
  (* structural facts present, message content absent *)
  field "model" = `String "deepseek-v4-flash"
  && field "message_count" = `Int 2
  && field "response_format_type" = `String "json_schema"
  && field "reasoning_effort" = `String "high"
  && field "thinking_present" = `Bool true
  && field "max_tokens_present" = `Bool false
  && (not (contains ~needle:"secret prompt" s))
  && not (contains ~needle:"private" s)
;;

(* The profile reports EVERY top-level key by NAME, so a 4xx caused by an
   unrecognised or misspelled field is diagnosable even though that field is not
   one of the typed fields. Key names are our own serialisation vocabulary
   (schema), not request TEXT, so no value or user content leaks through them. *)
let%test "shape profile surfaces unrecognised top-level keys without their values" =
  let body =
    {|{"model":"m","messages":[{"role":"user","content":"private"}],"unexpected_knob":"leak-me","typo_max_tokens":4}|}
  in
  let profile = request_body_shape_profile body in
  let s = Yojson.Safe.to_string profile in
  let contains ~needle haystack =
    let nl = String.length needle
    and hl = String.length haystack in
    let rec loop i =
      if i + nl > hl
      then false
      else if String.sub haystack i nl = needle
      then true
      else loop (i + 1)
    in
    nl = 0 || loop 0
  in
  let keys =
    match Yojson.Safe.Util.member "top_level_keys" profile with
    | `List xs ->
      List.filter_map
        (function
          | `String s -> Some s
          | _ -> None)
        xs
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _ -> []
  in
  let has_key k = List.mem k keys in
  (* unrecognised keys are visible by NAME ... *)
  has_key "unexpected_knob"
  && has_key "typo_max_tokens"
  && has_key "model"
  && has_key "messages"
  (* ... but their VALUES are not echoed, and message content stays absent *)
  && (not (contains ~needle:"leak-me" s))
  && not (contains ~needle:"private" s)
;;

(* Finding 1: an absent field, a present-null field, and a present-non-string
   field are three distinct facts — the profile must not report an absent field
   as a malformed one. *)
let%test "shape profile distinguishes absent from malformed string fields" =
  let m key j = Yojson.Safe.Util.member key j in
  let absent = request_body_shape_profile {|{"model":"m"}|} in
  let present_null = request_body_shape_profile {|{"reasoning_effort":null}|} in
  let present_int = request_body_shape_profile {|{"reasoning_effort":3}|} in
  m "reasoning_effort" absent = `String "<absent>"
  && m "reasoning_effort" present_null = `String "<null>"
  && m "reasoning_effort" present_int = `String "<non-string>"
  && m "model" absent = `String "m"
  && m "model" present_null = `String "<absent>"
;;

(* Finding 2: absent messages / non-list messages must not both read as an empty
   array; roles are attached only for a real list. *)
let%test "shape profile reports messages presence honestly" =
  let m key j = Yojson.Safe.Util.member key j in
  let absent = request_body_shape_profile {|{"model":"m"}|} in
  let empty = request_body_shape_profile {|{"messages":[]}|} in
  let non_list = request_body_shape_profile {|{"messages":"oops"}|} in
  m "message_count" absent = `String "<absent>"
  && m "message_count" empty = `Int 0
  && m "message_count" non_list = `String "<non-list>"
  && m "message_roles" empty = `List []
  && m "message_roles" absent = `Null (* key omitted -> member is `Null *)
  && m "message_roles" non_list = `Null
;;

(* Finding 3: non-chat containers ([contents] for Gemini, [input] for OpenAI
   Responses) are reported with the same tri-state as [messages]. *)
let%test "shape profile reports contents and input container counts" =
  let m key j = Yojson.Safe.Util.member key j in
  let gemini =
    request_body_shape_profile {|{"contents":[{"role":"user"},{"role":"model"}]}|}
  in
  let responses = request_body_shape_profile {|{"input":[{"type":"message"}]}|} in
  let neither = request_body_shape_profile {|{"model":"m"}|} in
  m "contents_count" gemini = `Int 2
  && m "input_count" gemini = `String "<absent>"
  && m "input_count" responses = `Int 1
  && m "contents_count" neither = `String "<absent>"
  && m "contents_count" responses = `String "<absent>"
;;

(* Finding 4: Gemini wraps all declarations in one top-level [tools] element, so
   [tool_count] is 1; the nested list length is surfaced generically. *)
let%test "shape profile reveals nested function-declaration count" =
  let m key j = Yojson.Safe.Util.member key j in
  let gemini =
    request_body_shape_profile
      {|{"tools":[{"functionDeclarations":[{"name":"a"},{"name":"b"},{"name":"c"}]}]}|}
  in
  let flat = request_body_shape_profile {|{"tools":[{"type":"function"}]}|} in
  let none = request_body_shape_profile {|{"model":"m"}|} in
  m "tool_count" gemini = `Int 1
  && m "tool_first_inner_count" gemini = `Int 3
  && m "tool_first_inner_count" flat = `String "<n/a>"
  && m "tool_count" none = `String "<absent>"
  && m "tool_first_inner_count" none = `String "<n/a>"
;;

(* Finding 5: bodies over [max_profiled_body_bytes] skip the full parse. *)
let%test "shape profile skips parsing oversized bodies" =
  let big = {|{"x":"|} ^ String.make (max_profiled_body_bytes + 1) 'a' ^ {|"}|} in
  let profile = request_body_shape_profile big in
  let m key = Yojson.Safe.Util.member key profile in
  m "skipped_oversized" = `Bool true
  && m "parseable" = `Bool false
  && m "body_bytes" = `Int (String.length big)
;;

(* Finding 6: duplicate top-level keys (a rejection class) are surfaced with
   their occurrence count instead of being silently deduped. *)
let%test "shape profile reports duplicate top-level keys" =
  let m key j = Yojson.Safe.Util.member key j in
  let dup = request_body_shape_profile {|{"model":"a","model":"b","stream":true}|} in
  let clean = request_body_shape_profile {|{"model":"a","stream":true}|} in
  m "duplicate_keys" dup = `List [ `Assoc [ "name", `String "model"; "count", `Int 2 ] ]
  && m "duplicate_keys" clean = `List []
;;

let%test "header_line_bytes = key + value + 4 (\": \" + CRLF)" =
  (* "x-runtime-mcp" = 13, "abc" = 3, + 4 = 20 *)
  header_line_bytes ("x-runtime-mcp", "abc") = 20
;;

let%test "header_size_profile orders the largest header first" =
  match
    header_size_profile
      [ "small", "v"; "big", String.make 100 'x'; "mid", String.make 20 'y' ]
  with
  | `Assoc (("name", `String "big") :: _) :: _ -> true
  | _ -> false
;;

(* The edge checks per-header-line size, not the total. Many small headers whose
   total far exceeds the limit are accepted; only the per-header max matters. *)
let%test "max_single_header_bytes ignores the total, tracks the largest line" =
  let many_small =
    List.init 20 (fun i -> Printf.sprintf "x-h%d" i, String.make 500 'y')
  in
  max_single_header_bytes many_small < cdn_per_header_limit_bytes
;;

let%test "max_single_header_bytes flags a single oversized header line" =
  max_single_header_bytes [ "x-big", String.make 9000 'x' ] > cdn_per_header_limit_bytes
;;
