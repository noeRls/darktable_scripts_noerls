--[[
  OwnTracks Recorder Geotagger for darktable (Windows)

  Fetches location history from OwnTracks Recorder (/api/0/locations) over HTTPS
  with HTTP Basic Auth, linearly interpolates coordinates (and altitude when present),
  and writes them to images in the current collection (or selection).
]]

local dt = require "darktable"

local MODULE = "owntracks_geotag"
local PS = (dt.configuration.running_os == "windows") and "\\" or "/"
local QUERY_PADDING_SEC = 86400 -- pad Recorder query by +/- 24 hours for bracketing

local state = {
  module_installed = false,
  event_registered = false,
  widgets = {},
}

-- ============================================================================
-- Pure-math UTC date/time utilities (immune to Windows os.time() DST quirks)
-- ============================================================================

-- Howard Hinnant's civil-to-days algorithm -> Unix UTC epoch (seconds)
local function utc_to_epoch(y, m, d, H, M, S)
  if m <= 2 then y = y - 1 end
  local era = math.floor(y / 400)
  local yoe = y - era * 400
  local doy = math.floor((153 * (m + (m > 2 and -3 or 9)) + 2) / 5) + d - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  local days = era * 146097 + doe - 719468
  return days * 86400 + H * 3600 + M * 60 + S
end

-- Unix UTC epoch (seconds) -> "YYYY-MM-DDTHH:MM:SS" (UTC, OwnTracks Recorder format)
local function epoch_to_iso_utc(epoch)
  local t = math.floor(epoch)
  local secs_in_day = t % 86400
  local z = math.floor(t / 86400) + 719468
  local era = math.floor(z / 146097)
  local doe = z - era * 146097
  local yoe = math.floor(
    (doe - math.floor(doe / 1460) + math.floor(doe / 36524) - math.floor(doe / 146096)) / 365
  )
  local y = yoe + era * 400
  local doy = doe - (365 * yoe + math.floor(yoe / 4) - math.floor(yoe / 100))
  local mp = math.floor((5 * doy + 2) / 153)
  local d = doy - math.floor((153 * mp + 2) / 5) + 1
  local m = mp + (mp < 10 and 3 or -9)
  if m <= 2 then y = y + 1 end
  local H = math.floor(secs_in_day / 3600)
  local M = math.floor((secs_in_day % 3600) / 60)
  local S = secs_in_day % 60
  return string.format("%04d-%02d-%02dT%02d:%02d:%02d", y, m, d, H, M, S)
end

-- Detect current Windows local UTC offset as "+HH:MM" / "-HH:MM"
local function get_system_offset_string()
  local now = os.time()
  local u = os.date("!*t", now)
  local l = os.date("*t", now)
  local diff = utc_to_epoch(l.year, l.month, l.day, l.hour, l.min, l.sec)
             - utc_to_epoch(u.year, u.month, u.day, u.hour, u.min, u.sec)
  local sign = diff >= 0 and "+" or "-"
  local abs_diff = math.abs(diff)
  local hh = math.floor(abs_diff / 3600)
  local mm = math.floor((abs_diff % 3600) / 60)
  return string.format("%s%02d:%02d", sign, hh, mm)
end

-- Parse camera UTC offset strings: "+07:00", "-05:30", "+7", "0", "+07:00:15"
-- Returns offset in seconds, or nil + error message
local function parse_offset_seconds(str)
  local s = (str or ""):match("^%s*(.-)%s*$")
  if s == "" or s == "0" or s == "+0" or s == "-0" or s:upper() == "Z" or s:upper() == "UTC" then
    return 0
  end

  local sign_str, hh_str, mm_str, ss_str = s:match("^([%+%-]?)(%d%d?):(%d%d):(%d%d)$")
  if not hh_str then
    sign_str, hh_str, mm_str = s:match("^([%+%-]?)(%d%d?):(%d%d)$")
    ss_str = "0"
  end
  if not hh_str then
    sign_str, hh_str = s:match("^([%+%-]?)(%d%d?)$")
    mm_str, ss_str = "0", "0"
  end

  if not hh_str then
    return nil, "Invalid UTC offset (use e.g. +07:00, -04:00, +05:30, or +07:00:15)"
  end

  local sign = (sign_str == "-") and -1 or 1
  local hh, mm, ss = tonumber(hh_str), tonumber(mm_str), tonumber(ss_str)
  if hh > 14 or mm >= 60 or ss >= 60 then
    return nil, "UTC offset out of range"
  end

  return sign * (hh * 3600 + mm * 60 + ss)
end

-- Parse darktable exif_datetime_taken ("YYYY:MM:DD HH:MM:SS" or with .mmm)
-- Returns floating-point epoch in camera's clock (before UTC offset adjustment)
local function parse_exif_datetime(dt_str)
  if not dt_str or dt_str == "" then return nil end
  local y, m, d, H, M, S, frac =
    dt_str:match("^(%d%d%d%d)[:%-](%d%d)[:%-](%d%d)[ T](%d%d):(%d%d):(%d%d)%.?(%d*)")
  if not y then return nil end
  y, m, d = tonumber(y), tonumber(m), tonumber(d)
  H, M, S = tonumber(H), tonumber(M), tonumber(S)
  if y == 0 or m == 0 or d == 0 then return nil end
  local subsec = (frac and frac ~= "") and tonumber("0." .. frac) or 0
  return utc_to_epoch(y, m, d, H, M, S) + subsec
end

-- ============================================================================
-- Minimal self-contained JSON decoder (handles full OwnTracks JSON responses)
-- ============================================================================

local function decode_json(str)
  local pos = 1
  local len = #str

  local function skip_ws()
    local _, e = str:find("^[ \t\r\n]+", pos)
    if e then pos = e + 1 end
  end

  local parse_value

  local function parse_string()
    pos = pos + 1 -- skip opening '"'
    local chunks = {}
    while pos <= len do
      local c = str:sub(pos, pos)
      if c == '"' then
        pos = pos + 1
        return table.concat(chunks)
      elseif c == "\\" then
        pos = pos + 1
        local esc = str:sub(pos, pos)
        if esc == '"' or esc == "\\" or esc == "/" then
          chunks[#chunks + 1] = esc
        elseif esc == "b" then chunks[#chunks + 1] = "\b"
        elseif esc == "f" then chunks[#chunks + 1] = "\f"
        elseif esc == "n" then chunks[#chunks + 1] = "\n"
        elseif esc == "r" then chunks[#chunks + 1] = "\r"
        elseif esc == "t" then chunks[#chunks + 1] = "\t"
        elseif esc == "u" then
          local hex = str:sub(pos + 1, pos + 4)
          local code = tonumber(hex, 16)
          if not code then error("Invalid \\u escape at position " .. pos) end
          pos = pos + 4
          if utf8 and utf8.char and (code < 0xD800 or code > 0xDFFF) then
            chunks[#chunks + 1] = utf8.char(code)
          else
            chunks[#chunks + 1] = "?"
          end
        else
          chunks[#chunks + 1] = esc
        end
        pos = pos + 1
      else
        local next_special = str:find('["\\]', pos)
        if not next_special then error("Unterminated JSON string") end
        chunks[#chunks + 1] = str:sub(pos, next_special - 1)
        pos = next_special
      end
    end
    error("Unterminated JSON string")
  end

  local function parse_number()
    local s, e = str:find("^%-?%d+%.?%d*[eE]?[%+%-]?%d*", pos)
    if not s then error("Invalid JSON number at position " .. pos) end
    local num = tonumber(str:sub(s, e))
    if not num then error("Invalid JSON number at position " .. pos) end
    pos = e + 1
    return num
  end

  local function parse_array()
    pos = pos + 1 -- skip '['
    local arr = {}
    local idx = 0
    skip_ws()
    if str:sub(pos, pos) == "]" then
      pos = pos + 1
      return arr
    end
    while pos <= len do
      skip_ws()
      idx = idx + 1
      arr[idx] = parse_value()
      skip_ws()
      local c = str:sub(pos, pos)
      if c == "]" then
        pos = pos + 1
        return arr
      elseif c == "," then
        pos = pos + 1
      else
        error("Expected ',' or ']' at position " .. pos)
      end
    end
    error("Unterminated JSON array")
  end

  local function parse_object()
    pos = pos + 1 -- skip '{'
    local obj = {}
    skip_ws()
    if str:sub(pos, pos) == "}" then
      pos = pos + 1
      return obj
    end
    while pos <= len do
      skip_ws()
      if str:sub(pos, pos) ~= '"' then
        error("Expected object key string at position " .. pos)
      end
      local key = parse_string()
      skip_ws()
      if str:sub(pos, pos) ~= ":" then
        error("Expected ':' at position " .. pos)
      end
      pos = pos + 1
      skip_ws()
      obj[key] = parse_value()
      skip_ws()
      local c = str:sub(pos, pos)
      if c == "}" then
        pos = pos + 1
        return obj
      elseif c == "," then
        pos = pos + 1
      else
        error("Expected ',' or '}' at position " .. pos)
      end
    end
    error("Unterminated JSON object")
  end

  parse_value = function()
    skip_ws()
    local c = str:sub(pos, pos)
    if c == "{" then
      return parse_object()
    elseif c == "[" then
      return parse_array()
    elseif c == '"' then
      return parse_string()
    elseif c == "-" or (c >= "0" and c <= "9") then
      return parse_number()
    elseif str:sub(pos, pos + 3) == "true" then
      pos = pos + 4
      return true
    elseif str:sub(pos, pos + 4) == "false" then
      pos = pos + 5
      return false
    elseif str:sub(pos, pos + 3) == "null" then
      pos = pos + 4
      return nil
    else
      error("Unexpected JSON token '" .. c .. "' at position " .. pos)
    end
  end

  skip_ws()
  if pos > len then error("Empty JSON response") end
  return parse_value()
end

-- ============================================================================
-- Preferences & credential helpers
-- ============================================================================

local function read_str_pref(key, default)
  local val = dt.preferences.read(MODULE, key, "string")
  if val == nil or val == "" then return default end
  return val
end

local function read_bool_pref(key, default)
  local val = dt.preferences.read(MODULE, key, "bool")
  if val == nil then return default end
  return val
end

local function load_password(auth_user)
  if auth_user and auth_user ~= "" and dt.password and dt.password.get then
    local ok, pw = pcall(dt.password.get, MODULE, auth_user)
    if ok and pw and pw ~= "" then
      return pw
    end
  end
  return read_str_pref("http_pass_fallback", "")
end

local function save_password(auth_user, password)
  local saved_in_keyring = false
  if auth_user and auth_user ~= "" and dt.password and dt.password.save then
    local ok, res = pcall(dt.password.save, MODULE, auth_user, password or "")
    if ok and res then
      saved_in_keyring = true
      -- Clear fallback if keyring storage succeeded
      dt.preferences.write(MODULE, "http_pass_fallback", "string", "")
    end
  end
  if not saved_in_keyring then
    dt.preferences.write(MODULE, "http_pass_fallback", "string", password or "")
  end
end

local function save_settings()
  local w = state.widgets
  local url = (w.url.text or ""):match("^%s*(.-)%s*$")
  local ot_user = (w.ot_user.text or ""):match("^%s*(.-)%s*$")
  local ot_device = (w.ot_device.text or ""):match("^%s*(.-)%s*$")
  local http_user = (w.http_user.text or ""):match("^%s*(.-)%s*$")
  local http_pass = w.http_pass.text or ""
  local offset = (w.utc_offset.text or ""):match("^%s*(.-)%s*$")

  dt.preferences.write(MODULE, "recorder_url", "string", url)
  dt.preferences.write(MODULE, "ot_user", "string", ot_user)
  dt.preferences.write(MODULE, "ot_device", "string", ot_device)
  dt.preferences.write(MODULE, "http_user", "string", http_user)
  dt.preferences.write(MODULE, "utc_offset", "string", offset)
  dt.preferences.write(MODULE, "allow_insecure", "bool", w.allow_insecure.value)

  local effective_auth_user = (http_user ~= "") and http_user or ot_user
  save_password(effective_auth_user, http_pass)
end

-- ============================================================================
-- OwnTracks Recorder HTTP fetch via Windows curl.exe (-K config file)
-- ============================================================================

local function escape_curl_val(s)
  return (s or ""):gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\r", ""):gsub("\n", "")
end

local function normalize_locations_url(raw_url)
  local u = (raw_url or ""):match("^%s*(.-)%s*$"):gsub("/+$", "")
  if u == "" then return nil end
  if not u:match("/api/0/locations$") then
    u = u .. "/api/0/locations"
  end
  return u
end

local function get_temp_dir()
  local dir = dt.configuration.tmp_dir
  if not dir or dir == "" then
    dir = os.getenv("TEMP") or os.getenv("TMP") or "."
  end
  return dir:gsub("[/\\]+$", "")
end

local function fetch_owntracks_points(cfg, from_epoch, to_epoch)
  local endpoint = normalize_locations_url(cfg.url)
  if not endpoint then
    return nil, "Recorder URL is empty."
  end

  math.randomseed(os.time() + math.floor((os.clock() or 0) * 1000))
  local tmp_dir = get_temp_dir()
  local token = string.format("dt_ot_%d_%06d", os.time(), math.random(0, 999999))
  local cfg_path = tmp_dir .. PS .. token .. "_cfg.txt"
  local out_path = tmp_dir .. PS .. token .. "_out.json"
  local meta_path = tmp_dir .. PS .. token .. "_meta.txt"

  local from_iso = epoch_to_iso_utc(from_epoch)
  local to_iso = epoch_to_iso_utc(to_epoch)

  local lines = {
    'url = "' .. escape_curl_val(endpoint) .. '"',
    "get",
    "silent",
    "show-error",
    "location",
    "connect-timeout = 15",
    "max-time = 120",
    'data-urlencode = "user=' .. escape_curl_val(cfg.ot_user) .. '"',
    'data-urlencode = "device=' .. escape_curl_val(cfg.ot_device) .. '"',
    'data-urlencode = "from=' .. escape_curl_val(from_iso) .. '"',
    'data-urlencode = "to=' .. escape_curl_val(to_iso) .. '"',
    'data-urlencode = "format=json"',
    'data-urlencode = "fields=tst,lat,lon,alt"',
    'output = "' .. escape_curl_val(out_path) .. '"',
    'write-out = "\\nHTTP_CODE:%{http_code}\\n"',
  }

  local auth_user = (cfg.http_user ~= "") and cfg.http_user or cfg.ot_user
  if auth_user ~= "" or cfg.http_pass ~= "" then
    lines[#lines + 1] = 'user = "' .. escape_curl_val(auth_user .. ":" .. cfg.http_pass) .. '"'
  end

  if cfg.allow_insecure then
    lines[#lines + 1] = "insecure"
  end

  local f_cfg, err_open = io.open(cfg_path, "wb")
  if not f_cfg then
    return nil, "Failed to create temporary curl config: " .. tostring(err_open)
  end
  f_cfg:write(table.concat(lines, "\n") .. "\n")
  f_cfg:close()

  local curl_bin = (dt.configuration.running_os == "windows") and "curl.exe" or "curl"
  local cmd = string.format('%s -K "%s" > "%s" 2>&1', curl_bin, cfg_path, meta_path)
  dt.print_log(MODULE .. ": querying " .. endpoint .. " (" .. from_iso .. " to " .. to_iso .. " UTC)")

  local exit_code = dt.control.execute(cmd)

  -- Read metadata (HTTP status + curl stderr) and response body, then immediately delete temp files
  local meta_text = ""
  local f_meta = io.open(meta_path, "rb")
  if f_meta then
    meta_text = f_meta:read("*a") or ""
    f_meta:close()
  end

  local body_text = ""
  local f_out = io.open(out_path, "rb")
  if f_out then
    body_text = f_out:read("*a") or ""
    f_out:close()
  end

  os.remove(cfg_path)
  os.remove(out_path)
  os.remove(meta_path)

  local http_code = tonumber(meta_text:match("HTTP_CODE:(%d%d%d)")) or 0
  local clean_err = meta_text:gsub("HTTP_CODE:%d%d%d", ""):match("^%s*(.-)%s*$")

  if exit_code ~= 0 then
    return nil, string.format("curl error (exit %s): %s", tostring(exit_code), clean_err ~= "" and clean_err or "request failed")
  end

  if http_code == 401 or http_code == 403 then
    return nil, string.format("Authentication failed (HTTP %d). Check HTTP username/password.", http_code)
  elseif http_code ~= 200 then
    return nil, string.format("Recorder returned HTTP %d. %s", http_code, clean_err)
  end

  local ok_json, parsed = pcall(decode_json, body_text)
  if not ok_json or type(parsed) ~= "table" then
    return nil, "Failed to parse Recorder JSON response: " .. tostring(parsed)
  end

  -- Recorder returns { count = N, data = [ ... ] }
  local raw_list = parsed.data or parsed
  if type(raw_list) ~= "table" then
    return nil, "Unexpected JSON structure from OwnTracks Recorder."
  end

  local points = {}
  for _, item in ipairs(raw_list) do
    if type(item) == "table" then
      local tst = tonumber(item.tst)
      local lat = tonumber(item.lat)
      local lon = tonumber(item.lon)
      local alt = tonumber(item.alt)
      if tst and lat and lon then
        points[#points + 1] = {
          tst = tst,
          lat = lat,
          lon = lon,
          alt = alt, -- nil if absent
        }
      end
    end
  end

  table.sort(points, function(a, b) return a.tst < b.tst end)

  -- Deduplicate identical timestamps (keep latest entry)
  local dedup = {}
  for _, p in ipairs(points) do
    if #dedup > 0 and dedup[#dedup].tst == p.tst then
      dedup[#dedup] = p
    else
      dedup[#dedup + 1] = p
    end
  end

  return dedup, nil
end

-- ============================================================================
-- Linear interpolation (with antimeridian wrap & endpoint clamping)
-- ============================================================================

local function interpolate_location(points, target_utc)
  local n = #points
  if n == 0 then return nil end

  -- Clamp to nearest endpoint if outside track range
  if target_utc <= points[1].tst then
    return points[1].lat, points[1].lon, points[1].alt
  end
  if target_utc >= points[n].tst then
    return points[n].lat, points[n].lon, points[n].alt
  end

  -- Binary search for largest index lo where points[lo].tst <= target_utc
  local lo, hi = 1, n
  while lo + 1 < hi do
    local mid = math.floor((lo + hi) / 2)
    if points[mid].tst <= target_utc then
      lo = mid
    else
      hi = mid
    end
  end

  local p1, p2 = points[lo], points[hi]
  local dt_sec = p2.tst - p1.tst
  local alpha = (dt_sec > 0) and ((target_utc - p1.tst) / dt_sec) or 0

  local lat = p1.lat + alpha * (p2.lat - p1.lat)

  -- Shortest-path longitude interpolation across +/-180 deg
  local dlon = p2.lon - p1.lon
  if dlon > 180 then
    dlon = dlon - 360
  elseif dlon < -180 then
    dlon = dlon + 360
  end
  local lon = p1.lon + alpha * dlon
  if lon > 180 then
    lon = lon - 360
  elseif lon < -180 then
    lon = lon + 360
  end

  local alt = nil
  if p1.alt ~= nil and p2.alt ~= nil then
    alt = p1.alt + alpha * (p2.alt - p1.alt)
  elseif p1.alt ~= nil then
    alt = p1.alt
  elseif p2.alt ~= nil then
    alt = p2.alt
  end

  return lat, lon, alt
end

-- ============================================================================
-- Main workflow
-- ============================================================================

local function image_has_gps(img)
  local lat, lon = img.latitude, img.longitude
  -- Guard against nil and NaN
  return (lat ~= nil and lon ~= nil and lat == lat and lon == lon)
end

local function set_status(msg, is_error)
  if state.widgets.status then
    state.widgets.status.label = msg
  end
  if is_error then
    dt.print_error(MODULE .. ": " .. msg)
    dt.print("OwnTracks: " .. msg)
  else
    dt.print_log(MODULE .. ": " .. msg)
    dt.print("OwnTracks: " .. msg)
  end
end

local function apply_owntracks_gps()
  local w = state.widgets
  save_settings()

  local cfg = {
    url = (w.url.text or ""):match("^%s*(.-)%s*$"),
    ot_user = (w.ot_user.text or ""):match("^%s*(.-)%s*$"),
    ot_device = (w.ot_device.text or ""):match("^%s*(.-)%s*$"),
    http_user = (w.http_user.text or ""):match("^%s*(.-)%s*$"),
    http_pass = w.http_pass.text or "",
    allow_insecure = w.allow_insecure.value,
  }

  if cfg.url == "" or cfg.ot_user == "" or cfg.ot_device == "" then
    set_status("Set Recorder URL, OwnTracks user, and device first.", true)
    return
  end

  local offset_sec, offset_err = parse_offset_seconds(w.utc_offset.text)
  if not offset_sec then
    set_status(offset_err, true)
    return
  end

  local overwrite = w.overwrite.value
  local selected_only = w.selected_only.value

  local source_list = selected_only and dt.gui.action_images or dt.collection
  local target_images = {}
  local seen_ids = {}

  local function add_image(img)
    if img and img.id and not seen_ids[img.id] then
      seen_ids[img.id] = true
      target_images[#target_images + 1] = img
    end
  end

  for _, img in ipairs(source_list) do
    add_image(img)
    local ok_grp, members = pcall(function() return img:get_group_members() end)
    if ok_grp and type(members) == "table" then
      for _, member in ipairs(members) do
        add_image(member)
      end
    end
  end

  if #target_images == 0 then
    set_status(selected_only and "No images selected." or "Current collection is empty.", true)
    return
  end

  -- Filter candidates & find UTC timestamp bounds
  local candidates = {}
  local skipped_existing = 0
  local skipped_no_date = 0
  local min_utc, max_utc = nil, nil

  for _, img in ipairs(target_images) do
    if (not overwrite) and image_has_gps(img) then
      skipped_existing = skipped_existing + 1
    else
      local local_epoch = parse_exif_datetime(img.exif_datetime_taken)
      if not local_epoch then
        skipped_no_date = skipped_no_date + 1
      else
        -- UTC = Camera local time - UTC offset
        local utc_epoch = local_epoch - offset_sec
        candidates[#candidates + 1] = { img = img, utc = utc_epoch }
        if not min_utc or utc_epoch < min_utc then min_utc = utc_epoch end
        if not max_utc or utc_epoch > max_utc then max_utc = utc_epoch end
      end
    end
  end

  if #candidates == 0 then
    set_status(string.format(
      "Nothing to update (skipped %d with GPS, %d without EXIF date).",
      skipped_existing, skipped_no_date
    ), false)
    return
  end

  local job = dt.gui.create_job("OwnTracks geotagging", true, function(j) j.valid = false end)
  job.percent = 0.1

  local ok_run, run_err = pcall(function()
    local points, fetch_err = fetch_owntracks_points(
      cfg,
      min_utc - QUERY_PADDING_SEC,
      max_utc + QUERY_PADDING_SEC
    )

    if not points then
      set_status(fetch_err, true)
      return
    end

    if #points == 0 then
      set_status("No OwnTracks locations found in this time range.", true)
      return
    end

    job.percent = 0.5
    local updated = 0
    local total = #candidates

    for i, item in ipairs(candidates) do
      if not job.valid then
        set_status(string.format("Cancelled after updating %d / %d images.", updated, total), false)
        return
      end

      local lat, lon, alt = interpolate_location(points, item.utc)
      if lat and lon then
        item.img.latitude = lat
        item.img.longitude = lon
        if alt ~= nil then
          item.img.elevation = alt
        end
        updated = updated + 1
      end

      if i % 10 == 0 or i == total then
        job.percent = 0.5 + 0.5 * (i / total)
      end
    end

    set_status(string.format(
      "Updated %d image(s) from %d points (skipped %d GPS, %d no date).",
      updated, #points, skipped_existing, skipped_no_date
    ), false)
  end)

  job.valid = false
  if not ok_run then
    set_status("Unexpected error: " .. tostring(run_err), true)
  end
end

-- ============================================================================
-- Lighttable UI module registration
-- ============================================================================

local function build_ui()
  local w = state.widgets

  local saved_url = read_str_pref("recorder_url", "")
  local saved_ot_user = read_str_pref("ot_user", "")
  local saved_ot_device = read_str_pref("ot_device", "")
  local saved_http_user = read_str_pref("http_user", "")
  local saved_offset = read_str_pref("utc_offset", get_system_offset_string())
  local saved_insecure = read_bool_pref("allow_insecure", false)

  local effective_auth_user = (saved_http_user ~= "") and saved_http_user or saved_ot_user
  local saved_http_pass = load_password(effective_auth_user)

  w.utc_offset = dt.new_widget("entry") {
    text = saved_offset,
    placeholder = "+07:00",
    tooltip = "Camera timezone offset from UTC (e.g. +07:00, -04:00, +05:30, or +07:00:15). UTC = camera time - offset.",
  }

  w.overwrite = dt.new_widget("check_button") {
    label = "Overwrite existing GPS",
    value = false,
    tooltip = "When unchecked, images that already have GPS coordinates are skipped.",
  }

  w.selected_only = dt.new_widget("check_button") {
    label = "Selected images only",
    value = false,
    tooltip = "Unchecked: process full current collection. Checked: process selected images only.",
  }

  w.apply_btn = dt.new_widget("button") {
    label = "Apply OwnTracks GPS",
    tooltip = "Fetch OwnTracks Recorder history and interpolate GPS coordinates.",
    clicked_callback = apply_owntracks_gps,
  }

  w.status = dt.new_widget("label") {
    label = "Ready.",
    halign = "start",
  }

  w.url = dt.new_widget("entry") {
    text = saved_url,
    placeholder = "https://owntracks.example.com",
    tooltip = "Base URL of your OwnTracks Recorder (/api/0/locations is appended automatically if omitted).",
  }

  w.ot_user = dt.new_widget("entry") {
    text = saved_ot_user,
    placeholder = "owntracks user",
    tooltip = "OwnTracks user ID stored in Recorder.",
  }

  w.ot_device = dt.new_widget("entry") {
    text = saved_ot_device,
    placeholder = "phone",
    tooltip = "OwnTracks device ID stored in Recorder.",
  }

  w.http_user = dt.new_widget("entry") {
    text = saved_http_user,
    placeholder = "(same as OT user if blank)",
    tooltip = "HTTP Basic Auth username. Leave blank to reuse the OwnTracks user.",
  }

  w.http_pass = dt.new_widget("entry") {
    text = saved_http_pass,
    is_password = true,
    placeholder = "HTTP Basic Auth password",
    tooltip = "HTTP Basic Auth password for your Recorder endpoint.",
  }

  w.allow_insecure = dt.new_widget("check_button") {
    label = "Allow self-signed HTTPS",
    value = saved_insecure,
    tooltip = "Passes --insecure to curl. Only enable for self-signed TLS certificates.",
  }

  w.save_btn = dt.new_widget("button") {
    label = "Save connection settings",
    clicked_callback = function()
      save_settings()
      set_status("Connection settings saved.", false)
    end,
  }

  w.main_box = dt.new_widget("box") {
    orientation = "vertical",

    dt.new_widget("label") { label = "Camera UTC offset", halign = "start" },
    w.utc_offset,
    w.overwrite,
    w.selected_only,
    w.apply_btn,
    w.status,

    dt.new_widget("separator") {},
    dt.new_widget("section_label") { label = "OwnTracks Recorder" },

    dt.new_widget("label") { label = "Recorder URL", halign = "start" },
    w.url,
    dt.new_widget("label") { label = "OwnTracks user", halign = "start" },
    w.ot_user,
    dt.new_widget("label") { label = "OwnTracks device", halign = "start" },
    w.ot_device,
    dt.new_widget("label") { label = "HTTP auth user", halign = "start" },
    w.http_user,
    dt.new_widget("label") { label = "HTTP auth password", halign = "start" },
    w.http_pass,
    w.allow_insecure,
    w.save_btn,
  }
end

local function install_module()
  if not state.module_installed then
    build_ui()
    dt.register_lib(
      MODULE,
      "OwnTracks geotag",
      true,  -- expandable
      false, -- resettable
      { [dt.gui.views.lighttable] = { "DT_UI_CONTAINER_PANEL_RIGHT_CENTER", 500 } },
      state.widgets.main_box,
      nil,
      nil
    )
    state.module_installed = true
  end
end

if dt.gui.current_view().id == "lighttable" then
  install_module()
else
  if not state.event_registered then
    dt.register_event(MODULE, "view-changed", function(_, _, new_view)
      if new_view.id == "lighttable" then
        install_module()
      end
    end)
    state.event_registered = true
  end
end

-- Script manager compatibility
local script_data = {}
script_data.metadata = {
  name = "OwnTracks geotag",
  purpose = "Geotag collection images by interpolating GPS data from OwnTracks Recorder",
  author = "Custom",
  help = "",
}
script_data.destroy_method = "hide"
script_data.destroy = function()
  if dt.gui.libs[MODULE] then
    dt.gui.libs[MODULE].visible = false
  end
end
script_data.restart = function()
  if dt.gui.libs[MODULE] then
    dt.gui.libs[MODULE].visible = true
  end
end
script_data.show = script_data.restart

return script_data
