-- Connect Pay: pay anyone by X handle from the badge, through Quidli Connect.
--
-- Pick a badge nearby (or type a handle), see their social reputation, choose
-- an amount, confirm. The badge holds no key: it asks your own worker, which
-- recognises this badge by the badge server's signature and calls Connect.
--
-- Permissions: http, mesh, profile, led.   Hosts: your worker's host.

-- Your worker's address. Leave it empty to type it on the badge once (This
-- badge > Worker address), or fix it here, e.g. "https://connect-pay.me.workers.dev".
-- Either way the worker's host has to be covered by "hosts" in app.json.
local WORKER = ""

local RETRY_MS = 3000     -- between tries while Connect says "processing"
local RETRY_MAX = 6
local WIFI_WAIT_S = 20    -- how long to wait for Wi-Fi after pausing the mesh

-- ---------------------------------------------------------------------------
-- Amounts. The badge's numbers are 32-bit, so smallest-unit amounts (up to 18
-- decimals) are built and compared as strings of digits, never as numbers.
-- The worker checks every amount again; this is so the player hears early.

-- "1.5", 6 -> "1500000". nil plus a reason when the text isn't an amount.
local function to_units(text, dec)
  local int, frac = text:match("^(%d*)%.?(%d*)$")
  if not int or (int == "" and frac == "") or (text:find("%.") and frac == "") then
    return nil, "Not an amount"
  end
  if #frac > dec then return nil, "Too many decimals" end
  local units = (int .. frac .. string.rep("0", dec - #frac)):gsub("^0+", "")
  if units == "" then return nil, "Amount is zero" end
  return units
end

-- Compares two digit strings without leading zeros: -1, 0 or 1.
local function cmp_units(a, b)
  if #a ~= #b then return #a < #b and -1 or 1 end
  if a == b then return 0 end
  return a < b and -1 or 1
end

-- A random UUID (version 4): the payment's id, Connect's idempotencyKey.
local function uuid()
  local hex = "0123456789abcdef"
  local out = {}
  for i = 1, 36 do
    if i == 9 or i == 14 or i == 19 or i == 24 then
      out[i] = "-"
    elseif i == 15 then
      out[i] = "4"
    else
      local n = (i == 20) and math.random(8, 11) or math.random(0, 15)
      out[i] = hex:sub(n + 1, n + 1)
    end
  end
  return table.concat(out)
end

-- An X handle without its "@", or nil: letters, digits and "_", at most 15.
local function clean_handle(text)
  local h = (text or ""):gsub("^%s*@?", ""):gsub("%s+$", "")
  if #h < 1 or #h > 15 or not h:match("^[%w_]+$") then return nil end
  return h
end

-- ---------------------------------------------------------------------------
-- Screens: a stack of functions that each draw one screen. `gen` goes up on
-- every draw, so an answer that arrives after the player moved on is dropped.

local stack = {}
local gen = 0
local keys = nil          -- the current screen's on_key handler, if it has one
local timers = {}

local function after(ms, fn)
  local id
  id = timer.after(ms, function() timers[id] = nil fn() end)
  timers[id] = true
  return id
end

local function every(ms, fn)
  local id = timer.every(ms, fn)
  timers[id] = true
  return id
end

local function stop(id)
  if id then timer.cancel(id) timers[id] = nil end
end

local function render()
  gen = gen + 1
  for id in pairs(timers) do timer.cancel(id) end
  timers = {}
  keys = nil
  ui.clear()
  ui.bg("bg")
  local top = stack[#stack]
  top.fn(table.unpack(top.args, 1, top.args.n))
end

local function go(fn, ...)
  stack[#stack + 1] = {fn = fn, args = table.pack(...)}
  render()
end

local function replace(fn, ...)
  stack[#stack] = {fn = fn, args = table.pack(...)}
  render()
end

local function back()
  if #stack > 1 then stack[#stack] = nil end
  render()
end

local function home()
  while #stack > 1 do stack[#stack] = nil end
  render()
end

-- A function that says whether the screen that made it is still showing.
local function showing()
  local g = gen
  return function() return g == gen end
end

local function title(text, sub)
  ui.label(10, 6, text, {size = 20, w = ui.W - 20})
  if sub then ui.label(10, 32, sub, {color = "dim", w = ui.W - 20}) end
end

-- ---------------------------------------------------------------------------
-- Network. Wi-Fi and the mesh share one radio: when the mesh has it, server
-- calls answer "offline" until mesh.pause() lets Wi-Fi rejoin.

local paused = false

local function mesh_on()
  if paused and mesh.resume then mesh.resume() end
  paused = false
end

-- Calls fn(true) once the badge can reach the server, fn(false) if it can't.
local function when_online(fn)
  if badge.online() then return fn(true) end
  if mesh.pause and not paused then
    mesh.pause()
    paused = true
  end
  local waited = 0
  local t
  t = every(500, function()
    waited = waited + 1
    if badge.online() then
      stop(t)
      fn(true)
    elseif waited >= WIFI_WAIT_S * 2 then
      stop(t)
      fn(false)
    end
  end)
end

-- What a call that got no answer means, for the player.
local WHY = {
  offline = "No Wi-Fi. Turn it on in the Wi-Fi app.",
  ["not linked"] = "This badge has no owner yet. Claim it first.",
  denied = "The badge server refused: the app needs a test run (12 h, from the submit page) or to be in the store.",
  ["host not allowed"] = "The app's hosts (app.json) don't cover this worker. Add its exact host there.",
  ["too fast"] = "Too many requests. Wait a minute.",
  timeout = "The worker didn't answer in time.",
  unreachable = "The worker can't be reached. Check its address under This badge.",
  busy = "The badge is busy. Try again.",
}

local function why(err)
  return WHY[err] or ("Request failed: " .. tostring(err))
end

-- The worker's own words for an answer, if it sent any.
local function told(data, status)
  if type(data.text) == "string" and data.text ~= "" then return data.text end
  return "The worker answered " .. tostring(status)
end

-- cb(status, data) for any answer (data: the decoded JSON, {} if it isn't a
-- JSON object), cb(nil, why) when there was none.
local function worker()
  if WORKER ~= "" then return WORKER end
  return storage.get("worker")
end

local function api(method, path, body, cb)
  http.request({method = method, url = worker() .. path, body = body}, function(ok, res)
    if not ok then return cb(nil, res) end
    local data = json.decode(res.body or "")
    cb(res.status, type(data) == "table" and data or {})
  end)
end

-- ---------------------------------------------------------------------------
-- Sending. A payment is saved before it is sent and keeps its id until there
-- is a final answer for it, so a lost answer is retried as the same payment
-- and never as a second one.

local function describe(p)
  return p.amount .. " " .. p.label .. " to @" .. p.handle, p.chain
end

-- done(state, text): "sent", "processing" (try again shortly), "unknown" (it
-- may have gone through) or "failed" (nothing was sent, the payment is dropped).
--
-- p.maybe says an earlier try may have reached Connect without a final answer
-- (a timeout, a server error, or the app closing mid-request). It is saved as
-- true before each request and put back only once the worker, or the badge,
-- has said for certain that this try sent nothing. A refusal then drops the
-- payment only when no earlier try could have gone through.
local function send(p, done)
  local before = p.maybe or false
  p.maybe = true
  storage.set("pending", p)

  -- This try sent nothing, for certain.
  local function refused(text)
    if before then
      return done("unknown", text)        -- an earlier try still might have
    end
    storage.remove("pending")
    done("failed", text)
  end

  api("POST", "/pay", {id = p.id, handle = p.handle, asset = p.asset, amount = p.amount}, function(status, data)
    if not status then
      if data == "timeout" then return done("unknown", why(data)) end
      return refused(why(data))           -- the request never left the badge server
    end
    if status >= 500 then return done("unknown", told(data, status)) end
    if status ~= 200 then return refused(told(data, status)) end   -- the worker turned it away
    if data.state == "sent" then
      storage.remove("pending")
      return done("sent")
    end
    if data.state == "processing" then    -- accepted, nothing sent yet
      p.maybe = before
      storage.set("pending", p)
      return done("processing")
    end
    if data.state == "failed" then return refused(told(data, status)) end
    done("unknown", told(data, status))
  end)
end

local function sending_screen()
  local p = storage.get("pending")
  if type(p) ~= "table" then return home() end
  local what, chain = describe(p)
  title("Sending", what .. " on " .. chain)
  local line = ui.label(10, 70, "Talking to Connect...", {w = ui.W - 20})
  local detail = ui.label(10, 96, "", {w = ui.W - 20, color = "dim"})
  ui.hint("CANCEL home")
  local here = showing()
  local tries = 0
  local attempt

  local function finish(state, text)
    if not here() then return end
    if state == "sent" then
      line:text("Sent")
      line:color("green")
      detail:text(what .. " on " .. chain)
      led.fill(0x14, 0xF1, 0x95)
      timer.after(1500, led.off)
      ui.hint("SELECT done")
      keys = function(k) if k == "select" then home() return true end end
    elseif state == "processing" and tries < RETRY_MAX then
      line:text("Connect is setting up the recipient...")
      after(RETRY_MS, attempt)
    elseif state == "failed" then
      line:text("Not sent")
      line:color("orange")
      detail:text(text or "")
      ui.hint("CANCEL home")
    else
      line:text("No final answer yet")
      line:color("yellow")
      detail:text((text and (text .. " ") or "") .. "Retry is the same payment, not a second one.")
      ui.hint("SELECT retry   CANCEL home")
      keys = function(k) if k == "select" then replace(sending_screen) return true end end
    end
  end

  attempt = function()
    tries = tries + 1
    when_online(function(up)
      if not up then
        if p.maybe then return finish("unknown", why("offline")) end
        storage.remove("pending")         -- no try ever left the badge
        return finish("failed", why("offline"))
      end
      send(p, finish)
    end)
  end
  attempt()
end

-- An unfinished payment found in storage: finish it or drop it.
local function pending_screen()
  local p = storage.get("pending")
  if type(p) ~= "table" then return home() end
  local what, chain = describe(p)
  title("Unfinished payment", what .. " on " .. chain)
  ui.list(0, 56, ui.W, ui.H - 72, {
    {title = "Retry", sub = "Same payment, never a second one"},
    {title = "Discard", sub = "Stop asking about it"},
  }, {on_select = function(i)
    if i == 1 then return replace(sending_screen) end
    ui.confirm("Discard? If it already went through, it stays sent.", function(yes)
      if yes then storage.remove("pending") home() end
    end)
  end})
  ui.hint("SELECT choose   CANCEL back")
end

-- ---------------------------------------------------------------------------
-- Paying: asset, amount, confirm. What can be sent, and how much, is the
-- worker's list (GET /assets), read once per launch.

local assets = nil

local function confirm_pay(handle, a, amount)
  local units, err = to_units(amount, a.dec)
  if not units then return ui.toast(err) end
  if cmp_units(units, to_units(a.max, a.dec)) > 0 then
    return ui.toast("Most per payment: " .. a.max .. " " .. a.label)
  end
  ui.confirm("Send " .. amount .. " " .. a.label .. " to @" .. handle .. " on " .. a.chain .. "?", function(yes)
    if not yes then return end
    -- Saved before it is sent: the id has to outlive a lost answer or a restart.
    storage.set("pending", {id = uuid(), handle = handle, asset = a.id, amount = amount, label = a.label, chain = a.chain})
    while #stack > 1 do stack[#stack] = nil end
    go(sending_screen)
  end)
end

local function amount_screen(handle, a)
  title("How much " .. a.label .. "?", "To @" .. handle .. " on " .. a.chain)
  local rows = {}
  for i, amt in ipairs(a.amounts) do rows[i] = {title = amt .. " " .. a.label} end
  rows[#rows + 1] = {title = "Other amount", sub = "Up to " .. a.max .. " " .. a.label}
  ui.list(0, 56, ui.W, ui.H - 72, rows, {on_select = function(i)
    if a.amounts[i] then return confirm_pay(handle, a, a.amounts[i]) end
    ui.input("Amount in " .. a.label .. " (max " .. a.max .. ")", 12, function(text)
      if text and text ~= "" then confirm_pay(handle, a, text) end
    end)
  end})
  ui.hint("SELECT choose   CANCEL back")
end

-- True when the worker's list is something the screens can show.
local function usable(list)
  if type(list) ~= "table" or #list == 0 then return false end
  for _, a in ipairs(list) do
    if type(a) ~= "table" or type(a.id) ~= "string" or type(a.label) ~= "string" or type(a.chain) ~= "string"
       or math.type(a.dec) ~= "integer" or a.dec < 0 or a.dec > 30
       or type(a.max) ~= "string" or not to_units(a.max, a.dec) or type(a.amounts) ~= "table" then
      return false
    end
    for _, amt in ipairs(a.amounts) do
      if type(amt) ~= "string" then return false end
    end
  end
  return true
end

local function asset_screen(handle)
  title("Pay @" .. handle, "Pick what to send")
  ui.hint("SELECT choose   CANCEL back")
  local function show()
    local rows = {}
    for i, a in ipairs(assets) do rows[i] = {title = a.label, right = a.chain} end
    ui.list(0, 56, ui.W, ui.H - 72, rows, {on_select = function(i)
      go(amount_screen, handle, assets[i])
    end})
  end
  if assets then return show() end
  local line = ui.label(10, 60, "Asking the worker...", {w = ui.W - 20, color = "dim"})
  local here = showing()
  when_online(function(up)
    if not here() then return end
    if not up then return line:text(why("offline")) end
    api("GET", "/assets", nil, function(status, data)
      if not here() then return end
      if not status then return line:text(why(data)) end
      if status ~= 200 then return line:text(told(data, status)) end
      if not usable(data.assets) then return line:text("The worker's asset list can't be read.") end
      assets = data.assets
      line:remove()
      show()
    end)
  end)
end

-- ---------------------------------------------------------------------------
-- The recipient: their handle and what Connect knows of their reputation.

local function recipient_screen(handle)
  title("@" .. handle)
  local head = ui.label(10, 36, "Asking Connect...", {color = "dim", w = ui.W - 20})
  local big = ui.label(10, 56, "", {size = 32, color = "green"})
  local lines = {}
  for i = 1, 3 do lines[i] = ui.label(10, 100 + (i - 1) * 20, "", {w = ui.W - 20, color = "dim"}) end
  ui.hint("SELECT pay   CANCEL back")
  local here = showing()

  keys = function(k)
    if k ~= "select" then return end
    if storage.get("pending") then
      ui.toast("Finish the unfinished payment first")
      go(pending_screen)
    else
      go(asset_screen, handle)
    end
    return true
  end

  when_online(function(up)
    if not here() then return end
    if not up then return head:text(why("offline")) end
    api("GET", "/score/" .. handle, nil, function(status, data)
      if not here() then return end
      if not status then return head:text(why(data)) end
      if status ~= 200 or data.text then return head:text(told(data, status)) end
      if data.score == nil then return head:text("No social reputation on Connect yet") end
      head:text("Social reputation")
      big:text(tostring(data.score))
      for i, text in ipairs(type(data.lines) == "table" and data.lines or {}) do
        if lines[i] and type(text) == "string" then lines[i]:text(text) end
      end
    end)
  end)
end

-- A badge picked from the mesh: find its owner's X handle.
local function resolve_screen(id, name)
  title(name or id)
  local line = ui.label(10, 44, "Finding their X handle...", {w = ui.W - 20, color = "dim"})
  ui.hint("CANCEL back")
  local here = showing()
  when_online(function(up)
    if not here() then return end
    if not up then return line:text(why("offline")) end
    profile.get(id, function(ok, p)
      if not here() then return end
      if not ok then return line:text(why(p)) end
      local handle = type(p) == "table" and clean_handle(p.x)
      if not handle then return line:text("This badge's owner hasn't linked an X account.") end
      replace(recipient_screen, handle)
    end)
  end)
end

local function nearby_screen()
  mesh_on()
  title("Nearby badges")
  local found = {}
  local list = ui.list(0, 34, ui.W, ui.H - 50, {"Looking for badges..."}, {on_select = function(i)
    local b = found[i]
    if b then go(resolve_screen, b.id, b.name) end
  end})
  ui.hint("SELECT pick   CANCEL back")
  local shown = ""

  local function refresh()
    local now = {}
    for _, b in ipairs(mesh.nearby() or {}) do
      if b.id and (b.kind == nil or b.kind == "badge") then now[#now + 1] = b end
    end
    table.sort(now, function(x, y) return (x.rssi or -999) > (y.rssi or -999) end)
    local ids = {}
    for i, b in ipairs(now) do ids[i] = b.id end
    local sig = table.concat(ids, ",")
    if sig == shown then return end          -- same badges in the same order
    local picked = found[list:selected()]
    shown, found = sig, now
    if #now == 0 then return list:items({"Looking for badges..."}) end
    local rows = {}
    for i, b in ipairs(now) do rows[i] = {title = b.name or b.id, right = b.id} end
    list:items(rows)
    for i, b in ipairs(now) do
      if picked and b.id == picked.id then list:select(i) end
    end
  end

  refresh()
  every(2000, refresh)
end

-- ---------------------------------------------------------------------------
-- Setup: which badge this is (the worker's BADGE_IDS needs it), where the
-- worker is, and whether it lets this badge in.

-- "https://name.me.workers.dev/" or "name.me.workers.dev" -> the address, or nil.
local function clean_address(text)
  local host = (text or ""):lower():gsub("%s", ""):gsub("^https://", ""):gsub("/+$", "")
  if #host < 4 or #host > 100 or not host:match("^[%w%-]+%.[%w%-%.]+$") or host:find("%.%.") or host:sub(-1) == "." then
    return nil
  end
  return "https://" .. host
end

local function setup_screen()
  local id = badge.id()
  local addr = worker()
  title("This badge", id and ("Id " .. id .. " (for the worker's BADGE_IDS)") or "No id yet: join Wi-Fi once")
  ui.label(10, 52, addr and (addr:gsub("^https://", "")) or "No worker address yet", {w = ui.W - 20, color = "dim"})
  local line = ui.label(10, 72, "", {w = ui.W - 20})
  local here = showing()

  local function ask()
    if not worker() then return line:text("Deploy the worker, then enter its address.") end
    line:text("Asking the worker...")
    line:color("text")
    when_online(function(up)
      if not here() then return end
      if not up then return line:text(why("offline")) end
      api("GET", "/assets", nil, function(status, data)
        if not here() then return end
        if not status then return line:text(why(data)) end
        if status ~= 200 then return line:text(told(data, status)) end
        line:text("The worker accepts this badge.")
        line:color("green")
        if usable(data.assets) then assets = data.assets end
      end)
    end)
  end

  local rows, acts = {}, {}
  if addr then rows[1] = {title = "Ask again"} acts[1] = ask end
  if WORKER == "" then
    rows[#rows + 1] = {title = addr and "Change worker address" or "Enter worker address"}
    acts[#acts + 1] = function()
      ui.input("Worker address (name.you.workers.dev)", 64, function(text)
        if not text or text == "" then return end
        local a = clean_address(text)
        if not a then return ui.toast("That isn't an address") end
        storage.set("worker", a)
        assets = nil
        render()
      end)
    end
  end
  if #rows > 0 then
    ui.list(0, 128, ui.W, ui.H - 144, rows, {on_select = function(i) acts[i]() end})
  end
  ui.hint("SELECT choose   CANCEL back")
  ask()
end

local function home_screen()
  title("Connect Pay", "Pay anyone by their handle")
  local p = storage.get("pending")
  local rows, acts = {}, {}
  local function row(r, act) rows[#rows + 1] = r acts[#acts + 1] = act end
  if not worker() then
    local id = badge.id()
    row({title = "Set up", sub = id and ("Badge id " .. id .. ", for your worker") or "Point the badge at your worker"},
      function() go(setup_screen) end)
  else
    if type(p) == "table" then
      row({title = "Unfinished payment", sub = (describe(p))}, function() go(pending_screen) end)
    end
    row({title = "Nearby badges", sub = "Pick someone next to you"}, function() go(nearby_screen) end)
    row({title = "Type an X handle", sub = "Pay anyone, wherever they are"}, function()
      ui.input("X handle", 16, function(text)
        if not text or text == "" then return end
        local handle = clean_handle(text)
        if not handle then return ui.toast("That isn't an X handle") end
        go(recipient_screen, handle)
      end)
    end)
    row({title = "This badge", right = badge.id() or "no id"}, function() go(setup_screen) end)
  end
  ui.list(0, 56, ui.W, ui.H - 72, rows, {on_select = function(i) acts[i]() end})
  ui.hint("SELECT choose   CANCEL exit")
end

function on_key(k)
  if keys and keys(k) then return true end
  if k == "back" and #stack > 1 then
    back()
    return true
  end
  return false
end

function on_exit()
  led.off()
end

go(home_screen)
