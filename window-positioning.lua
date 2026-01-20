-- window-positioning.lua
-- mpv Lua script that restores window position and size on startup using Windows API.

local options = require("mp.options")
local ok, ffi = pcall(require, "ffi")
if ok then ok, shcore = pcall(ffi.load, "shcore") end
if not ok then return end

local o = {
    restore_window_position = true, -- Enable or disable window restoration entirely
    restore_window_size = true,     -- Restore window size on startup (optional)
    clamp_bottom = true             -- Prevent window from extending below the monitor work area
}
options.read_options(o)

ffi.cdef[[
    typedef void*           HWND;
    typedef int             BOOL;
    typedef unsigned int    UINT;
    typedef unsigned long   DWORD;
    typedef long            LONG;
    typedef long            HRESULT;
    typedef void*           HMONITOR;

    typedef struct { LONG left, top, right, bottom; } RECT;
    typedef struct { LONG x, y; } POINT;

    typedef struct {
        UINT length, flags, showCmd;
        POINT ptMinPosition, ptMaxPosition;
        RECT rcNormalPosition, rcDevice;
    } WINDOWPLACEMENT;

    typedef struct {
        unsigned int cbSize;
        RECT rcMonitor;
        RECT rcWork;
        unsigned int dwFlags;
    } MONITORINFO;

    BOOL     GetWindowPlacement(HWND hwnd, WINDOWPLACEMENT* lpwndpl);
    BOOL     GetWindowRect(HWND hwnd, RECT* rect);
    BOOL     SetWindowPos(HWND hWnd, HWND hWndInsertAfter, int X, int Y, int cx, int cy, UINT uFlags);
    BOOL     SetWindowPlacement(HWND hWnd, const WINDOWPLACEMENT* lpwndpl);
    HMONITOR MonitorFromPoint(POINT pt, DWORD dwFlags);
    HWND     GetConsoleWindow(void);
    HRESULT  GetDpiForMonitor(HMONITOR hMonitor, UINT dpiType, UINT* dpiX, UINT* dpiY);
    UINT     GetDpiForWindow(HWND hwnd);
    int      GetSystemMetricsForDpi(int nIndex, UINT dpi);
    int      GetMonitorInfoW(void* hMonitor, MONITORINFO* lpmi);
]]

local MONITOR_DEFAULTTONEAREST = 2              -- Ensures MonitorFromPoint returns nearest monitor if point offscreen
local MDT_EFFECTIVE_DPI = 0                     -- Gets the DPI Windows actually uses to scale UI on a monitor
local SM_CXPADDEDBORDER = 92                    -- The amount of border padding for captioned windows
local SM_CYCAPTION      = 4                     -- The height of a caption area, in pixels
local SM_CXBORDER       = 5                     -- Standard window border width (1px)
local SM_CXFRAME        = 32                    -- Width of the resize frame
local SWP_NOSIZE        = 0x0001                -- Retains the current size (ignores the cx and cy parameters)
local SWP_NOZORDER      = 0x0004                -- Retains the current Z order (ignores the hwndInsertAfter).
local SWP_SHOWWINDOW    = 0x0040                -- Show the window if hidden
local HWND_TOP          = ffi.cast("HWND", 0)   -- Place the window at the top of the Z-order (ignored by SWP_NOZORDER)

local windowpos_path = mp.command_native({'expand-path', '~~/windowpos'})

local function get_full_window_size(hwnd)
    local rect = ffi.new("RECT")
    ffi.C.GetWindowRect(hwnd, rect)
    return {
        x = rect.left,
        y = rect.top,
        width  = rect.right - rect.left,
        height = rect.bottom - rect.top
    }
end

local function get_target_monitor_dpi(x, y)
    local point    = ffi.new("POINT", {x = x, y = y})
    local hMonitor = ffi.C.MonitorFromPoint(point, MONITOR_DEFAULTTONEAREST)
    if hMonitor then
        local dpiX = ffi.new("UINT[1]")
        local dpiY = ffi.new("UINT[1]")
        if shcore.GetDpiForMonitor(hMonitor, MDT_EFFECTIVE_DPI, dpiX, dpiY) == 0 then
            return dpiX[0]
        end
    end
    return nil
end

local function get_monitor_workarea(x, y)
    local point    = ffi.new("POINT", {x = x, y = y})
    local hMonitor = ffi.C.MonitorFromPoint(point, MONITOR_DEFAULTTONEAREST)
    if hMonitor then
        local mi  = ffi.new("MONITORINFO")
        mi.cbSize = ffi.sizeof(mi)
        if ffi.C.GetMonitorInfoW(hMonitor, mi) ~= 0 then
            return {
                left   = mi.rcWork.left,
                top    = mi.rcWork.top,
                right  = mi.rcWork.right,
                bottom = mi.rcWork.bottom,
            }
        end
    end
    return nil
end

local function get_window_border(dpi)
    local winBorder = {
        resizableFrameWidth = ffi.C.GetSystemMetricsForDpi(SM_CXFRAME, dpi),
        rawBorderPadding    = ffi.C.GetSystemMetricsForDpi(SM_CXPADDEDBORDER, dpi),
        thinBorderWidth     = ffi.C.GetSystemMetricsForDpi(SM_CXBORDER, dpi),
        titlebarHeight      = ffi.C.GetSystemMetricsForDpi(SM_CYCAPTION, dpi)
    }
    winBorder.borderPadding = winBorder.resizableFrameWidth + winBorder.rawBorderPadding
    return winBorder
end

local function get_window_state(hwnd)
    local current_dpi = ffi.C.GetDpiForWindow(hwnd)
    local borders     = get_window_border(current_dpi)
    return {
        current_dpi   = current_dpi,
        border_pad    = borders.borderPadding,
        title_height  = borders.titlebarHeight,
        has_border    = mp.get_property_native("border"),
        is_fullscreen = mp.get_property_native("fullscreen"),
        is_maximized  = mp.get_property_native("window-maximized"),
        is_minimized  = mp.get_property_native("window-minimized")
    }
end

local function border_offset(src, has_border)
    if not (has_border or src.has_border) then
        return 0, 0
    end
    local pad   = src.border_pad   or src.borderPadding  or 0
    local title = src.title_height or src.titlebarHeight or 0
    return pad, pad + title
end

local function scale_round(v, ratio)
    return math.floor(v * ratio + 0.5)
end

local function get_window_center(hwnd, client_x, client_y, state)
    local x_offset, y_offset = border_offset(state)
    local rect     = get_full_window_size(hwnd)
    local frame_x  = client_x - x_offset
    local frame_y  = client_y - y_offset
    local center_x = math.floor(frame_x + rect.width/2 + 0.5)
    local center_y = math.floor(frame_y + rect.height/2 + 0.5)
    return center_x, center_y, rect.width, rect.height
end

local function clamp_window_to_workarea(x, y, w, h, state, border)
    local wa = get_monitor_workarea(x + w/2, y + h/2)
    if wa then
        local y_offset = state.has_border and border.borderPadding or 0
        local client_bottom = y + h - y_offset
        if y < wa.top then
            y = wa.top
        elseif o.clamp_bottom and client_bottom > wa.bottom then
            y = wa.bottom - h + y_offset
        end
    end
    return x, y
end

local function apply_restore_rect(x, y, w, h, state, border, target_dpi, dpi_changed)
    local wp = ffi.new("WINDOWPLACEMENT")
    ffi.fill(wp, ffi.sizeof(wp))
    wp.length = ffi.sizeof(wp)
    if ffi.C.GetWindowPlacement(mpv_hwnd, wp) ~= 0 then
        local r = wp.rcNormalPosition
        local width  = (o.restore_window_size and not dpi_changed and w) or (r.right  - r.left)
        local height = (o.restore_window_size and not dpi_changed and h) or (r.bottom - r.top)
        if dpi_changed then
            local dpi_ratio = state.current_dpi / target_dpi
            width, height   = scale_round(width, dpi_ratio), scale_round(height, dpi_ratio)
        end
        local adj_x, adj_y = clamp_window_to_workarea(x, y, width, height, state, border)
        r.left   = adj_x
        r.top    = adj_y
        r.right  = adj_x + width
        r.bottom = adj_y + height
        ffi.C.SetWindowPlacement(mpv_hwnd, wp)
    end
end

local function rect_to_normalized_client(w_full, h_full, state)
    local dpi_ratio = opening_dpi / state.current_dpi
    local client_w  = w_full - (state.has_border and (state.border_pad * 2) or 0)
    local client_h  = h_full - (state.has_border and (state.border_pad * 2 + state.title_height) or 0)
    return scale_round(client_w, dpi_ratio), scale_round(client_h, dpi_ratio)
end

local function normalized_client_to_rect(norm_w, norm_h, state, border, target_dpi)
    local dpi_ratio = target_dpi / opening_dpi
    local client_w  = scale_round(norm_w, dpi_ratio)
    local client_h  = scale_round(norm_h, dpi_ratio)
    local win_w = client_w + (state.has_border and (border.borderPadding * 2) or 0)
    local win_h = client_h + (state.has_border and (border.borderPadding * 2 + border.titlebarHeight) or 0)
    return win_w, win_h
end

local function get_window_geometry(hwnd)
    local rect  = get_full_window_size(hwnd)
    local state = get_window_state(hwnd)
    local valid = not (state.is_fullscreen or state.is_maximized or state.is_minimized)

    local win_x, win_y
    if valid then
        local x_offset, y_offset = border_offset(state)
        win_x = rect.x + x_offset
        win_y = rect.y + y_offset
    else
        win_x, win_y = last_valid_x, last_valid_y
    end

    local width, height
    if o.restore_window_size and valid then
        width, height = rect_to_normalized_client(rect.width, rect.height, state)
    elseif o.restore_window_size then
        width, height = last_valid_w, last_valid_h
    end

    return win_x, win_y, width, height
end

local function cache_geometry(name, value)
    if not mpv_hwnd then return end
    local state = get_window_state(mpv_hwnd)
    local is_minmax = name == "window-minimized" or name == "window-maximized"
    local is_osd    = name == "osd-width" or name == "osd-height"
    local is_full   = name == "fullscreen"

    if (is_minmax and state.is_fullscreen) or
       (is_osd    and state.is_fullscreen) or
       (is_full   and state.is_maximized)  then return end

    if defer_minmax and is_minmax and not (value or left_minmax) then
        left_minmax = true
    end

    local wp = ffi.new("WINDOWPLACEMENT")
    ffi.fill(wp, ffi.sizeof(wp))
    wp.length = ffi.sizeof(wp)
    ffi.C.GetWindowPlacement(mpv_hwnd, wp)

    -- X/Y position
    local x_offset, y_offset = border_offset(state)
    local pos = wp.rcNormalPosition
    local x = pos.left + x_offset
    local y = pos.top  + y_offset
    -- Fullscreen position
    if is_full and value then
        x, y = saved_bounds.x, saved_bounds.y
    end

    local width, height
    local osd_w, osd_h = mp.get_osd_size()
    local valid = not (state.is_fullscreen or state.is_maximized or state.is_minimized)

    -- Width/height
    if o.restore_window_size then
        if is_minmax and value then
            local win_w = pos.right  - pos.left
            local win_h = pos.bottom - pos.top
            width, height = rect_to_normalized_client(win_w, win_h, state)

        elseif (is_full or (is_osd and valid)) and osd_w > 0 and osd_h > 0 then
            local dpi_ratio = opening_dpi / state.current_dpi
            width  = scale_round(osd_w, dpi_ratio)
            height = scale_round(osd_h, dpi_ratio)
        end
    end

    last_valid_x, last_valid_y = x, y
    if width and height then
        last_valid_w, last_valid_h = width, height
    end
end

local function debounced_window_resize(name, value)
    if debounce_timer then debounce_timer:kill() debounce_timer = nil end
    debounce_timer = mp.add_timeout(0.1, function()
        cache_geometry(name, value)
    end)
end

local function move_window(hwnd, x, y, w, h)
    local state = get_window_state(hwnd)
    local center_x, center_y, cur_w, cur_h = get_window_center(hwnd, x, y, state)
    local target_dpi  = get_target_monitor_dpi(center_x, center_y)
    local dpi_changed = (target_dpi ~= state.current_dpi)
    local border  = get_window_border(target_dpi)
    local restore = o.restore_window_size and w and h and not dpi_changed

    local win_w, win_h
    if restore then
        win_w, win_h = normalized_client_to_rect(w, h, state, border, target_dpi)
    else
        local dpi_ratio = target_dpi / state.current_dpi
        win_w, win_h = scale_round(cur_w, dpi_ratio), scale_round(cur_h, dpi_ratio)
    end

    local x_offset, y_offset = border_offset(border, state.has_border)
    local adj_x, adj_y = x - x_offset, y - y_offset

    -- Handle restore when mpv starts minimized/maximized/fullscreen
    if defer_restore then
        if not state.is_fullscreen then
            local t = defer_restore == "--fullscreen" and (console and 0.05 or 0.02) or 0.2
            mp.add_timeout(t, function()
                apply_restore_rect(
                    adj_x, adj_y,
                    win_w, win_h,
                    state, border,
                    target_dpi, dpi_changed
                )
                defer_restore = false
            end)
        end
        return "deferred"
    end
    adj_x, adj_y = clamp_window_to_workarea(
        adj_x, adj_y,
        win_w, win_h,
        state, border
    )
    local flags = bit.bor(SWP_NOZORDER, SWP_SHOWWINDOW)
    if dpi_changed or not restore then
        flags = bit.bor(flags, SWP_NOSIZE)
    end
    return ffi.C.SetWindowPos(hwnd, HWND_TOP, adj_x, adj_y, win_w, win_h, flags) ~= 0
end

local function save_geometry()
    if not mpv_hwnd then
        return mp.msg.error("mpv window not found.")
    end
    local x, y, w, h = get_window_geometry(mpv_hwnd)
    if math.abs(x) > 30000 or math.abs(y) > 30000 then return end
    -- In case if launched in min/max/fs, but closed before restoring.
    local use_saved = (sx and sy) and (defer_restore or (defer_minmax and not left_minmax))
    if use_saved then
        x, y, w, h = sx, sy, sw, sh
    end
    local file = io.open(windowpos_path, "w+")
    if not file then
        return mp.msg.error("Failed to save geometry.")
    end
    file:write(x, "\n", y, "\n")
    if o.restore_window_size and h and h >= 10 then
        file:write(w, "x", h)
    end
    file:close()
end

local function window_ready_check(_, value)
    if not value then return end
    if current_wid ~= value then
        current_wid = value
        mpv_hwnd = ffi.cast("HWND", value)
    end
    if mpv_hwnd then
        opening_dpi = ffi.C.GetDpiForWindow(mpv_hwnd)
        console = ffi.C.GetConsoleWindow() ~= nil
        if sx and sy and not skip_restore then
            if not (defer_restore or moved) then
                mp.set_property("geometry", "")
            end
            if not moved then
                moved = move_window(mpv_hwnd, sx, sy, sw, sh)
            end
            return
        end
    end
    if not skip_restore and not defer_restore then
        mp.set_property("geometry", "50%:50%")
        mp.msg.warn("Could not restore position.")
    end
end

local function initialize()
    if not o.restore_window_position then return end
    if not skip_restore then
        local file = io.open(windowpos_path, "r")
        if file then
            sx = tonumber(file:read("*l"))
            sy = tonumber(file:read("*l"))
            if o.restore_window_size then
                local size = file:read("*l")
                if size then
                    local w, h = size:match("^(%d+)x(%d+)$")
                    sw, sh = tonumber(w), tonumber(h)
                end
            end
            file:close()
            if sx and sy and not defer_restore then
                -- Set offscreen geometry to prevent startup centering
                -- and reduce flicker before window-id is ready.
                mp.set_property("geometry", "+-32000+32000")
            end
        end
    end
    mp.observe_property("window-id", "number", window_ready_check)
    mp.observe_property("window-maximized", "bool", cache_geometry)
    mp.observe_property("window-minimized", "bool", cache_geometry)
    if o.restore_window_size then
        mp.set_property("auto-window-resize", "no")
        mp.observe_property("osd-width",  "number", debounced_window_resize)
        mp.observe_property("osd-height", "number", debounced_window_resize)
    end
    mp.register_event("shutdown", save_geometry)

    -- Very hacky way of getting reliable window position before mpv enters fullscreen.
    -- rcNormalPosition returns fullscreen dimensions on the very first fullscreen toggle,
    -- so observing fullscreen isn’t enough to get the correct windowed geometry.
    -- The required data is available in verbose messages, but it can’t be accessed in any sane way.
    mp.enable_messages("v")
    mp.register_event("log-message", function(event)
        if event.prefix:match("^vo/.+/win32$") and event.text then
            local x, y, w, h = event.text:match("save window bounds:%s*(-?%d+):(-?%d+):(%d+):(%d+)")
            if x and y and w and h then
                saved_bounds = {
                    x = tonumber(x), y = tonumber(y),
                    w = tonumber(w), h = tonumber(h)
                }
                cache_geometry("fullscreen", mp.get_property_native("fullscreen"))
            end
        end
    end)
    -- Wait for fullscreen exit before setting 'SetWindowPlacement' to avoid broken window state.
    if defer_restore == "--fullscreen" then
        local function fullscreen_exit(_, value)
            if defer_restore and suppress_init and not value then
                move_window(mpv_hwnd, sx, sy, sw, sh)
                mp.unobserve_property(fullscreen_exit)
            end
            suppress_init = true
        end
        mp.observe_property("fullscreen", "bool", fullscreen_exit)
    end
end

local r = mp.get_property_native("screen") ~= "default" and "--screen"
       or mp.get_property_native("geometry") ~= ""      and "--geometry"
       or mp.get_property_native("fullscreen")          and "--fullscreen"
       or mp.get_property_native("window-maximized")    and "--window-maximized"
       or mp.get_property_native("window-minimized")    and "--window-minimized"

if r then
    if r == "--screen" or r == "--geometry" then
        skip_restore = true
        mp.msg.warn("mpv launched with " .. r .. ", skipping restore.")
    else
        defer_minmax  = r == "--window-maximized" or r == "--window-minimized"
        defer_restore = r
    end
end

initialize()
