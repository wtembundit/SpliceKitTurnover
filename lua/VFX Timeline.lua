-- VFX Timeline.lua
-- Folder-first controller for placing VFX delivery renders onto the timeline
-- against matching "<VFX Number> - VFX NAMING" title ranges.
--
-- Current architecture:
--   1) Ask SpliceKit Worker.app for user-specific delivery settings
--   2) Export current project as FCPXML
--   3) Ask the worker to run the Node planner
--   4) Import the patched FCPXML back into FCP
--
-- Current implementation target:
--   - folder-based delivery scan
--   - import matched delivery files into the browser when possible
--   - handle/slate trim before placement
--   - connected / replace / audition placement over earlier VFX versions
--
-- Still evolving:
--   - event creation when the target event does not exist yet
--   - richer existing-event reuse
--   - browser keyword tagging for delivery batches

local CONFIG = {
    IMPORT_INTERNAL = false,
    REQUEST_TIMEOUT_SEC = 300,
    JOB_TIMEOUT_SEC = 300,
    DEFAULT_TARGET_EVENT_NAME = "VFX Deliveries",
    DEFAULT_TOTAL_HANDLE_FRAMES = 0,
    DEFAULT_SLATE_FRAMES = 0,
    DEFAULT_PLACEMENT_MODE = "connected",
    DEFAULT_LANE = 10,
}

local function log(lines, msg)
    print("[vfx-timeline] " .. tostring(msg))
    lines[#lines + 1] = tostring(msg)
end

local function trim(s)
    return (s and s:gsub("^%s+", ""):gsub("%s+$", "")) or ""
end

local function state_dir()
    local home = os.getenv("HOME") or "/tmp"
    return home .. "/Library/Application Support/SpliceKit/VFXShotList"
end

local function file_exists(path)
    local f = io.open(path, "rb")
    if f then f:close(); return true end
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
    local out = {}
    if not file_exists(path) then return out end
    local text = read_file(path)
    for line in text:gmatch("[^\r\n]+") do
        local key, value = line:match("^([^\t]+)\t(.*)$")
        if key then
            out[key] = value
        end
    end
    return out
end

local function write_key_value_file(path, map)
    local keys = {}
    for key in pairs(map or {}) do
        keys[#keys + 1] = key
    end
    table.sort(keys)

    local out = {}
    for _, key in ipairs(keys) do
        out[#out + 1] = tostring(key) .. "\t" .. tostring(map[key] or "")
    end
    write_file(path, table.concat(out, "\n") .. "\n")
end

local function join_us(values)
    return table.concat(values or {}, string.char(31))
end

local function sorted_keys(set_map)
    local out = {}
    for key in pairs(set_map or {}) do
        out[#out + 1] = key
    end
    table.sort(out)
    return out
end

local function rpc_ok(method, params)
    local ok, res = pcall(function() return sk.rpc(method, params or {}) end)
    if ok and res and not res.error then return true, res end
    return false, ok and res or tostring(res)
end

local function ensure_worker_ready(lines)
    local ready_path = state_dir() .. "/VFX_Shot_List_Worker_Ready.flag"
    if file_exists(ready_path) then
        log(lines, "Worker ready: " .. ready_path)
        return true
    end
    error("SpliceKit Worker.app is not running.")
end

local function export_current_fcpxml(path)
    local res = sk.rpc("fcpxml.export", { path = path })
    if res and res.error then error("fcpxml.export failed: " .. tostring(res.error)) end
    if not file_exists(path) then error("Export did not create file: " .. path) end
end

local function import_patched_xml(xml_text)
    local res = sk.rpc("fcpxml.import", { xml = xml_text, internal = CONFIG.IMPORT_INTERNAL })
    if res and res.error then error("fcpxml.import failed: " .. tostring(res.error)) end
    return res
end

local function collect_browser_context(lines)
    local event_set = {}
    local project_names = {}
    local ok, res = rpc_ok("browser.listClips", {})
    if not ok or type(res) ~= "table" then
        log(lines, "Could not collect browser context; continuing with defaults.")
        return {}, {}
    end

    local clips = res.clips or {}
    for _, clip in ipairs(clips) do
        local event_name = trim(clip.event or "")
        if event_name ~= "" then
            event_set[event_name] = true
        end
        local class_name = tostring(clip.class or "")
        local clip_name = trim(clip.name or "")
        if clip_name ~= "" and class_name:find("Sequence") then
            project_names[#project_names + 1] = clip_name
        end
    end

    local event_names = sorted_keys(event_set)
    table.sort(project_names)
    return event_names, project_names
end

local function wait_for_file(path, timeout_sec, lines, label)
    local start_time = os.time()
    while os.difftime(os.time(), start_time) < timeout_sec do
        if file_exists(path) then
            log(lines, label .. ": " .. path)
            return true
        end
        sk.sleep(0.20)
    end
    return false
end

local function main()
    local lines = {}
    local runtime = state_dir()
    local source_xml_path = runtime .. "/VFX_Deliveries_Source.fcpxml"
    local request_path = runtime .. "/VFX_Deliveries_Request.tsv"
    local config_path = runtime .. "/VFX_Deliveries_Config.tsv"
    local job_path = runtime .. "/VFX_Deliveries_Job.tsv"
    local result_path = runtime .. "/VFX_Deliveries_Result.tsv"
    local output_xml_path = runtime .. "/VFX_Deliveries_Patched.fcpxml"
    local report_path = runtime .. "/VFX_Deliveries_Report.txt"
    delete_file(request_path)
    delete_file(config_path)
    delete_file(job_path)
    delete_file(result_path)
    delete_file(output_xml_path)
    delete_file(report_path)

    ensure_worker_ready(lines)
    local event_names, project_names = collect_browser_context(lines)

    write_key_value_file(request_path, {
        target_event_name = CONFIG.DEFAULT_TARGET_EVENT_NAME,
        total_handle_frames = tostring(CONFIG.DEFAULT_TOTAL_HANDLE_FRAMES),
        slate_frames = tostring(CONFIG.DEFAULT_SLATE_FRAMES),
        placement_mode = CONFIG.DEFAULT_PLACEMENT_MODE,
        lane = tostring(CONFIG.DEFAULT_LANE),
        existing_event_names = join_us(event_names),
        existing_project_names = join_us(project_names),
    })
    log(lines, "Waiting for worker config...")
    if not wait_for_file(config_path, CONFIG.REQUEST_TIMEOUT_SEC, lines, "Config ready") then
        error("Timed out waiting for VFX Timeline config.")
    end

    local config = parse_key_value_file(config_path)
    local status = trim(config.status or "")
    if status ~= "ok" then
        error("VFX Timeline cancelled: " .. trim(config.message or status or "unknown"))
    end

    log(lines, "Exporting current project...")
    export_current_fcpxml(source_xml_path)

    write_key_value_file(job_path, {
        source_xml_path = source_xml_path,
        config_path = config_path,
        output_xml_path = output_xml_path,
        report_path = report_path,
    })
    log(lines, "Waiting for worker planner...")
    if not wait_for_file(result_path, CONFIG.JOB_TIMEOUT_SEC, lines, "Planner result ready") then
        error("Timed out waiting for VFX Timeline planner.")
    end

    local result = parse_key_value_file(result_path)
    if trim(result.status or "") ~= "ok" then
        error("Planner failed: " .. trim(result.message or "unknown error"))
    end

    local patched_xml_path = trim(result.patched_xml_path or output_xml_path)
    if not file_exists(patched_xml_path) then
        error("Patched FCPXML missing: " .. patched_xml_path)
    end

    local patched_xml = read_file(patched_xml_path)
    log(lines, "Importing patched FCPXML...")
    import_patched_xml(patched_xml)

    if file_exists(report_path) then
        local report_text = read_file(report_path)
        log(lines, "Planner report:\n" .. report_text)
    end

    if sk and sk.toast then
        sk.toast("VFX Timeline import complete", 4)
    end
end

local ok, err = pcall(main)
if not ok then
    if sk and sk.toast then
        sk.toast("VFX Timeline failed: " .. tostring(err), 6)
    end
    error(err)
end
