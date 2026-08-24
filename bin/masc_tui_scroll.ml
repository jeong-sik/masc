let maximum ~count ~height = max 0 (count - height)

let normalize ~count ~height scroll =
  max 0 (min scroll (maximum ~count ~height))

let down ~count ~height scroll =
  min (maximum ~count ~height) (normalize ~count ~height scroll + 1)

let up ~count ~height scroll = max 0 (normalize ~count ~height scroll - 1)
