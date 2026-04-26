-- VFX Auto Naming.lua
-- One-click FCPXML roundtrip script for renumbering VFX NAMING titles.

local CONFIG = {
    TITLE_MATCH = "VFX NAMING",
    PLACEHOLDER = "XXXX",
    STEP = 10,
    START = 10,

    DRY_RUN_PARSE = false,
    DRY_RUN_XML   = false,

    AUTO_IMPORT = true,
    IMPORT_INTERNAL = true,

    PROJECT_PREFIX = "📝 ",
    KEEP_PATCHED_COPY = false,
    CLEANUP_TEMP_AFTER_IMPORT = true,
    CLEANUP_EXPORT_TRIES = true,

    MIN_REASONABLE_TIME = 0,
    MAX_REASONABLE_TIME = 86400,
    MAX_REASONABLE_GAP = 3600,

    LOG_LIMIT = 120,
    TEMP_BASENAME = "vfx_auto_naming",
}

local function log(msg) print("[vfx-auto-naming] " .. tostring(msg)) end
local function trim(s) return (s and s:gsub("^%s+",""):gsub("%s+$","")) or "" end
local function lower(s) return string.lower(s or "") end
local function escape_lua_pattern(s) return (tostring(s):gsub("([%%%-%^%$%(%)%%%.%[%]%*%+%-%?])","%%%1")) end

local function escape_xml_attr(s)
    s = tostring(s or "")
    return (s:gsub("&","&amp;"):gsub('"',"&quot;"):gsub("<","&lt;"):gsub(">","&gt;"):gsub("'","&apos;"))
end

local function escape_xml_text(s)
    s = tostring(s or "")
    return (s:gsub("&","&amp;"):gsub("<","&lt;"):gsub(">","&gt;"))
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

local function resolved_abs_time(parent_ctx, attrs)
    local parent_abs = parent_ctx and parent_ctx.abs_time or 0
    local parent_start = parent_ctx and parent_ctx.start or 0
    local my_offset = parse_fraction(attrs.offset) or 0
    return parent_abs + (my_offset - parent_start)
end

local function looks_like_vfx_code(first_line)
    first_line = trim(first_line or "")
    return first_line:match("^[%u%d_%-]+_XXXX$") ~= nil or first_line:match("^[%u%d_%-]+_%d%d%d%d$") ~= nil
end

local function is_vfx_title(title_name, first_line)
    if lower(title_name):find(lower(CONFIG.TITLE_MATCH), 1, true) then return true end
    if looks_like_vfx_code(first_line) then return true end
    return false
end

local function derive_synced_title_name(old_title_name, old_code, new_code)
    old_title_name = old_title_name or ""
    if old_title_name ~= "" then
        local replaced, n = old_title_name:gsub("^" .. escape_lua_pattern(old_code), new_code, 1)
        if n > 0 then return replaced end
        if old_title_name:find("VFX NAMING", 1, true) then
            return new_code .. " - VFX NAMING"
        end
    end
    return new_code .. " - VFX NAMING"
end

local function patch_title_open_tag(open_tag, old_title_name, new_title_name)
    local old_attr = old_title_name ~= "" and ('name="' .. escape_xml_attr(old_title_name) .. '"') or nil
    local new_attr = 'name="' .. escape_xml_attr(new_title_name) .. '"'
    if old_attr then
        local replaced, n = open_tag:gsub(escape_lua_pattern(old_attr), new_attr, 1)
        if n > 0 then return replaced, true end
    end
    local replaced, n = open_tag:gsub("<title%s+", "<title " .. new_attr .. " ", 1)
    if n > 0 then return replaced, true end
    return open_tag, false
end

local function parse_vfx_titles(xml)
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
            local abs_time = resolved_abs_time(parent, attrs)
            local start_val = parse_fraction(attrs.start) or 0
            local duration_val = parse_fraction(attrs.duration) or 0
            local node = {
                tag = tag_name,
                attrs = attrs,
                abs_time = abs_time,
                start = start_val,
                duration = duration_val,
                open_start = s,
                open_end = e,
            }
            if not is_self_closing then stack[#stack+1] = node end
        end

        if is_closing then
            local node = stack[#stack]
            if node and node.tag == tag_name then
                stack[#stack] = nil
                if node.tag == "title" then
                    local title_name = node.attrs.name or ""
                    local inner = xml:sub(node.open_end + 1, s - 1)
                    local full_text = extract_text_from_inner(inner)
                    local lines = split_nonempty_lines(full_text)
                    local first_line = lines[1] or ""
                    if is_vfx_title(title_name, first_line) then
                        titles[#titles+1] = {
                            title_name = title_name,
                            open_tag = xml:sub(node.open_start, node.open_end),
                            open_tag_start = node.open_start,
                            open_tag_end = node.open_end,
                            first_line = first_line,
                            full_text = full_text,
                            inner = inner,
                            timeline_time = node.abs_time + (node.duration / 2.0),
                            duration = node.duration,
                            inner_start = node.open_end + 1,
                            inner_end = s - 1,
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

local function sanity_check_titles(titles)
    if #titles == 0 then return false, "No VFX titles found" end
    for i, t in ipairs(titles) do
        if t.timeline_time < CONFIG.MIN_REASONABLE_TIME or t.timeline_time > CONFIG.MAX_REASONABLE_TIME then
            return false, string.format("Unreasonable parsed time for %s: %s", t.first_line, fmt_seconds(t.timeline_time))
        end
        if i > 1 then
            local gap = t.timeline_time - titles[i-1].timeline_time
            if gap > CONFIG.MAX_REASONABLE_GAP then
                return false, string.format("Suspiciously large gap between %s and %s: %s",
                    titles[i-1].first_line, t.first_line, fmt_seconds(gap))
            end
        end
    end
    return true, "ok"
end

local function pad4(n)
    return string.format("%04d", tonumber(n) or 0)
end

local function compute_renumber_plan(titles)
    local counters = {}
    local plan = {}

    for _, t in ipairs(titles) do
        local base = t.first_line:match("^(.-)_" .. escape_lua_pattern(CONFIG.PLACEHOLDER) .. "$")
        if base then
            local next_num = counters[base]
            if not next_num then
                next_num = CONFIG.START
            else
                next_num = next_num + CONFIG.STEP
            end
            counters[base] = next_num

            plan[#plan+1] = {
                title = t,
                base = base,
                old_code = t.first_line,
                new_code = base .. "_" .. pad4(next_num),
            }
        end
    end
    return plan
end

local function patch_title_inner(inner, old_code, new_code)
    local escaped_old = escape_xml_text(old_code)
    local escaped_new = escape_xml_text(new_code)

    local replaced, n = inner:gsub(escape_lua_pattern(escaped_old), escaped_new, 1)
    if n > 0 then return replaced, true end

    replaced, n = inner:gsub(escape_lua_pattern(old_code), new_code, 1)
    if n > 0 then return replaced, true end

    return inner, false
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

local function cleanup_temp_files(export_path, patched_path)
    if CONFIG.CLEANUP_EXPORT_TRIES then delete_file(export_path) end
    if CONFIG.CLEANUP_TEMP_AFTER_IMPORT and not CONFIG.KEEP_PATCHED_COPY then
        delete_file(patched_path)
    end
end

local function main()
    local base = tmp_base()
    local source_export_path = base .. "_source_export.fcpxml"
    local patched_path = base .. "_patched.fcpxml"

    export_current_fcpxml(source_export_path)
    local source_xml = read_file(source_export_path)
    local titles = parse_vfx_titles(source_xml)

    log("Parsed VFX titles: " .. tostring(#titles))
    for i, t in ipairs(titles) do
        if i > math.min(#titles, CONFIG.LOG_LIMIT) then break end
        log(string.format('title[%02d] t=%s first="%s"', i, fmt_seconds(t.timeline_time), t.first_line))
    end

    local ok_sanity, why = sanity_check_titles(titles)
    if not ok_sanity then
        error("Source export sanity check failed: " .. tostring(why))
    end

    local plan = compute_renumber_plan(titles)
    log("Titles matching _" .. CONFIG.PLACEHOLDER .. ": " .. tostring(#plan))
    for i, item in ipairs(plan) do
        if i > math.min(#plan, CONFIG.LOG_LIMIT) then break end
        log(string.format('plan[%02d] %s -> %s', i, item.old_code, item.new_code))
    end

    if CONFIG.DRY_RUN_PARSE then
        if CONFIG.CLEANUP_EXPORT_TRIES then delete_file(source_export_path) end
        if sk and sk.toast then sk.toast("VFX Auto Naming parse dry run complete", 4) end
        return
    end

    local replacements = {}
    local replaced_count = 0
    local renamed_title_count = 0
    for _, item in ipairs(plan) do
        local patched_inner, changed_inner = patch_title_inner(item.title.inner, item.old_code, item.new_code)
        local new_title_name = derive_synced_title_name(item.title.title_name, item.old_code, item.new_code)
        local patched_open_tag, changed_name = patch_title_open_tag(item.title.open_tag, item.title.title_name, new_title_name)

        if changed_inner then
            replaced_count = replaced_count + 1
            replacements[#replacements+1] = {
                start_pos = item.title.inner_start,
                end_pos = item.title.inner_end,
                replacement = patched_inner,
            }
        else
            log('WARN could not patch title text for "' .. tostring(item.old_code) .. '"')
        end

        if changed_name then
            renamed_title_count = renamed_title_count + 1
            replacements[#replacements+1] = {
                start_pos = item.title.open_tag_start,
                end_pos = item.title.open_tag_end,
                replacement = patched_open_tag,
            }
        else
            log('WARN could not patch title name for "' .. tostring(item.title.title_name) .. '"')
        end
    end

    table.sort(replacements, function(a,b) return a.start_pos > b.start_pos end)
    local patched = source_xml
    for _, r in ipairs(replacements) do
        patched = patched:sub(1, r.start_pos - 1) .. r.replacement .. patched:sub(r.end_pos + 1)
    end

    local prefixed_count = 0
    patched, prefixed_count = add_project_prefix(patched)
    log("Patched title text count: " .. tostring(replaced_count))
    log("Patched title name count: " .. tostring(renamed_title_count))
    log("Project prefix applications: " .. tostring(prefixed_count))

    write_file(patched_path, patched)
    log("Patched copy written to: " .. patched_path)

    if CONFIG.DRY_RUN_XML then
        log("XML dry run complete; no import performed")
        return
    end

    if CONFIG.AUTO_IMPORT then
        local res = import_patched_xml(patched)
        log("Import result: " .. tostring(res and res.status or "ok"))
        cleanup_temp_files(source_export_path, patched_path)
    else
        log("AUTO_IMPORT=false; patched XML created only")
    end

    if sk and sk.toast then sk.toast("VFX Auto Naming finished", 5) end
end

local ok, err = pcall(main)
if not ok then
    log("ERROR: " .. tostring(err))
    if sk and sk.toast then sk.toast("VFX Auto Naming failed: " .. tostring(err), 6) end
end
