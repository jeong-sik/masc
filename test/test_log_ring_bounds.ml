(** Log.Ring live-window bounds (feature-matrix Log row, 08-17 audit).

    The ring retains only the last [capacity] sequences, so a query
    that comes back empty is ambiguous without bounds: "never
    happened" and "evicted from the window" look identical. These
    tests pin the [bounds] contract and its ride-along on the
    dashboard logs response:

      1. Below capacity: [start_seq = 0], [dropped_before = false].
      2. Past capacity: [start_seq = total - capacity],
         [dropped_before = true], and a [since_seq] query below
         [start_seq] returning nothing coincides with bounds that
         SAY the window is cut.
      3. The dashboard logs JSON carries the [ring] object verbatim. *)

open Masc

let emit_n n =
  for i = 1 to n do
    Log.Misc.info "ring-bounds filler %d" i
  done

let test_bounds_below_capacity () =
  let before = Log.Ring.bounds () in
  emit_n 10;
  let b = Log.Ring.bounds () in
  Alcotest.(check int) "total grew by 10" (before.Log.Ring.total + 10) b.Log.Ring.total;
  if b.Log.Ring.total <= Log.Ring.capacity then begin
    Alcotest.(check int) "start_seq is 0 below capacity" 0 b.Log.Ring.start_seq;
    Alcotest.(check bool) "nothing dropped below capacity" false
      b.Log.Ring.dropped_before
  end

let test_bounds_past_capacity () =
  emit_n (Log.Ring.capacity + 50);
  let b = Log.Ring.bounds () in
  Alcotest.(check bool) "past capacity: dropped_before" true
    b.Log.Ring.dropped_before;
  Alcotest.(check int) "start_seq = total - capacity"
    (b.Log.Ring.total - Log.Ring.capacity)
    b.Log.Ring.start_seq;
  (* A query pinned entirely below the window returns nothing — and the
     bounds are what tell the operator why. *)
  let below = max 0 (b.Log.Ring.start_seq - 10) in
  let entries =
    Log.Ring.recent ~limit:5 ~since_seq:below
      ~before_seq:(max 1 (b.Log.Ring.start_seq - 1)) ()
  in
  Alcotest.(check int) "window below start_seq is empty" 0 (List.length entries)

let member name = function
  | `Assoc fields -> List.assoc name fields
  | _ -> Alcotest.fail "logs json is not an object"

let test_dashboard_logs_json_carries_ring_bounds () =
  let base_dir =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-test-ring-bounds-%06x" (Random.bits ()))
  in
  let config = Workspace.default_config base_dir in
  let bounds = Log.Ring.bounds () in
  let json =
    Server_dashboard_logs_json.build ~config ~limit:5 ~level_filter:"all"
      ~applied_level:Log.Info ~min_level:0 ~module_filter:"" ~since_seq:None
      ~before_seq:None ~category_filter:None ~exclude_category:None
      ~ring_bounds:bounds []
  in
  match member "ring" json with
  | `Assoc ring ->
    Alcotest.(check int) "ring.start_seq"
      bounds.Log.Ring.start_seq
      (match List.assoc "start_seq" ring with
       | `Int i -> i
       | _ -> Alcotest.fail "start_seq not an int");
    Alcotest.(check int) "ring.total"
      bounds.Log.Ring.total
      (match List.assoc "total" ring with
       | `Int i -> i
       | _ -> Alcotest.fail "total not an int");
    Alcotest.(check bool) "ring.dropped_before"
      bounds.Log.Ring.dropped_before
      (match List.assoc "dropped_before" ring with
       | `Bool b -> b
       | _ -> Alcotest.fail "dropped_before not a bool")
  | _ -> Alcotest.fail "ring field missing or not an object"

let () =
  Alcotest.run "log_ring_bounds"
    [
      ( "bounds",
        [
          Alcotest.test_case "below capacity" `Quick test_bounds_below_capacity;
          Alcotest.test_case "past capacity" `Quick test_bounds_past_capacity;
          Alcotest.test_case "dashboard logs json carries ring bounds" `Quick
            test_dashboard_logs_json_carries_ring_bounds;
        ] );
    ]
