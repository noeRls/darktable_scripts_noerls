--[[
  custom_export for darktable (Windows)

  Workflow:
  - Validates strict 1 RAW + 1 JPG pairing for every image in scope (fails fast otherwise).
  - Recognizes .ARW and all standard camera RAW extensions even before darktable opens them.
  - Expands collapsed RAW+JPG groups automatically.
  - Skips rejected pairs (rating == -1).
  - Reuses darktable's native Export module output directory & JPEG quality.
  - RAW rated 5 stars: exported via darktable's built-in JPEG format.
  - RAW below 5 stars: paired camera JPG copied 1:1 losslessly, then GPS-only
    metadata from the JPG's own darktable DB record is written to the copy
    via a single batched ExifTool (-stay_open True) invocation.
]]

local dt = require "darktable"

local MODULE = "custom_export"
local IS_WIN = (dt.configuration.running_os == "windows")
local PS = IS_WIN and "\\" or "/"

local RAW_EXTENSIONS = {
  arw = true, srf = true, sr2 = true, -- Sony
  cr2 = true, cr3 = true, crw = true, -- Canon
  nef = true, nrw = true,             -- Nikon
  raf = true,                         -- Fujifilm
  orf = true,                         -- Olympus / OM System
  rw2 = true,                         -- Panasonic
  dng = true,                         -- Adobe / Leica / Pentax / phones
  pef = true,                         -- Pentax
  srw = true,                         -- Samsung
  x3f = true,                         -- Sigma
  iiq = true, ["3fr"] = true, fff = true, rwl = true,
  erf = true, mef = true, mrw = true, kdc = true,
  dcr = true, gpr = true, raw = true, mos = true,
}

local state = {
  module_installed = false,
  event_registered = false,
  widgets = {},
}

-- ============================================================================
-- Preferences helpers
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

local function save_settings()
  local w = state.widgets
  local et = (w.exiftool_path.text or ""):match("^%s*(.-)%s*$")
  dt.preferences.write(MODULE, "exiftool_path", "string", et)
  dt.preferences.write(MODULE, "overwrite", "bool", w.overwrite.value)
  dt.preferences.write(MODULE, "selected_only", "bool", w.selected_only.value)
end

-- ============================================================================
-- Path, filesystem & process utilities (Windows-safe)
-- ============================================================================

local function normalize_path(p)
  if not p then return "" end
  local out = p:match("^%s*(.-)%s*$")
  if IS_WIN then
    out = out:gsub("/", "\\")
    local is_unc = out:sub(1, 2) == "\\\\"
    if is_unc then
      out = "\\\\" .. out:sub(3):gsub("\\+", "\\")
    else
      out = out:gsub("\\+", "\\")
    end
    if #out > 3 or not out:match("^%a:\\$") then
      out = out:gsub("\\+$", "")
    end
  else
    out = out:gsub("/+", "/")
    if #out > 1 then out = out:gsub("/+$", "") end
  end
  return out
end

local function path_key(p)
  local norm = normalize_path(p)
  return IS_WIN and norm:lower() or norm
end

local function split_ext(filename)
  local base, ext = filename:match("^(.*)%.([^%.]+)$")
  if not base or base == "" then
    return filename, ""
  end
  return base, ext:lower()
end

local function parent_dir(path)
  local norm = normalize_path(path)
  local dir = norm:match("^(.*)[/\\][^/\\]+$")
  if dir and IS_WIN and dir:match("^%a:$") then
    dir = dir .. "\\"
  end
  return dir
end

local function last_segment(path)
  local norm = normalize_path(path)
  return norm:match("([^/\\]+)$") or norm
end

local function file_exists(path)
  local f = io.open(path, "rb")
  if f then
    f:close()
    return true
  end
  return false
end

local function get_temp_dir()
  local dir = dt.configuration.tmp_dir
  if not dir or dir == "" then
    dir = os.getenv("TEMP") or os.getenv("TMP") or "."
  end
  return normalize_path(dir)
end

local function strip_wrapping_quotes(s)
  local t = (s or ""):match("^%s*(.-)%s*$")
  if (#t >= 2) and (t:sub(1, 1) == '"') and (t:sub(-1) == '"') then
    t = t:sub(2, -2)
  end
  return t
end

-- Safe command execution on Windows (avoids cmd /c quote-stripping bugs)
local function run_cmd_to_log(exe_path, args_str, log_path)
  local exe = strip_wrapping_quotes(exe_path)
  local cmd
  if IS_WIN then
    cmd = string.format('cmd /c ""%s" %s > "%s" 2>&1"', exe, args_str, log_path)
  else
    cmd = string.format('"%s" %s > "%s" 2>&1', exe, args_str, log_path)
  end
  return dt.control.execute(cmd)
end

local function ensure_dir(dir_path, cache)
  local norm = normalize_path(dir_path)
  local key = path_key(norm)
  if cache[key] then return true end

  local exit_code
  if IS_WIN then
    local target = norm
    if #target > 3 then target = target:gsub("\\+$", "") end
    local cmd = string.format('cmd /c "if not exist "%s" mkdir "%s""', target, target)
    exit_code = dt.control.execute(cmd)
  else
    local cmd = string.format('mkdir -p "%s"', norm)
    exit_code = dt.control.execute(cmd)
  end

  if exit_code ~= 0 then
    return false, "Failed to create output directory: " .. norm
  end
  cache[key] = true
  return true
end

-- Pure-Lua 1:1 binary file copy (lossless, no shell escaping issues)
local function copy_file_binary(src_path, dst_path)
  local fin, err_in = io.open(src_path, "rb")
  if not fin then
    return false, "Cannot read source JPG: " .. tostring(err_in)
  end

  local fout, err_out = io.open(dst_path, "wb")
  if not fout then
    fin:close()
    return false, "Cannot write destination JPG: " .. tostring(err_out)
  end

  local chunk_size = 1048576 -- 1 MiB
  while true do
    local chunk = fin:read(chunk_size)
    if not chunk then break end
    local ok_w, err_w = fout:write(chunk)
    if not ok_w then
      fin:close()
      fout:close()
      os.remove(dst_path)
      return false, "Write error on destination JPG: " .. tostring(err_w)
    end
  end

  fin:close()
  fout:close()
  return true
end

-- ============================================================================
-- Native darktable export path template expansion
-- ============================================================================

local function parse_exif_parts(dt_str)
  if not dt_str or dt_str == "" then return nil end
  local y, m, d, H, M, S =
    dt_str:match("^(%d%d%d%d)[:%-](%d%d)[:%-](%d%d)[ T](%d%d):(%d%d):(%d%d)")
  if not y then return nil end
  return { y = y, m = m, d = d, H = H, M = M, S = S }
end

local function expand_export_path(template, raw, jpg, base_name)
  local tpl = (template or ""):match("^%s*(.-)%s*$")
  if tpl == "" then
    return nil, "Native Export output directory is empty. Configure it in the Export module first."
  end

  local src_folder = normalize_path(raw.path)
  local roll_name = last_segment(src_folder)
  local home = normalize_path(os.getenv("USERPROFILE") or os.getenv("HOME") or "")
  local exif = parse_exif_parts(raw.exif_datetime_taken) or parse_exif_parts(jpg.exif_datetime_taken)

  local vars = {
    FILE_FOLDER = src_folder,
    ["FILE.FOLDER"] = src_folder,
    FILE_DIRECTORY = src_folder,
    FILE_NAME = base_name,
    ["FILE.NAME"] = base_name,
    FILE_EXTENSION = "jpg",
    ["FILE.EXTENSION"] = "jpg",
    ROLL_NAME = roll_name,
    ["ROLL.NAME"] = roll_name,
    HOME = home,
    ["FOLDER.HOME"] = home,
    PICTURES_FOLDER = (home ~= "") and (home .. PS .. "Pictures") or nil,
    ["FOLDER.PICTURES"] = (home ~= "") and (home .. PS .. "Pictures") or nil,
    DESKTOP = (home ~= "") and (home .. PS .. "Desktop") or nil,
    ["FOLDER.DESKTOP"] = (home ~= "") and (home .. PS .. "Desktop") or nil,
  }

  if exif then
    vars.EXIF_YEAR, vars["EXIF.YEAR"] = exif.y, exif.y
    vars.EXIF_MONTH, vars["EXIF.MONTH"] = exif.m, exif.m
    vars.EXIF_DAY, vars["EXIF.DAY"] = exif.d, exif.d
    vars.EXIF_HOUR, vars["EXIF.HOUR"] = exif.H, exif.H
    vars.EXIF_MINUTE, vars["EXIF.MINUTE"] = exif.M, exif.M
    vars.EXIF_SECOND, vars["EXIF.SECOND"] = exif.S, exif.S
  end

  local has_filename_var = (tpl:find("%$%(FILE[%.%_]NAME%)") ~= nil)

  local expanded = tpl:gsub("%$%(([^%)]+)%)", function(token)
    local replacement = vars[token]
    if replacement ~= nil then
      return replacement
    end
    return "$(" .. token .. ")"
  end)

  local unresolved = expanded:match("(%$%([^%)]+%))")
  if unresolved then
    return nil, "Unsupported native Export variable " .. unresolved .. " in: " .. tpl
  end

  expanded = normalize_path(expanded)

  local out_path
  if has_filename_var then
    if expanded:lower():match("%.jpe?g$") then
      out_path = expanded
    else
      out_path = expanded .. ".jpg"
    end
  else
    out_path = normalize_path(expanded .. PS .. base_name .. ".jpg")
  end

  return out_path, nil
end

-- ============================================================================
-- ExifTool helpers (GPS-only explicit allow-list, single batched run)
-- ============================================================================

local function image_has_gps(img)
  local lat, lon = img.latitude, img.longitude
  return (lat ~= nil and lon ~= nil and lat == lat and lon == lon)
end

local function make_temp_token()
  math.randomseed(os.time() + math.floor((os.clock() or 0) * 1000))
  return string.format("dt_cexp_%d_%06d", os.time(), math.random(0, 999999))
end

local function verify_exiftool(exiftool_bin)
  local log_path = get_temp_dir() .. PS .. make_temp_token() .. "_etver.txt"
  local exit_code = run_cmd_to_log(exiftool_bin, "-ver", log_path)

  local output = ""
  local f = io.open(log_path, "rb")
  if f then
    output = (f:read("*a") or ""):match("^%s*(.-)%s*$")
    f:close()
  end
  os.remove(log_path)

  if exit_code ~= 0 or not output:match("^%d+%.%d+") then
    return false, string.format(
      "ExifTool check failed for '%s' (exit %s). %s",
      exiftool_bin,
      tostring(exit_code),
      output ~= "" and output or "Verify ExifTool is installed and on PATH."
    )
  end
  return true, output
end

local function sanitize_arg_line(s)
  return (s or ""):gsub("[\r\n]", "")
end

local function run_exiftool_gps_batch(exiftool_bin, batch)
  if #batch == 0 then return true, 0 end

  local tmp_dir = get_temp_dir()
  local token = make_temp_token()
  local arg_path = tmp_dir .. PS .. token .. "_args.txt"
  local log_path = tmp_dir .. PS .. token .. "_log.txt"

  local lines = {}
  for _, item in ipairs(batch) do
    local lat = item.lat
    local lon = item.lon
    local alt = item.alt

    lines[#lines + 1] = "-charset"
    lines[#lines + 1] = "filename=UTF8"
    lines[#lines + 1] = "-overwrite_original"
    lines[#lines + 1] = string.format("-GPSLatitude=%.8f", math.abs(lat))
    lines[#lines + 1] = "-GPSLatitudeRef=" .. ((lat >= 0) and "N" or "S")
    lines[#lines + 1] = string.format("-GPSLongitude=%.8f", math.abs(lon))
    lines[#lines + 1] = "-GPSLongitudeRef=" .. ((lon >= 0) and "E" or "W")

    if alt ~= nil and alt == alt then
      lines[#lines + 1] = string.format("-GPSAltitude=%.2f", math.abs(alt))
      lines[#lines + 1] = "-GPSAltitudeRef#=" .. ((alt >= 0) and "0" or "1")
    end

    lines[#lines + 1] = sanitize_arg_line(item.out_path)
    lines[#lines + 1] = "-execute"
  end

  lines[#lines + 1] = "-stay_open"
  lines[#lines + 1] = "False"

  local f_arg, err_open = io.open(arg_path, "wb")
  if not f_arg then
    return false, "Failed to write ExifTool argfile: " .. tostring(err_open)
  end
  f_arg:write(table.concat(lines, "\n") .. "\n")
  f_arg:close()

  dt.print_log(MODULE .. ": writing GPS via ExifTool for " .. #batch .. " copied JPG(s)")
  local args_str = string.format('-stay_open True -@ "%s"', arg_path)
  local exit_code = run_cmd_to_log(exiftool_bin, args_str, log_path)

  local log_text = ""
  local f_log = io.open(log_path, "rb")
  if f_log then
    log_text = f_log:read("*a") or ""
    f_log:close()
  end

  os.remove(arg_path)
  os.remove(log_path)

  if exit_code ~= 0 then
    dt.print_error(MODULE .. ": ExifTool failed:\n" .. log_text)
    return false, "ExifTool exited with code " .. tostring(exit_code) .. ". Check Lua log for details."
  end

  local err_line = log_text:match("(Error:[^\r\n]+)")
  if err_line or log_text:find("weren't updated due to errors", 1, true) then
    dt.print_error(MODULE .. ": ExifTool reported errors:\n" .. log_text)
    return false, "ExifTool error: " .. (err_line or "one or more JPGs failed to update.")
  end

  local updated_count = 0
  for n in log_text:gmatch("(%d+) image files updated") do
    updated_count = updated_count + (tonumber(n) or 0)
  end

  return true, updated_count
end

-- ============================================================================
-- Main workflow
-- ============================================================================

local function set_status(msg, is_error)
  if state.widgets.status then
    state.widgets.status.label = msg
  end
  if is_error then
    dt.print_error(MODULE .. ": " .. msg)
    dt.print(MODULE .. ": " .. msg)
  else
    dt.print_log(MODULE .. ": " .. msg)
    dt.print(MODULE .. ": " .. msg)
  end
end

local function run_export()
  local w = state.widgets
  save_settings()

  local selected_only = w.selected_only.value
  local overwrite = w.overwrite.value
  local exiftool_bin = strip_wrapping_quotes(w.exiftool_path.text)
  if exiftool_bin == "" then exiftool_bin = IS_WIN and "exiftool.exe" or "exiftool" end

  -- 1. Read native darktable Export module preferences
  local export_dir_tpl = dt.preferences.read("darktable", "plugins/imageio/storage/disk/file_directory", "string")
  if not export_dir_tpl or export_dir_tpl:match("^%s*$") then
    set_status("Native Export folder is not set in darktable's Export module.", true)
    return
  end

  local jpeg_quality = dt.preferences.read("darktable", "plugins/imageio/format/jpeg/quality", "integer")
  if not jpeg_quality or jpeg_quality < 5 or jpeg_quality > 100 then
    jpeg_quality = 95
  end

  -- 2. Collect target images (expand collapsed darktable groups & deduplicate)
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

  -- 3. Strict RAW + JPG grouping & pre-flight validation (fail fast)
  local groups = {}
  local group_order = {}
  local unexpected_files = {}

  for _, img in ipairs(target_images) do
    local base, ext = split_ext(img.filename)
    local is_jpg = (ext == "jpg" or ext == "jpeg")
    local is_raw = (not is_jpg) and (RAW_EXTENSIONS[ext] == true or img.is_raw == true)

    if not is_jpg and not is_raw then
      unexpected_files[#unexpected_files + 1] = img.filename
    else
      local gkey = path_key(img.path) .. "\0" .. (IS_WIN and base:lower() or base)
      local g = groups[gkey]
      if not g then
        g = {
          key = gkey,
          path = img.path,
          base = base,
          raws = {},
          jpgs = {},
        }
        groups[gkey] = g
        group_order[#group_order + 1] = g
      end
      if is_jpg then
        g.jpgs[#g.jpgs + 1] = img
      else
        g.raws[#g.raws + 1] = img
      end
    end
  end

  table.sort(group_order, function(a, b) return a.key < b.key end)

  local errors = {}
  for _, name in ipairs(unexpected_files) do
    errors[#errors + 1] = name .. " (neither RAW nor JPG)"
  end

  for _, g in ipairs(group_order) do
    if #g.raws ~= 1 or #g.jpgs ~= 1 then
      errors[#errors + 1] = string.format("%s (%d RAW, %d JPG)", g.base, #g.raws, #g.jpgs)
    end
  end

  if #errors > 0 then
    for _, e in ipairs(errors) do
      dt.print_error(MODULE .. ": pairing error -> " .. e)
    end
    local preview = {}
    for i = 1, math.min(#errors, 3) do
      preview[#preview + 1] = errors[i]
    end
    local suffix = (#errors > 3) and string.format(" (+%d more, see Lua log)", #errors - 3) or ""
    set_status("Aborted: strict RAW+JPG check failed: " .. table.concat(preview, "; ") .. suffix, true)
    return
  end

  -- 4. Pre-resolve all destination paths, skip rejected/existing, check collisions
  local plan = {}
  local seen_outputs = {}
  local skipped_rejected = 0
  local skipped_existing = 0
  local needs_exiftool = false

  for _, g in ipairs(group_order) do
    local raw = g.raws[1]
    local jpg = g.jpgs[1]

    if raw.rating == -1 or jpg.rating == -1 then
      skipped_rejected = skipped_rejected + 1
    else
      local out_path, path_err = expand_export_path(export_dir_tpl, raw, jpg, g.base)
      if not out_path then
        set_status("Aborted: " .. path_err, true)
        return
      end

      local out_key = path_key(out_path)
      local src_jpg_path = normalize_path(jpg.path .. PS .. jpg.filename)
      local src_raw_path = normalize_path(raw.path .. PS .. raw.filename)

      if out_key == path_key(src_jpg_path) or out_key == path_key(src_raw_path) then
        set_status("Aborted: export path points to original file (" .. out_path .. ").", true)
        return
      end

      if seen_outputs[out_key] then
        set_status("Aborted: duplicate output filename collision -> " .. out_path, true)
        return
      end
      seen_outputs[out_key] = true

      if (not overwrite) and file_exists(out_path) then
        skipped_existing = skipped_existing + 1
      else
        local is_five_star = (raw.rating == 5)
        local jpg_has_gps = (not is_five_star) and image_has_gps(jpg)
        if jpg_has_gps then
          needs_exiftool = true
        end

        plan[#plan + 1] = {
          base = g.base,
          raw = raw,
          jpg = jpg,
          src_jpg_path = src_jpg_path,
          out_path = out_path,
          out_dir = parent_dir(out_path),
          is_five_star = is_five_star,
          jpg_has_gps = jpg_has_gps,
        }
      end
    end
  end

  if #plan == 0 then
    set_status(string.format(
      "Nothing to export (skipped %d rejected, %d existing).",
      skipped_rejected, skipped_existing
    ), false)
    return
  end

  -- 5. Fail-fast ExifTool check before exporting RAWs if any copied JPG needs GPS
  if needs_exiftool then
    local ok_et, et_info = verify_exiftool(exiftool_bin)
    if not ok_et then
      set_status("Aborted: " .. et_info, true)
      return
    end
    dt.print_log(MODULE .. ": using ExifTool v" .. et_info)
  end

  -- 6. Execute export plan
  local job = dt.gui.create_job("custom_export", true, function(j) j.valid = false end)
  job.percent = 0.0

  local ok_run, run_err = pcall(function()
    local created_dirs = {}
    local jpeg_exporter = nil
    local gps_batch = {}

    local exported_raws = 0
    local copied_jpgs = 0
    local copied_no_gps = 0
    local total = #plan

    for i, item in ipairs(plan) do
      if not job.valid then
        set_status(string.format(
          "Cancelled (%d RAW exported, %d JPG copied before stop).",
          exported_raws, copied_jpgs
        ), false)
        return
      end

      local ok_dir, dir_err = ensure_dir(item.out_dir, created_dirs)
      if not ok_dir then
        set_status(dir_err, true)
        return
      end

      if item.is_five_star then
        if not jpeg_exporter then
          jpeg_exporter = dt.new_format("jpeg")
          jpeg_exporter.quality = jpeg_quality
        end

        if overwrite and file_exists(item.out_path) then
          os.remove(item.out_path)
        end

        local ok_call, res = pcall(function()
          return jpeg_exporter:write_image(item.raw, item.out_path)
        end)

        if (not ok_call) or (not file_exists(item.out_path)) then
          set_status("Failed exporting 5-star RAW " .. item.raw.filename .. ": " .. tostring(res), true)
          return
        end
        exported_raws = exported_raws + 1
      else
        local ok_cp, cp_err = copy_file_binary(item.src_jpg_path, item.out_path)
        if not ok_cp then
          set_status("Failed copying JPG " .. item.jpg.filename .. ": " .. tostring(cp_err), true)
          return
        end
        copied_jpgs = copied_jpgs + 1

        -- GPS from JPG record ONLY (no fallback to paired RAW)
        if item.jpg_has_gps then
          gps_batch[#gps_batch + 1] = {
            out_path = item.out_path,
            lat = item.jpg.latitude,
            lon = item.jpg.longitude,
            alt = item.jpg.elevation,
          }
        else
          copied_no_gps = copied_no_gps + 1
        end
      end

      job.percent = 0.85 * (i / total)
    end

    local tagged_jpgs = 0
    if #gps_batch > 0 then
      local ok_gps, gps_res = run_exiftool_gps_batch(exiftool_bin, gps_batch)
      if not ok_gps then
        set_status(gps_res, true)
        return
      end
      tagged_jpgs = gps_res
    end

    job.percent = 1.0
    set_status(string.format(
      "Done: %d 5-star RAW exported, %d JPG copied (%d GPS written, %d no GPS), skipped %d rejected / %d existing.",
      exported_raws, copied_jpgs, tagged_jpgs, copied_no_gps, skipped_rejected, skipped_existing
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

  local saved_et = read_str_pref("exiftool_path", IS_WIN and "exiftool.exe" or "exiftool")
  local saved_overwrite = read_bool_pref("overwrite", false)
  local saved_selected = read_bool_pref("selected_only", false)

  w.overwrite = dt.new_widget("check_button") {
    label = "Overwrite existing output files",
    value = saved_overwrite,
    tooltip = "Unchecked: skip pairs whose destination JPG already exists.",
  }

  w.selected_only = dt.new_widget("check_button") {
    label = "Selected images only",
    value = saved_selected,
    tooltip = "Unchecked: process full current collection. Checked: process selected images only.",
  }

  w.exiftool_path = dt.new_widget("entry") {
    text = saved_et,
    placeholder = "exiftool.exe",
    tooltip = "ExifTool executable name (if on PATH) or full path (e.g. C:\\Tools\\exiftool\\exiftool.exe).",
  }

  w.export_btn = dt.new_widget("button") {
    label = "Run custom_export",
    tooltip = "Uses native Export module folder & JPEG quality. 5-star RAWs are rendered; other pairs copy JPG losslessly + write GPS.",
    clicked_callback = run_export,
  }

  w.status = dt.new_widget("label") {
    label = "Ready (uses native Export folder).",
    halign = "start",
  }

  w.main_box = dt.new_widget("box") {
    orientation = "vertical",

    w.overwrite,
    w.selected_only,
    dt.new_widget("label") { label = "ExifTool executable", halign = "start" },
    w.exiftool_path,
    w.export_btn,
    w.status,
  }
end

local function install_module()
  if not state.module_installed then
    build_ui()
    dt.register_lib(
      MODULE,
      "custom_export",
      true,  -- expandable
      false, -- resettable
      { [dt.gui.views.lighttable] = { "DT_UI_CONTAINER_PANEL_RIGHT_CENTER", 501 } },
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
  name = "custom_export",
  purpose = "Export 5-star RAWs via darktable JPEG and losslessly copy remaining JPGs with GPS",
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