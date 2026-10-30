val label : string -> string option
(** What this URL points at, in a few words, read out of the URL itself. No
    request is made: a keeper writes these links, and fetching one because it
    was mentioned would turn anything a keeper says into traffic this process
    sends. GitHub paths already carry the name, which is what masc's links
    mostly are.

    [None] where nothing can be said that the URL does not already show. A
    label repeating the host under the host answers nothing and costs a row. *)
