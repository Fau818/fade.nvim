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
    -- REGRESSION: `vim.tbl_filter` drops the keys, so this used to report "1, 2, 3".
    local out = report()
    h.truthy(out:find("hidden from handlers: signs, underline, virtual_text", 1, true),
      ("names missing from: %s"):format(out:match("hidden from handlers: [^\n]*") or "(no line)"))
  end },

  { "each feature reports the settings that decide how it fades", function()
    -- The values are the case's own: asserting the defaults would mean moving one fails here, in a
    -- file about the report, rather than where it moved. `config` is set directly and put back,
    -- since the report only reads it.
    local unused, ghost = require("fade.unused"), require("fade.ghost")
    local restore = { unused = unused.config, ghost = ghost.config }
    unused.config = vim.tbl_extend("force", vim.deepcopy(restore.unused), { alpha = 0.8 })
    ghost.config = vim.tbl_extend("force", vim.deepcopy(restore.ghost),
      { alpha = 0.6, min_contrast = 2.5, ignore = { "@comment" } })

    local ok, out = pcall(report)
    unused.config, ghost.config = restore.unused, restore.ghost
    if not ok then error(out, 0) end

    h.truthy(out:find("alpha 0.8", 1, true), "unused reports its alpha")
    h.truthy(out:find("alpha 0.6", 1, true), "ghost reports its alpha")
    h.truthy(out:find("min_contrast 2.5", 1, true), "and the floor that overrides it")
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

  { "the handlers reported are the ones actually wrapped", function()
    -- REGRESSION: this read the config, so a feature could claim to be hiding a handler it had
    -- \           never touched -- exactly the state `:checkhealth` exists to reveal.
    local unused = require("fade.unused")
    local restore = vim.deepcopy(unused.config)

    unused.setup({ hide = { fade_test_absent = true } })
    local out = report()
    unused.config = restore
    unused.setup({})

    h.falsy(out:find("fade_test_absent", 1, true),
      "a handler that does not exist cannot be hidden, so it must not be listed as hidden")
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
