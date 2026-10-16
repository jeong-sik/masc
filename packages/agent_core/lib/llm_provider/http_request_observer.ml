type mode = Synchronous | Streaming
type completion = Returned_ok | Returned_error | Cancelled | Raised
type tool_inventory =
  | No_tools_member
  | Tools_member of { wire_entries : int; json_bytes : int; json_sha256 : string }
  | Tools_unavailable
type phase =
  | Client_entered of
      { mode : mode; body_bytes : int; body_sha256 : string
      ; tool_inventory : tool_inventory option }
  | Dispatch_entered
  | Response_headers_received of { status : int }
  | Client_finished of completion

type event = { call_id : int; phase : phase }
type t =
  { observe : event -> (unit, unit) result
  ; next_id : int Atomic.t
  ; delivery_failures : int Atomic.t
  }
type call = { owner : t; id : int }
type tools_binding = { body_sha256 : string; inventory : tool_inventory }

let observer_key : t Eio.Fiber.key = Eio.Fiber.create_key ()
let tools_key : tools_binding Eio.Fiber.key = Eio.Fiber.create_key ()
let create observe = { observe; next_id = Atomic.make 0; delivery_failures = Atomic.make 0 }
let with_observer observer run = Eio.Fiber.with_binding observer_key observer run
let with_request_tools ~body ~inventory run =
  match Eio.Fiber.get observer_key with
  | None -> run ()
  | Some _ ->
    let inventory = match inventory () with
      | inventory -> inventory
      | exception exn -> Reserved_exn.reraise_if_reserved exn; Tools_unavailable in
    let binding = {body_sha256=Digestif.SHA256.(digest_string body |> to_hex);inventory} in
    Eio.Fiber.with_binding tools_key binding run
let capture run =
  match Eio.Fiber.get observer_key with
  | None -> run
  | Some observer -> fun () -> with_observer observer run
let delivery_failure_count observer = Atomic.get observer.delivery_failures

let emit call phase =
  match call.owner.observe { call_id = call.id; phase } with
  | Ok () -> ()
  | Error () -> Atomic.incr call.owner.delivery_failures
  | exception exn ->
    Reserved_exn.reraise_if_reserved exn;
    Atomic.incr call.owner.delivery_failures

let dispatch_entered = function
  | None -> ()
  | Some call -> emit call Dispatch_entered

let response_headers_received call ~status =
  match call with
  | None -> ()
  | Some call -> emit call (Response_headers_received { status })

let with_call ~mode ~body run =
  match Eio.Fiber.get observer_key with
  | None -> run None
  | Some owner ->
    let call = { owner; id = Atomic.fetch_and_add owner.next_id 1 } in
    let body_sha256 = Digestif.SHA256.(digest_string body |> to_hex) in
    let tool_inventory = match Eio.Fiber.get tools_key with
      | Some binding when String.equal binding.body_sha256 body_sha256 -> Some binding.inventory
      | Some _ | None -> None in
    emit call (Client_entered
      { mode; body_bytes = String.length body; body_sha256; tool_inventory });
    match run (Some call) with
    | (Ok _ as result) -> emit call (Client_finished Returned_ok); result
    | (Error _ as result) -> emit call (Client_finished Returned_error); result
    | exception exn ->
      let backtrace = Printexc.get_raw_backtrace () in
      let completion = match exn with Eio.Cancel.Cancelled _ -> Cancelled | _ -> Raised in
      emit call (Client_finished completion);
      Printexc.raise_with_backtrace exn backtrace
