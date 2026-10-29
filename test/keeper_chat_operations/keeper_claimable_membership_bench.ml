module Store = Keeper_chat_operation_store
module Operation = Keeper_chat_operation
module Semantic = Keeper_semantic_execution

let ok = function Ok value -> value | Error error -> failwith (Store.error_to_string error)
let text_ok = function Ok value -> value | Error error -> failwith error
let id n = Operation.Operation_id.of_string (Printf.sprintf "membership-%05d" n) |> text_ok
let input = `Assoc ["message", `String "preserve original work"]
let source = `Assoc ["kind", `String "benchmark"]
let sizes = [0; 1; 32; 256; 1024]
let file root layout n = Filename.concat root (Printf.sprintf "%s-%d.sqlite3" layout n)
let with_store path f =
  let store = Store.open_or_create ~path |> ok in
  Fun.protect ~finally:(fun () -> Store.close store |> ok) (fun () -> f store)

let seed root n =
  with_store (file root "prefix" n) (fun store ->
  let trace_id = Keeper_id.Trace_id.of_string "membership-fixture" |> text_ok in
  let checkpoint = Keeper_checkpoint_ref.of_persisted ~trace_id ~turn_count:1
    ~sha256:(Keeper_checkpoint_ref.sha256_of_canonical_bytes "retained checkpoint") |> function
    | Ok value -> value | Error _ -> failwith "invalid fixture checkpoint" in
  let retry = Semantic.runtime_retry ~not_before:(Some 100.) ~checkpoint
    ~assignment_id:"membership-fixture" ~failed_runtime_id:"provider-a"
    ~next_runtime_id:"provider-b" ~later_runtime_ids:[] |> text_ok in
  for index = 0 to n - 1 do
    let operation_id = id index in
    Store.submit store ~now:1. ~operation_id ~source ~input |> ok |> ignore;
    let running = Store.claim_next store ~now:2. |> ok |> Option.get in
    assert (Operation.Operation_id.equal operation_id running.operation_id);
    Store.defer_direct_runtime_retry store ~now:3. ~operation_id
      ~execution_digest:running.execution_digest ~continuation:retry |> ok |> ignore
  done;
  assert (not (Store.has_claimable_queued store ~now:4. |> ok));
  Store.submit store ~now:4. ~operation_id:(id n) ~source ~input |> ok |> ignore;
  assert (Store.has_claimable_queued store ~now:5. |> ok));
  In_channel.with_open_bin (file root "prefix" n) (fun source ->
    Out_channel.with_open_bin (file root "front" n) (fun target ->
      Out_channel.output_string target (In_channel.input_all source)));
  with_store (file root "front" n) (fun store ->
    Store.move_queued_to_front store ~now:5. ~operation_id:(id n) |> ok |> ignore)

let sample store ~now =
  Gc.full_major ();
  let before = Gc.allocated_bytes () in
  let start = Mtime_clock.counter () in
  let ready = Store.has_claimable_queued store ~now |> ok in
  let elapsed_ms = Mtime.Span.to_float_ns (Mtime_clock.count start) /. 1_000_000. in
  let allocated_bytes = Gc.allocated_bytes () -. before in
  ready, elapsed_ms, allocated_bytes

let quantile q samples =
  let values = Array.of_list (List.sort Float.compare samples) in
  values.(int_of_float (q *. float_of_int (Array.length values - 1)))

let measure root n =
  List.iter (fun (layout, now) -> with_store (file root layout n) (fun store ->
    for _ = 1 to 5 do ignore (sample store ~now) done;
    let samples = List.init 41 (fun _ -> sample store ~now) in
    assert (List.for_all (fun (ready, _, _) -> ready) samples);
    let times = List.map (fun (_, time, _) -> time) samples in
    let allocations = List.map (fun (_, _, bytes) -> bytes) samples in
    Printf.printf "%s\n%!" (Yojson.Safe.to_string (`Assoc
      ["deferred_rows", `Int n; "layout", `String layout; "observation_time", `Float now;
       "samples", `Int 41; "ready", `Bool true;
       "p50_ms", `Float (quantile 0.5 times);
       "p95_ms", `Float (quantile 0.95 times);
       "p50_allocated_bytes", `Float (quantile 0.5 allocations)]))))
    ["prefix", 5.; "prefix", 100.; "front", 5.]

let control root layout now n = with_store (file root layout n) (fun store ->
  let expected = if String.equal layout "front" || now < 100. || n = 0 then id n else id 0 in
  let claimed = Store.claim_next store ~now |> ok |> Option.get in
  assert (Operation.Operation_id.equal expected claimed.operation_id);
  Printf.printf "%s\n%!" (Yojson.Safe.to_string (`Assoc
    ["deferred_rows", `Int n; "layout", `String layout; "observation_time", `Float now;
     "claimed", `String (Operation.Operation_id.to_string claimed.operation_id)])))

let () =
  match Array.to_list Sys.argv with
  | [_; "seed"; root] -> List.iter (seed root) sizes
  | [_; "measure"; root] -> List.iter (measure root) sizes
  | [_; "control"; root; ("prefix" | "front" as layout); now] ->
    List.iter (control root layout (float_of_string now)) sizes
  | _ -> failwith "usage: keeper_claimable_membership_bench (seed|measure) directory, or control directory (prefix|front) now"
