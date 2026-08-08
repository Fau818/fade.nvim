---Shared color core: the faded twin of a highlight group, holding only `fg` so bold and italic
---still come from whatever draws underneath.
local M = {}

---Keyed by fade settings, then source group. `false` marks a source with no `fg` of its own.
---@type table<string, table<string, string|false>>
local cache = {}

---@param int integer
---@return integer r, integer g, integer b
local function channels(int)
  return bit.rshift(int, 16), bit.band(bit.rshift(int, 8), 0xFF), bit.band(int, 0xFF)
end


---Relative luminance, per WCAG: gamma-expanded, so it tracks how light a color looks.
---@param int integer
---@return number
local function luminance(int)
  local function linear(c)
    c = c / 255
    return c <= 0.03928 and c / 12.92 or ((c + 0.055) / 1.055) ^ 2.4
  end
  local r, g, b = channels(int)
  return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
end


---The color faded text falls toward. Transparent Normal reports no `bg`, so 'background' decides.
---@return integer
function M.background()
  local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
  return normal.bg or (vim.o.background == "dark" and 0x000000 or 0xFFFFFF)
end


---Mix `fg` into `bg`, keeping `alpha` of the original.
---@param fg integer
---@param bg integer
---@param alpha number
---@return integer
function M.blend(fg, bg, alpha)
  local fr, fg_, fb = channels(fg)
  local br, bg_, bb = channels(bg)
  local function mix(f, b) return math.floor(f * alpha + b * (1 - alpha) + 0.5) end
  return bit.bor(bit.lshift(mix(fr, br), 16), bit.lshift(mix(fg_, bg_), 8), mix(fb, bb))
end


---How far apart two colors read, as the WCAG contrast ratio: 1 is invisible, 21 is black on white.
---@param a integer
---@param b integer
---@return number
function M.contrast(a, b)
  local la, lb = luminance(a), luminance(b)
  if la < lb then la, lb = lb, la end
  return (la + 0.05) / (lb + 0.05)
end


---Whether `source` is one of `groups` or a child of one: `@comment` covers `@comment.doc.python`.
---@param source string
---@param groups string[]
---@return boolean
function M.ignored(source, groups)
  for _, group in ipairs(groups) do
    if source == group or source:sub(1, #group + 1) == group .. "." then return true end
  end
  return false
end


---Faded twin of a highlight group, created on first use.
---
---Fading is a share of the color, legibility is not: an already-quiet group can fade to nothing at
---an alpha a keyword reads fine at. So a result under `min_contrast` keeps its own color instead --
---skipped, never reversed.
---@param source string
---@param alpha number
---@param min_contrast number? WCAG ratio to keep against the background; 0 fades regardless.
---@return string? group nil when `source` has no `fg` to fade.
function M.faded(source, alpha, min_contrast)
  min_contrast = min_contrast or 0
  -- Names the cache bucket and its groups, so two features fading differently cannot collide.
  local prefix = ("Fade%d_%d"):format(math.floor(alpha * 100), math.floor(min_contrast * 100))

  local by_prefix = cache[prefix]
  if not by_prefix then
    by_prefix = {}
    cache[prefix] = by_prefix
  end

  local cached = by_prefix[source]
  if cached ~= nil then return cached or nil end

  local hl = vim.api.nvim_get_hl(0, { name = source, link = false })
  local group = false ---@type string|false
  if hl.fg then
    local background = M.background()
    local fg = M.blend(hl.fg, background, alpha)
    if M.contrast(fg, background) < min_contrast then fg = hl.fg end

    group = ("%s_%s"):format(prefix, source:gsub("%W", "_"))
    vim.api.nvim_set_hl(0, group, { fg = fg })
  end

  by_prefix[source] = group
  return group or nil
end


---Drop every faded group, so the next lookup rebuilds against the current palette.
function M.clear()
  cache = {}
end


return M
