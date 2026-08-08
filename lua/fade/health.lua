local M = {}

---@param config fade.UnusedConfig|fade.GhostConfig
---@return string
local function settings(config)
  return ("enabled, alpha %s, min_contrast %s%s"):format(config.alpha, config.min_contrast,
    #config.ignore > 0 and (", ignoring " .. table.concat(config.ignore, " ")) or "")
end


---`:checkhealth fade`. Both features can fail silently -- a missing parser, a renamed provider
---function -- with no symptom but unfaded text. This says which.
function M.check()
  local health = vim.health
  health.start("fade.nvim")

  if vim.fn.has("nvim-0.10") == 1 then
    health.ok("Neovim " .. tostring(vim.version()))
  else
    health.error("Neovim 0.10+ required for the `unnecessary` diagnostic tag")
  end

  local unused = require("fade.unused")
  local ghost = require("fade.ghost")

  -- ─── Unused ───────────────────────────────────────────────

  health.start("fade.nvim: unused")
  if not unused.config.enabled then
    health.info("disabled")
  else
    health.ok(settings(unused.config))

    if unused.config.priority > 150 then
      health.ok("priority " .. unused.config.priority .. " outranks diagnostics (150)")
    else
      health.warn(("priority %d does not outrank diagnostics (150), so fading may not show")
        :format(unused.config.priority))
    end

    -- NOTE: `vim.tbl_filter` drops the keys, so collect the names by hand.
    local hidden = {}
    for name, on in pairs(unused.config.hide) do
      if on then hidden[#hidden + 1] = name end
    end
    table.sort(hidden)
    health.info("hidden from handlers: " .. (next(hidden) and table.concat(hidden, ", ") or "none"))
  end

  -- ─── Ghost ────────────────────────────────────────────────

  health.start("fade.nvim: ghost")
  if not ghost.config.enabled then
    health.info("disabled")
  else
    health.ok(settings(ghost.config))

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

  -- ─── Treesitter ───────────────────────────────────────────

  health.start("fade.nvim: treesitter")
  local lang = vim.treesitter.language.get_lang(vim.bo.filetype or "")
  if not lang then
    health.info("no parser maps to this buffer's filetype; fading falls back to a flat color")
  elseif pcall(vim.treesitter.get_string_parser, "", lang) then
    health.ok(("parser for %q is available"):format(lang))
  else
    health.warn(("no %q parser installed, so this filetype gets a flat color"):format(lang))
  end
end

return M
