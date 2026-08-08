---Assertions and fixtures. No external dependency: the whole suite runs under `nvim -l`, so a stock
---Neovim is all a contributor or CI needs.
local M = {}

-- ════════════════════════════════════════════════════════════
-- ════════════════════════ Assertions ════════════════════════
-- ════════════════════════════════════════════════════════════

---@param message string
local function fail(message)
  error(message, 0)
end


---@param value any
---@return string
local function show(value)
  return (vim.inspect(value):gsub("%s+", " "))
end


---@param actual any
---@param expected any
---@param what string
function M.eq(actual, expected, what)
  if not vim.deep_equal(actual, expected) then
    fail(("%s\n      expected: %s\n      actual:   %s"):format(what, show(expected), show(actual)))
  end
end


---@param actual number
---@param expected number
---@param tolerance number
---@param what string
function M.near(actual, expected, tolerance, what)
  if type(actual) ~= "number" or math.abs(actual - expected) > tolerance then
    fail(("%s\n      expected: %s ± %s\n      actual:   %s"):format(what, expected, tolerance,
      show(actual)))
  end
end


---@param value any
---@param what string
function M.truthy(value, what)
  if not value then
    fail(("%s\n      expected something truthy, got %s"):format(what, show(value)))
  end
end


---@param value any
---@param what string
function M.falsy(value, what)
  if value then fail(("%s\n      expected something falsy, got %s"):format(what, show(value))) end
end


-- ════════════════════════════════════════════════════════════
-- ═════════════════════════ Fixtures ═════════════════════════
-- ════════════════════════════════════════════════════════════

---Colors the suite measures against; a contrast floor means nothing against an arbitrary scheme.
---
---`Comment` is deliberately the awkward case: readable at 4.62:1, but 2.67:1 once faded at alpha
---0.65. Not a dim color, so no floor picks it out by contrast alone -- only `ignore` can.
M.COMMENT_FG = 0x717cbd
M.COMMENT_FADED = 0x515883 -- `COMMENT_FG` blended 0.65 toward the background below.

function M.palette()
  vim.o.background = "dark"
  vim.api.nvim_set_hl(0, "Normal", { fg = 0xc8d3f5, bg = 0x151518 })
  vim.api.nvim_set_hl(0, "Comment", { fg = M.COMMENT_FG, italic = true })
  require("fade.hl").clear()
end


---A scratch buffer holding `lines`, with its tree parsed. Only bundled parsers are used, so the
---suite installs nothing. The explicit parse matters: `get_captures_at_pos` reads a parsed tree,
---and a buffer with no active highlighter has none.
---@param lines string[]
---@param filetype string?
---@return integer buf
function M.buffer(lines, filetype)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = filetype or "lua"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  pcall(function() vim.treesitter.get_parser(buf):parse() end)
  return buf
end


local NAMESPACE = vim.api.nvim_create_namespace("fade.tests")

---Draw `text` as ghost text at the end of `line` and recolor it, the way a provider hook does.
---@param line string Buffer text the suggestion follows.
---@param text string The suggestion itself.
---@param filetype string?
---@return table[] chunks
function M.ghost_chunks(line, text, filetype)
  local buf = M.buffer({ line }, filetype)
  local id = vim.api.nvim_buf_set_extmark(buf, NAMESPACE, 0, #line, {
    virt_text = { { text, "Comment" } },
    virt_text_pos = "inline",
  })
  require("fade.ghost").recolor(buf, NAMESPACE, id)

  local mark = vim.api.nvim_buf_get_extmark_by_id(buf, NAMESPACE, id, { details = true })
  return mark[3].virt_text
end


---The highlight group a chunk resolves to: chunks carry either a lone group or `{ real, faded }`.
---@param chunk table
---@return string
function M.chunk_group(chunk)
  return type(chunk[2]) == "table" and chunk[2][1] or chunk[2]
end


---Every distinct group across `chunks`.
---@param chunks table[]
---@return table<string, true>
function M.chunk_groups(chunks)
  local groups = {}
  for _, chunk in ipairs(chunks) do groups[M.chunk_group(chunk)] = true end
  return groups
end


---Extmarks `unused` has drawn in `buf`.
---@param buf integer
---@return table[]
function M.unused_marks(buf)
  return vim.api.nvim_buf_get_extmarks(buf, vim.api.nvim_create_namespace("fade.unused"), 0, -1,
    { details = true })
end


---Attach `diagnostics` to `buf` as a language server would, so `unused` reacts to them.
---@param buf integer
---@param diagnostics table[]
function M.diagnose(buf, diagnostics)
  vim.diagnostic.set(vim.api.nvim_create_namespace("fade.tests.lsp"), buf, diagnostics)
end


return M
