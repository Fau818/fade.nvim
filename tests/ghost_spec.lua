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
    -- `COMMENT_FADED` is a measurement, so the alpha is the fixture's and never a feature default.
    configured({ alpha = h.COMMENT_ALPHA, ignore = {}, min_contrast = 0 }, function()
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
    configured({ alpha = h.COMMENT_ALPHA, ignore = {} }, function()
      local faded = require("fade.hl").blend(h.COMMENT_FG, 0x151518, ghost.config.alpha)
      h.near(require("fade.hl").contrast(faded, 0x151518), 2.67, 0.05,
        "if this drifts, the documented 2.67 figure needs updating too")
    end)
  end },

  { "a fragment is parsed in the context of the buffer text around it", function()
    h.palette()
    -- Alone, `")` is one unterminated string; after the text it follows, a string then a bracket.
    local chunks = h.ghost_chunks('print("hi', '")')
    h.truthy(vim.tbl_count(h.chunk_groups(chunks)) >= 2,
      "the closing quote and bracket are different captures")
  end },

  { "a suggestion inside a multi-line string is not read as code", function()
    -- REGRESSION: the window was the current line up to the mark, so a construct opened on an
    -- \           earlier row was never in it. A suggestion inside a docstring parsed as code --
    -- \           `is` an operator, `best (1/1)` a call and a division.
    h.palette()
    local chunks = h.ghost_at({ "local s = [[", "what is the best?", "I ", "]]" }, 2, 2,
      "think it is the best (1/1)")

    h.eq(h.chunk_groups(chunks), { ["@string.lua"] = true },
      "the whole suggestion is string content, however much of it reads like code")
  end },

  { "the window widens to whatever opened the construct", function()
    -- The smallest node holding the mark is `comment_content`, and its range starts *after* the
    -- `--[[` that made it a comment: a window cut there parses as code again. So the climb keeps
    -- going while a parent covers the same rows -- free, and it is what picks the delimiters up.
    h.palette()
    local chunks = h.ghost_at({ "--[[", "note ", "]]" }, 1, 5, "about the thing")

    h.eq(h.chunk_groups(chunks), { ["@comment.lua"] = true },
      "the `--[[` two rows up is the whole reason this is a comment")
  end },

  { "buffer text right of the mark is context, not content", function()
    -- Ghost text lands between the two halves of a line, so both belong in the parse: autopairs put
    -- the `]]` in when the `[[` was typed, and without it `lo world` reads as two identifiers rather
    -- than string content. The right half must not become chunks either, or the buffer's own text is
    -- drawn a second time on top of itself.
    h.palette()
    local chunks = h.ghost_at({ "local s = [[hel]]" }, 0, 15, "lo world")

    h.eq(h.chunk_groups(chunks), { ["@string.lua"] = true },
      "what closes the string is to the right of the mark, and it still decides what this is")
    h.eq(table.concat(vim.tbl_map(function(chunk) return chunk[1] end, chunks), ""), "lo world",
      "while the buffer's own text stays in the buffer")
  end },

  { "a multi-line suggestion ends where the buffer text resumes", function()
    -- The window wraps the suggestion on both sides, so the span that becomes chunks begins partway
    -- into one row and ends partway into another -- only a multi-row one can catch the end going wrong.
    h.palette()
    local ns = vim.api.nvim_create_namespace("fade.tests.multiline")
    local buf = h.buffer({ "local x = ()" })
    local id = vim.api.nvim_buf_set_extmark(buf, ns, 0, 11, {
      virt_text = { { "compute(", "Comment" } },
      virt_lines = { { { "  1,", "Comment" } }, { { ") + 2", "Comment" } } },
      virt_text_pos = "inline",
    })

    ghost.recolor(buf, ns, id)
    -- `assert`: the mark going missing entirely is its own failure, and not the one being tested.
    local details = assert(vim.api.nvim_buf_get_extmark_by_id(buf, ns, id, { details = true })[3])
    local function joined(chunks)
      return table.concat(vim.tbl_map(function(chunk) return chunk[1] end, chunks), "")
    end

    h.eq(joined(details.virt_text), "compute(", "the first row stops where the suggestion does")
    h.eq(vim.tbl_map(joined, details.virt_lines), { "  1,", ") + 2" },
      "and every row below carries its own line and nothing the buffer already draws")
    h.eq(h.chunk_group(details.virt_lines[2][1]), "@punctuation.bracket.lua",
      "the `)` closes the call the first row opened, so the window held the two together")
  end },

  { "the window stops at the edge of an injected block", function()
    -- The window comes from the layer under the mark, so the climb runs inside the injected tree and
    -- stops at the fence rather than out in the markdown. The stray quote above proves it: read as
    -- lua it opens a string that swallows the suggestion whole. |vim.treesitter.get_node()| is the
    -- way to get this wrong -- it answers from the outermost layer.
    h.palette()
    local chunks = h.ghost_at({ 'prose with a " in it', "```lua", "local x = 1", "```" }, 2, 11,
      " + compute(2)", "markdown")

    local groups = {}
    for _, chunk in ipairs(chunks) do groups[chunk[1]] = h.chunk_group(chunk) end
    h.eq(groups["compute"], "@function.call.lua", "the fence's own language, down to its tokens")
    h.falsy(groups[" + compute(2)"], "one flat run would mean the window took the prose in too")
  end },

  { "a language injected into the suggestion keeps its own captures", function()
    -- REGRESSION: a plain `parse()` leaves `for_each_tree` seeing only the root tree, so a layer
    -- \           the window injects is never walked and its rows fall back to the flat twin.
    h.palette()
    local chunks = h.ghost_at({ "# title", "" }, 1, 0, "```lua\nlocal x = 1\n```", "markdown")

    h.eq(h.chunk_groups(chunks), { ["@markup.raw.markdown_inline"] = true },
      "the fence is raw markup, which only the injected layer captures")
  end },

  { "the climb stops before the window grows past 200 rows", function()
    -- A frame budget, not a correctness one: the window is reparsed on every redraw. The table
    -- is what makes the cut visible -- `name = 1` inside a constructor is a `@property`, and the
    -- same line standing on its own is an assignment to a global.
    h.palette()
    local function key_group(rows)
      local lines = { "local t = {" }
      for i = 1, rows do lines[#lines + 1] = ("  key%d = %d,"):format(i, i) end
      lines[#lines + 1] = "  n"
      lines[#lines + 1] = "}"
      return h.chunk_group(h.ghost_at(lines, #lines - 2, 3, "ame = 1,")[1])
    end

    h.eq(key_group(150), "@property.lua", "a constructor inside the budget is climbed out to")
    h.eq(key_group(250), "@variable.lua", "one past it is not, so the field reads as a global")
  end },

  { "past 32 KiB the window is given up on entirely", function()
    -- The row budget bounds the climb, and this bounds where the climb can have got to: a parent
    -- covering the same rows is climbed for free however large it is, and a long string is exactly
    -- such a node. Without this the whole of one is reparsed on every keystroke.
    h.palette()
    local lines = { "local s = [[" }
    for i = 1, 900 do
      lines[#lines + 1] = ("filler line %d, wordy enough to add up in bytes"):format(i)
    end
    lines[#lines + 1] = "I "
    lines[#lines + 1] = "]]"

    local chunks = h.ghost_at(lines, #lines - 2, 2, "think it is the best")
    h.falsy(h.chunk_groups(chunks)["@string.lua"],
      "over the cap the string that opened 900 rows up is out of reach, and that is the deal")
  end },

  { "the window is the top-level construct, not the whole file", function()
    -- The climb stops one step under the root. Bulk in a sibling is what makes that visible, since a
    -- well-formed one cannot change a capture: taken in, the window clears 32 KiB and the string is
    -- given up on; left out, it is nowhere near. Under 200 rows deliberately -- the row budget would
    -- otherwise be what stopped the climb, and this case would pass without the rule.
    h.palette()
    local lines = { "local blob = [[" }
    for i = 1, 190 do
      lines[#lines + 1] = ("filler %d "):format(i) .. string.rep("wordy ", 27)
    end
    vim.list_extend(lines, { "]]", "", "local s = [[", "I ", "]]" })

    local chunks = h.ghost_at(lines, #lines - 2, 2, "think it is the best")
    h.truthy(h.chunk_groups(chunks)["@string.lua"],
      "another top-level construct's bulk should not cost this one its context")
  end },

  { "the line fallback keeps the buffer text right of the mark too", function()
    -- REGRESSION: the fallback was the line *up to* the mark. The main path gained a suffix and
    -- \           this did not, so anything falling back read as code whenever what closed the
    -- \           construct sat to the right -- here the `]]`, with the table over the byte cap.
    h.palette()
    local filler = string.rep("x", 9000)
    local lines = { "local t = {" }
    for _, key in ipairs({ "a", "b", "c", "d" }) do
      lines[#lines + 1] = ("  %s = [[%s]],"):format(key, filler)
    end
    vim.list_extend(lines, { "  e = [[hel]],", "}" })

    local chunks = h.ghost_at(lines, #lines - 2, #"  e = [[hel", "lo world")
    h.eq(h.chunk_groups(chunks), { ["@string.lua"] = true },
      "the line alone still holds both halves, and the right one is what closes the string")
  end },

  { "a mark above every line of code falls back to its own line", function()
    -- REGRESSION: a tree's root starts at the first row that holds code, not at row 0, so on a
    -- \           leading blank line the window began below the mark -- `lines[index]` was nil and
    -- \           the whole recolor threw inside the provider's `pcall`.
    h.palette()
    local chunks = h.ghost_at({ "", "local x = 1" }, 0, 0, "local y = 2")

    h.eq(table.concat(vim.tbl_map(function(c) return c[1] end, chunks), ""), "local y = 2",
      "a window that cannot hold the mark must fall back, not throw")
  end },

  { "kind_group maps completion kinds to captures", function()
    local kinds = vim.lsp.protocol.CompletionItemKind
    h.eq(ghost.kind_group(kinds.Method), "@function.method", "Method")
    h.eq(ghost.kind_group(kinds.Class), "@type", "Class")
    h.eq(ghost.kind_group(kinds.Keyword), "@keyword", "Keyword")
    h.eq(ghost.kind_group(nil), nil, "no kind, no hint")
    h.eq(ghost.kind_group(9999), nil, "an unknown kind is not a group")
  end },

  { "the completion kind names the group a plain identifier could not", function()
    h.palette()
    local chunks = h.ghost_chunks("local a = fi", "eld", nil, "@function", "field")
    h.eq(h.chunk_group(chunks[#chunks]), "@function.lua",
      "a bare `@variable` gives way to what the kind says")
  end },

  { "the kind's chunk keeps the twin that fades it", function()
    -- REGRESSION: `h.chunk_group` reads either form, so writing the kind's capture on its own --
    -- \           with no twin behind it -- passed every assertion while the symbol drew unfaded.
    h.palette()
    local chunks = h.ghost_chunks("local a = fi", "eld", nil, "@function", "field")
    local hl = chunks[#chunks][2]

    h.truthy(type(hl) == "table" and tostring(hl[2]):find("^Fade"),
      ("the kind's color must come from a faded twin, got %s"):format(vim.inspect(hl)))
  end },

  { "a capture treesitter had evidence for outranks the kind", function()
    -- REGRESSION: the guard was `group:find("^@variable")`, which also matched
    -- \           `@variable.member` -- a read treesitter only reaches by seeing the dot. The
    -- \           kind overwrote it, so a field took the color of whatever the item was declared.
    h.palette()
    local chunks = h.ghost_chunks("local a = t.fi", "eld", nil, "@property", "field")
    h.eq(h.chunk_group(chunks[#chunks]), "@variable.member.lua",
      "`@variable.member` is specific, so the hint must leave it alone")
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

  { "the hook autocmds are the two that can fire, not a crossed list", function()
    -- REGRESSION: one call with both events and both patterns registered four, of which `User *`
    -- \           ran for every User event any plugin sent, and `InsertEnter LazyLoad` for no file.
    ghost.enable()
    local hooks = {}
    for _, autocmd in ipairs(vim.api.nvim_get_autocmds({ group = "fade.ghost" })) do
      if autocmd.event ~= "ColorScheme" then
        hooks[#hooks + 1] = ("%s %s"):format(autocmd.event, autocmd.pattern)
      end
    end
    table.sort(hooks)

    h.eq(hooks, { "InsertEnter *", "User LazyLoad" },
      "one autocmd per event, each with the pattern that means something for it")
  end },

  { "recolor keeps the extmark options it does not own", function()
    -- REGRESSION: the rewrite hand-picked four fields and dropped the rest, so a provider's
    -- \           `virt_lines_above` or `virt_text_hide` vanished the moment the suggestion was
    -- \           colored -- and anything Neovim adds later would have gone the same way.
    h.palette()
    local ns = vim.api.nvim_create_namespace("fade.tests.options")
    local buf = h.buffer({ "local x = 1" })
    local id = vim.api.nvim_buf_set_extmark(buf, ns, 0, 11, {
      virt_text = { { "local data = vim.json.decode(raw)", "Comment" } },
      virt_text_pos = "inline",
      virt_text_hide = true,
      right_gravity = false,
      priority = 175,
    })

    ghost.recolor(buf, ns, id)
    local details = assert(vim.api.nvim_buf_get_extmark_by_id(buf, ns, id, { details = true })[3])

    h.eq(details.virt_text_hide, true, "an option the rewrite never sets must survive it")
    h.eq(details.right_gravity, false, "including the ones deciding how the mark moves on an edit")
    h.eq(details.priority, 175, "and the ones it used to carry across by hand")
    h.eq(details.virt_text_pos, "inline", "the positioning too")
    h.truthy(#details.virt_text > 1, "while the text itself is still split into captures")
  end },

  { "recolor survives a suggestion positioned by window column", function()
    -- REGRESSION: the getter reports `win_col` for a mark placed by `virt_text_win_col`, and the
    -- \           setter refuses it -- `virt_text_win_col` is already in `opts` doing that job.
    -- \           copilot switches to it the moment a suggestion runs past one line, so every
    -- \           multi-line suggestion threw into the provider's `pcall` and the flat color
    -- \           stayed. Single-line ones are `inline`, which is how it went unseen.
    h.palette()
    local ns = vim.api.nvim_create_namespace("fade.tests.wincol")
    local buf = h.buffer({ "local x = 1" })
    local id = vim.api.nvim_buf_set_extmark(buf, ns, 0, 11, {
      virt_text = { { " + compute(2)", "Comment" } },
      virt_text_pos = "eol",
      virt_text_win_col = 11,
      virt_lines = { { { "local y = 2", "Comment" } } },
    })

    local ok, err = pcall(ghost.recolor, buf, ns, id)
    h.truthy(ok, ("recolor threw on a win_col mark: %s"):format(err))

    local details = assert(vim.api.nvim_buf_get_extmark_by_id(buf, ns, id, { details = true })[3])
    h.truthy(#details.virt_text > 1, "the suggestion should be split into captures like any other")
    h.eq(details.virt_text_win_col, 11, "and still be placed at the column the provider chose")
  end },

  { "an annotation the provider drew in its own group is left as it was", function()
    -- REGRESSION: the premise is that the suggestion arrives in one flat group, so a chunk in
    -- \           another group is not part of it. copilot hangs a `(1/3)` count off the same
    -- \           extmark in `CopilotAnnotation`; parsed with it, that came out a division.
    h.palette()
    local ns = vim.api.nvim_create_namespace("fade.tests.annotation")
    local buf = h.buffer({ "local x = 1" })
    local id = vim.api.nvim_buf_set_extmark(buf, ns, 0, 11, {
      virt_text = { { " + compute(2)", "Comment" }, { " " }, { "(1/3)", "CopilotAnnotation" } },
      virt_text_pos = "inline",
    })

    ghost.recolor(buf, ns, id)
    local details = assert(vim.api.nvim_buf_get_extmark_by_id(buf, ns, id, { details = true })[3])
    local tail = details.virt_text[#details.virt_text]

    h.eq(tail, { "(1/3)", "CopilotAnnotation" }, "the count keeps its text and the group it had")
    h.truthy(#details.virt_text > 3, "while the suggestion in front of it is still split up")
  end },

  { "a second pass over our own mark leaves it exactly as it was", function()
    -- A provider's draw function is called far more often than it redraws, so `recolor` keeps
    -- meeting its own output. Recognizing that is a fast path, not a correctness one -- what this
    -- case can see is that the passes are harmless: the annotation comes off and goes back once,
    -- however many times the mark is handed over.
    h.palette()
    local ns = vim.api.nvim_create_namespace("fade.tests.idempotent")
    local buf = h.buffer({ "local x = 1" })
    local id = vim.api.nvim_buf_set_extmark(buf, ns, 0, 11, {
      virt_text = { { " + compute(2)", "Comment" }, { " " }, { "(1/3)", "CopilotAnnotation" } },
      virt_text_pos = "inline",
      virt_lines = { { { "local y = 2", "Comment" } } },
    })

    local function rendered()
      local details = assert(vim.api.nvim_buf_get_extmark_by_id(buf, ns, id, { details = true })[3])
      local out = {}
      for _, chunks in ipairs(vim.list_extend({ details.virt_text }, details.virt_lines or {})) do
        out[#out + 1] = table.concat(vim.tbl_map(function(chunk) return chunk[1] end, chunks), "")
      end
      return out
    end

    ghost.recolor(buf, ns, id)
    local once = rendered()
    ghost.recolor(buf, ns, id)
    ghost.recolor(buf, ns, id)

    h.eq(rendered(), once, "and must leave the text exactly as the first one left it")
    h.eq(select(2, once[1]:gsub("%(1/3%)", "")), 1, "with the count appearing once, not once per pass")
  end },

  { "a suggestion redrawn with a new annotation does not keep the old", function()
    -- Cycling copilot's suggestions redraws the same text with a new `(1/2)` each time. The count
    -- is an annotation: taken off before the parse and put back after, so each redraw shows its own
    -- and only its own. The fast path cannot help here -- the provider really did redraw.
    h.palette()
    local ns = vim.api.nvim_create_namespace("fade.tests.redrawn")
    local buf = h.buffer({ "local x = 1" })

    ---Redraw the way a provider cycling its suggestions does: same text, a new count.
    ---@param count string
    ---@return string
    local function redraw(count)
      vim.api.nvim_buf_del_extmark(buf, ns, 1)
      vim.api.nvim_buf_set_extmark(buf, ns, 0, 11, {
        id = 1,
        virt_text = { { " + compute(2)", "Comment" }, { " " }, { count, "CopilotAnnotation" } },
        virt_text_pos = "inline",
      })
      ghost.recolor(buf, ns, 1)
      local details = assert(vim.api.nvim_buf_get_extmark_by_id(buf, ns, 1, { details = true })[3])
      return table.concat(vim.tbl_map(function(chunk) return chunk[1] end, details.virt_text), "")
    end

    h.eq(redraw("(1/2)"), " + compute(2) (1/2)", "the first draw carries the count once")
    h.eq(redraw("(2/2)"), " + compute(2) (2/2)", "the second shows its own count and only that")
    h.eq(redraw("(1/2)"), " + compute(2) (1/2)", "and cycling back does not bring the others along")
  end },

  { "recolor survives a mark the provider had marked for invalidation", function()
    -- REGRESSION: `ns_id` is not the only key the getter hands back that the setter refuses: a
    -- \           mark set with `invalidate` comes back carrying `invalid` once the text under it
    -- \           is deleted. That threw out of `recolor` -- swallowed by the `pcall` in the
    -- \           provider hooks, raised in the caller's face through the public one.
    h.palette()
    local ns = vim.api.nvim_create_namespace("fade.tests.invalidated")
    local buf = h.buffer({ "local x = 1", "local y = 2" })
    local id = vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, {
      end_row = 0, end_col = 11,
      virt_text = { { "compute(1)", "Comment" } },
      virt_text_pos = "inline",
      invalidate = true,
    })

    vim.api.nvim_buf_set_lines(buf, 0, 1, false, {})  -- the text the mark covered goes
    local details = vim.api.nvim_buf_get_extmark_by_id(buf, ns, id, { details = true })[3]
    -- `assert`: a mark that never went invalid would let this pass while testing nothing.
    h.truthy(assert(details).invalid, "the mark has to be invalid for this case to mean anything")

    local ok, err = pcall(ghost.recolor, buf, ns, id)
    h.truthy(ok, ("recolor threw on an invalidated mark: %s"):format(err))
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

  { "the hook listeners retire once nothing is left to wrap", function()
    -- Returning `true` from an autocmd callback deletes it. The test for "done" has to be what the
    -- config asks for, not what got wrapped: a provider turned off never fills `hooked` in, so
    -- waiting on that would leave the listeners firing for the rest of the session.
    local function listeners()
      local n = 0
      for _, autocmd in ipairs(vim.api.nvim_get_autocmds({ group = "fade.ghost" })) do
        if autocmd.event == "InsertEnter" or autocmd.event == "User" then n = n + 1 end
      end
      return n
    end

    configured({ providers = { copilot = false, blink = false } }, function()
      h.eq(listeners(), 2, "both listeners should be installed to begin with")
      vim.api.nvim_exec_autocmds("User", { pattern = "LazyLoad", modeline = false })
      h.eq(listeners(), 1, "with no provider wanted, the announcement listener should retire")
    end)

    configured({ providers = { copilot = true, blink = true } }, function()
      vim.api.nvim_exec_autocmds("User", { pattern = "LazyLoad", modeline = false })
      h.eq(listeners(), 2, "but one that is wanted and not installed must keep it waiting")
      -- The backstop is `once`, so it goes whether or not anything was there to wrap. A provider
      -- arriving later is what `LazyLoad` is for.
      vim.api.nvim_exec_autocmds("InsertEnter", { modeline = false })
      h.eq(listeners(), 1, "and the backstop retires after one insert either way")
    end)
  end },

  { "a suggestion inside a fenced block follows the injected language", function()
    -- The buffer is markdown but the mark sits in a lua block, and `prefix` carries only the text
    -- left of the cursor, so nothing in the parsed string reveals the fence. Reading the filetype
    -- instead of the layer under the mark left the whole suggestion one flat run.
    h.palette()
    local buf = h.buffer({ "```lua", "local x = 1", "```" }, "markdown")
    vim.treesitter.get_parser(buf):parse(true)

    local ns = vim.api.nvim_create_namespace("fade.tests.fenced")
    local id = vim.api.nvim_buf_set_extmark(buf, ns, 1, 11,
      { virt_text = { { " + compute(2)", "Comment" } }, virt_text_pos = "inline" })
    ghost.recolor(buf, ns, id)

    local groups = {}
    local mark = vim.api.nvim_buf_get_extmark_by_id(buf, ns, id, { details = true })
    for _, chunk in ipairs(mark[3].virt_text) do
      if type(chunk[2]) == "table" then groups[chunk[1]] = chunk[2][1] end
    end

    h.eq(groups["compute"], "@function.call.lua", "the block's own language should color it")
    h.eq(groups["("], "@punctuation.bracket.lua", "down to the punctuation, not one flat run")
  end },

  { "a feature that is off wraps nothing", function()
    -- `disable` leaves the wrappers in place, so before one goes in is the only say we get. Stand
    -- in for copilot, since the real one is not installed under test.
    local drawn = 0
    local fake = { update_preview = function() drawn = drawn + 1 end }
    local original = fake.update_preview
    package.loaded["copilot"] = {}
    package.loaded["copilot.suggestion"] = fake

    configured({ enabled = false }, function()
      ghost.hook()
      h.eq(ghost.hooked.copilot, nil, "a provider loading while off must be left alone")
      h.truthy(fake.update_preview == original, "and its draw function left as it was")
    end)

    ghost.hook()
    h.truthy(ghost.hooked.copilot, "switching back on picks the provider up")
    h.truthy(fake.update_preview ~= original, "and wraps it")

    package.loaded["copilot"] = nil
    package.loaded["copilot.suggestion"] = nil
    ghost.hooked.copilot = nil
  end },
}
