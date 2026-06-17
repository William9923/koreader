describe("FolderLock plugin — fixtures and environment", function()
    local DataStorage, FileManager, Screen, UIManager, lfs, ffiUtil, LuaSettings
    local abs_test_root, open_dir, locked_dir, locked_sub_dir
    local test_root = "spec/front/unit/data/folderlock_test"
    local registry_file

    local function create_dir(path)
        lfs.mkdir(path)
    end

    local function remove_tree(path)
        if lfs.attributes(path, "mode") == "directory" then
            for entry in lfs.dir(path) do
                if entry ~= "." and entry ~= ".." then
                    local full = path .. "/" .. entry
                    local mode = lfs.attributes(full, "mode")
                    if mode == "directory" then
                        remove_tree(full)
                    else
                        os.remove(full)
                    end
                end
            end
            lfs.rmdir(path)
        elseif lfs.attributes(path, "mode") == "file" then
            os.remove(path)
        end
    end

    local function seed_registry(entries)
        os.remove(registry_file)
        local reg = LuaSettings:open(registry_file)
        reg:saveSetting("locks", entries or {})
        reg:flush()
    end

    local function cleanup_registry()
        os.remove(registry_file)
    end

    setup(function()
        require("commonrequire")
        disable_plugins()
        load_plugin("folderlock")

        DataStorage = require("datastorage")
        FileManager = require("apps/filemanager/filemanager")
        Screen = require("device").screen
        UIManager = require("ui/uimanager")
        lfs = require("libs/libkoreader-lfs")
        ffiUtil = require("ffi/util")
        LuaSettings = require("luasettings")

        -- Resolve test root to absolute path for consistent lock matches
        lfs.mkdir(test_root)
        abs_test_root = ffiUtil.realpath(test_root) or test_root

        open_dir = abs_test_root .. "/open"
        locked_dir = abs_test_root .. "/locked"
        locked_sub_dir = locked_dir .. "/sub"

        create_dir(open_dir)
        create_dir(locked_dir)
        create_dir(locked_sub_dir)

        registry_file = DataStorage:getSettingsDir() .. "/folderlock_registry.lua"
    end)

    teardown(function()
        cleanup_registry()
        remove_tree(test_root)
    end)

    it("should create and cleanup test directory fixtures", function()
        assert.is_not_nil(lfs.attributes(open_dir, "mode"), "open_dir should exist")
        assert.is_not_nil(lfs.attributes(locked_dir, "mode"), "locked_dir should exist")
        assert.is_not_nil(lfs.attributes(locked_sub_dir, "mode"), "locked_sub_dir should exist")
    end)

    it("should pre-seed and cleanup registry file correctly", function()
        local test_entries = {
            [locked_dir] = tostring(5381), -- djb2("") placeholder
        }
        seed_registry(test_entries)

        -- Verify registry file was written
        local check_reg = LuaSettings:open(registry_file)
        local locks = check_reg:readSetting("locks") or {}
        assert.are.same(test_entries, locks)

        -- Cleanup
        cleanup_registry()
        assert.is_nil(lfs.attributes(registry_file, "mode"), "registry should be removed")
    end)

    it("should create FileManager instance with folderlock plugin loaded", function()
        -- Pre-seed an empty registry
        seed_registry({})

        local fm = FileManager:new{
            dimen = Screen:getSize(),
            root_path = open_dir,
        }
        UIManager:show(fm)
        fastforward_ui_events()

        -- After init, FileChooser should be patched and path should be set
        assert.is_not_nil(fm.file_chooser, "file_chooser should exist")
        assert.are_equal(open_dir, fm.file_chooser.path)

        fm:onClose()
        UIManager:quit()
        cleanup_registry()
    end)
end)

describe("FolderLock plugin — smoke", function()
    local DataStorage, FileManager, Screen, UIManager, lfs, ffiUtil, LuaSettings
    local abs_test_root, open_dir, locked_dir, locked_sub_dir
    local test_root = "spec/front/unit/data/folderlock_test"
    local registry_file

    local function create_dir(path)
        lfs.mkdir(path)
    end

    local function remove_tree(path)
        if lfs.attributes(path, "mode") == "directory" then
            for entry in lfs.dir(path) do
                if entry ~= "." and entry ~= ".." then
                    local full = path .. "/" .. entry
                    local mode = lfs.attributes(full, "mode")
                    if mode == "directory" then
                        remove_tree(full)
                    else
                        os.remove(full)
                    end
                end
            end
            lfs.rmdir(path)
        elseif lfs.attributes(path, "mode") == "file" then
            os.remove(path)
        end
    end

    local function seed_registry(entries)
        os.remove(registry_file)
        local reg = LuaSettings:open(registry_file)
        reg:saveSetting("locks", entries or {})
        reg:flush()
    end

    local function cleanup_registry()
        os.remove(registry_file)
    end

    setup(function()
        require("commonrequire")
        disable_plugins()
        load_plugin("folderlock")

        DataStorage = require("datastorage")
        FileManager = require("apps/filemanager/filemanager")
        Screen = require("device").screen
        UIManager = require("ui/uimanager")
        lfs = require("libs/libkoreader-lfs")
        ffiUtil = require("ffi/util")
        LuaSettings = require("luasettings")

        lfs.mkdir(test_root)
        abs_test_root = ffiUtil.realpath(test_root) or test_root

        open_dir = abs_test_root .. "/open"
        locked_dir = abs_test_root .. "/locked"
        locked_sub_dir = locked_dir .. "/sub"

        create_dir(open_dir)
        create_dir(locked_dir)
        create_dir(locked_sub_dir)

        registry_file = DataStorage:getSettingsDir() .. "/folderlock_registry.lua"
    end)

    teardown(function()
        cleanup_registry()
        remove_tree(test_root)
    end)

    it("smoke: FileChooser.changeToPath is patched after plugin init", function()
        -- Save original BEFORE creating FileManager (which triggers plugin init)
        local FileChooser = require("ui/widget/filechooser")
        local orig_do_patch = FileChooser.changeToPath

        seed_registry({})
        local fm = FileManager:new{
            dimen = Screen:getSize(),
            root_path = open_dir,
        }
        UIManager:show(fm)
        fastforward_ui_events()

        -- After FileManager init triggers FolderLock:init, the class method should be patched
        local patched = require("ui/widget/filechooser").changeToPath
        assert.are_not_equal(orig_do_patch, patched,
            "FileChooser.changeToPath should be patched by folderlock")
        assert.is_not_nil(fm.file_chooser, "file_chooser should exist")
        assert.are_equal(open_dir, fm.file_chooser.path)

        fm:onClose()
        UIManager:quit()
        cleanup_registry()
    end)

    it("smoke: unlocked navigation succeeds through patched changeToPath", function()
        seed_registry({})
        local fm = FileManager:new{
            dimen = Screen:getSize(),
            root_path = open_dir,
        }
        UIManager:show(fm)
        fastforward_ui_events()

        -- Navigate to an unlocked subdirectory
        fm.file_chooser:changeToPath(locked_sub_dir)
        assert.are_equal(locked_sub_dir, fm.file_chooser.path,
            "navigating to unlocked path should succeed")

        -- Navigate back to open_dir
        fm.file_chooser:changeToPath(open_dir)
        assert.are_equal(open_dir, fm.file_chooser.path,
            "navigating back to unlocked path should succeed")

        fm:onClose()
        UIManager:quit()
        cleanup_registry()
    end)
end)
