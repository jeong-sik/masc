let prefix = ".atomic_"
let suffix = ".tmp"

let is_name name =
  String.length name >= String.length prefix + String.length suffix
  && String.starts_with name ~prefix
  && String.ends_with ~suffix name
;;
