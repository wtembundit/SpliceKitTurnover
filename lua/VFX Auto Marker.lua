local STATE_DIR = (os.getenv("HOME") or "") .. "/Library/Application Support/SpliceKit/VFXShotList"
local READY_FILE = STATE_DIR .. "/VFX_Shot_List_Worker_Ready.flag"
local REQUEST_FILE = STATE_DIR .. "/VFX_Auto_Marker_Request.tsv"
local RESULT_FILE = STATE_DIR .. "/VFX_Auto_Marker_Result.tsv"
local POLL_INTERVAL = 0.10
local TIMEOUT_SEC = 180.0

local function log(msg)
    print("[vfx-auto-marker] " .. tostring(msg))
end

local function file_exists(path)
    local f = io.open(path, "rb")
    if f then
        f:close()
        return true
    end
    return false
end

local function read_file(path)
    local f, err = io.open(path, "rb")
    if not f then error("Cannot open file: " .. tostring(err)) end
    local s = f:read("*a")
    f:close()
    return s
end

local function write_file(path, content)
    local f, err = io.open(path, "wb")
    if not f then error("Cannot write file: " .. tostring(err)) end
    f:write(content)
    f:close()
end

local function delete_file(path)
    if file_exists(path) then
        os.remove(path)
    end
end

local function parse_key_value_file(path)
    local map = {}
    if not file_exists(path) then return map end
    local text = read_file(path)
    for line in text:gmatch("([^\r\n]+)") do
        local key, value = line:match("^([^\t]+)\t(.*)$")
        if key then
            map[key] = value
        end
    end
    return map
end

local function current_script_dir()
    local source = debug.getinfo(1, "S").source or ""
    if source:sub(1, 1) == "@" then
        source = source:sub(2)
    end
    return source:match("^(.*)/[^/]+$") or "."
end

local function chosen_script_path(marker_kind)
    local script_dir = current_script_dir()
    local mapping = {
        standard = script_dir .. "/scripts/VFX Auto Marker - Standard.lua",
        todo = script_dir .. "/scripts/VFX Auto Marker - To Do.lua",
        chapter = script_dir .. "/scripts/VFX Auto Marker - Chapter.lua",
    }
    return mapping[marker_kind]
end

local function wait_for_result(timeout_sec)
    local deadline = os.time() + math.ceil(timeout_sec)
    while os.time() <= deadline do
        if file_exists(RESULT_FILE) then
            return parse_key_value_file(RESULT_FILE)
        end
        sk.sleep(POLL_INTERVAL)
    end
    return nil
end

local function main()
    if not file_exists(READY_FILE) then
        error("SpliceKit Worker is not ready. Open SpliceKit Worker.app first.")
    end

    delete_file(RESULT_FILE)
    write_file(REQUEST_FILE, "default_marker_kind\tstandard\n")
    log("Waiting for worker marker choice...")

    local result = wait_for_result(TIMEOUT_SEC)
    delete_file(REQUEST_FILE)

    if not result then
        error("Timed out waiting for marker selection from SpliceKit Worker.")
    end

    delete_file(RESULT_FILE)

    local status = result.status or ""
    if status ~= "ok" then
        log(result.message or "Marker selection cancelled.")
        return
    end

    local marker_kind = result.marker_kind or ""
    local script_path = chosen_script_path(marker_kind)
    if not script_path or not file_exists(script_path) then
        error("Missing marker script for selection: " .. tostring(marker_kind))
    end

    log("Running marker script: " .. script_path)
    dofile(script_path)
end

main()
