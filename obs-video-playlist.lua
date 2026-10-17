--[[
================================================================================
  動画プレイリスト for OBS  (obs-video-playlist.lua)

  メディアソースに「動画プレイリスト」フィルタを付けると、登録した動画を
  順番またはランダムで連続再生し続けます。
  並べ替えや再生状況の確認は、同梱の video-playlist-dock.html を
  「カスタムブラウザドック」として追加すると GUI で操作できます。

  必要環境 : OBS Studio 28 以降（obs-websocket 内蔵版） / Windows・macOS・Linux
================================================================================
]]

obs = obslua

local VERSION     = "1.1.0"
local FILTER_ID   = "vp_video_playlist"
local FILTER_NAME = "動画プレイリスト"

-- フォルダ追加時に拾う拡張子（小文字）。必要に応じて追加してください。
local VIDEO_EXTS = {
	mp4 = true, m4v = true, mov = true, mkv = true, webm = true, avi = true,
	flv = true, wmv = true, mpg = true, mpeg = true, ts = true, mts = true,
	m2ts = true, ogv = true, ["3gp"] = true, mxf = true, gif = true,
}

local FILE_FILTER = "動画ファイル (*.mp4 *.m4v *.mov *.mkv *.webm *.avi *.flv *.wmv *.mpg *.mpeg *.ts *.mts *.m2ts *.ogv *.3gp *.mxf *.gif);;すべてのファイル (*.*)"

local MAX_SCAN_DEPTH = 10

-- ---------------------------------------------------------------------------
-- 共有状態
-- ---------------------------------------------------------------------------
local instances = {}     -- 生きているフィルタインスタンスの集合
local now_ms = 0         -- タイマーで進める経過時間（ミリ秒）
local hotkey_ids = {}
local pending_create = nil
local create_folder = ""        -- 「作成」時に最初に入れる動画フォルダ（スクリプト画面で選択）
local create_recursive = false  -- そのフォルダのサブフォルダも読み込むか
local dock_seen = 0             -- ドックからコマンドが最後に届いた時刻（os.time）。0 = まだ一度も届いていない

math.randomseed(os.time())
math.random(); math.random(); math.random()

local function log(msg)
	obs.script_log(obs.LOG_INFO, msg)
end

-- 想定内の問題（ファイルが無い等）は INFO で記録する。
-- OBS は WARNING 以上を記録するとスクリプトログ画面を自動で開いてしまうため。
local function warn(msg)
	obs.script_log(obs.LOG_INFO, "⚠ " .. msg)
end

-- 想定外のエラー（不具合）だけ WARNING で記録する
local function bug(msg)
	obs.script_log(obs.LOG_WARNING, msg)
end

-- ---------------------------------------------------------------------------
-- JSON（ドックとのやり取り・状態保存用の最小実装）
-- ---------------------------------------------------------------------------
local ARRAY_MT = { __jsontype = "array" }
local function jarray(t) return setmetatable(t or {}, ARRAY_MT) end

local ESCAPES = {
	['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f",
	["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t",
}

local function json_string(s)
	local out = s:gsub('[%c"\\]', function(c)
		return ESCAPES[c] or string.format("\\u%04x", c:byte())
	end)
	return '"' .. out .. '"'
end

local function json_encode(v)
	local t = type(v)
	if v == nil then
		return "null"
	elseif t == "boolean" then
		return v and "true" or "false"
	elseif t == "number" then
		if v ~= v or v == math.huge or v == -math.huge then return "null" end
		if math.floor(v) == v and math.abs(v) < 1e15 then
			return string.format("%.0f", v)
		end
		return string.format("%.14g", v)
	elseif t == "string" then
		return json_string(v)
	elseif t == "table" then
		if getmetatable(v) == ARRAY_MT or v[1] ~= nil then
			local out = {}
			for i = 1, #v do out[i] = json_encode(v[i]) end
			return "[" .. table.concat(out, ",") .. "]"
		end
		local keys = {}
		for k in pairs(v) do keys[#keys + 1] = tostring(k) end
		table.sort(keys)
		local out = {}
		for _, k in ipairs(keys) do
			out[#out + 1] = json_string(k) .. ":" .. json_encode(v[k])
		end
		return "{" .. table.concat(out, ",") .. "}"
	end
	return "null"
end

local function utf8_char(cp)
	local floor = math.floor
	if cp < 0x80 then
		return string.char(cp)
	elseif cp < 0x800 then
		return string.char(0xC0 + floor(cp / 0x40), 0x80 + cp % 0x40)
	elseif cp < 0x10000 then
		return string.char(0xE0 + floor(cp / 0x1000), 0x80 + floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
	end
	return string.char(0xF0 + floor(cp / 0x40000), 0x80 + floor(cp / 0x1000) % 0x40,
		0x80 + floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
end

local function json_decode(str)
	local pos = 1
	local SIMPLE = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }

	-- OBS は error() を「ログを出すだけ」に差し替えているため assert で中断する
	local function fail(msg) assert(false, "JSON " .. msg .. " (位置 " .. pos .. ")") end
	local function skip_ws() pos = str:find("[^ \t\r\n]", pos) or (#str + 1) end

	local parse_value

	local function parse_string()
		pos = pos + 1
		local buf = {}
		while true do
			local c = str:sub(pos, pos)
			if c == "" then fail("文字列が閉じていません") end
			if c == '"' then
				pos = pos + 1
				break
			elseif c == "\\" then
				local e = str:sub(pos + 1, pos + 1)
				if SIMPLE[e] then
					buf[#buf + 1] = SIMPLE[e]
					pos = pos + 2
				elseif e == "u" then
					local cp = tonumber(str:sub(pos + 2, pos + 5), 16)
					if not cp then fail("\\u が不正です") end
					pos = pos + 6
					if cp >= 0xD800 and cp <= 0xDBFF and str:sub(pos, pos + 1) == "\\u" then
						local lo = tonumber(str:sub(pos + 2, pos + 5), 16)
						if lo and lo >= 0xDC00 and lo <= 0xDFFF then
							cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
							pos = pos + 6
						end
					end
					buf[#buf + 1] = utf8_char(cp)
				else
					fail("エスケープが不正です")
				end
			else
				local s, e = str:find('^[^"\\]+', pos)
				buf[#buf + 1] = str:sub(s, e)
				pos = e + 1
			end
		end
		return table.concat(buf)
	end

	local function parse_array()
		pos = pos + 1
		local res = jarray({})
		skip_ws()
		if str:sub(pos, pos) == "]" then
			pos = pos + 1
			return res
		end
		while true do
			res[#res + 1] = parse_value()
			skip_ws()
			local c = str:sub(pos, pos)
			pos = pos + 1
			if c == "]" then return res end
			if c ~= "," then fail("配列の区切りが不正です") end
		end
	end

	local function parse_object()
		pos = pos + 1
		local res = {}
		skip_ws()
		if str:sub(pos, pos) == "}" then
			pos = pos + 1
			return res
		end
		while true do
			skip_ws()
			if str:sub(pos, pos) ~= '"' then fail("キーが必要です") end
			local k = parse_string()
			skip_ws()
			if str:sub(pos, pos) ~= ":" then fail(": が必要です") end
			pos = pos + 1
			res[k] = parse_value()
			skip_ws()
			local c = str:sub(pos, pos)
			pos = pos + 1
			if c == "}" then return res end
			if c ~= "," then fail("オブジェクトの区切りが不正です") end
		end
	end

	parse_value = function()
		skip_ws()
		local c = str:sub(pos, pos)
		if c == "{" then return parse_object() end
		if c == "[" then return parse_array() end
		if c == '"' then return parse_string() end
		if str:sub(pos, pos + 3) == "true" then pos = pos + 4; return true end
		if str:sub(pos, pos + 4) == "false" then pos = pos + 5; return false end
		if str:sub(pos, pos + 3) == "null" then pos = pos + 4; return nil end
		local s, e = str:find("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
		if s then
			pos = e + 1
			return tonumber(str:sub(s, e))
		end
		fail("予期しない文字 '" .. c .. "'")
	end

	local v = parse_value()
	return v
end

-- ---------------------------------------------------------------------------
-- パス関連
-- ---------------------------------------------------------------------------
local function url_decode(s)
	return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

local function url_encode_path(s)
	return (s:gsub("[^%w%-%._~/:]", function(c) return string.format("%%%02X", c:byte()) end))
end

local function is_url(p)
	return p:match("^%a[%w%+%.%-]*://") ~= nil and not p:match("^[Ff][Ii][Ll][Ee]://")
end

local function normalize_path(p)
	if type(p) ~= "string" then return nil end
	p = p:gsub("^%s+", ""):gsub("%s+$", "")
	p = p:gsub('^"(.*)"$', "%1"):gsub("^'(.*)'$", "%1")
	if p == "" then return nil end
	if is_url(p) then return p end
	if p:match("^[Ff][Ii][Ll][Ee]://") then
		p = p:gsub("^[Ff][Ii][Ll][Ee]://localhost", ""):gsub("^[Ff][Ii][Ll][Ee]://", "")
		p = url_decode(p)
		if p:match("^/%a:[/\\]") then p = p:sub(2) end
	end
	p = p:gsub("\\", "/")
	while #p > 1 and p:sub(-1) == "/" and not p:match("^%a:/$") do
		p = p:sub(1, -2)
	end
	if p == "" then return nil end
	return p
end

local function basename(p)
	return p:match("([^/]+)$") or p
end

local function extension(name)
	local e = name:match("%.([^%.]+)$")
	return e and e:lower() or ""
end

local function is_video_name(name)
	return VIDEO_EXTS[extension(name)] == true
end

-- 自然順ソート（"2.mp4" が "10.mp4" より前に来る）
local function natural_less(a, b)
	a, b = a:lower(), b:lower()
	local ia, ib = 1, 1
	local la, lb = #a, #b
	while ia <= la and ib <= lb do
		local na = a:match("^%d+", ia)
		local nb = b:match("^%d+", ib)
		if na and nb then
			local va, vb = tonumber(na), tonumber(nb)
			if va ~= vb then return va < vb end
			if #na ~= #nb then return #na < #nb end
			ia = ia + #na
			ib = ib + #nb
		else
			local ca, cb = a:sub(ia, ia), b:sub(ib, ib)
			if ca ~= cb then return ca < cb end
			ia = ia + 1
			ib = ib + 1
		end
	end
	return (la - ia) < (lb - ib)
end

local function is_dir(path)
	local d = obs.os_opendir(path)
	if d ~= nil then
		obs.os_closedir(d)
		return true
	end
	return false
end

local function scan_dir(path, recursive, out, depth)
	local d = obs.os_opendir(path)
	if d == nil then return end
	local files, dirs = {}, {}
	while true do
		local ent = obs.os_readdir(d)
		if ent == nil then break end
		local name = ent.d_name
		if name and name ~= "" and name:sub(1, 1) ~= "." then
			if ent.directory then
				dirs[#dirs + 1] = name
			elseif is_video_name(name) then
				files[#files + 1] = name
			end
		end
	end
	obs.os_closedir(d)
	table.sort(files, natural_less)
	table.sort(dirs, natural_less)
	local base = (path:sub(-1) == "/") and path or (path .. "/")
	for _, f in ipairs(files) do out[#out + 1] = base .. f end
	if recursive and depth < MAX_SCAN_DEPTH then
		for _, sub in ipairs(dirs) do scan_dir(base .. sub, true, out, depth + 1) end
	end
end

-- パス（ファイル／フォルダ／URL）の一覧を、再生できるエントリの一覧に展開する
local function expand_paths(paths, recursive)
	local entries, missing, folders = {}, 0, 0
	for _, raw in ipairs(paths) do
		local p = normalize_path(raw)
		if p then
			if is_url(p) then
				entries[#entries + 1] = { path = p, url = true }
			elseif is_dir(p) then
				folders = folders + 1
				local files = {}
				scan_dir(p, recursive, files, 0)
				for _, f in ipairs(files) do entries[#entries + 1] = { path = f } end
			elseif obs.os_file_exists(p) then
				entries[#entries + 1] = { path = p }
			else
				missing = missing + 1
				warn("見つかりません: " .. p)
			end
		end
	end
	return entries, missing, folders
end

-- ---------------------------------------------------------------------------
-- プレイリスト本体
-- ---------------------------------------------------------------------------
local function index_of(list, v)
	for i = 1, #list do
		if list[i] == v then return i end
	end
	return nil
end

local function rebuild_index(inst)
	inst.by_id = {}
	for _, it in ipairs(inst.items) do inst.by_id[it.id] = it end
end

local function play_order(inst)
	if inst.mode == "random" then return inst.shuffle end
	local o = {}
	for i, it in ipairs(inst.items) do o[i] = it.id end
	return o
end

local function shuffle_in_place(t)
	for i = #t, 2, -1 do
		local j = math.random(i)
		t[i], t[j] = t[j], t[i]
	end
	return t
end

-- first_id を先頭に固定して残りをシャッフル（ランダム切替時・シャッフルし直し時）
local function make_shuffle(inst, first_id)
	local ids = {}
	for _, it in ipairs(inst.items) do
		if it.id ~= first_id then ids[#ids + 1] = it.id end
	end
	shuffle_in_place(ids)
	if first_id and inst.by_id[first_id] then table.insert(ids, 1, first_id) end
	inst.shuffle = ids
end

-- 一巡したあとの再シャッフル。直前の動画がいきなり連続しないようにする
local function reshuffle_cycle(inst, avoid_id)
	local ids = {}
	for _, it in ipairs(inst.items) do ids[#ids + 1] = it.id end
	shuffle_in_place(ids)
	if #ids > 1 and ids[1] == avoid_id then
		local j = math.random(2, #ids)
		ids[1], ids[j] = ids[j], ids[1]
	end
	inst.shuffle = ids
end

-- shuffle を items と矛盾しない状態にそろえる
local function validate_shuffle(inst)
	local seen, ids = {}, {}
	for _, id in ipairs(inst.shuffle or {}) do
		if inst.by_id[id] and not seen[id] then
			seen[id] = true
			ids[#ids + 1] = id
		end
	end
	for _, it in ipairs(inst.items) do
		if not seen[it.id] then
			table.insert(ids, math.random(#ids + 1), it.id)
		end
	end
	inst.shuffle = ids
end

local function set_message(inst, msg)
	inst.msg = msg
	inst.msg_id = (inst.msg_id or 0) + 1
	inst.dirty = true
end

local function get_parent(inst)
	if inst.source == nil then return nil end
	return obs.obs_filter_get_parent(inst.source)
end

local function is_media_source(p)
	return p ~= nil and obs.obs_source_get_unversioned_id(p) == "ffmpeg_source"
end

local function stop_media(inst)
	local p = get_parent(inst)
	if is_media_source(p) then obs.obs_source_media_stop(p) end
end

local function play_id(inst, id)
	local it = inst.by_id[id]
	if not it then return false end
	inst.current = id
	inst.ended = false
	inst.error = nil
	inst.dirty = true
	inst.switch_at = now_ms
	inst.seen_play = false

	local p = get_parent(inst)
	if not is_media_source(p) then
		inst.pending_play = true
		return true
	end
	inst.pending_play = false

	local cur = obs.obs_source_get_settings(p)
	local key = it.url and "input" or "local_file"
	local same = (obs.obs_data_get_bool(cur, "is_local_file") == (not it.url))
		and obs.obs_data_get_string(cur, key) == it.path
	obs.obs_data_release(cur)

	local s = obs.obs_data_create()
	obs.obs_data_set_bool(s, "is_local_file", not it.url)
	obs.obs_data_set_string(s, key, it.path)
	obs.obs_data_set_bool(s, "looping", false)
	obs.obs_source_update(p, s)
	obs.obs_data_release(s)

	-- 同じファイルを続けて流す場合は、設定更新だけでは再生し直されない
	if same then obs.obs_source_media_restart(p) end
	return true
end

-- dir = 1:次 / -1:前。auto=true は「再生終了による自動送り」
local function advance(inst, dir, auto)
	local ord = play_order(inst)
	local n = #ord
	if n == 0 then
		if inst.current ~= nil then inst.current = nil; inst.dirty = true end
		return
	end
	local pos = inst.current and index_of(ord, inst.current)
	local npos
	if not pos then
		npos = (dir > 0) and 1 or n
	else
		npos = pos + dir
	end
	if npos > n then
		if auto and not inst.loop then
			inst.ended = true
			inst.dirty = true
			return
		end
		if inst.mode == "random" then
			reshuffle_cycle(inst, inst.current)
			ord = inst.shuffle
		end
		npos = 1
	elseif npos < 1 then
		npos = n
	end
	play_id(inst, ord[npos])
end

local function play_from_start(inst)
	if #inst.items == 0 then return end
	if inst.mode == "random" then reshuffle_cycle(inst, inst.current) end
	play_id(inst, play_order(inst)[1])
end

-- 再生順・ループはフィルタ設定にも即座に書き戻す（後続の update で古い値に戻されないように）
local function write_mode_settings(inst)
	if inst.source == nil then return end
	local s = obs.obs_source_get_settings(inst.source)
	if s == nil then return end
	obs.obs_data_set_string(s, "vp_mode", inst.mode)
	obs.obs_data_set_bool(s, "vp_loop", inst.loop)
	obs.obs_data_release(s)
end

local function set_mode(inst, mode)
	if mode ~= "random" then mode = "sequential" end
	if inst.mode == mode then return end
	inst.mode = mode
	if mode == "random" then make_shuffle(inst, inst.current) end
	inst.dirty = true
	write_mode_settings(inst)
end

local function set_loop(inst, loop)
	loop = loop and true or false
	if inst.loop == loop then return end
	inst.loop = loop
	inst.dirty = true
	write_mode_settings(inst)
end

-- entries を追加する。position = "end"（末尾）| "next"（次に再生）
local function add_entries(inst, entries, position, play_now)
	local existing = {}
	for _, it in ipairs(inst.items) do existing[it.path] = true end

	local new_items, dup = {}, 0
	for _, e in ipairs(entries) do
		if existing[e.path] then
			dup = dup + 1
		else
			existing[e.path] = true
			local id = inst.next_id
			inst.next_id = id + 1
			new_items[#new_items + 1] = { id = id, path = e.path, name = basename(e.path), url = e.url or nil }
		end
	end
	if #new_items == 0 then return 0, dup end

	local was_idle = (inst.current == nil) or (inst.by_id[inst.current] == nil)
	local was_ended = inst.ended

	-- 基本の並び（items）へ挿入
	local cur_item_pos
	if position == "next" and inst.current then
		for i, it in ipairs(inst.items) do
			if it.id == inst.current then cur_item_pos = i break end
		end
	end
	if cur_item_pos then
		for k, it in ipairs(new_items) do table.insert(inst.items, cur_item_pos + k, it) end
	else
		for _, it in ipairs(new_items) do inst.items[#inst.items + 1] = it end
	end
	rebuild_index(inst)

	-- ランダム時の再生順（shuffle）へ挿入
	if inst.mode == "random" then
		local cpos = inst.current and index_of(inst.shuffle, inst.current) or 0
		if position == "next" and cpos > 0 then
			for k, it in ipairs(new_items) do table.insert(inst.shuffle, cpos + k, it.id) end
		elseif was_idle then
			make_shuffle(inst, nil)
		else
			for _, it in ipairs(new_items) do
				table.insert(inst.shuffle, math.random(cpos + 1, #inst.shuffle + 1), it.id)
			end
		end
	end
	inst.dirty = true

	if play_now then
		play_id(inst, new_items[1].id)
	elseif was_idle then
		play_id(inst, play_order(inst)[1])
	elseif was_ended then
		advance(inst, 1, false)
	end
	return #new_items, dup
end

local function add_paths(inst, paths, recursive, position, play_now)
	local entries, missing, folders = expand_paths(paths, recursive)
	local added, dup = add_entries(inst, entries, position, play_now)
	local parts = {}
	if added > 0 then parts[#parts + 1] = added .. "本を追加しました" end
	if dup > 0 then parts[#parts + 1] = dup .. "本は登録済みのためスキップ" end
	if missing > 0 then parts[#parts + 1] = missing .. "件のパスが見つかりません" end
	if added == 0 and dup == 0 and missing == 0 then
		if folders > 0 then
			parts[#parts + 1] = "フォルダ内に動画ファイルが見つかりませんでした"
		else
			parts[#parts + 1] = "追加できる動画がありませんでした"
		end
	end
	set_message(inst, table.concat(parts, "・"))
	-- 1本も入らなかった理由は、リストが空のあいだフィルタ画面に表示する
	if added == 0 and dup == 0 then inst.add_problem = inst.msg else inst.add_problem = nil end
	log(string.format("[%s] %s", inst.parent_name or "?", inst.msg))
	return added
end

local function remove_ids(inst, ids)
	local rm = {}
	for _, id in ipairs(ids) do
		id = tonumber(id)
		if id then rm[id] = true end
	end

	local ord = play_order(inst)
	local cur_removed = inst.current ~= nil and rm[inst.current] == true
	local next_id
	if cur_removed and not inst.ended then
		local pos = index_of(ord, inst.current) or 0
		for k = pos + 1, #ord do
			if not rm[ord[k]] then next_id = ord[k] break end
		end
		if not next_id and inst.loop then
			for k = 1, pos - 1 do
				if not rm[ord[k]] then next_id = ord[k] break end
			end
		end
	end

	local items = {}
	for _, it in ipairs(inst.items) do
		if not rm[it.id] then items[#items + 1] = it end
	end
	inst.items = items
	local sh = {}
	for _, id in ipairs(inst.shuffle) do
		if not rm[id] then sh[#sh + 1] = id end
	end
	inst.shuffle = sh
	rebuild_index(inst)
	inst.dirty = true

	if cur_removed then
		if next_id then
			play_id(inst, next_id)
		else
			inst.current = nil
			inst.ended = false
			stop_media(inst)
		end
	end
end

local function clear_all(inst)
	inst.items, inst.shuffle, inst.by_id = {}, {}, {}
	inst.current = nil
	inst.ended = false
	inst.dirty = true
	stop_media(inst)
end

local function reorder(inst, order)
	local seen, new = {}, {}
	for _, id in ipairs(order or {}) do
		id = tonumber(id)
		if id and inst.by_id[id] and not seen[id] then
			seen[id] = true
			new[#new + 1] = id
		end
	end
	for _, id in ipairs(play_order(inst)) do
		if not seen[id] then
			seen[id] = true
			new[#new + 1] = id
		end
	end
	if inst.mode == "random" then
		inst.shuffle = new
	else
		local items = {}
		for i, id in ipairs(new) do items[i] = inst.by_id[id] end
		inst.items = items
	end
	inst.dirty = true
end

local function sort_by_name(inst)
	table.sort(inst.items, function(a, b)
		if a.name ~= b.name then return natural_less(a.name, b.name) end
		return natural_less(a.path, b.path)
	end)
	if inst.mode == "random" then make_shuffle(inst, inst.current) end
	inst.dirty = true
end

-- ---------------------------------------------------------------------------
-- ドックからのコマンド
-- ---------------------------------------------------------------------------
local function exec_command(inst, c)
	local op = c.op
	if op == "add" then
		local paths = c.paths
		if type(paths) == "string" then paths = { paths } end
		if type(paths) ~= "table" then return end
		local recursive = c.recursive
		if recursive == nil then recursive = inst.recursive end
		add_paths(inst, paths, recursive, c.position or "end", c.play == true)
	elseif op == "remove" then
		remove_ids(inst, c.ids or {})
	elseif op == "clear" then
		clear_all(inst)
	elseif op == "reorder" then
		reorder(inst, c.order)
	elseif op == "play" then
		local id = tonumber(c.item)
		if id and inst.by_id[id] then
			play_id(inst, id)
		elseif inst.ended or inst.current == nil then
			play_from_start(inst)
		else
			play_id(inst, inst.current)
		end
	elseif op == "next" then
		advance(inst, 1, false)
	elseif op == "prev" then
		advance(inst, -1, false)
	elseif op == "reshuffle" then
		if inst.mode == "random" then make_shuffle(inst, inst.current) end
		inst.dirty = true
	elseif op == "sort" then
		sort_by_name(inst)
	elseif op == "mode" then
		set_mode(inst, c.value)
	elseif op == "loop" then
		set_loop(inst, c.value == true)
	elseif op == "ping" then
		inst.dirty = true
	else
		warn("不明なコマンド: " .. tostring(op))
	end
end

local function process_cmds(inst, str)
	if str == nil or str == "" then return end
	local ok, list = pcall(json_decode, str)
	if not ok or type(list) ~= "table" then
		warn("コマンドを解釈できません: " .. tostring(list))
		return
	end
	table.sort(list, function(a, b) return (tonumber(a.id) or 0) < (tonumber(b.id) or 0) end)
	for _, c in ipairs(list) do
		local cid = tonumber(c.id) or 0
		if cid > inst.ack then
			inst.ack = cid
			dock_seen = os.time()  -- セットアップ状況の「ドック：接続を確認済み」に使う
			local ok2, err = pcall(exec_command, inst, c)
			if not ok2 then bug("コマンド実行エラー: " .. tostring(err)) end
			inst.dirty = true
		end
	end
end

-- プロパティ画面の「ファイル／フォルダを追加」に入ったものを取り込む
local function process_inbox(inst, settings)
	local arr = obs.obs_data_get_array(settings, "vp_inbox")
	if arr == nil then return false end
	local paths = {}
	local n = obs.obs_data_array_count(arr)
	for i = 0, n - 1 do
		local item = obs.obs_data_array_item(arr, i)
		local v = obs.obs_data_get_string(item, "value")
		if v ~= nil and v ~= "" then paths[#paths + 1] = v end
		obs.obs_data_release(item)
	end
	obs.obs_data_array_release(arr)
	if #paths == 0 then return false end

	local empty = obs.obs_data_array_create()
	obs.obs_data_set_array(settings, "vp_inbox", empty)
	obs.obs_data_array_release(empty)

	add_paths(inst, paths, obs.obs_data_get_bool(settings, "vp_recursive"), "end", false)
	return true
end

-- ---------------------------------------------------------------------------
-- 状態の保存・復元（フィルタ設定 vp_state に JSON で保持。シーンコレクションと一緒に保存される）
-- ---------------------------------------------------------------------------
local function state_table(inst)
	local items = jarray({})
	for i, it in ipairs(inst.items) do
		items[i] = { id = it.id, path = it.path, name = it.name, url = it.url or nil, dur = it.dur }
	end
	local order = jarray({})
	for i, id in ipairs(play_order(inst)) do order[i] = id end
	local shuffle = jarray({})
	for i, id in ipairs(inst.shuffle) do shuffle[i] = id end
	return {
		v = 1,
		version = VERSION,
		rev = inst.rev,
		ack = inst.ack,
		next_id = inst.next_id,
		mode = inst.mode,
		loop = inst.loop,
		current = inst.current,
		ended = inst.ended,
		items = items,
		order = order,
		shuffle = shuffle,
		parent = inst.parent_name,
		error = inst.error,
		warning = inst.warning,
		msg = inst.msg,
		msg_id = inst.msg_id,
	}
end

local function flush_state(inst)
	inst.rev = (inst.rev or 0) + 1
	local s = obs.obs_source_get_settings(inst.source)
	if s == nil then return end
	obs.obs_data_set_string(s, "vp_state", json_encode(state_table(inst)))
	obs.obs_data_set_string(s, "vp_mode", inst.mode)
	obs.obs_data_set_bool(s, "vp_loop", inst.loop)
	obs.obs_data_release(s)
	inst.dirty = false
end

local function restore_state(inst, str)
	if str == nil or str == "" then return end
	local ok, st = pcall(json_decode, str)
	if not ok or type(st) ~= "table" then
		warn("保存されたプレイリストを読み込めませんでした: " .. tostring(st))
		return
	end
	local max_id = 0
	for _, it in ipairs(st.items or {}) do
		local id = tonumber(it.id)
		if id and type(it.path) == "string" and it.path ~= "" then
			inst.items[#inst.items + 1] = {
				id = id, path = it.path, name = it.name or basename(it.path), url = it.url and true or nil,
				dur = tonumber(it.dur),
			}
			if id > max_id then max_id = id end
		end
	end
	rebuild_index(inst)
	for _, id in ipairs(st.shuffle or {}) do inst.shuffle[#inst.shuffle + 1] = tonumber(id) end
	inst.next_id = math.max(tonumber(st.next_id) or 1, max_id + 1)
	inst.ack = tonumber(st.ack) or 0
	inst.rev = tonumber(st.rev) or 0
	inst.msg_id = tonumber(st.msg_id) or 0
	local cur = tonumber(st.current)
	if cur and inst.by_id[cur] then inst.current = cur end
	inst.ended = st.ended == true
end

local function format_duration(ms)
	local s = math.floor((ms or 0) / 1000)
	local h, m, sec = math.floor(s / 3600), math.floor(s % 3600 / 60), s % 60
	if h > 0 then return string.format("%d:%02d:%02d", h, m, sec) end
	return string.format("%d:%02d", m, sec)
end

local function status_text(inst)
	if inst == nil then return "" end
	local lines = {}
	if inst.warning then lines[#lines + 1] = "⚠ " .. inst.warning end
	if #inst.items == 0 then
		if inst.add_problem then lines[#lines + 1] = "⚠ " .. inst.add_problem end
		lines[#lines + 1] = "まだ動画がありません。下の「ファイル／フォルダを追加」の ＋ から追加してください。"
	else
		local ord = play_order(inst)
		local pos = inst.current and index_of(ord, inst.current)
		local it = inst.current and inst.by_id[inst.current]
		if it and inst.ended then
			lines[#lines + 1] = string.format("■ 再生終了（%d本）  最後: %s", #ord, it.name)
		elseif it then
			lines[#lines + 1] = string.format("▶ 再生中 %d / %d : %s", pos or 0, #ord, it.name)
		else
			lines[#lines + 1] = string.format("登録 %d本（停止中）", #ord)
		end
	end
	if inst.error then lines[#lines + 1] = "⚠ " .. inst.error end
	return table.concat(lines, "\n")
end

-- ---------------------------------------------------------------------------
-- 毎フレームの監視（再生が終わったら次へ）
-- ---------------------------------------------------------------------------
local STATE = {
	ENDED     = obs.OBS_MEDIA_STATE_ENDED,
	PLAYING   = obs.OBS_MEDIA_STATE_PLAYING,
	PAUSED    = obs.OBS_MEDIA_STATE_PAUSED,
	OPENING   = obs.OBS_MEDIA_STATE_OPENING,
	BUFFERING = obs.OBS_MEDIA_STATE_BUFFERING,
}

local function fail_advance(inst, reason)
	inst.fail_count = (inst.fail_count or 0) + 1
	local it = inst.current and inst.by_id[inst.current]
	warn("再生できませんでした（" .. reason .. "）: " .. (it and it.path or "?"))
	if inst.fail_count > math.max(5, #inst.items * 2) then
		inst.ended = true
		inst.error = "再生できる動画が見つかりません。ファイルの場所や形式を確認してください。"
		inst.dirty = true
		return
	end
	advance(inst, 1, true)
end

local function tick_instance(inst)
	local p = get_parent(inst)
	local pname = p and obs.obs_source_get_name(p) or nil
	if pname ~= inst.parent_name then
		inst.parent_name = pname
		inst.dirty = true
	end
	if p == nil then return end

	if not is_media_source(p) then
		if not inst.warning then
			inst.warning = "このフィルタは「メディアソース」に追加してください。"
			inst.dirty = true
		end
		return
	elseif inst.warning then
		inst.warning = nil
		inst.dirty = true
	end

	if not obs.obs_source_enabled(inst.source) then return end

	if inst.pending_play then
		if inst.current and inst.by_id[inst.current] then
			play_id(inst, inst.current)
		else
			inst.pending_play = false
		end
		return
	end
	if inst.current == nil or inst.ended then return end

	local since = now_ms - inst.switch_at
	if since < 150 then return end  -- 設定反映前の古い状態を読まないための猶予

	local st = obs.obs_source_media_get_state(p)
	if st == STATE.ENDED and inst.seen_play then
		if since < 500 then
			inst.fail_count = (inst.fail_count or 0) + 1
			if inst.fail_count > math.max(5, #inst.items * 2) then
				fail_advance(inst, "すぐに終了")
				return
			end
		else
			inst.fail_count = 0
		end
		advance(inst, 1, true)
	elseif st == STATE.PLAYING or st == STATE.PAUSED or st == STATE.OPENING or st == STATE.BUFFERING then
		inst.seen_play = true
		if st == STATE.PLAYING then
			local it = inst.by_id[inst.current]
			local healthy = (it and it.url) or obs.obs_source_media_get_duration(p) > 0
				or obs.obs_source_media_get_time(p) > 0
			if healthy then
				if since > 1500 then inst.fail_count = 0 end
				-- 実際に再生して分かった長さを覚えておく（ドックの表示用。ドックが読めない形式でも表示できる）
				if it and not it.url and since > 500 then
					local d = math.floor(obs.obs_source_media_get_duration(p))
					if d > 0 and it.dur ~= d then
						it.dur = d
						inst.dirty = true
					end
				end
			elseif since > 4000 then
				-- 「再生中」なのに長さも進みも 0 のまま＝読み込みに失敗している
				fail_advance(inst, "読み込めない")
				return
			end
		end
	elseif not inst.seen_play and obs.obs_source_active(p) and since > 2500 then
		-- 表示中なのに切り替えてから一度も再生が始まらない＝開けないファイル
		fail_advance(inst, "開始できない")
	end
end

-- 「現在のシーンに作成」ボタンの実処理（描画スレッド側で実行してロック順の問題を避ける）
local function do_create_playlist_source(scene_src)
	local scene = obs.obs_scene_from_source(scene_src)
	if scene == nil then return end

	local base, name, n = "動画プレイリスト", "動画プレイリスト", 1
	while true do
		local ex = obs.obs_get_source_by_name(name)
		if ex == nil then break end
		obs.obs_source_release(ex)
		n = n + 1
		name = base .. " " .. n
	end

	local s = obs.obs_data_create()
	obs.obs_data_set_bool(s, "is_local_file", true)
	obs.obs_data_set_bool(s, "looping", false)
	obs.obs_data_set_bool(s, "restart_on_activate", false)
	obs.obs_data_set_bool(s, "close_when_inactive", false)
	local src = obs.obs_source_create("ffmpeg_source", name, s, nil)
	obs.obs_data_release(s)
	if src == nil then return end

	-- 先にシーンへ追加してからフィルタを付ける（シーンのロック中に本スクリプトを呼ばせないため）
	local item = obs.obs_scene_add(scene, src)

	-- スクリプト画面でフォルダが選ばれていれば、最初からその動画を登録しておく
	-- （フィルタは作成時に vp_inbox を取り込み、メディアソースに付いた時点で再生を始める）
	local fs = obs.obs_data_create()
	if create_folder ~= "" then
		local arr = obs.obs_data_array_create()
		local entry = obs.obs_data_create()
		obs.obs_data_set_string(entry, "value", create_folder)
		obs.obs_data_array_push_back(arr, entry)
		obs.obs_data_release(entry)
		obs.obs_data_set_array(fs, "vp_inbox", arr)
		obs.obs_data_array_release(arr)
		obs.obs_data_set_bool(fs, "vp_recursive", create_recursive)
	end
	local f = obs.obs_source_create(FILTER_ID, FILTER_NAME, fs, nil)
	obs.obs_data_release(fs)
	if f ~= nil then
		obs.obs_source_filter_add(src, f)
		obs.obs_source_release(f)
	end

	if item ~= nil then
		pcall(function()
			local ovi = obs.obs_video_info()
			if obs.obs_get_video_info(ovi) then
				local b = obs.vec2()
				b.x = ovi.base_width
				b.y = ovi.base_height
				obs.obs_sceneitem_set_bounds_type(item, obs.OBS_BOUNDS_SCALE_INNER)
				obs.obs_sceneitem_set_bounds_alignment(item, 0)
				obs.obs_sceneitem_set_bounds(item, b)
			end
		end)
	end

	if obs.obs_frontend_open_source_filters then
		pcall(obs.obs_frontend_open_source_filters, src)
	end
	if create_folder ~= "" then
		log("「" .. name .. "」を作成しました（フォルダ: " .. create_folder .. "）")
	else
		log("「" .. name .. "」を作成しました")
	end
	obs.obs_source_release(src)
end

-- 毎フレームの処理（再生終了の検出・状態の書き出し）。
-- script_tick は使わない。OBS 30.0 以前には、script_tick を定義したスクリプトの読み込み中に
-- 描画スレッドが未初期化の Lua を呼んで OBS ごと落ちる不具合がある（30.1 で修正）。タイマーなら安全。
local last_ns = nil
local function on_timer()
	local t = obs.os_gettime_ns()
	if last_ns then now_ms = now_ms + (t - last_ns) / 1000000 end
	last_ns = t

	if pending_create then
		local sc = pending_create
		pending_create = nil
		local ok, err = pcall(do_create_playlist_source, sc)
		if not ok then bug("ソース作成エラー: " .. tostring(err)) end
		obs.obs_source_release(sc)
	end

	for inst in pairs(instances) do
		local ok, err = pcall(tick_instance, inst)
		if not ok then bug("tick エラー: " .. tostring(err)) end
		if inst.dirty then
			local ok2, err2 = pcall(flush_state, inst)
			if not ok2 then bug("状態保存エラー: " .. tostring(err2)) end
		end
	end
end

-- ---------------------------------------------------------------------------
-- フィルタ定義
-- ---------------------------------------------------------------------------
local source_info = {}
source_info.id = FILTER_ID
source_info.type = obs.OBS_SOURCE_TYPE_FILTER
source_info.output_flags = obs.OBS_SOURCE_VIDEO

source_info.get_name = function()
	return FILTER_NAME
end

source_info.get_defaults = function(settings)
	obs.obs_data_set_default_string(settings, "vp_mode", "sequential")
	obs.obs_data_set_default_bool(settings, "vp_loop", true)
	obs.obs_data_set_default_bool(settings, "vp_recursive", false)
end

source_info.create = function(settings, source)
	local inst = {
		source = source,
		items = {}, shuffle = {}, by_id = {},
		next_id = 1, ack = 0, rev = 0, msg_id = 0,
		mode = "sequential", loop = true, recursive = false,
		current = nil, ended = false,
		switch_at = 0, seen_play = false, fail_count = 0,
		dirty = true,
	}
	restore_state(inst, obs.obs_data_get_string(settings, "vp_state"))
	inst.mode = (obs.obs_data_get_string(settings, "vp_mode") == "random") and "random" or "sequential"
	inst.loop = obs.obs_data_get_bool(settings, "vp_loop")
	inst.recursive = obs.obs_data_get_bool(settings, "vp_recursive")
	validate_shuffle(inst)
	instances[inst] = true

	process_inbox(inst, settings)
	process_cmds(inst, obs.obs_data_get_string(settings, "vp_cmds"))
	return inst
end

source_info.destroy = function(inst)
	if inst then
		instances[inst] = nil
		inst.source = nil
	end
end

source_info.update = function(inst, settings)
	if not inst then return end
	set_mode(inst, obs.obs_data_get_string(settings, "vp_mode"))
	set_loop(inst, obs.obs_data_get_bool(settings, "vp_loop"))
	inst.recursive = obs.obs_data_get_bool(settings, "vp_recursive")
	process_inbox(inst, settings)
	process_cmds(inst, obs.obs_data_get_string(settings, "vp_cmds"))
end

source_info.video_render = function(inst, effect)
	obs.obs_source_skip_video_filter(inst.source)
end

-- Lua のフィルタは get_width/get_height を定義しないと「幅0×高さ0」扱いになり、
-- 付けたソースが画面に映らなくなる。下流（元のソース）の大きさをそのまま返す。
local function target_size(inst)
	if inst == nil or inst.source == nil then return 0, 0 end
	local t = obs.obs_filter_get_target(inst.source)
	if t == nil then return 0, 0 end
	return obs.obs_source_get_base_width(t), obs.obs_source_get_base_height(t)
end

source_info.get_width = function(inst)
	local w = target_size(inst)
	return w
end

source_info.get_height = function(inst)
	local _, h = target_size(inst)
	return h
end

source_info.get_properties = function(inst)
	local props = obs.obs_properties_create()

	if inst then
		obs.obs_properties_add_text(props, "vp_status_info", status_text(inst), obs.OBS_TEXT_INFO)
	end

	local inbox = obs.obs_properties_add_editable_list(props, "vp_inbox", "ファイル／フォルダを追加",
		obs.OBS_EDITABLE_LIST_TYPE_FILES_AND_URLS, FILE_FILTER, nil)
	obs.obs_property_set_long_description(inbox,
		"＋ から動画ファイルやフォルダを選ぶと、プレイリストの末尾に追加されます（追加後この欄は空に戻ります）。")
	obs.obs_property_set_modified_callback(inbox, function(props_, prop, settings)
		if inst then process_inbox(inst, settings) end
		return true
	end)

	obs.obs_properties_add_bool(props, "vp_recursive", "フォルダ追加時にサブフォルダの中も読み込む")

	local mode = obs.obs_properties_add_list(props, "vp_mode", "再生順",
		obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
	obs.obs_property_list_add_string(mode, "順番に再生", "sequential")
	obs.obs_property_list_add_string(mode, "ランダム（シャッフル）", "random")
	obs.obs_property_set_modified_callback(mode, function(props_, prop, settings)
		if inst then
			local before = inst.mode
			set_mode(inst, obs.obs_data_get_string(settings, "vp_mode"))
			return before ~= inst.mode
		end
		return false
	end)

	local loop = obs.obs_properties_add_bool(props, "vp_loop", "最後まで再生したら最初から繰り返す")
	obs.obs_property_set_modified_callback(loop, function(props_, prop, settings)
		if inst then set_loop(inst, obs.obs_data_get_bool(settings, "vp_loop")) end
		return false
	end)

	if inst and #inst.items > 0 then
		local jump = obs.obs_properties_add_list(props, "vp_jump", "今すぐ再生",
			obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_INT)
		obs.obs_property_list_add_int(jump, "（選ぶとその動画へジャンプ）", 0)
		for i, id in ipairs(play_order(inst)) do
			local it = inst.by_id[id]
			if it then
				local mark = (id == inst.current) and "▶ " or ""
				local dur = it.dur and ("  (" .. format_duration(it.dur) .. ")") or ""
				obs.obs_property_list_add_int(jump, string.format("%s%d. %s%s", mark, i, it.name, dur), id)
			end
		end
		obs.obs_property_set_modified_callback(jump, function(props_, prop, settings)
			local id = obs.obs_data_get_int(settings, "vp_jump")
			if id > 0 then
				obs.obs_data_set_int(settings, "vp_jump", 0)
				play_id(inst, id)
				return true
			end
			return false
		end)

		obs.obs_properties_add_button(props, "vp_btn_prev", "⏮  前の動画", function()
			advance(inst, -1, false)
			return true
		end)
		obs.obs_properties_add_button(props, "vp_btn_next", "⏭  次の動画", function()
			advance(inst, 1, false)
			return true
		end)
		if inst.mode == "random" then
			obs.obs_properties_add_button(props, "vp_btn_shuffle", "🔀  シャッフルし直す", function()
				make_shuffle(inst, inst.current)
				inst.dirty = true
				return true
			end)
		else
			obs.obs_properties_add_button(props, "vp_btn_sort", "名前順に並べ替える", function()
				sort_by_name(inst)
				return true
			end)
		end
		obs.obs_properties_add_button(props, "vp_btn_clear", "リストを空にする", function()
			clear_all(inst)
			return true
		end)
	end

	obs.obs_properties_add_text(props, "vp_note",
		"ドラッグでの並べ替えや再生状況の確認は「動画プレイリスト」ドックで行えます（導入方法は README を参照）。",
		obs.OBS_TEXT_INFO)
	return props
end

obs.obs_register_source(source_info)

-- ---------------------------------------------------------------------------
-- スクリプト本体（ツール → スクリプト）
-- ---------------------------------------------------------------------------
local function dock_url()
	local dir = script_path():gsub("\\", "/")
	if dir:sub(-1) ~= "/" then dir = dir .. "/" end
	local path = dir .. "video-playlist-dock.html"
	if path:sub(1, 1) ~= "/" then path = "/" .. path end
	return "file://" .. url_encode_path(path)
end

function script_description()
	return [[
<h3>動画プレイリスト <small>v]] .. VERSION .. [[</small></h3>
<p>動画を順番またはランダムで連続再生し続けます。</p>
<ol>
<li>（任意）「最初に入れる動画フォルダ」を選び、下のボタンで「動画プレイリスト」を現在のシーンに作成<br>
（既存のメディアソースに使う場合は、そのソースのフィルタに「動画プレイリスト」を追加）</li>
<li>動画はフィルタ画面の「ファイル／フォルダを追加」の ＋ やドックからも追加できます</li>
<li>メニュー「ドック → カスタムブラウザドック」で、下の「ドックURL」を登録すると、
ドラッグで並べ替えできる操作パネルが使えます</li>
</ol>
<p>ドックは obs-websocket を使います（ツール → WebSocket サーバー設定 で有効化）。</p>
]]
end

-- セットアップ状況。OBS の設定ファイルは読まず、このスクリプト自身が見たことだけで判定する
-- （OBS を更新しても判定のしかたが変わらないように）
local function setup_status_text()
	local count, videos = 0, 0
	for inst in pairs(instances) do
		if inst.source then
			count = count + 1
			videos = videos + #inst.items
		end
	end
	local lines = { "セットアップ状況" }
	if count > 0 then
		lines[#lines + 1] = string.format("✅ プレイリスト：%d個（動画 %d本）", count, videos)
	else
		lines[#lines + 1] = "❌ プレイリスト：まだありません"
		lines[#lines + 1] = "　　→ 下の「現在のシーンに『動画プレイリスト』を作成」を押してください"
	end
	-- プレイリストがドックのコマンドを処理したことがあれば（ack > 0）、それも接続済みとみなす。
	-- ack はフィルタ側に保存されるので、スクリプトを外して付け直し、dock_seen が消えても残る
	local acked = false
	for inst in pairs(instances) do
		if inst.source and (inst.ack or 0) > 0 then acked = true break end
	end
	if dock_seen > 0 then
		lines[#lines + 1] = "✅ ドック：接続を確認済み（最後の接続 " .. os.date("%m/%d %H:%M", dock_seen) .. "）"
	elseif acked then
		lines[#lines + 1] = "✅ ドック：接続を確認済み"
	else
		lines[#lines + 1] = "❌ ドック：まだ接続を確認できていません"
		lines[#lines + 1] = "　　1. ツール → WebSocket サーバー設定 で「WebSocket サーバーを有効にする」にチェック"
		lines[#lines + 1] = "　　2. 下の「ドックURL」を「ドック → カスタムブラウザドック」に登録"
		lines[#lines + 1] = "　　3. 開いたドックが OBS に接続できれば完了（パスワードを聞かれたら、WebSocket サーバー設定の「接続情報を表示」で確認）"
		lines[#lines + 1] = "　　ドックを開いているのに ❌ のままなら、ドックで何か操作してから「再チェック」を押してください"
	end
	return table.concat(lines, "\n")
end

local function add_setup_props(props)
	obs.obs_properties_add_text(props, "vp_setup_status", setup_status_text(), obs.OBS_TEXT_INFO)
	obs.obs_properties_add_button(props, "vp_setup_recheck", "再チェック", function(props_, _)
		-- スクリプト画面は、ボタンが true を返しても script_properties を呼び直さず、
		-- 今ある項目のまま表示を作り直すだけ。そのため、ここで表示する文を書き換えてから true を返す
		local p = props_ and obs.obs_properties_get(props_, "vp_setup_status")
		if p then obs.obs_property_set_description(p, setup_status_text()) end
		return true
	end)
	local folder = obs.obs_properties_add_path(props, "vp_create_folder", "最初に入れる動画フォルダ（任意）",
		obs.OBS_PATH_DIRECTORY, nil, nil)
	obs.obs_property_set_long_description(folder,
		"選んでから下のボタンで作成すると、このフォルダの動画を登録した状態で再生が始まります。空欄なら動画なしで作成します。")
	obs.obs_properties_add_bool(props, "vp_create_recursive", "サブフォルダの中も読み込む")
end

function script_properties()
	local props = obs.obs_properties_create()
	add_setup_props(props)
	obs.obs_properties_add_button(props, "vp_create", "現在のシーンに「動画プレイリスト」を作成", function()
		local ok, sc = pcall(function()
			if obs.obs_frontend_preview_program_mode_active and obs.obs_frontend_preview_program_mode_active() then
				return obs.obs_frontend_get_current_preview_scene()
			end
			return obs.obs_frontend_get_current_scene()
		end)
		if ok and sc ~= nil then
			if pending_create then obs.obs_source_release(pending_create) end
			pending_create = sc
		else
			warn("現在のシーンを取得できませんでした")
		end
		return false
	end)
	local t = obs.obs_properties_add_text(props, "vp_dock_url", "ドックURL", obs.OBS_TEXT_DEFAULT)
	obs.obs_property_set_long_description(t, "コピーして「ドック → カスタムブラウザドック」の URL 欄に貼り付けてください。")
	return props
end

function script_defaults(settings)
	obs.obs_data_set_default_string(settings, "vp_dock_url", dock_url())
end

function script_update(settings)
	create_folder = obs.obs_data_get_string(settings, "vp_create_folder") or ""
	create_recursive = obs.obs_data_get_bool(settings, "vp_create_recursive")
	-- ドックURLは常にこのスクリプトの場所を指すように戻す
	local url = dock_url()
	if obs.obs_data_get_string(settings, "vp_dock_url") ~= url then
		obs.obs_data_set_string(settings, "vp_dock_url", url)
	end
end

local function for_each_active(fn)
	for inst in pairs(instances) do
		if inst.source and obs.obs_source_enabled(inst.source) and #inst.items > 0 then
			fn(inst)
		end
	end
end

local HOTKEYS = {
	{ name = "vp_hotkey_next",    desc = "動画プレイリスト: 次の動画",       fn = function(i) advance(i, 1, false) end },
	{ name = "vp_hotkey_prev",    desc = "動画プレイリスト: 前の動画",       fn = function(i) advance(i, -1, false) end },
	{ name = "vp_hotkey_shuffle", desc = "動画プレイリスト: シャッフルし直す", fn = function(i)
		if i.mode == "random" then make_shuffle(i, i.current); i.dirty = true end
	end },
	{ name = "vp_hotkey_mode",    desc = "動画プレイリスト: 順番／ランダム切替", fn = function(i)
		set_mode(i, i.mode == "random" and "sequential" or "random")
	end },
}

function script_load(settings)
	obs.timer_add(on_timer, 10)
	for _, hk in ipairs(HOTKEYS) do
		local id = obs.obs_hotkey_register_frontend(hk.name, hk.desc, function(pressed)
			if pressed then for_each_active(hk.fn) end
		end)
		hotkey_ids[hk.name] = id
		local a = obs.obs_data_get_array(settings, hk.name)
		obs.obs_hotkey_load(id, a)
		obs.obs_data_array_release(a)
	end
	dock_seen = obs.obs_data_get_int(settings, "vp_dock_seen")
	script_update(settings)
	log("動画プレイリスト v" .. VERSION .. " を読み込みました")
end

function script_save(settings)
	for _, hk in ipairs(HOTKEYS) do
		local id = hotkey_ids[hk.name]
		if id then
			local a = obs.obs_hotkey_save(id)
			obs.obs_data_set_array(settings, hk.name, a)
			obs.obs_data_array_release(a)
		end
	end
	obs.obs_data_set_int(settings, "vp_dock_seen", dock_seen)
end

function script_unload()
	if pending_create then
		obs.obs_source_release(pending_create)
		pending_create = nil
	end
end
