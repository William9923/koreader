--[[--
Plugin to password-protect folders via a lock registry.
@module koplugin.FolderLock
--]]--

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

-- In-memory lock registry: { [absolute_path] = djb2_hash_string }
local _lock_registry = {}

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

-- Enumerate all ancestor paths (including the path itself),
-- from deepest to shallowest (root-most).
-- e.g., "/a/b/c" -> { "/a/b/c", "/a/b", "/a", "/" }
local function path_ancestors(path)
    local ancestors = {}
    if not path or path == "" then return ancestors end
    while path ~= "/" and path ~= "" do
        table.insert(ancestors, path)
        local parent = path:match("^(.*)/[^/]+$")
        if parent == path or not parent then break end
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
        if _lock_registry[apath] then
            return apath
        end
    end
    return nil
end

local FolderLock = WidgetContainer:extend{
    name = "folderlock",
    is_doc_only = false,
}

function FolderLock:init()
    self.ui.menu:registerToMainMenu(self)

    if self.ui.registerPostInitCallback then
        self.ui:registerPostInitCallback(function()
            local fc = self.ui.file_chooser
            if not fc then return end

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
                dialog = InputDialog:new{
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
                                    UIManager:show(InfoMessage:new{
                                        text = _("Access Denied"),
                                        timeout = 2,
                                    })
                                end,
                            },
                            {
                                text = _("Unlock"),
                                is_enter_default = true,
                                callback = function()
                                    local input = dialog:getInputText()
                                    local hash = djb2_hash(input)
                                    local stored = _lock_registry[locked_path]
                                    if hash == stored then
                                        UIManager:close(dialog)
                                        orig_changeToPath(self_fc, path, focused_path)
                                    else
                                        UIManager:show(InfoMessage:new{
                                            text = _("Incorrect password"),
                                            timeout = 2,
                                        })
                                        dialog:onClose()

                                        -- Re-show dialog for another attempt
                                        UIManager:show(dialog)
                                        dialog:onShowKeyboard()
                                    end
                                end,
                            },
                        }
                    },
                }
                UIManager:show(dialog)
                dialog:onShowKeyboard()
            end
        end)
    end
end

function FolderLock:addToMainMenu(menu_items)
    menu_items.folder_lock = {
        text = _("Folder Lock"),
        sorting_hint = "more_tools",
        callback = function()
            -- Placeholder: will be replaced with submenu in Step 6
        end,
    }
end

return FolderLock
