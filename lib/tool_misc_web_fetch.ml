module Format = Stdlib.Format
module Map = Stdlib.Map
module Set = Stdlib.Set
module Queue = Stdlib.Queue
module Hashtbl = Stdlib.Hashtbl
module Mutex = Stdlib.Mutex
module Option = Stdlib.Option
module Result = Stdlib.Result
module Sys = Stdlib.Sys
module Filename = Stdlib.Filename
module List = Stdlib.List
module Array = Stdlib.Array
module String = Stdlib.String
module Char = Stdlib.Char
module Int = Stdlib.Int
module Float = Stdlib.Float

open Tool_args

let default_timeout_sec = 15

(** Extract <title> from HTML *)
let title_tag_re =
  Re.Pcre.re ~flags:[ `CASELESS; `DOTALL ] "<title[^>]*>(.*?)</title>"
  |> Re.compile

let extract_title html =
  match Re.exec_opt title_tag_re html with
  | Some groups ->
      let raw = Re.Group.get groups 1 in
      let cleaned = Tool_misc_web_search.clean_search_text raw in
      if String.equal cleaned "" then None else Some cleaned
  | None -> None

(** Extract <meta name="description"> or og:description from HTML *)
let meta_description_re =
  Re.Pcre.re
    ~flags:[ `CASELESS; `DOTALL ]
    "<meta[^>]+name\\s*=\\s*['\"]description['\"][^>]+content\\s*=\\s*['\"]([^'\"]+)['\"][^>]*>"
  |> Re.compile

let meta_description_reversed_re =
  Re.Pcre.re
    ~flags:[ `CASELESS; `DOTALL ]
    "<meta[^>]+content\\s*=\\s*['\"]([^'\"]+)['\"][^>]+name\\s*=\\s*['\"]description['\"][^>]*>"
  |> Re.compile

let og_description_re =
  Re.Pcre.re
    ~flags:[ `CASELESS; `DOTALL ]
    "<meta[^>]+property\\s*=\\s*['\"]og:description['\"][^>]+content\\s*=\\s*['\"]([^'\"]+)['\"][^>]*>"
  |> Re.compile

let og_description_reversed_re =
  Re.Pcre.re
    ~flags:[ `CASELESS; `DOTALL ]
    "<meta[^>]+content\\s*=\\s*['\"]([^'\"]+)['\"][^>]+property\\s*=\\s*['\"]og:description['\"][^>]*>"
  |> Re.compile

let first_match html pattern =
  match Re.exec_opt pattern html with
  | Some groups ->
      let cleaned = Tool_misc_web_search.clean_search_text (Re.Group.get groups 1) in
      if String.equal cleaned "" then None else Some cleaned
  | None -> None

let extract_description html =
  match first_match html og_description_re with
  | Some _ as value -> value
  | None -> (
      match first_match html og_description_reversed_re with
      | Some _ as value -> value
      | None -> (
          match first_match html meta_description_re with
          | Some _ as value -> value
          | None -> first_match html meta_description_reversed_re))

(** URL validation *)
let valid_url url =
  let trimmed = String.trim url in
  if String.equal trimmed "" then false
  else
    let uri = Uri.of_string trimmed in
    match Uri.scheme uri |> Option.map String.lowercase_ascii with
    | Some "http" | Some "https" -> true
    | _ -> false

(** Cache + rate limit — same pattern as web_search but separate state *)
type cache_entry = {
  response : string;
  expires_at : float;
}

let initial_cache_capacity = 32
let cache_entries : (string, cache_entry) Hashtbl.t =
  Hashtbl.create initial_cache_capacity
let cache_mutex = Eio.Mutex.create ()
let request_times : float Queue.t = Queue.create ()
let rate_limit_mutex = Eio.Mutex.create ()

let cache_ttl_sec () = Env_config.Tools.web_search_cache_ttl_sec ()

let cache_lookup key now =
  let ttl = cache_ttl_sec () in
  if Stdlib.Float.compare ttl 0.0 <= 0 then None
  else
    Eio.Mutex.use_rw ~protect:true cache_mutex (fun () ->
        Hashtbl.filter_map_inplace
          (fun _ entry ->
            if Stdlib.Float.compare entry.expires_at now <= 0 then None
            else Some entry)
          cache_entries;
        match Hashtbl.find_opt cache_entries key with
        | Some entry when Stdlib.Float.compare entry.expires_at now > 0 ->
            Some entry.response
        | _ -> None)

let cache_store key response now =
  let ttl = cache_ttl_sec () in
  if Stdlib.Float.compare ttl 0.0 > 0 then
    Eio.Mutex.use_rw ~protect:true cache_mutex (fun () ->
        Hashtbl.replace cache_entries key { response; expires_at = now +. ttl })

let enforce_rate_limit now =
  let window = Env_config.Tools.web_search_rate_limit_window_sec () in
  let max_calls = Env_config.Tools.web_search_rate_limit_max_calls () in
  Eio.Mutex.use_rw ~protect:true rate_limit_mutex (fun () ->
      while
        Queue.length request_times > 0
        && Stdlib.( > ) (Stdlib.Float.sub now (Queue.peek request_times)) window
      do
        let (_ : float) = Queue.pop request_times in
        ()
      done;
      if Queue.length request_times >= max_calls then
        Error "web fetch rate limit exceeded; retry shortly"
      else (
        Queue.push now request_times;
        Ok ()))

(** Max content length — prevent context overflow *)
let max_content_length = 100_000

(** Redact transport error detail before the " for " suffix *)
let redact_transport_error_detail message =
  match String.index_opt message ' ' with
  | Some idx -> String.sub message 0 idx
  | None -> message

(* RFC-0189 PR-1b.8 — typed fetch-failure variant. Each arm carries
   the data needed to render an operator-facing message AND a
   [tool_failure_class] tag. This SSOT keeps message formatting (in
   [fetch_failure_to_string]) and class assignment (in
   [fetch_failure_class]) co-located with construction — no
   substring re-classification downstream. *)
type fetch_failure =
  | Transport_error of string   (* raw transport-layer detail, already redacted *)
  | Http_status of int          (* upstream returned a non-2xx HTTP status *)
  | No_http_status              (* protocol level: status line missing *)

let fetch_failure_to_string = function
  | Transport_error detail -> Printf.sprintf "fetch failed: %s" detail
  | Http_status status -> Printf.sprintf "HTTP %d" status
  | No_http_status -> "no HTTP status received"

let fetch_failure_class : fetch_failure -> Tool_result.tool_failure_class =
  function
  | Transport_error _ -> Tool_result.Transient_error
  | Http_status _ -> Tool_result.Runtime_failure
  | No_http_status -> Tool_result.Runtime_failure

(** Main fetch implementation *)
let fetch_impl ~url ~timeout_sec =
  let headers =
    [ ("User-Agent", "Mozilla/5.0 (compatible; MASC-FetchWeb/1.0)") ]
  in
  match
    Tool_local_runtime_http.http_get_text_with_status_with_headers
      ~timeout_sec ~headers url
  with
  | Error detail ->
      Error (Transport_error (redact_transport_error_detail detail))
  | Ok (Some status, payload) when status >= 200 && status < 300 ->
      let title = extract_title payload in
      let description = extract_description payload in
      let text =
        let cleaned = Tool_misc_web_search.clean_search_text payload in
        if String.length cleaned > max_content_length then
          String.sub cleaned 0 max_content_length
          ^ "\n[TRUNCATED at 100KB]"
        else cleaned
      in
      Ok (status, title, description, text)
  | Ok (Some status, _) -> Error (Http_status status)
  | Ok (None, _) -> Error No_http_status

(* RFC-0189 PR-1b.8 — typed result.
   Failure-class assignments live with construction:
   - [Workflow_rejection]: caller-input violation (invalid URL).
   - [Transient_error]:    rate-limit hit + transport-level failure
                           ([fetch_failure_class] for transport).
                           Both retry-friendly by nature; clients can
                           now back off automatically based on the
                           tag instead of pattern-matching the message
                           string.
   - [Runtime_failure]:    upstream HTTP non-2xx or missing status —
                           server-side or malformed, retry is not
                           always safe.

   Note: no substring classifier downstream. Each [fetch_failure]
   variant carries its own [fetch_failure_class], assigned at the
   call site that constructs it. Avoids the workaround signature
   §2 anti-pattern (string-based classification). *)

let handle ~tool_name ~start_time args : Tool_result.result =
  let url = get_string args "url" "" in
  let timeout = max 1 (min 60 (get_int args "timeout" default_timeout_sec)) in
  if not (valid_url url) then
    Tool_result.make_err
      ~tool_name
      ~class_:Tool_result.Workflow_rejection
      ~start_time
      "url must be a valid http or https URL"
  else
    (* RFC-0189 follow-up — store the parsed JSON envelope in
       [~data] instead of wrapping as [`Assoc [ "text", `String body ]].
       The wrapped form corrupted [result.message] for callers (and
       tests) that round-tripped through [parse_json result.message],
       since [to_legacy] serialised the wrapper rather than the
       envelope.  Both the cache and fresh paths produce
       [Tool_args.ok_response] strings, so both go through
       [structured_payload_of_message]; plain-text fallback retained
       only for defence in depth. *)
    let ok_from_envelope body =
      let data =
        match Tool_result.structured_payload_of_message body with
        | Some json -> json
        | None -> `String body
      in
      Tool_result.make_ok ~tool_name ~start_time ~data ()
    in
    let now = Unix.gettimeofday () in
    let key = url ^ "|" ^ Int.to_string timeout in
    match cache_lookup key now with
    | Some cached -> ok_from_envelope cached
    | None -> (
        match enforce_rate_limit now with
        | Error message ->
            Tool_result.make_err
              ~tool_name
              ~class_:Tool_result.Transient_error
              ~start_time
              message
        | Ok () -> (
            match fetch_impl ~url ~timeout_sec:timeout with
            | Ok (http_status, title, description, text) ->
                let fields =
                  [
                    ("url", `String url);
                    ("http_status", `Int http_status);
                    ("text", `String text);
                  ]
                  @
                  (match title with
                  | Some t -> [ ("title", `String t) ]
                  | None -> [])
                  @
                  (match description with
                  | Some d -> [ ("description", `String d) ]
                  | None -> [])
                in
                let json = Tool_args.ok_response fields in
                cache_store key json now;
                ok_from_envelope json
            | Error failure ->
                Tool_result.make_err
                  ~tool_name
                  ~class_:(fetch_failure_class failure)
                  ~start_time
                  (fetch_failure_to_string failure)))
