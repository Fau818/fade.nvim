---fade.nvim -- faded, still syntax-colored text.
---
---Two applications of one technique: take the color treesitter would give a token, mix it toward
---the background, and set only `fg` so bold and italic survive. `unused` applies it to code the
---language server calls dead; `ghost` applies it to inline completion previews.
local M = {}

---@type table<string, table>
local features = {
  unused = require("fade.unused"),
  ghost = require("fade.ghost"),
}


---@param name string?
---@return table[]? chosen nil when `name` names no feature.
local function resolve(name)
  if not name then return { features.unused, features.ghost } end
  local feature = features[name]
  return feature and { feature }
end


---@param action string
---@param name string?
local function dispatch(action, name)
  local chosen = resolve(name)
  if not chosen then
    return vim.notify("Fade: no feature named " .. name, vim.log.levels.ERROR, { title = "fade.nvim" })
  end

  for _, feature in ipairs(chosen) do feature[action]() end
end


-- ════════════════════════════════════════════════════════════
-- ══════════════════════════ Setup ═══════════════════════════
-- ════════════════════════════════════════════════════════════

---@class fade.Config
---@field unused? fade.UnusedConfig
---@field ghost? fade.GhostConfig

---@param config? fade.Config
function M.setup(config)
  config = config or {}

  features.unused.setup(config.unused)
  features.ghost.setup(config.ghost)

  vim.api.nvim_create_user_command("Fade", function(args)
    local action, name = args.fargs[1], args.fargs[2]
    if not vim.tbl_contains({ "enable", "disable", "toggle" }, action) then
      return vim.notify("Fade: expected enable, disable or toggle", vim.log.levels.ERROR, { title = "fade.nvim" })
    end
    -- `nargs` has no "one or two", so the extras are turned away here rather than ignored.
    if #args.fargs > 2 then
      return vim.notify("Fade: expected at most one feature name", vim.log.levels.ERROR, { title = "fade.nvim" })
    end
    dispatch(action, name)
  end, {
    nargs = "+",
    desc = "Turn fading on or off",
    complete = function(arg_lead, line, pos)
      local args = line:sub(1, pos):match("Fade%s+(.*)$") or ""
      local slot = #vim.split(args, "%s+", { trimempty = true }) + ((args == "" or args:match("%s$")) and 1 or 0)

      local candidates = { "enable", "disable", "toggle" }
      if slot > 1 then candidates = vim.tbl_keys(features) table.sort(candidates) end

      return vim.tbl_filter(function(c) return vim.startswith(c, arg_lead) end, candidates)
    end,
  })
end


---@param name string? Only this feature, or both when omitted.
function M.enable(name) dispatch("enable", name) end


---@param name string? Only this feature, or both when omitted.
function M.disable(name) dispatch("disable", name) end


---@param name string? Only this feature, or both when omitted.
function M.toggle(name) dispatch("toggle", name) end


M.unused = features.unused
M.ghost = features.ghost

return M
