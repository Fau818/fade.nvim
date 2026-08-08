---Ghost text: splitting a suggestion into per-capture chunks, and the two escapes from fading.
local h = require("helpers")
local ghost = require("fade.ghost")

---Run `fn` with `overrides` merged into the ghost config, then put the defaults back.
---@param overrides table
---@param fn function
local function configured(overrides, fn)
  local restore = vim.deepcopy(ghost.config)
  ghost.setup(overrides)
  local ok, err = pcall(fn)
  ghost.config = restore
  ghost.setup({})
  if not ok then error(err, 0) end
end

return {
  { "a suggestion is split into one chunk per capture", function()
    h.palette()
    local chunks = h.ghost_chunks("", "local data = vim.json.decode(raw)")

    h.truthy(#chunks >= 8, ("expected many chunks, got %d"):format(#chunks))
    h.truthy(vim.tbl_count(h.chunk_groups(chunks)) >= 4,
      "a keyword, an identifier and a call should not collapse into one color")
    h.eq(table.concat(vim.tbl_map(function(c) return c[1] end, chunks), ""),
      "local data = vim.json.decode(raw)", "the text itself must survive the split")
  end },

  { "a suggestion inside a comment keeps the comment color", function()
    h.palette()
    local chunks = h.ghost_chunks("-- ", "TODO handle the empty case")

    for _, chunk in ipairs(chunks) do
      local group = h.chunk_group(chunk)
      h.truthy(tostring(group):find("^@comment"),
        ("every chunk should stay a comment, got %s"):format(group))
      h.falsy(tostring(chunk[2][2] or ""):find("^Fade"),
        "an ignored group is its own twin, so no Fade group is created")
    end
  end },

  { "clearing ignore lets the comment fade again", function()
    h.palette()
    configured({ ignore = {}, min_contrast = 0 }, function()
      local chunks = h.ghost_chunks("-- ", "TODO handle the empty case")
      local twin = chunks[1][2][2]
      h.truthy(tostring(twin):find("^Fade"), ("expected a faded twin, got %s"):format(twin))
      h.eq(vim.api.nvim_get_hl(0, { name = twin }).fg, h.COMMENT_FADED,
        "and it should be the comment color, faded")
    end)
  end },

  { "min_contrast alone cannot rescue this comment", function()
    h.palette()
    -- Why `ignore` exists: any floor high enough to catch 2.67 also catches ordinary syntax.
    configured({ ignore = {} }, function()
      local faded = require("fade.hl").blend(h.COMMENT_FG, 0x151518, ghost.config.alpha)
      h.near(require("fade.hl").contrast(faded, 0x151518), 2.67, 0.05,
        "if this drifts, the documented 2.67 figure needs updating too")
    end)
  end },

  { "a fragment is parsed in the context of the line it follows", function()
    h.palette()
    -- Alone, `")` is one unterminated string; after the prefix it is a string then a bracket.
    local chunks = h.ghost_chunks('print("hi', '")')
    h.truthy(vim.tbl_count(h.chunk_groups(chunks)) >= 2,
      "the closing quote and bracket are different captures")
  end },

  { "kind_group maps completion kinds to captures", function()
    local kinds = vim.lsp.protocol.CompletionItemKind
    h.eq(ghost.kind_group(kinds.Method), "@function.method", "Method")
    h.eq(ghost.kind_group(kinds.Class), "@type", "Class")
    h.eq(ghost.kind_group(kinds.Keyword), "@keyword", "Keyword")
    h.eq(ghost.kind_group(nil), nil, "no kind, no hint")
    h.eq(ghost.kind_group(9999), nil, "an unknown kind is not a group")
  end },

  { "a filetype with no parser is left to the provider", function()
    h.palette()
    local chunks = h.ghost_chunks("", "some text", "definitely-not-a-language")
    h.eq(chunks, { { "some text", "Comment" } },
      "with nothing to parse, the provider's own extmark must survive untouched")
  end },

  { "disabling leaves the provider's colors alone", function()
    h.palette()
    configured({ enabled = false }, function()
      local chunks = h.ghost_chunks("", "local data = 1")
      h.eq(chunks, { { "local data = 1", "Comment" } }, "recolor is a no-op while disabled")
    end)
  end },

  { "list options replace on setup, they do not merge", function()
    -- `vim.tbl_deep_extend` replaces arrays wholesale, so `ignore = {}` really clears the default.
    configured({ ignore = { "@string" } }, function()
      h.eq(ghost.config.ignore, { "@string" }, "a supplied list wins outright")
    end)
    configured({ ignore = {} }, function()
      h.eq(ghost.config.ignore, {}, "an empty list clears the default rather than being ignored")
    end)
    h.eq(ghost.config.ignore, { "@comment" }, "and the default is back afterwards")
  end },
}
