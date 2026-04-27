(** Masc_http_client — cohttp-eio wrapper with explicit socket close.

    cohttp-eio 6.1.1 does not reliably close the underlying TCP socket fd
    when the Eio.Switch exits (observed on macOS). This module intercepts
    the connection factory via [make_generic] to capture the raw socket and
    close it explicitly on switch release.

    All MASC code that makes outbound HTTP requests should use this module
    instead of [Cohttp_eio.Client.make] directly.

    @see <https://github.com/jeong-sik/masc-mcp/issues/3221> *)

let make_closing_client ~sw ~net ~https =
  let net = (net :> [ `Generic ] Eio.Net.ty Eio.Resource.t) in
  let tracked_flows :
    [ `Close | `Flow | `R | `Shutdown | `W ] Eio.Resource.t list ref =
    ref []
  in
  let clone_resource resource =
    let Eio.Resource.T (value, ops) = resource in
    Eio.Resource.T (value, ops)
  in
  let register_flow flow =
    tracked_flows := clone_resource flow :: !tracked_flows;
    flow
  in
  let close_flow flow =
    try Eio.Resource.close flow
    with Eio.Cancel.Cancelled _ as e -> raise e | exn -> Printf.eprintf "[masc_http_client] close flow failed: %s\n%!" (Printexc.to_string exn)
  in
  let connect ~sw:conn_sw uri =
    let service =
      match Uri.port uri with
      | Some port -> Int.to_string port
      | _ -> Uri.scheme uri |> Option.value ~default:"http"
    in
    let addr =
      match
        Eio.Net.getaddrinfo_stream ~service net
          (Uri.host_with_default ~default:"localhost" uri)
      with
      | ip :: _ -> ip
      | [] -> raise (Invalid_argument "masc_http_client: failed to resolve hostname")
    in
    let sock = Eio.Net.connect ~sw:conn_sw net addr in
    (* Return type must include `Close for cohttp-eio make_generic. *)
    match Uri.scheme uri with
    | Some "https" -> (
        match https with
        | Some wrap -> (
            let wrapped =
              try
                wrap uri sock
              with exn ->
                close_flow
                  (clone_resource
                     (sock :> [ `Close | `Flow | `R | `Shutdown | `W ] Eio.Resource.t));
                raise exn
            in
            tracked_flows :=
              (clone_resource wrapped
                :> [ `Close | `Flow | `R | `Shutdown | `W ] Eio.Resource.t)
              :: !tracked_flows;
            (wrapped :> [ `Close | `Flow | `R | `Shutdown | `W ] Eio.Resource.t))
        | None -> raise (Invalid_argument "masc_http_client: HTTPS requested but not enabled"))
    | _ ->
        register_flow
          (sock :> [ `Close | `Flow | `R | `Shutdown | `W ] Eio.Resource.t)
  in
  let client = Cohttp_eio.Client.make_generic connect in
  Eio.Switch.on_release sw (fun () ->
    let flows = !tracked_flows in
    tracked_flows := [];
    List.iter close_flow flows);
  client

(** POST with structured error handling.
    DNS resolution, TLS, and I/O errors return Error instead of crashing the fiber. *)
type response = {
  status : int;
  headers : (string * string) list;
  body : string;
}

(** Apply an optional Eio wall-clock timeout around a request. When both
    [clock] and [timeout_sec] are supplied, a sleep fiber races the request
    fiber; whichever finishes first wins and the loser is cancelled. On
    timeout the caller receives [Error "timeout after ..."] instead of the
    underlying HTTP result. When either argument is omitted the behaviour
    is identical to the pre-timeout implementation, so existing callers
    need not be updated.

    We use [Eio.Fiber.first] instead of [Eio.Time.with_timeout] because the
    latter requires the inner function's Error constructor to be a
    polymorphic variant compatible with [> `Timeout], while our callers use
    plain [string] error payloads. *)
let with_optional_timeout ?clock ?timeout_sec f =
  match clock, timeout_sec with
  | Some clock, Some timeout_sec when timeout_sec > 0.0 ->
      Eio.Fiber.first
        (fun () -> f ())
        (fun () ->
          Eio.Time.sleep clock timeout_sec;
          Error (Printf.sprintf "timeout after %.1fs" timeout_sec))
  | _ -> f ()

let post_sync ?clock ?timeout_sec ~net ?(https = None) ~url ~headers ~body () =
  with_optional_timeout ?clock ?timeout_sec @@ fun () ->
  try
    Eio.Switch.run @@ fun sw ->
    let client = make_closing_client ~sw ~net ~https in
    let uri = Uri.of_string url in
    let hdr =
      Cohttp.Header.of_list (("connection", "close") :: headers)
    in
    let body_content = Eio.Flow.string_source body in
    let resp, resp_body =
      Cohttp_eio.Client.post client ~sw uri ~headers:hdr ~body:body_content
    in
    let code =
      Cohttp.Response.status resp |> Cohttp.Code.code_of_status
    in
    let body_str =
      let max_size = 8 * 1024 * 1024 in
      let buf = Buffer.create 4096 in
      let chunk = Cstruct.create 4096 in
      let rec read_chunks () =
        if Buffer.length buf > max_size then
          raise (Failure (Printf.sprintf "masc_http_client: body size exceeds %d MB" (max_size / 1024 / 1024)))
        else
          match Eio.Flow.single_read resp_body chunk with
          | n ->
            Buffer.add_string buf (Cstruct.to_string ~off:0 ~len:n chunk);
            Eio.Fiber.yield ();
            read_chunks ()
          | exception End_of_file -> Buffer.contents buf
      in
      read_chunks ()
    in
    Ok (code, body_str)
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn -> Error (Printexc.to_string exn)

(** GET with structured error handling. *)
let get_response_sync ?clock ?timeout_sec ~net ?(https = None) ~url ~headers () =
  with_optional_timeout ?clock ?timeout_sec @@ fun () ->
  try
    Eio.Switch.run @@ fun sw ->
    let client = make_closing_client ~sw ~net ~https in
    let uri = Uri.of_string url in
    let hdr =
      Cohttp.Header.of_list (("connection", "close") :: headers)
    in
    let resp, resp_body =
      Cohttp_eio.Client.get client ~sw ~headers:hdr uri
    in
    let code =
      Cohttp.Response.status resp |> Cohttp.Code.code_of_status
    in
    let response_headers =
      Cohttp.Response.headers resp |> Cohttp.Header.to_list
    in
    let body_str =
      let max_size = 8 * 1024 * 1024 in
      let buf = Buffer.create 4096 in
      let chunk = Cstruct.create 4096 in
      let rec read_chunks () =
        if Buffer.length buf > max_size then
          raise (Failure (Printf.sprintf "masc_http_client: body size exceeds %d MB" (max_size / 1024 / 1024)))
        else
          match Eio.Flow.single_read resp_body chunk with
          | n ->
            Buffer.add_string buf (Cstruct.to_string ~off:0 ~len:n chunk);
            Eio.Fiber.yield ();
            read_chunks ()
          | exception End_of_file -> Buffer.contents buf
      in
      read_chunks ()
    in
    Ok { status = code; headers = response_headers; body = body_str }
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn -> Error (Printexc.to_string exn)

(** GET with structured error handling. *)
let get_sync ?clock ?timeout_sec ~net ?(https = None) ~url ~headers () =
  match get_response_sync ?clock ?timeout_sec ~net ~https ~url ~headers () with
  | Ok response -> Ok (response.status, response.body)
  | Error _ as error -> error
