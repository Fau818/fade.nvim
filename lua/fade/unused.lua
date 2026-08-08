---Fade the code the language server calls unused, one treesitter token at a time, so it keeps its
---own syntax colors instead of collapsing into a single gray.
local hl = require("fade.hl")

local M = {}

local NAMESPACE = vim.api.nvim_create_namespace("fade.unused")

---@class fade.UnusedConfig
---@field enabled? boolean
---@field alpha? number Share of the original color kept; the rest fades into `Normal` bg.
---@field min_contrast? number Groups that would fade below this keep their own color.
---@field ignore? string[] Capture groups never faded, whatever the contrast works out to.
---@field priority? integer Must outrank treesitter (100), semantic tokens (128), diagnostics (150).
---@field hide? table<string, boolean> Diagnostic handlers that should skip unused diagnostics.
---@field patterns? string[] Lua patterns for servers that report unused code without a tag.
---@field exclude? table<string, true> Filetypes to leave alone.
M.config = {
  enabled = true,
  alpha = 0.75,
  min_contrast = 3.0,
  -- Dead code's comments are dead too, and 0.75 leaves them readable.
  ignore = {},
  priority = 200,
  hide = { underline = true, virtual_text = true, signs = true },
  patterns = {},
  exclude = {},
}


-- ════════════════════════════════════════════════════════════
-- ══════════════════════ Unused Ranges ═══════════════════════
-- ════════════════════════════════════════════════════════════

---Servers flag dead code with the LSP `unnecessary` tag; `patterns` covers the ones that do not.
---@param diagnostic vim.Diagnostic
---@return boolean
local function is_unused(diagnostic)
  if diagnostic._tags and diagnostic._tags.unnecessary then return true end

  for _, pattern in ipairs(M.config.patterns) do
    if diagnostic.message:find(pattern) then return true end
  end
  return false
end


---Faded group covering `col`. The innermost capture wins, matching how treesitter layers its marks.
---@param bufnr integer
---@param row integer
---@param col integer
---@return string? group
local function group_at(bufnr, row, col)
  local captures = vim.treesitter.get_captures_at_pos(bufnr, row, col)

  for i = #captures, 1, -1 do
    local source = ("@%s.%s"):format(captures[i].capture, captures[i].lang)
    -- An ignored capture still answers, with its own color: the extmark repeats what is there.
    if hl.ignored(source, M.config.ignore) then return source end

    local group = hl.faded(source, M.config.alpha, M.config.min_contrast)
    if group then return group end
  end

  -- NOTE: Nothing parsed here, so Neovim's own flat group is the honest fallback.
  return "DiagnosticUnnecessary"
end


-- ════════════════════════════════════════════════════════════
-- ══════════════════════════ Fading ══════════════════════════
-- ════════════════════════════════════════════════════════════

---Where the token under `col` ends, so a multi-token range does not collapse into one color.
---Anonymous nodes are the keyword and punctuation leaves; without them `=` is the whole assignment.
---@param bufnr integer
---@param line string
---@param row integer
---@param col integer
---@param end_col integer
---@return integer stop Always greater than `col`, so the caller cannot spin.
local function token_end(bufnr, line, row, col, end_col)
  -- Not `vim.treesitter.get_node`: it only learned `include_anonymous` after 0.10, and it throws
  -- outright when the filetype names no real language. Walking the tree covers both.
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
  local tree = ok and parser and (parser:parse() or {})[1]
  -- `descendant_for_range` keeps anonymous nodes, unlike its `named_` twin.
  local node = tree and tree:root():descendant_for_range(row, col, row, col + 1)

  if node then
    local _, _, node_row, node_col = node:range()
    if node_row == row and col < node_col then return math.min(node_col, end_col) end
  end

  -- A node reaching past this row (an unreachable block) says nothing; fall back to the next space.
  local space = line:find("%s", col + 2)
  return math.min(space and space - 1 or end_col, end_col)
end


---@param bufnr integer
---@param line string
---@param row integer
---@param start_col integer
---@param end_col integer
local function fade_row(bufnr, line, row, start_col, end_col)
  local col = start_col
  while col < end_col do
    -- Whitespace has no glyph to recolor, and marking it would paint over the indent guides.
    if line:sub(col + 1, col + 1):match("%s") then
      col = col + 1
    else
      local stop = token_end(bufnr, line, row, col, end_col)
      local group = group_at(bufnr, row, col)
      if group then
        vim.api.nvim_buf_set_extmark(bufnr, NAMESPACE, row, col, {
          end_row = row, end_col = stop, hl_group = group, priority = M.config.priority,
        })
      end
      col = stop
    end
  end
end


---@param bufnr integer
---@param diagnostic vim.Diagnostic
local function fade_diagnostic(bufnr, diagnostic)
  local end_row = diagnostic.end_lnum or diagnostic.lnum
  local end_col = diagnostic.end_col or diagnostic.col

  for row = diagnostic.lnum, end_row do
    local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
    if line then
      local from = row == diagnostic.lnum and diagnostic.col or 0
      local to = row == end_row and end_col or #line
      fade_row(bufnr, line, row, math.min(from, #line), math.min(to, #line))
    end
  end
end


---Redraw a buffer's faded ranges from its current diagnostics.
---@param bufnr? integer Default is the current buffer.
function M.refresh(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then return end

  vim.api.nvim_buf_clear_namespace(bufnr, NAMESPACE, 0, -1)
  -- EXIT: Turned off, or a filetype that opted out.
  if not M.config.enabled or M.config.exclude[vim.bo[bufnr].filetype] then return end

  -- Two servers often flag the same code, and fading a range twice just doubles the extmarks.
  local seen = {} ---@type table<string, true>
  for _, diagnostic in ipairs(vim.diagnostic.get(bufnr)) do
    local range = ("%d:%d:%s:%s"):format(
      diagnostic.lnum, diagnostic.col, diagnostic.end_lnum, diagnostic.end_col)
    if is_unused(diagnostic) and not seen[range] then
      seen[range] = true
      fade_diagnostic(bufnr, diagnostic)
    end
  end
end


---@param bufnr? integer Default is every loaded buffer.
function M.refresh_all(bufnr)
  if bufnr then return M.refresh(bufnr) end

  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then M.refresh(buf) end
  end
end


-- ════════════════════════════════════════════════════════════
-- ══════════════════════════ Setup ═══════════════════════════
-- ════════════════════════════════════════════════════════════

---Drop unused diagnostics from the handlers named in `hide`, leaving the float and location list
---alone. `underline` is also where Neovim's own flat `DiagnosticUnnecessary` comes from, so hiding
---it is what hands the fading over.
local wrapped = false
local function hide_from_handlers()
  if wrapped then return end
  wrapped = true

  for name, hidden in pairs(M.config.hide) do
    local handler = vim.diagnostic.handlers[name]
    if hidden and handler then
      vim.diagnostic.handlers[name] = {
        show = function(namespace, bufnr, diagnostics, opts)
          local used = vim.tbl_filter(function(d) return not is_unused(d) end, diagnostics)
          handler.show(namespace, bufnr, used, opts)
        end,
        hide = handler.hide,
      }
    end
  end
end


function M.enable()
  M.config.enabled = true
  M.refresh_all()
end


function M.disable()
  M.config.enabled = false
  M.refresh_all()
end


function M.toggle()
  if M.config.enabled then M.disable() else M.enable() end
  return M.config.enabled
end


---@param config? fade.UnusedConfig
function M.setup(config)
  M.config = vim.tbl_deep_extend("force", M.config, config or {})
  -- EXIT: Left off, so the diagnostic handlers stay untouched.
  if not M.config.enabled then return end

  hide_from_handlers()

  local group = vim.api.nvim_create_augroup("fade.unused", { clear = true })
  vim.api.nvim_create_autocmd("DiagnosticChanged", {
    group = group,
    desc = "Fade the code its diagnostics call unused",
    callback = function(args) M.refresh(args.buf) end,
  })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    desc = "Rebuild the faded groups against the new palette",
    callback = function()
      hl.clear()
      M.refresh_all()
    end,
  })
end


return M
