(** Langfuse Integration - LLM Observability Platform

    Langfuse API를 통해 LLM 호출을 트레이싱합니다.

    특징:
    - Trace: 전체 요청의 컨테이너 (chain 실행 단위)
    - Generation: LLM 호출 기록 (모델, 프롬프트, 응답, 토큰)
    - Span: 일반 작업 구간

    환경변수:
    - LANGFUSE_SECRET_KEY: API 시크릿 키
    - LANGFUSE_PUBLIC_KEY: API 퍼블릭 키
    - LANGFUSE_HOST: Langfuse 서버 URL (기본값: http://localhost:3100)

    @author llm-mcp
    @since 2026-01
*)

(* Fiber-safe random state for ID generation *)
let langfuse_rng = Random.State.make_self_init ()

(** {1 Configuration} *)

(** Langfuse configuration loaded from environment *)
type config = {
  secret_key: string;
  public_key: string;
  host: string;
  enabled: bool;
}

(** Load configuration from environment *)
let load_config () =
  let secret = Sys.getenv_opt "LANGFUSE_SECRET_KEY" in
  let public = Sys.getenv_opt "LANGFUSE_PUBLIC_KEY" in
  let host = Sys.getenv_opt "LANGFUSE_HOST"
    |> Option.value ~default:"http://localhost:3100" in
  match secret, public with
  | Some sk, Some pk ->
      { secret_key = sk; public_key = pk; host; enabled = true }
  | _ ->
      { secret_key = ""; public_key = ""; host; enabled = false }

(** Global config - loaded lazily *)
let config = lazy (load_config ())

(** Check if Langfuse is enabled *)
let is_enabled () =
  let cfg = Lazy.force config in
  Printf.eprintf "[Langfuse] is_enabled check: enabled=%b, host=%s\n%!" cfg.enabled cfg.host;
  cfg.enabled

(** {1 ID Generation} *)

(** Generate a UUID-like ID *)
let generate_id () =
  let random_bytes = Bytes.create 16 in
  for i = 0 to 15 do
    Bytes.set random_bytes i (Char.chr (Random.State.int langfuse_rng 256))
  done;
  (* Format as UUID: 8-4-4-4-12 *)
  let hex = Bytes.fold_left (fun acc c ->
    acc ^ Printf.sprintf "%02x" (Char.code c)
  ) "" random_bytes in
  String.sub hex 0 8 ^ "-" ^
  String.sub hex 8 4 ^ "-" ^
  String.sub hex 12 4 ^ "-" ^
  String.sub hex 16 4 ^ "-" ^
  String.sub hex 20 12

(** {1 Trace Types} *)

(** Trace represents a complete chain execution *)
type trace = {
  trace_id: string;
  name: string;
  mutable metadata: (string * string) list;
  started_at: float;
}

(** Generation represents an LLM call *)
type generation = {
  gen_id: string;
  trace_id: string;
  name: string;
  model: string;
  input: string;
  mutable output: string option;
  mutable usage: (int * int * int) option; (* prompt, completion, total *)
  started_at: float;
  mutable ended_at: float option;
  mutable status: [ `Running | `Success | `Error of string ];
}

(** Span represents a generic operation *)
type span = {
  span_id: string;
  trace_id: string;
  name: string;
  mutable metadata: (string * string) list;
  started_at: float;
  mutable ended_at: float option;
}

(** {1 JSON Encoding} *)

(** Encode metadata to JSON *)
let metadata_to_json metadata =
  `Assoc (List.map (fun (k, v) -> (k, `String v)) metadata)

(** ISO 8601 timestamp *)
let iso8601_of_float t =
  let tm = Unix.gmtime t in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ"
    (tm.Unix.tm_year + 1900)
    (tm.Unix.tm_mon + 1)
    tm.Unix.tm_mday
    tm.Unix.tm_hour
    tm.Unix.tm_min
    tm.Unix.tm_sec
    (int_of_float ((t -. floor t) *. 1000.0))

(** Encode trace creation to JSON *)
let trace_to_json (t : trace) =
  `Assoc [
    ("id", `String t.trace_id);
    ("name", `String t.name);
    ("metadata", metadata_to_json t.metadata);
    ("timestamp", `String (iso8601_of_float t.started_at));
  ]

(** Encode generation to JSON *)
let generation_to_json (gen : generation) =
  (* Langfuse expects input/output as plain strings or standard formats *)
  let base = [
    ("id", `String gen.gen_id);
    ("traceId", `String gen.trace_id);
    ("name", `String gen.name);
    ("model", `String gen.model);
    ("input", `String gen.input);
    ("startTime", `String (iso8601_of_float gen.started_at));
  ] in
  let with_output = match gen.output with
    | Some o -> base @ [("output", `String o)]
    | None -> base
  in
  let with_usage = match gen.usage with
    | Some (prompt, completion, total) ->
        with_output @ [
          ("usage", `Assoc [
            ("promptTokens", `Int prompt);
            ("completionTokens", `Int completion);
            ("totalTokens", `Int total);
          ])
        ]
    | None -> with_output
  in
  let with_end = match gen.ended_at with
    | Some t -> with_usage @ [("endTime", `String (iso8601_of_float t))]
    | None -> with_usage
  in
  let with_status = match gen.status with
    | `Running -> with_end @ [("level", `String "DEFAULT")]
    | `Success -> with_end @ [("level", `String "DEFAULT")]
    | `Error msg -> with_end @ [
        ("level", `String "ERROR");
        ("statusMessage", `String msg)
      ]
  in
  `Assoc with_status

(** Encode span to JSON *)
let span_to_json (s : span) =
  let base = [
    ("id", `String s.span_id);
    ("traceId", `String s.trace_id);
    ("name", `String s.name);
    ("metadata", metadata_to_json s.metadata);
    ("startTime", `String (iso8601_of_float s.started_at));
  ] in
  let with_end = match s.ended_at with
    | Some et -> base @ [("endTime", `String (iso8601_of_float et))]
    | None -> base
  in
  `Assoc with_end

(** {1 HTTP Client (Eio-based)} *)

(** Send POST request to Langfuse API *)
let send_to_langfuse ~endpoint ~body () =
  if not (is_enabled ()) then ()
  else begin
    let cfg = Lazy.force config in
    let url = cfg.host ^ "/api/public" ^ endpoint in
    let auth = Base64.encode_string (cfg.public_key ^ ":" ^ cfg.secret_key) in
    let headers = [
      ("Content-Type", "application/json");
      ("Authorization", "Basic " ^ auth);
    ] in
    let body_str = Yojson.Safe.to_string body in

    (* Fire-and-forget HTTP POST using blocking Unix socket *)
    (* Using blocking mode for reliable delivery to local Langfuse *)
    try
      let uri = Uri.of_string url in
      let host = Uri.host uri |> Option.value ~default:"localhost" in
      let port = Uri.port uri |> Option.value ~default:3100 in
      Printf.eprintf "[Langfuse] Sending to %s:%d, endpoint=%s\n%!" host port endpoint;
      Printf.eprintf "[Langfuse] Body: %s\n%!" (String.sub body_str 0 (min 500 (String.length body_str)));
      let sockaddr = Unix.ADDR_INET (Unix.inet_addr_of_string
        (try (Unix.gethostbyname host).Unix.h_addr_list.(0)
              |> Unix.string_of_inet_addr
         with _ -> "127.0.0.1"), port) in
      let sock = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
      (* Use blocking socket for reliable connection *)
      Unix.setsockopt_float sock Unix.SO_SNDTIMEO 2.0;  (* 2 second timeout *)
      Unix.setsockopt_float sock Unix.SO_RCVTIMEO 2.0;
      Unix.connect sock sockaddr;
      Printf.eprintf "[Langfuse] Connected to socket\n%!";

      let path = Uri.path uri in
      let request = Printf.sprintf
        "POST %s HTTP/1.1\r\nHost: %s:%d\r\n%s\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s"
        path host port
        (String.concat "\r\n" (List.map (fun (k, v) -> k ^ ": " ^ v) headers))
        (String.length body_str)
        body_str in

      let _ = Unix.write_substring sock request 0 (String.length request) in
      (* Read response to ensure request is processed *)
      let buf = Bytes.create 256 in
      let n = try Unix.read sock buf 0 256 with _ -> 0 in
      Printf.eprintf "[Langfuse] Response (%d bytes): %s\n%!" n (Bytes.sub_string buf 0 (min n 100));
      Unix.close sock
    with exn ->
      Printf.eprintf "[Langfuse] Error: %s\n%!" (Printexc.to_string exn)
  end

(** {1 API Functions} *)

(** Create a new trace *)
let create_trace ~name ?(metadata=[]) () =
  let trace = {
    trace_id = generate_id ();
    name;
    metadata;
    started_at = Unix.gettimeofday ();
  } in
  send_to_langfuse ~endpoint:"/traces" ~body:(trace_to_json trace) ();
  trace

(** End a trace (update with final metadata) *)
let end_trace (trace : trace) =
  let body = `Assoc [
    ("id", `String trace.trace_id);
    ("metadata", metadata_to_json trace.metadata);
  ] in
  send_to_langfuse ~endpoint:"/traces" ~body ()

(** Create a generation (LLM call) *)
let create_generation ~(trace : trace) ~name ~model ~input () =
  let gen = {
    gen_id = generate_id ();
    trace_id = trace.trace_id;
    name;
    model;
    input;
    output = None;
    usage = None;
    started_at = Unix.gettimeofday ();
    ended_at = None;
    status = `Running;
  } in
  send_to_langfuse ~endpoint:"/generations" ~body:(generation_to_json gen) ();
  gen

(** End a generation with output *)
let end_generation (gen : generation) ~output ~prompt_tokens ~completion_tokens =
  gen.output <- Some output;
  gen.usage <- Some (prompt_tokens, completion_tokens, prompt_tokens + completion_tokens);
  gen.ended_at <- Some (Unix.gettimeofday ());
  gen.status <- `Success;
  send_to_langfuse ~endpoint:"/generations" ~body:(generation_to_json gen) ()

(** Mark generation as error *)
let error_generation (gen : generation) ~message =
  gen.ended_at <- Some (Unix.gettimeofday ());
  gen.status <- `Error message;
  send_to_langfuse ~endpoint:"/generations" ~body:(generation_to_json gen) ()

(** Create a span *)
let create_span ~(trace : trace) ~name ?(metadata=[]) () =
  let s = {
    span_id = generate_id ();
    trace_id = trace.trace_id;
    name;
    metadata;
    started_at = Unix.gettimeofday ();
    ended_at = None;
  } in
  send_to_langfuse ~endpoint:"/spans" ~body:(span_to_json s) ();
  s

(** End a span *)
let end_span (s : span) =
  s.ended_at <- Some (Unix.gettimeofday ());
  send_to_langfuse ~endpoint:"/spans" ~body:(span_to_json s) ()

(** {1 High-Level Wrappers} *)

(** Wrap an LLM call with tracing *)
let trace_llm ~trace ~name ~model ~input f =
  let gen = create_generation ~trace ~name ~model ~input () in
  try
    let (output, prompt_tokens, completion_tokens) = f () in
    end_generation gen ~output ~prompt_tokens ~completion_tokens;
    output
  with e ->
    error_generation gen ~message:(Printexc.to_string e);
    raise e

(** Wrap an operation with a span *)
let trace_span ~trace ~name ?metadata f =
  let span = create_span ~trace ~name ?metadata () in
  try
    let result = f () in
    end_span span;
    result
  with e ->
    end_span span;
    raise e

(** {1 Status} *)

(** Get Langfuse status *)
let status () =
  let cfg = Lazy.force config in
  if cfg.enabled then
    Printf.sprintf "Langfuse: ENABLED (host: %s)" cfg.host
  else
    "Langfuse: DISABLED (missing LANGFUSE_SECRET_KEY or LANGFUSE_PUBLIC_KEY)"
