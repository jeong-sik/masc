### Fixed

- Keeper chat streams keep buffered events ahead of newly arriving live events
  when acceptance and operation execution run on separate domains. A closed
  subscription drops pending and late callbacks without holding a state mutex
  during transport writes.
