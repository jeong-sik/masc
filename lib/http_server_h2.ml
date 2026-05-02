(** Http_server_h2 - HTTP/2 server using h2-eio

    Replaces httpun-eio for HTTP/2 support with unlimited SSE connections.
    HTTP/2 multiplexing allows many streams over single TCP connection.

    @see <https://github.com/anmonteiro/ocaml-h2> h2 documentation
*)

(** Server configuration *)
type config = {
  port: int;
  host: string;
  max_connections: int;
}

let default_config = {
  port = Env_config_core.masc_http_port_int ();
  host = Env_config_core.masc_host ();
  max_connections = 128;
}

(** HTTP/2 request handler type - receives H2.Reqd.t directly *)
type h2_request_handler = H2.Reqd.t -> unit

(** Abstracted request for route matching *)
type request = {
  meth: H2.Method.t;
  target: string;
  headers: H2.Headers.t;
}

(** Extract request info from H2.Reqd *)
let request_of_reqd reqd =
  let req = H2.Reqd.request reqd in
  {
    meth = req.meth;
    target = req.target;
    headers = req.headers;
  }

(** Simple response helpers - H2 streaming API *)
module Response = struct
  (** Send a complete response body *)
  let send_body reqd response body =
    (* H2 API: respond_with_streaming returns Body.Writer.t directly
       (no `Final argument like Httpun) *)
    let writer = H2.Reqd.respond_with_streaming ~flush_headers_immediately:true reqd response in
    H2.Body.Writer.write_string writer body;
    H2.Body.Writer.close writer

  let text ?(status = `OK) body reqd =
    let headers = H2.Headers.of_list ([
      ("content-type", "text/plain; charset=utf-8");
      ("content-length", string_of_int (String.length body));
    ]) in
    let response = H2.Response.create ~headers status in
    send_body reqd response body

  let html ?(status = `OK) ?(headers = []) body reqd =
    let base_headers = [
      ("content-type", "text/html; charset=utf-8");
      ("content-length", string_of_int (String.length body));
    ] in
    let response = H2.Response.create
      ~headers:(H2.Headers.of_list (base_headers @ headers))
      status
    in
    send_body reqd response body

  let json ?(status = `OK) body reqd =
    let headers = H2.Headers.of_list ([
      ("content-type", "application/json; charset=utf-8");
      ("content-length", string_of_int (String.length body));
    ]) in
    let response = H2.Response.create ~headers status in
    send_body reqd response body

  let not_found reqd =
    text ~status:`Not_found "404 Not Found" reqd

  let method_not_allowed reqd =
    text ~status:`Method_not_allowed "405 Method Not Allowed" reqd

  let bad_request msg reqd =
    text ~status:`Bad_request msg reqd

  (** Start SSE streaming response - returns body writer for continued writes *)
  let start_sse ?(headers = []) reqd =
    let base_headers = [
      ("content-type", "text/event-stream");
      ("cache-control", "no-cache");
    ] in
    let all_headers = H2.Headers.of_list (base_headers @ headers) in
    let response = H2.Response.create ~headers:all_headers `OK in
    (* H2.Reqd.respond_with_streaming returns Body.Writer.t
       Don't close it - keep stream open for SSE events *)
    H2.Reqd.respond_with_streaming ~flush_headers_immediately:true reqd response

  let bytes ?(status = `OK) ?(headers = []) ~content_type body reqd =
    let base_headers = [
      ("content-type", content_type);
      ("content-length", string_of_int (String.length body));
    ] in
    let response = H2.Response.create
      ~headers:(H2.Headers.of_list (base_headers @ headers))
      status
    in
    send_body reqd response body

  let internal_error msg reqd =
    text ~status:`Internal_server_error ("500 Internal Server Error: " ^ msg) reqd
end

(** Request helper functions *)
module Request = struct
  let path req =
    match String.index_opt req.target '?' with
    | Some i -> String.sub req.target 0 i
    | None -> req.target

  let query_string req =
    match String.index_opt req.target '?' with
    | Some i -> Some (String.sub req.target (i + 1) (String.length req.target - i - 1))
    | None -> None

  let method_string req =
    H2.Method.to_string req.meth

  let header name req =
    H2.Headers.get req.headers name

  let content_type req =
    header "content-type" req
end

(** Simple router *)
module Router = struct
  type route = {
    meth: H2.Method.t;
    path: string;
    handler: request -> H2.Reqd.t -> unit;
  }

  type t = route list

  let empty : t = []

  let add meth path handler routes =
    { meth; path; handler } :: routes

  let get path handler routes = add `GET path handler routes
  let post path handler routes = add `POST path handler routes
  let delete path handler routes = add `DELETE path handler routes
  let options path handler routes = add `OPTIONS path handler routes

  (** Match a route - simple prefix matching for now *)
  let find_route routes req =
    let path = Request.path req in
    List.find_opt (fun route ->
      route.meth = req.meth && String.equal route.path path
    ) routes

  (** Create handler from routes *)
  let to_handler routes =
    fun reqd ->
      let req = request_of_reqd reqd in
      match find_route routes req with
      | Some route -> route.handler req reqd
      | None -> Response.not_found reqd
end

(** Read request body - H2 uses async body reading with callback *)
let read_body_async reqd callback =
  let body = H2.Reqd.request_body reqd in
  let buf = Buffer.create 4096 in
  let rec read_loop () =
    H2.Body.Reader.schedule_read body
      ~on_eof:(fun () ->
        let body_str = Buffer.contents buf in
        callback body_str)
      ~on_read:(fun bigstring ~off ~len ->
        let bytes = Bigstringaf.substring bigstring ~off ~len in
        Buffer.add_string buf bytes;
        read_loop ())
  in
  read_loop ()

(** Error handler for H2 connections *)
let error_handler _client_addr ?request:_ error respond =
  let message = match error with
    | `Exn exn -> Printexc.to_string exn
    | `Bad_request -> "Bad request"
    | `Internal_server_error -> "Internal server error"
  in
  Log.Http.error "Error: %s" message;
  let headers = H2.Headers.of_list [("content-type", "text/plain")] in
  let body = respond headers in
  H2.Body.Writer.write_string body message;
  H2.Body.Writer.close body

(** Create H2 request handler from router *)
let make_request_handler routes =
  fun reqd ->
    try
      let req = request_of_reqd reqd in
      match Router.find_route routes req with
      | Some route -> route.handler req reqd
      | None -> Response.not_found reqd
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
      Response.internal_error (Printexc.to_string exn) reqd

(** Httpun-Compatible Adapter Layer
    Allows existing Httpun-style handlers to work with H2
    with minimal code changes *)
module Compat = struct
  (** Wrapper type for compatibility with Httpun-style handlers *)
  type httpun_request = {
    meth: [`GET | `POST | `DELETE | `OPTIONS | `PUT | `HEAD | `CONNECT | `TRACE | `Other of string];
    target: string;
    headers: (string * string) list;
  }

  (** Convert H2 request to Httpun-compatible request *)
  let to_httpun_request (h2_req : request) : httpun_request =
    let meth = match h2_req.meth with
      | `GET -> `GET
      | `POST -> `POST
      | `DELETE -> `DELETE
      | `OPTIONS -> `OPTIONS
      | `PUT -> `PUT
      | `HEAD -> `HEAD
      | `CONNECT -> `CONNECT
      | `TRACE -> `TRACE
      | `Other s -> `Other s
    in
    {
      meth;
      target = h2_req.target;
      headers = H2.Headers.to_list h2_req.headers;
    }

  (** Get header value from compat request — byte-wise CI equality so
      every HTTP request avoids 2 allocations per header inspected. *)
  let header_get headers name =
    List.find_map (fun (k, v) ->
      if String_util.equals_ci k name then Some v else None
    ) headers

  (** Compat helpers mimicking Httpun.Headers *)
  module Headers = struct
    let get headers name = header_get headers name
    let of_list pairs = pairs
  end
end

(** Run HTTP/2 server with Eio *)
let run ~sw ~net ~clock config request_handler =
  let ip = match Ipaddr.of_string config.host with
    | Ok addr -> Eio.Net.Ipaddr.of_raw (Ipaddr.to_octets addr)
    | Error _ -> Eio.Net.Ipaddr.V4.loopback
  in
  let addr = `Tcp (ip, config.port) in
  let socket = Eio.Net.listen net ~sw ~reuse_addr:true ~backlog:config.max_connections addr in

  Printf.printf "MASC MCP Server (HTTP/2) listening on http://%s:%d\n" config.host config.port;
  Printf.printf "   HTTP/2 multiplexing: unlimited SSE streams per connection\n%!";

  let initial_backoff_s = 0.05 in
  let max_backoff_s = 1.0 in
  let backoff_s = ref initial_backoff_s in
  let reset_backoff () = backoff_s := initial_backoff_s in
  let bump_backoff () = backoff_s := min max_backoff_s (!backoff_s *. 2.0) in
  let is_cancelled exn =
    match exn with
    | Eio.Cancel.Cancelled _ -> true
    | _ -> false
  in

  let rec accept_loop () =
    try
      (try
        let flow, client_addr = Eio.Net.accept ~sw socket in
        reset_backoff ();
        Eio.Fiber.fork ~sw (fun () ->
          Eio.Switch.run (fun conn_sw ->
            Eio.Switch.on_release conn_sw (fun () ->
              try Eio.Flow.close flow with
              | Eio.Cancel.Cancelled _ as e -> raise e
              | exn ->
                Log.Misc.error "[h2] flow close failed: %s" (Printexc.to_string exn)
            );
            try
              H2_eio.Server.create_connection_handler
                ~sw:conn_sw
                ~request_handler:(fun _client_addr -> request_handler)
                ~error_handler
                client_addr
                flow
            with
            | Eio.Cancel.Cancelled _ as e -> raise e
            | exn ->
              Log.Http.error "Connection error: %s" (Printexc.to_string exn)
          )
        )
      with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
        if is_cancelled exn then raise exn;
        let delay = !backoff_s in
        Log.Http.error "Accept error: %s (backoff %.2fs)"
          (Printexc.to_string exn) delay;
        Eio.Time.sleep clock delay;
        bump_backoff ());
      accept_loop ()
    with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
      if is_cancelled exn then ()
      else begin
        let delay = !backoff_s in
        Log.Http.error "Accept loop error: %s (backoff %.2fs)"
          (Printexc.to_string exn) delay;
        Eio.Time.sleep clock delay;
        bump_backoff ();
        accept_loop ()
      end
  in
  accept_loop ()
