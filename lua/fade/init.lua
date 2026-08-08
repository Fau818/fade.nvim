---fade.nvim -- faded, still syntax-colored text.
---
---Two applications of one technique: take the color treesitter would give a token, mix it toward
---the background, and set only `fg` so bold and italic survive. `unused` applies it to code the
---language server calls dead; `ghost` applies it to inline completion previews.
local M = {}

---@class fade.Config
---@field unused? fade.UnusedConfig
---@field ghost? fade.GhostConfig

---@type table<string, table>
local features = {
  unused = require("fade.unused"),
  ghost = require("fade.ghost"),
}


---@param name string?
---@return table[] chosen
local function resolve(name)
  if name and features[name] then return { features[name] } end
  return { features.unused, features.ghost }
end


---@param action string
---@param name string?
local function dispatch(action, name)
  for _, feature in ipairs(resolve(name)) do
    if action == "demo" then
      if feature.demo then feature.demo() end
    else
      feature[action]()
    end
  end
end


-- ════════════════════════════════════════════════════════════
-- ══════════════════════════ Setup ═══════════════════════════
-- ════════════════════════════════════════════════════════════

---@param config? fade.Config
function M.setup(config)
  config = config or {}

  features.unused.setup(config.unused)
  features.ghost.setup(config.ghost)

  vim.api.nvim_create_user_command("Fade", function(args)
    local action, name = args.fargs[1], args.fargs[2]
    if not vim.tbl_contains({ "enable", "disable", "toggle", "demo" }, action) then
      return vim.notify("Fade: expected enable, disable, toggle or demo", vim.log.levels.ERROR)
    end
    if name and not features[name] then
      return vim.notify("Fade: no feature named " .. name, vim.log.levels.ERROR)
    end
    dispatch(action, name)
  end, {
    nargs = "+",
    desc = "Turn fading on or off, or draw a sample suggestion",
    complete = function(_, line)
      local done = #vim.split(vim.trim(line), "%s+")
      if done <= 2 then return { "enable", "disable", "toggle", "demo" } end
      return vim.tbl_keys(features)
    end,
  })
end


---@param name string? Only this feature, or both when omitted.
function M.enable(name) dispatch("enable", name) end


---@param name string? Only this feature, or both when omitted.
function M.disable(name) dispatch("disable", name) end


---@param name string? Only this feature, or both when omitted.
function M.toggle(name) dispatch("toggle", name) end


---Draw a sample inline suggestion at the cursor. Colors follow the current setting, so toggling
---and re-running shows the flat original against the per-token version.
function M.demo() features.ghost.demo() end


M.unused = features.unused
M.ghost = features.ghost

return M
