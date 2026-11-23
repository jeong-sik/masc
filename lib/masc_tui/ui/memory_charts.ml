module Format_val = Masc_tui_core.Format_val
module Glyph = Masc_tui_core.Glyph
module Observed = Masc_tui_core.Observed
module Rect = Masc_tui_core.Rect
module Say = Masc_tui_core.Say
module Theme = Masc_tui_core.Theme
module Cell_grid = Masc_tui_term.Cell_grid
module Color = Masc_tui_term.Color
module Grapheme = Masc_tui_term.Grapheme
module Presenter = Masc_tui_term.Presenter

let bin_count = 24

type edge =
  | Edge_hour
  | Edge_day
  | Edge_week
  | Edge_month

let edge_bin = function
  | Edge_hour -> 1
  | Edge_day -> 9
  | Edge_week -> 17
  | Edge_month -> 23

let edge_label = function
  | Edge_hour -> "1h"
  | Edge_day -> "1d"
  | Edge_week -> "7d"
  | Edge_month -> "30d"

type age_tier =
  | Tier_within_day
  | Tier_within_week
  | Tier_past_week

let age_tier_rank = function
  | Tier_within_day -> 0
  | Tier_within_week -> 1
  | Tier_past_week -> 2

let equal_age_tier a b = Int.equal (age_tier_rank a) (age_tier_rank b)

let tier_of_bin bin =
  if bin <= 8 then Tier_within_day
  else if bin <= 16 then Tier_within_week
  else Tier_past_week

type ladder_cell = {
  count : int;
  tier : age_tier;
  newest_bin : int;
  oldest_bin : int;
}

let merge_of_width width =
  if width >= 24 then Some 1
  else if width >= 12 then Some 2
  else if width >= 6 then Some 4
  else None

let validate_bins bins =
  if Array.length bins <> bin_count then
    Error
      (Printf.sprintf "expected %d age bins, got %d" bin_count
         (Array.length bins))
  else
    let rec check i =
      if i >= bin_count then Ok ()
      else if bins.(i) < 0 then
        Error (Printf.sprintf "age_bins.(%d) must be >= 0, got %d" i bins.(i))
      else check (i + 1)
    in
    check 0

let fold_bins ~merge bins =
  match validate_bins bins with
  | Error _ as err -> err
  | Ok () -> (
      match merge with
      | 1 | 2 | 4 ->
          let n_cells = bin_count / merge in
          let cells =
            List.init n_cells (fun cell_idx ->
                (* Oldest on left (bin 23), newest on right (bin 0). *)
                let oldest_bin = bin_count - 1 - (cell_idx * merge) in
                let newest_bin = oldest_bin - merge + 1 in
                let sum = ref 0 in
                for b = newest_bin to oldest_bin do
                  sum := !sum + bins.(b)
                done;
                {
                  count = !sum;
                  tier = tier_of_bin newest_bin;
                  newest_bin;
                  oldest_bin;
                })
          in
          Ok cells
      | other ->
          Error
            (Printf.sprintf "invalid merge factor %d (expected 1, 2, or 4)"
               other))

let tier_counts bins =
  match validate_bins bins with
  | Error _ as err -> err
  | Ok () ->
      let within_day = ref 0 in
      let within_week = ref 0 in
      let past_week = ref 0 in
      for b = 0 to bin_count - 1 do
        match tier_of_bin b with
        | Tier_within_day -> within_day := !within_day + bins.(b)
        | Tier_within_week -> within_week := !within_week + bins.(b)
        | Tier_past_week -> past_week := !past_week + bins.(b)
      done;
      Ok (!within_day, !within_week, !past_week)

let unicode_levels = [| "▁"; "▂"; "▃"; "▄"; "▅"; "▆"; "▇"; "█" |]
let ascii_levels = [| "."; ":"; "-"; "="; "+"; "*"; "#"; "@" |]

let level_glyph ~unicode ~count ~max_count =
  if count <= 0 then if unicode then "·" else "."
  else
    let denom = float_of_int (Int.max 1 max_count) in
    let idx =
      let scaled =
        int_of_float (Float.ceil (float_of_int count *. 8.0 /. denom)) - 1
      in
      Int.max 0 (Int.min 7 scaled)
    in
    if unicode then unicode_levels.(idx) else ascii_levels.(idx)

let tick_header ~width =
  if width <= 0 then ""
  else
    let buf = Bytes.make width ' ' in
    match merge_of_width width with
    | None -> Bytes.to_string buf
    | Some merge ->
        let n_cells = bin_count / merge in
        let col_of_edge e =
          let b = edge_bin e in
          let cell_idx = (bin_count - 1 - b) / merge in
          Int.max 0 (Int.min (n_cells - 1) cell_idx)
        in
        (* Place labels right-to-left prioritizing newest/canonical markers,
           never overwriting an already placed label or overflowing [width]. *)
        let occupied = Array.make width false in
        let try_place e =
          let lbl = edge_label e in
          let len = String.length lbl in
          let col = col_of_edge e in
          let start =
            if col + len <= width then col else Int.max 0 (width - len)
          in
          if start + len <= width then begin
            let fits = ref true in
            for i = start to start + len - 1 do
              if occupied.(i) then fits := false
            done;
            (* Keep a 1-space gap from adjacent placed labels when possible. *)
            if !fits && start > 0 && occupied.(start - 1) then fits := false;
            if !fits && start + len < width && occupied.(start + len) then
              fits := false;
            if !fits then begin
              Bytes.blit_string lbl 0 buf start len;
              for i = start to start + len - 1 do
                occupied.(i) <- true
              done
            end
          end
        in
        List.iter try_place [ Edge_hour; Edge_day; Edge_week; Edge_month ];
        Bytes.to_string buf

let aggregate_fleet_age_bins bin_list =
  let valid =
    List.filter
      (fun arr ->
        match validate_bins arr with Ok () -> true | Error _ -> false)
      bin_list
  in
  match valid with
  | [] -> None
  | rows ->
      let acc = Array.make bin_count 0 in
      List.iter
        (fun arr ->
          for i = 0 to bin_count - 1 do
            acc.(i) <- acc.(i) + arr.(i)
          done)
        rows;
      Some acc

let style_of_age_tier ~bg ~(theme : Theme.t) = function
  | Tier_within_day -> Typography.status ~bg theme Theme.Status_active
  | Tier_within_week -> Typography.primary ~bg theme
  | Tier_past_week -> Typography.whisper ~bg ~italic:false theme

let put_clipped ~clip grid ~x ~y ~max_w ~style s =
  if max_w <= 0 then 0
  else
    let clipped = Grapheme.truncate_to_width ~max_width:max_w s in
    Cell_grid.put_text ~clip grid ~x ~y ~style clipped

let draw_age_ladder grid ~(rect : Rect.t) ~(theme : Theme.t)
    ~(caps : Presenter.capabilities) ~(lang : Say.lang) ?bg ?title
    ?observed_derived age_bins_opt =
  if Rect.is_empty rect then 0
  else
    let bg = Option.value bg ~default:(Color.of_rgb theme.surface_1) in
    let unicode = caps.unicode_blocks in
    let y = ref rect.y in
    let bottom = Rect.bottom rect in
    let title_str =
      match title with
      | Some s -> s
      | None ->
          Say.resolve lang
            (Say.make ~ko:"기억 연령 분포 (24-bin)" ~en:"Fact Age Ladder (24-bin)")
    in
    match age_bins_opt with
    | None ->
        if !y < bottom then begin
          ignore
            (put_clipped ~clip:rect grid ~x:rect.x ~y:!y ~max_w:rect.w
               ~style:(Typography.structure ~bg ~bold:true theme)
               title_str);
          incr y
        end;
        if !y < bottom then begin
          let empty_msg =
            Say.resolve lang
              (Say.make ~ko:"스냅샷 없음 · 연령 분포 미집계"
                 ~en:"No snapshot · age distribution unavailable")
          in
          ignore
            (put_clipped ~clip:rect grid ~x:rect.x ~y:!y ~max_w:rect.w
               ~style:(Typography.whisper ~bg theme)
               (Glyph.to_utf8 Glyph.Missing_absent ^ " " ^ empty_msg));
          incr y
        end;
        !y - rect.y
    | Some bins -> (
        match tier_counts bins with
        | Error _ ->
            if !y < bottom then begin
              ignore
                (put_clipped ~clip:rect grid ~x:rect.x ~y:!y ~max_w:rect.w
                   ~style:(Typography.whisper ~bg theme)
                   (Say.resolve lang
                      (Say.make ~ko:"연령 분포 형식 오류"
                         ~en:"Invalid age distribution")));
              incr y
            end;
            !y - rect.y
        | Ok (within_day, within_week, past_week) ->
            let total = within_day + within_week + past_week in
            let header_right =
              match observed_derived with
              | Some (obs, drv) ->
                  Printf.sprintf "%d (%s %d · %s %d)" total
                    (Say.resolve lang (Say.make ~ko:"관측" ~en:"obs"))
                    obs
                    (Say.resolve lang (Say.make ~ko:"유도" ~en:"drv"))
                    drv
              | None ->
                  Printf.sprintf "%d %s" total
                    (Say.resolve lang (Say.make ~ko:"사실" ~en:"facts"))
            in
            if !y < bottom then begin
              let rw = Grapheme.display_width header_right in
              let left_w =
                if rw + 2 < rect.w then rect.w - rw - 2 else rect.w
              in
              ignore
                (put_clipped ~clip:rect grid ~x:rect.x ~y:!y ~max_w:left_w
                   ~style:(Typography.structure ~bg ~bold:true theme)
                   title_str);
              if rw + 2 < rect.w then
                ignore
                  (put_clipped ~clip:rect grid ~x:(Rect.right rect - rw) ~y:!y
                     ~max_w:rw ~style:(Typography.whisper ~bg ~italic:false theme)
                     header_right);
              incr y
            end;
            let ladder_w = Int.min 24 rect.w in
            (match merge_of_width ladder_w with
            | Some merge -> (
                match fold_bins ~merge bins with
                | Ok cells ->
                    let cell_count = List.length cells in
                    let max_c =
                      List.fold_left
                        (fun acc (c : ladder_cell) -> Int.max acc c.count)
                        0 cells
                    in
                    (* Tick header row when we have room for >= 3 rows *)
                    if !y + 1 < bottom then begin
                      let ticks = tick_header ~width:cell_count in
                      ignore
                        (put_clipped ~clip:rect grid ~x:rect.x ~y:!y
                           ~max_w:cell_count
                           ~style:(Typography.whisper ~bg ~italic:false theme)
                           ticks);
                      incr y
                    end;
                    if !y < bottom then begin
                      List.iteri
                        (fun i (cell : ladder_cell) ->
                          let g =
                            level_glyph ~unicode ~count:cell.count
                              ~max_count:max_c
                          in
                          let st =
                            if cell.count <= 0 then
                              Typography.whisper ~bg ~italic:false theme
                            else style_of_age_tier ~bg ~theme cell.tier
                          in
                          ignore
                            (Cell_grid.put_text ~clip:rect grid
                               ~x:(rect.x + i) ~y:!y ~style:st g))
                        cells;
                      (* Inline tier counts to the right when space permits *)
                      let summary =
                        Printf.sprintf "  <1d:%d · 1-7d:%d · >7d:%d" within_day
                          within_week past_week
                      in
                      let rem_w = rect.w - cell_count in
                      if rem_w >= 14 then
                        ignore
                          (put_clipped ~clip:rect grid
                             ~x:(rect.x + cell_count) ~y:!y ~max_w:rem_w
                             ~style:(Typography.whisper ~bg ~italic:false theme)
                             summary);
                      incr y
                    end;
                    (* Dedicated summary row if inline summary didn't fit *)
                    if rect.w - cell_count < 14 && !y < bottom then begin
                      let cx = ref rect.x in
                      let right_e = Rect.right rect in
                      let put_seg st s =
                        let adv =
                          put_clipped ~clip:rect grid ~x:!cx ~y:!y
                            ~max_w:(Int.max 0 (right_e - !cx))
                            ~style:st s
                        in
                        cx := !cx + adv
                      in
                      let dot = Typography.whisper ~bg ~italic:false theme in
                      put_seg (style_of_age_tier ~bg ~theme Tier_within_day)
                        (Printf.sprintf "<1d:%d" within_day);
                      put_seg dot " · ";
                      put_seg (style_of_age_tier ~bg ~theme Tier_within_week)
                        (Printf.sprintf "1-7d:%d" within_week);
                      put_seg dot " · ";
                      put_seg (style_of_age_tier ~bg ~theme Tier_past_week)
                        (Printf.sprintf ">7d:%d" past_week);
                      incr y
                    end
                | Error _ -> ())
            | None ->
                if !y < bottom then begin
                  let s =
                    Printf.sprintf "<1d:%d 1-7d:%d >7d:%d" within_day within_week
                      past_week
                  in
                  ignore
                    (put_clipped ~clip:rect grid ~x:rect.x ~y:!y ~max_w:rect.w
                       ~style:(Typography.whisper ~bg ~italic:false theme)
                       s);
                  incr y
                end);
            !y - rect.y)

let choose_time_window points =
  match points with
  | [] | [ _ ] -> Chart.Time_window.Last_24h
  | (t0, _) :: rest ->
      let t_last = List.fold_left (fun _ (t, _) -> t) t0 rest in
      let span = t_last -. t0 in
      if span > 172800.0 then Chart.Time_window.Last_7d
      else if span > 7200.0 then Chart.Time_window.Last_24h
      else Chart.Time_window.Last_1h

let draw_facts_trend grid ~(rect : Rect.t) ~(theme : Theme.t)
    ~(caps : Presenter.capabilities) ~(lang : Say.lang) ?bg ?title
    ?observed_derived points =
  if Rect.is_empty rect then Chart.Render_mode.Numeric_delta_pill
  else
    let bg = Option.value bg ~default:(Color.of_rgb theme.surface_1) in
    let chart_rect, footer_rect_opt =
      match observed_derived with
      | Some _ when rect.h >= 5 ->
          let top, bot = Rect.split_v rect ~top_h:(rect.h - 1) in
          (top, Some bot)
      | Some _ | None -> (rect, None)
    in
    let samples =
      match points with
      | [] -> [| Chart.Series.Absent |]
      | xs ->
          Array.of_list
            (List.map
               (fun (_, n) ->
                 if n <= 0 then Chart.Series.Zero
                 else Chart.Series.Value (float_of_int n))
               xs)
    in
    let epoch_zero = Masc_tui_core.Clock.Mono.zero in
    let current, peak, avg, delta_pct =
      match points with
      | [] ->
          ( Observed.absent
          , Observed.absent
          , Observed.absent
          , None )
      | (_, first_n) :: _ ->
          let last_n =
            List.fold_left (fun _ (_, n) -> n) first_n points
          in
          let peak_n =
            List.fold_left (fun acc (_, n) -> Int.max acc n) 0 points
          in
          let sum_n =
            List.fold_left (fun acc (_, n) -> acc + n) 0 points
          in
          let avg_f = float_of_int sum_n /. float_of_int (List.length points) in
          let delta =
            match points with
            | [] | [ _ ] -> None
            | _ ->
                if first_n > 0 then
                  Some
                    (float_of_int (last_n - first_n)
                    *. 100.0 /. float_of_int first_n)
                else None
          in
          ( Observed.value ~observed_at:epoch_zero (float_of_int last_n)
          , Observed.value ~observed_at:epoch_zero (float_of_int peak_n)
          , Observed.value ~observed_at:epoch_zero avg_f
          , delta )
    in
    let chart_title =
      Option.value title
        ~default:(Say.make ~ko:"기억 수 추이" ~en:"Facts Evolution")
    in
    let series : Chart.Series.t =
      {
        label = Say.make ~ko:"사실" ~en:"Facts";
        unit = Format_val.Count;
        gradient = Chart.Gradient.Cool_flow;
        samples;
        current;
        peak;
        avg;
        delta_pct;
      }
    in
    let spec : Chart.Spec.t =
      {
        title = chart_title;
        hotkey_hint = None;
        kind =
          Chart.Spec.Time_series
            {
              series;
              scale = Chart.Scale.Auto_ceil { floor = 0.0; nice_step = true };
              window = choose_time_window points;
            };
      }
    in
    let mode =
      Chart.draw grid ~rect:chart_rect ~theme ~caps ~lang ~show_title:true spec
    in
    (match footer_rect_opt, observed_derived with
    | Some fr, Some (obs, drv) when not (Rect.is_empty fr) ->
        let tot = obs + drv in
        let obs_pct =
          if tot > 0 then (obs * 100) / tot else 0
        in
        let line =
          Printf.sprintf "%s %d (%d%%) · %s %d"
            (Say.resolve lang (Say.make ~ko:"관측" ~en:"Observed"))
            obs obs_pct
            (Say.resolve lang (Say.make ~ko:"유도" ~en:"Derived"))
            drv
        in
        ignore
          (put_clipped ~clip:fr grid ~x:fr.x ~y:fr.y ~max_w:fr.w
             ~style:(Typography.whisper ~bg ~italic:false theme)
             line)
    | Some _, Some _ | Some _, None | None, (Some _ | None) -> ());
    mode
