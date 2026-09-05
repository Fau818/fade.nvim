---@meta
---Types both features share. Annotation-only: nothing requires this file at runtime.

---Settings both features share, each with its own defaults.
---@class fade.FadeConfig
---@field enabled? boolean
---@field alpha? number Share of the original color kept; the rest fades into `Normal` bg.
---@field min_contrast? number Groups that would fade below this keep their own color.
---@field ignore? string[] Capture groups never faded, whatever the contrast works out to.

---A highlight group per position, keyed `[row][col]`, both 0-based.
---@alias fade.CaptureMap table<integer, table<integer, string>>
