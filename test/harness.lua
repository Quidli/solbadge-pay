-- Host harness for the badge app: stubs the badge's modules to the rules in
-- LUA_API.md and the worker to its contract, drives the app with key presses,
-- and checks what it does. Build and run: see the README ("Tests").

-- ---------------------------------------------------------------- mini JSON
local J = {}
local function esc(s)
  return '"' .. s:gsub('[%c"\\]', function(c)
    return ({['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n'})[c] or string.format("\\u%04x", c:byte())
  end) .. '"'
end
function J.encode(v)
  local t = type(v)
  if t == "nil" then return "null" end
  if t == "boolean" or t == "number" then return tostring(v) end
  if t == "string" then return esc(v) end
  if #v > 0 or next(v) == nil then
    local out = {}
    for i, x in ipairs(v) do out[i] = J.encode(x) end
    return "[" .. table.concat(out, ",") .. "]"
  end
  local ks = {}
  for k in pairs(v) do ks[#ks + 1] = k end
  table.sort(ks)
  local out = {}
  for i, k in ipairs(ks) do out[i] = esc(k) .. ":" .. J.encode(v[k]) end
  return "{" .. table.concat(out, ",") .. "}"
end
function J.decode(s)
  local i = 1
  local val
  local function ws() i = s:find("%S", i) or #s + 1 end
  local function str()
    local out = {}
    i = i + 1
    while true do
      local c = s:sub(i, i)
      if c == "" then error("eof") end
      if c == '"' then i = i + 1 break end
      if c == "\\" then
        local n = s:sub(i + 1, i + 1)
        if n == "u" then out[#out + 1] = "?" i = i + 6
        else out[#out + 1] = ({n = "\n", t = "\t", r = "\r", b = "\b", f = "\f"})[n] or n i = i + 2 end
      else out[#out + 1] = c i = i + 1 end
    end
    return table.concat(out)
  end
  function val()
    ws()
    local c = s:sub(i, i)
    if c == "{" then
      local t = {}
      i = i + 1 ws()
      if s:sub(i, i) == "}" then i = i + 1 return t end
      while true do
        ws() local k = str() ws()
        assert(s:sub(i, i) == ":") i = i + 1
        t[k] = val() ws()
        local d = s:sub(i, i) i = i + 1
        if d == "}" then return t end
        assert(d == ",")
      end
    elseif c == "[" then
      local t = {}
      i = i + 1 ws()
      if s:sub(i, i) == "]" then i = i + 1 return t end
      while true do
        t[#t + 1] = val() ws()
        local d = s:sub(i, i) i = i + 1
        if d == "]" then return t end
        assert(d == ",")
      end
    elseif c == '"' then return str()
    elseif s:sub(i, i + 3) == "true" then i = i + 4 return true
    elseif s:sub(i, i + 4) == "false" then i = i + 5 return false
    elseif s:sub(i, i + 3) == "null" then i = i + 4 return nil
    else
      local n = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", i)
      assert(n and n ~= "", "bad json at " .. i)
      i = i + #n
      return math.tointeger(tonumber(n)) or tonumber(n)
    end
  end
  local ok, v = pcall(val)
  if not ok then return nil, v end
  return v
end

-- ---------------------------------------------------------------- the badge
local B                       -- the emulated badge's state, reset per launch
local disk = {}               -- storage, kept across launches (as JSON text)

local function fresh()
  B = {
    objs = {}, order = 0, hint = nil, toasts = {}, dialog = nil,
    timers = {}, tid = 0, now = 0, net = {}, sent = {}, respond = nil,
    wifi = true, mesh_has_radio = false, paused = false, nearby = {}, profiles = {},
    leds = "off",
  }
end

local function obj(kind, fields)
  B.order = B.order + 1
  local o = fields
  o.kind, o.order, o.alive, o.shown = kind, B.order, true, true
  B.objs[#B.objs + 1] = o
  local live = 0
  for _, x in ipairs(B.objs) do if x.alive then live = live + 1 end end
  assert(live <= 128, "more than 128 UI objects")
  return o
end

local label_mt = {__index = {
  text = function(o, t) assert(type(t) == "string", "label text must be a string") o.t = t end,
  color = function(o, c) o.c = c end,
  pos = function() end,
  show = function(o, b) o.shown = b end,
  remove = function(o) o.alive = false end,
}}
local list_mt = {__index = {
  items = function(o, it) o.it = it if o.sel > #it then o.sel = math.max(#it, 1) end end,
  selected = function(o) return o.sel end,
  select = function(o, i) o.sel = i end,
  show = function(o, b) o.shown = b end,
  remove = function(o) o.alive = false end,
}}

ui = {W = 320, H = 218}
function ui.bg() end
function ui.label(x, y, text, opts)
  assert(type(text) == "string", "label text must be a string")
  return setmetatable(obj("label", {t = text, y = y, c = opts and opts.color}), label_mt)
end
function ui.list(x, y, w, h, items, opts)
  assert(y + h <= ui.H - 16 + 0.5, "list overlaps the hint")
  return setmetatable(obj("list", {it = items, sel = 1, on = opts and opts.on_select}), list_mt)
end
local qr_mt = {__index = {
  text = function(o, t) assert(type(t) == "string" and #t <= 256, "qr text over 256 bytes") o.t = t end,
  pos = function() end,
  show = function(o, b) o.shown = b end,
  remove = function(o) o.alive = false end,
}}
-- Solana OS 0.5.3: one QR code at a time, 25..218 px, text <= 256 bytes, and it must fit on screen.
local function qr(x, y, size, text)
  assert(type(text) == "string" and #text <= 256, "qr text over 256 bytes")
  assert(size >= 25 and size <= 218, "qr size out of range")
  assert(x >= 0 and y >= 0 and x + size <= ui.W and y + size <= ui.H - 16, "qr off screen or over the hint")
  for _, o in ipairs(B.objs) do assert(not (o.alive and o.kind == "qr"), "a second QR code") end
  return setmetatable(obj("qr", {t = text}), qr_mt)
end
ui.qr = qr
function ui.hint(t) B.hint = t end
function ui.toast(t) B.toasts[#B.toasts + 1] = t end
function ui.confirm(t, cb) assert(not B.dialog, "dialog over dialog") B.dialog = {kind = "confirm", t = t, cb = cb} end
function ui.input(t, max, cb)
  assert(not B.dialog, "dialog over dialog")
  B.dialog = {kind = "input", t = t, max = math.min(max, 64), cb = cb}
end
function ui.clear()
  for _, o in ipairs(B.objs) do o.alive = false end
  B.objs, B.hint = {}, nil
end

timer = {}
local function add_timer(ms, fn, rep)
  assert(ms >= 20, "timer under 20 ms")
  local n = 0
  for _ in pairs(B.timers) do n = n + 1 end
  assert(n < 8, "more than 8 timers")
  B.tid = B.tid + 1
  B.timers[B.tid] = {due = B.now + ms, ms = ms, fn = fn, rep = rep}
  return B.tid
end
function timer.after(ms, fn) return add_timer(ms, fn, false) end
function timer.every(ms, fn) return add_timer(ms, fn, true) end
function timer.cancel(id) B.timers[id] = nil end

storage = {}
local function load_disk() return disk.json and J.decode(disk.json) or {} end
function storage.get(k) return load_disk()[k] end
function storage.set(k, v)
  local t = load_disk()
  t[k] = v
  local text = J.encode(t)
  assert(#text <= 16 * 1024, "storage full")
  disk.json = text
end
function storage.remove(k) storage.set(k, nil) end

json = {encode = J.encode, decode = J.decode}
sys = {millis = function() return B.now end, time = function() return 1795000000 end, exit = function() end}
led = {fill = function() B.leds = "on" end, off = function() B.leds = "off" end}

badge = {id = function() return "7K2Q9M" end, owner = function() return "@justin" end}
function badge.online() return B.wifi and (not B.mesh_has_radio or B.paused) and (B.rejoin_at or 0) <= B.now end

mesh = {}
function mesh.nearby() return B.paused and {} or B.nearby end
function mesh.pause() B.paused = true B.rejoin_at = B.now + 3000 end       -- Wi-Fi rejoins in a few seconds
function mesh.resume() B.paused = false end

profile = {}
function profile.get(id, cb)
  if not badge.online() then B.net[#B.net + 1] = function() cb(false, "offline") end return end
  B.net[#B.net + 1] = function() cb(true, B.profiles[id] or {}) end
end

http = {}
function http.request(req, cb)
  assert(type(req.url) == "string" and req.url:match("^https://") and not req.url:find(" "), "bad url")
  assert(#req.url <= 512, "url too long")
  local host = req.url:match("^https://([^/]+)")
  local n = 0
  for name, value in pairs(req.headers or {}) do
    n = n + 1
    assert(name:match("^[%w-]+$"), "bad header name " .. name)
    assert(type(value) == "string" and #value <= 256 and not value:find("[^\32-\126]"), "bad header value for " .. name)
  end
  assert(n <= 8, "too many headers")
  local body = req.body
  if type(body) == "table" then body = J.encode(body) end
  assert(not body or #body <= 2048, "request too big")
  local method = req.method or (body and "POST" or "GET")
  local r = {method = method, url = req.url, path = req.url:sub(#("https://" .. host) + 1), headers = req.headers or {}, body = body}
  B.sent[#B.sent + 1] = r
  if not badge.online() then B.net[#B.net + 1] = function() cb(false, "offline") end return end
  if not host:match("%.workers%.dev$") then B.net[#B.net + 1] = function() cb(false, "host not allowed") end return end   -- app.json: "*.workers.dev"
  local a = B.respond(r)
  B.net[#B.net + 1] = function()
    if type(a) == "string" then return cb(false, a) end
    local text = a.body or ""
    cb(true, {status = a.status, body = text:sub(1, 3500), truncated = #text > 3500, type = "application/json"})
  end
end

-- ---------------------------------------------------------------- driving it
local function pump()                    -- deliver every waiting network answer
  while #B.net > 0 do table.remove(B.net, 1)() end
end

local function advance(ms)               -- move the clock, firing timers in order
  local target = B.now + ms
  while true do
    local id, t
    for i, x in pairs(B.timers) do
      if x.due <= target and (not t or x.due < t.due) then id, t = i, x end
    end
    if not t then break end
    B.now = t.due
    if t.rep then t.due = t.due + t.ms else B.timers[id] = nil end
    t.fn()
    pump()
  end
  B.now = target
end

local function focused()
  local best
  for _, o in ipairs(B.objs) do
    if o.alive and o.kind == "list" and o.shown and (not best or o.order > best.order) then best = o end
  end
  return best
end

-- A key press, routed as lua_ui.c does: dialog, then the focused list, then on_key.
local function key(k)
  local d = B.dialog
  if d then
    assert(d.kind == "confirm", "an input is open: use typed()")
    if k == "select" or k == "back" then B.dialog = nil d.cb(k == "select") end
    pump() return true
  end
  local l = focused()
  if l then
    if k == "up" then l.sel = math.max(1, l.sel - 1) return true end
    if k == "down" then l.sel = math.min(#l.it, l.sel + 1) return true end
    if k == "select" and l.on and #l.it > 0 then l.on(l.sel, l.it[l.sel]) pump() return true end
  end
  local handled = on_key(k, false)
  pump()
  return handled
end

local function typed(text)               -- answer the open keyboard (nil cancels)
  local d = assert(B.dialog, "no dialog open")
  assert(d.kind == "input", "the open dialog is a confirm")
  assert(not text or #text <= d.max, "typed more than the keyboard allows")
  B.dialog = nil
  d.cb(text)
  pump()
end

local function pick(want)                -- choose the list row whose title contains `want`
  local l = assert(focused(), "no list on screen")
  for i, it in ipairs(l.it) do
    local t = type(it) == "table" and it.title or it
    if t:find(want, 1, true) then l.sel = i return key("select") end
  end
  error("no row '" .. want .. "' on screen")
end

local function screen()                  -- every visible word, for checks
  local out = {}
  for _, o in ipairs(B.objs) do
    if o.alive and o.shown then
      if o.kind == "label" then out[#out + 1] = o.t end
      if o.kind == "qr" then out[#out + 1] = "[qr " .. o.t .. "]" end
      if o.kind == "list" then
        for _, it in ipairs(o.it) do
          out[#out + 1] = type(it) == "table" and ((it.title or "") .. " " .. (it.sub or "") .. " " .. (it.right or "")) or it
        end
      end
    end
  end
  if B.dialog then out[#out + 1] = "[" .. B.dialog.kind .. "] " .. B.dialog.t end
  return table.concat(out, " | ")
end

local function launch()
  fresh()
  on_key, on_exit, on_tick = nil, nil, nil
  local chunk = assert(host_load(APP))
  B.respond = function() return {status = 500, body = "{}"} end
  chunk()
  pump()
end

-- ---------------------------------------------------------------- checks
local passed, failed = 0, 0
local function check(name, cond, extra)
  if cond then passed = passed + 1
  else failed = failed + 1 print("FAIL  " .. name .. (extra and ("\n      " .. tostring(extra)) or "")) end
end
local function sees(name, want) check(name, screen():find(want, 1, true), "screen: " .. screen()) end
local function pays() local out = {} for _, r in ipairs(B.sent) do if r.path == "/pay" then out[#out + 1] = r end end return out end


local ASSETS = assert(host_read(DATA .. "/assets.json"), "missing assets.json (the worker's list)")
local ADDR = "https://solbadge-pay.justin.workers.dev"
local allowed = true

-- The worker, to its contract (worker/worker.js; its own checks are in worker.test.mjs).
local function a_worker(pay_answers)
  local n = 0
  return function(r)
    if not allowed then return {status = 403, body = '{"text":"Badge 7K2Q9M isn\'t on this worker\'s list (BADGE_IDS)."}'} end
    if r.path == "/assets" then return {status = 200, body = ASSETS} end
    if r.path:find("^/score/") then
      if r.path:find("nobody") then return {status = 200, body = '{"score":null,"lines":[]}'} end
      if r.path:find("toly") then return {status = 200, body = '{"score":null,"lines":["X reputation: 1985 (reputable)"]}'} end
      if r.path:find("limited") then return {status = 200, body = '{"text":"Too many requests"}'} end
      return {status = 200, body = '{"score":96,"lines":["Farcaster reputation: 0.96","Lens reputation: 0.89","Wallet reputation: 1200"]}'}
    end
    if r.path == "/pay" then
      n = n + 1
      return pay_answers[math.min(n, #pay_answers)]
    end
    return {status = 404, body = '{"text":"No such path"}'}
  end
end
local SENT = {status = 200, body = '{"state":"sent"}'}
local TX = "2WCfB21hUguybnTtWddyps9pkFKNBFF8Qbo2KiSBtLTeNEceyaJVVgzdgKk9xioyKpLWsnQxPWTthQBnaNDf3tT5"
local SENT_TX = {status = 200, body = '{"state":"sent","tx":"' .. TX .. '"}'}
local USDC = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"
local PROCESSING = {status = 200, body = '{"state":"processing"}'}
local function FAILED(text) return {status = 200, body = J.encode({state = "failed", text = text})} end
local function UNKNOWN(text) return {status = 200, body = J.encode({state = "unknown", text = text})} end
local function no_secrets()
  for _, r in ipairs(B.sent) do
    for name in pairs(r.headers) do if name:lower():find("key") or name:lower():find("auth") then return false end end
  end
  for k in pairs(J.decode(disk.json or "{}")) do if k ~= "worker" and k ~= "pending" then return false end end
  return true
end

-- 1. First launch: nothing set up. Enter the worker's address, check the badge is let in.
disk = {}
launch()
B.respond = a_worker({SENT})
sees("home asks for setup, with the badge id", "Set up Badge id 7K2Q9M, for your worker")
check("home offers no payment before setup", not screen():find("Nearby"))
check("CANCEL on home exits", key("back") == false)
pick("Set up")
sees("setup shows the badge id", "Id 7K2Q9M")
sees("setup says what to do", "Deploy the worker, then enter its address.")
check("no request before there is an address", #B.sent == 0)
pick("Enter worker address")
typed("not an address")
check("a bad address is refused", B.toasts[#B.toasts] == "That isn't an address" and storage.get("worker") == nil)
pick("Enter worker address")
typed("HTTPS://SolBadge-Pay.Justin.workers.dev/")
check("the address is stored clean", storage.get("worker") == ADDR, storage.get("worker"))
sees("the worker lets the badge in", "The worker accepts this badge.")
allowed = false
pick("Ask again")
sees("a badge that isn't listed is told so", "Badge 7K2Q9M isn't on this worker's list (BADGE_IDS).")
allowed = true
key("back")
sees("home now offers payments", "Nearby badges")
sees("home shows the badge id", "This badge  7K2Q9M")

-- 2. Typed handle, reputation, pay 1 USDC on Solana.
pick("Type an X handle")
typed("not a handle!")
check("bad handle is refused", B.toasts[#B.toasts] == "That isn't an X handle")
pick("Type an X handle")
typed("@quidliprotocol")
sees("recipient shows the handle", "@quidliprotocol")
sees("recipient shows social reputation", "Social reputation | 96")
sees("recipient shows a category", "Farcaster reputation: 0.96")
check("the lookup goes to the worker", B.sent[#B.sent].method == "GET" and B.sent[#B.sent].url == ADDR .. "/score/quidliprotocol")
key("select")
sees("assets come from the wallet, with what each can send", "SOL  0.052096561 | Bonk  1234567.89012 | USDC  10")
pick("USDC")
sees("amount screen", "How much USDC?")
pick("1 USDC")
sees("confirm names amount, handle and chain", "[confirm] Send 1 USDC to @quidliprotocol on Solana?")
sees("...and the SOL fee of a token payment", "Fee: up to 0.002 SOL.")
check("nothing is sent before the confirm", #pays() == 0)
key("select")
local d = pays()
check("one /pay after the confirm", #d == 1 and d[1].method == "POST")
local body = J.decode(d[1].body)
check("the request says what, to whom, how much", body.asset == USDC and body.handle == "quidliprotocol" and body.units == "1000000", d[1].body)
check("the request holds nothing else", (function() local n = 0 for _ in pairs(body) do n = n + 1 end return n end)() == 4)
check("the payment id is a v4 UUID", body.id:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-4%x%x%x%-[89ab]%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$"), body.id)
sees("success screen", "Sent")
check("pending cleared after success", storage.get("pending") == nil)
check("LEDs on", B.leds == "on")
key("select")
sees("done returns home", "SolBadge Pay")
check("home no longer offers an unfinished payment", not screen():find("Unfinished"))
local asked = 0
for _, r in ipairs(B.sent) do if r.path == "/assets" then asked = asked + 1 end end
check("no key in any request or in storage", no_secrets())

-- 3. Custom amounts, the wallet's limit, decimals.
local function to_amount(asset, amount)   -- from home, up to the confirm (or a toast)
  pick("Type an X handle") typed("quidliprotocol") key("select") pick(asset)
  if amount then pick("Other amount") typed(amount) end
end
local function assets_asked() local n = 0 for _, r in ipairs(B.sent) do if r.path == "/assets" then n = n + 1 end end return n end
to_amount("USDC")
check("after a payment the balances are asked for again", assets_asked() == asked + 1)
key("back") key("back") key("back")
to_amount("USDC", "1.5")
sees("custom amount confirm", "Send 1.5 USDC")
key("select")
check("1.5 USDC is sent in smallest units", J.decode(pays()[2].body).units == "1500000")
key("select")
to_amount("USDC", "10.01")
check("more than the wallet holds is refused on the badge", B.toasts[#B.toasts] == "You can send up to 10 USDC" and not B.dialog, B.toasts[#B.toasts])
pick("Other amount") typed("1.2345678")
check("too many decimals is refused", B.toasts[#B.toasts] == "Too many decimals")
for _, bad in ipairs({"0", "0.000", "1.", ".", "1,5", "-1", "1e3", "abc"}) do
  pick("Other amount") typed(bad)
  check("'" .. bad .. "' is not sent", not B.dialog and #pays() == 2, B.toasts[#B.toasts])
end
pick("Other amount") typed(nil)
check("cancelling the keyboard does nothing", not B.dialog)
key("back") key("back") key("back")
sees("three backs return home", "Contactless Solana payments")
to_amount("SOL", "0.005")
sees("SOL confirm names Solana", "Send 0.005 SOL to @quidliprotocol on Solana?")
check("...with no token fee line", not screen():find("Fee:", 1, true))
key("select")
body = J.decode(pays()[3].body)
check("SOL by its id, in lamports", body.asset == "sol" and body.units == "5000000", pays()[3].body)
key("select")
to_amount("Bonk", "1234568")
check("the limit compares past 32-bit", B.toasts[#B.toasts] == "You can send up to 1234567.89012 Bonk", B.toasts[#B.toasts])
key("back") key("back") key("back")

-- 4. "processing" twice, then sent: one payment id throughout.
B.sent = {}
B.respond = a_worker({PROCESSING, PROCESSING, SENT})
to_amount("USDC") pick("2 USDC") key("select")
sees("processing is shown", "setting up the recipient")
check("still pending while processing", storage.get("pending") ~= nil)
advance(3000) advance(3000)
d = pays()
check("three tries", #d == 3)
check("all three carry one payment id", J.decode(d[1].body).id == J.decode(d[3].body).id and J.decode(d[1].body).id == J.decode(d[2].body).id)
sees("sent after processing", "Sent")
check("pending cleared", storage.get("pending") == nil)
key("select")

-- 5. A timeout: unknown, kept, and the retry is the same payment. A relaunch still knows.
B.sent = {}
B.respond = a_worker({"timeout", SENT})
to_amount("USDC") pick("2 USDC") key("select")
sees("timeout is not called a failure", "No final answer yet")
sees("timeout says the retry is safe", "same payment, not a second one")
local id1 = storage.get("pending").id
check("pending kept after a timeout", id1 == J.decode(pays()[1].body).id)
launch()                                  -- the badge restarts
B.respond = a_worker({SENT})
sees("relaunch offers the unfinished payment", "Unfinished payment 2 USDC to @quidliprotocol")
pick("Type an X handle") typed("quidliprotocol") key("select")
sees("a new payment waits for the unfinished one", "Unfinished payment")
check("no second payment was started", #pays() == 0)
pick("Retry")
check("the retry reuses the payment id", J.decode(pays()[1].body).id == id1)
sees("retry succeeds", "Sent")
key("select")

-- 6. Refusals. On a first try nothing was sent, so the payment is dropped.
B.sent = {}
B.respond = a_worker({FAILED("Insufficient funds")})
to_amount("USDC") pick("5 USDC") key("select")
sees("a refusal shows Connect's words", "Not sent | Insufficient funds")
check("a first-try refusal drops the payment", storage.get("pending") == nil)
key("back")
-- ...but after a timeout, a refusal must not drop it: the first try may have gone through.
B.respond = a_worker({"timeout", FAILED("chain busy")})
to_amount("USDC") pick("5 USDC") key("select")
key("select")                             -- retry
sees("a refusal after a timeout stays unknown", "No final answer yet | chain busy")
check("...and the payment is kept", storage.get("pending") ~= nil)
key("back")
pick("Unfinished payment") pick("Discard")
sees("discard warns", "If it already went through, it stays sent.")
key("select")
check("discard removes it", storage.get("pending") == nil)
-- The worker says "unknown" (Connect timed out behind it).
B.respond = a_worker({UNKNOWN("Connect didn't answer in time.")})
to_amount("USDC") pick("1 USDC") key("select")
sees("the worker's unknown is kept as unknown", "No final answer yet | Connect didn't answer in time.")
check("...and pending", storage.get("pending") ~= nil)
key("back") pick("Unfinished payment") pick("Discard") key("select")
-- A 5xx page from in front of the worker is unknown too.
B.respond = a_worker({{status = 500, body = "<html>error 1101</html>"}})
to_amount("USDC") pick("1 USDC") key("select")
sees("a 500 with an HTML body is unknown, not a crash", "No final answer yet | The worker answered 500")
key("back") pick("Unfinished payment") pick("Discard") key("select")
-- An answer that isn't the contract is unknown, never "sent".
B.respond = a_worker({{status = 200, body = '{"ok":true}'}})
to_amount("USDC") pick("1 USDC") key("select")
sees("an unreadable 200 is unknown", "No final answer yet")
key("back") pick("Unfinished payment") pick("Discard") key("select")
-- The worker turns the badge away at /pay.
B.respond = a_worker({{status = 403, body = '{"text":"Badge 7K2Q9M isn\'t on this worker\'s list (BADGE_IDS)."}'}})
to_amount("USDC") pick("1 USDC") key("select")
sees("a worker refusal says why", "Not sent | Badge 7K2Q9M isn't on this worker's list")
check("...and drops the payment", storage.get("pending") == nil)
key("back")
-- Not in the store and no test run.
B.respond = function(r) return "denied" end
pick("Type an X handle") typed("quidliprotocol")
sees("denied explains the test run", "needs a test run")
key("back")
-- Processing that never ends.
B.sent = {}
B.respond = a_worker({PROCESSING})
to_amount("USDC") pick("1 USDC") key("select")
advance(60000)
check("processing stops after 6 tries", #pays() == 6 and screen():find("No final answer yet", 1, true), #pays())
key("back") pick("Unfinished payment") pick("Discard") key("select")

-- 7. Nearby: the mesh has the radio, so the app pauses it to reach the server.
launch()
B.respond = a_worker({SENT})
B.mesh_has_radio = true
B.nearby = {
  {id = "AAAAAA", name = "@far", rssi = -80, kind = "badge"},
  {id = "BEACON", name = "beacon", rssi = -20, kind = "beacon"},
  {id = "BBBBBB", name = "@near", rssi = -40, kind = "badge"},
  {id = "CCCCCC", name = "@nox", rssi = -60, kind = "badge"},
}
B.profiles = {BBBBBB = {name = "Near", x = "near_one"}, CCCCCC = {name = "No X"}}
check("offline while the mesh has the radio", not badge.online())
pick("Nearby badges")
local l = focused()
check("badges only, nearest first", #l.it == 3 and l.it[1].title == "@near" and l.it[3].title == "@far", screen())
B.nearby[#B.nearby + 1] = {id = "DDDDDD", name = "@new", rssi = -30, kind = "badge"}
l.sel = 2                                 -- @nox selected
advance(2000)
check("a new badge appears and the selection stays on the same badge", #l.it == 4 and l.it[l.sel].title == "@nox", screen())
pick("@near")
sees("resolving", "Finding their X handle")
check("the mesh was paused for Wi-Fi", B.paused)
advance(3500)
sees("the badge's owner resolves to their X handle", "@near_one | Social reputation")
key("back")
check("back to nearby resumes the mesh", not B.paused and screen():find("Nearby badges", 1, true))
pick("@nox")
advance(3500)
sees("a badge without X says so", "hasn't linked an X account")
key("back") key("back")
-- Wi-Fi off entirely.
B.wifi = false
pick("Type an X handle") typed("quidliprotocol")
advance(21000)
sees("no Wi-Fi is explained", "No Wi-Fi. Turn it on in the Wi-Fi app.")
B.wifi = true
key("select") advance(3500)
pick("USDC") pick("1 USDC")
B.wifi = false
key("select")
advance(21000)
sees("offline before the first try: not sent", "Not sent | No Wi-Fi")
check("...and nothing is pending", storage.get("pending") == nil and #pays() == 0)

-- 8. Reputation answers that aren't a score.
B.wifi = true
launch()
B.respond = a_worker({SENT})
pick("Type an X handle") typed("nobody_here")
sees("no reputation is stated plainly", "No social reputation on Connect yet")
key("back")
pick("Type an X handle") typed("toly")
sees("no Quidli score, but what Connect knows is shown", "Social reputation |  | X reputation: 1985 (reputable)")
key("back")
pick("Type an X handle") typed("limited")
sees("the worker's words are shown", "Too many requests")
key("select")
sees("paying is still offered", "Pick what to send")
key("back") key("back")

-- 9. A worker on a host the app's hosts don't cover; an asset list that can't be used.
pick("This badge") pick("Change worker address")
typed("pay.example.com")
check("an address off workers.dev is refused on the badge", B.toasts[#B.toasts] == "That isn't an address")
pick("Change worker address")
typed("solbadge-pay.justin")
check(".workers.dev is filled in", storage.get("worker") == "https://solbadge-pay.justin.workers.dev", storage.get("worker"))
pick("Change worker address")
typed("justin")
check("a name without its account is refused", B.toasts[#B.toasts] == "That isn't an address" and storage.get("worker") == "https://solbadge-pay.justin.workers.dev")
pick("Change worker address")
typed("solbadge-pay.justin.workers.dev")
sees("back on a covered host", "The worker accepts this badge.")
key("back")
B.respond = function(r) return {status = 200, body = '{"assets":[{"id":"x","label":"X"}]}'} end
launch()
B.respond = function(r)
  if r.path == "/assets" then return {status = 200, body = '{"assets":[{"id":"x","label":"X"}]}'} end
  return {status = 200, body = '{"score":1,"lines":[]}'}
end
pick("Type an X handle") typed("quidliprotocol") key("select")
sees("a broken asset list is refused, not shown", "The worker's asset list can't be read.")
local EMPTY = '{"text":"The Connect wallet has nothing to send on Solana yet. Add some SOL first."}'
launch()
B.respond = function(r)
  if r.path == "/assets" then return {status = 200, body = EMPTY} end
  return {status = 200, body = '{"score":1,"lines":[]}'}
end
pick("Type an X handle") typed("quidliprotocol") key("select")
sees("an empty wallet is explained on the asset screen", "nothing to send on Solana yet")
key("back") key("back")
pick("This badge")
sees("setup says the badge is in but the wallet is empty", "The worker accepts this badge. The Connect wallet has nothing")

-- 9b. The receipt: a sent payment shows its transaction on Solscan as a QR code.
launch()
B.respond = a_worker({SENT_TX})
to_amount("USDC") pick("1 USDC") key("select")
sees("sent", "Sent")
sees("the receipt is a QR code of the transaction", "[qr https://solscan.io/tx/" .. TX .. "]")
sees("...and says what it is", "Scan for the receipt")
key("select")
sees("done returns home, the QR code gone", "Contactless Solana payments")
check("no QR code left on home", not screen():find("[qr", 1, true))
B.respond = a_worker({{status = 200, body = '{"state":"sent","tx":"<script>"}'}})
to_amount("USDC") pick("1 USDC") key("select")
check("a malformed transaction id draws no QR code", screen():find("Sent", 1, true) and not screen():find("[qr", 1, true), screen())
key("select")

-- 10. Wallet: balances, and Add funds with the wallet's address as a QR code.
local WALLET = "Badge4BJRYfnu29GPWdksz7EMUbiqx5CKSZgov3AHQXe"
launch()
B.respond = a_worker({SENT})
pick("Wallet")
sees("the wallet lists what's ready to send", "Add funds Show your wallet's QR code  | SOL  0.052096561 | Bonk  1234567.89012 | USDC  10")
sees("...and says SOL is kept for fees", "0.01 SOL is kept for fees")
key("back")
B.respond = function(r) return {status = 200, body = ASSETS:sub(1, -2) .. ',"note":"Low on SOL: every payment pays its fee in SOL. Add some under Add funds."}'} end
pick("Wallet")
sees("low SOL is warned about in the wallet", "Low on SOL: every payment pays its fee in SOL.")
key("back")
B.respond = a_worker({SENT})
pick("Wallet")
local before = #B.sent
pick("USDC")
check("a balance row does nothing", #B.sent == before and screen():find("Ready to send", 1, true))
key("back")
B.sent = {}
pick("Wallet")
check("balances are asked for fresh on every visit", #B.sent == 1 and B.sent[1].path == "/assets")
pick("Add funds")
sees("the wallet's address is a QR code", "[qr " .. WALLET .. "]")
sees("...and written out, to check against the phone", "Badge4BJRYf | nu29GPWdksz | 7EMUbiqx5CK | SZgov3AHQXe")
sees("it says what to send", "any SPL token")
key("back")
sees("back from Add funds is the wallet", "Ready to send")
pick("Add funds")                         -- the stub refuses a second live QR code, so this proves the first went
sees("opening it again draws it again", "[qr " .. WALLET .. "]")
key("back") key("back")
-- An empty wallet: say so, and still show where to send.
B.respond = function(r) return {status = 200, body = EMPTY:sub(1, -2) .. ',"wallet":"' .. WALLET .. '"}'} end
pick("Wallet")
sees("an empty wallet is explained", "nothing to send on Solana yet")
check("...with Add funds the only row", #focused().it == 1)
pick("Add funds")
sees("an empty wallet still gets its QR code", "[qr " .. WALLET .. "]")
key("back") key("back")
-- Older Solana OS: no ui.qr. The address alone.
ui.qr = nil
pick("Wallet") pick("Add funds")
sees("without QR codes, the address and why", "Update Solana OS to show it as a QR code.")
sees("...still written out", "Badge4BJRYf")
ui.qr = qr
key("back") key("back")
-- No address in the answer: say so, never draw a bad code.
B.respond = function(r) return {status = 200, body = '{"text":"Connect refused the worker\'s API key."}'} end
pick("Wallet")
sees("a refused key is explained in the wallet", "Connect refused the worker's API key.")
pick("Add funds")
sees("no address: the worker's words", "Connect refused the worker's API key.")
check("no QR code without an address", not screen():find("[qr", 1, true))
key("back") key("back")
sees("back home", "Contactless Solana payments")

check("no key in any request or in storage, to the end", no_secrets())
on_exit()
print(string.format("%d passed, %d failed", passed, failed))
if failed > 0 then error("checks failed") end
