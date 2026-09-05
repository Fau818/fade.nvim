---Syntax-color inline suggestions instead of the one flat group their plugin draws them in.
---
---Virtual text is not buffer content, so treesitter never parses a suggestion and it arrives in one
---group. It is spliced back into the buffer text around it, parsed there, and the provider's extmark
---rewritten in place. A chunk's highlight is the list `{ capture, faded }`, which Neovim merges per
---field: color from the twin, bold and italic from the real capture.

local hl = require("fade.hl")

local M = {}

---@class fade.GhostConfig : fade.FadeConfig
---@field providers? table<string, boolean> Which plugins to hook.
---@type fade.GhostConfig
local DEFAULTS = {
  enabled = true,
  alpha = 0.65,
  min_contrast = 3.0,
  ignore = { "@comment" },
  providers = { copilot = true, blink = true },
}

---@type fade.GhostConfig
M.config = vim.deepcopy(DEFAULTS)


---The group to draw `source` in once faded, or `nil` when `source` has no color to fade.
---@param source string
---@return string? group The faded twin, or `source` itself when it is ignored.
local function faded(source)
  -- NOTE: `nil` means "no color here" and drops the text, but ignoring should keep the color.
  if hl.ignored(source, M.config.ignore) then return source end
  return hl.faded(source, M.config.alpha, M.config.min_contrast)
end


-- ════════════════════════════════════════════════════════════
-- ═══════════════════════ Parse window ═══════════════════════
-- ════════════════════════════════════════════════════════════

-- DESC: A fragment reads as something else: a trailing `")` as one unterminated string, a
-- \     docstring line as code. So the window is the node enclosing the mark, split there.

---How far the window may grow. It is reparsed at typing speed, so this is a frame budget.
local MAX_ROWS = 200
local MAX_BYTES = 32768

---@class fade.GhostWindow
---@field prefix string Buffer text from the window's start up to the mark.
---@field suffix string Buffer text from the mark to the window's end.


---Climb from `node` to the top-level construct it sits in, or as far as the budget allows.
---The result is the node the parse window is taken from.
---@param node TSNode
---@return TSNode
local function widen(node)
  while true do
    local parent = node:parent()
    -- EXIT1: `node` is already this layer's root, so there is nothing to widen to.
    if not parent then return node end
    -- EXIT2: the top-level construct is context enough; siblings cannot change what it parses as.
    if not parent:parent() then return node end

    local start_row, _, end_row = node:range()
    local parent_start, _, parent_end = parent:range()
    -- A parent covering the same rows skips the budget: it is what adds the delimiters.
    local grows = parent_start ~= start_row or parent_end ~= end_row
    if grows and parent_end - parent_start > MAX_ROWS then return node end
    node = parent
  end
end


---Take the enclosing construct's text and split it at the mark, so the suggestion can be parsed
---between the halves. With no tree to ask, or past the caps, the mark's own line is used instead.
---@param buf integer
---@param ltree vim.treesitter.LanguageTree? The layer the mark sits in, when there is one.
---@param row integer 0-based.
---@param col integer 0-based.
---@return fade.GhostWindow
local function window(buf, ltree, row, col)
  ---The rows `first` through `last`, split at the mark into the one string on each side that the
  ---parse takes: the rows above join its head, the rows below follow its tail.
  ---@param first integer 0-based.
  ---@param last integer 0-based and inclusive.
  ---@param last_col integer Where to stop on `last`, exclusive; `-1` takes that row whole.
  ---@return fade.GhostWindow
  local function split(first, last, last_col)
    -- NOTE: Read from column 0, so the mark's column cuts its own row unshifted.
    local lines = vim.api.nvim_buf_get_text(buf, first, 0, last, last_col, {})
    local index = row - first + 1  -- 1-indexed for `lines`.
    local head, tail = lines[index]:sub(1, col), lines[index]:sub(col + 1)
    local above, below = vim.list_slice(lines, 1, index - 1), vim.list_slice(lines, index + 1)
    return {
      prefix = #above > 0 and table.concat(above, "\n") .. "\n" .. head or head,
      suffix = #below > 0 and tail .. "\n" .. table.concat(below, "\n") or tail,
    }
  end

  ---The mark's own row, which is the window whenever the construct around it is out of reach.
  local function line_only() return split(row, row, -1) end

  local tree = ltree and ltree:tree_for_range({ row, col, row, col }, { ignore_injections = false })
  -- NOTE: The mark sits at a token's right edge, so only one column left is still inside it.
  local at = math.max(col - 1, 0)
  local found = tree and tree:root():named_descendant_for_range(row, at, row, at)
  -- EXIT: nothing parsed here to take a window from.
  if not found then return line_only() end

  local node = widen(found)
  -- NOTE: The window starts at column 0, not the node's own column: that dedents the first row,
  -- \     and an indentation-sensitive grammar like YAML captures the rows below differently.
  local start_row, _, end_row, end_col = node:range()
  -- NOTE: The window ends at the last line, never at the row a tree root reports -- that might past
  -- \     the file, and `nvim_buf_get_text` refuses it, while `-1` as a column takes the line whole.
  local last = vim.api.nvim_buf_line_count(buf) - 1
  if end_row > last then end_row, end_col = last, -1 end

  local ok, win = pcall(split, start_row, end_row, end_col)
  -- EXIT: Blank rows before any code fall outside a root's range, so `split` misses the mark's row.
  if not ok then return line_only() end

  -- EXIT: Too much to reparse on every keystroke, and the row alone still beats one flat color.
  if #win.prefix + #win.suffix > MAX_BYTES then return line_only() end

  return win
end


-- ════════════════════════════════════════════════════════════
-- ══════════════════════════ Chunks ══════════════════════════
-- ════════════════════════════════════════════════════════════


-- ═════════════════════ Completion kind ══════════════════════

---Capture to give the completed symbol, by `lsp.CompletionItemKind` name.
---A lone identifier parses as `@variable` whatever it really is; the kind knows better.
---@type table<string, string>
local KIND_GROUPS = {
  Method = "@function.method", Function = "@function", Constructor = "@constructor",
  Class = "@type", Interface = "@type", Struct = "@type", Enum = "@type",
  TypeParameter = "@type.parameter", Module = "@module", Keyword = "@keyword",
  Field = "@property", Property = "@property",
  Constant = "@constant", EnumMember = "@constant", Operator = "@operator",
}


---@param kind integer? An `lsp.CompletionItemKind`.
---@return string? group
function M.kind_group(kind)
  local name = kind and vim.lsp.protocol.CompletionItemKind[kind]
  return name and KIND_GROUPS[name]
end


---Give the completed symbol the color its kind says it deserves, by rewriting its chunk in place.
---
---E.g.: A function call is parsed as `@variable`, but the completion knows it is a function.
---@param chunks table[]? A chunk list for one line of the completion.
---@param lang string
---@param kind string? Capture named by the completion kind, from `M.kind_group`.
---@param inserted string? The whole text the completion inserts.
local function apply_kind(chunks, lang, kind, inserted)
  if not chunks or not kind or not inserted then return end

  for i = #chunks, 1, -1 do
    local text = chunks[i][1]
    -- NOTE: A chunk's highlight is stacked, highest priority last: `[1]` is what treesitter
    -- \     called the token and `[2]` our twin, which wins the color and nothing else.
    local group = type(chunks[i][2]) == "table" and chunks[i][2][1] or nil
    -- NOTE: Only the bare guess gives way -- `@variable.lua` does, `@variable.member.lua` does not.
    if (not group or group:match("^@variable%.[^.]+$")) and (#text > 0 and inserted:sub(-#text) == text) then
      local kind_capture = ("%s.%s"):format(kind, lang)
      local twin = faded(kind_capture)
      if twin then chunks[i][2] = { kind_capture, twin } end
      return
    end
  end
end


-- ═════════════════════════ Building ═════════════════════════

---Parse `source` and map each position from `first_row` to `last_row` to the capture covering it,
---last write winning the way treesitter layers its own marks. The rest is parsed but not mapped.
---@param source string
---@param lang string
---@param lines string[] `source` split by line, keyed by line number.
---@param first_row integer First row to map, 0-based.
---@param last_row integer Last row to map, 0-based and inclusive.
---@return fade.CaptureMap? map nil when `lang` has no parser.
local function capture_map(source, lang, lines, first_row, last_row)
  local ok, parser = pcall(vim.treesitter.get_string_parser, source, lang)
  if not ok or not parser then return end

  -- NOTE: An injected language is a tree of its own, and a plain `parse()` walks only the root.
  pcall(parser.parse, parser, true)
  local map = {}

  parser:for_each_tree(function(tree, ltree)
    local query = vim.treesitter.query.get(ltree:lang(), "highlights")
    if not query then return end

    -- IMPO: An explicit `end_row` is exclusive; upstream's `+ 1` runs only when it is nil.
    for id, node in query:iter_captures(tree:root(), source, first_row, last_row + 1) do
      local group = ("@%s.%s"):format(query.captures[id], ltree:lang())
      if faded(group) then
        local start_row, start_col, end_row, end_col = node:range()
        for row = math.max(start_row, first_row), math.min(end_row, last_row) do
          map[row] = map[row] or {}
          local from = row == start_row and start_col or 0
          local to = row == end_row and end_col or #lines[row + 1]
          for col = from, to - 1 do map[row][col] = group end
        end
      end
    end
  end)

  return map
end


---Split a suggestion into `virt_text` chunks, one list per line, each carrying the real capture plus
---its faded twin. Only the suggestion becomes chunks; `win` is context for the parse.
---@param text string The suggestion as drawn, without the prefix already typed.
---@param lang string
---@param win fade.GhostWindow Buffer text around the mark, split where `text` goes.
---@param kind string? Capture named by the completion kind, from `M.kind_group`.
---@param inserted string? The whole text the completion inserts, typed prefix included.
---@return table[]? lines One chunk list per line, 1-indexed.
local function build(text, lang, win, kind, inserted)
  local source = win.prefix .. text .. win.suffix
  local lines = vim.split(source, "\n", { plain = true })

  -- STEP1: Find the suggestion's span in `source` -- the rows and columns it occupies.
  local head = vim.split(win.prefix, "\n", { plain = true })
  local body = vim.split(text, "\n", { plain = true })
  local first_row, first_col = #head - 1, #head[#head]  -- 0-based
  local last_row = first_row + #body - 1
  local last_col = (#body == 1 and first_col or 0) + #body[#body]  -- exclusive

  -- STEP2: Get the capture covering each position in those rows: `map[row][col]` is what to fade.
  local map = capture_map(source, lang, lines, first_row, last_row)
  -- EXIT: No parser for this language, so leave the provider's own colors alone.
  if not map then return end

  -- STEP3: Cut a chunk at every change of group, and stop at the suggestion's end.
  local out = {}
  for row = first_row, last_row do
    local line, chunks = lines[row + 1], {}
    local col = row == first_row and first_col or 0
    local ends = row == last_row and last_col or #line  -- exclusive

    while col < ends do
      local group = map[row] and map[row][col]
      local stop = col + 1  -- exclusive
      while stop < ends and (map[row] and map[row][stop]) == group do stop = stop + 1 end

      local twin = faded(group or "Normal")
      chunks[#chunks + 1] = { line:sub(col + 1, stop), group and { group, twin } or twin }
      col = stop
    end

    out[#out + 1] = chunks
  end

  -- STEP4: The first chunk is the completed symbol, so give it the color its kind says it deserves.
  apply_kind(out[1], lang, kind, inserted)
  return out
end


-- ════════════════════════ Rewriting ═════════════════════════

local ANNOTATION = "CopilotAnnotation"  ---The group copilot draws its cycling count in, on the same extmark as the suggestion.


---Rewrite a ghost-text extmark in place, keeping its id so the provider still owns it.
---@param buf integer
---@param ns integer
---@param id integer
---@param kind string? Capture named by the completion kind, from `M.kind_group`.
---@param inserted string? The whole text the completion inserts, typed prefix included.
function M.recolor(buf, ns, id, kind, inserted)
  if not M.config.enabled or not vim.api.nvim_buf_is_valid(buf) then return end

  local mark = vim.api.nvim_buf_get_extmark_by_id(buf, ns, id, { details = true })
  local row, col, details = mark[1], mark[2], mark[3]
  if not row or not details or not details.virt_text then return end

  -- NOTE: A fenced block is not in the file's language, so the layer at the mark is asked instead.
  local ok, parser = pcall(vim.treesitter.get_parser, buf)
  local ltree = (ok and parser) and parser:language_for_range({ row, col, row, col }) or nil
  local lang = ltree and ltree:lang() or vim.treesitter.language.get_lang(vim.bo[buf].filetype)
  if not lang then return end

  local first = details.virt_text[1]
  -- EXIT: The mark is one we wrote, and blink hands it back several times a keystroke.
  if first and (type(first[2]) == "table" or tostring(first[2]):find("^Fade")) then return end

  -- STEP1: Put the provider's suggestion into a list of chunk lists, one per line.
  ---@type table[][] One row per entry; a row is a list of `{ text, highlight }` chunks.
  local rows = vim.list_extend({ details.virt_text }, details.virt_lines or {})

  -- NOTE: Lift copilot's `(1/3)` count out of the suggestion, for STEP2 to put back untouched.
  -- \     Parsed as code it came out a division; it is the last chunk of the last row.
  local last = vim.list_slice(rows[#rows])  -- a copy, so taking it off leaves `details` whole
  rows[#rows] = last
  local annot = last[#last] and last[#last][2] == ANNOTATION and table.remove(last) or nil

  -- Get the text the provider drew.
  local lines = {}
  for i, chunks in ipairs(rows) do
    lines[i] = table.concat(vim.tbl_map(function(chunk) return chunk[1] end, chunks))
  end
  local text = table.concat(lines, "\n")

  local chunks = build(text, lang, window(buf, ltree, row, col), kind, inserted)
  -- EXIT: `build` found no parser for the language, so the provider's own colors stay.
  if not chunks then return end

  -- STEP2: The annotation was never ours to color, so it returns to its row exactly as drawn.
  if annot and chunks[#chunks] then table.insert(chunks[#chunks], annot) end

  -- STEP3: Set the extmark with the new chunks, keeping the field values the provider set.
  local opts = vim.deepcopy(details) --[[@as table]]
  -- NOTE: Each line below drops something the getter answers with and the setter rejects, throwing.
  opts.ns_id = nil
  opts.invalid = nil
  if opts.virt_text_pos == "win_col" then opts.virt_text_pos = nil end

  opts.id = id
  opts.virt_text = chunks[1]
  opts.virt_lines = #chunks > 1 and vim.list_slice(chunks, 2) or nil

  vim.api.nvim_buf_set_extmark(buf, ns, row, col, opts)
end


-- ════════════════════════════════════════════════════════════
-- ════════════════════════ Providers ═════════════════════════
-- ════════════════════════════════════════════════════════════

-- DESC: Neither plugin takes a chunk list, so the wrapper rewrites the extmark in the same frame it
-- \     set it, before the flat color shows.

---Which providers are wrapped, so a second `hook` does not stack another layer on the first.
M.hooked = {}

---Whether the autocmds are in: `:checkhealth` reports observed state, not what was configured.
M.installed = false


local function hook_copilot()
  if M.hooked.copilot or not package.loaded["copilot"] then return end
  local ok, suggestion = pcall(require, "copilot.suggestion")
  local update_preview = ok and suggestion.update_preview
  if not update_preview then return end
  M.hooked.copilot = true

  -- NOTE: `"copilot.suggestion"` is the namespace the plugin uses for its preview.
  local namespace = vim.api.nvim_create_namespace("copilot.suggestion")
  ---@diagnostic disable-next-line: duplicate-set-field
  suggestion.update_preview = function(...)
    local result = update_preview(...)
    -- NOTE: copilot hardcodes the extmark id as `1` for its preview.
    pcall(M.recolor, vim.api.nvim_get_current_buf(), namespace, 1)
    return result
  end
end


local function hook_blink()
  if M.hooked.blink or not package.loaded["blink.cmp"] then return end
  local ok, ghost = pcall(require, "blink.cmp.completion.windows.ghost_text")
  local draw_preview = ok and ghost.draw_preview
  if not draw_preview then return end
  M.hooked.blink = true

  ghost.draw_preview = function()
    local result = draw_preview()
    -- NOTE: blink's ghost-text namespace is unused; the mark lands in the shared appearance one.
    local config_ok, config = pcall(require, "blink.cmp.config")
    if config_ok and ghost.extmark_id and ghost.extmark_buf then
      local item = ghost.selected_item or {}
      local inserted = (item.textEdit or {}).newText or item.insertText or item.label
      pcall(M.recolor, ghost.extmark_buf, config.appearance.highlight_ns, ghost.extmark_id, M.kind_group(item.kind), inserted)
    end
    return result
  end
end


-- ════════════════════════════════════════════════════════════
-- ══════════════════════════ Setup ═══════════════════════════
-- ════════════════════════════════════════════════════════════

---Wrap whatever providers the config asks for and are loaded. Idempotent.
function M.hook()
  -- EXIT: `disable` leaves wrappers in place, so refusing here is our only say over adding one.
  if not M.config.enabled then return end
  if M.config.providers.copilot then pcall(hook_copilot) end
  if M.config.providers.blink then pcall(hook_blink) end
end


---Hook, and report whether every provider the config asks for is now wrapped. Returning `true` from
---an autocmd callback deletes it, so the listeners retire once there is nothing left to hook.
---@return boolean done
local function hook_until_done()
  M.hook()
  for name, wanted in pairs(M.config.providers) do
    if wanted and not M.hooked[name] then return false end
  end
  return true
end


---Put the autocmds and provider wrappers in. Idempotent.
local function install()
  local group = vim.api.nvim_create_augroup("fade.ghost", { clear = true })
  -- Providers may load lazily, so wrappers go in as they arrive.
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "LazyLoad",
    desc = "Hook ghost text rendering once its provider is loaded",
    callback = hook_until_done,
  })
  -- The case `LazyLoad` leaves over is a provider arriving unannounced before the first insert.
  vim.api.nvim_create_autocmd("InsertEnter", {
    group = group,
    once = true,
    desc = "Hook ghost text rendering before a suggestion can be drawn",
    callback = M.hook,
  })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    desc = "Rebuild the faded groups against the new palette",
    callback = function() hl.clear() end,
  })

  M.installed = true
  M.hook()
end


function M.enable()
  M.config.enabled = true
  install()
end


function M.disable()
  M.config.enabled = false
end


function M.toggle()
  if M.config.enabled then M.disable() else M.enable() end
  return M.config.enabled
end


---@param config? fade.GhostConfig
function M.setup(config)
  M.config = vim.tbl_deep_extend("force", vim.deepcopy(DEFAULTS), config or {})
  if not M.config.enabled then return end

  install()
end


return M
