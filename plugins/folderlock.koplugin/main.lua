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

local _orig_FileChooser_changeToPath = nil
local _filechooser_patch_installed = false

local function table_count(t)
    local count = 0
    for _ in pairs(t or {}) do
        count = count + 1
    end
    return count
end

local function normalize_path(path)
    if not path or path == "" then
        return nil
    end
    return ffiUtil.realpath(path) or path
end

local function _save_registry()
    if not _registry_settings then
        logger.dbg("folderlock: _save_registry skipped (no settings handle)")
        return
    end
    _registry_settings:saveSetting("locks", _lock_registry)
    _registry_settings:flush()
    logger.dbg("folderlock: registry saved, entries =", table_count(_lock_registry))
end

local function _load_registry()
    _registry_settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/folderlock_registry.lua")
    _lock_registry = _registry_settings:readSetting("locks") or {}
    logger.dbg("folderlock: registry loaded, entries =", table_count(_lock_registry))
end

local function _set_folder_lock(path, password)
    local normalized = normalize_path(path)
    if not normalized then
        logger.dbg("folderlock: cannot set lock, invalid path =", path)
        return false
    end
    _lock_registry[normalized] = djb2_hash(password)
    _save_registry()
    logger.dbg("folderlock: lock set for", normalized)
    return true
end

local function _remove_folder_lock(path)
    local normalized = normalize_path(path)
    if not normalized then
        logger.dbg("folderlock: cannot remove lock, invalid path =", path)
        return false
    end
    _lock_registry[normalized] = nil
    _save_registry()
    logger.dbg("folderlock: lock removed for", normalized)
    return true
end

local function _clear_all_locks()
    _lock_registry = {}
    _save_registry()
    logger.dbg("folderlock: all locks cleared")
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
local function check_folder_lock(path)
    if _lock_registry == nil then
        logger.dbg("folderlock: check skipped (registry is nil)")
        return nil
    end

    local normalized = normalize_path(path)
    if not normalized then
        logger.dbg("folderlock: check skipped (invalid path)", path)
        return nil
    end

    local ancestors = path_ancestors(normalized)
    logger.dbg("folderlock: checking path", normalized, "ancestors =", table.concat(ancestors, " -> "))

    for _, apath in ipairs(ancestors) do
        if _lock_registry[apath] then
            logger.dbg("folderlock: lock match found at", apath)
            return apath
        end
    end

    return nil
end

local function ensure_filechooser_patch()
    if _filechooser_patch_installed then
        logger.dbg("folderlock: FileChooser.changeToPath patch already installed")
        return
    end

    local FileChooser = require("ui/widget/filechooser")
    if type(FileChooser.changeToPath) ~= "function" then
        logger.err("folderlock: cannot patch FileChooser.changeToPath (not a function)")
        return
    end

    _orig_FileChooser_changeToPath = FileChooser.changeToPath

    FileChooser.changeToPath = function(self_fc, path, focused_path)
        local chooser_name = self_fc and self_fc.name or "nil"
        logger.dbg("folderlock: changeToPath hook", "chooser=", chooser_name, "path=", path, "focused=", focused_path)

        -- Only guard FileManager navigation.
        if chooser_name ~= "filemanager" then
            logger.dbg("folderlock: bypass hook (non-filemanager chooser)")
            return _orig_FileChooser_changeToPath(self_fc, path, focused_path)
        end

        local real_path = normalize_path(path)
        if not real_path then
            logger.dbg("folderlock: bypass hook (realpath failed)", path)
            return _orig_FileChooser_changeToPath(self_fc, path, focused_path)
        end

        local locked_path = check_folder_lock(real_path)
        if not locked_path then
            logger.dbg("folderlock: allow navigation (unlocked)", real_path)
            return _orig_FileChooser_changeToPath(self_fc, path, focused_path)
        end

        logger.dbg("folderlock: LOCK HIT", "target=", real_path, "locked_by=", locked_path)

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
                            logger.dbg("folderlock: unlock canceled for", locked_path)
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
                                logger.dbg("folderlock: registry unavailable at unlock time")
                                return
                            end

                            local stored = _lock_registry[locked_path]
                            if not stored then
                                logger.dbg("folderlock: lock disappeared, allowing navigation to", real_path)
                                UIManager:close(dialog)
                                return _orig_FileChooser_changeToPath(self_fc, path, focused_path)
                            end

                            if hash == stored then
                                logger.dbg("folderlock: unlock success for", locked_path)
                                UIManager:close(dialog)
                                return _orig_FileChooser_changeToPath(self_fc, path, focused_path)
                            end

                            logger.dbg("folderlock: unlock failed for", locked_path)
                            UIManager:show(InfoMessage:new({
                                text = _("Incorrect password"),
                                timeout = 2,
                            }))
                            dialog:onClose()
                            UIManager:show(dialog)
                            dialog:onShowKeyboard()
                        end,
                    },
                },
            },
        })

        UIManager:show(dialog)
        dialog:onShowKeyboard()
    end

    _filechooser_patch_installed = true
    logger.dbg("folderlock: installed FileChooser.changeToPath class patch")
end

local FolderLock = WidgetContainer:extend({
    name = "folderlock",
    is_doc_only = false,
})

function FolderLock:init()
    _load_registry()

    local ui_name = self.ui and self.ui.name or "nil"
    logger.dbg("folderlock: init for ui", ui_name)

    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
        logger.dbg("folderlock: registered to main menu for", ui_name)
    else
        logger.dbg("folderlock: menu unavailable for", ui_name)
    end

    -- Install one class-level patch for all FileChooser instances.
    ensure_filechooser_patch()

    -- Keep post-init logs so we can verify whether we're in ReaderUI or FileManager.
    if self.ui and self.ui.registerPostInitCallback then
        self.ui:registerPostInitCallback(function()
            local fc = self.ui and self.ui.file_chooser
            logger.dbg("folderlock: postInit", "ui=", ui_name, "file_chooser=", fc and fc.name or "nil", "path=", fc and fc.path or "nil")
        end)
    end
end

local function get_current_folder(self)
    local path = self.ui and self.ui.file_chooser and self.ui.file_chooser.path or nil
    logger.dbg("folderlock: get_current_folder =", path)
    return path
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

                    local normalized_path = normalize_path(path) or path
                    logger.dbg("folderlock: lock flow started for", normalized_path)

                    -- First password entry dialog
                    local pw_dialog
                    pw_dialog = InputDialog:new({
                        title = _("Lock folder"),
                        description = normalized_path,
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
                                                            local ok = _set_folder_lock(path, pw1)
                                                            if not ok then
                                                                UIManager:show(InfoMessage:new({
                                                                    text = _("Failed to lock folder"),
                                                                    timeout = 2,
                                                                }))
                                                                return
                                                            end
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

                    local normalized_path = normalize_path(path) or path
                    logger.dbg("folderlock: unlock flow started for", normalized_path)

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
                                            logger.dbg("folderlock: unlock current folder failed for", locked_path)
                                            UIManager:show(InfoMessage:new({
                                                text = _("Incorrect password"),
                                                timeout = 2,
                                            }))
                                            return
                                        end
                                        logger.dbg("folderlock: unlock current folder success for", locked_path)
                                        UIManager:close(unlock_dialog)
                                        local ok = _remove_folder_lock(locked_path)
                                        if not ok then
                                            UIManager:show(InfoMessage:new({
                                                text = _("Failed to unlock folder"),
                                                timeout = 2,
                                            }))
                                            return
                                        end
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
