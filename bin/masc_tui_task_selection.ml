(** Task-detail lookup for the Overview surface (#29684).

    The detail view reads the same domain rows the Overview list was
    projected from. [None] covers both "no detail open" and "id no longer
    in the backlog": the renderer falls back to the Overview list, the
    same shape Board and Planning detail use for a missing row. A row
    that is terminal but still present answers [Some] -- the active list
    drops exactly those rows, the detail view must not, or a task that
    finishes while its detail is open would blank the screen. *)

let detail_row ~detail_id ~tasks =
  match detail_id with
  | None -> None
  | Some task_id ->
      List.find_opt
        (fun (task : Masc_domain.task) ->
           String.equal task.Masc_domain.id task_id)
        tasks
