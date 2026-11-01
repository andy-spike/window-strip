-- Optional Hyprland companion for Window Strip (Hyprland 0.56+ Lua config).
-- Load it from ~/.config/hypr/hyprland.lua, for example:
--   dofile(os.getenv("HOME") .. "/.config/omarchy/plugins/io.github.andy-spike.window-strip/extras/activation-focus.lua")

-- Bring activated windows into view. When an app asks to be activated (a link
-- opening in the browser on another workspace), Hyprland switches workspace and
-- focuses the window, but the scrolling layout can leave its column off-screen,
-- and the cursor warp can hand focus back to the window still in view. An
-- explicit focus scrolls the column in.
--
-- Eligibility is decided when Hyprland actually focuses the activated window,
-- so the correction still runs if the cursor warp takes focus away again before
-- it fires. Windows that are never given focus (focus_on_activate = false,
-- plain urgency hints) leave no correction behind: the pending request expires.
local activation_pending = nil

hl.on("window.urgent", function(window)
  local address = window and window.address
  if not address then return end
  activation_pending = address
  hl.timer(function()
    if activation_pending == address then activation_pending = nil end
  end, { timeout = 1000, type = "oneshot" })
end)

hl.on("window.active", function(window)
  local address = window and window.address
  if not address or address ~= activation_pending then return end
  activation_pending = nil
  hl.timer(function()
    hl.dispatch(hl.dsp.focus({ window = "address:" .. address }))
  end, { timeout = 50, type = "oneshot" })
end)
