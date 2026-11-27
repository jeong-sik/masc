(** Agent-core metrics collection — counters and histograms.

    Instance-based: each [create ()] returns independent state.
    Thread-safe via Eio.Mutex. *)

(* -- Internal types --------------------------------------------------- *)

type label_key = (string * string) list

let label_key_of labels = List.sort (fun (a, _) (b, _) -> String.compare a b) labels

module LabelMap = Map.Make (struct
    type t = label_key

    let compare = compare
  end)

(* -- Counter ---------------------------------------------------------- *)

type counter_data =
  { c_name : string
  ; c_unit : string
  ; c_values : int LabelMap.t
  }

(* -- Histogram -------------------------------------------------------- *)

type histogram_series =
  { hs_bucket_counts : int array
  ; hs_sum : float
  ; hs_count : int
  }

type histogram_data =
  { h_name : string
  ; h_buckets : float list
  ; h_sorted_buckets : float array
  ; h_values : histogram_series LabelMap.t
  }

let empty_histogram_series n =
  { hs_bucket_counts = Array.make n 0; hs_sum = 0.0; hs_count = 0 }
;;

let empty_histogram_values n = LabelMap.singleton [] (empty_histogram_series n)

(* -- Metrics instance ------------------------------------------------- *)

type t =
  { mu : Eio.Mutex.t
  ; mutable counters : counter_data list
  ; mutable histograms : histogram_data list
  }

type counter = t * string
type histogram = t * string

let create () = { mu = Eio.Mutex.create (); counters = []; histograms = [] }
let with_lock t f = Eio.Mutex.use_rw ~protect:true t.mu f

(* Prometheus identifier normalization, hoisted above the registration
   functions so they can detect post-normalization collisions at
   register time. The text-export call sites below reuse the same
   helper. *)
let is_identifier_start = function
  | 'A' .. 'Z' | 'a' .. 'z' | '_' | ':' -> true
  | _ -> false
;;

let is_identifier_char = function
  | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '_' | ':' -> true
  | _ -> false
;;

let prometheus_identifier raw =
  let buf = Buffer.create (String.length raw + 1) in
  String.iteri
    (fun index ch ->
       let valid = if index = 0 then is_identifier_start ch else is_identifier_char ch in
       Buffer.add_char buf (if valid then ch else '_'))
    raw;
  let rendered = Buffer.contents buf in
  if String.equal rendered "" then "_" else rendered
;;

(* [check_no_normalized_collision_unlocked t ~kind ~name] raises
   [Invalid_argument] if registering [name] would emit a Prometheus
   metric whose [prometheus_identifier]-normalized name clashes with
   a *different* registered name in [t] (across counters and
   histograms). Re-registering the exact same [name] under the same
   kind is the idempotent path and skips this check; only true
   collisions (e.g. [foo.bar] vs [foo_bar], or a counter and a
   histogram that normalize to the same name) are rejected.

   Detecting at register time stops the text-export emit path from
   producing duplicate # HELP / # TYPE blocks for a single Prometheus
   metric name — a violation of the text exposition format. Caller
   must already hold the instance lock. *)
let check_no_normalized_collision_unlocked t ~kind ~name =
  let prom_name = prometheus_identifier name in
  let collides_with existing_kind raw =
    if String.equal raw name && String.equal existing_kind kind
    then false (* same name + same kind = idempotent re-register *)
    else String.equal (prometheus_identifier raw) prom_name
  in
  let collision_msg existing_kind raw =
    Printf.sprintf
      "Metrics.%s: name %S normalizes to %S, which collides with the \
       already-registered %s %S"
      kind
      name
      prom_name
      existing_kind
      raw
  in
  match List.find_opt (fun c -> collides_with "counter" c.c_name) t.counters with
  | Some c -> Error (collision_msg "counter" c.c_name)
  | None ->
    (match List.find_opt (fun h -> collides_with "histogram" h.h_name) t.histograms with
     | Some h -> Error (collision_msg "histogram" h.h_name)
     | None -> Ok ())
;;

(* [check_no_duplicate_buckets ~name ~buckets] returns [Error msg] if [buckets]
   contains the same bound twice. Raising inside [Eio.Mutex.use_rw] would poison
   the mutex, so registration helpers return [Result.t] from the critical
   section and raise [Invalid_argument] only after unlocking. *)
let check_no_duplicate_buckets ~name ~buckets =
  let sorted = List.sort Float.compare buckets in
  let rec find_dup = function
    | a :: (b :: _ as rest) ->
      if Float.equal a b
      then
        Error
          (Printf.sprintf
             "Metrics.histogram: name %S has duplicate bucket bound %g"
             name
             a)
      else find_dup rest
    | _ -> Ok ()
  in
  find_dup sorted
;;

let counter t ~name ~unit_ =
  match
    with_lock t (fun () ->
      match List.find_opt (fun c -> c.c_name = name) t.counters with
      | Some _ -> Ok (t, name)
      | None ->
        (match check_no_normalized_collision_unlocked t ~kind:"counter" ~name with
         | Error msg -> Error msg
         | Ok () ->
           let c = { c_name = name; c_unit = unit_; c_values = LabelMap.empty } in
           t.counters <- c :: t.counters;
           Ok (t, name)))
  with
  | Ok counter -> counter
  | Error msg -> invalid_arg msg
;;

let histogram t ~name ~buckets =
  match
    with_lock t (fun () ->
      match List.find_opt (fun h -> h.h_name = name) t.histograms with
      | Some _ -> Ok (t, name)
      | None ->
        (match check_no_normalized_collision_unlocked t ~kind:"histogram" ~name with
         | Error msg -> Error msg
         | Ok () ->
           (match check_no_duplicate_buckets ~name ~buckets with
            | Error msg -> Error msg
            | Ok () ->
              let sorted_buckets = Array.of_list (List.sort Float.compare buckets) in
              let h =
                { h_name = name
                ; h_buckets = buckets
                ; h_sorted_buckets = sorted_buckets
                ; h_values = empty_histogram_values (Array.length sorted_buckets)
                }
              in
              t.histograms <- h :: t.histograms;
              Ok (t, name))))
  with
  | Ok histogram -> histogram
  | Error msg -> invalid_arg msg
;;

let incr (t, name) ?(labels = []) n =
  let key = label_key_of labels in
  with_lock t (fun () ->
    t.counters
    <- List.map
         (fun c ->
            if c.c_name = name
            then (
              let current =
                match LabelMap.find_opt key c.c_values with
                | Some v -> v
                | None -> 0
              in
              { c with c_values = LabelMap.add key (current + n) c.c_values })
            else c)
         t.counters)
;;

let counter_value (t, name) ?(labels = []) () =
  let key = label_key_of labels in
  with_lock t (fun () ->
    match List.find_opt (fun c -> c.c_name = name) t.counters with
    | Some c ->
      (match LabelMap.find_opt key c.c_values with
       | Some v -> v
       | None -> 0)
    | None -> 0)
;;

let observe (t, name) ?(labels = []) value =
  let key = label_key_of labels in
  with_lock t (fun () ->
    t.histograms
    <- List.map
         (fun h ->
            if h.h_name = name
            then (
              let bucket_n = Array.length h.h_sorted_buckets in
              let series =
                match LabelMap.find_opt key h.h_values with
                | Some series -> series
                | None -> empty_histogram_series bucket_n
              in
              let next_counts =
                Array.init bucket_n (fun i ->
                  series.hs_bucket_counts.(i)
                  + if value <= h.h_sorted_buckets.(i) then 1 else 0)
              in
              let updated =
                { hs_bucket_counts = next_counts
                ; hs_sum = series.hs_sum +. value
                ; hs_count = series.hs_count + 1
                }
              in
              { h with h_values = LabelMap.add key updated h.h_values })
            else h)
         t.histograms)
;;

let histogram_count ?labels (t, name) =
  with_lock t (fun () ->
    match List.find_opt (fun h -> h.h_name = name) t.histograms with
    | Some h ->
      (match labels with
       | Some labels ->
         let key = label_key_of labels in
         (match LabelMap.find_opt key h.h_values with
          | Some series -> series.hs_count
          | None -> 0)
       | None -> LabelMap.fold (fun _ series acc -> acc + series.hs_count) h.h_values 0)
    | None -> 0)
;;

let reset t =
  with_lock t (fun () ->
    t.counters <- List.map (fun c -> { c with c_values = LabelMap.empty }) t.counters;
    t.histograms
    <- List.map
         (fun h ->
            { h with h_values = empty_histogram_values (Array.length h.h_sorted_buckets) })
         t.histograms)
;;

(* -- OTLP JSON export ------------------------------------------------ *)

let labels_to_json labels : Yojson.Safe.t =
  `List
    (List.map
       (fun (k, v) ->
          `Assoc [ "key", `String k; "value", `Assoc [ "stringValue", `String v ] ])
       labels)
;;

let counter_to_json (c : counter_data) : Yojson.Safe.t =
  let data_points =
    LabelMap.fold
      (fun labels value acc ->
         `Assoc
           [ "attributes", labels_to_json labels; "asInt", `String (string_of_int value) ]
         :: acc)
      c.c_values
      []
  in
  `Assoc
    [ "name", `String c.c_name
    ; "unit", `String c.c_unit
    ; "sum", `Assoc [ "dataPoints", `List data_points; "isMonotonic", `Bool true ]
    ]
;;

let histogram_datapoint_to_json buckets labels series : Yojson.Safe.t =
  let bc = Array.to_list series.hs_bucket_counts @ [ series.hs_count ] in
  let base =
    [ "count", `String (string_of_int series.hs_count)
    ; "sum", `Float series.hs_sum
    ; "bucketCounts", `List (List.map (fun n -> `String (string_of_int n)) bc)
    ; "explicitBounds", `List (List.map (fun b -> `Float b) buckets)
    ]
  in
  let fields =
    match labels with
    | [] -> base
    | _ -> ("attributes", labels_to_json labels) :: base
  in
  `Assoc fields
;;

let histogram_to_json (h : histogram_data) : Yojson.Safe.t =
  let data_points =
    LabelMap.fold
      (fun labels series acc ->
         histogram_datapoint_to_json h.h_buckets labels series :: acc)
      h.h_values
      []
  in
  `Assoc
    [ "name", `String h.h_name; "histogram", `Assoc [ "dataPoints", `List data_points ] ]
;;

let to_otlp_json t =
  with_lock t (fun () ->
    let scope_metrics =
      `Assoc
        [ "scope", `Assoc [ "name", `String "agent_core.metrics" ]
        ; ( "metrics"
          , `List
              (List.map counter_to_json t.counters
               @ List.map histogram_to_json t.histograms) )
        ]
    in
    `Assoc
      [ ( "resourceMetrics"
        , `List
            [ `Assoc
                [ ( "resource"
                  , `Assoc
                      [ ( "attributes"
                        , `List
                            [ `Assoc
                                [ "key", `String "service.name"
                                ; "value", `Assoc [ "stringValue", `String "agent_core" ]
                                ]
                            ] )
                      ] )
                ; "scopeMetrics", `List [ scope_metrics ]
                ]
            ] )
      ])
;;

(* -- Prometheus text export ------------------------------------------ *)
(* [prometheus_identifier] / [is_identifier_*] are defined above so the
   registration functions can detect post-normalization collisions. *)

let escape_prometheus_value raw =
  let buf = Buffer.create (String.length raw) in
  String.iter
    (function
      | '\\' -> Buffer.add_string buf "\\\\"
      | '"' -> Buffer.add_string buf "\\\""
      | '\n' -> Buffer.add_string buf "\\n"
      | ch -> Buffer.add_char buf ch)
    raw;
  Buffer.contents buf
;;

let float_to_prometheus value =
  match classify_float value with
  | FP_nan -> "NaN"
  | FP_infinite -> if value > 0.0 then "+Inf" else "-Inf"
  | FP_normal | FP_subnormal | FP_zero -> Printf.sprintf "%.17g" value
;;

let labels_to_prometheus labels =
  match labels with
  | [] -> ""
  | _ ->
    labels
    |> List.map (fun (key, value) ->
      Printf.sprintf
        "%s=\"%s\""
        (prometheus_identifier key)
        (escape_prometheus_value value))
    |> String.concat ","
    |> Printf.sprintf "{%s}"
;;

let add_prometheus_header buf ~name ~kind =
  let prom_name = prometheus_identifier name in
  Buffer.add_string buf (Printf.sprintf "# HELP %s %s\n" prom_name name);
  Buffer.add_string buf (Printf.sprintf "# TYPE %s %s\n" prom_name kind);
  prom_name
;;

let counter_to_prometheus buf (c : counter_data) =
  let prom_name = add_prometheus_header buf ~name:c.c_name ~kind:"counter" in
  LabelMap.iter
    (fun labels value ->
       Buffer.add_string
         buf
         (Printf.sprintf "%s%s %d\n" prom_name (labels_to_prometheus labels) value))
    c.c_values
;;

let histogram_to_prometheus buf (h : histogram_data) =
  let prom_name = add_prometheus_header buf ~name:h.h_name ~kind:"histogram" in
  LabelMap.iter
    (fun labels series ->
       Array.iteri
         (fun idx bound ->
            let count = series.hs_bucket_counts.(idx) in
            Buffer.add_string
              buf
              (Printf.sprintf
                 "%s_bucket%s %d\n"
                 prom_name
                 (labels_to_prometheus (labels @ [ "le", float_to_prometheus bound ]))
                 count))
         h.h_sorted_buckets;
       Buffer.add_string
         buf
         (Printf.sprintf
            "%s_bucket%s %d\n"
            prom_name
            (labels_to_prometheus (labels @ [ "le", "+Inf" ]))
            series.hs_count);
       Buffer.add_string
         buf
         (Printf.sprintf
            "%s_sum%s %s\n"
            prom_name
            (labels_to_prometheus labels)
            (float_to_prometheus series.hs_sum));
       Buffer.add_string
         buf
         (Printf.sprintf
            "%s_count%s %d\n"
            prom_name
            (labels_to_prometheus labels)
            series.hs_count))
    h.h_values
;;

let to_prometheus_text t =
  with_lock t (fun () ->
    let buf = Buffer.create 256 in
    let counters = List.sort (fun a b -> String.compare a.c_name b.c_name) t.counters in
    let histograms =
      List.sort (fun a b -> String.compare a.h_name b.h_name) t.histograms
    in
    List.iter (counter_to_prometheus buf) counters;
    List.iter (histogram_to_prometheus buf) histograms;
    Buffer.contents buf)
;;
