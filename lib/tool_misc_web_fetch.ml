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

(** JSON response helpers — same pattern as Tool_misc_web_search *)
let json_error message =
  Yojson.Safe.to_string
    (`Assoc [ ("status", `String "error"); ("message", `String message) ])

let json_ok fields =
  Yojson.Safe.to_string (`Assoc (("status", `String "ok") :: fields))

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

(** Main fetch implementation *)
let fetch_impl ~url ~timeout_sec =
  let headers =
    [ ("User-Agent", "Mozilla/5.0 (compatible; MASC-WebFetch/1.0)") ]
  in
  match
    Tool_local_runtime_http.http_get_text_with_status_with_headers
      ~timeout_sec ~headers url
  with
  | Error detail ->
      Error
        (Printf.sprintf "fetch failed: %s"
           (redact_transport_error_detail detail))
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
  | Ok (Some status, _) -> Error (Printf.sprintf "HTTP %d" status)
  | Ok (None, _) -> Error "no HTTP status received"

let handle args =
  let url = get_string args "url" "" in
  let timeout = max 1 (min 60 (get_int args "timeout" 15)) in
  if not (valid_url url) then
    (false, json_error "url must be a valid http or https URL")
  else
    let now = Unix.gettimeofday () in
    let key = url ^ "|" ^ Int.to_string timeout in
    match cache_lookup key now with
    | Some cached -> (true, cached)
    | None -> (
        match enforce_rate_limit now with
        | Error message -> (false, json_error message)
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
                let json = json_ok fields in
                cache_store key json now;
                (true, json)
            | Error message -> (false, json_error message)))
