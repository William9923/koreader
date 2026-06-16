--[[--
Plugin to password-protect folders via a lock registry.
@module koplugin.FolderLock
--]]--

local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

local FolderLock = WidgetContainer:extend{
    name = "folderlock",
    is_doc_only = false,
}

function FolderLock:init()
    self.ui.menu:registerToMainMenu(self)

    if self.ui.registerPostInitCallback then
        self.ui:registerPostInitCallback(function()
            -- Only wrap if we have a FileChooser (FileManager, not ReaderUI)
            local fc = self.ui.file_chooser
            if not fc then return end

            local orig_changeToPath = fc.changeToPath
            fc.changeToPath = function(self_fc, path, focused_path)
                -- Lock check will be added in Step 4
                return orig_changeToPath(self_fc, path, focused_path)
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
