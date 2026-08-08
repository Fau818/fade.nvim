---Unused code: turning `unnecessary` diagnostics into one faded extmark per token.
local h = require("helpers")
local unused = require("fade.unused")

---An `unnecessary` diagnostic covering the whole of row 0.
---@param length integer
---@return table
local function unnecessary(length)
  return {
    lnum = 0, col = 0, end_lnum = 0, end_col = length,
    message = "unused variable", severity = vim.diagnostic.severity.HINT,
    _tags = { unnecessary = true },
  }
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
}
