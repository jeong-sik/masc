(** Server Dashboard HTTP — fleet Keeper efficiency month view.

    [GET /api/v1/keeper-efficiency?month=YYYY-MM] answers the per-Keeper
    month aggregation the TUI Keepers view renders: distinct turns, resolved
    token/cost sums, tool call counts by disposition, tool milliseconds, and
    the run-weighted fleet row. [Keeper_efficiency] owns the computation and
    its per-day boundary cache; this module only carries the month query
    parameter, runs the blocking fold off the Eio domain, and writes the
    response. A missing [month] answers the wall clock's current month. *)

module Http = Http_server_eio

let route_path = "/api/v1/keeper-efficiency"

let current_month () =
  let t = Unix.gmtime (Unix.time ()) in
  Printf.sprintf "%04d-%02d" (t.Unix.tm_year + 1900) (t.Unix.tm_mon + 1)
;;

let month_parameter req =
  match Server_utils.query_param req "month" with
  | Some raw when String.trim raw <> "" -> String.trim raw
  | Some _ | None -> current_month ()
;;

let error_json code detail =
  `Assoc [ ("error", `String detail); ("code", `String code) ]
;;

let handle_get state req reqd =
  let month = month_parameter req in
  let masc_root =
    Common.masc_dir_from_base_path ~base_path:(Mcp_server.workspace_config state).base_path
  in
  (* [Keeper_efficiency.read_month] folds dated JSONL with blocking channel
     IO, exactly the shape the metrics tail routes off the Eio domain. *)
  let reading =
    Eio_guard.with_named_switch "keeper-efficiency" (fun () ->
        Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
            Keeper_efficiency.read_month ~masc_root ~month))
  in
  match reading with
  | Error detail ->
    Server_auth.respond_json_value_with_cors ~status:`Bad_request req reqd
      (error_json "keeper_efficiency_invalid_month" detail)
  | Ok view ->
    Http.Response.json_value ~status:`OK ~compress:true ~request:req
      ~extra_headers:(Server_auth.cors_headers (Server_auth.get_origin req))
      (Keeper_efficiency.month_view_to_json view) reqd
;;
