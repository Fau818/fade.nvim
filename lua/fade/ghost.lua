---Syntax-color inline suggestions instead of the one flat group their plugin draws them in.
---
---Treesitter never touches virtual text, so ghost text arrives one hardcoded color. But a chunk's
---highlight may be a list, merged per field: `{ capture, faded }` takes the color from the twin and
---the italic from the real capture. So the suggestion is parsed alone and the extmark rewritten.
local hl = require("fade.hl")

local M = {}

---@class fade.GhostConfig
---@field enabled? boolean
---@field alpha? number Share of the real syntax color kept; the rest fades into `Normal` bg.
---@field min_contrast? number Groups that would fade below this keep their own color.
---@field ignore? string[] Capture groups never faded, whatever the contrast works out to.
---@field providers? table<string, boolean> Which plugins to hook.
M.config = {
  enabled = true,
  alpha = 0.65,
  min_contrast = 3.0,
  ignore = { "@comment" },
  providers = { copilot = true, blink = true },
}


---@param source string
---@return string? group
local function faded(source)
  -- An ignored group is its own twin. `nil` would read as "no color here" and drop the capture.
  if hl.ignored(source, M.config.ignore) then return source end
  return hl.faded(source, M.config.alpha, M.config.min_contrast)
end


-- ════════════════════════════════════════════════════════════
-- ══════════════════════════ Chunks ══════════════════════════
-- ════════════════════════════════════════════════════════════

---@type table<string, table[]>
local cache = {}

---A lone identifier is `@variable` whatever it really is -- nothing in `unregister_task` says
---function. The completion item's kind does, so it names the group that identifier deserved.
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
  return type(name) == "string" and KIND_GROUPS[name] or nil
end


---Which capture covers each column, last write winning the way treesitter layers its own marks.
---@param source string
---@param lang string
---@param lines string[]
---@return table<integer, table<integer, string>>? map nil when `lang` has no parser.
local function capture_map(source, lang, lines)
  local ok, parser = pcall(vim.treesitter.get_string_parser, source, lang)
  if not ok or not parser then return end

  pcall(parser.parse, parser, true)
  local map = {}

  parser:for_each_tree(function(tree, ltree)
    local query = vim.treesitter.query.get(ltree:lang(), "highlights")
    if not query then return end

    for id, node in query:iter_captures(tree:root(), source) do
      local group = ("@%s.%s"):format(query.captures[id], ltree:lang())
      -- `@spell` has no color of its own; letting it win would drop the `@comment` underneath.
      if faded(group) then
        local start_row, start_col, end_row, end_col = node:range()
        for row = start_row, math.min(end_row, #lines - 1) do
          map[row] = map[row] or {}
          local from = row == start_row and start_col or 0
          local to = row == end_row and end_col or #lines[row + 1]
          for col = from, math.min(to, #lines[row + 1]) - 1 do map[row][col] = group end
        end
      end
    end
  end)

  return map
end


---Give the completed symbol the color its kind says it deserves.
---
---Which chunk that is cannot be assumed: an auto-import sends a qualified `os.pread` and only the
---tail is shown, so the symbol may come last. It is the chunk ending the inserted text -- and only
---one treesitter read as a plain name, since anything specific already beats a guess.
---@param chunks table[]? Chunks of the suggestion's first line.
---@param lang string
---@param hint string? Group named by the completion kind.
---@param symbol string? The text the completion inserts.
local function apply_hint(chunks, lang, hint, symbol)
  if not chunks or not hint or not symbol then return end

  for i = #chunks, 1, -1 do
    local text = chunks[i][1]
    local group = type(chunks[i][2]) == "table" and chunks[i][2][1] or nil
    if (not group or group:find("^@variable")) and #text > 0 and symbol:sub(-#text) == text then
      local hinted = ("%s.%s"):format(hint, lang)
      local twin = faded(hinted)
      if twin then chunks[i][2] = { hinted, twin } end
      return
    end
  end
end


---Split a suggestion into `virt_text` chunks, one list per line, each carrying the real capture
---plus its faded twin. It is a fragment: alone, a trailing `")` parses as one unterminated string
---that swallows the bracket. `prefix .. text` with the prefix dropped fixes the captures.
---@param text string
---@param lang string
---@param prefix string Buffer text to the left of the suggestion.
---@param hint string? Group named by the completion kind.
---@param symbol string? The text the completion inserts.
---@return table[]? lines
local function build(text, lang, prefix, hint, symbol)
  local key = ("%s\0%s\0%s\0%s\0%s"):format(lang, prefix, text, hint or "", symbol or "")
  if cache[key] then return cache[key] end

  local source = prefix .. text
  local lines = vim.split(source, "\n", { plain = true })
  local map = capture_map(source, lang, lines)
  -- EXIT: No parser for this language, so leave the provider's own colors alone.
  if not map then return end

  local out = {}
  for row = 0, #lines - 1 do
    local line, chunks = lines[row + 1], {}
    local col = row == 0 and #prefix or 0

    while col < #line do
      local group = map[row] and map[row][col]
      local stop = col + 1
      while stop < #line and (map[row] and map[row][stop]) == group do stop = stop + 1 end

      local twin = faded(group or "Normal")
      chunks[#chunks + 1] = { line:sub(col + 1, stop), group and { group, twin } or twin }
      col = stop
    end

    out[#out + 1] = chunks
  end

  apply_hint(out[1], lang, hint, symbol)

  cache[key] = out
  return out
end


---Rewrite a ghost-text extmark in place, keeping its id so the provider still owns it.
---Public so a provider this module does not know about can be wired up by hand.
---@param buf integer
---@param ns integer
---@param id integer
---@param hint string? Group named by the completion kind.
---@param symbol string? The text the completion inserts.
function M.recolor(buf, ns, id, hint, symbol)
  if not M.config.enabled or not vim.api.nvim_buf_is_valid(buf) then return end

  local mark = vim.api.nvim_buf_get_extmark_by_id(buf, ns, id, { details = true })
  local row, col, details = mark[1], mark[2], mark[3]
  if not row or not details or not details.virt_text then return end

  local function join(chunks)
    return table.concat(vim.tbl_map(function(chunk) return chunk[1] end, chunks), "")
  end
  local text = join(details.virt_text)
  for _, virt_line in ipairs(details.virt_lines or {}) do text = text .. "\n" .. join(virt_line) end

  local lang = vim.treesitter.language.get_lang(vim.bo[buf].filetype)
  -- EXIT: Nothing to color against.
  if not lang or text == "" then return end

  local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
  local chunks = build(text, lang, line:sub(1, col), hint, symbol)
  if not chunks then return end

  vim.api.nvim_buf_set_extmark(buf, ns, row, col, {
    id = id,
    virt_text = chunks[1],
    virt_lines = #chunks > 1 and vim.list_slice(chunks, 2) or nil,
    virt_text_pos = details.virt_text_pos,
    virt_text_win_col = details.virt_text_win_col,
    hl_mode = details.hl_mode,
    priority = details.priority,
  })
end


-- ════════════════════════════════════════════════════════════
-- ════════════════════════ Providers ═════════════════════════
-- ════════════════════════════════════════════════════════════

---Neither plugin takes a chunk list, so the extmark is rewritten right after it is set -- inside
---the wrapper, so it lands in the same frame and the flat color never shows. Both are pcall'd: a
---rename upstream costs the coloring, not the editor.
M.hooked = {}

---Whether any module of a plugin has loaded. Asking for the draw submodule directly would make
---lazy.nvim load the plugin at startup, so the whole namespace is what gets tested.
---@param prefix string
---@return boolean
local function plugin_loaded(prefix)
  for name in pairs(package.loaded) do
    if name == prefix or name:sub(1, #prefix + 1) == prefix .. "." then return true end
  end
  return false
end


local function hook_copilot()
  if M.hooked.copilot or not plugin_loaded("copilot") then return end
  local ok, suggestion = pcall(require, "copilot.suggestion")
  local update_preview = ok and suggestion.update_preview
  if not update_preview then return end
  M.hooked.copilot = true

  -- `ns_id` is file-local but the namespace is named, so it can be looked up. The id is copilot's
  -- hardcoded 1.
  local namespace = vim.api.nvim_create_namespace("copilot.suggestion")
  suggestion.update_preview = function(...)
    local result = update_preview(...)
    pcall(M.recolor, vim.api.nvim_get_current_buf(), namespace, 1)
    return result
  end
end


local function hook_blink()
  if M.hooked.blink or not plugin_loaded("blink.cmp") then return end
  local ok, ghost = pcall(require, "blink.cmp.completion.windows.ghost_text")
  local draw_preview = ok and ghost.draw_preview
  if not draw_preview then return end
  M.hooked.blink = true

  ghost.draw_preview = function(...)
    local result = draw_preview(...)
    -- NOTE: The module's own `ns` field is dead code; the mark goes to the shared appearance one.
    local config_ok, config = pcall(require, "blink.cmp.config")
    if config_ok and ghost.extmark_id and ghost.extmark_buf then
      local item = ghost.selected_item or {}
      local symbol = (item.textEdit or {}).newText or item.insertText or item.label
      pcall(M.recolor, ghost.extmark_buf, config.appearance.highlight_ns, ghost.extmark_id,
        M.kind_group(item.kind), symbol)
    end
    return result
  end
end


-- ════════════════════════════════════════════════════════════
-- ══════════════════════════ Setup ═══════════════════════════
-- ════════════════════════════════════════════════════════════

function M.hook()
  if M.config.providers.copilot then pcall(hook_copilot) end
  if M.config.providers.blink then pcall(hook_blink) end
end


function M.enable()
  M.config.enabled = true
  M.hook()
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
  M.config = vim.tbl_deep_extend("force", M.config, config or {})
  -- Chunks are keyed by their text, not by the settings that colored it. (`fade.hl` needs no reset:
  -- its keys carry the alpha and floor, so new settings simply miss the old entries.)
  cache = {}

  -- EXIT: Left off, so no provider gets wrapped at all.
  if not M.config.enabled then return end

  local group = vim.api.nvim_create_augroup("fade.ghost", { clear = true })
  -- Providers load lazily, so wrappers go in as they arrive. `InsertEnter` is the backstop: the
  -- earliest ghost text can appear, and hooking is a table lookup once done.
  vim.api.nvim_create_autocmd({ "User", "InsertEnter" }, {
    group = group,
    pattern = { "LazyLoad", "*" },
    desc = "Hook ghost text rendering once its provider is loaded",
    callback = M.hook,
  })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    desc = "Rebuild the faded groups against the new palette",
    callback = function()
      hl.clear()
      cache = {}
    end,
  })

  M.hook()
end


return M
