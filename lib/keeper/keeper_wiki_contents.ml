type t =
  | Off
  | Listed of Wiki_journal.entry list
  | Unlisted of string

let observe ~base_path =
  if not (Env_config_keeper.KeeperWikiContents.enabled ()) then Off
  else
    match Tool_wiki.read_index_entries ~base_path with
    | Ok entries -> Listed entries
    | Error detail -> Unlisted detail
