type endpoint = Answers | Refuses_json | Unreachable

type check = {
  docker : bool;
  container : Sandbox_prerequisites.searxng_container;
  endpoint : endpoint;
}

let default_url = Masc_network_defaults.searxng_default_url

(* A health probe, not a search worth reading: the query only has to be one a
   search accepts. *)
let probe_query = "masc"
let probe_timeout_sec = 5

let capture argv =
  match Process_eio.run_argv_with_status_split_or_refusal argv with
  | Ok (Unix.WEXITED 0, stdout, _) -> Ok stdout
  | Ok ((Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _), _, _) | Error _ -> Error ()

let get url = Tool_local_runtime_http.http_get_text_with_status ~timeout_sec:probe_timeout_sec url

let docker_up ~run =
  match run [ "docker"; "info"; "--format"; "{{.ServerVersion}}" ] with
  | Ok _ -> true
  | Error () -> false

let container_state ~run =
  match
    run
      [ "docker"; "inspect"; "--format"; "{{.State.Status}}"
      ; Sandbox_prerequisites.searxng_container_name ]
  with
  | Ok output ->
    (match String.trim output with
     | "running" -> Sandbox_prerequisites.Searxng_running
     | _ -> Sandbox_prerequisites.Searxng_stopped)
  | Error () -> Sandbox_prerequisites.Searxng_absent

let container ?(run = capture) () =
  if docker_up ~run then container_state ~run else Sandbox_prerequisites.Searxng_absent

let endpoint_of ~get url =
  let search =
    Printf.sprintf "%s/search?q=%s&format=json" url (Uri.pct_encode probe_query)
  in
  match get search with
  | Ok (Some 200, body) ->
    (match Yojson.Safe.from_string body with
     | `Assoc fields when List.mem_assoc "results" fields -> Answers
     | _ | (exception Yojson.Json_error _) -> Refuses_json)
  | Ok (Some 403, _) -> Refuses_json
  | Ok _ | Error _ -> Unreachable

let observe ?(run = capture) ?(get = get) ?(url = default_url) () =
  let docker = docker_up ~run in
  let container =
    if docker then container_state ~run else Sandbox_prerequisites.Searxng_absent
  in
  { docker; container; endpoint = endpoint_of ~get url }

let available check =
  match check.endpoint with
  | Answers -> true
  | Refuses_json | Unreachable -> false

(* A container takes a few seconds from start to listening. 30 looks, one a
   second, is a bound on that wait and not a measurement of it. *)
let default_attempts = 30
let default_pause_sec = 1.0

let wait_until_available ?(attempts = default_attempts) ?(pause_sec = default_pause_sec)
    ?(sleep = Unix.sleepf) ?run ?get ?url () =
  let rec look remaining =
    let check = observe ?run ?get ?url () in
    if available check || remaining <= 1 then check
    else begin
      sleep pause_sec;
      look (remaining - 1)
    end
  in
  look (max 1 attempts)

let container_label = function
  | Sandbox_prerequisites.Searxng_absent -> "absent"
  | Sandbox_prerequisites.Searxng_stopped -> "stopped"
  | Sandbox_prerequisites.Searxng_running -> "running"

let endpoint_label = function
  | Answers -> "answers"
  | Refuses_json -> "refuses_json"
  | Unreachable -> "unreachable"

let to_json check =
  `Assoc
    [ ("schema", `String "masc.searxng_readiness.v1")
    ; ("status", `String (if available check then "ready" else "unavailable"))
    ; ("docker", `String (if check.docker then "ready" else "unavailable"))
    ; ("container", `String (container_label check.container))
    ; ("endpoint", `String (endpoint_label check.endpoint))
    ; ("url", `String default_url)
    ]
