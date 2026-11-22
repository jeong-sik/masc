type unit_kind =
  | Count
  | Rate_per_sec
  | Percent
  | Milliseconds
  | Bytes
  | Tokens
  | Usd
  | Candles

type cost_state =
  | Amount of float
  | Subscription_zero
  | Exhausted_zero
  | Unreported

let format_compact_number v =
  let abs_v = Float.abs v in
  let sign = if v < 0. then "-" else "" in
  if abs_v >= 1e9 then Printf.sprintf "%s%.1fB" sign (abs_v /. 1e9)
  else if abs_v >= 1e6 then Printf.sprintf "%s%.1fM" sign (abs_v /. 1e6)
  else if abs_v >= 1e3 then Printf.sprintf "%s%.1fk" sign (abs_v /. 1e3)
  else if Float.abs (abs_v -. Float.round abs_v) < 0.005 then
    Printf.sprintf "%s%.0f" sign abs_v
  else Printf.sprintf "%s%.1f" sign abs_v

let format_bytes v =
  let abs_v = Float.abs v in
  let sign = if v < 0. then "-" else "" in
  let kib = 1024. in
  let mib = kib *. 1024. in
  let gib = mib *. 1024. in
  let tib = gib *. 1024. in
  if abs_v >= tib then Printf.sprintf "%s%.1f TiB" sign (abs_v /. tib)
  else if abs_v >= gib then Printf.sprintf "%s%.1f GiB" sign (abs_v /. gib)
  else if abs_v >= mib then Printf.sprintf "%s%.1f MiB" sign (abs_v /. mib)
  else if abs_v >= kib then Printf.sprintf "%s%.1f KiB" sign (abs_v /. kib)
  else Printf.sprintf "%s%.0f B" sign abs_v

let format_ms v =
  let abs_v = Float.abs v in
  let sign = if v < 0. then "-" else "" in
  if abs_v >= 60_000. then Printf.sprintf "%s%.1fm" sign (abs_v /. 60_000.)
  else if abs_v >= 1_000. then Printf.sprintf "%s%.1fs" sign (abs_v /. 1_000.)
  else if abs_v >= 100. then Printf.sprintf "%s%.0fms" sign abs_v
  else Printf.sprintf "%s%.1fms" sign abs_v

let format_usd v =
  if v < 0. then Printf.sprintf "-$%.2f" (Float.abs v)
  else Printf.sprintf "$%.2f" v

let format_value unit_kind v =
  if not (Float.is_finite v) then Glyph.to_utf8 Glyph.Missing_unreported
  else
    match unit_kind with
    | Count -> format_compact_number v
    | Rate_per_sec -> format_compact_number v ^ "/s"
    | Percent -> Printf.sprintf "%.1f%%" v
    | Milliseconds -> format_ms v
    | Bytes -> format_bytes v
    | Tokens -> format_compact_number v ^ " tok"
    | Usd -> format_usd v
    | Candles -> Printf.sprintf "%.3f C" v

let unreported_label =
  Say.make ~ko:"? 미보고" ~en:"? Unreported"

let failed_label =
  Say.make ~ko:"✕ 오류" ~en:"✕ Error"

let sub_zero_label =
  Say.make ~ko:"$0 구독" ~en:"$0 Sub"

let exhausted_zero_label =
  Say.make ~ko:"$0 소진" ~en:"$0 Exhausted"

let format_observed unit_kind obs ~lang =
  match obs with
  | Observed.Loading _ -> Glyph.to_utf8 Glyph.Ellipsis
  | Observed.Absent -> Glyph.to_utf8 Glyph.Missing_absent
  | Observed.Unreported -> Say.resolve lang unreported_label
  | Observed.Failed _ -> Say.resolve lang failed_label
  | Observed.Value { data; stale; observed_at = _ } ->
      let formatted = format_value unit_kind data in
      if stale then
        Printf.sprintf "%s %s" (Glyph.to_utf8 Glyph.Transport_stale) formatted
      else formatted

let format_cost state ~lang =
  match state with
  | Amount v -> format_value Usd v
  | Subscription_zero -> Say.resolve lang sub_zero_label
  | Exhausted_zero -> Say.resolve lang exhausted_zero_label
  | Unreported -> Say.resolve lang unreported_label

let format_delta_pct pct =
  if not (Float.is_finite pct) then Glyph.to_utf8 Glyph.Missing_unreported
  else if pct > 0.05 then
    Printf.sprintf "%s+%.1f%%" (Glyph.to_utf8 Glyph.Delta_up) pct
  else if pct < -0.05 then
    Printf.sprintf "%s-%.1f%%" (Glyph.to_utf8 Glyph.Delta_down) (Float.abs pct)
  else Printf.sprintf "%s0.0%%" (Glyph.to_utf8 Glyph.Delta_flat)

let format_duration_s seconds =
  if not (Float.is_finite seconds) || seconds < 0. then
    Glyph.to_utf8 Glyph.Missing_unreported
  else
    let total = int_of_float seconds in
    if total < 60 then Printf.sprintf "%ds" total
    else if total < 3600 then
      let m = total / 60 and s = total mod 60 in
      if s = 0 then Printf.sprintf "%dm" m else Printf.sprintf "%dm%ds" m s
    else if total < 86400 then
      let h = total / 3600 and m = (total mod 3600) / 60 in
      if m = 0 then Printf.sprintf "%dh" h else Printf.sprintf "%dh%02dm" h m
    else
      let d = total / 86400 and h = (total mod 86400) / 3600 in
      if h = 0 then Printf.sprintf "%dd" d else Printf.sprintf "%dd%dh" d h
