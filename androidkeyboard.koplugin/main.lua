--[[--
Android native keyboard: uses the system IME (predictions, swipe typing,
stylus/handwriting keyboards...) for KOReader text fields.

A tiny helper (kbhelper.dex, source in ../java) is loaded at runtime over JNI.
It owns a hidden EditText, which gives the IME a real InputConnection. While a
KOReader InputText is active, we poll the helper (~12x/s) and mirror text and
cursor both ways. KOReader's own VirtualKeyboard is replaced by a zero-size stub.
--]]--

local Device = require("device")
if not Device:isAndroid() then
    return { disabled = true }
end

local Geom = require("ui/geometry")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")

local Bridge = require("kbbridge")

local SETTING = "android_native_keyboard_enabled"
local POLL_INTERVAL = 0.08

-- android.text.InputType / EditorInfo constants
local TYPE_CLASS_NUMBER = 0x2
local TYPE_CLASS_TEXT = 0x1
local TYPE_TEXT_FLAG_MULTI_LINE = 0x20000
local TYPE_TEXT_VARIATION_PASSWORD = 0x80
local IME_ACTION_DONE = 0x6
local IME_ACTION_NONE = 0x1

local ime_height = 0 -- last measured IME height; new keyboard stubs start with it
local session -- { ib = InputText, text = string, pos = number }

local function plugin_dir()
    local src = debug.getinfo(1, "S").source:gsub("^@", "")
    return src:match("^(.*)/[^/]*$") or "."
end

local function endSession()
    session = nil
    Bridge:hide()
end

local function apply(ib, text, cursor)
    ib.charlist = util.splitToChars(text)
    ib.charpos = cursor + 1
    ib.undo_charlist = nil
    ib.is_text_edited = true
    ib:initTextBox(nil, true)
end

local function tick()
    local s = session
    if not s then return end
    local ib = s.ib
    local cur, flags, text = Bridge:poll()
    if cur then
        if text ~= table.concat(ib.charlist) or cur + 1 ~= ib.charpos then
            apply(ib, text, cur)
        end
        s.text, s.pos = text, cur
        if flags % 2 >= 1 and ib.enter_callback then
            ib.enter_callback()
        end
        if flags >= 2 and ib.keyboard then
            ib.keyboard.visible = false -- IME dismissed (e.g. Back); tapping the field shows it again
        end
    else
        local lt, lp = table.concat(ib.charlist), ib.charpos - 1
        if lt ~= s.text or lp ~= s.pos then
            Bridge:push(lt, lp)
            s.text, s.pos = lt, lp
        end
    end
    local kb = ib.keyboard
    if kb and kb.visible then
        local h = Bridge:imeHeight()
        if h > 0 and h ~= ime_height then
            ime_height = h
            if kb.dimen.h ~= h then
                kb.dimen.h = h
                -- Let the dialog re-layout so the field isn't drawn under the IME.
                if ib.parent and ib.parent.onKeyboardHeightChanged then
                    UIManager:nextTick(function() ib.parent:onKeyboardHeightChanged() end)
                end
            end
        end
    end
    if session == s then
        UIManager:scheduleIn(POLL_INTERVAL, tick)
    end
end

local function startSession(ib)
    local text, cursor = table.concat(ib.charlist or {}), (ib.charpos or 1) - 1
    local input_type, ime, single
    single = ib.enter_callback ~= nil
    if ib.input_type == "number" then
        input_type = TYPE_CLASS_NUMBER
    elseif ib.text_type == "password" then
        input_type = TYPE_CLASS_TEXT + TYPE_TEXT_VARIATION_PASSWORD
    else
        input_type = TYPE_CLASS_TEXT + (single and 0 or TYPE_TEXT_FLAG_MULTI_LINE)
    end
    ime = single and IME_ACTION_DONE or IME_ACTION_NONE
    if session and session.ib == ib then
        Bridge:reshow() -- same field: keep the existing EditText (and its state)
        return
    end
    session = { ib = ib, text = text, pos = cursor }
    Bridge:show(text, cursor, input_type, ime, single)
    -- (Re)start polling; a previous session's timer may have been cancelled or still be pending.
    UIManager:unschedule(tick)
    UIManager:scheduleIn(POLL_INTERVAL, tick)
end

-- Drop-in replacement for VirtualKeyboard, as far as InputText/InputDialog care.
local NativeKeyboard = {}
NativeKeyboard.__index = NativeKeyboard

function NativeKeyboard:new(o)
    o = o or {}
    o.dimen = Geom:new{ w = Device.screen:getWidth(), h = ime_height }
    o.visible = false
    o.locked = false
    return setmetatable(o, self)
end
function NativeKeyboard:showKeyboard()
    self.visible = true
    startSession(self.inputbox)
end
-- End the session on the next tick, unless a new keyboard took over meanwhile
-- (InputDialog:reinit closes and re-opens the keyboard; this avoids an IME flicker).
function NativeKeyboard:_endSoon()
    local ib = self.inputbox
    UIManager:nextTick(function()
        if session and session.ib == ib and not (ib.keyboard and ib.keyboard.visible) then
            UIManager:unschedule(tick)
            endSession()
        end
    end)
end
function NativeKeyboard:hideKeyboard()
    if self.locked then return end
    self.visible = false
    self:_endSoon()
end
function NativeKeyboard:isVisible() return self.visible end
function NativeKeyboard:lockVisibility(toggle)
    if toggle ~= nil then self.locked = toggle end
    return self.locked
end
function NativeKeyboard:free()
    self.visible = false
    self:_endSoon()
end

local AndroidKeyboard = WidgetContainer:extend{ name = "androidkeyboard", is_doc_only = false }

local patched, orig = false, {}

function AndroidKeyboard:enable()
    if patched then return true end
    if not Bridge:load(plugin_dir() .. "/kbhelper.dex") then
        logger.err("androidkeyboard: could not load kbhelper.dex; keeping KOReader's keyboard")
        local InfoMessage = require("ui/widget/infomessage")
        UIManager:show(InfoMessage:new{ text = _("Android native keyboard: could not load the helper. Using KOReader's keyboard.") })
        return false
    end
    local InputText = require("ui/widget/inputtext")
    orig.initKeyboard = InputText.initKeyboard
    orig.startTextInput = Device.startTextInput
    orig.stopTextInput = Device.stopTextInput
    function InputText:initKeyboard()
        self.key_events = {}
        self.keyboard = NativeKeyboard:new{ inputbox = self }
    end
    -- The session is driven by the keyboard stub; the generic hooks must not touch the IME.
    Device.startTextInput = function() end
    Device.stopTextInput = function() end
    patched = true
    return true
end

function AndroidKeyboard:disable()
    if not patched then return end
    local InputText = require("ui/widget/inputtext")
    InputText.initKeyboard = orig.initKeyboard
    Device.startTextInput = orig.startTextInput
    Device.stopTextInput = orig.stopTextInput
    UIManager:unschedule(tick)
    if session then endSession() end
    patched = false
end

function AndroidKeyboard:isEnabled()
    return G_reader_settings:nilOrTrue(SETTING)
end

function AndroidKeyboard:init()
    if self:isEnabled() then self:enable() end
    self.ui.menu:registerToMainMenu(self)
end

function AndroidKeyboard:addToMainMenu(menu_items)
    menu_items.android_native_keyboard = {
        text = _("Android native keyboard"),
        sorting_hint = "setting",
        checked_func = function() return self:isEnabled() end,
        callback = function()
            local on = not self:isEnabled()
            if on and not self:enable() then return end
            G_reader_settings:saveSetting(SETTING, on)
            if not on then self:disable() end
            -- Already-open dialogs keep their old keyboard; new ones use the new setting.
        end,
    }
end

return AndroidKeyboard
