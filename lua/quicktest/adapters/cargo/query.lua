return [[
(
  (attribute_item
    [
      (attribute (identifier) @macro_name)
      (attribute (scoped_identifier name: (identifier) @macro_name))
    ]
  )
  .
  (function_item name: (identifier) @test.name) @test.definition
  (#eq? @macro_name "test")
)
]]
