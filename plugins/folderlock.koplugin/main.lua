--[[--
Plugin to password-protect folders via a lock registry.
@module koplugin.FolderLock
--]]
--

local DataStorage = require("datastorage")
local ffiUtil = require("ffi/util")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local LuaSettings = require("luasettings")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")
local logger = require("logger")
local bit = require("bit")

-- Lock registry settings file: DataStorage:getSettingsDir() .. "/folderlock_registry.lua"
-- Loaded into _lock_registry on init for fast in-memory lookups.
local _lock_registry = nil -- initialized in _load_registry()

-- Settings (persistent storage) for folderlock plugins
local _registry_settings = nil -- LuaSettings handle

-- DJB2 hash using LuaJIT's bit module.
-- Returns the hash as a string (to be compared as string).
local function djb2_hash(str)
    local hash = 5381
    for i = 1, #str do
        local byte = str:byte(i)
        hash = bit.bxor(hash * 33 + byte, 0xFFFFFFFF)
    end
    return tostring(hash)
end

local function _save_registry()
    if not _registry_settings then
        return
    end
    _registry_settings:saveSetting("locks", _lock_registry)
    _registry_settings:flush()
end

local function _load_registry()
    _registry_settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/folderlock_registry.lua")
    _lock_registry = _registry_settings:readSetting("locks") or {}
end

local function _set_folder_lock(path, password)
    _lock_registry[path] = djb2_hash(password)
    _save_registry()
end

local function _remove_folder_lock(path)
    _lock_registry[path] = nil
    _save_registry()
end

local function _clear_all_locks()
    _lock_registry = {}
    _save_registry()
end

-- Enumerate all ancestor paths (including the path itself),
-- from deepest to shallowest (root-most).
-- e.g., "/a/b/c" -> { "/a/b/c", "/a/b", "/a", "/" }
local function path_ancestors(path)
    local ancestors = {}
    if not path or path == "" then
        return ancestors
    end
    while path ~= "/" and path ~= "" do
        table.insert(ancestors, path)
        local parent = path:match("^(.*)/[^/]+$")
        if parent == path or not parent then
            break
        end
        path = parent
    end
    if path == "/" or (#ancestors > 0 and ancestors[#ancestors] ~= "/") then
        table.insert(ancestors, "/")
    end
    return ancestors
end

-- Check if a path (or any ancestor) is locked. Returns the locked path or nil.
-- Check run based on number of tree path
local function check_folder_lock(path)
    local ancestors = path_ancestors(path)
    for _, apath in ipairs(ancestors) do
        if _lock_registry ~= nil and _lock_registry[apath] then
            return apath
        end
    end
    return nil
end

local FolderLock = WidgetContainer:extend({
    name = "folderlock",
    is_doc_only = false,
})

function FolderLock:init()
    _load_registry()
    self.ui.menu:registerToMainMenu(self)

    if self.ui.registerPostInitCallback then
        self.ui:registerPostInitCallback(function()
            local fc = self.ui.file_chooser
            if not fc then
                return
            end

            local orig_changeToPath = fc.changeToPath
            fc.changeToPath = function(self_fc, path, focused_path)
                local real_path = ffiUtil.realpath(path)
                if not real_path then
                    return orig_changeToPath(self_fc, path, focused_path)
                end

                local locked_path = check_folder_lock(real_path)
                if not locked_path then
                    return orig_changeToPath(self_fc, path, focused_path)
                end

                -- Show password dialog
                local dialog
                dialog = InputDialog:new({
                    title = _("Folder Lock"),
                    text_type = "password",
                    input_hint = _("Enter password"),
                    buttons = {
                        {
                            {
                                text = _("Cancel"),
                                id = "close",
                                callback = function()
                                    UIManager:close(dialog)
                                    UIManager:show(InfoMessage:new({
                                        text = _("Access Denied"),
                                        timeout = 2,
                                    }))
                                end,
                            },
                            {
                                text = _("Unlock"),
                                is_enter_default = true,
                                callback = function()
                                    local input = dialog:getInputText()
                                    local hash = djb2_hash(input)

                                    if _lock_registry == nil then
                                        return
                                    end

                                    local stored = _lock_registry[locked_path]
                                    if hash == stored then
                                        UIManager:close(dialog)
                                        orig_changeToPath(self_fc, path, focused_path)
                                    else
                                        UIManager:show(InfoMessage:new({
                                            text = _("Incorrect password"),
                                            timeout = 2,
                                        }))
                                        dialog:onClose()

                                        -- Re-show dialog for another attempt
                                        UIManager:show(dialog)
                                        dialog:onShowKeyboard()
                                    end
                                end,
                            },
                        },
                    },
                })
                UIManager:show(dialog)
                dialog:onShowKeyboard()
            end
        end)
    end
end

local function get_current_folder(self)
    if self.ui and self.ui.file_chooser and self.ui.file_chooser.path then
        return self.ui.file_chooser.path
    end
    return nil
end

function FolderLock:addToMainMenu(menu_items)
    menu_items.folder_lock = {
        text = _("Folder Lock"),
        sorting_hint = "more_tools",
        sub_item_table = {
            {
                text = _("Lock current folder"),
                callback = function()
                    local path = get_current_folder(self)
                    if not path then
                        UIManager:show(InfoMessage:new({
                            text = _("No folder selected"),
                            timeout = 2,
                        }))
                        return
                    end

                    -- First password entry dialog
                    local pw_dialog
                    pw_dialog = InputDialog:new({
                        title = _("Lock folder"),
                        description = path,
                        text_type = "password",
                        input_hint = _("Enter password"),
                        buttons = {
                            {
                                {
                                    text = _("Cancel"),
                                    id = "close",
                                    callback = function()
                                        UIManager:close(pw_dialog)
                                    end,
                                },
                                {
                                    text = _("Next"),
                                    is_enter_default = true,
                                    callback = function()
                                        local pw1 = pw_dialog:getInputText()
                                        if pw1 == "" then
                                            UIManager:show(InfoMessage:new({
                                                text = _("Password cannot be empty"),
                                                timeout = 2,
                                            }))
                                            return
                                        end
                                        UIManager:close(pw_dialog)

                                        -- Re-confirm password dialog
                                        local confirm_dialog
                                        confirm_dialog = InputDialog:new({
                                            title = _("Confirm password"),
                                            text_type = "password",
                                            input_hint = _("Re-enter password"),
                                            buttons = {
                                                {
                                                    {
                                                        text = _("Cancel"),
                                                        id = "close",
                                                        callback = function()
                                                            UIManager:close(confirm_dialog)
                                                        end,
                                                    },
                                                    {
                                                        text = _("Lock"),
                                                        is_enter_default = true,
                                                        callback = function()
                                                            local pw2 = confirm_dialog:getInputText()
                                                            if pw1 ~= pw2 then
                                                                UIManager:show(InfoMessage:new({
                                                                    text = _("Passwords do not match"),
                                                                    timeout = 2,
                                                                }))
                                                                UIManager:close(confirm_dialog)
                                                                return
                                                            end
                                                            UIManager:close(confirm_dialog)
                                                            _set_folder_lock(path, pw1)
                                                            UIManager:show(InfoMessage:new({
                                                                text = _("Folder locked"),
                                                                timeout = 2,
                                                            }))
                                                        end,
                                                    },
                                                },
                                            },
                                        })
                                        UIManager:show(confirm_dialog)
                                        confirm_dialog:onShowKeyboard()
                                    end,
                                },
                            },
                        },
                    })
                    UIManager:show(pw_dialog)
                    pw_dialog:onShowKeyboard()
                end,
            },
            {
                text = _("Unlock current folder"),
                callback = function()
                    local path = get_current_folder(self)
                    if not path then
                        UIManager:show(InfoMessage:new({
                            text = _("No folder selected"),
                            timeout = 2,
                        }))
                        return
                    end

                    local locked_path = check_folder_lock(path)
                    if not locked_path then
                        UIManager:show(InfoMessage:new({
                            text = _("Folder is not locked"),
                            timeout = 2,
                        }))
                        return
                    end

                    local unlock_dialog
                    unlock_dialog = InputDialog:new({
                        title = _("Unlock folder"),
                        description = locked_path,
                        text_type = "password",
                        input_hint = _("Enter current password"),
                        buttons = {
                            {
                                {
                                    text = _("Cancel"),
                                    id = "close",
                                    callback = function()
                                        UIManager:close(unlock_dialog)
                                    end,
                                },
                                {
                                    text = _("Unlock"),
                                    is_enter_default = true,
                                    callback = function()
                                        local input = unlock_dialog:getInputText()
                                        local hash = djb2_hash(input)
                                        local stored = _lock_registry and _lock_registry[locked_path]
                                        if hash ~= stored then
                                            UIManager:show(InfoMessage:new({
                                                text = _("Incorrect password"),
                                                timeout = 2,
                                            }))
                                            return
                                        end
                                        UIManager:close(unlock_dialog)
                                        _remove_folder_lock(locked_path)
                                        UIManager:show(InfoMessage:new({
                                            text = _("Folder unlocked"),
                                            timeout = 2,
                                        }))
                                    end,
                                },
                            },
                        },
                    })
                    UIManager:show(unlock_dialog)
                    unlock_dialog:onShowKeyboard()
                end,
            },
            {
                text = _("Remove all locks"),
                callback = function()
                    UIManager:show(require("ui/widget/confirmbox"):new({
                        text = _("Remove all folder locks?"),
                        ok_text = _("Remove all"),
                        ok_callback = function()
                            _clear_all_locks()
                            UIManager:show(InfoMessage:new({
                                text = _("All locks removed"),
                                timeout = 2,
                            }))
                        end,
                    }))
                end,
            },
        },
    }
end

return FolderLock
