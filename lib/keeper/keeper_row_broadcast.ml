let row_changed_event = "keeper_row_changed"
let roster_changed_event = "keeper_roster_changed"

type target =
  | One_row of string
  | Every_row

let announce ~base_path target =
  let event, fields, keeper_label =
    match target with
    | One_row keeper_name ->
      row_changed_event, [ "name", `String keeper_name ], [ "keeper", keeper_name ]
    | Every_row -> roster_changed_event, [], []
  in
  let report exn =
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string SseBroadcastFailures)
      ~labels:(keeper_label @ [ "site", event ])
      ();
    Log.Keeper.warn
      "keeper_row_broadcast: %s %s failed: %s"
      event
      (Yojson.Safe.to_string (`Assoc fields))
      (Printexc.to_string exn)
  in
  (* Every caller has already committed its write, and the registry calls this
     inside its lifecycle key lock before its own bookkeeping. A cancellation
     raised here would skip that bookkeeping, so it is reported like any
     failure; the caller's next suspension point still sees it. *)
  match
    let authority = Sse.runtime_authority_exn ~base_path in
    Sse.broadcast_to (Sse.Runtime_observers authority)
      (`Assoc
        (("type", `String event) :: fields
         @ [ "ts_unix", `Float (Time_compat.now ()) ]))
  with
  | () -> ()
  | exception exn -> report exn
;;

let changed ~base_path ~keeper_name = announce ~base_path (One_row keeper_name)
let roster_changed ~base_path = announce ~base_path Every_row
