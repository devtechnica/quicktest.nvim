local Job = require("plenary.job")
local test_query_string = require("quicktest.adapters.rust.query")

local ts = vim.treesitter

local M = {
  name = "rust",
  options = {},
}

local function normalize(path)
  return vim.loop.fs_realpath(path) or path
end

local function relpath(cwd, file)
  cwd = normalize(cwd)
  file = normalize(file)
  if file:sub(1, #cwd) ~= cwd then
    return nil
  end
  return (file:sub(#cwd + 1):gsub("^/+", ""))
end

local function find_cargo_root(start_path)
  local uv = vim.loop
  local root = normalize(start_path)
  while root do
    local st = uv.fs_stat(root .. "/Cargo.toml")
    if st and st.type == "file" then
      return root
    end
    local parent = uv.fs_realpath(root .. "/..")
    if not parent or parent == root then
      break
    end
    root = parent
  end
  return nil
end

M.get_cwd = function(bufnr)
  local file = vim.api.nvim_buf_get_name(bufnr)
  if file and file ~= "" then
    local root = find_cargo_root(vim.fn.fnamemodify(file, ":h"))
    if root then
      return root
    end
  end
  return vim.fn.getcwd()
end

local function to_mod_path(no_ext)
  local p = no_ext:gsub("/mod$", "")
  return (p:gsub("/", "::"))
end

local function get_test_filter_for_file(_, cwd, file)
  local rel = relpath(cwd, file)
  if not rel or rel == "" then
    return nil
  end

  if rel:match("^tests/") then
    return { type = "integration", value = vim.fn.fnamemodify(rel, ":t:r") }
  end

  if rel:match("^src/") then
    local no_ext = rel:gsub("^src/", ""):gsub("%.rs$", "")

    local bin = no_ext:match("^bin/([^/]+)$") or no_ext:match("^bin/([^/]+)/main$")
    if bin then
      return { type = "bin_named", value = bin }
    end

    if no_ext == "lib" then
      return { type = "lib_root" }
    end
    if no_ext == "main" then
      return { type = "bin_all" }
    end

    local mod_path = to_mod_path(no_ext)
    if mod_path == "" then
      return { type = "all" }
    end
    return { type = "unit", value = mod_path .. "::" }
  end

  return nil
end

local function get_test_filter_for_dir(_, cwd, dir)
  local rel = relpath(cwd, dir)
  if not rel or rel == "" then
    return { type = "all" }
  end
  if rel:match("^tests/") then
    return { type = "all" }
  end
  if rel:match("^src/") then
    local mod_path = to_mod_path(rel:gsub("^src/", ""))
    if mod_path == "" then
      return { type = "all" }
    end
    return { type = "unit_dir", value = mod_path .. "::" }
  end
  return { type = "all" }
end

local function module_prefix_for_file(cwd, file)
  local f = get_test_filter_for_file(nil, cwd, file)
  return (f and f.type == "unit" and f.value) or ""
end

local _compiled_query
local function test_query()
  if not _compiled_query then
    _compiled_query = ts.query.parse("rust", test_query_string)
  end
  return _compiled_query
end

local function queried_test_ids(bufnr, root)
  local ids = {}
  local q = test_query()
  for id, node in q:iter_captures(root, bufnr, 0, -1) do
    if q.captures[id] == "test.definition" then
      ids[node:id()] = true
    end
  end
  return ids
end

local function has_test_attribute(func, bufnr)
  local sib = func:prev_named_sibling()
  while sib and sib:type() == "attribute_item" do
    if ts.get_node_text(sib, bufnr):find("test") then
      return true
    end
    sib = sib:prev_named_sibling()
  end
  return false
end

local function is_test_function(func, bufnr, queried)
  return queried[func:id()] or has_test_attribute(func, bufnr)
end

local function enclosing_function(bufnr, row0, col)
  local node = ts.get_node({ bufnr = bufnr, pos = { row0, col } })
  while node do
    local t = node:type()
    if t == "function_item" then
      return node
    end
    if t == "attribute_item" then
      -- cursor is on the attribute line: target the item that follows
      local nxt = node:next_named_sibling()
      while nxt and nxt:type() == "attribute_item" do
        nxt = nxt:next_named_sibling()
      end
      if nxt and nxt:type() == "function_item" then
        return nxt
      end
    end
    node = node:parent()
  end
  return nil
end

local function module_chain(node, bufnr)
  local mods, p = {}, node:parent()
  while p do
    if p:type() == "mod_item" then
      local nm = p:field("name")[1]
      if nm then
        table.insert(mods, 1, ts.get_node_text(nm, bufnr))
      end
    end
    p = p:parent()
  end
  return mods
end

local function regex_test_name(bufnr, line)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, line + 2, false)
  local n = #lines
  if n == 0 then
    return nil
  end
  for i = math.min(line, n), 1, -1 do
    if lines[i]:find("#%[.-test.-%]") then
      local fn = lines[i]:match("fn%s+([%w_]+)")
      if fn then
        return { name = fn }
      end
      for j = i + 1, n do -- peek forward past more attributes
        fn = lines[j]:match("fn%s+([%w_]+)")
        if fn then
          return { name = fn }
        end
        if not (lines[j]:match("^%s*#%[") or lines[j]:match("^%s*$")) then
          break
        end
      end
    end
  end
  return nil
end

local function get_test_name_at_position(bufnr, line, col)
  local ok, parser = pcall(ts.get_parser, bufnr, "rust")
  if not ok or not parser then
    return regex_test_name(bufnr, line)
  end

  local root = parser:parse()[1]:root()
  local func = enclosing_function(bufnr, line - 1, col or 0)
  if not func then
    return nil
  end

  local queried = queried_test_ids(bufnr, root)
  if not is_test_function(func, bufnr, queried) then
    return nil
  end

  local nm = func:field("name")[1]
  if not nm then
    return nil
  end
  local name = ts.get_node_text(nm, bufnr)
  local chain = module_chain(func, bufnr)
  table.insert(chain, name)
  return { name = name, path = table.concat(chain, "::") }
end

M.build_line_run_params = function(bufnr, cursor_pos)
  local cwd = M.get_cwd(bufnr)
  local file = vim.api.nvim_buf_get_name(bufnr)
  local line = cursor_pos[1]

  local test = get_test_name_at_position(bufnr, line, cursor_pos[2])
  local filter_type, filter_value
  if test and test.path then
    filter_type = "exact"
    filter_value = module_prefix_for_file(cwd, file) .. test.path
  end

  return {
    bufnr = bufnr,
    cursor_pos = cursor_pos,
    cwd = cwd,
    file = file,
    func_names = test and { test.name } or {},
    pos = line,
    filter_type = filter_type,
    filter_value = filter_value,
  }, nil
end

M.build_file_run_params = function(bufnr, cursor_pos)
  local cwd = M.get_cwd(bufnr)
  local file = vim.api.nvim_buf_get_name(bufnr)
  local filter = get_test_filter_for_file(bufnr, cwd, file)
  return {
    bufnr = bufnr,
    cursor_pos = cursor_pos,
    cwd = cwd,
    file = file,
    func_names = {},
    pos = cursor_pos[1],
    filter_type = filter and filter.type,
    filter_value = filter and filter.value,
  }, nil
end

M.build_dir_run_params = function(bufnr, cursor_pos)
  local cwd = M.get_cwd(bufnr)
  local file = vim.api.nvim_buf_get_name(bufnr)
  local dir = vim.fn.fnamemodify(file, ":h")
  local filter = get_test_filter_for_dir(bufnr, cwd, dir)
  return {
    bufnr = bufnr,
    cursor_pos = cursor_pos,
    cwd = cwd,
    file = file,
    dir = dir,
    func_names = {},
    pos = cursor_pos[1],
    filter_type = filter and filter.type,
    filter_value = filter and filter.value,
  }, nil
end

M.build_all_run_params = function(bufnr, cursor_pos)
  return {
    bufnr = bufnr,
    cursor_pos = cursor_pos,
    cwd = M.get_cwd(bufnr),
    file = vim.api.nvim_buf_get_name(bufnr),
    func_names = {},
    pos = cursor_pos[1],
    filter_type = "all",
    filter_value = nil,
  }, nil
end

M.is_enabled = function(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if not name:match("%.rs$") then
    return false
  end
  local st = vim.loop.fs_stat(M.get_cwd(bufnr) .. "/Cargo.toml")
  return st ~= nil and st.type == "file"
end

local function build_args(params)
  local args = { "test" }
  local ft = params.filter_type

  if ft == "integration" then
    table.insert(args, "--test")
    table.insert(args, params.filter_value)
  elseif ft == "lib_root" then
    table.insert(args, "--lib")
  elseif ft == "bin_all" then
    table.insert(args, "--bins")
  elseif ft == "bin_named" then
    table.insert(args, "--bin")
    table.insert(args, params.filter_value)
  elseif ft == "unit" or ft == "unit_dir" then
    table.insert(args, params.filter_value)
  elseif ft == "exact" then
    table.insert(args, params.filter_value)
    table.insert(args, "--")
    table.insert(args, "--exact")
  elseif ft == "all" then
    -- run everything: no extra args
  elseif params.func_names and #params.func_names > 0 then
    table.insert(args, params.func_names[1])
  else
    return nil, "no test target under cursor"
  end

  return args
end

M.run = function(params, send)
  local args, err = build_args(params)
  if not args then
    send({ type = "stderr", output = "rust adapter: " .. err .. "\n" })
    send({ type = "exit", code = 1 })
    return nil
  end

  local job = Job:new({
    command = "cargo",
    args = args,
    cwd = params.cwd,
    on_stdout = function(_, data)
      send({ type = "stdout", output = data or "" })
    end,
    on_stderr = function(_, data)
      send({ type = "stderr", output = data or "" })
    end,
    on_exit = function(_, code)
      send({ type = "exit", code = code })
    end,
  })

  job:start()
  return job.pid
end

return M
