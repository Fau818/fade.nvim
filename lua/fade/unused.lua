---Fade the code the language server calls unused, one treesitter token at a time, so it keeps its
---own syntax colors instead of collapsing into a single gray.
local hl = require("fade.hl")

local M = {}

local NAMESPACE = vim.api.nvim_create_namespace("fade.unused")

---@class fade.UnusedConfig : fade.FadeConfig
---@field priority? integer Must outrank treesitter (100), semantic tokens (128), diagnostics (150).
---@field hide? table<string, boolean> Diagnostic handlers that should skip unused diagnostics.
---@field patterns? string[] Lua patterns for servers that report unused code without a tag.
---@field exclude? table<string, true> Filetypes to leave alone.
---@type fade.UnusedConfig
local DEFAULTS = {
  enabled = true,
  alpha = 0.75,
  min_contrast = 3.0,
  ignore = {},
  priority = 200,
  hide = { underline = true, virtual_text = true, signs = true },
  patterns = {},
  exclude = {},
}

---@type fade.UnusedConfig
M.config = vim.deepcopy(DEFAULTS)

M.wrapped = {}  ---@type table<string, vim.diagnostic.Handler>
M.installed = false


-- ════════════════════════════════════════════════════════════
-- ══════════════════════ Unused Ranges ═══════════════════════
-- ════════════════════════════════════════════════════════════


-- ═══════════════════════ Recognizing ════════════════════════

---@type integer
local UNNECESSARY = vim.tbl_get(vim.lsp.protocol, "DiagnosticTag", "Unnecessary") or 1

---Whether `diagnostic` marks code the server considers dead. Servers say so with the LSP
---`unnecessary` tag; `patterns` covers the ones that only say it in the message.
---
---Public so `:checkhealth` can count what this recognizes: the tag is read through a private field,
---and a rename upstream would otherwise just stop the fading, in silence.
---@param diagnostic vim.Diagnostic
---@return boolean
function M.is_unused(diagnostic)
  if diagnostic._tags and diagnostic._tags.unnecessary then return true end

  -- NOTE: `_tags` is private, so fall back to the raw LSP diagnostic it was derived from.
  for _, tag in ipairs(vim.tbl_get(diagnostic, "user_data", "lsp", "tags") or {}) do
    if tag == UNNECESSARY then return true end
  end

  for _, pattern in ipairs(M.config.patterns) do
    if diagnostic.message:find(pattern) then return true end
  end
  return false
end


-- ══════════════════════════ Ranges ══════════════════════════

---A span of dead code, in the same 0-based rows and byte columns a diagnostic uses, `end_col` exclusive.
---@class fade.Range
---@field start_row integer
---@field start_col integer
---@field end_row integer
---@field end_col integer

---Sort `ranges` and fold overlapping or touching ones into single spans, so code two servers both
---flag is marked once. Only real overlaps join: crossing a gap would fade code nothing flagged.
---@param ranges fade.Range[]
---@return fade.Range[] merged Disjoint and sorted by where they start.
local function merge_ranges(ranges)
  ---Whether position `(row_a, col_a)` strictly comes before `(row_b, col_b)`.
  local function before(row_a, col_a, row_b, col_b)
    return row_a < row_b or (row_a == row_b and col_a < col_b)
  end

  table.sort(ranges, function(a, b)
    return before(a.start_row, a.start_col, b.start_row, b.start_col)
  end)

  local merged = {}  ---@type fade.Range[]
  for _, range in ipairs(ranges) do
    local last = merged[#merged]
    if last and not before(last.end_row, last.end_col, range.start_row, range.start_col) then
      -- Overlapping or touching, so grow the span rather than starting another.
      if before(last.end_row, last.end_col, range.end_row, range.end_col) then
        last.end_row, last.end_col = range.end_row, range.end_col
      end
    else
      merged[#merged + 1] = {
        start_row = range.start_row, start_col = range.start_col,
        end_row = range.end_row, end_col = range.end_col,
      }
    end
  end

  return merged
end


---The first and last column to draw on `row`, clamped to `line_len` -- a stale diagnostic can
---outrun a line an edit has shortened.
---@param row integer 0-based.
---@param line_len integer Byte length of `row`'s text.
---@param start_row integer 0-based.
---@param start_col integer 0-based.
---@param end_row integer 0-based.
---@param end_col integer 0-based and exclusive.
---@return integer from, integer to 0-based, `to` is exclusive.
local function bounds(row, line_len, start_row, start_col, end_row, end_col)
  return row == start_row and math.min(start_col, line_len) or 0,
    row == end_row and math.min(end_col, line_len) or line_len
end


-- ═════════════════════════ Captures ═════════════════════════

---The group to draw `source` in once faded, or `nil` when `source` has no color to fade.
---@param source string
---@return string? group The faded twin, or `source` itself when it is ignored.
local function faded(source)
  -- NOTE: `nil` means "no color here" and drops the text, but ignoring should keep the color.
  if hl.ignored(source, M.config.ignore) then return source end
  return hl.faded(source, M.config.alpha, M.config.min_contrast)
end


---One mark an LSP's semantic tokens left behind, in the rows and columns a diagnostic uses.
---@class fade.SemanticMark : fade.Range
---@field group string
---@field priority integer
---@field ns integer
---@field id integer Extmark id, which counts up per namespace.

---The groups an LSP's semantic tokens put over `range`, sorted so that painting them in order
---leaves the highest priority on top.
---@param bufnr integer
---@param namespaces integer[] The semantic-token namespaces, gathered once by `capture_map`.
---@param range fade.Range
---@return fade.SemanticMark[] marks The sorted marks.
local function semantic_marks(bufnr, namespaces, range)
  local found = {}  ---@type fade.SemanticMark[]
  for _, ns in ipairs(namespaces) do
    local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, { range.start_row, 0 }, { range.end_row, -1 }, { details = true })
    for _, mark in ipairs(marks) do
      local id, row, col, detail = mark[1], mark[2], mark[3], mark[4]
      if detail and detail.hl_group then
        found[#found + 1] = {
          start_row = row,
          start_col = col,
          end_row = detail.end_row or row,
          end_col = detail.end_col or col,
          group = detail.hl_group,
          priority = detail.priority,
          ns = ns,
          id = id,
        }
      end
    end
  end

  -- NOTE: Neovim emits one mark per modifier, so a token carrying two puts two marks on one
  -- \     priority, and `table.sort` is unstable -- the color was arbitrary.
  table.sort(found, function(a, b)
    if a.priority ~= b.priority then return a.priority < b.priority end
    if a.ns ~= b.ns then return a.ns < b.ns end
    return a.id < b.id
  end)
  return found
end


---Build a `map[row][col]` of the faded group each position in `ranges` should be drawn in.
---
---Highlights merge per field, so what a position shows is the topmost group with an `fg` of its
---own -- reading treesitter alone faded a color that was never on screen. The passes below run
---lowest first, which is what puts the LSP's colors over treesitter's.
---@param bufnr integer
---@param parser vim.treesitter.LanguageTree? `nil` without a grammar; semantic tokens still apply.
---@param lines table<integer, string> Buffer text, keyed by line number.
---@param ranges fade.Range[]
---@return fade.CaptureMap map
local function capture_map(bufnr, parser, lines, ranges)
  local map = {}  ---@type fade.CaptureMap

  ---Write `group` into `map`, over every position the span covers inside `range`.
  ---@param range fade.Range
  ---@param group string
  ---@param start_row integer 0-based. The span's own bounds, `end_col` exclusive.
  local function paint(range, group, start_row, start_col, end_row, end_col)
    for row = math.max(start_row, range.start_row), math.min(end_row, range.end_row) do
      local line = lines[row + 1]
      if line then
        map[row] = map[row] or {}
        local from, to = bounds(row, #line, start_row, start_col, end_row, end_col)
        for col = from, to - 1 do map[row][col] = group end
      end
    end
  end

  -- STEP1: Base layer: Treesitter's captures, tree by tree.
  if parser then
    parser:for_each_tree(
      function(tree, ltree)
        local query = vim.treesitter.query.get(ltree:lang(), "highlights")
        -- EXIT: the language has no highlights query, so treesitter colors nothing here.
        if not query then return end

        local root = tree:root()
        local tree_start, _, tree_end = root:range()
        local groups = {}  ---@type table<integer, string|false>  false means the capture has no color to fade.

        for _, range in ipairs(ranges) do
          -- A fenced block is its own tree, so without this it is queried once per range.
          if range.end_row >= tree_start and range.start_row <= tree_end then
            -- IMPO: An explicit `end_row` is exclusive; upstream's `+ 1` runs only when it is nil.
            for id, node in query:iter_captures(root, bufnr, range.start_row, range.end_row + 1) do
              local group = groups[id]
              if group == nil then
                group = faded(("@%s.%s"):format(query.captures[id], ltree:lang())) or false
                groups[id] = group
              end
              if group then paint(range, group, node:range()) end
            end
          end
        end
      end)
  end

  -- STEP2: LSP layer: A semantic-token namespace per client, so the ids can only be found by name.
  local namespaces = {} ---@type integer[]
  for name, ns in pairs(vim.api.nvim_get_namespaces()) do
    if name:find("^nvim%.lsp%.semantic_tokens") then namespaces[#namespaces + 1] = ns end
  end

  for _, range in ipairs(ranges) do
    for _, mark in ipairs(semantic_marks(bufnr, namespaces, range)) do
      local group = faded(mark.group)
      if group then paint(range, group, mark.start_row, mark.start_col, mark.end_row, mark.end_col) end
    end
  end

  return map
end


-- ════════════════════════════════════════════════════════════
-- ══════════════════════════ Fading ══════════════════════════
-- ════════════════════════════════════════════════════════════

---Draw `range` row by row, one extmark per run of neighboring columns that share a group. The
---marks never overlap and never cross a row, so Neovim never breaks a tie between two of ours.
---@param bufnr integer
---@param lines table<integer, string> Buffer text, keyed by line number.
---@param map fade.CaptureMap From `capture_map`.
---@param range fade.Range
local function fade_range(bufnr, lines, map, range)
  ---One mark over `[from, to)` of `row`.
  local function emit(row, from, to, group)
    vim.api.nvim_buf_set_extmark(bufnr, NAMESPACE, row, from, { end_row = row, end_col = to, hl_group = group, priority = M.config.priority })
  end

  for row = range.start_row, range.end_row do
    local line = lines[row + 1]
    if line then
      local row_map = map[row] or {}

      ---The group `col` should be drawn in, or `nil` where nothing should be drawn at all.
      ---@param col integer 0-based.
      ---@return string?
      local function group_of(col)
        -- Whitespace has no glyph to recolor, so a mark over it would draw nothing.
        if line:sub(col + 1, col + 1):match("%s") then return nil end
        if row_map[col] then return row_map[col] end
        -- NOTE: Nothing parsed here, so Neovim's own flat group is the honest fallback.
        return "DiagnosticUnnecessary"
      end

      local first, last = bounds(row, #line, range.start_row, range.start_col, range.end_row, range.end_col)

      local start, group
      for col = first, last - 1 do
        local at = group_of(col)
        if at ~= group then
          if group then emit(row, start, col, group) end
          start, group = col, at
        end
      end
      -- `last` is exclusive, so the run the row ends inside is still open here.
      if group then emit(row, start, last, group) end
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

  local ranges = {} ---@type fade.Range[]
  for _, diagnostic in ipairs(vim.diagnostic.get(bufnr)) do
    if M.is_unused(diagnostic) then
      ranges[#ranges + 1] = {
        start_row = diagnostic.lnum,
        start_col = diagnostic.col,
        end_row = diagnostic.end_lnum or diagnostic.lnum,
        end_col = diagnostic.end_col or diagnostic.col,
      }
    end
  end

  -- EXIT: Nothing is flagged, so there is no tree worth walking.
  if #ranges == 0 then return end

  ranges = merge_ranges(ranges)
  local lines = {}  ---@type table<integer, string> Buffer text, keyed by line number.
  for _, range in ipairs(ranges) do
    local text = vim.api.nvim_buf_get_lines(bufnr, range.start_row, range.end_row + 1, false)
    for i = 1, #text do lines[range.start_row + i] = text[i] end
  end

  local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
  if not ok then parser = nil end
  if parser then pcall(parser.parse, parser, true) end

  local map = capture_map(bufnr, parser, lines, ranges)
  for _, range in ipairs(ranges) do fade_range(bufnr, lines, map, range) end
end


---Redraw every loaded buffer.
function M.refresh_all()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then M.refresh(buf) end
  end
end


-- ════════════════════════════════════════════════════════════
-- ══════════════════════════ Setup ═══════════════════════════
-- ════════════════════════════════════════════════════════════

---Hide unused diagnostics from the handlers.
local function hide_from_handlers()
  for name in pairs(M.config.hide) do
    local handler = vim.diagnostic.handlers[name]
    if handler and handler ~= M.wrapped[name] then
      ---@type vim.diagnostic.Handler
      local wrapper = {
        show = function(namespace, bufnr, diagnostics, opts)
          if M.config.enabled and M.config.hide[name] and not M.config.exclude[vim.bo[bufnr].filetype] then
            diagnostics = vim.tbl_filter(function(d) return not M.is_unused(d) end, diagnostics)
          end
          handler.show(namespace, bufnr, diagnostics, opts)
        end,
        hide = handler.hide,
      }
      M.wrapped[name] = wrapper
      vim.diagnostic.handlers[name] = wrapper
    end
  end
end


local pending = {}  ---@type table<integer, true>
---Redraw `bufnr` once the current batch of events has finished.
---
---Semantic tokens land after the diagnostics that triggered the last refresh,
---and Neovim announces them one token at a time.
local function refresh_soon(bufnr)
  if pending[bufnr] then return end
  pending[bufnr] = true

  vim.schedule(function() pending[bufnr] = nil M.refresh(bufnr) end)
end


---Ask Neovim to draw its diagnostics again.
local function redisplay() pcall(vim.diagnostic.show) end


---Put the handler wrappers (which hide the original unused drawings) and the autocmds in place.
local function install()
  hide_from_handlers()

  local group = vim.api.nvim_create_augroup("fade.unused", { clear = true })
  vim.api.nvim_create_autocmd("DiagnosticChanged", {
    group = group,
    desc = "Fade the code its diagnostics call unused",
    callback = function(args) M.refresh(args.buf) end,
  })

  vim.api.nvim_create_autocmd("LspTokenUpdate", {
    group = group,
    desc = "Recolor once the LSP's semantic tokens have landed",
    callback = function(args) refresh_soon(args.buf) end,
  })

  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    desc = "Rebuild the faded groups against the new palette",
    callback = function() hl.clear() M.refresh_all() end,
  })

  M.installed = true
end


function M.enable()
  M.config.enabled = true
  install()
  M.refresh_all()
  redisplay()
end


function M.disable()
  M.config.enabled = false
  M.refresh_all()
  redisplay()
end


function M.toggle()
  if M.config.enabled then M.disable() else M.enable() end
  return M.config.enabled
end


---@param config? fade.UnusedConfig
function M.setup(config)
  M.config = vim.tbl_deep_extend("force", vim.deepcopy(DEFAULTS), config or {})
  if not M.config.enabled then return end

  install()
end


return M
