---`:checkhealth fade`, which is the only thing that tells a user why nothing is fading.
local h = require("helpers")

---Capture every line `fade.health` reports.
---@return string
local function report()
  local lines = {}
  local real = vim.health
  vim.health = setmetatable({}, {
    __index = function(_, level)
      return function(message) lines[#lines + 1] = level .. ": " .. tostring(message) end
    end,
  })

  local ok, err = pcall(require("fade.health").check)
  vim.health = real
  if not ok then error(err, 0) end

  return table.concat(lines, "\n")
end

return {
  { "hidden handlers are listed by name", function()
    -- Regression: `vim.tbl_filter` drops the keys, so this used to report "1, 2, 3".
    local out = report()
    h.truthy(out:find("hidden from handlers: signs, underline, virtual_text", 1, true),
      ("names missing from: %s"):format(out:match("hidden from handlers: [^\n]*") or "(no line)"))
  end },

  { "each feature reports the settings that decide how it fades", function()
    local out = report()
    h.truthy(out:find("alpha 0.75", 1, true), "unused reports its alpha")
    h.truthy(out:find("alpha 0.65", 1, true), "ghost reports its alpha")
    h.truthy(out:find("min_contrast 3", 1, true), "and the floor that overrides it")
    h.truthy(out:find("ignoring @comment", 1, true), "and anything exempt from fading")
  end },

  { "a provider that was never requested is distinguished from one not yet hooked", function()
    local ghost = require("fade.ghost")
    local restore = vim.deepcopy(ghost.config)

    ghost.setup({ providers = { copilot = false, blink = true } })
    local out = report()
    ghost.config = restore

    h.truthy(out:find("copilot: not requested", 1, true), "an unwanted provider says so")
    h.truthy(out:find("blink: not hooked yet", 1, true),
      "a wanted one that has not loaded says something different")
  end },

  { "a disabled feature reports as disabled rather than broken", function()
    local ghost = require("fade.ghost")
    local restore = vim.deepcopy(ghost.config)

    ghost.disable()
    h.truthy(report():find("disabled", 1, true), "disabled is a state, not a failure")

    ghost.config = restore
    ghost.enable()
  end },
}
