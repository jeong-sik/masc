(** Runtime-observables read surface (masc#29023 follow-up).

    The store writer landing cells is only half the feature: the dashboard
    endpoint must serve every family the writer lands, or a sample ships
    invisible. Coverage is asserted structurally — every sample name the
    writer produces must be in [served_metric_names] — and behaviorally:
    after one writer pass the endpoint JSON carries the written values. *)

open Alcotest
module Obs = Masc.Otel_runtime_observables
module Endpoint = Server_dashboard_http_runtime_observables

let member key = function
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None
;;

let with_temp_masc_root f =
  let root =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "runtime-obs-endpoint-%d" (Unix.getpid ()))
  in
  let store = Filename.concat root "logs" in
  Unix.mkdir root 0o755;
  Unix.mkdir store 0o755;
  let oc = open_out (Filename.concat store "runtime.log") in
  output_string oc "one line of log payload\n";
  close_out oc;
  Fun.protect
    ~finally:(fun () ->
      Sys.remove (Filename.concat store "runtime.log");
      Unix.rmdir store;
      Unix.rmdir root)
    (fun () -> f root)
;;

(* Drift guard: a new sample family in the writer without a matching row in
   the endpoint fails here, not silently in production. *)
let test_every_sample_name_is_served () =
  with_temp_masc_root (fun root ->
    Obs.For_testing.reset_store_cache ();
    let samples = Obs.For_testing.samples ~masc_root:root () in
    List.iter
      (fun (s : Otel_metrics.sample) ->
         check
           bool
           (Printf.sprintf "sample %s has an endpoint row" s.name)
           true
           (List.exists (String.equal s.name) Endpoint.served_metric_names))
      samples)
;;

let test_endpoint_serves_written_cells () =
  with_temp_masc_root (fun root ->
    Obs.For_testing.reset_store_cache ();
    let written = Obs.For_testing.write_samples_to_store ~masc_root:root () in
    check bool "writer landed at least the core samples" true (written >= 3);
    let json = Endpoint.runtime_observables_http_json () in
    (match member "console_sink" json with
     | Some console ->
       (match member "queue_depth" console with
        | Some (`Int depth) -> check bool "console queue depth is an int" true (depth >= 0)
        | _ -> fail "console_sink.queue_depth missing or null after a write")
     | None -> fail "console_sink block missing");
    (match member "transition_audit" json with
     | Some audit ->
       (match member "queue_depth" audit with
        | Some (`Int depth) -> check bool "audit queue depth is an int" true (depth >= 0)
        | _ -> fail "transition_audit.queue_depth missing or null after a write")
     | None -> fail "transition_audit block missing");
    (match member "stores" json with
     | Some (`List entries) ->
       let logs_entry =
         List.find_opt
           (fun entry ->
              match member "store" entry with
              | Some (`String store) -> String.equal store "logs"
              | _ -> false)
           entries
       in
       (match logs_entry with
        | Some entry ->
          (match member "bytes" entry with
           | Some (`Int bytes) ->
             check bool "walked store reports its payload bytes" true (bytes > 0)
           | _ -> fail "stores.logs.bytes missing")
        | None -> fail "written watched store missing from stores block")
     | _ -> fail "stores block missing");
    match member "last_write_unixtime" json, member "age_seconds" json with
    | Some (`Float t), Some (`Float age) ->
      check bool "last write stamp is a real unix time" true (t > 0.0);
      check bool "age is non-negative" true (age >= 0.0)
    | _ -> fail "freshness stamp missing after a write")
;;

let () =
  run
    "server_dashboard_runtime_observables"
    [ ( "runtime-observables read surface"
      , [ test_case
            "every writer sample name is served"
            `Quick
            test_every_sample_name_is_served
        ; test_case
            "endpoint serves written cells"
            `Quick
            test_endpoint_serves_written_cells
        ] )
    ]
;;
