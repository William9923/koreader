describe("FolderLock plugin", function()
    local DataStorage, FileManager, Screen, UIManager, lfs, ffiUtil, LuaSettings, makePath
    local test_root, open_dir, locked_dir, locked_sub_dir, registry_file
    local fm
    local test_idx = 0

    local orig_FileChooser_changeToPath

    local function create_dir(path)
        makePath(path)
        assert.is_not_nil(lfs.attributes(path, "mode"), "failed to create dir: " .. path)
    end

    local function remove_tree(path)
        local mode = lfs.attributes(path, "mode")
        if mode == "directory" then
            for entry in lfs.dir(path) do
                if entry ~= "." and entry ~= ".." then
                    remove_tree(path .. "/" .. entry)
                end
            end
            lfs.rmdir(path)
        elseif mode == "file" then
            os.remove(path)
        end
    end

    local function cleanup_registry()
        os.remove(registry_file)
    end

    local function seed_registry(entries)
        cleanup_registry()
        local reg = LuaSettings:open(registry_file)
        reg:saveSetting("locks", entries or {})
        reg:flush()
    end

    local function djb2_hash(str)
        local bit = require("bit")
        local hash = 5381
        for i = 1, #str do
            hash = bit.bxor(hash * 33 + str:byte(i), 0xFFFFFFFF)
        end
        return tostring(hash)
    end

    local function reset_global_plugin_state()
        local FileChooser = require("ui/widget/filechooser")
        if not orig_FileChooser_changeToPath then
            orig_FileChooser_changeToPath = FileChooser.changeToPath
        else
            FileChooser.changeToPath = orig_FileChooser_changeToPath
        end

        local PluginLoader = require("pluginloader")
        PluginLoader.enabled_plugins = {}
        PluginLoader.disabled_plugins = {}
        PluginLoader.loaded_plugins = {}

        load_plugin("folderlock")
    end

    local function create_filemanager(root_path)
        fm = FileManager:new{
            dimen = Screen:getSize(),
            root_path = root_path,
        }
        UIManager:show(fm)
        fastforward_ui_events()
        assert.is_not_nil(fm.file_chooser, "file_chooser should exist")
        return fm
    end

    setup(function()
        require("commonrequire")
        DataStorage = require("datastorage")
        FileManager = require("apps/filemanager/filemanager")
        Screen = require("device").screen
        UIManager = require("ui/uimanager")
        lfs = require("libs/libkoreader-lfs")
        ffiUtil = require("ffi/util")
        LuaSettings = require("luasettings")
        makePath = require("util").makePath

        registry_file = DataStorage:getSettingsDir() .. "/folderlock_registry.lua"
    end)

    before_each(function()
        test_idx = test_idx + 1
        test_root = DataStorage:getDataDir() .. "/folderlock_test_" .. tostring(test_idx)
        open_dir = test_root .. "/open"
        locked_dir = test_root .. "/locked"
        locked_sub_dir = locked_dir .. "/sub"

        create_dir(open_dir)
        create_dir(locked_sub_dir)

        reset_global_plugin_state()
        seed_registry({})
    end)

    after_each(function()
        if fm then
            fm:onClose()
            fm = nil
        end
        UIManager:quit()

        cleanup_registry()
        remove_tree(test_root)

        -- Always restore class-level patch target so tests don't leak state.
        local FileChooser = require("ui/widget/filechooser")
        if orig_FileChooser_changeToPath then
            FileChooser.changeToPath = orig_FileChooser_changeToPath
        end

        disable_plugins()
    end)

    -- Step 3
    it("creates deterministic directory fixtures", function()
        assert.are.equal("directory", lfs.attributes(open_dir, "mode"))
        assert.are.equal("directory", lfs.attributes(locked_dir, "mode"))
        assert.are.equal("directory", lfs.attributes(locked_sub_dir, "mode"))
    end)

    it("seeds and cleans registry deterministically", function()
        local entries = {
            [locked_dir] = djb2_hash("seed"),
        }
        seed_registry(entries)

        local reg = LuaSettings:open(registry_file)
        local locks = reg:readSetting("locks") or {}
        assert.are.same(entries, locks)

        cleanup_registry()
        assert.is_nil(lfs.attributes(registry_file, "mode"))
    end)

    -- Step 4
    it("smoke: patches FileChooser.changeToPath on plugin init", function()
        local FileChooser = require("ui/widget/filechooser")
        local before_patch = FileChooser.changeToPath

        create_filemanager(open_dir)

        local after_patch = require("ui/widget/filechooser").changeToPath
        assert.are_not.equal(before_patch, after_patch)
    end)

    it("smoke: unlocked navigation succeeds via patched changeToPath", function()
        create_filemanager(open_dir)

        fm.file_chooser:changeToPath(locked_sub_dir)
        local expected = ffiUtil.realpath(locked_sub_dir) or locked_sub_dir
        local actual = ffiUtil.realpath(fm.file_chooser.path) or fm.file_chooser.path
        assert.are.equal(expected, actual)
    end)

    -- Step 5
    it("scenario: unlocked navigation is unaffected even when another folder is locked", function()
        seed_registry({
            [ffiUtil.realpath(locked_dir) or locked_dir] = djb2_hash("secret123"),
        })

        create_filemanager(test_root)

        fm.file_chooser:changeToPath(open_dir)
        local expected = ffiUtil.realpath(open_dir) or open_dir
        local actual = ffiUtil.realpath(fm.file_chooser.path) or fm.file_chooser.path
        assert.are.equal(expected, actual)
    end)
end)
