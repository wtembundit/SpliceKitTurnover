-- VFX Pull EDL.lua
-- Builds a source-pull EDL from VFX markers and the actual source ranges used under each VFX shot.
--
-- Main design:
--   - Focus on SOURCE ranges, not original timeline positions
--   - Build a brand new single-track record timeline
--   - One event per used source layer
--   - First layer = PL01, following layers = EL01, EL02, ...
--   - Export companion TSV with full breakdown for verification

local CONFIG = {
    MARKER_PREFIX_PATTERN = "^[%u%d_]+_%d%d%d%d$",
    RECORD_START_TC = "01:00:00:00",
    DEFAULT_FRAME_DURATION = 1 / 24,
    TOTAL_HANDLE_FRAMES = 0,
    EDL_EXT = ".edl",
    TSV_EXT = ".tsv",
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
    print("[vfx-pull-edl] " .. tostring(msg))
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

local function parse_key_value_file(path)
    local out = {}
    if not file_exists(path) then return out end
    local text = read_file(path)
    for line in text:gmatch("[^\r\n]+") do
        local key, value = line:match("^([^\t]+)\t(.*)$")
        if key then out[key] = value end
    end
    return out
end

local function load_runtime_config()
    local config = parse_key_value_file(state_dir() .. "/VFX_Pull_EDL_Config.tsv")
    local handle_frames = tonumber(config.handle_frames or config.total_handle_frames or CONFIG.TOTAL_HANDLE_FRAMES) or 0
    handle_frames = math.floor(handle_frames + 0.5)
    if handle_frames < 0 then
        handle_frames = 0
    end
    CONFIG.TOTAL_HANDLE_FRAMES = handle_frames
end

local function tsv_escape(value)
    value = tostring(value or "")
    value = value:gsub("\\", "\\\\")
    value = value:gsub("\t", "\\t")
    value = value:gsub("\r", "\\r")
    value = value:gsub("\n", "\\n")
    return value
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

local function parse_attrs(attr_str)
    local attrs = {}
    if not attr_str then return attrs end
    for k, v in attr_str:gmatch('([%w:_-]+)%s*=%s*"([^"]*)"') do
        attrs[k] = v
    end
    return attrs
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

local function source_path_from_src(src)
    src = trim(src or "")
    if src == "" then return "" end
    src = src:gsub("^file://localhost", "")
    src = src:gsub("^file://", "")
    src = src:gsub("^file:", "")
    src = src:gsub("%?.*$", "")
    src = decode_uri_component(src)
    return src
end

local function basename_without_extension(name)
    name = trim(name or "")
    if name == "" then return "" end
    local stem = name:match("^(.*)%.([^.]+)$")
    return stem or name
end

local function parse_formats(xml)
    local formats = {}

    local function remember(attrs)
        local id = trim(attrs.id or "")
        if id == "" then return end
        formats[id] = {
            id = id,
            frame_duration = parse_fraction(attrs.frameDuration),
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

    local function first_media_rep_src(body)
        body = body or ""
        return body:match('<media%-rep[^>]-kind="original%-media"[^>]-src="([^"]+)"')
            or body:match('<media%-rep[^>]-src="([^"]+)"')
    end

    local function remember(attrs, body)
        local id = trim(attrs.id or "")
        if id == "" then return end
        local media_rep_src = trim(first_media_rep_src(body) or "")
        local src = media_rep_src ~= "" and media_rep_src or trim(attrs.src or "")
        local format_id = trim(attrs.format or "")
        local format_info = format_map and format_map[format_id] or nil
        assets[id] = {
            id = id,
            src = src,
            source_path = source_path_from_src(src),
            filename = basename_from_src(src),
            name = trim(attrs.name or ""),
            start = parse_fraction(attrs.start) or 0,
            hasVideo = trim(attrs.hasVideo or ""),
            frame_duration = (format_info and format_info.frame_duration) or CONFIG.DEFAULT_FRAME_DURATION,
        }
    end

    for attr_str in xml:gmatch("<asset%s+([^>]-)/>") do
        remember(parse_attrs(attr_str), "")
    end
    for attr_str, body in xml:gmatch("<asset%s+([^>]-)>(.-)</asset>") do
        remember(parse_attrs(attr_str), body)
    end

    return assets
end

local function parse_sequence_frame_duration(xml, format_map)
    local format_id = xml:match("<sequence%s+[^>]-format=\"([^\"]+)\"")
    local format_info = format_id and format_map[trim(format_id)] or nil
    local frame_duration = format_info and tonumber(format_info.frame_duration) or nil
    if frame_duration and frame_duration > 0 then
        return frame_duration
    end
    return CONFIG.DEFAULT_FRAME_DURATION
end

local function context_timeline_start(parent_ctx, attrs)
    local parent_tl = parent_ctx and parent_ctx.timeline_start or 0
    local my_offset = parse_fraction(attrs.offset)
    if my_offset == nil then
        return parent_tl
    end
    local parent_start = parent_ctx and tonumber(parent_ctx.start) or 0
    return parent_tl + my_offset - parent_start
end

local function find_first_child_ref(blob)
    if not blob or blob == "" then return nil end
    return blob:match("<video[^>]-ref=\"([^\"]+)\"")
        or blob:match("<audio[^>]-ref=\"([^\"]+)\"")
        or blob:match("<asset%-clip[^>]-ref=\"([^\"]+)\"")
        or blob:match("<ref%-clip[^>]-ref=\"([^\"]+)\"")
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

    return {
        ref = ref,
        asset = asset,
        source_filename = source_filename,
        source_path = asset and trim(asset.source_path or "") or "",
        source_tc_seconds = source_tc_seconds,
        source_frame_duration = asset and asset.frame_duration or CONFIG.DEFAULT_FRAME_DURATION,
    }
end

local function is_real_media_source(source)
    local asset = source and source.asset or nil
    local filename = trim(source and source.source_filename or "")
    if not asset then return false end
    if trim(asset.hasVideo or "") ~= "1" then return false end
    if filename == "" then return false end
    return true
end

local function is_original_video_segment(segment_node, source)
    local tag = trim(segment_node and segment_node.tag or ""):lower()
    local attrs = (segment_node and segment_node.attrs) or {}
    local role = trim(attrs._effective_role or attrs.role or ""):lower()

    if tag == "audio" then return false end
    if role ~= "" and not role:match("^video") then return false end
    if tag == "sync-clip" or tag == "mc-clip" or tag == "audition" or tag == "spine" or tag == "gap" then
        return false
    end

    return is_real_media_source(source)
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
            if depth > 0 then depth = depth - 1 end
        end

        pos = e + 1
    end

    return false
end

local parse_time_map_bounds

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

    return { points = points }
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

local function canonical_source_group_key(source_key, source_filename)
    local filename = trim(source_filename or "")
    if filename ~= "" then
        return filename:lower()
    end
    return trim(source_key or ""):lower()
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
            }
            if child.start == nil then
                child.start = parent and tonumber(parent.start) or (tonumber(node and node.start) or 0)
            end

            if not is_self_closing then
                stack[#stack + 1] = child
            elseif tag_name == "title" then
                local title_name = trim(attrs.name or "")
                local vfx_number = trim((title_name:match("^(.-)%s+%-%s+VFX NAMING$") or title_name))
                titles[#titles + 1] = {
                    name = title_name,
                    vfx_number = vfx_number,
                    timeline_start = timeline_start,
                    duration = child.duration or 0,
                    timeline_end = timeline_start + (child.duration or 0),
                }
            end
        else
            local child = stack[#stack]
            if child then
                if child.tag == "title" then
                    local title_name = trim((child.attrs and child.attrs.name) or "")
                    local vfx_number = trim((title_name:match("^(.-)%s+%-%s+VFX NAMING$") or title_name))
                    titles[#titles + 1] = {
                        name = title_name,
                        vfx_number = vfx_number,
                        timeline_start = child.timeline_start or 0,
                        duration = child.duration or 0,
                        timeline_end = (child.timeline_start or 0) + (child.duration or 0),
                    }
                end
                stack[#stack] = nil
            end
        end

        pos = e + 1
    end

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
        source_path = source.source_path or "",
        source_in_seconds = source_in,
        source_out_seconds = source_out,
        source_frame_duration = source.source_frame_duration or CONFIG.DEFAULT_FRAME_DURATION,
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
            attrs._effective_role = effective_role

            local node = {
                tag = tag_name,
                attrs = attrs,
                effective_role = effective_role,
                is_primary_spine = (tag_name == "spine" and parent and (parent.tag == "sequence" or parent.tag == "project")),
                timeline_start = timeline_start,
                start = parse_fraction(attrs.start),
                duration = parse_fraction(attrs.duration) or 0,
                open_end = e + 1,
            }
            if node.start == nil then
                node.start = parent and tonumber(parent.start) or 0
            end

            local include_here = parent and parent.is_primary_spine and MEDIA_SEGMENT_LIKE[tag_name]

            if not is_self_closing then
                stack[#stack + 1] = node
            elseif include_here then
                local segment = build_segment_record(node, "", asset_map or {})
                if segment then segments[#segments + 1] = segment end
            end
        else
            local node = stack[#stack]
            if node then
                if node.tag ~= "title" and node.tag ~= "marker" and node.tag ~= "chapter-marker" and node.tag ~= "keyword"
                    and stack[#stack - 1] and stack[#stack - 1].is_primary_spine and MEDIA_SEGMENT_LIKE[node.tag] then
                    local body = xml:sub(node.open_end, s - 1)
                    local segment = build_segment_record(node, body, asset_map or {})
                    if segment then segments[#segments + 1] = segment end
                end
                stack[#stack] = nil
            end
        end

        pos = e + 1
    end

    return segments
end

local function collect_body_details_for_range(node, body, asset_map, visible_start_override, visible_end_override)
    local segments = {}
    local stack = {}
    local pos = 1
    local body_visible_start = visible_start_override
    local body_visible_end = visible_end_override
    if body_visible_start == nil or body_visible_end == nil then
        body_visible_start = tonumber(node and node.timeline_start) or 0
        body_visible_end = body_visible_start + (tonumber(node and node.duration) or 0)
    end

    local function add_segment_from_node(segment_node, segment_body)
        local source = resolve_source_info(segment_node, asset_map, segment_body or "")
        local tag = trim(segment_node and segment_node.tag or ""):lower()
        local has_own_ref = trim((segment_node and segment_node.attrs and segment_node.attrs.ref) or "") ~= ""

        if not is_original_video_segment(segment_node, source) then return end
        if (tag == "clip" or tag == "asset-clip" or tag == "ref-clip")
            and not has_own_ref
            and has_nested_container_children(segment_body or "") then
            return
        end
        if direct_media_child_uses_non_video_role(segment_body or "") then
            return
        end

        local segment_timeline_start = tonumber(segment_node.timeline_start) or 0
        local segment_timeline_end = segment_timeline_start + (tonumber(segment_node.duration) or 0)
        local overlap_start = math.max(segment_timeline_start, body_visible_start)
        local overlap_end = math.min(segment_timeline_end, body_visible_end)
        if overlap_end <= overlap_start then return end

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

        segments[#segments + 1] = {
            source_key = trim(source.ref or "") ~= "" and trim(source.ref or "") or trim(source.source_filename or ""),
            timeline_start = overlap_start,
            timeline_end = overlap_end,
            source_filename = source.source_filename or "",
            source_path = source.source_path or "",
            source_in_seconds = source_in,
            source_out_seconds = source_out,
            source_frame_duration = source.source_frame_duration or CONFIG.DEFAULT_FRAME_DURATION,
        }
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
            attrs._effective_role = effective_role

            local child = {
                tag = tag_name,
                attrs = attrs,
                effective_role = effective_role,
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

    local source_groups = {}
    local source_order = {}
    for _, segment in ipairs(segments) do
        local key = canonical_source_group_key(segment.source_key, segment.source_filename)
        if key ~= "" then
            local group = source_groups[key]
            if not group then
                group = {
                    source_key = segment.source_key,
                    source_filename = trim(segment.source_filename or ""),
                    source_path = trim(segment.source_path or ""),
                    first_in_seconds = segment.source_in_seconds or 0,
                    last_out_seconds = segment.source_out_seconds or 0,
                    first_timeline_start = segment.timeline_start or 0,
                    source_frame_duration = segment.source_frame_duration or CONFIG.DEFAULT_FRAME_DURATION,
                }
                source_groups[key] = group
                source_order[#source_order + 1] = key
            else
                if (segment.timeline_start or 0) < (group.first_timeline_start or 0) then
                    group.first_timeline_start = segment.timeline_start or 0
                    group.first_in_seconds = segment.source_in_seconds or group.first_in_seconds
                    if trim(segment.source_filename or "") ~= "" then
                        group.source_filename = trim(segment.source_filename or "")
                    end
                    if trim(segment.source_path or "") ~= "" then
                        group.source_path = trim(segment.source_path or "")
                    end
                end
                if (segment.source_out_seconds or 0) > (group.last_out_seconds or 0) then
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

    local groups = {}
    for _, key in ipairs(source_order) do
        local group = source_groups[key]
        if group then groups[#groups + 1] = group end
    end

    return {
        has_displayable_segments = (#groups > 0),
        groups = groups,
    }
end

local function collect_pull_rows(xml, asset_map, timeline_frame_duration)
    local rows, stack = {}, {}
    local global_segments = collect_global_source_segments(xml, asset_map)
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
                    local title_ranges = collect_title_ranges(node, body)
                    local source_details = collect_body_details_for_range(node, body, asset_map or {}, nil, nil)
                    for _, marker in ipairs(node.pending_markers) do
                        local marker_value = trim(marker.value or "")
                        if marker_value:match(CONFIG.MARKER_PREFIX_PATTERN) then
                            local matched_title = nil
                            for _, title in ipairs(title_ranges) do
                                if trim(title.vfx_number or "") == marker_value then
                                    matched_title = title
                                    break
                                end
                            end

                            local visible_start = matched_title and matched_title.timeline_start or node.timeline_start
                            local visible_end = matched_title and matched_title.timeline_end or (node.timeline_start + (node.duration or 0))
                            local details = collect_body_details_for_range(node, body, asset_map or {}, visible_start, visible_end)
                            if not details.has_displayable_segments then
                                details = source_details
                            end

                            local layer_index = 0
                            for _, group in ipairs(details.groups or {}) do
                                layer_index = layer_index + 1
                                local layer_name
                                if layer_index == 1 then
                                    layer_name = "PL01"
                                else
                                    layer_name = string.format("EL%02d", layer_index - 1)
                                end

                                local frame_duration = tonumber(group.source_frame_duration) or timeline_frame_duration or CONFIG.DEFAULT_FRAME_DURATION
                                local head_handle_frames = CONFIG.TOTAL_HANDLE_FRAMES or 0
                                local tail_handle_frames = head_handle_frames
                                local source_in_seconds = math.max((group.first_in_seconds or 0) - (head_handle_frames * frame_duration), 0)
                                local source_out_seconds_raw = (group.last_out_seconds or 0) + (tail_handle_frames * frame_duration)
                                local source_duration_seconds = math.max(source_out_seconds_raw - source_in_seconds, 0)
                                local source_duration_frames = math.floor((source_duration_seconds / frame_duration) + 0.5)
                                if source_duration_frames <= 0 then
                                    source_duration_frames = 1
                                end
                                local source_out_seconds = source_in_seconds + (source_duration_frames * frame_duration)

                                rows[#rows + 1] = {
                                    vfx_number = marker_value,
                                    note = trim(marker.note or ""),
                                    layer = layer_name,
                                    source_filename = trim(group.source_filename or ""),
                                    source_path = trim(group.source_path or ""),
                                    reel = basename_without_extension(trim(group.source_filename or "")),
                                    source_in_seconds = source_in_seconds,
                                    source_out_seconds = source_out_seconds,
                                    source_frame_duration = frame_duration,
                                    source_duration_frames = source_duration_frames,
                                    handle_frames_per_side = CONFIG.TOTAL_HANDLE_FRAMES or 0,
                                    total_handle_frames = CONFIG.TOTAL_HANDLE_FRAMES or 0,
                                    head_handle_frames = head_handle_frames,
                                    tail_handle_frames = tail_handle_frames,
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

    return rows
end

local function tc_to_frames(tc, fps)
    local hh, mm, ss, ff = tostring(tc or ""):match("^(%d+):(%d+):(%d+):(%d+)$")
    if not hh then return 0 end
    hh, mm, ss, ff = tonumber(hh), tonumber(mm), tonumber(ss), tonumber(ff)
    return (((hh * 60 + mm) * 60) + ss) * fps + ff
end

local function frames_to_tc(frames, fps)
    frames = math.max(0, math.floor((tonumber(frames) or 0) + 0.5))
    local hh = math.floor(frames / (fps * 3600))
    local rem = frames % (fps * 3600)
    local mm = math.floor(rem / (fps * 60))
    rem = rem % (fps * 60)
    local ss = math.floor(rem / fps)
    local ff = rem % fps
    return string.format("%02d:%02d:%02d:%02d", hh, mm, ss, ff)
end

local function seconds_to_tc(seconds, frame_duration)
    frame_duration = tonumber(frame_duration) or CONFIG.DEFAULT_FRAME_DURATION
    if frame_duration <= 0 then frame_duration = CONFIG.DEFAULT_FRAME_DURATION end
    local fps = math.floor((1 / frame_duration) + 0.5)
    if fps <= 0 then fps = 24 end
    local total_frames = math.floor((tonumber(seconds) or 0) / frame_duration + 0.000001)
    return frames_to_tc(total_frames, fps)
end

local function edl_safe_name(s, max_len)
    s = trim(s or ""):gsub("%s+", "_")
    s = s:gsub("[^%w_%-%.]", "_")
    if max_len and #s > max_len then
        return s:sub(1, max_len)
    end
    return s
end

local function build_edl(project_name, rows, timeline_frame_duration)
    local fps = math.floor((1 / (timeline_frame_duration or CONFIG.DEFAULT_FRAME_DURATION)) + 0.5)
    if fps <= 0 then fps = 24 end
    local record_cursor = tc_to_frames(CONFIG.RECORD_START_TC, fps)
    local edl_lines = {
        "TITLE: " .. edl_safe_name((project_name ~= "" and project_name or "VFX_PULL"), 64) .. " MPS",
        "FCM: NON-DROP FRAME",
        "",
    }

    local companion_rows = {}

    for i, row in ipairs(rows) do
        local record_in_frames = record_cursor
        local record_out_frames = record_in_frames + math.max(1, tonumber(row.source_duration_frames) or 1)
        local record_in_tc = frames_to_tc(record_in_frames, fps)
        local record_out_tc = frames_to_tc(record_out_frames, fps)
        local source_in_tc = seconds_to_tc(row.source_in_seconds or 0, row.source_frame_duration)
        local source_out_tc = seconds_to_tc(row.source_out_seconds or 0, row.source_frame_duration)
        local event_name = string.format("%s_%s", trim(row.vfx_number or ""), trim(row.layer or "PL01"))
        local reel = edl_safe_name(row.reel ~= "" and row.reel or row.source_filename, 32)

        edl_lines[#edl_lines + 1] = string.format(
            "%06d  %-32s V     C        %s %s %s %s",
            i,
            reel,
            source_in_tc,
            source_out_tc,
            record_in_tc,
            record_out_tc
        )
        edl_lines[#edl_lines + 1] = "* FROM CLIP NAME: " .. trim(row.source_filename or "")
        if trim(row.source_path or "") ~= "" then
            edl_lines[#edl_lines + 1] = "* FILE PATH: " .. trim(row.source_path or "")
        end
        edl_lines[#edl_lines + 1] = "* LOC: " .. source_in_tc .. " GREEN " .. event_name
        edl_lines[#edl_lines + 1] = ""

        companion_rows[#companion_rows + 1] = {
            index = i,
            event_name = event_name,
            vfx_number = trim(row.vfx_number or ""),
            layer = trim(row.layer or ""),
            reel = reel,
            source_filename = trim(row.source_filename or ""),
            source_path = trim(row.source_path or ""),
            source_tc_in = source_in_tc,
            source_tc_out = source_out_tc,
            source_duration_frames = tonumber(row.source_duration_frames) or 0,
            handle_frames_per_side = tonumber(row.handle_frames_per_side or row.total_handle_frames) or 0,
            total_handle_frames = tonumber(row.total_handle_frames) or 0,
            head_handle_frames = tonumber(row.head_handle_frames) or 0,
            tail_handle_frames = tonumber(row.tail_handle_frames) or 0,
            record_tc_in = record_in_tc,
            record_tc_out = record_out_tc,
            loc_tc = source_in_tc,
            note = trim(row.note or ""),
        }

        record_cursor = record_out_frames
    end

    return table.concat(edl_lines, "\n"), companion_rows
end

local function build_companion_tsv(rows)
    local out = {}
    out[#out + 1] = table.concat({
        "index",
        "event_name",
        "vfx_number",
        "layer",
        "reel",
        "source_filename",
        "source_path",
        "source_tc_in",
        "source_tc_out",
        "source_duration_frames",
        "handle_frames_per_side",
        "total_handle_frames",
        "head_handle_frames",
        "tail_handle_frames",
        "record_tc_in",
        "record_tc_out",
        "loc_tc",
        "note",
    }, "\t")

    for _, row in ipairs(rows or {}) do
        out[#out + 1] = table.concat({
            tostring(row.index or 0),
            tsv_escape(row.event_name or ""),
            tsv_escape(row.vfx_number or ""),
            tsv_escape(row.layer or ""),
            tsv_escape(row.reel or ""),
            tsv_escape(row.source_filename or ""),
            tsv_escape(row.source_path or ""),
            tsv_escape(row.source_tc_in or ""),
            tsv_escape(row.source_tc_out or ""),
            tsv_escape(tostring(row.source_duration_frames or 0)),
            tsv_escape(tostring(row.handle_frames_per_side or 0)),
            tsv_escape(tostring(row.total_handle_frames or 0)),
            tsv_escape(tostring(row.head_handle_frames or 0)),
            tsv_escape(tostring(row.tail_handle_frames or 0)),
            tsv_escape(row.record_tc_in or ""),
            tsv_escape(row.record_tc_out or ""),
            tsv_escape(row.loc_tc or ""),
            tsv_escape(row.note or ""),
        }, "\t")
    end

    return table.concat(out, "\n")
end

local function export_current_fcpxml(path)
    local res = sk.rpc("fcpxml.export", { path = path })
    if res and res.error then error("fcpxml.export failed: " .. tostring(res.error)) end
    if not file_exists(path) then error("Export did not create file: " .. path) end
end

local function main()
    local lines = {}
    local runtime = state_dir()
    local xml_path = runtime .. "/VFX_Pull_EDL.fcpxml"
    local report_path = runtime .. "/VFX_Pull_EDL_Report.txt"
    local home = os.getenv("HOME") or "/tmp"
    local desktop = home .. "/Desktop"
    load_runtime_config()
    log(lines, "Handle frames per side: " .. tostring(CONFIG.TOTAL_HANDLE_FRAMES or 0))

    log(lines, "Exporting current project...")
    export_current_fcpxml(xml_path)
    local xml = read_file(xml_path)

    local project_name = trim(xml:match('<project%s+[^>]-name="([^"]+)"') or "")
    log(lines, "Project name: " .. tostring(project_name))

    local format_map = parse_formats(xml)
    local asset_map = parse_assets(xml, format_map)
    local timeline_frame_duration = parse_sequence_frame_duration(xml, format_map)
    local rows = collect_pull_rows(xml, asset_map, timeline_frame_duration)

    if #rows == 0 then
        error("No VFX pull rows could be built from the current project.")
    end

    local edl_text, companion_rows = build_edl(project_name, rows, timeline_frame_duration)
    local safe_project = edl_safe_name(project_name ~= "" and project_name or "Project", 80)
    local edl_path = desktop .. "/VFX Pull EDL - " .. safe_project .. ".edl"

    write_file(edl_path, edl_text)
    write_file(report_path, table.concat(lines, "\n"))

    log(lines, "EDL written: " .. edl_path)
    write_file(report_path, table.concat(lines, "\n"))

    print("[vfx-pull-edl] EDL: " .. edl_path)
    if sk and sk.toast then
        sk.toast("VFX Pull EDL exported", 5)
    end
end

local ok, err = pcall(main)
if not ok then
    print("[vfx-pull-edl] ERROR: " .. tostring(err))
    if sk and sk.toast then
        sk.toast("VFX Pull EDL failed: " .. tostring(err), 6)
    end
end
