---The `:Fade` command and the dispatch behind it: which feature a name resolves to, and what the
---command line offers while you are still typing one.
local h = require("helpers")
local fade = require("fade")

return {
  { "completion offers actions first, then feature names", function()
    -- REGRESSION: `vim.trim` removed the trailing space, which is the only thing telling "finished
    -- \           the action" apart from "still typing it" -- so `:Fade enable <Tab>` offered actions again.
    h.eq(vim.fn.getcompletion("Fade ", "cmdline"), { "enable", "disable", "toggle" },
      "nothing typed yet, so the actions, in the order they are worth reading")
    h.eq(vim.fn.getcompletion("Fade toggle ", "cmdline"), { "ghost", "unused" },
      "an action and a space, so the features it could apply to")
    h.eq(vim.fn.getcompletion("Fade toggle g", "cmdline"), { "ghost" },
      "and a started feature name narrows them")
  end },

  { "completion filters by what has been typed", function()
    -- A Lua `complete` behaves like `customlist`: Neovim does no filtering, so an unfiltered list
    -- let `:Fade en<Tab>` complete to `disable`.
    h.eq(vim.fn.getcompletion("Fade en", "cmdline"), { "enable" }, "only the action that matches")
    h.eq(vim.fn.getcompletion("Fade z", "cmdline"), {}, "and nothing when none does")
  end },

  { "a command modifier does not shift the slot being completed", function()
    -- REGRESSION: the slot was counted from the words of the whole command line, and a modifier is
    -- \           a word like any other -- so `:silent Fade <Tab>` read "silent" as the action already given
    -- \           and offered feature names in its place, then offered nothing once one was half typed.
    h.eq(vim.fn.getcompletion("silent Fade ", "cmdline"), { "enable", "disable", "toggle" },
      "a modifier must not fill the action slot")
    h.eq(vim.fn.getcompletion("silent Fade en", "cmdline"), { "enable" },
      "nor stop a half-typed action from completing")
    h.eq(vim.fn.getcompletion("silent Fade toggle ", "cmdline"), { "ghost", "unused" },
      "and the feature slot still follows the action")
  end },

  { "completion is ordered, not left to `pairs`", function()
    -- `vim.tbl_keys` walks the table, so the feature list came out in whichever order it liked.
    for _ = 1, 5 do
      h.eq(vim.fn.getcompletion("Fade disable ", "cmdline"), { "ghost", "unused" },
        "the same list every time")
    end
  end },

  { "an unknown feature name turns nothing on", function()
    -- REGRESSION: `resolve` fell through to "both", so a typo enabled the feature it was told to
    -- \           leave alone. Only the command checked the name; the Lua API did not.
    local unused, ghost = require("fade.unused"), require("fade.ghost")
    unused.disable()
    ghost.disable()

    local notified
    local real = vim.notify
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.notify = function(message) notified = message end
    local ok = pcall(fade.enable, "gost")
    vim.notify = real

    h.truthy(ok, "a typo is a message, not a crash")
    h.truthy(tostring(notified):find("no feature named gost", 1, true),
      ("expected a complaint, got %s"):format(notified))
    h.falsy(unused.config.enabled, "the misspelled feature stays off")
    h.falsy(ghost.config.enabled, "and so does the other one")

    unused.enable()
    ghost.enable()
  end },

  { "a name still reaches exactly one feature", function()
    local unused, ghost = require("fade.unused"), require("fade.ghost")
    fade.disable("ghost")
    h.falsy(ghost.config.enabled, "the one named is turned off")
    h.truthy(unused.config.enabled, "the other is left alone")
    fade.enable("ghost")

    fade.disable()
    h.falsy(unused.config.enabled, "and no name reaches both")
    h.falsy(ghost.config.enabled, "both of them")
    fade.enable()
  end },
}
