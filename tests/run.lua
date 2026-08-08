---Test runner. `nvim -l tests/run.lua [spec ...]`, or `make test`. Dependency-free, like the
---plugin. A spec returns an ordered list of `{ name, fn }`; `fn` throws to fail.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(root)
package.path = ("%s/tests/?.lua;%s"):format(root, package.path)

local specs = #_G.arg > 0 and _G.arg or { "hl", "ghost", "unused", "health" }

require("fade").setup()

local GREEN, RED, DIM, RESET = "\27[32m", "\27[31m", "\27[2m", "\27[0m"
local passed, failures = 0, {}

for _, name in ipairs(specs) do
  name = name:gsub("_spec$", "")
  io.write(("\n%s%s%s\n"):format(DIM, name, RESET))

  for _, test in ipairs(require(name .. "_spec")) do
    local label, fn = test[1], test[2]
    local ok, err = pcall(fn)
    if ok then
      passed = passed + 1
      io.write(("  %s✓%s %s\n"):format(GREEN, RESET, label))
    else
      failures[#failures + 1] = ("%s / %s\n    %s"):format(name, label, err)
      local detail = tostring(err):gsub("\n", "\n    ")
      io.write(("  %s✗ %s%s\n    %s\n"):format(RED, label, RESET, detail))
    end
  end
end

io.write(("\n%d passed, %d failed\n"):format(passed, #failures))
os.exit(#failures == 0 and 0 or 1)
