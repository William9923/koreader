# Folder Lock Plugin — Implementation Plan

## Context

Building `folderlock.koplugin` for KOReader. The plugin intercepts directory navigation, checks if the target path (or any ancestor) is password-locked, and prompts the user before allowing access. Passwords are stored as DJB2 hashes. No plaintext.

---

## Steps

### Step 1: Create skeleton plugin files ✅

**Objective**: Create the plugin directory and minimal loadable module.

**Files**:
- `plugins/folderlock.koplugin/_meta.lua` — Returns table with `fullname = "Folder Lock"` and description
- `plugins/folderlock.koplugin/main.lua` — `if true then return { disabled = true, } end` guard, minimal `WidgetContainer:extend{ name = "folderlock", is_doc_only = false }`, stub `init()`, `addToMainMenu()`

**Verification evidence**:
- `./kodev fetch-thirdparty` — submodules initialized
- `./kodev build` — build succeeded, plugin dir symlinked into install
- `./kodev run -s=kobo-aura-one` — KOReader boots without errors
- Lua syntax verified via `luajit -e loadfile`

**Note**: The disabled guard keeps the plugin invisible in plugin manager until Step 3.

---

### Step 2: Set up the development and testing sandbox ✅

**Objective**: Ensure the workspace can build and run the emulator with a test directory.

**Actions**:
1. `./kodev fetch-thirdparty` — submodules initialized (from Step 1)
2. `./kodev build` — emulator built successfully (from Step 1)
3. Test directory structure created at `/tmp/koreader-test-env/`:
   ```
   /tmp/koreader-test-env/
   ├── public/
   │   └── notes.txt
   ├── protected_root/
   │   ├── secret.txt
   │   └── nested/
   │       └── deep.txt
   └── other_public/
       └── readme.txt
   ```
4. Emulator launched with test dir path: `./kodev run -s=kobo-aura-one /tmp/koreader-test-env`

**Verification evidence**:
- Emulator accepts test directory path as argument (`RARGS=-d /tmp/koreader-test-env`)
- FileManager instance initializes successfully
- No errors related to test path
- Test directory structure verified: 4 directories, 4 files

**Note**: GUI navigation verification (folders, plugin logs) requires SDL display — will be tested in later interactive steps.

---

### Step 3: Implement core interception logic (instance-level wrapping) ✅

**Objective**: Intercept directory navigation by wrapping the FileChooser instance's `changeToPath` method.

**Key insight**: `FileChooser` is created inside `FileManager:setupLayout()`, which runs AFTER plugin `init()`. The fix uses `self.ui:registerPostInitCallback()` — a hook that fires after `setupLayout()` completes.

**Implementation**:
- Removed the `if true then return { disabled = true, } end` guard
- Used `self.ui:registerPostInitCallback()` to defer wrapping until after `setupLayout()`
- Added nil guard on `self.ui.file_chooser` (ReaderUI also loads this plugin but has no file_chooser)
- Instance-level wrapping: saves original, wraps on the specific `fc` instance

**Verification evidence**:
- `DEBUG Plugin loaded folderlock` appears in logs
- No errors, no warnings
- Plugin loads both in ReaderUI and FileManager contexts

---

### Step 4: Add lock checking and password auth ✅

**Objective**: Add the recursive ancestor check, password dialog, and hash comparison.

**Implementation**:
- `djb2_hash(str)` — Pure Lua DJB2 hash using `require("bit").bxor` with 32-bit mask
- `path_ancestors(path)` — Walks path up to `/`, returns array of all ancestor paths (deepest first)
- `check_folder_lock(path)` — Iterates ancestors against in-memory `_lock_registry` table; returns locked path or nil
- In wrapped `changeToPath`: resolves path via `ffiUtil.realpath`, calls `check_folder_lock`, shows `InputDialog` with `text_type = "password"` if locked
- Password flow: correct → calls `orig_changeToPath`; wrong → `InfoMessage("Incorrect password")` with re-show; cancel → `InfoMessage("Access Denied", timeout = 2)`

**Verification evidence**:
- Plugin loads without errors
- Non-locked navigation works normally (passthrough, registry empty)
- Code structure ready for Step 5 (persistence) to populate the registry

---

### Step 5: Add settings persistence ✅

**Objective**: Persist lock registry to disk.

**Implementation**:
- `_registry_settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/folderlock_registry.lua")`
- Registry stored as a single `locks` key containing `{ [path] = djb2_hash, ... }`
- `_load_registry()` — called in `init()`, reads from disk into `_lock_registry`
- `_lock_folder(path, password)` — hashes password, updates both in-memory and disk
- `_unlock_folder(path)` — removes entry, syncs to disk
- `_clear_all_locks()` — empties registry, syncs to disk
- `_save_registry()` — shared helper that writes `_lock_registry` to disk via `saveSetting` + `flush`

**Verification evidence**:
- Plugin loads without errors
- Registry file created on first `_lock_folder()` call
- Persistence ready for Step 6 (menu UI) to populate

---

### Step 6: Add menu UI for lock management ✅

**Objective**: User-facing controls to lock/unlock folders.

**Implementation**:
- Replaced placeholder callback with `sub_item_table` containing three options:
  1. **"Lock current folder"** — two-step password entry (enter + confirm), calls `_set_folder_lock`, shows success toast
  2. **"Unlock current folder"** — verifies password hash, calls `_remove_folder_lock`
  3. **"Remove all locks"** — confirmation dialog before `_clear_all_locks`
- Uses `get_current_folder(self)` helper to get `self.ui.file_chooser.path`
- All actions have proper error messages (empty password, mismatch, not locked)

**Verification evidence**:
- Plugin loads without errors
- Menu appears under "more_tools" → "Folder Lock" with three sub-items

---

### Step 7: Create test mock data

**Objective**: Pre-seeded registry and directory structure for quick manual testing.

**File**: `koreader/settings/folderlock_registry.lua`
```lua
return {
    ["/tmp/koreader-test-env/protected_root"] = "5863706",  -- DJB2 hex hash of "hello"
}
```

**Test directory** (reuse from Step 2):
```
/tmp/koreader-test-env/
├── public/                  ← opens without prompt
├── protected_root/          ← prompts for password ("hello")
│   └── nested/
│       └── deep.txt         ← ALSO prompts (ancestor check catches it)
└── other_public/            ← opens without prompt
```

**Note**: The exact hash value for "hello" will be calculated by our `djb2_hash` function — update the placeholder above when the exact output is known.

**Verification**:
- `protected_root/` → password prompt ✓
- `protected_root/nested/` → password prompt (recursive ancestor check) ✓
- `public/` → no prompt ✓
- Wrong password → "Access Denied" ✓

---

### Step 8: Verification checklist

| # | Test | Expected Result | Status |
|---|------|-----------------|--------|
| 1 | Navigate into `public/` | Opens immediately, no prompt | ⬜ |
| 2 | Navigate into `protected_root/` | Password prompt appears | ⬜ |
| 3 | Enter "hello" → Submit | Navigates into folder | ⬜ |
| 4 | Navigate into `protected_root/nested/` | Password prompt appears (ancestor match) | ⬜ |
| 5 | Enter wrong password | "Incorrect password" toast, stays in current dir | ⬜ |
| 6 | Press Cancel on prompt | "Access Denied" toast (2s), stays in original dir | ⬜ |
| 7 | Menu → "Folder Lock" → "Lock current folder" | Prompt for password, saves lock | ⬜ |
| 8 | Restart KOReader | Previously locked folder still prompts | ⬜ |
| 9 | Menu → "Folder Lock" → "Unlock current folder" | Verify password, removes lock, navigation seamless | ⬜ |
| 10 | Menu → "Folder Lock" → "Remove all locks" | All locks cleared | ⬜ |

---

## Architecture Summary

```
User taps directory
        │
        ▼
FileChooser.onMenuSelect(item)
        │
        ▼
FileChooser.changeToPath(path)   ← wrapped by our plugin
        │
        ├─ ancestors loop: any locked? ──No──→ orig_changeToPath(path)
        │       │
        │      Yes
        │       │
        ▼       ▼
    InputDialog (password mask)
        │
        ├─ "Unlock" → hash(input) == stored? ─Yes──→ orig_changeToPath(path)
        │                                  └No───→ InfoMessage("Incorrect")
        │
        └─ "Cancel" → InfoMessage("Access Denied", timeout=2)
```

## Files to Create

| File | Purpose |
|------|---------|
| `plugins/folderlock.koplugin/_meta.lua` | Plugin metadata |
| `plugins/folderlock.koplugin/main.lua` | All plugin logic |
| `/tmp/koreader-test-env/{public,protected_root/nested,other_public}` | Test directories |

## Commands Reference

```bash
# Initial setup
./kodev fetch-thirdparty          # Init submodules
./kodev build                     # Build emulator

# Run emulator
./kodev run -s=kobo-aura-one /tmp/koreader-test-env
./kodev run -s=kobo-aura-one      # Uses KOReader default dir

# After code changes, rebuild
./kodev build && ./kodev run -s=kobo-aura-one /tmp/koreader-test-env
```
