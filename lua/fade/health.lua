local M = {}

---@param config fade.UnusedConfig|fade.GhostConfig
---@return string
local function settings(config)
  return ("enabled, alpha %s, min_contrast %s%s"):format(config.alpha, config.min_contrast,
    #config.ignore > 0 and (", ignoring " .. table.concat(config.ignore, " ")) or "")
end


---The buffer `:checkhealth` was run from. Neovim switches to its own `health://` buffer before
---calling any check, so buffer 0 would report on the report.
---@return integer
local function origin()
  local buf = vim.api.nvim_get_current_buf()
  -- EXIT: Called directly rather than through `:checkhealth`, so this is already the right buffer.
  if not vim.api.nvim_buf_get_name(buf):find("^health://") then return buf end

  local alt = vim.fn.bufnr("#")
  return (alt > 0 and vim.api.nvim_buf_is_loaded(alt)) and alt or buf
end


---`:checkhealth fade`. Both features can fail silently -- a missing parser, a renamed provider
---function -- with no symptom but unfaded text. This says which.
function M.check()
  local health = vim.health
  health.start("fade.nvim")

  if vim.fn.has("nvim-0.11") == 1 then
    health.ok("Neovim " .. tostring(vim.version()))
  else
    health.error("Neovim 0.11+ required: semantic tokens are found by namespace name, and 0.11 renamed them")
  end

  local unused = require("fade.unused")
  local ghost = require("fade.ghost")

  local buf = origin()
  local label = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":t")
  if label == "" then label = "[No Name]" end

  -- ═════════════════════════ Unused ═════════════════════════
  health.start("fade.nvim: unused")
  if not unused.config.enabled then
    health.info("disabled")
  else
    health.ok(settings(unused.config))

    if not unused.installed then
      health.error("autocmds are not installed, so fading will not follow diagnostics")
    end

    if unused.config.priority > 150 then
      health.ok("priority " .. unused.config.priority .. " outranks diagnostics (150)")
    else
      health.warn(("priority %d does not outrank diagnostics (150), so fading may not show")
        :format(unused.config.priority))
    end

    -- Reporting `config.hide` let a feature claim to be hiding handlers it had never touched, which
    -- is precisely the failure this check exists to catch. So the names come from what is wrapped.
    -- NOTE: `vim.tbl_filter` drops the keys, so collect the names by hand.
    local hidden = {}
    for name, wrapper in pairs(unused.wrapped) do
      -- A plugin that replaces a handler after `setup` takes our wrapper out with it, and the name
      -- alone would still be here -- so the wrapper itself has to be the one still installed.
      if unused.config.hide[name] and vim.diagnostic.handlers[name] == wrapper then
        hidden[#hidden + 1] = name
      end
    end
    table.sort(hidden)
    health.info("hidden from handlers: " .. (next(hidden) and table.concat(hidden, ", ") or "none"))

    -- The `unnecessary` tag is read through a private field, so a rename upstream would show up as
    -- nothing fading and nothing else. Counting what this buffer's diagnostics look like says so.
    local diagnostics = vim.diagnostic.get(buf)
    local flagged = #vim.tbl_filter(unused.is_unused, diagnostics)
    health.info(("%s: %d diagnostics, %d read as unused"):format(label, #diagnostics, flagged))
  end

  -- ═════════════════════════ Ghost ══════════════════════════
  health.start("fade.nvim: ghost")
  if not ghost.config.enabled then
    health.info("disabled")
  else
    health.ok(settings(ghost.config))

    if not ghost.installed then
      health.error("autocmds are not installed, so a provider loading later will not be hooked")
    end

    for name, wanted in pairs(ghost.config.providers) do
      if not wanted then
        health.info(name .. ": not requested")
      elseif ghost.hooked[name] then
        health.ok(name .. ": hooked")
      else
        health.info(name .. ": not hooked yet (loads lazily; re-check after insert mode)")
      end
    end
  end

  -- ─── Color Sources ────────────────────────────────────────
  -- Two independent layers feed `unused`, and it draws whichever sits on top. Either can be absent,
  -- so a missing parser is only worth a warning when no server is filling in for it -- reporting it
  -- alone told buffers that were being colored perfectly well that they would come out flat.
  health.start(("fade.nvim: color sources (%s)"):format(label))

  local lang = vim.treesitter.language.get_lang(vim.bo[buf].filetype or "")
  local parser = lang ~= nil and pcall(vim.treesitter.get_string_parser, "", lang)
  if parser then
    health.ok(("treesitter: parser for %q is available"):format(lang))
  elseif lang then
    health.info(("treesitter: no %q parser installed"):format(lang))
  else
    health.info("treesitter: no parser maps to this filetype")
  end

  local tokens = false
  for _, client in ipairs(vim.lsp.get_clients({ bufnr = buf })) do
    if vim.tbl_get(client, "server_capabilities", "semanticTokensProvider") then
      tokens = true
      health.ok(("semantic tokens: %s sends them"):format(client.name))
    end
  end
  if not tokens then health.info("semantic tokens: no attached server sends them") end

  if not (parser or tokens) then
    health.warn("neither layer covers this buffer, so `unused` falls back to a flat color")
  elseif not parser and ghost.config.enabled then
    -- NOTE: `ghost` never sees semantic tokens, so the layer covering `unused` here does nothing
    -- \     for suggestions.
    health.info("`ghost` reads treesitter only, so suggestions here keep their plain color")
  end
end

return M
