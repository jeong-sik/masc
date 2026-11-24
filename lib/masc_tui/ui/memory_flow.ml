open Masc_tui_core
open Masc_tui_term

type revision_tick = {
  rev : int;
  at_unix : float;
  added : int;
  removed : int;
}

type window_kind =
  | Window_24h
  | Window_7d
  | Window_30d
  | Window_revs of { from_rev : int; to_rev : int }

type chart_mode =
  | Flow_io
  | Net_total

type input = {
  revisions : revision_tick list;
  from_unix : float option;
  to_unix : float option;
  total_now : int;
  is_world : bool;
  window : window_kind;
}

type built = {
  spec : Chart.Spec.t;
  subtitle : Say.t option;
  observed_count : int;
}

let equal_chart_mode a b =
  match a, b with
  | Flow_io, Flow_io | Net_total, Net_total -> true
  | Flow_io, Net_total | Net_total, Flow_io -> false

let toggle_mode = function
  | Flow_io -> Net_total
  | Net_total -> Flow_io

let mode_label = function
  | Flow_io -> Say.make ~ko:"유입/유출 ▲▼" ~en:"Flow ▲/▼"
  | Net_total -> Say.make ~ko:"순 총량" ~en:"Net Total"

let chart_height_for ~avail_h =
  if avail_h >= 15 then 7
  else if avail_h >= 6 then 2
  else 0

let time_window_of_kind = function
  | Window_24h -> Chart.Time_window.Last_24h
  | Window_7d -> Chart.Time_window.Last_7d
  | Window_30d -> Chart.Time_window.Last_30d
  | Window_revs { from_rev; to_rev } ->
      Chart.Time_window.Rev_span { from_rev; to_rev }

let window_duration_s = function
  | Window_24h -> 86400.0
  | Window_7d -> 7.0 *. 86400.0
  | Window_30d -> 30.0 *. 86400.0
  | Window_revs _ -> 0.0

let bucket_count_for ~rev_count = function
  | Window_24h -> 24
  | Window_7d -> 28
  | Window_30d -> 30
  | Window_revs _ -> Int.min 48 (Int.max 1 rev_count)

let finite_pos v = Float.is_finite v && v > 0.0

let resolve_time_bounds ~now_unix (inp : input) (valid : revision_tick list) =
  match inp.from_unix, inp.to_unix with
  | Some a, Some b when finite_pos a && finite_pos b && b > a -> (a, b)
  | _ -> (
      match inp.window with
      | Window_revs _ -> (
          match valid with
          | [] -> (0.0, 0.0)
          | first :: rest ->
              let lo, hi =
                List.fold_left
                  (fun (mn, mx) (r : revision_tick) ->
                    (Float.min mn r.at_unix, Float.max mx r.at_unix))
                  (first.at_unix, first.at_unix)
                  rest
              in
              (lo, hi))
      | Window_24h | Window_7d | Window_30d ->
          let dur = window_duration_s inp.window in
          let max_tick =
            List.fold_left
              (fun acc (r : revision_tick) -> Float.max acc r.at_unix)
              0.0 valid
          in
          let hi =
            if finite_pos now_unix then Float.max now_unix max_tick
            else if finite_pos max_tick then max_tick
            else dur
          in
          (Float.max 0.0 (hi -. dur), hi))

let sample_of_int n =
  if n <= 0 then Chart.Series.Zero else Chart.Series.Value (float_of_int n)

let stats_of_array (arr : int array) =
  let n = Array.length arr in
  if n = 0 then (Observed.absent, Observed.absent, Observed.absent)
  else
    let sum = ref 0 in
    let peak = ref 0 in
    for i = 0 to n - 1 do
      let v = arr.(i) in
      sum := !sum + v;
      if v > !peak then peak := v
    done;
    let cur = float_of_int arr.(n - 1) in
    let pk = float_of_int !peak in
    let avg = float_of_int !sum /. float_of_int n in
    ( Observed.value ~observed_at:Clock.Mono.zero cur
    , Observed.value ~observed_at:Clock.Mono.zero pk
    , Observed.value ~observed_at:Clock.Mono.zero avg )

let build ~now_unix ~mode (inp : input) =
  let valid =
    inp.revisions
    |> List.filter (fun (r : revision_tick) -> finite_pos r.at_unix)
    |> List.sort (fun (a : revision_tick) (b : revision_tick) ->
           let tc = Float.compare a.at_unix b.at_unix in
           if tc <> 0 then tc else Int.compare a.rev b.rev)
  in
  let observed_count = List.length valid in
  let window = time_window_of_kind inp.window in
  let subtitle =
    match valid with
    | [] ->
        Some
          (Say.make
             ~ko:"창 내 관측 리비전 없음 · [w] 창 확대"
             ~en:"No observed revisions in window · [w] expand window")
    | [ single ] ->
        Some
          (Say.make
             ~ko:(Printf.sprintf "관측 리비전 1건 (r%d)" single.rev)
             ~en:(Printf.sprintf "1 observed revision (r%d)" single.rev))
    | _ :: _ :: _ -> None
  in
  let hotkey_hint = Some "[M]" in
  let title =
    match mode with
    | Flow_io ->
        Say.make ~ko:"기억 흐름 ▲/▼" ~en:"Memory Flow ▲/▼"
    | Net_total ->
        if inp.is_world then
          Say.make ~ko:"기억 총량 (주장)" ~en:"Memory Net Total (claims)"
        else
          Say.make ~ko:"기억 총량 (사실)" ~en:"Memory Net Total (facts)"
  in
  match observed_count with
  | 0 ->
      let empty_series label gradient : Chart.Series.t =
        {
          label;
          unit = Format_val.Count;
          gradient;
          samples = [||];
          current = Observed.absent;
          peak = Observed.absent;
          avg = Observed.absent;
          delta_pct = None;
        }
      in
      let kind =
        match mode with
        | Flow_io ->
            Chart.Spec.Dual_inverted
              {
                upper =
                  empty_series
                    (Say.make ~ko:"+추가" ~en:"+Added")
                    Chart.Gradient.Efficiency;
                lower =
                  empty_series
                    (Say.make ~ko:"-제거" ~en:"-Removed")
                    Chart.Gradient.Warm_flow;
                scale = Chart.Scale.Synced_pair;
                window;
              }
        | Net_total ->
            Chart.Spec.Time_series
              {
                series =
                  empty_series
                    (Say.make ~ko:"총량" ~en:"Total")
                    Chart.Gradient.Ai_flow;
                scale = Chart.Scale.Auto_ceil { floor = 0.0; nice_step = true };
                window;
              }
      in
      {
        spec = { Chart.Spec.title; kind; hotkey_hint };
        subtitle;
        observed_count = 0;
      }
  | 1 -> (
      let single = List.hd valid in
      let kind =
        match mode with
        | Flow_io ->
            let up_arr = [| Int.max 0 single.added |] in
            let dn_arr = [| Int.max 0 single.removed |] in
            let up_cur, up_pk, up_avg = stats_of_array up_arr in
            let dn_cur, dn_pk, dn_avg = stats_of_array dn_arr in
            Chart.Spec.Dual_inverted
              {
                upper =
                  {
                    label = Say.make ~ko:"+추가" ~en:"+Added";
                    unit = Format_val.Count;
                    gradient = Chart.Gradient.Efficiency;
                    samples = [| sample_of_int up_arr.(0) |];
                    current = up_cur;
                    peak = up_pk;
                    avg = up_avg;
                    delta_pct = None;
                  };
                lower =
                  {
                    label = Say.make ~ko:"-제거" ~en:"-Removed";
                    unit = Format_val.Count;
                    gradient = Chart.Gradient.Warm_flow;
                    samples = [| sample_of_int dn_arr.(0) |];
                    current = dn_cur;
                    peak = dn_pk;
                    avg = dn_avg;
                    delta_pct = None;
                  };
                scale = Chart.Scale.Synced_pair;
                window;
              }
        | Net_total ->
            let tot = Int.max 0 inp.total_now in
            let tot_arr = [| tot |] in
            let cur, pk, avg = stats_of_array tot_arr in
            Chart.Spec.Time_series
              {
                series =
                  {
                    label = Say.make ~ko:"총량" ~en:"Total";
                    unit = Format_val.Count;
                    gradient = Chart.Gradient.Ai_flow;
                    samples = [| sample_of_int tot |];
                    current = cur;
                    peak = pk;
                    avg;
                    delta_pct = None;
                  };
                scale = Chart.Scale.Auto_ceil { floor = 0.0; nice_step = true };
                window;
              }
      in
      {
        spec = { Chart.Spec.title; kind; hotkey_hint };
        subtitle;
        observed_count = 1;
      })
  | _ ->
      let n_buckets = bucket_count_for ~rev_count:observed_count inp.window in
      let t_start, t_end = resolve_time_bounds ~now_unix inp valid in
      let span = t_end -. t_start in
      let added_b = Array.make n_buckets 0 in
      let removed_b = Array.make n_buckets 0 in
      List.iteri
        (fun idx (r : revision_tick) ->
          let bi =
            if span > 0.0 then
              let ratio = (r.at_unix -. t_start) /. span in
              let clamped = Float.max 0.0 (Float.min 1.0 ratio) in
              let raw = int_of_float (Float.floor (clamped *. float_of_int n_buckets)) in
              Int.max 0 (Int.min (n_buckets - 1) raw)
            else
              let raw = idx * n_buckets / Int.max 1 observed_count in
              Int.max 0 (Int.min (n_buckets - 1) raw)
          in
          added_b.(bi) <- added_b.(bi) + Int.max 0 r.added;
          removed_b.(bi) <- removed_b.(bi) + Int.max 0 r.removed)
        valid;
      let kind =
        match mode with
        | Flow_io ->
            let up_cur, up_pk, up_avg = stats_of_array added_b in
            let dn_cur, dn_pk, dn_avg = stats_of_array removed_b in
            Chart.Spec.Dual_inverted
              {
                upper =
                  {
                    label = Say.make ~ko:"+추가" ~en:"+Added";
                    unit = Format_val.Count;
                    gradient = Chart.Gradient.Efficiency;
                    samples = Array.map sample_of_int added_b;
                    current = up_cur;
                    peak = up_pk;
                    avg = up_avg;
                    delta_pct = None;
                  };
                lower =
                  {
                    label = Say.make ~ko:"-제거" ~en:"-Removed";
                    unit = Format_val.Count;
                    gradient = Chart.Gradient.Warm_flow;
                    samples = Array.map sample_of_int removed_b;
                    current = dn_cur;
                    peak = dn_pk;
                    avg = dn_avg;
                    delta_pct = None;
                  };
                scale = Chart.Scale.Synced_pair;
                window;
              }
        | Net_total ->
            let net_window_delta =
              let acc = ref 0 in
              for i = 0 to n_buckets - 1 do
                acc := !acc + added_b.(i) - removed_b.(i)
              done;
              !acc
            in
            let running = ref (Int.max 0 (inp.total_now - net_window_delta)) in
            let stock =
              Array.init n_buckets (fun i ->
                  running := Int.max 0 (!running + added_b.(i) - removed_b.(i));
                  !running)
            in
            let cur, pk, avg = stats_of_array stock in
            let delta_pct =
              let first = stock.(0) in
              let last = stock.(n_buckets - 1) in
              if first > 0 then
                Some (100.0 *. float_of_int (last - first) /. float_of_int first)
              else None
            in
            Chart.Spec.Time_series
              {
                series =
                  {
                    label = Say.make ~ko:"총량" ~en:"Total";
                    unit = Format_val.Count;
                    gradient = Chart.Gradient.Ai_flow;
                    samples = Array.map sample_of_int stock;
                    current = cur;
                    peak = pk;
                    avg;
                    delta_pct;
                  };
                scale = Chart.Scale.Auto_ceil { floor = 0.0; nice_step = true };
                window;
              }
      in
      {
        spec = { Chart.Spec.title; kind; hotkey_hint };
        subtitle = None;
        observed_count;
      }

let draw grid ~(rect : Rect.t) ~(theme : Theme.t) ~caps ~lang ~now_unix ~mode
    inp =
  if Rect.is_empty rect then ()
  else
    let built = build ~now_unix ~mode inp in
    let bg = Color.of_rgb theme.surface_1 in
    match built.observed_count, built.subtitle with
    | 0, Some notice ->
        (* Honest empty state with title row + whisper notice, zero synthetic plot *)
        let hdr =
          Printf.sprintf "%s  %s"
            (Say.resolve lang built.spec.title)
            (Say.resolve lang (mode_label mode))
        in
        ignore
          (Cell_grid.put_text ~clip:rect grid ~x:rect.x ~y:rect.y
             ~style:(Typography.structure ~bg ~bold:true theme)
             (Grapheme.truncate_to_width ~max_width:rect.w hdr));
        if rect.h >= 2 then begin
          let msg = Say.resolve lang notice in
          let mid_y = rect.y + Int.max 1 (rect.h / 2) in
          let fit = Grapheme.truncate_to_width ~max_width:rect.w msg in
          let cx =
            rect.x + Int.max 0 ((rect.w - Grapheme.display_width fit) / 2)
          in
          ignore
            (Cell_grid.put_text ~clip:rect grid ~x:cx ~y:mid_y
               ~style:(Typography.whisper ~bg theme)
               fit)
        end
    | 1, Some sub when rect.h >= 3 ->
        let chart_r =
          Rect.make ~x:rect.x ~y:rect.y ~w:rect.w ~h:(rect.h - 1)
        in
        ignore
          (Chart.draw grid ~rect:chart_r ~theme ~caps ~lang ~show_title:true
             built.spec);
        let sub_txt = Say.resolve lang sub in
        ignore
          (Cell_grid.put_text ~clip:rect grid ~x:rect.x
             ~y:(Rect.bottom rect - 1)
             ~style:(Typography.whisper ~bg theme)
             (Grapheme.truncate_to_width ~max_width:rect.w sub_txt))
    | _ ->
        ignore
          (Chart.draw grid ~rect ~theme ~caps ~lang ~show_title:true built.spec)
