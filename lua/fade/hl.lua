---Color helpers shared by both features. A faded group sets only `fg`, so bold and italic still
---come from whatever draws underneath.
local M = {}

---Faded groups already built, so a repeat lookup neither recomputes the color nor re-registers the
---group. The key is the group's own name, which carries the settings and the source; the value is
---that same name again, or `false` when the source had no `fg` to fade.
---@type table<string, string|false>
local cache = {}


-- ════════════════════════ Color Math ════════════════════════

---Split a color into its red, green and blue bytes.
---@param int integer
---@return integer r, integer g, integer b
local function channels(int)
  return bit.rshift(int, 16), bit.band(bit.rshift(int, 8), 0xFF), bit.band(int, 0xFF)
end


---How much light a color puts out, from 0 for black to 1 for white. Stored RGB values are
---perceptual and cannot meaningfully be added, so the gamma is undone first.
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


---The background that faded text mixes into. A transparent `Normal` has no `bg`, so 'background'
---decides instead.
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
  local fg_r, fg_g, fg_b = channels(fg)
  local bg_r, bg_g, bg_b = channels(bg)
  local function mix(f, b) return math.floor(f * alpha + b * (1 - alpha) + 0.5) end
  return bit.bor(bit.lshift(mix(fg_r, bg_r), 16), bit.lshift(mix(fg_g, bg_g), 8), mix(fg_b, bg_b))
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


-- ═══════════════════════ Faded Groups ═══════════════════════

---Turn a number into a piece of a highlight group name: `0.75` becomes `0_75`, `3.0` becomes `3`.
---@param number number
---@return string
local function tag(number)
  return (("%g"):format(number):gsub("%W", "_"))
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


---Build a highlight group that is `source` mixed toward the background, and return its name. The
---group is created on first use and reused after that.
---
---Fading takes a fixed share of the color, but legibility is not proportional and an already-quiet
---group can go to nothing: a color landing under `min_contrast` keeps its original instead.
---@param source string
---@param alpha number
---@param min_contrast number? WCAG ratio to keep against the background; 0 fades regardless.
---@return string? hl_group nil when `source` has no `fg` to fade.
function M.faded(source, alpha, min_contrast)
  min_contrast = min_contrast or 0
  local group = ("Fade%s_%s_%s"):format(tag(alpha), tag(min_contrast), (source:gsub("%W", "_")))

  local cached = cache[group]
  if cached ~= nil then return cached or nil end

  local hl = vim.api.nvim_get_hl(0, { name = source, link = false })
  -- EXIT: no `fg` of its own to fade. Cached as `false`, since `nil` would read as never looked up.
  if not hl.fg then cache[group] = false; return nil end

  local background = M.background()
  local fg = M.blend(hl.fg, background, alpha)
  if M.contrast(fg, background) < min_contrast then fg = hl.fg end
  vim.api.nvim_set_hl(0, group, { fg = fg })

  cache[group] = group
  return group
end


---Drop every faded group, so the next lookup rebuilds against the current palette.
function M.clear()
  cache = {}
end


return M
