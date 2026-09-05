---Unused code: turning `unnecessary` diagnostics into one faded extmark per token.
local h = require("helpers")
local unused = require("fade.unused")

---An `unnecessary` diagnostic over row 0, from `from` to `to`.
---@param to integer
---@param from integer? Default is the start of the line.
---@return table
local function unnecessary(to, from)
  return {
    lnum = 0, col = from or 0, end_lnum = 0, end_col = to,
    message = "unused variable", severity = vim.diagnostic.severity.HINT,
    _tags = { unnecessary = true },
  }
end

---Where every mark lands once `diagnostics` are set over a one-line buffer, as `start-end` strings.
---@param line string
---@param diagnostics table[]
---@return string[] sorted
local function spans(line, diagnostics)
  local buf = h.buffer({ line })
  h.diagnose(buf, diagnostics)

  local out = {}
  for _, mark in ipairs(h.unused_marks(buf)) do
    out[#out + 1] = ("%d-%d"):format(mark[3], mark[4].end_col)
  end
  table.sort(out)
  return out
end

---Run `fn` with `overrides` merged into the unused config, then put the defaults back.
---@param overrides table
---@param fn function
local function configured(overrides, fn)
  local restore = vim.deepcopy(unused.config)
  unused.setup(overrides)
  local ok, err = pcall(fn)
  unused.config = restore
  unused.setup({})
  if not ok then error(err, 0) end
end


---What `fg` fades to under the settings the feature is fading with. The cases below are about which
---layer the color was taken from, not about the arithmetic -- `hl_spec` pins that against alphas of
---its own -- so restating a default here would only mean that moving it fails in the wrong file.
---@param fg integer Against the background `h.palette()` sets.
---@return integer
local function faded_fg(fg)
  return require("fade.hl").blend(fg, 0x151518, unused.config.alpha)
end

return {
  { "an unused range fades one token at a time", function()
    h.palette()
    local line = "local total = compute(1)"
    local buf = h.buffer({ line })
    h.diagnose(buf, { unnecessary(#line) })

    local marks = h.unused_marks(buf)
    h.truthy(#marks >= 4, ("expected a mark per token, got %d"):format(#marks))

    local groups = {}
    for _, mark in ipairs(marks) do groups[mark[4].hl_group] = true end
    h.truthy(vim.tbl_count(groups) >= 3,
      "the keyword, the name and the call should keep different colors")
  end },

  { "whitespace is left unmarked", function()
    h.palette()
    local line = "local total = compute(1)"
    local buf = h.buffer({ line })
    h.diagnose(buf, { unnecessary(#line) })

    for _, mark in ipairs(h.unused_marks(buf)) do
      local text = line:sub(mark[3] + 1, mark[4].end_col)
      h.falsy(text:match("^%s*$"), ("a mark covers only whitespace: %q"):format(text))
    end
  end },

  { "code with no unused diagnostic is untouched", function()
    h.palette()
    local buf = h.buffer({ "local total = compute(1)" })
    h.diagnose(buf, { {
      lnum = 0, col = 0, end_lnum = 0, end_col = 5,
      message = "something else entirely", severity = vim.diagnostic.severity.WARN,
    } })
    h.eq(#h.unused_marks(buf), 0, "only `unnecessary` code fades")
  end },

  { "disable clears the marks and enable brings them back", function()
    h.palette()
    local line = "local total = compute(1)"
    local buf = h.buffer({ line })
    h.diagnose(buf, { unnecessary(#line) })
    local before = #h.unused_marks(buf)

    unused.disable()
    h.eq(#h.unused_marks(buf), 0, "disabling clears every mark")
    unused.enable()
    h.eq(#h.unused_marks(buf), before, "enabling redraws exactly what was there")
  end },

  { "an excluded filetype is left alone", function()
    h.palette()
    configured({ exclude = { lua = true } }, function()
      local line = "local total = compute(1)"
      local buf = h.buffer({ line })
      h.diagnose(buf, { unnecessary(#line) })
      h.eq(#h.unused_marks(buf), 0, "an excluded filetype never gets marks")
    end)
  end },

  { "patterns catch servers that send no tag", function()
    h.palette()
    local line = "local total = compute(1)"
    local untagged = {
      lnum = 0, col = 0, end_lnum = 0, end_col = #line,
      message = "'total' is not accessed", severity = vim.diagnostic.severity.HINT,
    }

    local buf = h.buffer({ line })
    h.diagnose(buf, { untagged })
    h.eq(#h.unused_marks(buf), 0, "without a matching pattern the message means nothing")

    configured({ patterns = { "[nN]ot accessed" } }, function()
      local matched = h.buffer({ line })
      h.diagnose(matched, { untagged })
      h.truthy(#h.unused_marks(matched) > 0, "a matching pattern stands in for the tag")
    end)
  end },

  { "overlapping ranges are merged before fading", function()
    -- Two servers rarely agree on the exact span. Unmerged, the overlap gets a second set of
    -- extmarks, and a range starting mid-token adds one covering only the tail of it.
    h.palette()
    local line = "local total = compute(1)"

    h.eq(spans(line, { unnecessary(11), unnecessary(#line, 8) }),
      spans(line, { unnecessary(#line) }),
      "two overlapping halves must mark exactly what the one whole range does")
  end },

  { "ranges that end where the next begins are merged too", function()
    -- `before` is deliberately strict, so `not before(last_end, next_start)` is true when the two
    -- meet. Loosen it and a token straddling the seam would be split across two marks.
    h.palette()
    local line = "local total = compute(1)"

    h.eq(spans(line, { unnecessary(11), unnecessary(#line, 11) }),
      spans(line, { unnecessary(#line) }),
      "two touching halves must mark exactly what the one whole range does")
  end },

  { "ranges sharing a start do not upset the sort", function()
    -- `table.sort` rejects a comparator that calls equal elements ordered, but only once five or
    -- more of them collide -- so a pair would not catch `before` being loosened to `<=`.
    h.palette()
    local line = "local total = compute(1)"

    local crowd = {}
    for i = 1, 6 do crowd[i] = unnecessary(5 + i) end

    local ok, result = pcall(spans, line, crowd)
    h.truthy(ok, ("sorting six identical starts threw: %s"):format(result))
    h.eq(ok and result or nil, spans(line, { unnecessary(11) }),
      "and they collapse to the widest of them")
  end },

  { "ranges with live code between them stay apart", function()
    -- The merge joins only what overlaps: swallowing the gap would fade code no server flagged.
    h.palette()
    local line = "local total = compute(1)"
    local buf = h.buffer({ line })
    h.diagnose(buf, { unnecessary(5), unnecessary(#line, 14) })

    local marks = h.unused_marks(buf)
    for _, mark in ipairs(marks) do
      h.falsy(mark[3] >= 5 and mark[3] < 14,
        ("a mark landed on live code: %q"):format(line:sub(mark[3] + 1, mark[4].end_col)))
    end
    h.truthy(#marks >= 4, ("and both flagged spans are still marked, got %d"):format(#marks))
  end },

  { "a range already covered by another adds nothing", function()
    h.palette()
    local line = "local total = compute(1)"

    h.eq(spans(line, { unnecessary(#line), unnecessary(11, 6) }),
      spans(line, { unnecessary(#line) }),
      "a range inside one already flagged contributes no extra marks")
  end },

  { "an ignored capture keeps its own color", function()
    -- `unused` ignores nothing by default, so this branch had no coverage at all. Returning `nil`
    -- rather than the source group would drop dead code's comments back to the flat gray.
    h.palette()
    local line = "local total = 1  -- note"
    local comment_at = line:find("%-%-") - 1

    ---Every distinct group the marks over the comment resolve to.
    local function over_comment(buf)
      local groups = {}
      for _, mark in ipairs(h.unused_marks(buf)) do
        if mark[3] >= comment_at then groups[mark[4].hl_group] = true end
      end
      return vim.tbl_keys(groups)
    end

    configured({ ignore = { "@comment" } }, function()
      local buf = h.buffer({ line })
      h.diagnose(buf, { unnecessary(#line) })
      h.eq(over_comment(buf), { "@comment.lua" },
        "an ignored capture is drawn in its own group, never in a faded twin")
    end)

    local buf = h.buffer({ line })
    h.diagnose(buf, { unnecessary(#line) })
    local groups = over_comment(buf)
    h.eq(#groups, 1, "one group covers the comment either way")
    h.truthy(tostring(groups[1]):find("^Fade"),
      ("and without `ignore` that same comment fades, got %s"):format(groups[1]))
  end },

  { "an injected language keeps its own captures", function()
    -- REGRESSION: a parse that stops at the root tree reaches none of the injected ones, so a
    -- \           fenced block faded flat. Both parsers here ship with Neovim.
    h.palette()
    local code = "local x = compute(1)"
    local buf = h.buffer({ "text", "```lua", code, "```" }, "markdown")
    h.diagnose(buf, { {
      lnum = 2, col = 0, end_lnum = 2, end_col = #code,
      message = "unused variable", severity = vim.diagnostic.severity.HINT,
      _tags = { unnecessary = true },
    } })

    local groups = {}
    for _, mark in ipairs(h.unused_marks(buf)) do groups[mark[4].hl_group] = true end

    h.falsy(groups["DiagnosticUnnecessary"],
      "falling back to the flat group means the injected tree was never reached")
    h.truthy(vim.tbl_count(groups) >= 3,
      ("the keyword, the name and the call should stay apart, got %d groups")
        :format(vim.tbl_count(groups)))
  end },

  { "an injected language splits into the tokens its own buffer would", function()
    -- REGRESSION: walking the top-level tree, whose only node over a fenced block spans the whole
    -- \           block, reads as "no boundary here": `compute(1)` stayed one token and took the
    -- \           call's color across the brackets.
    h.palette()
    local code = "local x = compute(1)"

    ---@param buf integer
    ---@return string[] Every mark as `start-end group`, sorted.
    local function marked(buf)
      local out = {}
      for _, mark in ipairs(h.unused_marks(buf)) do
        out[#out + 1] = ("%d-%d %s"):format(mark[3], mark[4].end_col, mark[4].hl_group)
      end
      table.sort(out)
      return out
    end

    local fenced = h.buffer({ "text", "```lua", code, "```" }, "markdown")
    h.diagnose(fenced, { {
      lnum = 2, col = 0, end_lnum = 2, end_col = #code,
      message = "unused variable", severity = vim.diagnostic.severity.HINT,
      _tags = { unnecessary = true },
    } })

    local plain = h.buffer({ code })
    h.diagnose(plain, { unnecessary(#code) })

    -- The rows differ, so compare the columns and groups rather than the marks themselves.
    local a, b = marked(fenced), marked(plain)
    h.eq(#a, #b, ("a fenced block split into %d tokens, its own buffer into %d"):format(#a, #b))
    h.eq(a, b, "and each one should land on the same columns, in the same group")
  end },

  { "a semantic token decides the color, not the capture underneath it", function()
    -- Highlights stack and merge per field, so the color a token shows is the one from the topmost
    -- layer that defines an `fg`. Reading only treesitter meant fading a color the screen was not
    -- showing whenever the server classified an identifier differently.
    h.palette()
    vim.api.nvim_set_hl(0, "@function.call.lua", { fg = 0x82aaff, italic = true })
    vim.api.nvim_set_hl(0, "@lsp.mod.defaultLibrary.lua", {})
    vim.api.nvim_set_hl(0, "@lsp.typemod.class.defaultLibrary.lua", { fg = 0xffc777 })

    local line = "local a = compute(1)"
    local buf = h.buffer({ line })
    local ns = vim.api.nvim_create_namespace("nvim.lsp.semantic_tokens:1")
    -- The three marks Neovim draws for one token: type, then modifier and typemod, priority rising.
    for _, layer in ipairs({
      { "@lsp.type.class.lua", 125 },
      { "@lsp.mod.defaultLibrary.lua", 126 },
      { "@lsp.typemod.class.defaultLibrary.lua", 127 },
    }) do
      vim.api.nvim_buf_set_extmark(buf, ns, 0, 10,
        { end_col = 17, hl_group = layer[1], priority = layer[2] })
    end
    h.diagnose(buf, { unnecessary(#line) })

    local group
    for _, mark in ipairs(h.unused_marks(buf)) do
      if line:sub(mark[3] + 1, mark[4].end_col) == "compute" then group = mark[4].hl_group end
    end

    h.eq(vim.api.nvim_get_hl(0, { name = group }).fg,
      faded_fg(0xffc777),
      ("`compute` should fade from the typemod layer, not the capture; got %s"):format(group))

    vim.api.nvim_set_hl(0, "@function.call.lua", {})
    vim.api.nvim_set_hl(0, "@lsp.typemod.class.defaultLibrary.lua", {})
  end },

  { "semantic tokens sharing a priority are not left to the sort to separate", function()
    -- REGRESSION: `semantic_marks` sorted on `priority` alone, which does not order these. Neovim
    -- emits one mark per modifier -- `@lsp.mod.<mod>` at 126, `@lsp.typemod.<type>.<mod>` at 127 --
    -- so a token with several modifiers lands several marks on one priority, and `table.sort` is
    -- unstable. Six is what it takes to see it; two or three sort stably by accident.
    h.palette()
    local mods = { "readonly", "defaultLibrary", "static", "deprecated", "async", "declaration" }
    local colors = { 0xffc777, 0xc3e88d, 0x82aaff, 0xff757f, 0xc099ff, 0x86e1fc }
    local function group_for(mod) return ("@lsp.typemod.class.%s.lua"):format(mod) end
    for i, mod in ipairs(mods) do vim.api.nvim_set_hl(0, group_for(mod), { fg = colors[i] }) end

    local line = "local a = compute(1)"
    local buf = h.buffer({ line })
    local ns = vim.api.nvim_create_namespace("nvim.lsp.semantic_tokens:3")
    for _, mod in ipairs(mods) do
      vim.api.nvim_buf_set_extmark(buf, ns, 0, 10,
        { end_col = 17, hl_group = group_for(mod), priority = 127 })
    end
    h.diagnose(buf, { unnecessary(#line) })

    local group
    for _, mark in ipairs(h.unused_marks(buf)) do
      if line:sub(mark[3] + 1, mark[4].end_col) == "compute" then group = mark[4].hl_group end
    end

    -- Nothing ranks equally ranked modifiers, so the last one set winning is a choice rather than a
    -- fact to match -- pinned because an unpinned one is the sort's to make again. Compared as the
    -- twin of a source group, not as a color, so the contrast floor cannot move what is asserted.
    h.eq(group, require("fade.hl").faded(group_for(mods[#mods]), unused.config.alpha,
      unused.config.min_contrast),
      ("the last of %d marks tied at 127 should decide the color; got %s"):format(#mods, group))

    for _, mod in ipairs(mods) do vim.api.nvim_set_hl(0, group_for(mod), {}) end
  end },

  { "a semantic token landing late redraws what was already faded", function()
    -- Tokens arrive after the diagnostics that triggered the refresh, so without an event of their
    -- own the first coloring would stand and never be corrected.
    h.palette()
    vim.api.nvim_set_hl(0, "@lsp.type.class.lua", { fg = 0xffc777 })

    local line = "local a = compute(1)"
    local buf = h.buffer({ line })
    h.diagnose(buf, { unnecessary(#line) })

    local function group_over_compute()
      for _, mark in ipairs(h.unused_marks(buf)) do
        if line:sub(mark[3] + 1, mark[4].end_col) == "compute" then return mark[4].hl_group end
      end
    end
    local before = group_over_compute()

    local ns = vim.api.nvim_create_namespace("nvim.lsp.semantic_tokens:1")
    vim.api.nvim_buf_set_extmark(buf, ns, 0, 10,
      { end_col = 17, hl_group = "@lsp.type.class.lua", priority = 125 })
    vim.api.nvim_exec_autocmds("LspTokenUpdate", { buffer = buf, modeline = false })
    vim.wait(200, function() return group_over_compute() ~= before end)

    h.truthy(group_over_compute() ~= before,
      ("the token landed but the fading never followed; still %s"):format(before))
    h.eq(vim.api.nvim_get_hl(0, { name = group_over_compute() }).fg,
      faded_fg(0xffc777), "and it should fade from the token")

    vim.api.nvim_set_hl(0, "@lsp.type.class.lua", {})
  end },


  { "disabling hands unused diagnostics back to the handlers", function()
    -- REGRESSION: the wrapper filtered whether or not the feature was on, so turning `unused` off
    -- \           cleared the fading *and* kept Neovim's own underline hidden -- dead code with no marking at
    -- \           all, which is worse than either state on its own.
    h.palette()
    local seen
    vim.diagnostic.handlers["fade_test_spy"] = {
      show = function(_, _, diagnostics) seen = diagnostics end,
      hide = function() end,
    }

    local line = "local total = compute(1)"
    configured({ hide = { fade_test_spy = true } }, function()
      local buf = h.buffer({ line })
      h.diagnose(buf, { unnecessary(#line) })
      h.eq(#(seen or {}), 0, "while fading, the handler must not mark the same code again")

      unused.disable()
      h.diagnose(buf, {})
      h.diagnose(buf, { unnecessary(#line) })
      h.eq(#(seen or {}), 1, "with fading off, the handler is what marks it")
      unused.enable()
    end)

    vim.diagnostic.handlers["fade_test_spy"] = nil
  end },

  { "an excluded filetype keeps Neovim's own marking", function()
    -- REGRESSION: the wrapper read `enabled` and `hide` but not `exclude`, so a filetype `refresh`
    -- \           leaves alone got no fading *and* no underline -- the same "no marking at all" as
    -- \           the case above, reached another way. Its own handler name: wrapping happens once
    -- \           per handler for the whole run, so a shared spy would be the bare one.
    h.palette()
    local seen
    vim.diagnostic.handlers["fade_test_excluded"] = {
      show = function(_, _, diagnostics) seen = diagnostics end,
      hide = function() end,
    }

    local line = "local total = compute(1)"
    configured({ exclude = { ["fade-excluded"] = true }, hide = { fade_test_excluded = true } },
      function()
        local buf = h.buffer({ line }, "fade-excluded")
        h.diagnose(buf, { unnecessary(#line) })

        h.eq(#h.unused_marks(buf), 0, "an excluded filetype should not be faded")
        h.eq(#(seen or {}), 1, "so the handler has to go on marking it")
      end)

    vim.diagnostic.handlers["fade_test_excluded"] = nil
  end },

  { "a later setup can show a hidden handler again", function()
    -- REGRESSION: the wrapper closed over the first `hide` it saw, so a second `setup` was ignored.
    h.palette()
    local seen
    vim.diagnostic.handlers["fade_test_relisted"] = {
      show = function(_, _, diagnostics) seen = diagnostics end,
      hide = function() end,
    }

    local line = "local total = compute(1)"
    configured({ hide = { fade_test_relisted = true } }, function()
      h.diagnose(h.buffer({ line }), { unnecessary(#line) })
      h.eq(#(seen or {}), 0, "hidden to begin with")
    end)
    configured({ hide = { fade_test_relisted = false } }, function()
      h.diagnose(h.buffer({ line }), { unnecessary(#line) })
      h.eq(#(seen or {}), 1, "and shown once the config says so")
    end)

    vim.diagnostic.handlers["fade_test_relisted"] = nil
  end },

  { "enabling a feature that started disabled installs its autocmds", function()
    -- REGRESSION: `setup` returned before creating them and `enable` only flipped the flag, so the
    -- \           feature drew once and then never followed another diagnostic.
    pcall(vim.api.nvim_del_augroup_by_name, "fade.unused")

    configured({ enabled = false }, function()
      h.falsy(pcall(vim.api.nvim_get_autocmds, { group = "fade.unused" }),
        "a feature left off installs nothing")

      unused.enable()
      local ok, autocmds = pcall(vim.api.nvim_get_autocmds, { group = "fade.unused" })
      h.truthy(ok, "enabling has to put them in")

      local events = {}
      for _, autocmd in ipairs(ok and autocmds or {}) do events[autocmd.event] = true end
      h.truthy(events.DiagnosticChanged, "without this the fading never follows the server")
      h.truthy(events.ColorScheme, "nor a new palette")
    end)
  end },

  { "a filetype with no parser still fades, flatly", function()
    h.palette()
    local line = "some unparseable content"
    local buf = h.buffer({ line }, "definitely-not-a-language")
    h.diagnose(buf, { unnecessary(#line) })

    local marks = h.unused_marks(buf)
    h.truthy(#marks > 0, "the range should still be marked")
    for _, mark in ipairs(marks) do
      h.eq(mark[4].hl_group, "DiagnosticUnnecessary",
        "with no captures to read, Neovim's own flat group is the honest fallback")
    end
  end },

  { "a filetype with no parser is still colored by the server's semantic tokens", function()
    -- The two layers are independent, so a missing grammar is not an early return: an
    -- `if not parser then return map end` once left every such buffer flat, with the docs agreeing
    -- that was expected -- which is why the case above, on its own, was not enough.
    h.palette()
    vim.api.nvim_set_hl(0, "@lsp.type.class.xyz", { fg = 0xffc777 })

    local line = "some unparseable content"
    local buf = h.buffer({ line }, "definitely-not-a-language")
    local ns = vim.api.nvim_create_namespace("nvim.lsp.semantic_tokens:2")
    vim.api.nvim_buf_set_extmark(buf, ns, 0, 5,
      { end_col = 16, hl_group = "@lsp.type.class.xyz", priority = 125 })
    h.diagnose(buf, { unnecessary(#line) })

    local group
    for _, mark in ipairs(h.unused_marks(buf)) do
      if line:sub(mark[3] + 1, mark[4].end_col) == "unparseable" then group = mark[4].hl_group end
    end

    h.truthy(group, "`unparseable` should be one mark of its own, not swallowed by the flat run")
    h.eq(vim.api.nvim_get_hl(0, { name = group }).fg,
      faded_fg(0xffc777),
      ("it should fade from the semantic token, with no parser in play; got %s"):format(group))

    vim.api.nvim_set_hl(0, "@lsp.type.class.xyz", {})
  end },
}
