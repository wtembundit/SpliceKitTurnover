-- splicekit_vfx_pipeline_generic_todo_fixed.lua
-- Generic one-click VFX marker pipeline for SpliceKit / Final Cut Pro
-- To Do FIXED:
-- live phase uses STANDARD markers as visible anchors
-- XML relabel/import phase converts matched markers to TODO markers

local CONFIG = {
    TITLE_MATCH = "VFX NAMING",
    DRY_RUN_PARSE = false,
    DRY_RUN_LIVE  = false,
    DRY_RUN_XML   = false,
    LIVE_SLEEP_SEC = 0.05,
    AUTO_IMPORT = true,
    IMPORT_INTERNAL = true,
    PROJECT_PREFIX = "🛠 ",
    KEEP_PATCHED_COPY = false,
    CLEANUP_TEMP_AFTER_IMPORT = true,
    CLEANUP_EXPORT_TRIES = true,
    POST_CREATE_SETTLE_SEC = 2.5,
    EXPORT_RETRY_COUNT = 6,
    EXPORT_RETRY_SLEEP_SEC = 1.0,
    MIN_EXPECTED_MARKERS = 8,
    EPSILON = 0.0005,
    PREFER_DEFAULT_MARKERS = true,
    MIN_REASONABLE_TIME = 0,
    MAX_REASONABLE_TIME = 86400,
    MAX_REASONABLE_GAP = 3600,
    LOG_LIMIT = 120,
    TEMP_BASENAME = "splicekit_vfx_pipeline_generic_todo_fixed",
}

local CLIP_LIKE = {
    ["audio"] = true, ["video"] = true, ["clip"] = true, ["title"] = true,
    ["mc-clip"] = true, ["ref-clip"] = true, ["sync-clip"] = true,
    ["asset-clip"] = true, ["audition"] = true, ["gap"] = true, ["spine"] = true,
}

local function log(msg) print("[vfx-generic-todo-fixed] " .. tostring(msg)) end
local function trim(s) return (s and s:gsub("^%s+",""):gsub("%s+$","")) or "" end
local function lower(s) return string.lower(s or "") end
local function escape_lua_pattern(s) return (tostring(s):gsub("([%%%-%^%$%(%)%%%.%[%]%*%+%-%?])","%%%1")) end
local function escape_xml_attr(s)
    s = tostring(s or "")
    return (s:gsub("&","&amp;"):gsub('"',"&quot;"):gsub("<","&lt;"):gsub(">","&gt;"):gsub("'","&apos;"))
end
local function unescape_xml(s)
    if not s then return "" end
    return (s:gsub("&lt;","<"):gsub("&gt;",">"):gsub("&quot;",'"'):gsub("&apos;","'"):gsub("&amp;","&"))
end
local function parse_fraction(str)
    if not str then return nil end
    local a,b = str:match("^([%-%.%d]+)/([%-%.%d]+)s$")
    if a and b then
        a,b = tonumber(a), tonumber(b)
        if a and b and b ~= 0 then return a/b end
    end
    local n = str:match("^([%-%.%d]+)s$")
    if n then return tonumber(n) end
    return nil
end
local function fmt_seconds(s)
    s = tonumber(s) or 0
    local rounded = math.floor(s * 1000000 + 0.5) / 1000000
    local text = string.format("%.6f", rounded):gsub("0+$",""):gsub("%.$","")
    if text == "" then text = "0" end
    return text .. "s"
end
local function file_exists(path)
    local f = io.open(path, "rb")
    if f then f:close(); return true end
    return false
end
local function read_file(path)
    local f, err = io.open(path, "rb")
    if not f then error("Cannot open file: " .. tostring(err)) end
    local s = f:read("*a"); f:close(); return s
end
local function write_file(path, content)
    local f, err = io.open(path, "wb")
    if not f then error("Cannot write file: " .. tostring(err)) end
    f:write(content); f:close()
end
local function delete_file(path)
    if path and file_exists(path) then
        local ok, err = os.remove(path)
        log("delete " .. tostring(path) .. " => " .. tostring(ok) .. (err and (" err=" .. tostring(err)) or ""))
    end
end
local function tmp_base()
    local t = os.time()
    local home = os.getenv("HOME") or "/tmp"
    return string.format("%s/Desktop/%s_%d", home, CONFIG.TEMP_BASENAME, t)
end
local function parse_attrs(attr_str)
    local attrs = {}
    if not attr_str then return attrs end
    for k,v in attr_str:gmatch('([%w:_-]+)%s*=%s*"([^"]*)"') do attrs[k] = v end
    return attrs
end
local function split_nonempty_lines(s)
    local out = {}
    if not s then return out end
    s = s:gsub("\226\128\168","\n"):gsub("\r\n","\n"):gsub("\r","\n")
    for line in s:gmatch("([^\n]*)\n?") do
        line = trim(line)
        if line ~= "" then out[#out+1] = line end
    end
    return out
end
local function extract_text_from_inner(inner)
    local parts = {}
    for txt in inner:gmatch("<text%-style[^>]*>(.-)</text%-style>") do
        local cleaned = trim(unescape_xml(txt))
        if cleaned ~= "" then parts[#parts+1] = cleaned end
    end
    if #parts == 0 then
        for txt in inner:gmatch("<text[^>]*>(.-)</text>") do
            local cleaned = trim(unescape_xml((txt:gsub("<[^>]+>",""))))
            if cleaned ~= "" then parts[#parts+1] = cleaned end
        end
    end
    return table.concat(parts, "\n")
end
local function is_vfx_title(title_name, title_text)
    local lines = split_nonempty_lines(title_text)
    local first_line = lines[1] or ""
    if lower(title_name):find(lower(CONFIG.TITLE_MATCH), 1, true) then return true end
    if first_line:match("^[%u%d_%-]+_%d%d%d%d$") then return true end
    if first_line:match("^[%u%d_%-]+_XXXX$") then return true end
    return false
end

local function derive_marker_name_and_note(title_name, title_text)
    local lines = split_nonempty_lines(title_text)
    local first_line = lines[1] or ""
    local shot_code_from_name = title_name:match("^([%u%d_%-]+)%s*%-%s*VFX%s+NAMING$")
    local marker_name = trim(first_line) ~= "" and trim(first_line) or shot_code_from_name or trim(title_name)
    local note_lines = {}
    for i = 2, #lines do
        local cleaned = trim(lines[i])
        if cleaned ~= "" then note_lines[#note_lines+1] = cleaned end
    end
    return marker_name, table.concat(note_lines, "\n")
end
local function resolved_abs_time(parent_ctx, attrs)
    local parent_abs = parent_ctx and parent_ctx.abs_time or 0
    local parent_start = parent_ctx and parent_ctx.start or 0
    local my_offset = parse_fraction(attrs.offset) or 0
    return parent_abs + (my_offset - parent_start)
end
local function context_timeline_start(parent_ctx, attrs)
    local parent_tl = parent_ctx and parent_ctx.timeline_start or 0
    local my_offset = parse_fraction(attrs.offset) or 0
    return parent_tl + my_offset
end
local function parse_source_titles(xml)
    local titles, stack = {}, {}
    local pos = 1
    while true do
        local s,e,closing,tag_name,attr_str,self_close = xml:find("<(%/?)([%w:_-]+)(.-)(/?)>", pos)
        if not s then break end
        local is_closing = (closing == "/")
        local is_self_closing = (self_close == "/")
        if not is_closing then
            local attrs = parse_attrs(attr_str)
            local parent = stack[#stack]
            local timeline_start = context_timeline_start(parent, attrs)
            local abs_time = resolved_abs_time(parent, attrs)
            local start_val = parse_fraction(attrs.start) or 0
            local duration_val = parse_fraction(attrs.duration) or 0
            local lane_val = tonumber(attrs.lane) or 0
            local node = {
                tag = tag_name, attrs = attrs, timeline_start = timeline_start,
                abs_time = abs_time, start = start_val, duration = duration_val,
                lane = lane_val, open_start = s, open_end = e,
            }
            if not is_self_closing then stack[#stack+1] = node end
        end
        if is_closing then
            local node = stack[#stack]
            if node and node.tag == tag_name then
                stack[#stack] = nil
                if node.tag == "title" then
                    local title_name = node.attrs.name or ""
                    if is_vfx_title(title_name, title_text) then
                        local inner = xml:sub(node.open_end + 1, s - 1)
                        local title_text = extract_text_from_inner(inner)
                        local marker_name, marker_note = derive_marker_name_and_note(title_name, title_text)
                        titles[#titles+1] = {
                            source_title_name = title_name,
                            marker_name = marker_name,
                            marker_note = marker_note,
                            timeline_time = node.abs_time + (node.duration / 2.0),
                            duration = node.duration,
                            lane = node.lane,
                        }
                    end
                end
            end
        end
        pos = e + 1
    end
    table.sort(titles, function(a,b) return a.timeline_time < b.timeline_time end)
    return titles
end
local function sanity_check_events(events)
    if #events == 0 then return false, "No VFX titles found" end
    for i, e in ipairs(events) do
        if e.timeline_time < CONFIG.MIN_REASONABLE_TIME or e.timeline_time > CONFIG.MAX_REASONABLE_TIME then
            return false, string.format("Unreasonable parsed time for %s: %s", e.marker_name, fmt_seconds(e.timeline_time))
        end
        if i > 1 then
            local gap = e.timeline_time - events[i-1].timeline_time
            if gap > CONFIG.MAX_REASONABLE_GAP then
                return false, string.format("Suspiciously large gap between %s and %s: %s", events[i-1].marker_name, e.marker_name, fmt_seconds(gap))
            end
        end
    end
    return true, "ok"
end
local function looks_like_default_marker(value)
    local v = lower(trim(value or ""))
    if v == "" then return true end
    if v:match("^marker%s*%d*$") then return true end
    return false
end
local function parse_existing_markers(xml)
    local markers, stack = {}, {}
    local pos = 1
    while true do
        local s,e,closing,tag_name,attr_str,self_close = xml:find("<(%/?)([%w:_-]+)(.-)(/?)>", pos)
        if not s then break end
        local is_closing = (closing == "/")
        local is_self_closing = (self_close == "/")
        if not is_closing then
            local attrs = parse_attrs(attr_str)
            local parent = stack[#stack]
            local timeline_start = context_timeline_start(parent, attrs)
            local start_val = parse_fraction(attrs.start) or 0
            local duration_val = parse_fraction(attrs.duration) or 0
            local node = {
                tag = tag_name, attrs = attrs, timeline_start = timeline_start,
                start = start_val, duration = duration_val, open_start = s, open_end = e,
            }
            if (tag_name == "marker" or tag_name == "chapter-marker") and parent and CLIP_LIKE[parent.tag] then
                markers[#markers+1] = {
                    tag_name = tag_name,
                    local_start = start_val,
                    raw_start = attrs.start or "",
                    value = unescape_xml(attrs.value or ""),
                    note = unescape_xml(attrs.note or ""),
                    open_start = s, open_end = e,
                    parent_tag = parent.tag,
                    parent_timeline_start = parent.timeline_start,
                    parent_duration = parent.duration,
                    interval_start = parent.timeline_start,
                    interval_end = parent.timeline_start + parent.duration,
                    attrs = attrs,
                }
            end
            if not is_self_closing then stack[#stack+1] = node end
        else
            if #stack > 0 then stack[#stack] = nil end
        end
        pos = e + 1
    end
    table.sort(markers, function(a,b)
        if a.interval_start == b.interval_start then return a.parent_duration < b.parent_duration end
        return a.interval_start < b.interval_start
    end)
    return markers
end
local function build_todo_marker_xml(m, new_value, new_note)
    local attrs = {}
    for k, v in pairs(m.attrs) do attrs[k] = v end
    attrs.value = new_value
    attrs.note = (new_note and new_note ~= "") and new_note or nil
    attrs.completed = "0"
    attrs.posterOffset = nil
    local ordered, seen = {}, {}
    local preferred = {"start","duration","value","completed","note"}
    for _, k in ipairs(preferred) do
        if attrs[k] ~= nil then ordered[#ordered+1] = k; seen[k] = true end
    end
    for k, _ in pairs(attrs) do
        if not seen[k] then ordered[#ordered+1] = k end
    end
    local parts = {}
    for _, k in ipairs(ordered) do
        parts[#parts+1] = string.format('%s="%s"', k, escape_xml_attr(attrs[k]))
    end
    return "<marker " .. table.concat(parts, " ") .. "/>"
end
local function export_current_fcpxml(path)
    log("Exporting current project to: " .. path)
    local res = sk.rpc("fcpxml.export", { path = path })
    if res and res.error then error("fcpxml.export failed: " .. tostring(res.error)) end
    if not file_exists(path) then error("Export did not create file: " .. path) end
end
local function import_patched_xml(xml_text)
    log("Importing patched XML back into FCP")
    local res = sk.rpc("fcpxml.import", { xml = xml_text, internal = CONFIG.IMPORT_INTERNAL })
    if res and res.error then error("fcpxml.import failed: " .. tostring(res.error)) end
    return res
end
local function add_project_prefix(xml)
    if not CONFIG.PROJECT_PREFIX or CONFIG.PROJECT_PREFIX == "" then return xml, 0 end
    local count = 0
    local function repl_open(attr_str)
        local attrs = parse_attrs(attr_str)
        local name = attrs.name or ""
        if name ~= "" and name:sub(1, #CONFIG.PROJECT_PREFIX) ~= CONFIG.PROJECT_PREFIX then
            local old = 'name="' .. escape_xml_attr(name) .. '"'
            local new = 'name="' .. escape_xml_attr(CONFIG.PROJECT_PREFIX .. name) .. '"'
            local replaced, n = attr_str:gsub(escape_lua_pattern(old), new, 1)
            if n > 0 then
                count = count + 1
                return "<project " .. replaced .. ">"
            end
        end
        return "<project " .. attr_str .. ">"
    end
    local patched = xml:gsub("<project%s+([^>]-)>", repl_open, 1)
    return patched, count
end
local function run_live_create(events)
    log("=== LIVE CREATE PHASE ===")
    log("To Do fixed strategy: live anchors use addMarker, final import converts them to To Do")
    local created = 0
    for i, e in ipairs(events) do
        if i <= CONFIG.LOG_LIMIT then
            log(string.format('#%02d live t=%s name="%s" action=addMarker(final=todo)', i, fmt_seconds(e.timeline_time), e.marker_name))
        end
        if not CONFIG.DRY_RUN_LIVE then
            sk.seek(e.timeline_time)
            sk.sleep(CONFIG.LIVE_SLEEP_SEC)
            pcall(function() sk.rpc("timeline.selectClipInLane", { lane = 0 }) end)
            local res = sk.rpc("timeline.action", { action = "addMarker" })
            if res and res.error then error("timeline.action failed: " .. tostring(res.error) .. " action=addMarker") end
            sk.sleep(CONFIG.LIVE_SLEEP_SEC)
            created = created + 1
        end
    end
    log(string.format("Live phase done: %d parsed events%s", #events, CONFIG.DRY_RUN_LIVE and " (dry run)" or ", markers created=" .. created))
    if not CONFIG.DRY_RUN_LIVE then
        log("Waiting for FCP to settle before export: " .. tostring(CONFIG.POST_CREATE_SETTLE_SEC) .. "s")
        sk.sleep(CONFIG.POST_CREATE_SETTLE_SEC)
    end
end
local function expected_marker_floor(n)
    local approx = math.floor(n * 0.8 + 0.5)
    if approx < CONFIG.MIN_EXPECTED_MARKERS then approx = CONFIG.MIN_EXPECTED_MARKERS end
    if approx > n then approx = n end
    return approx
end
local function export_until_marker_count(base, expected_count)
    local best_xml, best_markers, best_path = nil, {}, nil
    local export_paths = {}
    local floor_count = expected_marker_floor(expected_count)
    for attempt = 1, CONFIG.EXPORT_RETRY_COUNT do
        local exported_path = string.format("%s_export_try%d.fcpxml", base, attempt)
        export_paths[#export_paths+1] = exported_path
        export_current_fcpxml(exported_path)
        local xml = read_file(exported_path)
        local markers = parse_existing_markers(xml)
        log(string.format("Export try %d/%d -> found %d markers (need >= %d)", attempt, CONFIG.EXPORT_RETRY_COUNT, #markers, floor_count))
        if #markers > #best_markers then
            best_xml, best_markers, best_path = xml, markers, exported_path
        end
        if #markers >= floor_count then
            return xml, markers, exported_path, export_paths, floor_count
        end
        if attempt < CONFIG.EXPORT_RETRY_COUNT then sk.sleep(CONFIG.EXPORT_RETRY_SLEEP_SEC) end
    end
    return best_xml, best_markers, best_path, export_paths, floor_count
end
local function interval_contains(m, t)
    return t + CONFIG.EPSILON >= m.interval_start and t - CONFIG.EPSILON <= m.interval_end
end
local function choose_marker_for_event(e, markers, used)
    local best, best_score = nil, math.huge
    for i, m in ipairs(markers) do
        if not used[i] and interval_contains(m, e.timeline_time) then
            local mid = (m.interval_start + m.interval_end) / 2
            local dist_mid = math.abs(e.timeline_time - mid)
            local score = dist_mid + (m.parent_duration * 0.01)
            if CONFIG.PREFER_DEFAULT_MARKERS and not looks_like_default_marker(m.value) then score = score + 1.0 end
            if score < best_score then
                best_score = score
                best = { index = i, marker = m, score = score }
            end
        end
    end
    return best
end
local function cleanup_temp_files(export_paths, patched_path)
    if CONFIG.CLEANUP_EXPORT_TRIES then
        for _, p in ipairs(export_paths or {}) do delete_file(p) end
    end
    if CONFIG.CLEANUP_TEMP_AFTER_IMPORT and not CONFIG.KEEP_PATCHED_COPY then delete_file(patched_path) end
end
local function run_xml_relabel(events)
    log("=== XML RELABEL PHASE ===")
    local base = tmp_base()
    local patched_path = base .. "_patched.fcpxml"
    local xml, markers, exported_path, export_paths, floor_count = export_until_marker_count(base, #events)
    if not xml or not markers then error("Export failed to produce readable XML") end
    log("Using export file: " .. tostring(exported_path))
    log(string.format("Found %d parsed events and %d existing markers", #events, #markers))
    if #markers < floor_count then error("Export still contains too few markers (" .. tostring(#markers) .. ", need >= " .. tostring(floor_count) .. ").") end
    local used, replacements = {}, {}
    local matched, unmatched = 0, 0
    for _, e in ipairs(events) do
        local choice = choose_marker_for_event(e, markers, used)
        if choice then
            used[choice.index] = true
            matched = matched + 1
            replacements[#replacements+1] = {
                start_pos = choice.marker.open_start,
                end_pos = choice.marker.open_end,
                replacement = build_todo_marker_xml(choice.marker, e.marker_name, e.marker_note),
                event = e, marker = choice.marker, score = choice.score,
            }
            if matched <= CONFIG.LOG_LIMIT then
                log(string.format('match event="%s" t=%s -> marker value="%s" interval=%s..%s parent=%s score=%.3f final=todo',
                    e.marker_name, fmt_seconds(e.timeline_time), choice.marker.value,
                    fmt_seconds(choice.marker.interval_start), fmt_seconds(choice.marker.interval_end),
                    choice.marker.parent_tag, choice.score))
            end
        else
            unmatched = unmatched + 1
            log(string.format('WARN no marker interval contains event="%s" t=%s', e.marker_name, fmt_seconds(e.timeline_time)))
        end
    end
    table.sort(replacements, function(a,b) return a.start_pos > b.start_pos end)
    local patched = xml
    for _, r in ipairs(replacements) do
        patched = patched:sub(1, r.start_pos - 1) .. r.replacement .. patched:sub(r.end_pos + 1)
    end
    local prefixed_count = 0
    patched, prefixed_count = add_project_prefix(patched)
    log("Project prefix applications: " .. tostring(prefixed_count))
    log(string.format("Matched %d events to markers, unmatched %d", matched, unmatched))
    write_file(patched_path, patched)
    log("Patched copy written to: " .. patched_path)
    if CONFIG.DRY_RUN_XML then
        log("XML phase dry run complete; no import performed")
        return
    end
    if CONFIG.AUTO_IMPORT then
        local res = import_patched_xml(patched)
        log("Import result: " .. tostring(res and res.status or "ok"))
        cleanup_temp_files(export_paths, patched_path)
    else
        log("AUTO_IMPORT=false; patched XML created only")
    end
end
local function main()
    local base = tmp_base()
    local source_export_path = base .. "_source_export.fcpxml"
    export_current_fcpxml(source_export_path)
    local source_xml = read_file(source_export_path)
    local events = parse_source_titles(source_xml)
    log("Parsed VFX events: " .. tostring(#events))
    for i, e in ipairs(events) do
        if i > math.min(#events, CONFIG.LOG_LIMIT) then break end
        log(string.format('event[%02d] t=%s name="%s" note="%s"', i, fmt_seconds(e.timeline_time), e.marker_name, e.marker_note))
    end
    local ok_sanity, why = sanity_check_events(events)
    if not ok_sanity then error("Source export sanity check failed: " .. tostring(why)) end
    if CONFIG.DRY_RUN_PARSE then
        if CONFIG.CLEANUP_EXPORT_TRIES then delete_file(source_export_path) end
        if sk and sk.toast then sk.toast("Parse dry run complete", 4) end
        return
    end
    run_live_create(events)
    run_xml_relabel(events)
    if CONFIG.CLEANUP_EXPORT_TRIES then delete_file(source_export_path) end
    if sk and sk.toast then sk.toast("Generic VFX To Do fixed finished", 5) end
end
local ok, err = pcall(main)
if not ok then
    log("ERROR: " .. tostring(err))
    if sk and sk.toast then sk.toast("Generic VFX To Do fixed failed: " .. tostring(err), 6) end
end
