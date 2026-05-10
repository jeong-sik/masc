(** GraphQL Client — typed interface to second-brain-graphql server.

    Provides [query] and [mutate] functions that send GraphQL operations
    to the Second Brain GraphQL API with Bearer token auth.

    Uses Cohttp_eio with curl fallback (same pattern as keeper_heartbeat).

    @since 2.91.0
*)

(** {1 Configuration} *)

let graphql_url () = Graphql_endpoint.graphql_url ()

let api_key () =
  Sys.getenv_opt "GRAPHQL_API_KEY" |> Option.value ~default:""

(** {1 HTTP Transport} *)

let looks_like_html_response body =
  let trimmed = String.lowercase_ascii (String.trim body) in
  trimmed <> "" && String.length trimmed > 0 && trimmed.[0] = '<'

let ensure_json_response body =
  if String.length body = 0 then Error "empty response"
  else if looks_like_html_response body then
    Error "endpoint returned HTML instead of JSON"
  else Ok body

(** Write auth header to temp file (keeps token out of argv).  *)
let with_auth_header_file key f =
  if key = "" then f None
  else
    let path = Filename.temp_file "masc-gql-auth-" ".hdr" in
    Fun.protect
      ~finally:(fun () -> try Sys.remove path with Sys_error _ -> ())
      (fun () ->
         Fs_compat.save_file path ("Authorization: Bearer " ^ key ^ "\n");
         f (Some path))

let with_body_file body f =
  let path = Filename.temp_file "masc-gql-body-" ".json" in
  Fun.protect
    ~finally:(fun () -> try Sys.remove path with Sys_error _ -> ())
    (fun () ->
       Fs_compat.save_file path body;
       f path)

(** curl-based fallback for Railway containers with DNS issues. *)
let request_curl ~timeout_sec body =
  let url = graphql_url () in
  let key = api_key () in
  with_auth_header_file key (fun auth_file ->
      with_body_file body (fun body_file ->
          let argv =
            [ "curl"; "-s"; "-m"; string_of_int (int_of_float timeout_sec);
              "-X"; "POST"; url;
              "-H"; "Content-Type: application/json";
              "-H"; "Accept: application/json"
            ]
            |> fun base ->
            (match auth_file with
             | None -> base
             | Some hf -> base @ [ "-H"; "@" ^ hf ])
            |> fun with_auth ->
            with_auth @ [ "-d"; "@" ^ body_file ]
          in
          if Process_eio.is_initialized () then
            (try
               let output =
                 Masc_exec.Exec_gate.run_argv
                   ~actor:(Masc_exec.Agent_id.of_string "system/graphql_client_eio")
                   ~raw_source:(String.concat " " (List.map Filename.quote argv))
                   ~summary:"graphql curl fallback"
                   ~timeout_sec
                   argv
               in
               ensure_json_response output
             with Eio.Cancel.Cancelled _ as e -> raise e | exn -> Error (Printf.sprintf "curl: %s" (Printexc.to_string exn)))
          else
            (* Unix fallback when Eio loop not started *)
            (try
               match
                 Masc_exec.Exec_gate.run_argv_with_status
                   ~actor:(Masc_exec.Agent_id.of_string "system/graphql_client_eio")
                   ~raw_source:(String.concat " " (List.map Filename.quote argv))
                   ~summary:"graphql curl fallback"
                   ~timeout_sec
                   argv
               with
               | Unix.WEXITED 0, output ->
                   ensure_json_response output
               | Unix.WEXITED code, output ->
                   Error (Printf.sprintf "curl exited %d: %s" code output)
               | Unix.WSIGNALED code, _ ->
                   Error (Printf.sprintf "curl signaled: %d" code)
               | Unix.WSTOPPED code, _ ->
                   Error (Printf.sprintf "curl stopped: %d" code)
             with Eio.Cancel.Cancelled _ as e -> raise e | exn -> Error (Printexc.to_string exn))))

(** Cohttp_eio primary transport with curl fallback. *)
let is_transport_error msg =
  let m = String.lowercase_ascii msg in
  let has pat =
    let plen = String.length pat in
    let mlen = String.length m in
    if plen > mlen then false
    else
      let rec scan i =
        if i > mlen - plen then false
        else if String.sub m i plen = pat then true
        else scan (i + 1)
      in scan 0
  in
  List.exists has
    [ "eio net not initialized"; "connection refused"; "name resolution";
      "dns"; "timed out"; "timeout"; "broken pipe"; "eof";
      "connection reset"; "network is unreachable" ]

let request ?(timeout_sec=10.0) ?(fallback=true) body : (string, string) result =
  let url = graphql_url () in
  let key = api_key () in
  let cohttp_result = match Eio_context.get_net_opt () with
    | None -> Error "Eio net not initialized"
    | Some net ->
      let headers =
        if key = "" then
          Cohttp.Header.of_list [("Content-Type", "application/json")]
        else
          Cohttp.Header.of_list [
            ("Content-Type", "application/json");
            ("Authorization", "Bearer " ^ key);
          ]
      in
      let uri = Uri.of_string url in
      let is_https = Uri.scheme uri = Some "https" in
      let run () =
        let https_result =
          if not is_https then Ok None
          else
            match Eio_context.get_https_connector_result () with
            | Ok connector -> Ok (Some connector)
            | Error message -> Error message
        in
        match https_result with
        | Error _ as error -> error
        | Ok https ->
            let header_list = Cohttp.Header.to_list headers in
            (match Masc_http_client.post_sync ~net ~https ~url ~headers:header_list
                ~body () with
            | Error e -> Error (Printf.sprintf "HTTP request failed: %s" e)
            | Ok (code, body_str) ->
                if not (Cohttp.Code.is_success code) then
                  Error (Printf.sprintf "HTTP %d" code)
                else ensure_json_response body_str)
      in
      match Eio_context.get_clock_opt () with
      | Some clock ->
        (try Eio.Time.with_timeout_exn clock timeout_sec run
         with Eio.Cancel.Cancelled _ as e -> raise e | exn -> Error (Printexc.to_string exn))
      | None ->
        (try run () with Eio.Cancel.Cancelled _ as e -> raise e | exn -> Error (Printexc.to_string exn))
  in
  match cohttp_result with
  | Ok _ as success -> success
  | Error cohttp_err when fallback && is_transport_error cohttp_err ->
    request_curl ~timeout_sec body
  | Error _ as err -> err

(** {1 GraphQL Response Parsing} *)

(** Parse GraphQL JSON response into data or error. *)
let parse_response body : (Yojson.Safe.t, string) result =
  match Yojson.Safe.from_string body with
  | exception Yojson.Json_error msg -> Error ("JSON parse error: " ^ msg)
  | json ->
    let open Yojson.Safe.Util in
    (match member "errors" json with
     | `List (err :: _) ->
       let msg = err |> member "message" |> to_string_option
                 |> Option.value ~default:"Unknown GraphQL error" in
       Error ("GraphQL error: " ^ msg)
     | _ ->
       match member "data" json with
       | `Null -> Error "GraphQL data is null"
       | data -> Ok data)

(** {1 Public API} *)

(** Build a GraphQL request body with query and optional variables. *)
let build_body ~query ?(variables=`Null) () =
  Yojson.Safe.to_string
    (`Assoc [
      ("query", `String query);
      ("variables", variables);
    ])

(** Execute a GraphQL query. Returns parsed data or error message. *)
let query ?(timeout_sec=10.0) ~query:q ?(variables=`Null) ()
    : (Yojson.Safe.t, string) result =
  let body = build_body ~query:q ~variables () in
  match request ~timeout_sec body with
  | Error msg -> Error msg
  | Ok raw -> parse_response raw

(** Execute a GraphQL mutation. Does not fall back to curl to prevent replay. *)
let mutate ?(timeout_sec=10.0) ~mutation ?(variables=`Null) ()
    : (Yojson.Safe.t, string) result =
  let body = build_body ~query:mutation ~variables () in
  match request ~timeout_sec ~fallback:false body with
  | Error msg -> Error msg
  | Ok raw -> parse_response raw

(** Convenience: extract a mutation result (success/message). *)
let extract_mutation_result field_name data : (bool * string option, string) result =
  let open Yojson.Safe.Util in
  let field = member field_name data in
  if field = `Null then Error ("Field " ^ field_name ^ " not found in response")
  else
    let success = field |> member "success" |> to_bool_option
                  |> Option.value ~default:false in
    let message = field |> member "message" |> to_string_option in
    Ok (success, message)
