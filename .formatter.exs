spark_locals_without_parens = [
  base_path: 1,
  code: 1,
  collection_operation: 1,
  collection_operation: 2,
  create: 1,
  create: 2,
  delete: 1,
  delete: 2,
  description: 1,
  fields: 1,
  headers: 1,
  idempotent?: 1,
  identifier_names: 1,
  identifiers: 1,
  list: 1,
  list: 2,
  member_names: 1,
  method: 1,
  name: 1,
  namespace: 1,
  operation: 1,
  operation: 2,
  paginated?: 1,
  path: 1,
  plural_name: 1,
  prefix: 1,
  protocol: 1,
  query: 1,
  read: 1,
  read: 2,
  read_action: 1,
  readonly?: 1,
  service: 1,
  title: 1,
  update: 1,
  update: 2,
  version: 1
]

[
  import_deps: [:ash, :spark],
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  locals_without_parens: spark_locals_without_parens,
  export: [
    locals_without_parens: spark_locals_without_parens
  ]
]
