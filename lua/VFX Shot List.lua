-- VFX Shot List.lua
-- Controller-first implementation for a timeline-based VFX shot list workflow.
--
-- What this version does reliably:
--   1) Exports current project FCPXML
--   2) Parses VFX markers from the timeline
--   3) Enters View > Playback > Play Full Screen
--   4) Immediately pauses/toggles playback
--   5) Seeks through markers in order
--   6) Captures the viewer for each marker through SpliceKit's GPU/window capture RPC
--   7) Writes a manifest TSV for Excel generation

local CONFIG = {
    MARKER_PREFIX_PATTERN = "^[%u%d_]+_%d%d%d%d$",
    TEMP_BASENAME = "vfx_shot_list",
    -- Timing profile:
    -- Set FAST_MODE = true to use more aggressive timing.
    FAST_MODE = true,
    SAFE_DWELL_AFTER_SEEK_SEC = 0.22,
    SAFE_DWELL_BETWEEN_MARKERS_SEC = 0.18,
    FAST_DWELL_AFTER_SEEK_SEC = 0.18,
    FAST_DWELL_BETWEEN_MARKERS_SEC = 0.04,

    ENABLE_VIEWER_CAPTURE = true,

    -- Best-effort fullscreen playback routing.
    ENTER_PLAY_FULL_SCREEN_MENU = {"View", "Playback", "Play Full Screen"},
    TOGGLE_PLAY_MENU = {"View", "Playback", "Play Full Screen"},
    PAUSE_TOGGLE_MENU = {"View", "Playback", "Play"},

    MANIFEST_EXT = ".tsv",
    PROGRESS_EXT = ".progress.tsv",
    DONE_EXT = ".done",
}

local CLIP_LIKE = {
    ["audio"] = true, ["video"] = true, ["clip"] = true, ["title"] = true,
    ["mc-clip"] = true, ["ref-clip"] = true, ["sync-clip"] = true,
    ["asset-clip"] = true, ["audition"] = true, ["gap"] = true, ["spine"] = true,
}

local MEDIA_SEGMENT_LIKE = {
    ["audio"] = true, ["video"] = true, ["clip"] = true,
    ["mc-clip"] = true, ["ref-clip"] = true, ["sync-clip"] = true,
    ["asset-clip"] = true,
}

local function log(lines, msg)
    print("[vfx-shot-list] " .. tostring(msg))
    lines[#lines + 1] = tostring(msg)
end

local function trim(s)
    return (s and s:gsub("^%s+", ""):gsub("%s+$", "")) or ""
end

local function state_dir()
    local home = os.getenv("HOME") or "/tmp"
    return home .. "/Library/Application Support/SpliceKit/VFXShotList"
end

local function parse_fraction(str)
    if not str then return nil end
    local a, b = str:match("^([%-%.%d]+)/([%-%.%d]+)s$")
    if a and b then
        a, b = tonumber(a), tonumber(b)
        if a and b and b ~= 0 then return a / b end
    end
    local n = str:match("^([%-%.%d]+)s$")
    if n then return tonumber(n) end
    return nil
end

local function fmt_seconds(s)
    s = tonumber(s) or 0
    local rounded = math.floor(s * 1000000 + 0.5) / 1000000
    local text = string.format("%.6f", rounded):gsub("0+$", ""):gsub("%.$", "")
    if text == "" then text = "0" end
    return text .. "s"
end

local function fmt_hms_seconds(sec)
    sec = tonumber(sec) or 0
    local total_frames = math.floor(sec * 24 + 0.5) -- display only; not authoritative TC
    local hh = math.floor(total_frames / (24 * 3600))
    local rem = total_frames % (24 * 3600)
    local mm = math.floor(rem / (24 * 60))
    rem = rem % (24 * 60)
    local ss = math.floor(rem / 24)
    local ff = rem % 24
    return string.format("%02d:%02d:%02d:%02d", hh, mm, ss, ff)
end

local function frames_to_tc(total_frames, fps)
    local hh = math.floor(total_frames / (fps * 3600))
    local rem = total_frames % (fps * 3600)
    local mm = math.floor(rem / (fps * 60))
    rem = rem % (fps * 60)
    local ss = math.floor(rem / fps)
    local ff = rem % fps
    return string.format("%02d:%02d:%02d:%02d", hh, mm, ss, ff)
end

local function frames_to_drop_frame_tc(total_frames, fps)
    local drop_frames = math.floor((fps * 0.0666666667) + 0.5)
    if drop_frames <= 0 then return frames_to_tc(total_frames, fps) end
    local frames_per_minute = (fps * 60) - drop_frames
    local frames_per_10_minutes = (fps * 600) - (drop_frames * 9)
    local ten_minute_chunks = math.floor(total_frames / frames_per_10_minutes)
    local remainder = total_frames % frames_per_10_minutes
    local extra_dropped = (drop_frames * 9 * ten_minute_chunks)
        + (drop_frames * math.floor(math.max(0, remainder - drop_frames) / frames_per_minute))
    return frames_to_tc(total_frames + extra_dropped, fps)
end

local function fmt_source_tc_seconds(sec, frame_duration, tc_format)
    sec = tonumber(sec) or 0
    frame_duration = tonumber(frame_duration) or (1 / 24)
    if frame_duration <= 0 then
        frame_duration = 1 / 24
    end

    local fps = math.floor((1 / frame_duration) + 0.5)
    if fps <= 0 then fps = 24 end

    local total_frames = math.floor((sec / frame_duration) + 0.000001)
    if trim(tc_format or "") == "DF" and (fps == 30 or fps == 60) then
        return frames_to_drop_frame_tc(total_frames, fps)
    end
    return frames_to_tc(total_frames, fps)
end

local function decode_uri_component(s)
    s = tostring(s or "")
    return (s:gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end))
end

local function basename_from_src(src)
    src = trim(src or "")
    if src == "" then return "" end
    src = src:gsub("^file://localhost", "")
    src = src:gsub("^file://", "")
    src = src:gsub("^file:", "")
    src = src:gsub("%?.*$", "")
    src = decode_uri_component(src)
    local name = src:match("([^/]+)$")
    return name or src
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

local function mkdir_p(path)
    -- SpliceKit disables os.execute for safety. The native Turnover plugin
    -- creates these capture folders before this Lua controller runs.
    return path
end

local function append_file(path, content)
    local f, err = io.open(path, "ab")
    if not f then error("Cannot append file: " .. tostring(err)) end
    f:write(content)
    f:close()
end

local function tsv_escape(value)
    value = tostring(value or "")
    value = value:gsub("\\", "\\\\")
    value = value:gsub("\t", "\\t")
    value = value:gsub("\r", "\\r")
    value = value:gsub("\n", "\\n")
    return value
end

local function unescape_xml(s)
    if not s then return "" end
    return (s:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&apos;", "'"):gsub("&amp;", "&"))
end

local function split_nonempty_lines(s)
    local out = {}
    if not s then return out end
    s = s:gsub("\226\128\168", "\n"):gsub("\r\n", "\n"):gsub("\r", "\n")
    for line in s:gmatch("([^\n]*)\n?") do
        line = trim(line)
        if line ~= "" then out[#out + 1] = line end
    end
    return out
end

local function extract_title_text(inner)
    local parts = {}
    inner = inner or ""
    for txt in inner:gmatch("<text%-style[^>]*>(.-)</text%-style>") do
        local cleaned = trim(unescape_xml(txt))
        if cleaned ~= "" then parts[#parts + 1] = cleaned end
    end
    if #parts == 0 then
        for txt in inner:gmatch("<text[^>]*>(.-)</text>") do
            local cleaned = trim(unescape_xml((txt:gsub("<[^>]+>", ""))))
            if cleaned ~= "" then parts[#parts + 1] = cleaned end
        end
    end
    return table.concat(parts, "\n")
end

local function is_vfx_title(title_name, title_text)
    local lower_name = string.lower(title_name or "")
    local lines = split_nonempty_lines(title_text)
    local first_line = lines[1] or ""
    if lower_name:find("vfx naming", 1, true) then return true end
    if first_line:match("^[%u%d_%-]+_%d%d%d%d$") then return true end
    if first_line:match("^[%u%d_%-]+_XXXX$") then return true end
    return false
end

local function derive_vfx_title_info(title_name, title_text)
    local lines = split_nonempty_lines(title_text)
    local first_line = lines[1] or ""
    local shot_code_from_name = title_name:match("^([%u%d_%-]+)%s*%-%s*VFX%s+NAMING$")
    local vfx_number = trim(first_line) ~= "" and trim(first_line) or shot_code_from_name or trim(title_name)
    local note_lines = {}
    for i = 2, #lines do
        local cleaned = trim(lines[i])
        if cleaned ~= "" then note_lines[#note_lines + 1] = cleaned end
    end
    return vfx_number, table.concat(note_lines, "\n")
end

local function ensure_worker_ready(lines)
    local ready_path = state_dir() .. "/VFX_Shot_List_Worker_Ready.flag"
    if file_exists(ready_path) then
        log(lines, "Capture worker already ready: " .. ready_path)
        return true
    end
    log(lines, "No external capture worker flag found; using Turnover fullscreen capture.")
    return true
end


local function parse_attrs(attr_str)
    local attrs = {}
    if not attr_str then return attrs end
    for k, v in attr_str:gmatch('([%w:_-]+)%s*=%s*"([^"]*)"') do
        attrs[k] = v
    end
    return attrs
end

local function parse_metadata_blob(blob)
    local picked = {}
    local ordered = {}
    blob = blob or ""

    local function remember(label, value, score)
        label = trim(label or "")
        value = trim(value or "")
        score = tonumber(score) or 0
        if label == "" or value == "" then return end
        local key = label:lower()
        local existing = picked[key]
        if existing and existing.score > score then return end
        if not existing then ordered[#ordered + 1] = key end
        picked[key] = {label = label, value = value, score = score}
    end

    local function maybe_pick(attrs)
        local key = trim(attrs.key or "")
        local value = trim(attrs.value or "")
        local display = trim(attrs.displayName or "")
        local source = trim(attrs.source or "")
        local lower_key = key:lower()
        local lower_display = display:lower()
        local lower_source = source:lower()
        local lower_value = value:lower()

        local looks_like_shot_note =
            lower_key:find("shot%-note", 1, false) or
            lower_display:find("shot%-note", 1, false) or
            lower_key:find("shot_note", 1, true) or
            lower_display:find("shot_note", 1, true)

        local looks_custom =
            lower_source == "custom" or
            lower_key:find("custom", 1, true) or
            lower_display:find("custom", 1, true)

        local looks_user_note =
            lower_key:find("note", 1, true) or
            lower_display:find("note", 1, true) or
            lower_value:find("shot", 1, true)

        if looks_like_shot_note then
            remember(display ~= "" and display or key, value, 100)
        elseif looks_custom and looks_user_note then
            remember(display ~= "" and display or key, value, 80)
        elseif looks_custom then
            remember(display ~= "" and display or key, value, 50)
        end
    end

    for attr_str in blob:gmatch("<md%s+([^>]-)/>") do
        maybe_pick(parse_attrs(attr_str))
    end
    for attr_str in blob:gmatch("<md%s+([^>]-)>.-</md>") do
        maybe_pick(parse_attrs(attr_str))
    end

    local out = {}
    for _, key in ipairs(ordered) do
        local item = picked[key]
        if item then
            out[#out + 1] = item.label .. ": " .. item.value
        end
    end
    return table.concat(out, " | ")
end

local function parse_formats(xml)
    local formats = {}

    local function remember(attrs)
        local id = trim(attrs.id or "")
        if id == "" then return end
        local frame_duration = parse_fraction(attrs.frameDuration)
        formats[id] = {
            id = id,
            frame_duration = frame_duration,
        }
    end

    for attr_str in xml:gmatch("<format%s+([^>]-)/>") do
        remember(parse_attrs(attr_str))
    end
    for attr_str in xml:gmatch("<format%s+([^>]-)>.-</format>") do
        remember(parse_attrs(attr_str))
    end

    return formats
end

local function parse_assets(xml, format_map)
    local assets = {}

    local function remember(attrs, body)
        local id = trim(attrs.id or "")
        if id == "" then return end
        local src = trim(attrs.src or "")
        local name = trim(attrs.name or "")
        local format_id = trim(attrs.format or "")
        local format_info = format_map and format_map[format_id] or nil
        assets[id] = {
            id = id,
            src = src,
            filename = basename_from_src(src),
            name = name,
            start = parse_fraction(attrs.start) or 0,
            hasVideo = trim(attrs.hasVideo or ""),
            metadata = parse_metadata_blob(body or ""),
            format_id = format_id,
            frame_duration = (format_info and format_info.frame_duration) or (1 / 24),
        }
    end

    for attr_str, body in xml:gmatch("<asset%s+([^>]-)>(.-)</asset>") do
        remember(parse_attrs(attr_str), body)
    end
    for attr_str in xml:gmatch("<asset%s+([^>]-)/>") do
        remember(parse_attrs(attr_str), "")
    end

    return assets
end

local function parse_effects(xml)
    local effects = {}

    local function remember(attrs)
        local id = trim(attrs.id or "")
        if id == "" then return end
        effects[id] = trim(attrs.name or attrs.uid or id)
    end

    for attr_str in xml:gmatch("<effect%s+([^>]-)/>") do
        remember(parse_attrs(attr_str))
    end
    for attr_str in xml:gmatch("<effect%s+([^>]-)>.-</effect>") do
        remember(parse_attrs(attr_str))
    end

    return effects
end

local function context_timeline_start(parent_ctx, attrs)
    local parent_tl = parent_ctx and parent_ctx.timeline_start or 0
    local my_offset = parse_fraction(attrs.offset)
    if my_offset == nil then
        return parent_tl
    end
    if parent_ctx
        and parent_ctx.tag == "spine"
        and trim(parent_ctx.attrs and parent_ctx.attrs.lane or "") ~= ""
        and my_offset < (tonumber(parent_ctx.start) or 0) then
        return parent_tl + my_offset
    end
    local parent_start = parent_ctx and tonumber(parent_ctx.start) or 0
    return parent_tl + my_offset - parent_start
end

local function export_current_fcpxml(path)
    local res = sk.rpc("fcpxml.export", { path = path })
    if res and res.error then error("fcpxml.export failed: " .. tostring(res.error)) end
    if not file_exists(path) then error("Export did not create file: " .. path) end
end

local function find_first_child_ref(blob)
    if not blob or blob == "" then return nil end
    local ref = blob:match("<video[^>]-ref=\"([^\"]+)\"")
        or blob:match("<asset%-clip[^>]-ref=\"([^\"]+)\"")
        or blob:match("<ref%-clip[^>]-ref=\"([^\"]+)\"")
    return ref
end

local function resolve_source_info(node, asset_map, body)
    local ref = trim((node.attrs and node.attrs.ref) or "")
    if ref == "" then
        ref = trim(find_first_child_ref(body) or "")
    end

    local asset = ref ~= "" and asset_map[ref] or nil
    local source_filename = ""
    if asset and asset.filename ~= "" then
        source_filename = asset.filename
    elseif asset and asset.name ~= "" then
        source_filename = asset.name
    else
        source_filename = trim((node.attrs and node.attrs.name) or "")
    end

    local source_tc_seconds = node.start or 0
    if (not node.attrs or not node.attrs.start) and asset and asset.start then
        source_tc_seconds = asset.start
    end

    local custom_metadata = parse_metadata_blob(body)
    if custom_metadata == "" and asset and asset.metadata then
        custom_metadata = asset.metadata
    elseif custom_metadata ~= "" and asset and asset.metadata and asset.metadata ~= "" then
        custom_metadata = custom_metadata .. " | " .. asset.metadata
    end

    return {
        ref = ref,
        asset = asset,
        source_filename = source_filename,
        source_tc_seconds = source_tc_seconds,
        source_tc_format = trim((node and node.attrs and (node.attrs.tcFormat or node.attrs._effective_tcFormat)) or ""),
        source_tc = fmt_source_tc_seconds(source_tc_seconds, asset and asset.frame_duration or nil, trim((node and node.attrs and (node.attrs.tcFormat or node.attrs._effective_tcFormat)) or "")),
        source_frame_duration = asset and asset.frame_duration or (1 / 24),
        custom_metadata = custom_metadata,
    }
end

local function is_original_video_segment(segment_node, source)
    local tag = trim(segment_node and segment_node.tag or ""):lower()
    local attrs = (segment_node and segment_node.attrs) or {}
    local role = trim(attrs._effective_role or attrs.role or ""):lower()
    local asset = source and source.asset or nil
    local filename = trim(source and source.source_filename or "")

    if tag == "audio" then
        return false
    end

    if role ~= "" and not role:match("^video") then
        return false
    end

    if tag == "sync-clip" or tag == "mc-clip" or tag == "audition" or tag == "spine" or tag == "gap" then
        return false
    end

    if not asset then
        return false
    end

    if trim(asset.hasVideo or "") ~= "1" then
        return false
    end

    if filename == "" then
        return false
    end

    return true
end

local function is_real_media_source(source)
    local asset = source and source.asset or nil
    local filename = trim(source and source.source_filename or "")
    if not asset then return false end
    if trim(asset.hasVideo or "") ~= "1" then return false end
    if filename == "" then return false end
    return true
end

local function is_generator_source(source)
    local asset = source and source.asset or nil
    local ref = trim(source and source.ref or ""):lower()
    local filename = trim(source and source.source_filename or ""):lower()
    local asset_name = trim(asset and asset.name or ""):lower()

    if ref == "r3" and filename == "custom" then
        return true
    end
    if filename == "custom" or asset_name == "custom" then
        return true
    end
    if filename:match("%.motn$") or filename:match("%.moti$") or filename:match("%.moef$") then
        return true
    end
    return false
end

local parse_time_map_bounds

local function has_speed_change_in_body(body)
    local time_map = parse_time_map_bounds(body or "")
    if not time_map then
        return false
    end
    local timeline_span = tonumber(time_map.timeline_span) or 0
    local source_span = tonumber(time_map.source_span) or 0
    return (tonumber(time_map.point_count) or 0) > 2 or math.abs(source_span - timeline_span) > 0.0005
end

local function body_uses_non_video_role(body)
    body = body or ""
    for _, role in body:gmatch("<[%w:_-]+[^>]-role=\"([^\"]+)\"") do
        local lower = trim(role or ""):lower()
        if lower ~= "" and not lower:match("^video") then
            return true
        end
    end
    return false
end

local function has_nested_media_children(body)
    body = body or ""
    return body:find("<video[%s>]")
        or body:find("<audio[%s>]")
        or body:find("<asset%-clip[%s>]")
        or body:find("<clip[%s>]")
        or body:find("<ref%-clip[%s>]")
        or body:find("<sync%-clip[%s>]")
        or body:find("<mc%-clip[%s>]")
end

local function has_nested_container_children(body)
    body = body or ""
    return body:find("<asset%-clip[%s>]")
        or body:find("<clip[%s>]")
        or body:find("<ref%-clip[%s>]")
        or body:find("<sync%-clip[%s>]")
        or body:find("<mc%-clip[%s>]")
end

local function direct_media_child_uses_non_video_role(body)
    body = body or ""
    local pos = 1
    local depth = 0

    while true do
        local s, e, closing, tag_name, attr_str, self_close = body:find("<(%/?)([%w:_-]+)(.-)(/?)>", pos)
        if not s then break end
        local is_closing = (closing == "/")
        local is_self_closing = (self_close == "/")

        if not is_closing then
            if depth == 0 and MEDIA_SEGMENT_LIKE[tag_name] then
                local attrs = parse_attrs(attr_str)
                local role = trim(attrs.role or ""):lower()
                if role ~= "" and not role:match("^video") then
                    return true
                end
            end
            if not is_self_closing then
                depth = depth + 1
            end
        else
            if depth > 0 then
                depth = depth - 1
            end
        end

        pos = e + 1
    end

    return false
end

local function unique_join(items, sep)
    local seen = {}
    local ordered = {}
    for _, item in ipairs(items or {}) do
        local value = trim(item or "")
        if value ~= "" and not seen[value] then
            seen[value] = true
            ordered[#ordered + 1] = value
        end
    end
    return table.concat(ordered, sep or ", ")
end

local function join_lines(items)
    local out = {}
    for _, item in ipairs(items or {}) do
        local value = trim(item or "")
        if value ~= "" then
            out[#out + 1] = value
        end
    end
    return table.concat(out, "\n")
end

local function canonical_source_group_key(source_key, source_filename)
    local filename = trim(source_filename or "")
    if filename ~= "" then
        return filename:lower()
    end
    return trim(source_key or ""):lower()
end

local function split_metadata_items(text)
    local items = {}
    text = trim(text or "")
    if text == "" then return items end
    for piece in text:gmatch("([^|]+)") do
        local value = trim(piece)
        if value ~= "" then
            items[#items + 1] = value
        end
    end
    return items
end

parse_time_map_bounds = function(body)
    body = body or ""
    local time_map_body = body:match("<timeMap[^>]*>(.-)</timeMap>")
    if not time_map_body then return nil end

    local points = {}
    for attr_str in time_map_body:gmatch("<timept%s+([^>]-)/>") do
        local attrs = parse_attrs(attr_str)
        local timeline_time = parse_fraction(attrs.time)
        local source_time = parse_fraction(attrs.value)
        if timeline_time and source_time then
            points[#points + 1] = {
                timeline_time = timeline_time,
                source_time = source_time,
            }
        end
    end

    if #points < 2 then return nil end
    table.sort(points, function(a, b) return a.timeline_time < b.timeline_time end)

    local first = points[1]
    local last = points[#points]
    local timeline_span = (last.timeline_time or 0) - (first.timeline_time or 0)
    local source_span = (last.source_time or 0) - (first.source_time or 0)
    local speed_percent = nil
    if timeline_span > 0 then
        speed_percent = (source_span / timeline_span) * 100
    end

    return {
        points = points,
        point_count = #points,
        source_first = first.source_time or 0,
        source_last = last.source_time or 0,
        timeline_first = first.timeline_time or 0,
        timeline_last = last.timeline_time or 0,
        source_span = source_span,
        timeline_span = timeline_span,
        speed_percent = speed_percent,
    }
end

local function interpolate_time_map_source(time_map, timeline_time)
    if not time_map or type(time_map.points) ~= "table" or #time_map.points < 2 or timeline_time == nil then
        return nil
    end

    local points = time_map.points

    local function interpolate_between(a, b, t)
        local timeline_span = (b.timeline_time or 0) - (a.timeline_time or 0)
        if timeline_span == 0 then
            return a.source_time or 0
        end
        local ratio = (t - (a.timeline_time or 0)) / timeline_span
        return (a.source_time or 0) + (((b.source_time or 0) - (a.source_time or 0)) * ratio)
    end

    if timeline_time <= (points[1].timeline_time or 0) then
        return interpolate_between(points[1], points[2], timeline_time)
    end

    for i = 1, (#points - 1) do
        local a = points[i]
        local b = points[i + 1]
        local ta = a.timeline_time or 0
        local tb = b.timeline_time or 0
        if timeline_time >= ta and timeline_time <= tb then
            return interpolate_between(a, b, timeline_time)
        end
    end

    return interpolate_between(points[#points - 1], points[#points], timeline_time)
end

local function collect_effect_names(body, effect_map)
    local names = {}
    body = body or ""
    local function remember(effect_ref)
        local name = trim(effect_map[trim(effect_ref)] or trim(effect_ref))
        local lower = name:lower()
        if name == "" then return end
        if lower:find("burn%-in", 1, false) then return end
        if lower:find("timecode", 1, true) then return end
        if lower:find("color correction", 1, true) then return end
        names[#names + 1] = name
    end
    for effect_ref in body:gmatch("<filter%-video[^>]-ref=\"([^\"]+)\"") do
        remember(effect_ref)
    end
    for effect_ref in body:gmatch("<filter%-audio[^>]-ref=\"([^\"]+)\"") do
        remember(effect_ref)
    end
    for effect_ref in body:gmatch("<effect[^>]-ref=\"([^\"]+)\"") do
        remember(effect_ref)
    end
    return names
end

local function collect_top_level_effect_names(body, effect_map)
    local names = {}
    local pos = 1
    local depth = 0

    local function remember_from_attrs(attrs)
        local effect_ref = trim((attrs and attrs.ref) or "")
        local name = trim(effect_map[effect_ref] or effect_ref)
        local lower = name:lower()
        if name == "" then return end
        if lower:find("burn%-in", 1, false) then return end
        if lower:find("timecode", 1, true) then return end
        if lower:find("color correction", 1, true) then return end
        names[#names + 1] = name
    end

    while true do
        local s, e, closing, tag_name, attr_str, self_close = body:find("<(%/?)([%w:_-]+)(.-)(/?)>", pos)
        if not s then break end
        local is_closing = (closing == "/")
        local is_self_closing = (self_close == "/")

        if not is_closing then
            if depth == 0 and (tag_name == "filter-video" or tag_name == "filter-audio") then
                remember_from_attrs(parse_attrs(attr_str))
            end
            if not is_self_closing then
                depth = depth + 1
            end
        else
            if depth > 0 then
                depth = depth - 1
            end
        end

        pos = e + 1
    end

    return names
end

local collect_body_details_for_range

local function collect_body_details(node, body, asset_map, effect_map)
    return collect_body_details_for_range(node, body, asset_map, effect_map, nil, nil)
end

collect_body_details_for_range = function(node, body, asset_map, effect_map, visible_start_override, visible_end_override)
    local segments = {}
    local stack = {}
    local aggregate_effects = {}
    local has_retime = false
    local pending_retime_keys = {}
    local pending_effects_by_source = {}
    local displayed_source_keys = {}
    local pos = 1
    local body_visible_start = visible_start_override
    local body_visible_end = visible_end_override
    if body_visible_start == nil or body_visible_end == nil then
        body_visible_start = tonumber(node and node.timeline_start) or 0
        body_visible_end = body_visible_start + (tonumber(node and node.duration) or 0)
    end

    local function remember_pending_effects(source_key, effect_names)
        source_key = trim(source_key or "")
        if source_key == "" then return end
        if not pending_effects_by_source[source_key] then
            pending_effects_by_source[source_key] = {}
        end
        for _, effect_name in ipairs(effect_names or {}) do
            pending_effects_by_source[source_key][#pending_effects_by_source[source_key] + 1] = effect_name
        end
    end

    local function add_segment_from_node(segment_node, segment_body)
        local source = resolve_source_info(segment_node, asset_map, segment_body or "")
        local source_key = trim(source.ref or "") ~= "" and trim(source.ref or "") or trim(source.source_filename or "")
        local speed_change_here = is_real_media_source(source) and has_speed_change_in_body(segment_body or "")
        local candidate_effects = collect_top_level_effect_names(segment_body or "", effect_map)
        local tag = trim(segment_node and segment_node.tag or ""):lower()
        local has_own_ref = trim((segment_node and segment_node.attrs and segment_node.attrs.ref) or "") ~= ""

        if speed_change_here and source_key ~= "" then
            pending_retime_keys[source_key] = true
        end
        if is_real_media_source(source) and not is_generator_source(source) and #candidate_effects > 0 then
            remember_pending_effects(source_key, candidate_effects)
        end

        if not is_original_video_segment(segment_node, source) then
            return false
        end
        if (tag == "clip" or tag == "asset-clip" or tag == "ref-clip")
            and not has_own_ref
            and has_nested_container_children(segment_body or "") then
            return false
        end
        if direct_media_child_uses_non_video_role(segment_body or "") then
            return false
        end
        local segment_timeline_start = tonumber(segment_node.timeline_start) or 0
        local segment_timeline_end = segment_timeline_start + (tonumber(segment_node.duration) or 0)
        local overlap_start = math.max(segment_timeline_start, body_visible_start)
        local overlap_end = math.min(segment_timeline_end, body_visible_end)

        if overlap_end <= overlap_start then
            return false
        end

        local overlap_in_delta = overlap_start - segment_timeline_start
        local overlap_out_delta = overlap_end - segment_timeline_start
        local local_source_in_time = (segment_node.start or source.source_tc_seconds or 0) + overlap_in_delta
        local local_source_out_time = (segment_node.start or source.source_tc_seconds or 0) + overlap_out_delta

        local source_in = source.source_tc_seconds or 0
        local source_out = source_in + (overlap_end - overlap_start)
        local time_map = parse_time_map_bounds(segment_body or "")
        if time_map then
            source_in = interpolate_time_map_source(time_map, local_source_in_time) or source_in
            source_out = interpolate_time_map_source(time_map, local_source_out_time) or source_out
        else
            source_in = (source.source_tc_seconds or 0) + overlap_in_delta
            source_out = (source.source_tc_seconds or 0) + overlap_out_delta
        end

        if source_key ~= "" then
            displayed_source_keys[source_key] = true
            if pending_retime_keys[source_key] then
                has_retime = true
            end
            local pending_effects = pending_effects_by_source[source_key] or {}
            for _, effect_name in ipairs(pending_effects) do
                aggregate_effects[#aggregate_effects + 1] = effect_name
            end
        elseif speed_change_here then
            has_retime = true
        end

        segments[#segments + 1] = {
            source_key = source_key,
            timeline_start = overlap_start,
            timeline_end = overlap_end,
            source_filename = source.source_filename or "",
            source_in_seconds = source_in,
            source_out_seconds = source_out,
            source_frame_duration = source.source_frame_duration or (1 / 24),
            source_tc_format = source.source_tc_format or "",
            custom_metadata = source.custom_metadata or "",
        }
        return true
    end

    if MEDIA_SEGMENT_LIKE[node.tag] then
        add_segment_from_node(node, body)
    end

    while true do
        local s, e, closing, tag_name, attr_str, self_close = body:find("<(%/?)([%w:_-]+)(.-)(/?)>", pos)
        if not s then break end
        local is_closing = (closing == "/")
        local is_self_closing = (self_close == "/")

        if not is_closing then
            local attrs = parse_attrs(attr_str)
            local parent = stack[#stack]
            local timeline_start = context_timeline_start(parent or node, attrs)
            local explicit_role = trim(attrs.role or "")
            local parent_effective_role = parent and trim((parent.attrs and parent.attrs._effective_role) or parent.effective_role or "") or ""
            local effective_role = explicit_role ~= "" and explicit_role or parent_effective_role
            local explicit_tc_format = trim(attrs.tcFormat or "")
            local parent_effective_tc_format = parent and trim((parent.attrs and parent.attrs._effective_tcFormat) or parent.effective_tc_format or "") or ""
            local effective_tc_format = explicit_tc_format ~= "" and explicit_tc_format or parent_effective_tc_format
            attrs._effective_role = effective_role
            attrs._effective_tcFormat = effective_tc_format
            local child = {
                tag = tag_name,
                attrs = attrs,
                effective_role = effective_role,
                effective_tc_format = effective_tc_format,
                timeline_start = timeline_start,
                start = parse_fraction(attrs.start),
                duration = parse_fraction(attrs.duration) or 0,
                open_end = e + 1,
            }
            if child.start == nil then
                child.start = parent and tonumber(parent.start) or (tonumber(node and node.start) or 0)
            end

            if not is_self_closing then
                stack[#stack + 1] = child
            elseif MEDIA_SEGMENT_LIKE[tag_name] then
                add_segment_from_node(child, "")
            end
        else
            local child = stack[#stack]
            if child then
                if MEDIA_SEGMENT_LIKE[child.tag] then
                    local child_body = body:sub(child.open_end, s - 1)
                    add_segment_from_node(child, child_body)
                end
                stack[#stack] = nil
            end
        end

        pos = e + 1
    end

    for key, flagged in pairs(pending_retime_keys) do
        if flagged and displayed_source_keys[key] then
            has_retime = true
            break
        end
    end

    local first_segment = nil
    local last_segment = nil
    local source_groups = {}
    local source_order = {}
    for _, segment in ipairs(segments) do
        if (not first_segment)
            or (segment.timeline_start < first_segment.timeline_start)
            or (segment.timeline_start == first_segment.timeline_start and segment.timeline_end < first_segment.timeline_end) then
            first_segment = segment
        end
        if (not last_segment)
            or (segment.timeline_end > last_segment.timeline_end)
            or (segment.timeline_end == last_segment.timeline_end and segment.timeline_start > last_segment.timeline_start) then
            last_segment = segment
        end

        local group_key = canonical_source_group_key(segment.source_key, segment.source_filename)
        if group_key ~= "" then
            local group = source_groups[group_key]
            if not group then
                group = {
                    source_filename = trim(segment.source_filename or ""),
                    first_in_seconds = segment.source_in_seconds or 0,
                    last_out_seconds = segment.source_out_seconds or 0,
                    first_timeline_start = segment.timeline_start or 0,
                    source_frame_duration = segment.source_frame_duration or (1 / 24),
                    source_tc_format = segment.source_tc_format or "",
                    metadata_items = {},
                }
                for _, item in ipairs(split_metadata_items(segment.custom_metadata or "")) do
                    group.metadata_items[#group.metadata_items + 1] = item
                end
                source_groups[group_key] = group
                source_order[#source_order + 1] = group_key
            else
                if (segment.timeline_start or 0) < (group.first_timeline_start or 0) then
                    group.first_timeline_start = segment.timeline_start or 0
                    group.first_in_seconds = segment.source_in_seconds or group.first_in_seconds
                    if trim(segment.source_filename or "") ~= "" then
                        group.source_filename = trim(segment.source_filename or "")
                    end
                    if trim(segment.source_tc_format or "") ~= "" then
                        group.source_tc_format = trim(segment.source_tc_format or "")
                    end
                end
                if (segment.source_in_seconds or 0) < (group.first_in_seconds or 0) then
                    group.first_in_seconds = segment.source_in_seconds or group.first_in_seconds
                end
                if (segment.source_out_seconds or 0) > (group.last_out_seconds or 0) then
                    group.last_out_seconds = segment.source_out_seconds or group.last_out_seconds
                end
                for _, item in ipairs(split_metadata_items(segment.custom_metadata or "")) do
                    group.metadata_items[#group.metadata_items + 1] = item
                end
            end
        end
    end

    table.sort(source_order, function(a, b)
        local ga = source_groups[a]
        local gb = source_groups[b]
        local ta = ga and ga.first_timeline_start or 0
        local tb = gb and gb.first_timeline_start or 0
        if ta == tb then
            return (ga and ga.source_filename or a) < (gb and gb.source_filename or b)
        end
        return ta < tb
    end)

    local source_filename_lines = {}
    local source_tc_in_lines = {}
    local source_tc_out_lines = {}
    local metadata_lines = {}
    for _, key in ipairs(source_order) do
        local group = source_groups[key]
        if group then
            local frame_duration = tonumber(group.source_frame_duration) or (1 / 24)
            local tc_format = trim(group.source_tc_format or "")
            local inclusive_out_seconds = math.max((group.last_out_seconds or 0) - frame_duration, group.first_in_seconds or 0)
            local source_filename = trim(group.source_filename or "")
            source_filename_lines[#source_filename_lines + 1] = source_filename
            source_tc_in_lines[#source_tc_in_lines + 1] = fmt_source_tc_seconds(group.first_in_seconds or 0, frame_duration, tc_format)
            source_tc_out_lines[#source_tc_out_lines + 1] = fmt_source_tc_seconds(inclusive_out_seconds, frame_duration, tc_format)
            local metadata_text = unique_join(group.metadata_items or {}, " | ")
            if metadata_text ~= "" then
                if #source_order > 1 and source_filename ~= "" then
                    metadata_lines[#metadata_lines + 1] = source_filename .. ": " .. metadata_text
                else
                    metadata_lines[#metadata_lines + 1] = metadata_text
                end
            end
        end
    end

    local effects_text = unique_join(aggregate_effects, ", ")
    local metadata_text = join_lines(metadata_lines)

    local remark_parts = {}
    if has_retime then
        remark_parts[#remark_parts + 1] = "Speed Change"
    end
    if effects_text ~= "" then
        remark_parts[#remark_parts + 1] = "FX: " .. effects_text
    end

    return {
        first_segment = first_segment,
        last_segment = last_segment,
        has_displayable_segments = (#source_order > 0),
        source_keys = source_order,
        source_filename_text = join_lines(source_filename_lines),
        source_tc_in_text = join_lines(source_tc_in_lines),
        source_tc_out_text = join_lines(source_tc_out_lines),
        custom_metadata_text = metadata_text,
        remark = table.concat(remark_parts, " | "),
    }
end

local function collect_title_ranges(node, body)
    local titles = {}
    local stack = {}
    local pos = 1

    while true do
        local s, e, closing, tag_name, attr_str, self_close = body:find("<(%/?)([%w:_-]+)(.-)(/?)>", pos)
        if not s then break end
        local is_closing = (closing == "/")
        local is_self_closing = (self_close == "/")

        if not is_closing then
            local attrs = parse_attrs(attr_str)
            local parent = stack[#stack]
            local timeline_start = context_timeline_start(parent or node, attrs)
            local child = {
                tag = tag_name,
                attrs = attrs,
                timeline_start = timeline_start,
                start = parse_fraction(attrs.start),
                duration = parse_fraction(attrs.duration) or 0,
                open_end = e + 1,
            }
            if child.start == nil then
                child.start = parent and tonumber(parent.start) or (tonumber(node and node.start) or 0)
            end

            if not is_self_closing then
                stack[#stack + 1] = child
            elseif tag_name == "title" then
                local title_name = trim(attrs.name or "")
                if is_vfx_title(title_name, "") then
                    local vfx_number, note = derive_vfx_title_info(title_name, "")
                    titles[#titles + 1] = {
                        name = title_name,
                        vfx_number = vfx_number,
                        note = note,
                        timeline_start = timeline_start,
                        duration = child.duration or 0,
                        timeline_end = timeline_start + (child.duration or 0),
                    }
                end
            end
        else
            local child = stack[#stack]
            if child then
                if child.tag == "title" then
                    local title_name = trim((child.attrs and child.attrs.name) or "")
                    local inner = body:sub(child.open_end, s - 1)
                    local title_text = extract_title_text(inner)
                    if is_vfx_title(title_name, title_text) then
                        local vfx_number, note = derive_vfx_title_info(title_name, title_text)
                        titles[#titles + 1] = {
                            name = title_name,
                            vfx_number = vfx_number,
                            note = note,
                            timeline_start = child.timeline_start or 0,
                            duration = child.duration or 0,
                            timeline_end = (child.timeline_start or 0) + (child.duration or 0),
                        }
                    end
                end
                stack[#stack] = nil
            end
        end

        pos = e + 1
    end

    return titles
end

local function collect_global_vfx_titles(xml)
    local titles, stack = {}, {}
    local pos = 1

    while true do
        local s, e, closing, tag_name, attr_str, self_close = xml:find("<(%/?)([%w:_-]+)(.-)(/?)>", pos)
        if not s then break end
        local is_closing = (closing == "/")
        local is_self_closing = (self_close == "/")

        if not is_closing then
            local attrs = parse_attrs(attr_str)
            local parent = stack[#stack]
            local timeline_start = context_timeline_start(parent, attrs)
            local child = {
                tag = tag_name,
                attrs = attrs,
                timeline_start = timeline_start,
                start = parse_fraction(attrs.start),
                duration = parse_fraction(attrs.duration) or 0,
                open_end = e + 1,
            }
            if child.start == nil then
                child.start = parent and tonumber(parent.start) or 0
            end

            if not is_self_closing then
                stack[#stack + 1] = child
            elseif tag_name == "title" then
                local title_name = trim(attrs.name or "")
                if is_vfx_title(title_name, "") then
                    local vfx_number, note = derive_vfx_title_info(title_name, "")
                    titles[#titles + 1] = {
                        name = title_name,
                        vfx_number = vfx_number,
                        note = note,
                        timeline_start = timeline_start,
                        duration = child.duration or 0,
                        timeline_end = timeline_start + (child.duration or 0),
                    }
                end
            end
        else
            local child = stack[#stack]
            if child then
                if child.tag == "title" then
                    local title_name = trim((child.attrs and child.attrs.name) or "")
                    local inner = xml:sub(child.open_end, s - 1)
                    local title_text = extract_title_text(inner)
                    if is_vfx_title(title_name, title_text) then
                        local vfx_number, note = derive_vfx_title_info(title_name, title_text)
                        titles[#titles + 1] = {
                            name = title_name,
                            vfx_number = vfx_number,
                            note = note,
                            timeline_start = child.timeline_start or 0,
                            duration = child.duration or 0,
                            timeline_end = (child.timeline_start or 0) + (child.duration or 0),
                        }
                    end
                end
                stack[#stack] = nil
            end
        end

        pos = e + 1
    end

    table.sort(titles, function(a, b)
        if a.timeline_start == b.timeline_start then
            return (a.timeline_end or 0) < (b.timeline_end or 0)
        end
        return (a.timeline_start or 0) < (b.timeline_start or 0)
    end)
    return titles
end

local function build_segment_record(segment_node, segment_body, asset_map)
    local source = resolve_source_info(segment_node, asset_map, segment_body or "")
    local source_key = trim(source.ref or "") ~= "" and trim(source.ref or "") or trim(source.source_filename or "")
    local tag = trim(segment_node and segment_node.tag or ""):lower()
    local has_own_ref = trim((segment_node and segment_node.attrs and segment_node.attrs.ref) or "") ~= ""

    if not is_original_video_segment(segment_node, source) then
        return nil
    end
    if (tag == "clip" or tag == "asset-clip" or tag == "ref-clip")
        and not has_own_ref
        and has_nested_container_children(segment_body or "") then
        return nil
    end
    if direct_media_child_uses_non_video_role(segment_body or "") then
        return nil
    end

    local segment_timeline_start = tonumber(segment_node.timeline_start) or 0
    local segment_duration = tonumber(segment_node.duration) or 0
    local segment_timeline_end = segment_timeline_start + segment_duration
    local local_source_in_time = segment_node.start or source.source_tc_seconds or 0
    local local_source_out_time = local_source_in_time + segment_duration

    local source_in = source.source_tc_seconds or 0
    local source_out = source_in + segment_duration
    local time_map = parse_time_map_bounds(segment_body or "")
    if time_map then
        source_in = interpolate_time_map_source(time_map, local_source_in_time) or source_in
        source_out = interpolate_time_map_source(time_map, local_source_out_time) or source_out
    else
        source_in = source.source_tc_seconds or 0
        source_out = (source.source_tc_seconds or 0) + segment_duration
    end

    return {
        source_key = source_key,
        timeline_start = segment_timeline_start,
        timeline_end = segment_timeline_end,
        source_filename = source.source_filename or "",
        source_in_seconds = source_in,
        source_out_seconds = source_out,
        source_frame_duration = source.source_frame_duration or (1 / 24),
        source_tc_format = source.source_tc_format or "",
    }
end

local function summarize_segments_for_window(segments, visible_start, visible_end)
    local clipped = {}
    for _, segment in ipairs(segments or {}) do
        local seg_start = tonumber(segment.timeline_start) or 0
        local seg_end = tonumber(segment.timeline_end) or seg_start
        local overlap_start = math.max(seg_start, visible_start)
        local overlap_end = math.min(seg_end, visible_end)
        if overlap_end > overlap_start then
            local source_in = segment.source_in_seconds or 0
            local source_out = segment.source_out_seconds or source_in
            local source_span = source_out - source_in
            local seg_duration = seg_end - seg_start

            if seg_duration > 0 and source_span ~= 0 then
                local in_ratio = (overlap_start - seg_start) / seg_duration
                local out_ratio = (overlap_end - seg_start) / seg_duration
                source_in = source_in + (source_span * in_ratio)
                source_out = source_in + (source_span * (out_ratio - in_ratio))
            end

            clipped[#clipped + 1] = {
                source_key = segment.source_key,
                timeline_start = overlap_start,
                timeline_end = overlap_end,
                source_filename = segment.source_filename,
                source_in_seconds = source_in,
                source_out_seconds = source_out,
                source_frame_duration = segment.source_frame_duration or (1 / 24),
                source_tc_format = segment.source_tc_format or "",
            }
        end
    end

    local first_segment = nil
    local last_segment = nil
    local source_groups = {}
    local source_order = {}
    for _, segment in ipairs(clipped) do
        if (not first_segment)
            or (segment.timeline_start < first_segment.timeline_start)
            or (segment.timeline_start == first_segment.timeline_start and segment.timeline_end < first_segment.timeline_end) then
            first_segment = segment
        end
        if (not last_segment)
            or (segment.timeline_end > last_segment.timeline_end)
            or (segment.timeline_end == last_segment.timeline_end and segment.timeline_start > last_segment.timeline_start) then
            last_segment = segment
        end

        local group_key = canonical_source_group_key(segment.source_key, segment.source_filename)
        if group_key ~= "" then
            local group = source_groups[group_key]
            if not group then
                group = {
                    source_filename = trim(segment.source_filename or ""),
                    first_in_seconds = segment.source_in_seconds or 0,
                    last_out_seconds = segment.source_out_seconds or 0,
                    first_timeline_start = segment.timeline_start or 0,
                    last_timeline_end = segment.timeline_end or 0,
                    source_frame_duration = segment.source_frame_duration or (1 / 24),
                    source_tc_format = segment.source_tc_format or "",
                }
                source_groups[group_key] = group
                source_order[#source_order + 1] = group_key
            else
                if (segment.timeline_start or 0) < (group.first_timeline_start or 0) then
                    group.first_timeline_start = segment.timeline_start or 0
                    group.first_in_seconds = segment.source_in_seconds or group.first_in_seconds
                    if trim(segment.source_filename or "") ~= "" then
                        group.source_filename = trim(segment.source_filename or "")
                    end
                    if trim(segment.source_tc_format or "") ~= "" then
                        group.source_tc_format = trim(segment.source_tc_format or "")
                    end
                end
                if (segment.timeline_end or 0) > (group.last_timeline_end or 0) then
                    group.last_timeline_end = segment.timeline_end or 0
                    group.last_out_seconds = segment.source_out_seconds or group.last_out_seconds
                end
            end
        end
    end

    table.sort(source_order, function(a, b)
        local ga = source_groups[a]
        local gb = source_groups[b]
        local ta = ga and ga.first_timeline_start or 0
        local tb = gb and gb.first_timeline_start or 0
        if ta == tb then
            return (ga and ga.source_filename or a) < (gb and gb.source_filename or b)
        end
        return ta < tb
    end)

    local source_filename_lines = {}
    local source_tc_in_lines = {}
    local source_tc_out_lines = {}
    local source_keys = {}
    for _, key in ipairs(source_order) do
        local group = source_groups[key]
        if group then
            source_keys[#source_keys + 1] = key
            local frame_duration = tonumber(group.source_frame_duration) or (1 / 24)
            local tc_format = trim(group.source_tc_format or "")
            local inclusive_out_seconds = math.max((group.last_out_seconds or 0) - frame_duration, group.first_in_seconds or 0)
            source_filename_lines[#source_filename_lines + 1] = trim(group.source_filename or "")
            source_tc_in_lines[#source_tc_in_lines + 1] = fmt_source_tc_seconds(group.first_in_seconds or 0, frame_duration, tc_format)
            source_tc_out_lines[#source_tc_out_lines + 1] = fmt_source_tc_seconds(inclusive_out_seconds, frame_duration, tc_format)
        end
    end

    return {
        first_segment = first_segment,
        last_segment = last_segment,
        has_displayable_segments = (#source_order > 0),
        source_keys = source_keys,
        source_filename_text = join_lines(source_filename_lines),
        source_tc_in_text = join_lines(source_tc_in_lines),
        source_tc_out_text = join_lines(source_tc_out_lines),
    }
end

local function collect_global_source_segments(xml, asset_map)
    local segments, stack = {}, {}
    local pos = 1

    while true do
        local s, e, closing, tag_name, attr_str, self_close = xml:find("<(%/?)([%w:_-]+)(.-)(/?)>", pos)
        if not s then break end
        local is_closing = (closing == "/")
        local is_self_closing = (self_close == "/")

        if not is_closing then
            local attrs = parse_attrs(attr_str)
            local parent = stack[#stack]
            local timeline_start = context_timeline_start(parent, attrs)
            local explicit_role = trim(attrs.role or "")
            local parent_effective_role = parent and trim((parent.attrs and parent.attrs._effective_role) or parent.effective_role or "") or ""
            local effective_role = explicit_role ~= "" and explicit_role or parent_effective_role
            local explicit_tc_format = trim(attrs.tcFormat or "")
            local parent_effective_tc_format = parent and trim((parent.attrs and parent.attrs._effective_tcFormat) or parent.effective_tc_format or "") or ""
            local effective_tc_format = explicit_tc_format ~= "" and explicit_tc_format or parent_effective_tc_format
            attrs._effective_role = effective_role
            attrs._effective_tcFormat = effective_tc_format

            local node = {
                tag = tag_name,
                attrs = attrs,
                effective_role = effective_role,
                effective_tc_format = effective_tc_format,
                is_primary_spine = (tag_name == "spine" and parent and (parent.tag == "sequence" or parent.tag == "project")),
                inside_nested_media_container = (parent and parent.inside_nested_media_container)
                    or tag_name == "sync-clip"
                    or tag_name == "mc-clip"
                    or tag_name == "audition",
                timeline_start = timeline_start,
                start = parse_fraction(attrs.start),
                duration = parse_fraction(attrs.duration) or 0,
                open_end = e + 1,
            }
            if node.start == nil then
                node.start = parent and tonumber(parent.start) or 0
            end

            local include_here = parent
                and parent.tag == "spine"
                and not parent.inside_nested_media_container
                and MEDIA_SEGMENT_LIKE[tag_name]

            if not is_self_closing then
                stack[#stack + 1] = node
            elseif include_here then
                local segment = build_segment_record(node, "", asset_map or {})
                if segment then
                    segments[#segments + 1] = segment
                end
            end
        else
            local node = stack[#stack]
            if node then
                local parent = stack[#stack - 1]
                if node.tag ~= "title" and node.tag ~= "marker" and node.tag ~= "chapter-marker" and node.tag ~= "keyword"
                    and parent
                    and parent.tag == "spine"
                    and not parent.inside_nested_media_container
                    and MEDIA_SEGMENT_LIKE[node.tag] then
                    local body = xml:sub(node.open_end, s - 1)
                    local segment = build_segment_record(node, body, asset_map or {})
                    if segment then
                        segments[#segments + 1] = segment
                    end
                end
                stack[#stack] = nil
            end
        end

        pos = e + 1
    end

    return segments
end

local function marker_matches_title(marker_abs_time, marker_value, title)
    local eps = 0.0005
    if trim(marker_value or "") ~= "" and trim(title.vfx_number or "") == trim(marker_value or "") then
        return true
    end
    return marker_abs_time >= ((title.timeline_start or 0) - eps)
        and marker_abs_time <= ((title.timeline_end or title.timeline_start or 0) + eps)
end

local function choose_title_for_marker(marker_abs_time, marker_value, local_titles, global_titles)
    local candidates = {}
    for _, title in ipairs(local_titles or {}) do
        if marker_matches_title(marker_abs_time, marker_value, title) then
            candidates[#candidates + 1] = title
        end
    end
    for _, title in ipairs(global_titles or {}) do
        if marker_matches_title(marker_abs_time, marker_value, title) then
            candidates[#candidates + 1] = title
        end
    end
    if #candidates == 0 then return nil end
    table.sort(candidates, function(a, b)
        local amid = ((a.timeline_start or 0) + (a.timeline_end or a.timeline_start or 0)) / 2
        local bmid = ((b.timeline_start or 0) + (b.timeline_end or b.timeline_start or 0)) / 2
        local ad = math.abs(marker_abs_time - amid)
        local bd = math.abs(marker_abs_time - bmid)
        if ad == bd then
            return ((a.duration or 0) < (b.duration or 0))
        end
        return ad < bd
    end)
    return candidates[1]
end

local function parse_markers(xml, asset_map, effect_map, global_segments, global_titles)
    local markers, stack = {}, {}
    local pos = 1

    while true do
        local s, e, closing, tag_name, attr_str, self_close = xml:find("<(%/?)([%w:_-]+)(.-)(/?)>", pos)
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
                tag = tag_name,
                attrs = attrs,
                timeline_start = timeline_start,
                start = start_val,
                duration = duration_val,
                open_end = e + 1,
                pending_markers = {},
            }
            if attrs.start == nil then
                node.start = parent and tonumber(parent.start) or 0
            end

            if (tag_name == "marker" or tag_name == "chapter-marker") and parent and CLIP_LIKE[parent.tag] then
                parent.pending_markers[#parent.pending_markers + 1] = {
                    tag_name = tag_name,
                    value = attrs.value or "",
                    note = attrs.note or "",
                    rel_start = parse_fraction(attrs.start) or 0,
                    duration = parse_fraction(attrs.duration) or 0,
                }
            end

            if not is_self_closing then
                stack[#stack + 1] = node
            end
        else
            local node = stack[#stack]
            if node then
                if CLIP_LIKE[node.tag] and #node.pending_markers > 0 then
                    local body = xml:sub(node.open_end, s - 1)
                    local source = resolve_source_info(node, asset_map or {}, body)
                    local title_ranges = collect_title_ranges(node, body)
                    local base_details = collect_body_details(node, body, asset_map or {}, effect_map or {})
                    for _, marker in ipairs(node.pending_markers) do
                        local marker_abs_time = node.timeline_start + (marker.rel_start - (node.start or 0))
                        local matched_title = choose_title_for_marker(marker_abs_time, marker.value, title_ranges, {})
                        if not matched_title then
                            matched_title = choose_title_for_marker(marker_abs_time, marker.value, {}, global_titles)
                        end

                        if matched_title then
                            local visible_start = matched_title.timeline_start or node.timeline_start
                            local visible_end = matched_title.timeline_end or (node.timeline_start + (node.duration or 0))
                            local details = collect_body_details_for_range(node, body, asset_map or {}, effect_map or {}, visible_start, visible_end)
                            if not details.has_displayable_segments then
                                details = base_details
                            end
                            local allowed_source_keys = {}
                            for _, key in ipairs(details.source_keys or {}) do
                                allowed_source_keys[key] = true
                            end
                            if next(allowed_source_keys) == nil and trim(source.source_filename or "") ~= "" then
                                allowed_source_keys[canonical_source_group_key(source.ref, source.source_filename)] = true
                            end
                            local filtered_global_segments = {}
                            for _, segment in ipairs(global_segments or {}) do
                                local key = canonical_source_group_key(segment.source_key, segment.source_filename)
                                if allowed_source_keys[key] then
                                    filtered_global_segments[#filtered_global_segments + 1] = segment
                                end
                            end
                            local timeline_details = summarize_segments_for_window(filtered_global_segments, visible_start, visible_end)
                            local source_details = timeline_details.has_displayable_segments and timeline_details or details
                            local has_source_details = source_details.has_displayable_segments
                            local fallback_source_ok = (not has_source_details) and is_real_media_source(source) and trim(source.source_filename or "") ~= ""
                            local resolved_source_filename = has_source_details
                                and trim((source_details.source_filename_text ~= "" and source_details.source_filename_text) or ((source_details.first_segment and source_details.first_segment.source_filename) or source.source_filename) or "")
                                or (fallback_source_ok and trim(source.source_filename or "") or "")
                            local resolved_source_tc_seconds = has_source_details
                                and ((source_details.first_segment and source_details.first_segment.source_in_seconds) or source.source_tc_seconds or 0)
                                or (fallback_source_ok and (source.source_tc_seconds or 0) or 0)
                            local resolved_source_frame_duration = ((source_details.first_segment and source_details.first_segment.source_frame_duration) or source.source_frame_duration or (1 / 24))
                            local resolved_source_tc_format = trim((source_details.first_segment and source_details.first_segment.source_tc_format) or source.source_tc_format or "")
                            local resolved_source_tc = has_source_details
                                and trim((source_details.source_tc_in_text ~= "" and source_details.source_tc_in_text) or fmt_source_tc_seconds(((source_details.first_segment and source_details.first_segment.source_in_seconds) or source.source_tc_seconds or 0), resolved_source_frame_duration, resolved_source_tc_format))
                                or (fallback_source_ok and fmt_source_tc_seconds(resolved_source_tc_seconds, resolved_source_frame_duration, resolved_source_tc_format) or "")
                            local fallback_source_out_seconds = (source.source_tc_seconds or 0) + math.max((visible_end or visible_start or 0) - (visible_start or 0), 0)
                            local resolved_source_tc_out_seconds = has_source_details
                                and math.max((((source_details.last_segment and source_details.last_segment.source_out_seconds) or ((source.source_tc_seconds or 0) + (node.duration or 0))) - resolved_source_frame_duration), resolved_source_tc_seconds)
                                or (fallback_source_ok and math.max(fallback_source_out_seconds - resolved_source_frame_duration, resolved_source_tc_seconds) or 0)
                            local resolved_source_tc_out = has_source_details
                                and trim((source_details.source_tc_out_text ~= "" and source_details.source_tc_out_text) or fmt_source_tc_seconds(math.max((((source_details.last_segment and source_details.last_segment.source_out_seconds) or ((source.source_tc_seconds or 0) + (node.duration or 0))) - resolved_source_frame_duration), resolved_source_tc_seconds), resolved_source_frame_duration, resolved_source_tc_format))
                                or (fallback_source_ok and fmt_source_tc_seconds(resolved_source_tc_out_seconds, resolved_source_frame_duration, resolved_source_tc_format) or "")
                            local eps = 0.0005

                            if marker_abs_time >= (visible_start - eps) and marker_abs_time <= (visible_end + eps) then
                                markers[#markers + 1] = {
                                    tag_name = marker.tag_name,
                                    value = matched_title.vfx_number or marker.value,
                                    note = matched_title.note or marker.note,
                                    raw_marker_value = marker.value,
                                    raw_marker_note = marker.note,
                                    interval_start = marker_abs_time,
                                    interval_end = marker_abs_time,
                                    timeline_in_seconds = visible_start or marker_abs_time,
                                    timeline_in_tc = fmt_hms_seconds(visible_start or marker_abs_time),
                                    parent_tag = node.tag,
                                    parent_name = trim((node.attrs and node.attrs.name) or ""),
                                    source_filename = resolved_source_filename,
                                    source_tc_seconds = resolved_source_tc_seconds,
                                    source_tc = resolved_source_tc,
                                    source_tc_out_seconds = resolved_source_tc_out_seconds,
                                    source_tc_out = resolved_source_tc_out,
                                    duration_seconds = math.max((visible_end or visible_start or 0) - (visible_start or 0), 0),
                                    duration_frames = math.floor((math.max((visible_end or visible_start or 0) - (visible_start or 0), 0) * 24) + 0.5),
                                    custom_metadata = trim((details.custom_metadata_text ~= "" and details.custom_metadata_text) or (source.custom_metadata or "")),
                                    remark = trim(details.remark or ""),
                                }
                            end
                        end
                    end
                end
                stack[#stack] = nil
            end
        end

        pos = e + 1
    end

    table.sort(markers, function(a, b)
        if a.interval_start == b.interval_start then
            return a.interval_end < b.interval_end
        end
        return a.interval_start < b.interval_start
    end)

    return markers
end

local function merge_unique_lines(a, b)
    local out = {}
    local seen = {}
    local function add_lines(value)
        for _, line in ipairs(split_nonempty_lines(value or "")) do
            if not seen[line] then
                seen[line] = true
                out[#out + 1] = line
            end
        end
    end
    add_lines(a)
    add_lines(b)
    return join_lines(out)
end

local function split_pipe_items(value)
    local out = {}
    value = trim(value or "")
    if value == "" then return out end
    for item in value:gmatch("[^|]+") do
        item = trim(item)
        if item ~= "" then out[#out + 1] = item end
    end
    return out
end

local function merge_unique_pipe(a, b)
    local out = {}
    local seen = {}
    local function add_items(value)
        for _, item in ipairs(split_pipe_items(value or "")) do
            if not seen[item] then
                seen[item] = true
                out[#out + 1] = item
            end
        end
    end
    add_items(a)
    add_items(b)
    return table.concat(out, " | ")
end

local function shallow_copy_table(t)
    local out = {}
    for k, v in pairs(t or {}) do out[k] = v end
    return out
end

local function dedupe_vfx_rows_by_title(markers)
    local rows = {}
    local by_key = {}
    local duplicate_count = 0

    for _, marker in ipairs(markers or {}) do
        local title_start = tonumber(marker.timeline_in_seconds) or tonumber(marker.interval_start) or 0
        local title_duration = tonumber(marker.duration_seconds) or 0
        local key = trim(marker.value or "") .. "|" .. string.format("%.6f", title_start)
        local existing = by_key[key]

        if not existing then
            local copy = shallow_copy_table(marker)
            copy._capture_target = title_start + (title_duration / 2)
            copy._capture_distance = math.abs((tonumber(copy.interval_start) or title_start) - copy._capture_target)
            by_key[key] = copy
            rows[#rows + 1] = copy
        else
            duplicate_count = duplicate_count + 1
            local candidate_distance = math.abs((tonumber(marker.interval_start) or title_start) - (existing._capture_target or title_start))
            if candidate_distance < (existing._capture_distance or math.huge) then
                existing._capture_distance = candidate_distance
                existing.source_filename = marker.source_filename
                existing.source_tc = marker.source_tc
                existing.source_tc_out = marker.source_tc_out
                existing.custom_metadata = marker.custom_metadata
                existing.remark = marker.remark
                existing.interval_start = marker.interval_start
                existing.interval_end = marker.interval_end
                existing.raw_marker_value = marker.raw_marker_value
                existing.raw_marker_note = marker.raw_marker_note
                existing.tag_name = marker.tag_name
            end
        end
    end

    table.sort(rows, function(a, b)
        local at = tonumber(a.timeline_in_seconds) or tonumber(a.interval_start) or 0
        local bt = tonumber(b.timeline_in_seconds) or tonumber(b.interval_start) or 0
        if at == bt then
            return trim(a.value or "") < trim(b.value or "")
        end
        return at < bt
    end)

    for _, row in ipairs(rows) do
        row._capture_target = nil
        row._capture_distance = nil
    end

    return rows, duplicate_count
end

local function looks_like_vfx_marker(name)
    name = trim(name or "")
    return name:match(CONFIG.MARKER_PREFIX_PATTERN) ~= nil
end

local function rpc_ok(method, params)
    local ok, res = pcall(function() return sk.rpc(method, params or {}) end)
    if ok and res and not res.error then return true, res end
    return false, ok and res or tostring(res)
end

local function try_menu(lines, menuPath)
    local ok, res = rpc_ok("menu.execute", { menuPath = menuPath })
    log(lines, "menu.execute " .. table.concat(menuPath, " > ") .. " ok=" .. tostring(ok))
    if (not ok) and type(res) == "table" then
        if res.error and res.error.message then
            log(lines, "menu.error: " .. tostring(res.error.message))
        end
    end
    return ok, res
end

local function shell_safe_name(s)
    s = tostring(s or "")
    s = s:gsub("[/\\:%*%?\"<>|]", "_")
    s = s:gsub("%s+", "_")
    return s
end

local function exit_play_fullscreen(lines)
    local attempts = {
        {"View", "Playback", "Play Full Screen"},
        {"View", "Playback", "Play Full Screen"},
        {"View", "Playback", "Play Full Screen"},
    }
    local ok_any = false
    for i, path in ipairs(attempts) do
        local ok = try_menu(lines, path)
        log(lines, "Exit Play Full Screen attempt " .. tostring(i) .. ": " .. tostring(ok))
        if ok then ok_any = true end
        sk.sleep(0.20)
    end
    return ok_any
end

local function build_manifest(base, project_name, rows)
    local out = {}
    out[#out + 1] = table.concat({
        "index",
        "vfx_number",
        "note",
        "timeline_seconds",
        "timeline_tc_in",
        "duration_frames",
        "source_filename",
        "source_tc_in",
        "source_tc_out",
        "custom_metadata",
        "remark",
        "project_name",
        "suggested_thumb_name",
        "capture_seconds",
    }, "\t")

    for i, row in ipairs(rows) do
        out[#out + 1] = table.concat({
            tostring(i),
            tsv_escape(row.marker_name),
            tsv_escape(row.marker_note),
            string.format("%.6f", row.timeline_seconds),
            tsv_escape(row.timeline_tc),
            tsv_escape(tostring(row.duration_frames or 0)),
            tsv_escape(row.source_filename or ""),
            tsv_escape(row.source_tc or ""),
            tsv_escape(row.source_tc_out or ""),
            tsv_escape(row.custom_metadata or ""),
            tsv_escape(row.remark or ""),
            tsv_escape(project_name or ""),
            tsv_escape(row.thumb_name),
            string.format("%.6f", row.capture_seconds or row.timeline_seconds or 0),
        }, "\t")
    end

    return table.concat(out, "\n")
end

local function main()
    local lines = {}
    local home = os.getenv("HOME") or "/tmp"
    local desktop = home .. "/Desktop"
    local runtime = state_dir()
    local base = runtime .. "/VFX_Shot_List"
    local xml_path = runtime .. "/VFX_Shot_List.fcpxml"
    local manifest_path = runtime .. "/VFX_Shot_List_Manifest.tsv"
    local progress_path = runtime .. "/VFX_Shot_List_Progress.tsv"
    local done_path = runtime .. "/VFX_Shot_List_Done.flag"
    local report_path = runtime .. "/VFX_Shot_List_Report.txt"
    local manifest_only_path = runtime .. "/VFX_Shot_List_Manifest_Only.flag"
    local capture_dir = desktop .. "/VFX_Shot_List_Captures_16x9"
    local thumb_dir = desktop .. "/VFX_Shot_List_Captures_Thumb"
    os.remove(progress_path)
    os.remove(done_path)
    os.remove(manifest_path)
    os.remove(report_path)
    mkdir_p(capture_dir)
    mkdir_p(thumb_dir)

    ensure_worker_ready(lines)

    log(lines, "Exporting current project...")
    export_current_fcpxml(xml_path)
    local xml = read_file(xml_path)

    local project_name = ""
    do
        local name = xml:match('<project%s+[^>]-name="([^"]+)"')
        if name then project_name = name end
    end
    log(lines, "Project name: " .. tostring(project_name))

    local format_map = parse_formats(xml)
    local asset_map = parse_assets(xml, format_map)
    local effect_map = parse_effects(xml)
    local global_segments = collect_global_source_segments(xml, asset_map)
    local global_titles = collect_global_vfx_titles(xml)
    local vfx = parse_markers(xml, asset_map, effect_map, global_segments, global_titles)
    local raw_vfx_count = #vfx
    local duplicate_vfx_count = 0
    vfx, duplicate_vfx_count = dedupe_vfx_rows_by_title(vfx)

    log(lines, "VFX titles found: " .. tostring(#global_titles))
    log(lines, "Matched marker anchors: " .. tostring(raw_vfx_count))
    log(lines, "VFX rows after title dedupe: " .. tostring(#vfx) .. " (merged " .. tostring(duplicate_vfx_count) .. ")")
    if #vfx == 0 then
        error("No marker anchors found under VFX titles. Run VFX Auto Marker first.")
    end

    local rows = {}
    for _, m in ipairs(vfx) do
        local marker_name = trim(m.value)
        local safe = shell_safe_name(marker_name)
        if safe == "" then safe = "VFX" end
        -- VFX numbers can repeat when stacked titles share the same shot number.
        -- Prefix the row index so captures never overwrite each other.
        local unique_safe = string.format("%03d_%s", #rows + 1, safe)
        rows[#rows + 1] = {
            marker_name = marker_name,
            marker_note = trim(m.note or ""),
            timeline_seconds = tonumber(m.timeline_in_seconds) or tonumber(m.interval_start) or 0,
            timeline_tc = trim(m.timeline_in_tc or "") ~= "" and m.timeline_in_tc or fmt_hms_seconds(m.interval_start),
            capture_seconds = tonumber(m.interval_start) or 0,
            duration_frames = tonumber(m.duration_frames) or math.floor(((tonumber(m.duration_seconds) or 0) * 24) + 0.5),
            source_filename = trim(m.source_filename or ""),
            source_tc = trim(m.source_tc or ""),
            source_tc_out = trim(m.source_tc_out or ""),
            custom_metadata = trim(m.custom_metadata or ""),
            remark = trim(m.remark or ""),
            full_capture_name = unique_safe .. ".png",
            thumb_name = unique_safe .. ".jpg",
        }
    end

    local manifest = build_manifest(base, project_name, rows)
    write_file(manifest_path, manifest)
    write_file(progress_path, table.concat({"status","index","marker_name","timeline_seconds","full_capture_name","thumb_name"}, "\t") .. "\n")
    log(lines, "Manifest written: " .. manifest_path)
    log(lines, "Progress file: " .. progress_path)

    if file_exists(manifest_only_path) then
        log(lines, "Manifest-only mode enabled; native Turnover plugin will seek/capture frames.")
        write_file(report_path, table.concat(lines, "\n"))
        print("[vfx-shot-list] Report: " .. report_path)
        print("[vfx-shot-list] Manifest: " .. manifest_path)
        return
    end

    local dwell_after_seek = CONFIG.FAST_MODE and CONFIG.FAST_DWELL_AFTER_SEEK_SEC or CONFIG.SAFE_DWELL_AFTER_SEEK_SEC
    local dwell_between_markers = CONFIG.FAST_MODE and CONFIG.FAST_DWELL_BETWEEN_MARKERS_SEC or CONFIG.SAFE_DWELL_BETWEEN_MARKERS_SEC
    log(lines, string.format("Timing mode: %s (after_seek=%.3f, between=%.3f)",
        CONFIG.FAST_MODE and "FAST" or "SAFE",
        dwell_after_seek,
        dwell_between_markers))

    -- Fullscreen playback controller flow.
    local ok_enter = try_menu(lines, CONFIG.ENTER_PLAY_FULL_SCREEN_MENU)
    if not ok_enter then
        error("Could not enter Play Full Screen.")
    end
    sk.sleep(CONFIG.LIVE_SLEEP_SEC or 0.06)

    local ok_pause = try_menu(lines, CONFIG.PAUSE_TOGGLE_MENU)
    log(lines, "Pause toggle attempted: " .. tostring(ok_pause))
    sk.sleep(CONFIG.LIVE_SLEEP_SEC or 0.06)

    for i, row in ipairs(rows) do
        log(lines, string.format("Marker %02d/%02d => %s @ %s", i, #rows, row.marker_name, fmt_seconds(row.capture_seconds or row.timeline_seconds)))
        sk.seek(row.capture_seconds or row.timeline_seconds)
        sk.sleep(dwell_after_seek)
        append_file(progress_path, table.concat({
            "ready",
            tostring(i),
            row.marker_name,
            string.format("%.6f", row.capture_seconds or row.timeline_seconds),
            row.full_capture_name,
            row.thumb_name
        }, "\t") .. "\n")

        if CONFIG.ENABLE_VIEWER_CAPTURE then
            local capture_path = capture_dir .. "/" .. row.full_capture_name
            local ok_cap, cap_res = rpc_ok("com.turnover.tools.capture_fullscreen_viewer", { path = capture_path })
            log(lines, "turnover.capture_fullscreen_viewer ok=" .. tostring(ok_cap) .. " path=" .. capture_path)
            if (not ok_cap) or (type(cap_res) == "table" and cap_res.error) or (type(cap_res) == "table" and cap_res.status == "error") then
                log(lines, "turnover.capture_fullscreen_viewer fallback to viewer.capture")
                ok_cap, cap_res = rpc_ok("viewer.capture", { path = capture_path })
                log(lines, "viewer.capture ok=" .. tostring(ok_cap) .. " path=" .. capture_path)
            end
            if type(cap_res) == "table" and cap_res.bytes then
                log(lines, "capture bytes=" .. tostring(cap_res.bytes))
            end
            if type(cap_res) == "table" and cap_res.window_title then
                log(lines, "capture window=" .. tostring(cap_res.window_title))
            elseif type(cap_res) == "table" and cap_res.error then
                log(lines, "capture error=" .. tostring(cap_res.error))
            elseif not ok_cap then
                log(lines, "capture failed=" .. tostring(cap_res))
            end
        end

        sk.sleep(dwell_between_markers)
    end

    local ok_exit = exit_play_fullscreen(lines)
    log(lines, "Exit/toggle Play Full Screen attempted: " .. tostring(ok_exit))

    append_file(progress_path, table.concat({"done", tostring(#rows), "", "", "", ""}, "\t") .. "\n")
    write_file(done_path, "done\n")
    log(lines, "DONE")
    log(lines, "Capture folder: " .. capture_dir)
    log(lines, "Suggested capture order file: " .. manifest_path)
    log(lines, "Done marker file: " .. done_path)

    write_file(report_path, table.concat(lines, "\n"))
    print("[vfx-shot-list] Report: " .. report_path)
    print("[vfx-shot-list] Manifest: " .. manifest_path)
end

local ok, err = pcall(main)
if not ok then
    print("[vfx-shot-list] ERROR: " .. tostring(err))
    if sk and sk.toast then
        sk.toast("VFX Shot List failed: " .. tostring(err), 6)
    end
end
