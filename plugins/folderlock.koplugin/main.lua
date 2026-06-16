--[[--
Plugin to password-protect folders via a lock registry.
Passwords are stored as DJB2 hashes, never in plain text.

@module koplugin.FolderLock
--]]--

-- Temporary guard — remove after initial build test
if true then
    return { disabled = true, }
end

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

local FolderLock = WidgetContainer:extend{
    name = "folderlock",
    is_doc_only = false,
}

function FolderLock:init()
    self.ui.menu:registerToMainMenu(self)
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
