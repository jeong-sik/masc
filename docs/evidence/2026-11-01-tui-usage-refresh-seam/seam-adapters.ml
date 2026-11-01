open Masc_tui_types
module Masc = struct module Tui_decode = Tui_decode end
module Mtime_clock = struct let elapsed_ns () = 1L end
module System_logs_view = struct
  type source = Server
  type page = {lp_min_level:string option}
  let page Server () = {lp_min_level=None}
end
module Masc_tui_credential_preparation = struct let await_initial () = () end
let jobs : (unit -> unit) Queue.t = Queue.create ()
module Eio = struct
  module Cancel = struct exception Cancelled of unit end
  module Fiber = struct let fork ~sw:() work = Queue.add work jobs end
end
module Eio_context = struct
  let switch = ref (Some ())
  let get_switch_opt () = !switch
end
type readings = {http_scoped_server_identity:(Tui_decode.server_identity,string) result;loaded_days:int}
type dataset = History of int
type dataset_event = {
  ed_ticket:Http_refresh_order.ticket;ed_authority:int;ed_request:Surface_read_order.request;
  ed_identity:Tui_decode.server_identity;ed_dataset:dataset
}
type completion =
  | Http_scoped_refresh_done of int * currency_authority * readings
  | Http_scoped_refresh_failed of int * string * unit option * Http_refresh_order.ticket
      * (Tui_decode.server_identity,string) result option * Surface_read_order.request
type message = Http_dataset_loaded of dataset_event
  | Http_surface_read_completed of Surface_read_context.t * completion
type transport_call = {days:int;needs:surface_needs;request:Surface_read_order.request;ticket:Http_refresh_order.ticket;host:string;port:int}
let calls : transport_call list ref = ref []
let probes = ref 0
let identity_readings : (Tui_decode.server_identity,string) result Queue.t = Queue.create ()
let on_probe = ref (fun (_ : int) -> ())
let on_transport = ref (fun () -> ())
let load_server_identity ~host:_ ~port:_ =
  incr probes;!on_probe !probes;
  if Queue.is_empty identity_readings then Ok identity else Queue.take identity_readings
let load_http_scoped_surface_reads ~on_progress:_ ~on_dataset ~surface_request
    ~ask_request:_ ~roster_request:_ ~refresh_ticket ~server_identity ~host ~port
    ~approval_ticket:_ ~board_query:_ ~provider_history_days ~system_log_level:_ ~needs =
  calls := !calls @ [{days=provider_history_days;needs;request=surface_request;ticket=refresh_ticket;host;port}];
  (match server_identity,on_dataset with Ok identity,Some publish -> publish identity (History provider_history_days) | _ -> ());
  !on_transport ();
  {http_scoped_server_identity=server_identity;loaded_days=provider_history_days}
let enqueue_async mailbox message = Queue.add message mailbox
let board_query _ = ()
let log_http_surface_read_started _ ~full_refresh_running:_ _ = ()
let log_http_surface_read_finished _ _ = ()
let dispatch_approvals_listing _ = Some ()
let launch_keeper_history_load _ ~mailbox:_ ~keeper_name:_ = ()
let apply_http_scoped_refresh_success state ~currency_authority:_ ~base_path:_ ~mailbox:_
    ~refresh_inflight:_ ~scoped_refresh_inflight:_ ~scoped_refresh_followup:_ _ =
  state.applied <- state.applied + 1
let read_authority state = state.workspace_authority
let apply_http_scoped_refresh_failure state ~mailbox:_ ~refresh_ticket:_ ~approval_ticket:_ ~latest:_ _ =
  state.failed <- state.failed + 1
let resume_reads_after_authority_change _ ~mailbox:_ ~refresh_inflight:_
    ~scoped_refresh_inflight:_ ~scoped_refresh_followup:_ ~before:_ = ()
let reset () =
  Queue.clear jobs;calls:=[];probes:=0;Queue.clear identity_readings;
  on_probe:=(fun _ -> ());on_transport:=(fun () -> ());Eio_context.switch:=Some ()
let drain () = while not (Queue.is_empty jobs) do (Queue.take jobs) () done
