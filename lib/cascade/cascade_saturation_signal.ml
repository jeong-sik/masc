(** Cascade_saturation_signal — Typed signal for tier saturation events.

    RFC-0153 Phase A.1. See .mli for full documentation.

    Phase A.1 단독으로는 *동작 변경 없음* (variant 정의 + 직렬화 only).
    Phase A.2 가 caller 를 wire-in 한다. *)

type t =
  | Provider_rate_limited of {
      provider_id : string;
      retry_after_ms : int option;
    }
  | Time_cap_fired of {
      observed_latency_ms : int;
      cap_ms : int;
      provider_id : string option;
    }
  | All_tiers_filtered_after_cycles of {
      cascade_name : string;
      cycle_count : int;
    }
  | Inflight_capacity_full of {
      tier_id : string;
      max_inflight : int;
    }

type kind =
  | K_provider_rate_limited
  | K_time_cap_fired
  | K_all_tiers_filtered_after_cycles
  | K_inflight_capacity_full

let kind = function
  | Provider_rate_limited _ -> K_provider_rate_limited
  | Time_cap_fired _ -> K_time_cap_fired
  | All_tiers_filtered_after_cycles _ -> K_all_tiers_filtered_after_cycles
  | Inflight_capacity_full _ -> K_inflight_capacity_full

let kind_to_string = function
  | K_provider_rate_limited -> "provider_rate_limited"
  | K_time_cap_fired -> "time_cap_fired"
  | K_all_tiers_filtered_after_cycles -> "all_tiers_filtered_after_cycles"
  | K_inflight_capacity_full -> "inflight_capacity_full"

let to_metric_label t = kind_to_string (kind t)

let int_opt_field name v fields =
  match v with
  | None -> fields
  | Some n -> (name, `Int n) :: fields

let string_opt_field name v fields =
  match v with
  | None -> fields
  | Some s -> (name, `String s) :: fields

let to_yojson = function
  | Provider_rate_limited { provider_id; retry_after_ms } ->
      let fields =
        [ ("kind", `String "provider_rate_limited");
          ("provider_id", `String provider_id);
        ]
        |> int_opt_field "retry_after_ms" retry_after_ms
      in
      `Assoc fields
  | Time_cap_fired { observed_latency_ms; cap_ms; provider_id } ->
      let fields =
        [ ("kind", `String "time_cap_fired");
          ("observed_latency_ms", `Int observed_latency_ms);
          ("cap_ms", `Int cap_ms);
        ]
        |> string_opt_field "provider_id" provider_id
      in
      `Assoc fields
  | All_tiers_filtered_after_cycles { cascade_name; cycle_count } ->
      `Assoc
        [ ("kind", `String "all_tiers_filtered_after_cycles");
          ("cascade_name", `String cascade_name);
          ("cycle_count", `Int cycle_count);
        ]
  | Inflight_capacity_full { tier_id; max_inflight } ->
      `Assoc
        [ ("kind", `String "inflight_capacity_full");
          ("tier_id", `String tier_id);
          ("max_inflight", `Int max_inflight);
        ]

let to_log_string = function
  | Provider_rate_limited { provider_id; retry_after_ms } ->
      let retry =
        match retry_after_ms with
        | None -> ""
        | Some ms -> Printf.sprintf " retry_after_ms=%d" ms
      in
      Printf.sprintf "provider_rate_limited provider=%s%s" provider_id retry
  | Time_cap_fired { observed_latency_ms; cap_ms; provider_id } ->
      let prov =
        match provider_id with
        | None -> ""
        | Some p -> Printf.sprintf " provider=%s" p
      in
      Printf.sprintf "time_cap_fired observed_latency_ms=%d cap_ms=%d%s"
        observed_latency_ms cap_ms prov
  | All_tiers_filtered_after_cycles { cascade_name; cycle_count } ->
      Printf.sprintf "all_tiers_filtered_after_cycles cascade=%s cycles=%d"
        cascade_name cycle_count
  | Inflight_capacity_full { tier_id; max_inflight } ->
      Printf.sprintf "inflight_capacity_full tier=%s max_inflight=%d"
        tier_id max_inflight

let pp ppf t = Format.fprintf ppf "%s" (to_log_string t)

let equal a b =
  match (a, b) with
  | ( Provider_rate_limited { provider_id = p1; retry_after_ms = r1 },
      Provider_rate_limited { provider_id = p2; retry_after_ms = r2 } ) ->
      String.equal p1 p2 && Option.equal Int.equal r1 r2
  | ( Time_cap_fired
        { observed_latency_ms = l1; cap_ms = c1; provider_id = p1 },
      Time_cap_fired
        { observed_latency_ms = l2; cap_ms = c2; provider_id = p2 } ) ->
      Int.equal l1 l2 && Int.equal c1 c2 && Option.equal String.equal p1 p2
  | ( All_tiers_filtered_after_cycles
        { cascade_name = n1; cycle_count = c1 },
      All_tiers_filtered_after_cycles
        { cascade_name = n2; cycle_count = c2 } ) ->
      String.equal n1 n2 && Int.equal c1 c2
  | ( Inflight_capacity_full { tier_id = t1; max_inflight = m1 },
      Inflight_capacity_full { tier_id = t2; max_inflight = m2 } ) ->
      String.equal t1 t2 && Int.equal m1 m2
  | _, _ -> false

(* Yojson deserialization — used only in tests for round-trip validation.
   Production code path emits these signals; downstream typed match
   handles them. We do not parse them from JSON in the hot path. *)

let of_yojson json =
  let open Result in
  let assoc_of_json = function
    | `Assoc fields -> Ok fields
    | _ -> Error "expected JSON object"
  in
  let find_field name fields =
    match List.assoc_opt name fields with
    | Some v -> Ok v
    | None -> Error (Printf.sprintf "missing field: %s" name)
  in
  let as_string = function
    | `String s -> Ok s
    | _ -> Error "expected string"
  in
  let as_int = function
    | `Int n -> Ok n
    | _ -> Error "expected int"
  in
  let int_field name fields = bind (find_field name fields) as_int in
  let string_field name fields = bind (find_field name fields) as_string in
  let int_field_opt name fields =
    match List.assoc_opt name fields with
    | None | Some `Null -> Ok None
    | Some v -> bind (as_int v) (fun n -> Ok (Some n))
  in
  let string_field_opt name fields =
    match List.assoc_opt name fields with
    | None | Some `Null -> Ok None
    | Some v -> bind (as_string v) (fun s -> Ok (Some s))
  in
  bind (assoc_of_json json) (fun fields ->
      bind (string_field "kind" fields) (function
        | "provider_rate_limited" ->
            bind (string_field "provider_id" fields) (fun provider_id ->
                bind (int_field_opt "retry_after_ms" fields)
                  (fun retry_after_ms ->
                    Ok
                      (Provider_rate_limited
                         { provider_id; retry_after_ms })))
        | "time_cap_fired" ->
            bind (int_field "observed_latency_ms" fields)
              (fun observed_latency_ms ->
                bind (int_field "cap_ms" fields) (fun cap_ms ->
                    bind (string_field_opt "provider_id" fields)
                      (fun provider_id ->
                        Ok
                          (Time_cap_fired
                             { observed_latency_ms; cap_ms; provider_id }))))
        | "all_tiers_filtered_after_cycles" ->
            bind (string_field "cascade_name" fields) (fun cascade_name ->
                bind (int_field "cycle_count" fields) (fun cycle_count ->
                    Ok
                      (All_tiers_filtered_after_cycles
                         { cascade_name; cycle_count })))
        | "inflight_capacity_full" ->
            bind (string_field "tier_id" fields) (fun tier_id ->
                bind (int_field "max_inflight" fields) (fun max_inflight ->
                    Ok (Inflight_capacity_full { tier_id; max_inflight })))
        | other -> Error (Printf.sprintf "unknown kind: %s" other)))
