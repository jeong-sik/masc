(** Tool_lodge - The Lodge: Agent Research Club

    Read → Dig → Share → React cycle for autonomous agent learning.
    Uses Eio fibers for concurrent content fetching and LLM analysis.

    OCaml 5.4+ / Eio — type-safe, concurrent, no bash/python parsing.
*)

type result = bool * string

(** {1 Lodge Configuration} *)

(** Read Lodge config from .masc/config.json *)
let read_lodge_config () =
  match Env_config.me_root_opt () with
  | None -> (None, None)
  | Some root ->
      let config_path = Filename.concat root ".masc/config.json" in
      try
        let content = Fs_compat.load_file config_path in
        let json = Yojson.Safe.from_string content in
        let lodge = Yojson.Safe.Util.(member "lodge" json) in
        let lang = Yojson.Safe.Util.(member "language" lodge |> to_string_option) in
        let inst = Yojson.Safe.Util.(member "instruction" lodge |> to_string_option) in
        (lang, inst)
      with Yojson.Safe.Util.Type_error _ | Yojson.Json_error _ | Sys_error _ -> (None, None)

let (config_language, config_instruction) = read_lodge_config ()

(** Lodge 공용어 — config.json > 환경변수 > 기본값(ko) *)
let lodge_language =
  match config_language with
  | Some lang -> lang
  | None ->
    match Sys.getenv_opt "MASC_LODGE_LANGUAGE" with
    | Some "en" -> "en"
    | Some "auto" -> "auto"
    | _ -> "ko"

(** Lodge 인스트럭션 — config.json에서 읽음 *)
let language_instruction () =
  match config_instruction with
  | Some inst -> inst
  | None ->
    match lodge_language with
    | "ko" -> "반드시 한글로 작성하세요."
    | "en" -> "Write in English."
    | _ -> ""

(** Get sb script path from ME_ROOT env var (portable) *)
let sb_path () =
  Env_config.sb_path ()

(** {1 Types} *)

type category =
  | Review   (** Content worth discussing *)
  | Notify   (** Alert needing attention *)
  | Noise    (** Irrelevant, skip *)

type source =
  | HackerNews
  | GeekNews

type article = {
  title: string;
  url: string;
  source: source;
}

type analysis = {
  summary: string;
  why_it_matters: string;
  connection: string;
  open_question: string;
}

type classification = {
  category: category;
  details: string;
}

(** {1 Parsing} *)

let category_of_string = function
  | "REVIEW" -> Review
  | "NOTIFY" -> Notify
  | _ -> Noise

let string_of_category = function
  | Review -> "REVIEW"
  | Notify -> "NOTIFY"
  | Noise -> "NOISE"

let string_of_source = function
  | HackerNews -> "hn"
  | GeekNews -> "geek"

let source_of_string = function
  | "hn" | "hackernews" -> Some HackerNews
  | "geek" | "geeknews" -> Some GeekNews
  | _ -> None

(** {1 HTTP helpers} *)

let run_cmd_with_status ?(timeout_sec = 60.0) (argv : string list) : Unix.process_status * string =
  Process_eio.run_argv_with_status ~timeout_sec argv

let run_cmd ?(timeout_sec = 10.0) (argv : string list) : string =
  Process_eio.run_argv ~timeout_sec argv

let sb_argv args = (sb_path ()) :: args

let sb_neo4j_query ?(timeout_sec = 60.0) (cypher : string) : Unix.process_status * string =
  run_cmd_with_status ~timeout_sec (sb_argv ["neo4j"; "query"; cypher])

(** HTTP GET via curl subprocess — supports both HTTP and HTTPS *)
let http_get_json ~net:_ url =
  try
    let (status, content) =
      run_cmd_with_status ~timeout_sec:15.0 ["curl"; "-sf"; "--max-time"; "10"; url]
    in
    match status with
    | Unix.WEXITED 0 -> Ok content
    | Unix.WEXITED n -> Error (Printf.sprintf "❌ HTTP: curl exit %d [url=%s]" n (String.sub url 0 (min 60 (String.length url))))
    | _ -> Error "❌ HTTP: curl signaled"
  with exn -> Error (Printf.sprintf "❌ HTTP: %s" (Printexc.to_string exn))

(* NOTE: http_get_local removed — using curl subprocess for all HTTP *)

(** Use Railway GraphQL by default.
    Set GRAPHQL_URL explicitly for local dev or alternate endpoints. *)
let graphql_url () = Graphql_endpoint.graphql_url ()

let looks_like_html_response body =
  let trimmed = String.lowercase_ascii (String.trim body) in
  trimmed <> "" && trimmed.[0] = '<'

let ensure_graphql_json_response body =
  if String.length body = 0 then
    Error "❌ GraphQL: empty response"
  else if looks_like_html_response body then
    Error "❌ GraphQL: endpoint returned HTML instead of JSON"
  else
    Ok body

let graphql_error_message json =
  match Yojson.Safe.Util.member "errors" json with
  | `List (first :: _) ->
      first |> Yojson.Safe.Util.member "message" |> Yojson.Safe.Util.to_string_option
  | _ -> None

let graphql_agents_edges json =
  match graphql_error_message json with
  | Some msg -> Error ("GraphQL error: " ^ msg)
  | None ->
      let data = Yojson.Safe.Util.member "data" json in
      if data = `Null then
        Error "GraphQL data is null"
      else
        let agents = Yojson.Safe.Util.member "agents" data in
        if agents = `Null then
          Error "GraphQL agents is null"
        else
          match Yojson.Safe.Util.member "edges" agents with
          | `List edges -> Ok edges
          | `Null -> Ok []
          | _ -> Error "GraphQL agents.edges is not a list"

(** Keep auth token out of argv so process errors don't leak secrets. *)
let with_auth_header_file api_key f =
  if api_key = "" then f None
  else
    let path = Filename.temp_file "masc-gql-auth-" ".hdr" in
    Fun.protect
      ~finally:(fun () -> try Sys.remove path with Sys_error _ -> ())
      (fun () ->
         Fs_compat.save_file path ("Authorization: Bearer " ^ api_key ^ "\n");
         f (Some path))

let with_body_file body f =
  let path = Filename.temp_file "masc-gql-body-" ".json" in
  Fun.protect
    ~finally:(fun () -> try Sys.remove path with Sys_error _ -> ())
    (fun () ->
       Fs_compat.save_file path body;
       f path)

let run_argv_unix (argv : string list)
  : (string, string) Stdlib.result =
  match argv with
  | [] -> Error "empty argv"
  | prog :: _ -> (
      try
        let ic = Unix.open_process_args_in prog (Array.of_list argv) in
        let output =
          Fun.protect
            ~finally:(fun () -> ignore (Unix.close_process_in ic))
            (fun () -> In_channel.input_all ic)
        in
        Ok output
      with exn -> Error (Printexc.to_string exn))

(** curl-based GraphQL request — reliable DNS resolution in Railway containers *)
let graphql_request_curl body : (string, string) Stdlib.result =
  let url = graphql_url () in
  let api_key = Sys.getenv_opt "GRAPHQL_API_KEY" |> Option.value ~default:"" in
  with_auth_header_file api_key (fun auth_header_file ->
      with_body_file body (fun body_file ->
          let argv =
            [ "curl"; "-s"; "-m"; "10"; "-f"; "-X"; "POST"; url;
              "-H"; "Content-Type: application/json"
              ; "-H"; "Accept: application/json"
            ]
            |> fun base ->
            match auth_header_file with
            | None -> base
            | Some header_file -> base @ [ "-H"; "@" ^ header_file ]
            |> fun with_auth ->
            with_auth @ [ "-d"; "@" ^ body_file ]
          in
          let process_eio_result =
            if Process_eio.is_initialized () then
              try
                Ok (Process_eio.run_argv ~timeout_sec:15.0 argv)
              with exn -> Error (Printf.sprintf "❌ GraphQL curl: %s" (Printexc.to_string exn))
            else
              Error "❌ GraphQL curl: Process_eio not initialized"
          in
          match process_eio_result with
          | Ok output -> (
              match ensure_graphql_json_response output with
              | Ok _ as success -> success
              | Error "❌ GraphQL: empty response" ->
                  Log.Lodge.error "Process_eio curl failed (empty response), trying Unix curl fallback...";
                  (match run_argv_unix argv with
                   | Ok unix_output -> ensure_graphql_json_response unix_output
                   | Error unix_err ->
                       Error
                         (Printf.sprintf "❌ GraphQL curl: process_eio=empty response; unix=%s"
                            unix_err))
              | Error msg -> Error msg)
          | Error process_err ->
              Log.Lodge.error "Process_eio curl failed (%s), trying Unix curl fallback..."
                process_err;
              (match run_argv_unix argv with
               | Ok output -> ensure_graphql_json_response output
               | Error unix_err ->
                   Error
                     (Printf.sprintf "❌ GraphQL curl: process_eio=%s; unix=%s"
                        process_err unix_err))))

(** GraphQL request via Cohttp_eio with curl fallback.
    Falls back to curl if Cohttp fails (Railway DNS issues).
    URL configurable via GRAPHQL_URL env var for Railway internal networking. *)
let graphql_request ?(timeout_sec=5.0) body : (string, string) Stdlib.result =
  let url = graphql_url () in
  let api_key = Sys.getenv_opt "GRAPHQL_API_KEY" |> Option.value ~default:"" in
  let max_response_bytes = 1_000_000 in
  let cohttp_result = match Eio_context.get_net_opt () with
  | None -> Error "❌ GraphQL: Eio net not initialized"
  | Some net ->
      let headers =
        if api_key = "" then
          Cohttp.Header.of_list [("Content-Type", "application/json")]
        else
          Cohttp.Header.of_list [
            ("Content-Type", "application/json");
            ("Authorization", "Bearer " ^ api_key);
          ]
      in
      let uri = Uri.of_string url in
      let is_https = Uri.scheme uri = Some "https" in
      let run () =
        Eio.Switch.run (fun sw ->
          let client =
            if is_https then
              Cohttp_eio.Client.make ~https:(Some (Eio_context.get_https_connector ())) net
            else
              Cohttp_eio.Client.make ~https:None net  (* HTTP: no TLS connector *)
          in
          let body_content = Eio.Flow.string_source body in
          let resp, resp_body =
            Cohttp_eio.Client.post client ~sw uri ~headers ~body:body_content
          in
          let status = Cohttp.Response.status resp |> Cohttp.Code.code_of_status in
          let body_str =
            Eio.Buf_read.(parse_exn take_all) resp_body ~max_size:max_response_bytes
          in
          if not (Cohttp.Code.is_success status) then
            Error (Printf.sprintf "❌ GraphQL: HTTP %d" status)
          else
            ensure_graphql_json_response body_str
        )
      in
      match Eio_context.get_clock_opt () with
      | Some clock ->
          (try Eio.Time.with_timeout_exn clock timeout_sec run
           with exn -> Error (Printexc.to_string exn))
      | None ->
          (try run () with exn -> Error (Printexc.to_string exn))
  in
  (* Fallback to curl on Cohttp failure (Railway DNS issues) *)
  match cohttp_result with
  | Ok _ as success -> success
  | Error cohttp_err ->
      Log.Lodge.error "Cohttp failed (%s), trying curl fallback..." cohttp_err;
      graphql_request_curl body
