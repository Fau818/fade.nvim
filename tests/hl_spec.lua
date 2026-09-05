---The color core: blending, contrast, and the two ways a group escapes fading.
local h = require("helpers")
local hl = require("fade.hl")

return {
  { "contrast spans 1 to 21", function()
    h.near(hl.contrast(0x000000, 0xffffff), 21, 0.001, "black against white is the maximum")
    h.near(hl.contrast(0x808080, 0x808080), 1, 0.001, "a color against itself is invisible")
    h.near(hl.contrast(0xffffff, 0x000000), hl.contrast(0x000000, 0xffffff), 0.001,
      "contrast does not depend on argument order")
  end },

  { "blend interpolates from background to foreground", function()
    h.eq(hl.blend(0xffffff, 0x000000, 1), 0xffffff, "alpha 1 keeps the foreground")
    h.eq(hl.blend(0xffffff, 0x000000, 0), 0x000000, "alpha 0 reaches the background")
    h.eq(hl.blend(0xffffff, 0x000000, 0.5), 0x808080, "alpha 0.5 lands halfway")
    h.eq(hl.blend(0x717cbd, 0x151518, 0.65), h.COMMENT_FADED, "channels blend independently")
  end },

  { "background falls back to 'background' when Normal is transparent", function()
    -- Order matters: setting 'background' reapplies the default colorscheme, which would hand
    -- `Normal` a bg again. Clear it after, not before.
    vim.o.background = "dark"
    vim.api.nvim_set_hl(0, "Normal", { fg = 0xc8d3f5 })
    h.eq(hl.background(), 0x000000, "a dark transparent background counts as black")

    vim.o.background = "light"
    vim.api.nvim_set_hl(0, "Normal", { fg = 0x151518 })
    h.eq(hl.background(), 0xffffff, "a light one counts as white")

    h.palette()
    h.eq(hl.background(), 0x151518, "otherwise Normal's own bg wins")
  end },

  { "ignore matches a group and its children, not merely its prefix", function()
    h.truthy(hl.ignored("@comment", { "@comment" }), "the group itself")
    h.truthy(hl.ignored("@comment.lua", { "@comment" }), "a language variant")
    h.truthy(hl.ignored("@comment.documentation.python", { "@comment" }), "a nested capture")
    h.falsy(hl.ignored("@commentary.lua", { "@comment" }), "@commentary is a different group")
    h.falsy(hl.ignored("@string.lua", { "@comment" }), "an unrelated group")
    h.falsy(hl.ignored("@comment.lua", {}), "an empty list ignores nothing")
  end },

  { "a group with no color of its own has no faded twin", function()
    h.palette()
    vim.api.nvim_set_hl(0, "FadeTestBoldOnly", { bold = true })
    h.eq(hl.faded("FadeTestBoldOnly", 0.65, 0), nil,
      "nil is what tells the callers there is nothing here to color")
  end },

  { "min_contrast keeps a group that would fade below the floor", function()
    h.palette()
    local floored = hl.faded("Comment", 0.65, 3.0)
    local unfloored = hl.faded("Comment", 0.65, 0)

    h.eq(vim.api.nvim_get_hl(0, { name = floored }).fg, h.COMMENT_FG,
      "under the floor, the group keeps its own color")
    h.eq(vim.api.nvim_get_hl(0, { name = unfloored }).fg, h.COMMENT_FADED,
      "with the floor off, the same group fades")
    h.truthy(floored ~= unfloored, "the two settings must not share a highlight group")
  end },

  { "a group above the floor fades normally", function()
    h.palette()
    vim.api.nvim_set_hl(0, "FadeTestBright", { fg = 0xc3e88d })
    local group = assert(hl.faded("FadeTestBright", 0.65, 3.0))
    -- `assert`: a group with no faded twin at all is its own failure, and not the one being tested.
    local faded = assert(vim.api.nvim_get_hl(0, { name = group }).fg)

    h.truthy(faded ~= 0xc3e88d, "a bright color has room to fade")
    h.truthy(hl.contrast(faded, hl.background()) >= 3.0, "and still clears the floor")
  end },

  { "faded sets only fg, so bold and italic survive", function()
    h.palette()
    local group = vim.api.nvim_get_hl(0, { name = hl.faded("Comment", 0.65, 0) })
    h.eq(group.italic, nil, "the faded twin carries no italic of its own")
    h.eq(group.bold, nil, "nor bold")
    h.truthy(group.fg ~= nil, "only a foreground")
  end },

  { "clear rebuilds against the current palette", function()
    h.palette()
    local before = vim.api.nvim_get_hl(0, { name = hl.faded("Comment", 0.65, 0) }).fg

    vim.api.nvim_set_hl(0, "Normal", { fg = 0x000000, bg = 0xffffff })
    hl.clear()
    local after = vim.api.nvim_get_hl(0, { name = hl.faded("Comment", 0.65, 0) }).fg

    h.truthy(before ~= after, "fading toward white cannot land where fading toward black did")
    h.palette()
  end },
}
