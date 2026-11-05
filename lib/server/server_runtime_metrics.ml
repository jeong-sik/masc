(* The runtime history answers the last day. *)
let window_minutes = 1440

let kept : (string, Model_inference_metrics_kept.t) Hashtbl.t = Hashtbl.create 1
let kept_mu = Stdlib.Mutex.create ()

(* Told when a read stored new rows, so the window watcher looks again: a file
   read for the first time can hold rows that leave sooner. *)
let kept_observer : (base_path:string -> unit) Atomic.t = Atomic.make (fun ~base_path:_ -> ())

(* Two reads can start from the same kept value; each stores a whole reading
   of its own moment, and the next read continues from whichever it finds. *)
let read ~base_path ~now =
  let previous =
    Stdlib.Mutex.protect kept_mu (fun () ->
      Option.value ~default:Model_inference_metrics_kept.empty (Hashtbl.find_opt kept base_path))
  in
  let next, reading = Model_inference_metrics_kept.refresh ~base_path ~now ~window_minutes previous in
  Stdlib.Mutex.protect kept_mu (fun () -> Hashtbl.replace kept base_path next);
  (Atomic.get kept_observer) ~base_path;
  Model_inference_metrics.runtime_metrics_json ~observed_at:now ~window_minutes reading
;;

let next_change ~base_path ~after =
  match Stdlib.Mutex.protect kept_mu (fun () -> Hashtbl.find_opt kept base_path) with
  | None -> None
  | Some kept -> Model_inference_metrics_kept.next_change kept ~window_minutes ~after
;;

let install ~sw ~clock ~(config : Workspace.config) =
  let announce () =
    Workspace_dataset_event.announce ~base_path:config.base_path
      Workspace_dataset_event.Runtime_metrics
  in
  let own_masc_root = Common.masc_dir_from_base_path ~base_path:config.base_path in
  Cost_ledger_row_signal.install (fun ~masc_root ->
    if String.equal masc_root own_masc_root then announce ());
  let wake = Eio.Stream.create 1 in
  let wake_mu = Stdlib.Mutex.create () in
  Atomic.set kept_observer (fun ~base_path ->
    if String.equal base_path config.base_path
    then
      Stdlib.Mutex.protect wake_mu (fun () ->
        if Eio.Stream.is_empty wake then Eio.Stream.add wake ()));
  Eio.Fiber.fork_daemon ~sw (fun () ->
    let rec watch () =
      (match next_change ~base_path:config.base_path ~after:(Eio.Time.now clock) with
       | None -> Eio.Stream.take wake
       | Some at ->
         (match
            Eio.Fiber.first
              (fun () ->
                Eio.Stream.take wake;
                `Kept_rows_changed)
              (fun () ->
                Eio.Time.sleep_until clock at;
                `Left_window)
          with
          | `Kept_rows_changed -> ()
          | `Left_window -> announce ()));
      watch ()
    in
    watch ())
;;
