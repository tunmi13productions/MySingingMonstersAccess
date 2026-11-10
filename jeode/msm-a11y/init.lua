-- ===========================================================================
-- MSM Accessibility mod - Lua layer (runs under Jeode's sandboxed mod env)
--
-- The native half (a11y.dll) registers these game globals via Jeode's
-- register_global:  a11y_speak(text[,interrupt]), a11y_silence(),
-- a11y_is_active() -> bool, a11y_log(text).
--
-- This file does the game-facing work: read the HUD on demand and announce
-- game notifications/popups, using the *verified* game.* API (see the
-- game-lua-api notes: HUD counter text, playerLevel, getPopUp, etc.).
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. Resolve the speech function.
--
-- OPEN QUESTION to confirm on first run: native register_global installs into
-- the game's Lua state. This mod's init.lua runs in Jeode's *sandbox* env, so
-- `a11y_speak` may or may not be directly visible here. We probe a few places;
-- if it stays nil, uncomment the queue_lua bridge in jeode_a11y.c (it copies
-- the functions into game _G) and/or expose them via jeode.registerGlobal.
-- ---------------------------------------------------------------------------
local function resolve(name)
    local v = rawget(_G, name)
    if type(v) == "function" then return v end
    -- try the thread's real global table (game state) if reachable
    local ok, genv = pcall(getfenv, 0)
    if ok and type(genv) == "table" and type(genv[name]) == "function" then
        return genv[name]
    end
    return nil
end

local speak         = resolve("a11y_speak")
local silence       = resolve("a11y_silence")
local is_active     = resolve("a11y_is_active")
local a11y_log      = resolve("a11y_log") or function() end
local clickFraction = resolve("a11y_click_fraction")   -- native mouse click
local tutStepFn     = resolve("a11y_tutorial_step")    -- native: returns (step,max)

if not speak then
    a11y_log("init.lua: a11y_speak NOT visible from mod sandbox - see bridge note")
    speak = function() end  -- no-op so the rest of the file is safe to load
else
    a11y_log("init.lua: speech function bound")
end

-- Small helper so accidental nils never raise inside the game loop.
local function say(text, interrupt)
    if not text then return end
    -- Game text carries colour and style tags (<c=#45db99>Diamonds</c>) that
    -- some paths pass through raw. Strip them here, so nothing speaks them.
    text = tostring(text):gsub("</?%a[^<>]*>", "")
    -- "1 diamonds", "1 Keys", "1 Common Sticker Packs": a lone 1 (not 21 or
    -- 1,001) makes the next counted word singular, up to two words on.
    if text:find("1 ", 1, true) then
        text = (" " .. text):gsub("([^%d,%.])1 (%a+)( ?)(%a*)( ?)(%a*)", function(pre, a, s1, b, s2, c)
            local words = { a, b, c }
            for k = 1, 3 do
                local w = words[k]
                local low = w:lower()
                local stem = low:match("^(.-)s$")
                if stem and (stem == "coin" or stem == "diamond" or stem == "key" or stem == "relic"
                    or stem == "shard" or stem == "medal" or stem == "wildcard" or stem == "token"
                    or stem == "pack" or stem == "egg" or stem == "point" or stem == "item"
                    or stem == "piece" or stem == "card" or stem == "ticket" or stem == "spin") then
                    words[k] = w:sub(1, -2)
                    break
                end
                if w == "" or low == "food" or low == "xp" then break end
            end
            return pre .. "1 " .. words[1] .. s1 .. words[2] .. s2 .. words[3]
        end):sub(2)
    end
    if text ~= "" then speak(text, interrupt and true or false) end
end

-- ---------------------------------------------------------------------------
-- 2. HUD readers  (verified approach: read the counter widget's text)
--    Ethereal islands use ShardCounter instead of CoinCounter.
-- ---------------------------------------------------------------------------
local LOC = game.getLocalizedText

local function counterText(name)
    local ok, hud = pcall(game.getHUD)
    if not ok or not hud then return nil end
    local widget = hud[name]
    if not widget then return nil end
    local ok2, str = pcall(function() return widget.Text("text"):GetString() end)
    if ok2 then return str end
    return nil
end

local function readCoins()    return counterText("CoinCounter") or counterText("ShardCounter") end
local function readDiamonds() return counterText("DiamondCounter") end
local function readFood()     return counterText("FoodCounter") end

local function readLevel()
    local ok, lvl = pcall(game.playerLevel)
    if ok then return lvl end
    return nil
end

-- Reject anything that isn't a real, speakable name (objects, empty, etc.)
local function humanName(v)
    if v == nil then return nil end
    local s = tostring(v)
    if s == "" then return nil end
    if s:find("userdata") or s:find("table:") or s:find("function:") then return nil end
    return s
end

-- UI stores localization KEYS (e.g. "MAIN_MENU_EXIT", "NO_GOALS_LEFT"); the game
-- localizes them at render time. Speaking the raw key is gibberish, so run any
-- ALL_CAPS_UNDERSCORE key through LOC to get real words. Non-key strings (normal
-- text, numbers like "1,861") pass through unchanged.
local function localize(s)
    if s == nil then return nil end
    s = tostring(s)
    if s == "" then return nil end
    if s:find("^[A-Z0-9_]+$") and s:find("%a") then
        for _, fn in ipairs({ function() return LOC(s) end, function() return game.getLocalizedText(s) end }) do
            local ok, t = pcall(fn)
            if ok and t then
                local h = tostring(t)
                if h ~= "" and h ~= s then return h end
            end
        end
        -- An internal key with no translation ("M_C_LVL_4") is noise, not a
        -- label: drop it so callers fall back to something speakable. Plain
        -- capitalised words ("OPTIONS") are real button text and are kept.
        if s:find("_") then return nil end
    end
    return s
end

-- Strip colour/markup tags (e.g. <c=#6efa05>) and localize bare keys.
local function cleanText(s)
    if not s then return nil end
    s = tostring(s):gsub("<[^>]*>", ""):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
    if s == "" then return nil end
    return localize(s)
end

-- Speech joining. Game text often ends in its own punctuation ("...island?"),
-- so add a full stop only where one is missing: no "?." or "..".
local function trimEnd(s) return (tostring(s):gsub("[%s%.,;:]+$", "")) end
local function endsSentence(s) return tostring(s):find("[%.!?]%s*$") ~= nil end
local function joinSentences(parts)
    local out = ""
    for _, p in ipairs(parts) do
        if p and p ~= "" then
            if out ~= "" then out = out .. (endsSentence(out) and " " or ". ") end
            out = out .. p
        end
    end
    return out
end
-- "1. First, 2. Second" style list for screen readers: each item trimmed of
-- trailing punctuation, numbered, and ended with a full stop.
local function numberedList(items)
    local out = {}
    for i, it in ipairs(items) do out[#out + 1] = i .. ". " .. trimEnd(it) .. "." end
    return table.concat(out, " ")
end

local function readIsland()
    -- Strategy 1 (proven on 5.4): island id -> name key -> localized text.
    local ok, r = pcall(function() return LOC(game.islandName(game.currentIsland())) end)
    r = ok and humanName(r) or nil
    if r then return r end

    -- Strategy 2: island type enum -> localized.
    ok, r = pcall(function() return LOC(game.currentIslandType()) end)
    r = ok and humanName(r) or nil
    if r then return r end

    -- Strategy 3: ask the active Island object for its type/name directly.
    ok, r = pcall(function()
        local isl = game.player():getActiveIsland()
        if not isl then return nil end
        for _, m in ipairs({ "getType", "getName", "name", "type" }) do
            if type(isl[m]) == "function" then
                local v = isl[m](isl)
                if v ~= nil then return LOC(v) end
            end
        end
        return nil
    end)
    return ok and humanName(r) or nil
end

-- Full HUD summary, spoken on demand (bind to a hotkey / call from console).
local function announceHud()
    local parts = {}
    local lvl = readLevel();      if lvl then parts[#parts+1] = "Level " .. tostring(lvl) end
    local isl = readIsland();     if isl then parts[#parts+1] = tostring(isl) end
    local coins = readCoins();    if coins then parts[#parts+1] = coins .. " coins" end
    local dia = readDiamonds();   if dia then parts[#parts+1] = dia .. " diamonds" end
    local food = readFood();      if food then parts[#parts+1] = food .. " food" end
    if #parts == 0 then say("HUD not available", true)
    else say(table.concat(parts, ", "), true) end
end

-- ---------------------------------------------------------------------------
-- 3. Automatic announcements
--    game.displayNotification is a verified, real call -> speak toasts.
-- ---------------------------------------------------------------------------
if type(game.displayNotification) == "function" then
    local orig_notify = game.displayNotification
    game.displayNotification = function(msg, ...)
        say(localize(msg), false)
        return orig_notify(msg, ...)
    end
    a11y_log("patched game.displayNotification")
end

-- Confirmation dialogs (yes / no) get their question from the caller. Keep it
-- so the dialog's announcement can read it even when its label isn't readable.
local lastConfirmation = { text = nil, t = -100 }
if type(game.displayConfirmation) == "function" then
    local orig_confirm = game.displayConfirmation
    game.displayConfirmation = function(id, msg, ...)
        pcall(function()
            lastConfirmation.text = cleanText(msg)
            lastConfirmation.t = os.clock()
        end)
        return orig_confirm(id, msg, ...)
    end
    a11y_log("patched game.displayConfirmation")
end

-- ---------------------------------------------------------------------------
-- Popup / menu announcements  (EVENT-DRIVEN, safe)
--
-- The game opens dialogs with game.pushPopUp(id) (verified in decompiled
-- scripts: game.pushPopUp("island_select") etc.). We wrap it and announce
-- INSIDE that call -- the game's own execution context, where the freshly
-- built popup is valid. This is the crash-safe replacement for the old poller
-- that deref'd stale popups during transitions. Everything is pcall-guarded so
-- a weird popup can never crash the game.
-- ---------------------------------------------------------------------------

-- Common MSM popup button element names (from decompiled scripts + M1 probe).
local POPUP_BTN_PROBE = {
    "OkayButton","OKButton","OkButton","ContinueButton","Continue",
    "YesButton","NoButton","CloseButton","CancelButton","ConfirmButton","AcceptButton",
    "DeclineButton","BuyButton","PurchaseButton","CollectButton","CollectAllButton",
    "ClaimButton","SkipButton","WatchButton","ShareButton","RetryButton","NextButton",
    "PrevButton","BackButton","StartButton","PlayButton","DoneButton","SellButton",
    "FeedButton","HatchButton","PlaceButton","UpgradeButton","InfoButton","HelpButton",
    "SettingsButton","ExitButton","QuitButton","GoButton",
}

-- Read a label from a UI element: try elem.Text('text') then elem('text').
local function elementText(e)
    if not e then return nil end
    -- A hidden caption is a leftover (template default "Meebs are cute" on
    -- picture items, "Monster Hunter Joe" on empty friend cards): skip it.
    local hidden = false
    pcall(function() hidden = e.Text("visible"):GetInt() == 0 end)
    if hidden then return nil end
    local ok, t = pcall(function() return e.Text("text"):GetString() end)
    if not (ok and t and #tostring(t) > 0) then
        ok, t = pcall(function() return e("text"):GetString() end)
    end
    -- Context bar buttons (template_barbutton) keep their caption here.
    if not (ok and t and #tostring(t) > 0) then
        ok, t = pcall(function() return e.ButtonLabel("text"):GetString() end)
    end
    if not (ok and t and #tostring(t) > 0) then
        ok, t = pcall(function() return e("ButtonLabelText"):GetString() end)
    end
    if ok and t and #tostring(t) > 0 then
        t = tostring(t):gsub("<[^>]*>", ""):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
        if t ~= "" then return localize(t) end
    end
    return nil
end

-- Text of an element's visible descendants, for list rows whose label lives in
-- children (bakery food: name, amount and time, price).
local function descendantText(el, depth, parts)
    parts = parts or {}
    if depth > 3 or #parts >= 4 then return parts end
    local kids = nil; pcall(function() kids = el:elements() end)
    if not kids then return parts end
    local n = 0; pcall(function() n = kids:size() end)
    for i = 0, n - 1 do
        if #parts >= 4 then break end
        local c = nil; pcall(function() c = kids[i] end)
        if c then
            local vis = 1; pcall(function() vis = c.Text("visible"):GetInt() end)
            local t = vis ~= 0 and elementText(c) or nil
            if t and not t:find("^[%p%s]*$") then parts[#parts + 1] = t end
            descendantText(c, depth + 1, parts)
        end
    end
    return parts
end

-- Humanize a popup id like "popup_breed_warning" -> "breed warning".
local function popupDisplayName(id)
    if id == nil then return "dialog" end
    local s = tostring(id)
    if s == "social" then return "Friends" end
    local ok, loc = pcall(function() return LOC(s) end)
    local h = ok and humanName(loc) or nil
    if h and h ~= s then return h end
    return (s:gsub("^popup_", ""):gsub("_", " "))
end

-- The popup's heading, if it has one.
-- Find a descendant element by name (breadth-first, a few levels deep).
-- Screens opened from C++ hand us their outer menu root, so the dialog's
-- Title / Notification elements sit a couple of levels below it.
local function findNamed(root, name, maxDepth)
    local level = { root }
    for _ = 0, maxDepth or 4 do
        local nextLevel = {}
        for _, el in ipairs(level) do
            -- Compare child element names: el[name] could also return one of
            -- el's components (every button has a "Text" component).
            local kids = nil; pcall(function() kids = el:elements() end)
            local n = 0; pcall(function() n = kids:size() end)
            for i = 0, n - 1 do
                local c = nil; pcall(function() c = kids[i] end)
                if c then
                    local cn = nil; pcall(function() cn = c:name() end)
                    if cn == name then return c end
                    nextLevel[#nextLevel + 1] = c
                end
            end
        end
        if #nextLevel == 0 then return nil end
        level = nextLevel
    end
    return nil
end

-- Text of a named label, if it is showing (hidden placeholders like the
-- newsflash "TITLE" or a confirmation's "..." are skipped).
local function shownText(root, name)
    local el = findNamed(root, name)
    if not el then return nil end
    local vis = 1
    pcall(function() vis = el.Text("visible"):GetInt() end)
    if vis == 0 then return nil end
    local t = elementText(el)
    if not t or t:find("^[%.%s]*$") then return nil end
    return t
end

local TITLE_NAMES = { "Title", "TitleText", "TitleLabel", "Header" }
-- Left / Center / Right: the numbered steps of "How it works" screens.
local BODY_NAMES = { "Text", "Message", "MessageText", "Body", "Description", "Desc", "Notification", "Notification2",
                     "NotificationBottom",
                     "Left", "Center", "Right" }

local function popupTitle(popup)
    if not popup then return nil end
    for _, nm in ipairs(TITLE_NAMES) do
        local t = shownText(popup, nm)
        if t then return t end
    end
    return nil
end

-- The popup's body / message text (everything that isn't the heading).
local function popupBody(popup)
    if not popup then return nil end
    local parts = {}
    for _, nm in ipairs(BODY_NAMES) do
        local t = shownText(popup, nm)
        if t and t ~= parts[#parts] then parts[#parts + 1] = t end
    end
    if #parts > 0 then return joinSentences(parts) end
    return nil
end

-- Is an element visible / clickable (has a Touch child)?
local function isVisible(el)
    local vis = true
    pcall(function() if el.isVisible == false then vis = false end end)
    -- Buttons hidden with setInvisible: every sprite and the caption off.
    -- (The game can switch such a button's touch back on, as on empty
    -- friend cards, so touch alone doesn't say it is showing.)
    if vis then
        pcall(function()
            if el.UpSprite("visible"):GetInt() == 0 and el.DownSprite("visible"):GetInt() == 0
                and el.Text("visible"):GetInt() == 0 then vis = false end
        end)
    end
    return vis
end
-- Has a Touch component that the game hasn't switched off (hidden context bar
-- buttons and tutorial-blocked controls have Touch "enabled" = 0).
-- isClickable.heldBack: buttons the Enter guard (nav.guardEnter) switched off
-- for a moment; they still count, so a new question lists Yes as well as No.
local isClickable = setmetatable({ heldBack = {} }, { __call = function(self, el)
    local hit = false
    pcall(function() if el.Touch ~= nil then hit = true end end)
    if not hit then return false end
    local en = 1
    pcall(function() en = el.Touch("enabled"):GetInt() end)
    return en ~= 0 or self.heldBack[tostring(el)] == true
end })
local function elementName(el)
    local nm = nil
    pcall(function() nm = tostring(el:name()) end)
    return nm
end

-- Friendly names for known island/HUD controls (element name -> spoken label).
-- Counters get their live value appended.
local FRIENDLY = {
    IslandTitleBG = "Island name",
    GoalsButton = "Goals", RankButton = "Rank", ActivityButton = "Activity",
    StickerbookButton = "Sticker book", ViewButton = "Menu", ProfilePic = "Profile",
    EncoreBar = "Encore", Handle = "More counters",
    CoinCounter = "Coins", DiamondCounter = "Diamonds", FoodCounter = "Food",
    MedalCounter = "Medals", WildcardCounter = "Wildcards", KeyCounter = "Keys",
    RelicCounter = "Relics", StarCounter = "Star power",
    BattleButton = "Battle", DailyLoginButton = "Daily login", CalendarButton = "Calendar",
    ShowAll = "Show all", Featured = "Featured",
    -- Colossingum quests (template_battle_campaign_infopane.xml).
    TeamTab = "Team tab: your monsters for this battle", OpponentsTab = "Opponents tab",
    StartBattleButton = "Start battle", ProgressInfoButton = "Quest stages and rewards",
    SMP_CLOSE = "Close",
}
-- Names that are decoration/containers/backgrounds -- never a navigable control.
local function isChrome(name)
    if not name then return true end
    return name:find("BG$") or name:find("Backing") or name:find("Bracket")
        or name:find("^Xp") or name:find("Notification") or name:find("Indicator")
        or name:find("Anim") or name:find("Sprite") or name:find("^debug")
        or name:find("ScrollMarker") or name:find("HelpArrow") or name:find("Faded")
        or name:find("Entries$") or name:find("^Panel") or name:find("^Tray")
        or name:find("^Timer") or name:find("RewardBar") or name:find("EventType")
        or name:find("^Block$") or name:find("Fader")
end

-- Decide if a clickable element is a real, speakable control. Returns its label,
-- or nil to skip. FRIENDLY names always win (chrome check bypassed for those).
-- The bar's currency counters (currency_counter_0/1/2): coins (shards on
-- ethereal islands), diamonds, food.
local function currencyCounterName(name)
    local n = name and name:match("^currency_counter_(%d+)$")
    if not n then return nil end
    if n == "0" then
        local ethereal = false
        pcall(function() ethereal = game.player():getActiveIsland():isEtherealIsland() and true or false end)
        return ethereal and "Shards" or "Coins"
    end
    local known = ({ ["1"] = "Diamonds", ["2"] = "Food" })[n]
    if known then return known end
    -- The number is the counter's currency type (CurrencyCounter.lua): match
    -- it against the game's own CurrencyType_ values.
    for _, c in ipairs({ { "Shards", "Shards" }, { "Starpower", "Starpower" }, { "Keys", "Keys" },
                         { "Relics", "Relics" }, { "Medals", "Medals" }, { "EggWildcards", "Egg Wildcards" },
                         { "MinigameTokens", "Minigame Tokens" }, { "ClubboxTokens", "Clubbox Tokens" },
                         { "CardPack", "Sticker Packs" }, { "BattleXp", "Battle XP" }, { "Xp", "XP" },
                         { "Coins", "Coins" }, { "Diamonds", "Diamonds" }, { "Food", "Food" } }) do
        local v = nil
        pcall(function() v = game["CurrencyType_" .. c[1]] end)
        if v ~= nil and tostring(v) == n then return c[2] end
    end
    return "Currency"
end

-- Rarity of a monster type id, only when it isn't an ordinary monster
-- ("Rare", "Epic", "Seasonal", "Mythical"); nil for ordinary ones. withRarity
-- puts it before a species name unless the name already says it. On
-- FRIENDLY, not a local: the main chunk is at Lua's 200-local limit.
function FRIENDLY.__withRarity(name, typeId)
    if not typeId or not name then return name end
    local w = nil
    for _, r in ipairs({ { "isSeasonal", "Seasonal" }, { "isMythicalType", "Mythical" },
                         { "isEpic", "Epic" }, { "isRare", "Rare" } }) do
        local ok, v = pcall(function() return game[r[1]](typeId) end)
        if ok and v == true then w = r[2] break end
    end
    if not w or name:lower():find(w:lower(), 1, true) then return name end
    return w .. " " .. name
end

-- Friends screen (social.xml, template_social_card, template_topislandsentry_new).
-- Its buttons are icons whose meaning comes from the sprite or the parent.
-- Returns label, true (final: no row context added) or nil.
local controlLabel
do
local SOCIAL_SORT = {
    FilterFavourites = "Show favourites only", FilterTorch = "Show unlit torches only",
    SortAlpha = "Sort by name", SortActivity = "Sort by last login",
    SortLevel = "Sort by level", SortTorches = "Sort by torches",
}
local BOOK_FILTERS = {
    MonsterSingleGeneFilter = "one element", MonsterDoubleGeneFilter = "two elements",
    MonsterTripleGeneFilter = "three elements", MonsterQuadGeneFilter = "four elements",
    MonsterFiveGeneFilter = "five elements", MonsterSpecialFilter = "special monsters",
}
local CARD_ICONS = {
    button_light_torch = "Light torch", button_light_torch_highlight = "Light torch",
    keys = "Send key", button_yes = "Accept request", button_no = "Decline request",
}
local function comp(el, c, var)
    local v = nil
    pcall(function() v = el:C(c)(var or "text"):GetString() end)
    if v then v = cleanText(localize(v) or v) end
    if v == "" then v = nil end
    return v
end
local function parentOf(el)
    local p = nil; pcall(function() p = el:parent() end)
    return p
end
-- A friend card's name, the way cardSummary reads it.
local function cardName(card)
    local full = nil
    pcall(function() full = card("DisplayNameText"):GetString() end)
    if full == "" then full = nil end
    return full or elementText(findNamed(card, "DisplayName", 1))
end
local function cardSummary(card)
    local parts = {}
    local full = nil
    pcall(function() full = card("DisplayNameText"):GetString() end)
    if full == "" then full = nil end
    parts[#parts + 1] = full or elementText(findNamed(card, "DisplayName", 1)) or "Friend"
    local pic = findNamed(card, "ProfilePic", 1)
    local lvl = pic and elementText(findNamed(pic, "Level", 1))
    if lvl then parts[#parts + 1] = "level " .. lvl end
    local act = elementText(findNamed(card, "Activity", 1))
    if act then parts[#parts + 1] = act end
    return table.concat(parts, ", ")
end
local function cardShown(card)
    local vis = 0
    pcall(function() vis = card:C("bg")("visible"):GetInt() end)
    return vis ~= 0
end
-- The open letter in the Inbox (mail.xml CurrentSender / CurrentMessage /
-- AttachmentDetails): text components on plain elements, so no button reads it.
local function mailMessage(el)
    local parts = {}
    local sender = findNamed(el, "CurrentSender", 1)
    local msg = findNamed(el, "CurrentMessage", 1)
    local att = findNamed(el, "AttachmentDetails", 1)
    local function add(e, c, prefix)
        if not e then return end
        local v = 0
        pcall(function() v = e:C(c)("visible"):GetInt() end)
        local t = v ~= 0 and comp(e, c) or nil
        if t then parts[#parts + 1] = (prefix or "") .. t end
    end
    add(sender, "Text", "From ")
    add(msg, "Text")
    add(att, "Name", "Attachment: ")
    add(att, "Expiry")
    if #parts == 0 then return nil end
    return table.concat(parts, ". ")
end

-- A Book of Monsters entry (BOMEntry.lua): only a portrait, so describe it
-- from its MonsterID the way BOMEntry:Refresh decides how to draw it.
local function bookEntry(e)
    local id, shown, filtered = nil, true, false
    pcall(function() id = e.MonsterID end)
    pcall(function() shown = e.visible ~= false end)
    pcall(function() filtered = e.FilteredOut == true end)
    if not id or id == 0 or not shown then return nil end
    local name = nil
    pcall(function() name = cleanText(LOC(game.getMonsterData(id):name())) end)
    local parts = { name or "Unknown monster" }
    pcall(function()
        if game.isSeasonal(id) then parts[#parts + 1] = "seasonal"
        elseif game.isEpic(id) then parts[#parts + 1] = "epic"
        elseif game.isRare(id) then parts[#parts + 1] = "rare" end
    end)
    local owned, avail, unlock, lvl = false, false, nil, nil
    pcall(function() owned = game.hasOrHasEverHadMonsterOnBookOfMonstersIsland(id) == true end)
    pcall(function() avail = game.monsterIsAvail(id, false) or game.monsterIsAvail(id, true) end)
    pcall(function() unlock = game.monsterUnlockLevel(id); lvl = game.playerLevel() end)
    if owned then parts[#parts + 1] = "collected"
    elseif not avail then parts[#parts + 1] = "not collected, not available now"
    elseif unlock and lvl and lvl < unlock then parts[#parts + 1] = "not collected, unlocks at level " .. unlock
    else parts[#parts + 1] = "not collected" end
    if filtered then parts[#parts + 1] = "filtered out" end
    return table.concat(parts, ", ")
end
-- "You received:" (popup_store_bundle_rewards): Contents/entryN/NameFrame.
local function rewardList(root)
    local out = {}
    local contents = root and findNamed(root, "Contents", 5)
    local kids = nil; pcall(function() kids = contents:elements() end)
    local n = 0; pcall(function() n = kids:size() end)
    for i = 0, n - 1 do
        local c = nil; pcall(function() c = kids[i] end)
        local t = c and elementText(findNamed(c, "NameFrame", 1))
        if t then out[#out + 1] = t end
    end
    return out
end
-- Breeding (breeding_v2): two lists, LeftMonsterSelect ("Monster 1") and
-- RightMonsterSelect ("Monster 2"), of List/entryN rows. A picked row's Bg
-- turns yellow (BreedingMonsterListEntry.SetSelected).
local BREED_SIDES = { LeftMonsterSelect = "Monster 1", RightMonsterSelect = "Monster 2" }
local BREED_OTHER = { LeftMonsterSelect = "RightMonsterSelect", RightMonsterSelect = "LeftMonsterSelect" }
local function breedSideOf(el)
    local cur = el
    for _ = 1, 3 do
        cur = parentOf(cur)
        local nm = cur and elementName(cur)
        if nm and BREED_SIDES[nm] then return cur, nm end
    end
    return nil
end
local function breedSelected(entry)
    local s = ""
    pcall(function() s = findNamed(entry, "Bg", 1):C("Sprite")("spriteName"):GetString() end)
    return tostring(s):find("yellow") ~= nil
end
local function breedName(entry)
    return elementText(findNamed(entry, "MonsterName", 1)) or elementText(findNamed(entry, "MonsterSpecies", 1))
end
-- The picked monster's name in one side's list, if any.
local function breedPick(side)
    local list = side and findNamed(side, "List", 1)
    local kids = nil; pcall(function() kids = list:elements() end)
    local n = 0; pcall(function() n = kids:size() end)
    for i = 0, n - 1 do
        local c = nil; pcall(function() c = kids[i] end)
        if c and isVisible(c) and breedSelected(c) then return breedName(c) or "a monster" end
    end
    return nil
end
-- Both picks on the breeding screen: monster 1, monster 2 (either may be nil).
local function breedPicks(root)
    local l, r = findNamed(root, "LeftMonsterSelect", 4), findNamed(root, "RightMonsterSelect", 4)
    return breedPick(l), breedPick(r), findNamed(root, "HeartButton", 4)
end
FRIENDLY.__social = { cardShown = cardShown, cardSummary = cardSummary, mailMessage = mailMessage,
                      bookEntry = bookEntry, rewardList = rewardList, breedPicks = breedPicks,
                      BREED_SIDES = BREED_SIDES }

local function socialLabel(el, name)
    if not name then return nil end
    -- Tabs keep their caption in a "Label" component (Friends, profile editor).
    if name:find("^Tab%u") then
        local t = comp(el, "Label") or elementText(el)
            or name:gsub("^Tab", ""):gsub("(%l)(%u)", "%1 %2")
        return t .. " tab", true
    end
    -- HUD eye button: hides the whole interface to view the island.
    local sprite = name == "ViewButton" and comp(el, "Sprite", "spriteName")
    if sprite == "button_show_hud" then return "Show menus (view mode is on)", true end
    if sprite == "button_hide_hud" then return "Hide menus (view mode)", true end
    local p = parentOf(el)
    local pn = p and elementName(p)
    -- HUD: the Clubbox and Sticker book buttons are pictures (an inner
    -- "Button" with a timer / count); name them from their holder.
    if name == "Button" and pn == "ClubboxButton" then
        local parts = { "Clubbox" }
        local left = elementText(findNamed(el, "TimerBar", 1))
        if left then parts[#parts + 1] = left .. " left" end
        local tickets = elementText(findNamed(el, "TicketBar", 1))
        if tickets then parts[#parts + 1] = tickets .. " tickets" end
        return table.concat(parts, ", "), true
    end
    if name == "Button" and pn == "StickerbookButton" then
        local stars = elementText(findNamed(el, "StarBar", 1))
        return "Sticker book" .. (stars and (", " .. stars) or ""), true
    end
    -- Map: the selected island's arrows and GO; the alert buttons at the top.
    if (name == "LeftButton" or name == "RightButton") and pn == "Main" then
        return name == "LeftButton" and "Previous island" or "Next island", true
    end
    if name == "ActivateButton" and pn == "Main" then
        local island = elementText(findNamed(p, "IslandName", 1))
        return (elementText(el) or "Go") .. (island and (", travel to " .. island) or ""), true
    end
    -- Battle moves (template_battle_action_button): the move's name and type
    -- are text components on the button itself, not child elements.
    if pn == "ActionBar" and name:find("^ActionButton%d$") then
        local function ctext(c)
            local t = nil
            pcall(function()
                if el[c]("visible"):GetInt() ~= 0 then t = cleanText(el[c]("text"):GetString()) end
            end)
            return (t and t ~= "") and t or nil
        end
        local locked = 0; pcall(function() locked = el("locked"):GetInt() end)
        local n = tonumber(name:match("%d")) + 1
        if locked == 1 then return "Move " .. n .. ": locked", true end
        local parts = { ctext("ActionName") or ("Move " .. n) }
        local kind = ctext("ActionTypeName")
        if kind then parts[#parts + 1] = kind end
        local res = 0; pcall(function() res = el("elementalResistance"):GetFloat() end)
        if res > 0 then parts[#parts + 1] = "elemental advantage"
        elseif res < 0 then parts[#parts + 1] = "elemental disadvantage" end
        local on = 1; pcall(function() on = el["Touch"]("enabled"):GetInt() end)
        if on == 0 then parts[#parts + 1] = "not available now" end
        a11y_log("[battle] " .. name .. " resistance " .. tostring(res))
        return table.concat(parts, ", "), true
    end
    -- "Get it now" SPEED UP (get_it_now_breed): the price is a Cost text
    -- component on the button, kept current by the game (diamondsLeftToSpeedup).
    if name == "GetItNow" then
        local cost = nil
        pcall(function() cost = cleanText(el["Cost"]("text"):GetString()) end)
        cost = cost and cost:gsub("^%-", "")
        local text = elementText(el) or "Speed up"
        if cost and cost ~= "" then return text .. ", " .. cost .. " Diamonds", true end
    end
    -- Jukebox tunes (jukebox: Contents/entryN SongName + LockedIcon).
    if name:find("^entry%d+$") and pn == "Contents" then
        local song = elementText(findNamed(el, "SongName", 1))
        if song then
            local lock = findNamed(el, "LockedIcon", 1)
            return song .. ((lock and isVisible(lock)) and ", locked" or ""), true
        end
    end
    -- Colossingum quest: team slots (tap one to choose a monster in SELECT
    -- MONSTER) and opponents. Entries carry LevelFrame/NameFrame texts.
    if (pn == "TeamView" or pn == "OpponentView") and name:find("^entry%d+$") then
        local n = tonumber(name:match("%d+")) + 1
        local who = elementText(findNamed(el, "NameFrame", 1))
        local lvl = elementText(findNamed(el, "LevelFrame", 1))
        local desc = who and (who .. (lvl and (", " .. lvl) or "")) or nil
        if pn == "OpponentView" then return "Opponent " .. n .. ": " .. (desc or "unknown"), true end
        if desc then return "Team slot " .. n .. ": " .. desc .. ". Enter to change", true end
        return "Team slot " .. n .. ": empty. Enter to choose a monster", true
    end
    -- Wishing Torch bar: two LIGHT buttons (a day / for good), the friends
    -- highlight toggle and BUY MORE, told apart by their FunctionName.
    if name:find("^barItem%d+$") and FRIENDLY.__torchLabel then
        local t = FRIENDLY.__torchLabel(el) or FRIENDLY.__upgradeLabel(el) or FRIENDLY.__speedUpLabel(el)
            or FRIENDLY.__removeLabel(el) or FRIENDLY.__feedLabel(el)
        if t then return t, true end
    end
    -- Promo tray (PromoCenterItem_<id>): a picture plus a countdown. Name the
    -- offer from its promo data (PromoCenter.lua's DebugPrintAllPromoInfo fields).
    if name == "Button" and pn and pn:find("^PromoCenterItem_") then
        local parts = {}
        local promo = nil; pcall(function() promo = p.promo end)
        local function field(k)
            -- The promo's fields are methods (ComboPack.lua: promo:storeItemTitle()).
            local v = nil
            pcall(function() v = promo[k] end)
            if type(v) == "function" then
                local f = v; v = nil
                pcall(function() v = f(promo) end)
            end
            if type(v) ~= "string" or v == "" then return nil end
            v = cleanText(localize(v) or v)
            return (v and v ~= "") and v or nil
        end
        local title = field("storeItemTitle") or field("storeItemName")
        if not title then
            -- Offers shown as an ad: the ad's own title.
            pcall(function()
                local ad = game.nativePlacement(promo.placement):getAd(0)
                title = cleanText(ad:getTitle())
            end)
        end
        parts[1] = "Offer" .. (title and title ~= "" and (": " .. title) or "")
        local disc = field("discountText")
        if disc then parts[#parts + 1] = disc end
        local left = elementText(el)
        if left then parts[#parts + 1] = left .. " left" end
        return table.concat(parts, ", "), true
    end
    -- Goal rows (named by goal id): the arrow that shows where to do it. Not
    -- final: the goal's text and rewards are added after.
    if name == "HelpArrow" and pn and pn:find("^%d+$") then return "Show me", false end
    -- Hype game (HypeGame.lua): its HypeBar is the spin button; Minus /
    -- Plus step through the ticket amounts.
    if pn == "hype_game" then
        local g = p
        local tickets = nil
        pcall(function() tickets = g.currentTickets end)
        -- HypeButton spins; the HypeBar opens Hype Progress.
        if name == "HypeButton" then
            return "Spin" .. (tickets and (" with " .. tickets .. (tickets == 1 and " ticket" or " tickets")) or ""), true
        end
        if name == "HypeBar" then
            local pts = elementText(findNamed(el, "RewardBar", 1))
            local a, b = (pts or ""):match("(%d+)%s*/%s*(%d+)")
            return "Hype progress" .. (a and (", " .. a .. " of " .. b) or ""), true
        end
        if name == "MinusButton" then return "Fewer tickets" .. (tickets and (", now " .. tickets) or ""), true end
        if name == "PlusButton" then return "More tickets" .. (tickets and (", now " .. tickets) or ""), true end
    end
    -- Hype Progress (ClubboxProgress.lua): each stop on the path holds its
    -- reward's name (TooltipText; the shown tooltip is a "Hello"
    -- placeholder) and is coloured grey (locked), teal (earned) or yellow
    -- (the one being worked toward).
    local stop = name and name:match("^ClubboxProgressNode(%d+)$")
    if stop then
        local parts = { "Reward " .. stop }
        local what = nil
        pcall(function() what = el.TooltipText end)
        if type(what) == "string" and what ~= "" then
            local t = cleanText(LOC(what)) or what
            t = t:gsub("%s*\n%s*", ", "):gsub("%s+unlocked!?$", "")
            parts[#parts + 1] = t
        end
        local base = ""
        pcall(function() base = tostring(el:C("Base")("spriteName"):GetString()) end)
        if base:find("teal") then parts[#parts + 1] = "earned"
        elseif base:find("yellow") then parts[#parts + 1] = "next"
        elseif base:find("grey") then parts[#parts + 1] = "locked" end
        return table.concat(parts, ", "), true
    end
    -- Opening a sticker pack (OpenCardPack.lua): the whole screen is the
    -- "Click to continue" button.
    if name == "Fade" and pn == "open_card_pack" then
        local left = elementText(findNamed(p, "CurrencyCounter", 1))
        return "Continue" .. (left and (", " .. left .. " packs left") or ""), true
    end
    -- CUSTOMIXER (template_ClubboxPerfEditor / template_ClubStageEdEntry).
    if name == "CategoryIcon" and pn and pn:find("^Prop%d+$") then
        return FRIENDLY.__mixPerformer(p), true
    end
    -- Performer volume sliders (template_club_perfSlider: SliderBg under
    -- VolumeControl under the PropN row).
    if name == "SliderBg" and pn == "VolumeControl" then
        local t = FRIENDLY.__mixVolume(el)
        if t then return t, true end
    end
    -- One-slider screens (Time Warper, monster volume, decoration size).
    if name == "Slider" and FRIENDLY.__sliderKinds then
        for _, k in ipairs(FRIENDLY.__sliderKinds) do
            if k.screen == pn then
                local v = k.get()
                return k.name .. ", slider, " .. (k.text and k.text(v) or FRIENDLY.__warp.text()), true
            end
        end
    end
    -- Options page: the Motion FX switch (ToggleScreenFx; ToggleArea is the touch).
    if name == "ToggleArea" and pn == "ToggleScreenFx" then
        local on = nil
        pcall(function() on = p:IsToggled() and true or false end)
        local what = elementText(p) or "Motion FX"
        return what:gsub("^Enable ", "") .. (on == nil and "" or (on and ", on" or ", off")), true
    end
    if name == "VariantControlButton" and pn and pn:find("^StageEditorBg%d+$") then
        return FRIENDLY.__mixStage(p, el), true
    end
    -- Fuzer CONJURE (fuzer_create.xml): three Glowbes to pick from, entries
    -- named 0, 1 and 2, coloured by game.tintDefaultBuddy(entry, i).
    if pn == "FuzerEntries" and name and name:find("^%d$") then
        return FRIENDLY.__glowbeChoice(el, tonumber(name)), true
    end
    -- INFO on a building with no close button: tapping outside closes it.
    if name == "FadedBG" and pn == "object_info" then return "Close", true end
    if (name == "YesButton" or name == "NoButton") and (pn == "popup_text_entry" or pn == "popup_name_entry") then
        if name == "NoButton" then return "Cancel", true end
        local d = (elementText(findNamed(p, "Description", 1)) or ""):lower()
        if d:find("friend", 1, true) then return "Send friend request", true end
        return pn == "popup_name_entry" and "Save" or "OK", true
    end
    -- Clubbox unlock fanfare ("DJ Epic has joined the Act"): tap anywhere.
    if name == "Fade" and pn == "popup_clubbox_unlock_fanfare" then return "Continue", true end
    -- Clubbox HUD: the Hype bar.
    if name == "HypeBar" then
        local pts = elementText(findNamed(el, "RewardBar", 1))
        local a, b = (pts or ""):match("(%d+)%s*/%s*(%d+)")
        if a then return "Hype progress, " .. a .. " of " .. b, true end
        return "Hype progress" .. (pts and (", " .. pts) or ""), true
    end
    -- Clubbox act cards (template_clubbox_acts_entry): only a poster; the
    -- act is its actId (ClubboxActSelect: game.getClubboxActTitle).
    if name and name:find("^entry%d+$") then
        local id = nil
        pcall(function() id = el.actId end)
        if type(id) == "number" and id > 0 then
            local t = nil
            pcall(function() t = cleanText(LOC(game.getClubboxActTitle(id))) end)
            if t and t ~= "" then
                local sel = nil
                pcall(function() sel = el.parent.selectedActId end)
                return "Act: " .. t .. (sel == id and ", selected" or ""), true
            end
        end
    end
    -- HUD Encore button: the event's points and time left.
    if name == "EncoreBar" then
        local parts = { "Encore event" }
        local pts = elementText(findNamed(el, "RewardBar", 1))
        local a, b = (pts or ""):match("(%d+)%s*/%s*(%d+)")
        if a then parts[#parts + 1] = a .. " of " .. b .. " points" elseif pts then parts[#parts + 1] = pts end
        local left = elementText(findNamed(el, "Timer", 1))
        if left then parts[#parts + 1] = left .. " left" end
        return table.concat(parts, ", "), true
    end
    local MAP_ALERTS = { SeasonalAlertButton = "Seasonal event", SaleAlertButton = "Sale",
                         NotificationAlertButton = "Notifications" }
    if MAP_ALERTS[name] then return MAP_ALERTS[name], true end
    -- Hatching fanfare: "The egg is ready! Click it to crack it open!" The egg
    -- needs 7 taps (MonsterHatchFanfare.lua NUM_CRACK_TAPS); Enter taps it
    -- until it opens (nav.crackEgg). In the tutorial there may be no Skip
    -- button, so this is the way on.
    if name == "EggImage" then return "Egg, press Enter to crack it open", true end
    -- A monster's info screen: the name plate at the top is the rename button
    -- (SharedObjectInfo.lua ImageTitle -> game.showMonsterNamePopup). Its
    -- touch is switched off for anything that isn't a monster.
    if name == "ImageTitle" then
        local t = elementText(el)
        return "Rename" .. (t and (", now called " .. t) or ""), true
    end
    -- The full-screen "Click to continue" area (rewards, card packs, the new
    -- island fanfare), shown only while that caption is showing.
    if (name == "Fade" or name == "TouchBlocker") and p and FRIENDLY.__saysContinue(p, 0) then
        return "Continue", true
    end
    -- Hatch fanfare after the egg cracks: the NEW badge says what hatched.
    if name == "NewLabel" and pn == "popup_hatch_monster_fanfare" then
        return FRIENDLY.__hatchedText(p) or "New monster", true
    end
    -- Breeding list rows: name, species, whether picked, and who they'd breed with.
    if name:find("^entry%d+$") and pn == "List" then
        local side, sideName = breedSideOf(el)
        if side then
            local parts = { breedName(el) or "Monster" }
            local species = elementText(findNamed(el, "MonsterSpecies", 1))
            -- The row's Lua object keeps its monster (BreedingMonsterListEntry).
            local tid, kind = nil, "none"
            pcall(function()
                local m = el.monster
                kind = type(m)
                if kind == "userdata" then tid = m:monsterTypeId()
                elseif kind == "table" then tid = m.monsterTypeId or m.monsterId or m.MonsterId end
                if type(tid) == "function" then tid = tid(m) end
            end)
            if not A11Y_RARITY_LOGGED then
                A11Y_RARITY_LOGGED = true
                a11y_log("[rarity] breeding row monster is " .. kind .. ", type id " .. tostring(tid))
            end
            if species then species = FRIENDLY.__withRarity(species, tonumber(tid)) end
            if species and species ~= parts[1] then parts[#parts + 1] = species end
            local els = tid and FRIENDLY.__elementsOf(tid)
            if els then parts[#parts + 1] = els end
            local feed = findNamed(el, "feed_overlay", 1)
            local need = feed and isVisible(feed) and elementText(feed)
            if need then parts[#parts + 1] = need end
            if breedSelected(el) then
                parts[#parts + 1] = "selected"
            else
                local otherSide = findNamed(parentOf(side), BREED_OTHER[sideName], 1)
                local other = breedPick(otherSide)
                if other then
                    parts[#parts + 1] = "breed with " .. other
                    local hint = FRIENDLY.__pairHint(tid, FRIENDLY.__pickTid(otherSide))
                    if hint then parts[#parts + 1] = hint end
                end
            end
            return table.concat(parts, ", "), true
        end
    end
    -- Inbox rows (template_mailentry / template_newsentry): title and sender
    -- live in the row's vars.
    if name == "ViewButton" and pn and pn:find("^mail_%d") then
        local parts = { "View" }
        local function var(n)
            local v = nil; pcall(function() v = p(n):GetString() end)
            v = v and cleanText(v)
            return v
        end
        local title = var("title") or var("shortTitle")
        if title then parts[#parts + 1] = title end
        local sender = var("sender")
        if sender then parts[#parts + 1] = "from " .. sender end
        return table.concat(parts, ", "), true
    end
    -- Profile editor: picture items have no caption, only a sprite.
    if name:find("^item%d+$") and pn == "Panel" then
        local t = elementText(el)
        if not t then
            local s = comp(el, "Sprite", "spriteName")
            s = s and s:match("([^/]+)$")
            if s then
                s = s:gsub("%.%w+$", ""):gsub("^__BUILTIN__WHITE_TEXTURE$", "colour")
                t = s:gsub("_", " "):gsub("(%l)(%u)", "%1 %2")
            end
        end
        local sel = false
        pcall(function() sel = el:C("SelectedSprite")("visible"):GetInt() ~= 0 end)
        return (t or "item") .. (sel and ", selected" or ""), true
    end
    -- Book of Monsters: collected counters and element filters.
    local rarity = name:match("^Collected(%u%l+)$")
    if rarity then
        local t = elementText(el) or ""
        local a, b = t:match("(%d+)%s*/%s*(%d+)")
        return rarity .. (a and (", " .. a .. " of " .. b .. " collected") or (", " .. t)), true
    end
    if name == "FilterButton" and pn and BOOK_FILTERS[pn] then
        local on = false
        pcall(function() on = el.isSelected == true end)
        return "Filter: " .. BOOK_FILTERS[pn] .. (on and ", on" or ", off"), true
    end
    if name == "EditIcon" then return "Edit display name", true end
    if name == "DisplayName" and pn == "Card" then
        return "Display name, " .. (elementText(el) or "") .. ", edit", true
    end
    if name == "FilterButton" and pn and SOCIAL_SORT[pn] then
        return SOCIAL_SORT[pn], true
    end
    if name == "CopyIdButton" then
        local code = p and elementText(p)
        return "Copy friend code" .. (code and (", " .. code) or ""), true
    end
    if pn and pn:find("^cardItem%d") and (name == "SmallLeftButton" or name == "SmallRightButton" or name == "LargeButton") then
        local action = elementText(el)
        if not action then
            local sprite = comp(el, "Overlay", "spriteName")
            action = sprite and CARD_ICONS[sprite] or name:gsub("Button$", "")
        end
        local off = false
        pcall(function() off = el.enabled == false end)
        -- Short: the card itself already reads level and last login.
        local who = cardName(p) or "this friend"
        local t
        if action == "Light torch" then t = "Light " .. who .. "'s torch"
        elseif action == "Send key" then t = "Send key to " .. who
        elseif action == "Accept request" or action == "Decline request" then t = action .. " from " .. who
        else t = action .. " " .. who end
        return t .. (off and ", unavailable" or ""), true
    end
    if name == "FavoriteToggleButton" and pn and pn:find("^cardItem%d") then
        local s = comp(el, "Sprite", "spriteName")
        return "Favourite " .. (cardName(p) or "this friend") .. (s == "favoritestar" and ", on" or ", off"), true
    end
    if name == "VisitButton" and pn and pn:find("^topIslandEntry%d") then
        local parts = { "Visit" }
        local rank = comp(p, "Rank")
        if rank then parts[#parts + 1] = "rank " .. rank end
        parts[#parts + 1] = comp(p, "UserName")
        parts[#parts + 1] = comp(p, "IslandName")
        return table.concat(parts, ", "), true
    end
    return nil
end

controlLabel = function(el, name)
    local special, final = socialLabel(el, name)
    if special then return special, final end
    local friendly = name and (FRIENDLY[name] or currencyCounterName(name))
    if friendly then
        local t = elementText(el)           -- append counter value if present
        if t and not friendly:find(t, 1, true) then return friendly .. ", " .. t end
        return friendly
    end
    -- Real visible text makes it a genuine control (popup buttons like "Show All").
    local t = elementText(el)
    if t then return t end
    -- Names ending in Button are controls even without text.
    if name and name:find("Button$") and not isChrome(name) then
        return (localize(name) or name):gsub("Button$", "")
    end
    if isChrome(name) then return nil end
    -- Icon-only context bar buttons: name them after the action they run.
    local fn = nil; pcall(function() fn = el("FunctionName"):GetString() end)
    if fn and fn ~= "" then
        return (fn:gsub("^show_", ""):gsub("_", " "))
    end
    -- List rows: label from their children.
    local parts = descendantText(el, 0)
    if #parts > 0 then return table.concat(parts, ", ") end
    return nil                              -- background / container: skip
end
end -- do (controlLabel)

-- Goal rows (template_goalentry): a bare "Collect" says nothing about which
-- goal it pays out. Name the goal and its rewards, read from the row itself
-- (GoalDesc text, rewardEntry<RewardId> elements with a RewardAmount var).
local REWARD_WORDS = {
    { "RewardCoins", "coins" }, { "RewardDiamonds", "diamonds" }, { "RewardFood", "food" },
    { "RewardXp", "XP" }, { "RewardShards", "shards" }, { "RewardKeys", "keys" },
    { "RewardRelics", "relics" }, { "RewardStarpower", "starpower" }, { "RewardEntity", nil },
}

-- The goal's text: a GoalDesc text component on the row itself (5.7.4), or
-- a GoalDesc child element (older versions).
FRIENDLY.__goalDesc = function(row)
    local v = nil
    pcall(function() v = row:C("GoalDesc")("text"):GetString() end)
    if v and v ~= "" then
        v = cleanText(localize(v) or v)
        if v and v ~= "" then return v end
    end
    local descEl = findNamed(row, "GoalDesc", 1)
    local desc = elementText(descEl)
    if not desc and descEl then
        local parts = descendantText(descEl, 0)
        if #parts > 0 then desc = table.concat(parts, " ") end
    end
    return desc
end

-- The goal row holding el: a child of GoalEntries (rows are named by goal id).
local function goalRow(el)
    local cur = el
    for _ = 1, 4 do
        local p = nil; pcall(function() p = cur:parent() end)
        if not p or p == cur then return nil end
        if elementName(p) == "GoalEntries" then return cur end
        cur = p
        if findNamed(cur, "GoalDesc", 1) then return cur end
    end
    return nil
end

local function goalRewards(row)
    local parts = {}
    for _, r in ipairs(REWARD_WORDS) do
        local e = findNamed(row, "rewardEntry" .. r[1], 6)
        if e then
            local amount = nil; pcall(function() amount = e("RewardAmount"):GetString() end)
            if not amount or amount == "" then amount = elementText(e) end
            if r[2] then
                if amount and amount ~= "" then parts[#parts + 1] = amount .. " " .. r[2] end
            else
                local item = nil
                pcall(function()
                    local q = game.getQuest(row("id"):GetInt())
                    item = cleanText(game.getLocalizedText(game.entityName(q:getRewardEntity())))
                end)
                parts[#parts + 1] = item or "an item"
            end
        end
    end
    return parts
end

local function withGoalContext(el, label)
    local row = goalRow(el)
    if not row then return label end
    local desc = FRIENDLY.__goalDesc(row)
    local out = label
    if desc and not label:find(desc, 1, true) then out = out .. ": " .. desc end
    -- Progress ("2/5") under the Collect spot, while the goal isn't done.
    local prog = findNamed(row, "Progress", 1)
    if prog and isVisible(prog) then
        local t = nil
        pcall(function() t = prog:C("Label")("text"):GetString() end)
        t = t and cleanText(t)
        if t and t ~= "" then out = out .. ". Progress " .. t end
    end
    local rewards = goalRewards(row)
    if #rewards > 0 then out = out .. ". Reward: " .. table.concat(rewards, ", ") end
    return out
end

-- List rows. A row (a monster in the breeding list) is a button with its own
-- text (MonsterName, MonsterSpecies), and may hold buttons of its own (Feed!).
-- Its text, names first: "Fwub, Fwog".
local function rowText(el)
    local names, others = {}, {}
    local kids = nil; pcall(function() kids = el:elements() end)
    local n = 0; pcall(function() n = kids:size() end)
    for i = 0, n - 1 do
        local c = nil; pcall(function() c = kids[i] end)
        if c and isVisible(c) and not isClickable(c) then
            local t = elementText(c)
            if t then
                local nm = elementName(c) or ""
                if nm:find("Name$") then names[#names + 1] = t else others[#others + 1] = t end
            end
        end
    end
    for _, t in ipairs(others) do names[#names + 1] = t end
    return names
end

-- A button inside a row says which row: "Feed! Fwub, Fwog".
local function withRowContext(el, label)
    local cur = el
    for _ = 1, 3 do
        local p = nil; pcall(function() p = cur:parent() end)
        if not p or p == cur then return label end
        cur = p
        if isClickable(cur) then
            local t = rowText(cur)
            if #t > 0 then
                local ctx = table.concat(t, ", ", 1, t[2] and 2 or 1)
                if not label:find(ctx, 1, true) then return label .. " " .. ctx end
                return label
            end
        end
    end
    return label
end

-- Recursively collect navigable controls under `root` into `out` (arrays of
-- {el=, label=}). Depth/count limited; read-only, fully pcall-guarded; runs at a
-- queue_lua frame boundary so it can't race the engine.
-- Does this element contain another clickable element? Then it is a scroller
-- or panel (the breeding menu's monster lists), not a button: naming it from
-- its contents read out the whole list on every Tab.
local function hasClickableDescendant(el, depth)
    if depth > 5 then return false end
    local kids = nil; pcall(function() kids = el:elements() end)
    local n = 0; pcall(function() n = kids:size() end)
    for i = 0, n - 1 do
        local c = nil; pcall(function() c = kids[i] end)
        if c and isVisible(c) and (isClickable(c) or hasClickableDescendant(c, depth + 1)) then return true end
    end
    return false
end

local MAX_NAV_DEPTH = 10
local MAX_NAV_ITEMS = 120
local function collectControls(root, out, depth, group)
    if not root or depth > MAX_NAV_DEPTH or #out >= MAX_NAV_ITEMS then return end
    local kids = nil
    pcall(function() kids = root:elements() end)
    if not kids then return end
    local n = 0
    pcall(function() n = kids:size() end)
    for i = 0, n - 1 do
        if #out >= MAX_NAV_ITEMS then return end
        local child = nil
        pcall(function() child = kids[i] end)
        local cname = child and elementName(child)
        local social = FRIENDLY.__social
        local card = cname and cname:find("^cardItem%d") and social
        if card and not social.cardShown(child) then
            child = nil                              -- empty friend slot
        elseif cname and social and cname:find("^monsterEntry%d") then
            local text = social.bookEntry(child)
            if text then
                local c = child
                out[#out + 1] = { el = { virtual = function() c:touch() end }, label = text }
            end
            child = nil                              -- portraits only below
        elseif cname == "IslandName" and social and elementName(root) == "book_o_monsters" and elementText(child) then
            local text = elementText(child)
            out[#out + 1] = { el = { virtual = function() say(text, true) end }, label = "Page: " .. text }
        elseif cname and cname:find("^scratchEntry%d$") and FRIENDLY.__scratch and elementName(root) == "ScratchBox" then
            -- Scratch ticket squares: Enter rubs the coating off (FRIENDLY.__scratch).
            local S = FRIENDLY.__scratch
            local i = tonumber(cname:match("%d$"))
            if i == 0 then
                out[#out + 1] = { el = { virtual = function() S.scratch({ 0, 1, 2, 3, 4, 5 }) end },
                                  label = "Scratch all squares" }
            end
            local lbl = S.label(i)
            if lbl then
                out[#out + 1] = { el = { virtual = function() S.scratch({ i }) end }, label = lbl }
            end
            child = nil
        elseif cname and cname:find("^cardEntry%d+$") and FRIENDLY.__flip and elementName(root) == "Cards" then
            -- Memory game cards: Enter turns the card over (FRIENDLY.__flip).
            local i = tonumber(cname:match("%d+$")) + 1
            local lbl = FRIENDLY.__flip.label(child, i)
            if lbl then
                out[#out + 1] = { el = { virtual = function() FRIENDLY.__flip.turn(i) end }, label = lbl }
            end
            child = nil
        elseif cname == "Slider" and FRIENDLY.__warp and elementName(root) == "warp_popup" then
            -- Time Machine's WARP slider only answers dragging: buttons instead.
            local W = FRIENDLY.__warp
            out[#out + 1] = { el = { virtual = function() say(W.text(), true) end }, label = W.text() }
            out[#out + 1] = { el = { virtual = function() W.step(0.1) end }, label = "Faster" }
            out[#out + 1] = { el = { virtual = function() W.step(-0.1) end }, label = "Slower" }
            out[#out + 1] = { el = { virtual = function() W.set(1.0) end }, label = "Normal speed" }
            child = nil
        elseif cname == "Layout" and FRIENDLY.__conundrum and elementName(root) == "MainPanel" then
            -- Colossal Conundrum puzzle: progress as one item.
            local text = FRIENDLY.__conundrum(root)
            if text then
                local short = text:match("^[^%.]+") or text
                out[#out + 1] = { el = { virtual = function() say(text, true) end },
                                  label = "Puzzle, " .. short .. ", Enter for details" }
            end
            child = nil
        elseif cname == "StatsList" and FRIENDLY.__infoIsMonster() and FRIENDLY.__infoTab(root) == "stats" then
            -- Stats tab: each row's label (Stat) and value (Value), as the
            -- game words them (template_stat_*.xml).
            for _, row in ipairs(FRIENDLY.__statRows(child)) do
                local text = row
                out[#out + 1] = { el = { virtual = function() say(text, true) end }, label = text }
            end
            child = nil
        elseif cname == "InfoContent" and FRIENDLY.__infoIsMonster() and FRIENDLY.__infoTab(root) == "bio" then
            local bio = elementText(child)
            if bio then
                out[#out + 1] = { el = { virtual = function() say(bio, true) end }, label = "Bio: " .. bio }
            end
            child = nil
        elseif cname == "InfoLikes" and FRIENDLY.__likes and isVisible(child)
            and FRIENDLY.__infoIsMonster() and FRIENDLY.__infoTab(root) ~= "stats"
            and FRIENDLY.__infoTab(root) ~= "bio" then
            -- Likes tab: pictures only; name them from game.getLikes.
            local text = nil
            pcall(function()
                local st = FRIENDLY.__likeStatus(game.selectedMonsterId())
                if st then
                    text = "Likes: " .. table.concat(st.items, "; ") .. "; and a mystery like. "
                        .. st.met .. " of " .. st.total .. " known likes met"
                end
            end)
            if not text then pcall(function() text = FRIENDLY.__likes(game.selectedMonsterTypeId()) end) end
            if text then
                out[#out + 1] = { el = { virtual = function() say(text, true) end }, label = text }
            end
            child = nil
        elseif cname == "CurrentSender" and social then
            local text = social.mailMessage(root)
            if text then
                out[#out + 1] = { el = { virtual = function() say(text, true) end }, label = "Message: " .. text }
            end
        end
        if card and child then
            -- The card itself opens the friend's profile (SocialCard.OnCardClicked).
            local c = child
            out[#out + 1] = { el = { virtual = function() c:OnCardClicked() end },
                              label = social.cardSummary(c) .. ", open profile" }
        end
        if child and isVisible(child) then
            local isRow = hasClickableDescendant(child, 0) and #rowText(child) > 0
            -- A friend card is already listed once, as "open profile" above.
            if not card and isClickable(child) and (isRow or not hasClickableDescendant(child, 0)) then
                local lbl, final = controlLabel(child, cname)
                -- Market items: the price is a number with a currency icon.
                if lbl and cname == "Button" and FRIENDLY.__spinPrize and elementName(root) == "minigame_spinprize" then
                    local prize = FRIENDLY.__spinPrize()
                    if prize then lbl = lbl .. ", " .. prize end
                end
                if lbl and cname and cname:find("^storeItem%d+$") and FRIENDLY.__storePrice then
                    pcall(function() lbl = FRIENDLY.__storePrice(child, lbl) end)
                end
                -- MEMORY on the Castle: the game marks a free game with "!"
                -- (template_flipindicator, game.showFreeFlipIndicator).
                if lbl then
                    pcall(function()
                        if child("FunctionName"):GetString() == "play_memory_minigame" then
                            lbl = lbl .. (game.showFreeFlipIndicator() and ", free game ready" or ", no free game yet")
                        end
                    end)
                end
                if final then isRow = false end
                if isRow then
                    -- Its own text plus what its inner buttons say ("Requires Level 4").
                    local parts = rowText(child)
                    local kids = nil; pcall(function() kids = child:elements() end)
                    local n = 0; pcall(function() n = kids:size() end)
                    for i = 0, n - 1 do
                        local c = nil; pcall(function() c = kids[i] end)
                        local t = c and isVisible(c) and isClickable(c) and elementText(c)
                        if t then parts[#parts + 1] = t end
                    end
                    lbl = table.concat(parts, ", ")
                end
                if lbl and not final then
                    local before = lbl
                    lbl = withGoalContext(child, lbl)
                    if lbl == before then lbl = withRowContext(child, lbl) end
                end
                if lbl and lbl:find("%w") then out[#out + 1] = { el = child, label = lbl, group = group } end
            end
            -- Named lists (breeding's Monster 1 / Monster 2): announced on entry,
            -- and [ / ] jump between them.
            local side = social and cname and social.BREED_SIDES[cname]
            collectControls(child, out, depth + 1, side and (side .. " list") or group)   -- recurse into containers too
        end
    end
end

-- Navigable controls under a root: returns parallel {objects}, {labels}.
local function scanClickables(root)
    local out = {}
    -- A picker shown inside a screen (Colossingum SELECT MONSTER, set by
    -- BattleMonsterSelectUI "IsShowing"): list only the picker, not the
    -- screen behind it.
    pcall(function()
        local smp = findNamed(root, "SelectMonstersPopup", 4)
        if smp and smp("IsShowing"):GetInt() == 1 then root = smp end
    end)
    if root then collectControls(root, out, 0) end
    local items, labels, groups = {}, {}, {}
    for i, rec in ipairs(out) do items[i] = rec.el; labels[i] = rec.label; groups[i] = rec.group or false end
    return items, labels, groups
end

-- Screens whose message is not in their element tree.
-- newsflash (update alerts, events, offers): the message is an image; the ad
-- behind it carries the title and description (Newsflash.lua: nativePlacement).
local function newsflashText(root)
    local el = nil
    pcall(function() el = root["newsflash"] end)
    el = el or root
    local parts = {}
    pcall(function()
        local placement = game.nativePlacement(el("placement"):GetString())
        local ad = placement:getAd(el("index"):GetInt())
        for _, getter in ipairs({ "getTitle", "getDescription" }) do
            local ok, t = pcall(function() return ad[getter](ad) end)
            t = ok and cleanText(t) or nil
            if t and t ~= parts[#parts] then parts[#parts + 1] = t end
        end
    end)
    if #parts == 0 then return nil end
    return joinSentences(parts)
end

local POPUP_READERS = { newsflash = newsflashText }

local function announcePopup(id, popup)
    -- Screens can share one root (a notice over the Hype game): read only
    -- this screen's own element.
    if id ~= nil and popup then
        local own = findNamed(popup, tostring(id), 3)
        if own and isVisible(own) then popup = own end
    end
    -- Prefer the popup's real title; fall back to the humanized id.
    local title = popupTitle(popup)
    local msg = title or popupDisplayName(id)
    local body = popupBody(popup)
    if not body then
        -- Log the dialog's element names (and any text) so missing labels can be added.
        local names, budget = {}, 40
        local function walk(el, depth)
            if depth > 4 or budget <= 0 then return end
            local kids = nil; pcall(function() kids = el:elements() end)
            local n = 0; pcall(function() n = kids:size() end)
            for i = 0, n - 1 do
                local c = nil; pcall(function() c = kids[i] end)
                if c and budget > 0 then
                    budget = budget - 1
                    local cn = "?"; pcall(function() cn = tostring(c:name()) end)
                    local t = elementText(c)
                    names[#names + 1] = cn .. (t and ("='" .. t .. "'") or "")
                    walk(c, depth + 1)
                end
            end
        end
        pcall(walk, popup, 0)
        a11y_log("[announce] no message found for " .. tostring(id) .. ": " .. table.concat(names, " "))
    end
    if not body and lastConfirmation.text then
        local now = 0; pcall(function() now = os.clock() end)
        if now - lastConfirmation.t < 3 then body = lastConfirmation.text end
    end
    lastConfirmation.text = nil
    local reader = POPUP_READERS[tostring(id)]
        or (tostring(id):find("_event_screen$") and POPUP_READERS.__eventScreen)
    if reader then
        local t = nil
        pcall(function() t = reader(popup) end)
        if t then msg, body = t, nil end
    end
    if body and body ~= msg then msg = joinSentences({ msg, body }) end
    local _, labels = scanClickables(popup)
    if #labels > 0 then
        msg = joinSentences({ msg, #labels .. (#labels == 1 and " button: " or " buttons: ") .. table.concat(labels, ", ") })
        msg = msg .. ". Tab to move, Enter to select."
    end
    say(msg, true)
end

-- On-demand: read whatever popup is currently on top (for a future hotkey).
local function announceCurrentPopup()
    local ok, popup = pcall(game.getPopUp)
    if not ok or not popup then say("No dialog open", true) return end
    local ok2, name = pcall(game.getTopPopUpName)
    pcall(announcePopup, ok2 and name or nil, popup)
end

-- Popup object tracking. game.getPopUp() returns an EMPTY wrapper (confirmed by
-- UI dump: "?") -- the real, enumerable popup object is only the return value of
-- game.pushPopUp(). So we keep our own stack of {obj,id}, pushed/popped by
-- hooking both calls, and navigate the top of it.
local popupStack = {}

-- game.getPopUp() returns the top popup's NAME (a string). "MenuReduxElement_Root"
-- is the island base -- i.e. no real popup. This is the check the game's own
-- scripts use (ContextBar.lua). hasPopUp() proved unreliable here.
-- Quiet period while the game switches places (island <-> Market).
-- The game frees the island's bar state but its own bar script still reads
-- it (manager:getContext) for a few frames: a use-after-free that only
-- crashes when that memory has been reused, which the mod's per-frame work
-- and key handling make likely. So for 4 seconds after a switch starts the
-- mod does nothing at all: screen ticks return at once and every key only
-- says "Still loading". Started only by events (a switching button, a
-- Places entry, Escape in the Market, a Market screen or the island HUD
-- FIRST appearing), never by a screen that keeps ticking, so it always ends.
FRIENDLY.__lockUntil = -100
FRIENDLY.__storeSeenAt = -100
FRIENDLY.__seen = {}
function FRIENDLY.__lockKeys(why)
    local now = 0; pcall(function() now = os.clock() end)
    if now >= FRIENDLY.__lockUntil then a11y_log("[quiet] 4 seconds: " .. tostring(why)) end
    FRIENDLY.__lockUntil = now + 4
end
function FRIENDLY.__quietNow(now)
    return now < FRIENDLY.__lockUntil
end
function FRIENDLY.__keysLocked()
    local now = 0; pcall(function() now = os.clock() end)
    if now < FRIENDLY.__lockUntil then
        -- Said once per quiet period; further presses stay silent.
        if FRIENDLY.__loadingSaidFor ~= FRIENDLY.__lockUntil then
            FRIENDLY.__loadingSaidFor = FRIENDLY.__lockUntil
            say("Loading", true)
        end
        return true
    end
    return false
end
-- The game's own bar script (ContextBar.lua onTick) calls manager:getContext()
-- 17 times a frame. While the game switches to the Market that reads the
-- island's freed bar state (crash at exe+0x214a00 when the memory has been
-- reused). Wrap the bar's onTick so it skips while the Market is up or a
-- switch is under way; the bar isn't shown there. Decided from which screens
-- tick (pure Lua), never by asking the game. Applied once per bar instance.
FRIENDLY.__barWrapped = {}
FRIENDLY.__barSkips = 0
function FRIENDLY.__inMarketOrSwitching(now)
    return now - FRIENDLY.__storeSeenAt < 0.5 or now < FRIENDLY.__lockUntil
end
function FRIENDLY.__wrapBar(root)
    local bar = findNamed(root, "ContextBar", 2)
    if not bar then return end
    local id = tostring(bar)
    if FRIENDLY.__barWrapped[id] then return end
    FRIENDLY.__barWrapped[id] = true
    local orig = nil
    pcall(function() orig = bar.onTick end)
    if type(orig) ~= "function" then
        a11y_log("[barguard] ContextBar onTick not reachable (" .. type(orig) .. ")")
        return
    end
    local ok, err = pcall(function()
        bar.onTick = function(...)
            local now = 0; pcall(function() now = os.clock() end)
            if FRIENDLY.__inMarketOrSwitching(now) then
                FRIENDLY.__barSkips = FRIENDLY.__barSkips + 1
                if FRIENDLY.__barSkips == 1 or FRIENDLY.__barSkips % 600 == 0 then
                    a11y_log("[barguard] skipped the bar's tick " .. FRIENDLY.__barSkips .. " times")
                end
                return
            end
            return orig(...)
        end
    end)
    local now2 = nil; pcall(function() now2 = bar.onTick end)
    a11y_log("[barguard] wrap " .. (ok and "set" or ("failed: " .. tostring(err))) .. ", reads back as "
        .. ((now2 == orig) and "the original" or type(now2)))
end
-- Every key handler goes through this.
function FRIENDLY.__keyGuard(fn)
    return function(...)
        if FRIENDLY.__keysLocked() then return end
        return fn(...)
    end
end
local function currentPopupName()
    local n = ""
    pcall(function() n = tostring(game.getPopUp()) end)
    return n
end
local function popupOpen()
    local n = currentPopupName()
    return n ~= "" and n ~= "MenuReduxElement_Root" and n ~= "nil"
end

-- MSVC's clock() is wall time since process start, so this is a real timer.
local function clock() local t = 0; pcall(function() t = os.clock() end); return t end

-- Last popup announced, so a menu's own tick doesn't announce it a second time.
local lastAnnounced = { id = nil, t = -100 }

if type(game.pushPopUp) == "function" then
    local orig_push = game.pushPopUp
    game.pushPopUp = function(id, ...)
        local popup = orig_push(id, ...)
        popupStack[#popupStack + 1] = { obj = popup, id = id }
        lastAnnounced.id, lastAnnounced.t = tostring(id), clock()
        pcall(announcePopup, id, popup)
        return popup
    end
    a11y_log("patched game.pushPopUp (event-driven popup announcements)")
else
    a11y_log("game.pushPopUp not found - popup announcements unavailable")
end

for _, fn in ipairs({ "popPopUp", "popTopPopUp" }) do
    if type(game[fn]) == "function" then
        local orig = game[fn]
        game[fn] = function(...)
            local r = orig(...)
            popupStack[#popupStack] = nil          -- top closed
            return r
        end
    end
end

-- ---------------------------------------------------------------------------
-- Live menu registry. Every game menu XML is overridden (generated by
-- scripts/Build-MenuOverrides.ps1) with an invisible A11yHook element whose
-- onTick calls a11y_menuTick(root, file). So any screen the game opens, even
-- from C++ (bakery, context bar, confirmations), hands us a fresh root each
-- frame, and stops the moment it's gone, so we never hold a stale handle.
-- ---------------------------------------------------------------------------
-- Menus that are always on screen (or always ticking) on the island. Anything
-- else that is live is a screen opened on top of the island.
local PERSISTENT_MENUS = { hud = true, contextbar = true, tutorial = true, empty = true, load_fade = true, friend_hud = true,
                           hud_clubbox = true }
local DIALOG_BUTTONS = { "YesButton", "NoButton", "OkayButton", "OkButton", "BuyButton", "ConfirmButton",
                         "CancelButton", "CloseButton", "PurchaseButton" }
local MENU_FRESH_SECONDS = 0.5
local menus = {}   -- file name -> { root, t, frame, rootName, countdown }
-- Which roots are safe to touch. A screen can be freed at any moment (pressing
-- Market swaps the whole island for the store), and touching a freed element
-- crashes the game outright. So a root counts only if its menu ticked after
-- the mod last pressed anything, and hasn't missed its own usual tick: screens
-- don't all tick every frame (the map doesn't), so each one's interval is
-- learned. "Missed" is measured against the newest tick of any menu, not the
-- clock, so one slow frame doesn't hide every screen.
-- (A table, not locals: the main chunk is at Lua's 200-local limit.)
local menuState = { announceFrames = 4, activated = -100, lastTick = -100,
    -- Panels that open alongside placing or a selected decoration (Show Grid,
    -- Decoration Size). Never a screen of their own, and they can linger.
    sidePanels = { showgrid_popup = true, scale_popup = true, volume_popup = true } }
function menuState.usable(m)
    if m == nil or m.root == nil or m.t <= menuState.activated then return false end
    if clock() - m.t > MENU_FRESH_SECONDS then return false end
    return menuState.lastTick - m.t <= 1.5 * (m.gap or 0.05) + 0.004
end
-- Call right before pressing, selecting or opening anything.
function menuState.touch() menuState.activated = clock() end
-- Did any screen open (or grow a new panel) at or after time t? Used to tell
-- a tap that opened something from a tap on empty ground.
function menuState.openedSince(t)
    for _, m in pairs(menus) do
        if ((m.appeared or -100) >= t or (m.opened or -100) >= t) and clock() - m.t <= MENU_FRESH_SECONDS then
            return true
        end
    end
    return false
end

-- Menus with their own announcer (tutorial hook) or that are always on screen.
local function selfAnnounced(file)
    return file:find("^popup_tutorial") or file == "tutorial" or file == "hud" or file == "contextbar"
        or file == "empty" or file == "load_fade" or file == "store_categoryselect"
        or menuState.sidePanels[file]
end

-- Actions to run a little later on the game thread (after the camera moves,
-- after a selection settles). Driven by menu ticks, which run every frame.
local pending = {}
local function later(seconds, fn)
    pending[#pending + 1] = { t = clock() + seconds, fn = fn }
end

-- Tap a point of the game window, (fx, fy) in 0..1. Prefers the native
-- a11y_touch, which calls the game's own mouse handler (no Windows click, so
-- display scaling, other windows or the real mouse can't get in the way):
-- move there, press, and release a few frames later. Falls back to a real
-- click when the handler couldn't be found (a game update).
function menuState.tap(fx, fy)
    local touch = resolve("a11y_touch")
    if type(touch) == "function" then
        local ok, sent = pcall(touch, fx, fy, 2)
        if ok and sent then
            pcall(touch, fx, fy, 1)
            later(0.05, function() pcall(touch, fx, fy, 0) end)
            return true
        end
    end
    if type(clickFraction) == "function" then clickFraction(fx, fy) return true end
    return false
end
-- An action with p.perRoot runs once for each menu that ticks after its time
-- (it gets that menu's live root) until p.stop; anything else runs once.
local function runPending(now, root)
    if #pending == 0 then return end
    local list = pending
    pending = {}                  -- actions may schedule more via later()
    for _, p in ipairs(list) do
        if now < p.t then
            pending[#pending + 1] = p
        elseif p.perRoot then
            local key = tostring(root)
            if root and not p.done[key] then p.done[key] = true; pcall(p.fn, root) end
            if now < p.stop then pending[#pending + 1] = p end
        elseif p.everyTick then
            -- Runs on every menu tick (each live root) until p.finished or p.stop.
            if root then pcall(p.fn, root, now) end
            if not p.finished and now < p.stop then pending[#pending + 1] = p end
        else
            pcall(p.fn)
        end
    end
end

-- Set later (placement watcher); runs on every context bar tick.
local contextbarHook = nil
local readyHook = nil      -- set to watchReady further down
local walletHook = nil     -- set to watchWallet further down

local function menuTick(root, file)
    local now = clock()
    do
        local last = FRIENDLY.__seen[file]
        FRIENDLY.__seen[file] = now
        local appeared = not last or now - last > MENU_FRESH_SECONDS
        local market = file:find("^store") or file:find("^admin_store")
        if market then
            if appeared then FRIENDLY.__lockKeys("Market opening (" .. file .. ")") end
            FRIENDLY.__storeSeenAt = now
        elseif file == "hud" and appeared and now - FRIENDLY.__storeSeenAt < 10 then
            FRIENDLY.__lockKeys("back from the Market")
        end
        if file == "contextbar" then pcall(FRIENDLY.__wrapBar, root) end
        if FRIENDLY.__quietNow(now) then return end
    end
    runPending(now, root)
    if file == "contextbar" and contextbarHook then pcall(contextbarHook) end
    if file == "hud" and readyHook then pcall(readyHook, now) end
    if (file == "popup_name_entry" or file == "popup_text_entry") and menuState.nameEcho then pcall(menuState.nameEcho, root) end
    if file == "minigame_spinprize" and FRIENDLY.__spinTick then pcall(FRIENDLY.__spinTick, root) end
    if file == "login_base" and FRIENDLY.__loadingTick then pcall(FRIENDLY.__loadingTick, root) end
    if file == "newsflash" and FRIENDLY.__newsTick then pcall(FRIENDLY.__newsTick, root, now) end
    if file == "hype_game" and FRIENDLY.__hypeTick then pcall(FRIENDLY.__hypeTick, root, now) end
    if file == "clubbox_customization" and FRIENDLY.__mixTick then pcall(FRIENDLY.__mixTick, root, now) end
    if file == "empty" and FRIENDLY.__emptyTick then pcall(FRIENDLY.__emptyTick, now) end
    if (file == "clubbox_act_select" or file == "clubbox_tutorial_popup") and FRIENDLY.__clubTick then
        pcall(FRIENDLY.__clubTick, root, now)
    end
    if file == "battle_base" and FRIENDLY.__battleTick then pcall(FRIENDLY.__battleTick, root, now) end
    if file == "battle_campaign_results" and FRIENDLY.__resultsTick then pcall(FRIENDLY.__resultsTick, root, now) end
    if walletHook then pcall(walletHook, now) end
    if menuState.levelWatch then pcall(menuState.levelWatch, now) end
    local m = menus[file]
    if not m then
        local rn = "?"; pcall(function() rn = tostring(root:name()) end)
        m = { rootName = rn, t = -100 }
        menus[file] = m
        a11y_log("[menu] live: " .. file .. " (root " .. rn .. ")")
    end
    -- Learn this screen's tick interval: the longest recent gap, slowly
    -- forgotten. (Two copies of one screen can tick in the same frame: ignore
    -- tiny gaps.)
    local gap = now - m.t
    if gap > MENU_FRESH_SECONDS then
        m.gap = nil
    elseif gap > 0.002 then
        m.gap = math.max(gap, (m.gap or gap) * 0.9)
    end
    menuState.lastTick = now
    if now - m.t > MENU_FRESH_SECONDS then                -- (re)appeared
        m.countdown, m.appeared, m.opened, m.panel = menuState.announceFrames, now, now, nil
    end
    -- Some screens stay loaded once used and get reused: the confirmation
    -- popup keeps ticking with nothing in it, and a new "Would you like to
    -- bake...?" is added inside it. Others grow a panel (a buy box) inside a
    -- screen that is already open. Track what is showing: something new after
    -- the screen settled counts as a new screen of its own (announced, and Tab
    -- stays inside it until it goes away); nothing showing means closed.
    if not PERSISTENT_MENUS[file] then
        local shown, newest = {}, nil
        pcall(function()
            local kids = root:elements()
            for i = 0, kids:size() - 1 do
                local inner = kids[i]:elements()
                for j = 0, inner:size() - 1 do
                    local c = inner[j]
                    if isVisible(c) and elementName(c) ~= "A11yHook" then
                        local k = i .. "/" .. j .. "/" .. tostring(elementName(c))
                        shown[k] = c
                        if m.shown and not m.shown[k] then newest = k end
                    end
                end
            end
        end)
        local count = 0
        for _ in pairs(shown) do count = count + 1 end
        -- Only dialogs count (they carry a Yes/No/OK/Buy/Close button): a tab
        -- page or a scroll bar showing up must not trap Tab inside it.
        local function isDialog(k)
            for _, b in ipairs(DIALOG_BUTTONS) do
                if findNamed(shown[k], b, 4) then return true end
            end
            return false
        end
        if newest and now - (m.opened or now) > 1 and isDialog(newest) then
            m.countdown, m.appeared, m.panel = menuState.announceFrames, now, newest
            a11y_log("[menu] new panel in " .. file .. ": " .. newest)
        end
        if m.panel and not shown[m.panel] then m.panel = nil end
        m.panelEl = m.panel and shown[m.panel] or nil
        m.shown, m.content = shown, count
    end
    m.root, m.t = root, now
    if m.countdown then
        m.countdown = m.countdown - 1
        if m.countdown <= 0 then
            m.countdown = nil
            -- Announce popups opened from C++ (Lua pushPopUp already announced its own).
            -- getPopUp() can lag behind for C++-pushed screens (newsflash):
            -- getTopPopUpName() already names them.
            local top = currentPopupName()
            local top2 = ""; pcall(function() top2 = tostring(game.getTopPopUpName()) end)
            -- C++ confirmations report only "MenuReduxElement_Root" as the top
            -- popup, so a popup_* screen that just (re)appeared counts too.
            -- The game can keep naming the screen underneath (the Bakery) while
            -- its confirmation is up, so also accept the newest open screen.
            local newest = true
            for f, o in pairs(menus) do
                if f ~= file and not PERSISTENT_MENUS[f] and not f:find("^popup_tutorial") and not menuState.sidePanels[f]
                    and now - o.t <= MENU_FRESH_SECONDS and o.content ~= 0 and (o.appeared or 0) > (m.appeared or 0) then
                    newest = false
                end
            end
            -- Only real dialogs qualify (popup_* menus or a dialog panel), not
            -- helper screens like load_fade, empty or the store's category bar.
            local dialogLike = file:find("^popup_") or m.panel
            local isTop = top == file or top2 == file or (newest and m.content ~= 0 and dialogLike)
            if not selfAnnounced(file) and isTop
                and not (lastAnnounced.id == file and now - lastAnnounced.t < 2) then
                lastAnnounced.id, lastAnnounced.t = file, now
                pcall(announcePopup, file, m.panelEl or root)
            end
        end
    end
end


-- A Clubbox tutorial step waiting for you to do something on the screen
-- behind it ("Let's try it by spending 3"): its Continue button is hidden.
-- It isn't a screen to Tab through then; the one behind it is.
function menuState.waitingTutorial(file, m)
    if file ~= "clubbox_tutorial_popup" then return false end
    local btn = findNamed(m.root, "ContinueButton", 4)
    return btn ~= nil and not isVisible(btn)
end

-- The most recently opened screen still on screen, if any. Some screens opened
-- from C++ (bakery...) don't always show up as the top popup; without this,
-- Tab would fall back to the island and list the main menu behind them.
local function topOverlay()
    local now, best, bestFile = clock(), nil, nil
    -- Only screens opened after the island loaded: login menus that linger
    -- don't count.
    local since = 0
    for _, f in ipairs({ "hud", "hud_clubbox", "friend_hud" }) do
        local m = menus[f]
        if m and m.appeared and m.appeared > since and menuState.usable(m) then since = m.appeared end
    end
    if since == 0 then
        local m = menus.contextbar
        if m and m.appeared then since = m.appeared end
    end
    for file, m in pairs(menus) do
        -- showgrid_popup (the Show Grid toggle) can linger after placing or
        -- cancelling; it only belongs to placement, never a screen of its own.
        if not PERSISTENT_MENUS[file] and not file:find("^popup_tutorial") and not menuState.sidePanels[file]
            -- (A second of slack: after a quiet period the bar and this screen
            -- are both re-recorded, in either order.)
            and (m.appeared or 0) >= since - 1
            and m.content ~= 0
            and menuState.usable(m) and (not best or (m.appeared or 0) > (best.appeared or 0))
            and not menuState.waitingTutorial(file, m) then
            best, bestFile = m, file
        end
    end
    if best then
        if best.panelEl then return best.panelEl, bestFile .. ":" .. best.panel, bestFile end
        return best.root, bestFile, bestFile
    end
    return nil
end

-- Fresh root for a menu, by file name or by root element name.
local function liveMenu(name)
    local m = menus[name]
    if menuState.usable(m) then return m.root end
    for _, mm in pairs(menus) do
        if mm.rootName == name and menuState.usable(mm) then return mm.root end
    end
    return nil
end

-- A popup the game put inside the "empty" screen (C++ offers like "top up
-- your Clubbox Tickets"): getPopUp() doesn't name it, getTopPopUpName() does.
function FRIENDLY.__emptyPopup()
    local t2 = ""; pcall(function() t2 = tostring(game.getTopPopUpName()) end)
    if t2 == "" or t2 == "nil" or t2 == "MenuReduxElement_Root" then return nil end
    -- Screens with their own menu (Hype game, Clubbox tutorial) are handled
    -- the usual way; a lingering one can still be named here with nothing on it.
    if menuState.usable(menus[t2]) then return nil end
    local e = liveMenu("empty")
    local own = e and findNamed(e, t2, 3)
    if own and isVisible(own) then return { el = own, name = t2 } end
    return nil
end
FRIENDLY.__emptyState = { at = -100 }
function FRIENDLY.__emptyTick(now)
    local E = FRIENDLY.__emptyState
    if now - E.at < 0.25 then return end
    E.at = now
    -- Never while the Market is up (see the quiet period).
    if now - FRIENDLY.__storeSeenAt < 2 then return end
    if not (liveMenu("hud") or liveMenu("hud_clubbox")) then return end
    local p = FRIENDLY.__emptyPopup()
    local name = p and p.name or nil
    -- A popup counts as closed only after a full second without it: screens
    -- like the Hype game drop out for a moment and must not be re-announced.
    if name == E.name then E.goneAt = nil return end
    if not name then
        E.goneAt = E.goneAt or now
        if now - E.goneAt >= 1 then E.name, E.goneAt = nil, nil end
        return
    end
    E.name, E.goneAt = name, nil
    -- Screens with their own menu (the Hype game, Clubbox tutorial) are
    -- announced the usual way; this is only for ones that have none.
    if menuState.usable(menus[name]) then return end
    if p and not (lastAnnounced.id == name and now - lastAnnounced.t < 3) then
        later(0.3, function()
            -- Announced meanwhile by its own screen, or it has one now.
            if lastAnnounced.id == name and clock() - lastAnnounced.t < 3 then return end
            if menuState.usable(menus[name]) then return end
            lastAnnounced.id, lastAnnounced.t = name, clock()
            pcall(announcePopup, name, p.el)
        end)
    end
end

-- Encore event info: name, theme, how points are earned ("15m = 1"), and the
-- progress shown on the HUD's Encore button.
-- Monster name entry (PopupMonsterNameEntry.lua): typed keys go straight to
-- the game. Say what it's for and how it works, then echo what is typed.
function menuState.nameEntryText(root)
    local t = nil
    pcall(function() t = root.TextEntry.Text("text"):GetString() end)
    if not t then
        local e = findNamed(root, "TextEntry", 4)
        pcall(function() t = e.Text("text"):GetString() end)
    end
    return t or ""
end
POPUP_READERS.popup_name_entry = function(popup)
    local title = elementText(findNamed(popup, "TitleLabel", 4)) or "Name your monster"
    local desc = elementText(findNamed(popup, "Description", 4))
    local cur = menuState.nameEntryText(popup)
    menuState.nameText = cur
    return joinSentences({ title, desc,
        cur ~= "" and ("The name is now " .. cur) or "The name is empty",
        "Type a new name. Backspace deletes the last letter, Enter saves, Escape cancels" })
end
POPUP_READERS.popup_text_entry = function(popup)
    local desc = elementText(findNamed(popup, "Description", 4))
    local cur = menuState.nameEntryText(popup)
    menuState.nameText = cur
    local friend = desc and desc:lower():find("friend", 1, true)
    return joinSentences({ desc or elementText(findNamed(popup, "TitleLabel", 4)) or "Enter text",
        cur ~= "" and ("It says " .. cur) or "It's empty",
        friend and "Type or paste the code with Control V, then Tab to Send friend request"
            or "Type the text, then Tab to OK. Escape cancels" })
end
function menuState.nameEcho(root)
    local cur = menuState.nameEntryText(root)
    local old = menuState.nameText
    if old == nil then menuState.nameText = cur return end
    if cur == old then return end
    menuState.nameText = cur
    if #cur > #old and cur:sub(1, #old) == old then
        local added = cur:sub(#old + 1)
        say(added == " " and "space" or added, true)
    elseif #cur < #old and old:sub(1, #cur) == cur then
        local gone = old:sub(#cur + 1)
        say("deleted " .. (gone == " " and "space" or gone) .. (cur == "" and ", empty" or ""), true)
    else
        say(cur ~= "" and cur or "empty", true)
    end
end

-- Scratch ticket (minigame_doorprize, template_scratchentry): six squares
-- under a scratch-off coating that the game's native ScratchBox wipes as a
-- finger rubs over it. No Lua call reveals a square, so the mod rubs each one
-- with engine touch drags (a11y_touch press, moves, release): the handler
-- turns moves into drags while a press is down. A revealed square's sprite
-- moves to the FrontPopUps layer (its "reveal" event). Lives on FRIENDLY so
-- collectControls, which is above menuState, can reach it.
do
local S = {}
FRIENDLY.__scratch = S
local SPRITE_WORDS = { { "diamond", "diamonds" }, { "coin", "coins" }, { "food", "food" }, { "treat", "treats" },
    { "relic", "relics" }, { "key", "keys" }, { "shard", "shards" }, { "xp", "XP" }, { "starpower", "starpower" },
    { "egg", "egg" } }

function S.entry(i)
    local root = liveMenu("minigame_doorprize")
    local box = root and findNamed(root, "ScratchBox", 4)
    return box and findNamed(box, "scratchEntry" .. i, 1)
end

function S.revealed(e)
    local layer = nil
    pcall(function() layer = e:GetElement("iSprite"):GetComponent("Sprite")("layer"):GetString() end)
    return layer == "FrontPopUps"
end

-- What a square holds, from the game's own scratch data (only asked once
-- the square is uncovered).
function S.prize(i)
    local str, sprite = nil, nil
    pcall(function() str = tostring(game.scratchEntryString(i)) end)
    pcall(function() sprite = tostring(game.scratchEntrySprite(i)) end)
    a11y_log("[scratch] square " .. i .. " string=" .. tostring(str) .. " sprite=" .. tostring(sprite))
    local kind = nil
    local low = (sprite or ""):lower()
    for _, w in ipairs(SPRITE_WORDS) do
        if low:find(w[1], 1, true) then kind = w[2] break end
    end
    -- Monster tickets: the string is a monster id and the picture its egg
    -- ("gfx/spore_BDE"), not an amount.
    if str and str:find("^%d+$") and low:find("spore", 1, true) then
        local name = nil
        pcall(function() name = cleanText(LOC(game.getMonsterData(tonumber(str)):name())) end)
        if name then return FRIENDLY.__withRarity(name, tonumber(str)) .. " egg" end
    end
    if str and str:find("^%d+$") then
        local n = str
        pcall(function() n = game.commaizeNumber(str) end)
        return n .. (kind and (" " .. kind) or "")
    end
    local name = str and str ~= "" and cleanText(localize(str) or str)
    if name and name ~= "" then return name end
    if kind then return kind end
    return (sprite or "a prize"):gsub("[_%-]", " ")
end

function S.label(i)
    local e = S.entry(i)
    if not e then return nil end
    if S.revealed(e) then
        local won = false
        pcall(function() won = game.isWinningZone(i) and true or false end)
        return "Square " .. (i + 1) .. ": " .. S.prize(i) .. (won and ", match" or "")
    end
    return "Square " .. (i + 1) .. ", covered"
end

-- Rub square i: zig-zag strokes inside it, one stroke per frame. pass 2 rubs
-- up and down instead, for a second try. done(revealed) runs afterwards.
function S.rub(i, pass, done)
    local touch = resolve("a11y_touch")
    local e = S.entry(i)
    if not e or type(touch) ~= "function" then if done then done(false) end return end
    local sw, sh, x, y, w, h = 0, 0, 0, 0, 0, 0
    pcall(function()
        sw, sh = lua_sys.screenWidth(), lua_sys.screenHeight()
        x, y, w, h = e:absX(), e:absY(), e:absW(), e:absH()
    end)
    if sw <= 0 or sh <= 0 or w <= 0 or h <= 0 then if done then done(false) end return end
    a11y_log("[scratch] rub " .. i .. " pass " .. pass .. " at " .. math.floor(x) .. "," .. math.floor(y)
        .. " size " .. math.floor(w) .. "x" .. math.floor(h) .. " of " .. math.floor(sw) .. "x" .. math.floor(sh))
    local strokes = {}
    local ROWS, STEPS = 7, 8
    for r = 0, ROWS - 1 do
        local pts = {}
        for s = 0, STEPS do
            local a = 0.08 + 0.84 * (r / (ROWS - 1))
            local b = 0.08 + 0.84 * (s / STEPS)
            if r % 2 == 1 then b = 1 - b end
            if pass == 2 then a, b = b, a end
            pts[#pts + 1] = { (x + w * b) / sw, (y + h * a) / sh }
        end
        strokes[#strokes + 1] = pts
    end
    local first = strokes[1][1]
    pcall(touch, first[1], first[2], 2)
    pcall(touch, first[1], first[2], 1)
    local k = 0
    local function step()
        k = k + 1
        local pts = strokes[k]
        if not pts then
            local last = strokes[#strokes]; last = last[#last]
            pcall(touch, last[1], last[2], 0)
            later(0.4, function()
                local now = S.entry(i)
                if done then done(now ~= nil and S.revealed(now)) end
            end)
            return
        end
        for _, p in ipairs(pts) do pcall(touch, p[1], p[2], 2) end
        later(0.02, step)
    end
    later(0.02, step)
end

-- Scratch the given squares in turn (two passes each at most), then say what
-- they hold. S.busy keeps a second Enter from starting another run.
function S.scratch(list)
    if S.busy then say("Still scratching", true) return end
    -- Called right after menuState.touch(), which hides every menu until it
    -- ticks again: start on the next frame.
    S.busy = true
    later(0.05, function() S.busy = false S.start(list) end)
end

function S.start(list)
    if not liveMenu("minigame_doorprize") then
        a11y_log("[scratch] ticket not live")
        say("The scratch ticket isn't ready yet, try again", true)
        return
    end
    local touch = resolve("a11y_touch")
    if type(touch) ~= "function" then
        say("Scratching needs the mod's touch support, which couldn't start in this version of the game", true)
        return
    end
    S.busy = true
    say(#list == 1 and ("Scratching square " .. (list[1] + 1)) or "Scratching", true)
    local found, idx = {}, 0
    local function nextSquare()
        idx = idx + 1
        local i = list[idx]
        if i == nil then
            S.busy = false
            S.report(found, #list == 1)
            return
        end
        local e = S.entry(i)
        if not e then S.busy = false return end      -- the ticket closed
        if S.revealed(e) then found[#found + 1] = i nextSquare() return end
        S.rub(i, 1, function(ok)
            if ok then found[#found + 1] = i nextSquare() return end
            S.rub(i, 2, function(ok2)
                if ok2 then found[#found + 1] = i else a11y_log("[scratch] square " .. i .. " did not reveal") end
                nextSquare()
            end)
        end)
    end
    nextSquare()
end

function S.report(found, single)
    local parts = {}
    for _, i in ipairs(found) do
        local l = S.label(i)
        if l then parts[#parts + 1] = l end
    end
    local left = 0
    for i = 0, 5 do
        local e = S.entry(i)
        if e and not S.revealed(e) then left = left + 1 end
    end
    if #parts == 0 then
        say("The square did not uncover. The game may not have taken the scratch; try again, or tell the mod's author.", true)
        return
    end
    if left > 0 then
        parts[#parts + 1] = left .. (left == 1 and " square" or " squares") .. " still covered"
        say(joinSentences(parts), true)
        return
    end
    -- All six: the game greys out the losers, then shows Collect (1 second).
    say(joinSentences(parts), true)
    later(1.3, function()
        local won = {}
        for i = 0, 5 do
            local w = false
            pcall(function() w = game.isWinningZone(i) end)
            if w then won[#won + 1] = S.prize(i) end
        end
        local msg = #won > 0 and ("You matched three: " .. won[1] .. ".") or "All squares uncovered."
        say(msg .. " Tab to Collect.", false)
    end)
end
end -- do (scratch ticket)

-- Colossal Conundrum (daily_cumulative_login, DCL.lua): a puzzle with one
-- piece per day. Pieces not collected yet show their day number
-- (piece_NN_number / piece_special_NN_number / piece_final_NN_number under
-- Layout); collected ones lose it. So the lowest number left is the next
-- day to collect.
function FRIENDLY.__conundrum(root)
    local layout = findNamed(root, "Layout", 4)
    if not layout then return nil end
    local lo, hi, left, special, final = nil, 0, 0, {}, nil
    local kids = nil; pcall(function() kids = layout:elements() end)
    local n = 0; pcall(function() n = kids:size() end)
    for i = 0, n - 1 do
        local c = nil; pcall(function() c = kids[i] end)
        local nm = c and elementName(c) or ""
        local day = c and isVisible(c) and tonumber(elementText(findNamed(c, "Number", 1)) or "")
        if day then
            left = left + 1
            if not lo or day < lo then lo = day end
            if day > hi then hi = day end
            if nm:find("^piece_special") then special[#special + 1] = day end
            if nm:find("^piece_final") then final = day end
        end
    end
    local parts = {}
    if left == 0 then
        parts[1] = "All pieces collected"
    else
        parts[1] = (lo - 1) .. " of " .. hi .. " pieces collected"
        if #special > 0 then
            table.sort(special)
            parts[#parts + 1] = "Special pieces on day" .. (#special == 1 and " " or "s ") .. table.concat(special, ", ")
        end
        if final then parts[#parts + 1] = "The final piece is day " .. final end
    end
    local nextMsg = shownText(root, "NextCollectMessage")
    if nextMsg then parts[#parts + 1] = nextMsg end
    local done = shownText(root, "CompletedMessage")
    if done then parts[#parts + 1] = done end
    local details = shownText(root, "CompletedMessageDetails")
    if details then parts[#parts + 1] = details end
    return joinSentences(parts)
end

POPUP_READERS.daily_cumulative_login = function(popup)
    return joinSentences({ "Colossal Conundrum", FRIENDLY.__conundrum(popup) })
end

-- object_info is shared by monsters and buildings; buildings hide the
-- Bio/Likes/Stats tabs and have no Likes.
function FRIENDLY.__infoIsMonster()
    local m = false
    pcall(function() m = game.selectedObjIsMonster() and true or false end)
    return m
end
-- Which tab of a monster's INFO page is open: its own tab button is the one
-- that can't be pressed (BioButton / LikesButton / StatsButton).
function FRIENDLY.__infoTab(root)
    for _, t in ipairs({ { "BioButton", "bio" }, { "LikesButton", "likes" }, { "StatsButton", "stats" } }) do
        local b = findNamed(root, t[1], 1)
        if b and not isClickable(b) then return t[2] end
    end
    return nil
end
-- The Stats tab's rows as "Label: value" (template_stat_*.xml: a Stat text
-- component, and a Value text component or a Value child element).
function FRIENDLY.__statRows(list)
    local rows = {}
    local kids = nil; pcall(function() kids = list:elements() end)
    local n = 0; pcall(function() n = kids:size() end)
    for i = 0, n - 1 do
        local row = nil; pcall(function() row = kids[i] end)
        if row and isVisible(row) then
            local label, value = nil, nil
            pcall(function()
                if row["Stat"]("visible"):GetInt() ~= 0 then label = cleanText(row["Stat"]("text"):GetString()) end
            end)
            pcall(function()
                if row["Value"]("visible"):GetInt() ~= 0 then value = cleanText(row["Value"]("text"):GetString()) end
            end)
            if not value then value = elementText(findNamed(row, "Value", 1)) end
            if label and value then
                label = label:gsub("[:%s]+$", "")
                rows[#rows + 1] = label .. ": " .. value
            elseif label or value then
                rows[#rows + 1] = label or value
            end
        end
    end
    return rows
end
-- A building's INFO page: name, description, time left (torches: lit status).
POPUP_READERS.object_info = function(popup)
    if FRIENDLY.__infoIsMonster() then return nil end
    local parts = {}
    local title = shownText(popup, "ImageTitle")
    if title then parts[#parts + 1] = title end
    local torch = FRIENDLY.__torchStatus and FRIENDLY.__torchStatus()
    if torch then parts[#parts + 1] = torch end
    local left = shownText(popup, "TimeRemainingText")
    if left and not torch then parts[#parts + 1] = left end
    local desc = shownText(popup, "InfoContent")
    if desc then parts[#parts + 1] = desc end
    if #parts == 0 then return nil end
    return joinSentences(parts)
end

-- TRAIN confirmation (battle_training_popup.xml): the numbers are text
-- components on the elements (TextA -> TextB, AbilityNameLabel, TimeLabel, CostLabel).
POPUP_READERS.battle_training_popup = function(popup)
    local function ctext(elName, c)
        local t = nil
        pcall(function()
            local e = findNamed(popup, elName, 2)
            if e[c]("visible"):GetInt() ~= 0 then t = cleanText(e[c]("text"):GetString()) end
        end)
        return (t and t ~= "") and t or nil
    end
    local parts = { "Training" }
    local desc = shownText(popup, "DESCRIPTION")
    if desc then parts[#parts + 1] = desc end
    local a, b = ctext("POWER_INCREASE", "TextA"), ctext("POWER_INCREASE", "TextB")
    if a and b then parts[#parts + 1] = "Power " .. a .. " to " .. b end
    a, b = ctext("STAMINA_INCREASE", "TextA"), ctext("STAMINA_INCREASE", "TextB")
    if a and b then parts[#parts + 1] = "Stamina " .. a .. " to " .. b end
    local move = ctext("ABILITY_UNLOCK", "AbilityNameLabel")
    if move then parts[#parts + 1] = "New move: " .. move end
    local time = ctext("TRAINING_TIME", "TimeLabel")
    if time then parts[#parts + 1] = "Training will take " .. time end
    local cost = ctext("TRAINING_COST", "CostLabel")
    if cost then parts[#parts + 1] = "Costs " .. cost .. " Coins" end
    return joinSentences(parts)
end

-- OCCUPANTS (hotel_list, e.g. the Colossingum's Mess Hall): who is staying
-- and how many beds are used (template_hotelbedsavailable: hotelBedsUsed/max).
POPUP_READERS.hotel_list = function(popup)
    local parts = { shownText(popup, "HotelTitle") or "Occupants" }
    local used, max = nil, nil
    pcall(function() used = tonumber(game.hotelBedsUsed()); max = tonumber(game.maxHotelBeds()) end)
    if used and max then parts[#parts + 1] = used .. " of " .. max .. " beds occupied" end
    local n = 0
    pcall(function() n = game.getMonstersInHotel():size() end)
    if n == 0 then parts[#parts + 1] = "No monsters are staying here" end
    return joinSentences(parts)
end

-- What a monster likes (object_info.xml InfoLikes: game.getLikes(typeId) is
-- a list of entity ids; the game shows the last one as a mystery "?").
function FRIENDLY.__entityName(eid)
    local n = nil
    pcall(function() n = cleanText(LOC(game.entityName(eid))) end)
    if not n or n == "" then
        pcall(function() n = cleanText(LOC(game.getMonsterByEntityId(eid):name())) end)
    end
    return (n and n ~= "") and n or nil
end
function FRIENDLY.__likes(typeId)
    local likes = game.getLikes(typeId)
    local n = likes:size()
    if n == 0 then return "Likes: nothing" end
    local names = {}
    for i = 0, n - 2 do
        names[#names + 1] = FRIENDLY.__entityName(likes[i]) or "something"
    end
    if not POPUP_READERS.__likesLogged then
        POPUP_READERS.__likesLogged = true
        a11y_log("[likes] type " .. tostring(typeId) .. ": " .. n .. " entries, " .. table.concat(names, ", "))
    end
    if #names == 0 then return "Likes: a mystery like" end
    return "Likes: " .. table.concat(names, ", ") .. ", and a mystery like"
end

-- Likes near the spot being placed on (spotText). A monster being placed:
-- which of its Likes are close. A decoration: which monsters close by like
-- it. The game's hidden "mystery" like is left out.
FRIENDLY.__likeCache = {}
FRIENDLY.LIKE_RADIUS = 5
function FRIENDLY.__likeNames(typeId)
    local c = FRIENDLY.__likeCache[typeId]
    if c then return c end
    c = {}
    pcall(function()
        local likes = game.getLikes(typeId)
        for i = 0, likes:size() - 2 do
            local n = FRIENDLY.__entityName(likes[i])
            if n then
                c[#c + 1] = n:lower()
                FRIENDLY.__likeDisplay = FRIENDLY.__likeDisplay or {}
                FRIENDLY.__likeDisplay[n:lower()] = n
            end
        end
    end)
    FRIENDLY.__likeCache[typeId] = c
    return c
end
function FRIENDLY.__isLike(likeNames, l)
    local mine = (l.species or l.name or ""):lower():gsub("%s+%d+$", "")
    for _, n in ipairs(likeNames) do
        if mine == n then return true end
    end
    return false
end
function FRIENDLY.__likesNear(w)
    if not (w and w.x and w.list) then return nil end
    local function dist(l) return math.max(math.abs(l.x - w.x), math.abs(l.y - w.y)) end
    local function away(d) return d <= 1 and "next to it" or (d .. " tiles away") end
    local isMonster = false
    pcall(function() isMonster = game.selectedObjIsMonster() and true or false end)
    local found = {}
    if isMonster then
        local tid = nil
        pcall(function() tid = game.GetMonster(game.selectedMonsterId()):monsterTypeId() end)
        if not tid then pcall(function() tid = game.selectedMonsterTypeId() end) end
        if not tid then return nil end
        local names = FRIENDLY.__likeNames(tid)
        if #names == 0 then return nil end
        for _, l in ipairs(w.list) do
            local d = dist(l)
            if d <= FRIENDLY.LIKE_RADIUS and FRIENDLY.__isLike(names, l) then
                found[#found + 1] = { d = d, text = (l.species and l.name or l.name) .. ", " .. away(d) }
            end
        end
        table.sort(found, function(a, b) return a.d < b.d end)
        local parts = {}
        for i = 1, math.min(#found, 3) do parts[i] = found[i].text end
        return #parts > 0 and ("Likes nearby: " .. table.concat(parts, "; ")) or nil
    end
    local me = nil
    pcall(function() me = cleanText(game.objectName()) end)
    if not me or me == "" then return nil end
    local probe = { name = me }
    for _, l in ipairs(w.list) do
        local d = dist(l)
        if l.tid and d <= FRIENDLY.LIKE_RADIUS and FRIENDLY.__isLike(FRIENDLY.__likeNames(l.tid), probe) then
            found[#found + 1] = { d = d, text = l.name .. ", " .. away(d) }
        end
    end
    table.sort(found, function(a, b) return a.d < b.d end)
    local parts = {}
    for i = 1, math.min(#found, 3) do parts[i] = found[i].text end
    return #parts > 0 and ("Liked by " .. table.concat(parts, "; ")) or nil
end

-- Market prices (template_storeitem.xml): AnyCost is the number, its Sprite
-- the currency icon (StoreItem.lua picks it by currency type). Sale items
-- show saleTag's SaleAmount / OriginalAmount with their own CurrencySprite.
FRIENDLY.__currencyWords = {
    { "diamond", "Diamonds" }, { "coin", "Coins" }, { "relic", "Relics" }, { "shard", "Shards" },
    { "eth", "Shards" }, { "starpower", "Starpower" }, { "medal", "Medals" }, { "wildcard", "Egg Wildcards" },
    { "key", "Keys" }, { "food", "Food" }, { "treat", "Food" }, { "star", "Starpower" },
}
FRIENDLY.__currencySeen = {}
function FRIENDLY.__currencyOf(el)
    if not el then return nil end
    local s = nil
    pcall(function() s = el:C("Sprite")("spriteName"):GetString() end)
    if not s or s == "" then return nil end
    if not FRIENDLY.__currencySeen[s] then
        FRIENDLY.__currencySeen[s] = true
        a11y_log("[store] currency sprite " .. s)
    end
    local low = s:lower()
    for _, w in ipairs(FRIENDLY.__currencyWords) do
        if low:find(w[1], 1, true) then return w[2] end
    end
    return nil
end
function FRIENDLY.__storePrice(item, lbl)
    -- Put the currency after the number, matching the whole number only
    -- ("100" must not hit the end of "1,100").
    local function addWord(amountEl, iconEl, before)
        local amt = amountEl and isVisible(amountEl) and elementText(amountEl)
        local cur = FRIENDLY.__currencyOf(iconEl)
        if not amt or not cur then return end
        local from = 1
        while true do
            local i, j = lbl:find(amt, from, true)
            if not i then return end
            local pc, nc = lbl:sub(i - 1, i - 1), lbl:sub(j + 1, j + 1)
            if not pc:find("[%w,]") and not nc:find("[%w]") and not (nc == "," and lbl:sub(j + 2, j + 2):find("%d")) then
                lbl = lbl:sub(1, i - 1) .. (before or "") .. amt .. " " .. cur .. lbl:sub(j + 1)
                return
            end
            from = j + 1
        end
    end
    local sale = findNamed(item, "saleTag", 1)
    if sale and isVisible(sale) then
        addWord(findNamed(sale, "SaleAmount", 1), findNamed(sale, "CurrencySprite", 1), "on sale, ")
        addWord(findNamed(sale, "OriginalAmount", 1), findNamed(sale, "OriginalCurrencySprite", 1), "was ")
    end
    local any = findNamed(item, "AnyCost", 1)
    addWord(any, any)
    return lbl
end

-- What a monster looks like (Control+Shift+I with a monster selected).
-- Written from the game's own portraits (gfx/breeding/monster_portrait_
-- square_<code>), keyed by the portrait code game.getPortraitName gives for
-- the monster type. The natural monsters' codes are their elements: a Air,
-- b Plant, c Earth, d Water, e Cold. Rare and Epic portraits share the
-- common one's description.
FRIENDLY.__looks = {
    a = "A purple bird with big yellow eyes, an orange beak, a tuft of orange feathers on its head and wide purple wings.",
    ab = "A huge round puff of white fluffy fur, with a yellow duck-like bill and big blue-rimmed eyes peeking out.",
    abc = "A lime-green furry creature with a sleepy grin and four wooden pipes, like recorders, sticking up from its back.",
    abcd = "A purple octopus-like creature with a frilly fin by each ear, holding drumsticks.",
    abcde = "A bird with a pale, skull-like head, one big green eye, a hooked grey beak and a crest of bright green, blue and yellow feathers.",
    abce = "A cluster of grey stone heads stacked like a little rock tower, each with a round hole for a mouth and patches of green moss.",
    abd = "A round lime-green blob with small eyes on top of its head and a round O-shaped mouth, as if singing one long note.",
    abde = "A tall light-blue creature with a big black speaker set into its forehead, purple headphones and a worried, wide mouth.",
    abe = "Two round fuzzy balls, one pink and one brown, each with big yellow eyes and a toothy grin.",
    ac = "A round tan creature with one big green eye, a riveted metal rim around its wide toothy mouth and a small antenna on top.",
    acd = "A fuzzy blue creature with big orange-rimmed eyes, two short yellow horns and purple and blue striped legs.",
    acde = "An orange furry creature with a mop of red hair and a small round mouth, playing a green electric guitar.",
    ace = "A tall pink creature with a bow on its head, big eyes and an open, smiling purple mouth, holding a bright pink fluffy pom-pom.",
    ad = "Two tall blue-green birds side by side, each with a long pale beak and a purple crest.",
    ade = "An orange creature with two tall eye stalks, a wide smile and little bumps all over its skin.",
    ae = "A dark purple, penguin-like bird with a red scarf and an orange and grey beak with icicles dripping from it.",
    b = "A green, bulb-shaped plant creature with lighter green spots, a huge open mouth full of teeth and leafy vines around it.",
    bc = "A creature made of wood, with a round green leafy head, big eyes, a little yellow flower and long branch-like arms.",
    bcd = "A pale blue creature with yellow eyes on top, a huge pink-rimmed mouth with a swirly tongue, waving one hand.",
    bcde = "A yellow-green creature in a coat of leaves, with a huge open mouth and a big curled wooden horn on its head.",
    bce = "A green creature hiding under a golden cymbal like a hat, with only its eyes peeking out and a curly green stalk on top.",
    bd = "A tree-trunk creature with a carved wooden face, big orange eyes and a bushy green treetop for hair.",
    bde = "A pale blue furry creature playing a big wooden stringed instrument with a bow, like a cello.",
    be = "A bright green furry creature with big mismatched eyes, a sharp-toothed mouth and a little stalk on its head.",
    c = "A grey stone block with green eyes and two pale hands resting on top of its head.",
    cd = "A teal, frog-like creature with three yellow eyes, big pink lips and pink crystals growing on its head.",
    cde = "A grey, stony creature like a rhino, with small horns, a pale blue eye and a golden mouthpiece.",
    ce = "An orange-red furry creature with a tuft of red hair, a pale yellow belly, big eyes and drumsticks in its hands.",
    d = "A light-blue, round blob with big green eyes on top and a wide, pink-lipped mouth.",
    de = "A huge open mouth with a pink tongue and crooked teeth, ringed by purple lips, with pink and orange spines on top.",
    e = "A white, furry, yeti-like creature with big yellow eyes and a huge grin full of square teeth.",
    f = "A dark creature that is mostly a huge grin of square yellow teeth, with two glowing red eyes peeking over it.",
    g = "A ghostly, see-through purple creature with golden eyes and a wide, fanged smile.",
}
-- Monsters whose element letters don't tell them apart (every Dipster's
-- genes are "Q"), by name. Dipster portraits q01-q07 run Do to Ti.
FRIENDLY.__looksByName = {
    Do = "A small blue creature with a big white onion bulb on its head, round eyes and a wide, toothy smile.",
    Re = "A small orange creature like a carrot, with a tuft of green leaves on top and a wide, toothy grin.",
    Mi = "A small green creature wearing a big pale spiral snail shell on its head, with round eyes and a toothy grin.",
    Fa = "A small dark grey-blue creature topped with a spiky brown plant like an artichoke, with a wide, toothy grin.",
    Sol = "A small yellow, spongy creature with tall green grass and orange sprouts growing from its head and a big open smile.",
    La = "A small white creature under a big green mushroom cap with white spots, with a toothy grin.",
    Ti = "A small pink, fuzzy creature with a clump of soil and an orange flower on its head and big shiny black eyes.",
}
FRIENDLY.__elementLetters = { a = "Air", b = "Plant", c = "Earth", d = "Water", e = "Cold" }
-- A monster type's Natural elements as words ("Earth and Water"), and how
-- many, from game.monsterTypeGenes. nil for other elements (Ethereal etc.).
function FRIENDLY.__elementsOf(tid)
    local genes = nil
    pcall(function() genes = tostring(game.monsterTypeGenes(tid)) end)
    local base = genes and genes:lower():gsub("[^%a]", "")
    if not base or not base:find("^[a-e]+$") then return nil end
    local letters = {}
    for ch in base:gmatch(".") do letters[#letters + 1] = ch end
    table.sort(letters)
    local els = {}
    for _, ch in ipairs(letters) do els[#els + 1] = FRIENDLY.__elementLetters[ch] end
    if #els == 1 then return els[1], 1 end
    return table.concat(els, ", ", 1, #els - 1) .. " and " .. els[#els], #els
end

-- A breeding row's monster type (BreedingMonsterListEntry keeps .monster).
function FRIENDLY.__entryTid(entry)
    local tid = nil
    pcall(function()
        local m = entry.monster
        if type(m) == "userdata" then tid = m:monsterTypeId()
        elseif type(m) == "table" then tid = m.monsterTypeId or m.monsterId or m.MonsterId end
        if type(tid) == "function" then tid = tid(entry.monster) end
    end)
    return tonumber(tid)
end
-- The picked monster's type in one breeding side (LeftMonsterSelect/RightMonsterSelect).
function FRIENDLY.__pickTid(side)
    local list = side and findNamed(side, "List", 1)
    local kids = nil; pcall(function() kids = list:elements() end)
    local n = 0; pcall(function() n = kids:size() end)
    for i = 0, n - 1 do
        local c = nil; pcall(function() c = kids[i] end)
        local picked = false
        pcall(function() picked = tostring(findNamed(c, "Bg", 1):C("Sprite")("spriteName"):GetString()):find("yellow") ~= nil end)
        if c and isVisible(c) and picked then return FRIENDLY.__entryTid(c) end
    end
    return nil
end
-- Sorted Natural element letters of a type ("cd"), or nil.
function FRIENDLY.__geneKey(tid)
    local genes = nil
    pcall(function() genes = tostring(game.monsterTypeGenes(tid)) end)
    local base = genes and genes:lower():gsub("[^%a]", "")
    if not base or not base:find("^[a-e]+$") then return nil end
    local letters = {}
    for ch in base:gmatch(".") do letters[#letters + 1] = ch end
    table.sort(letters)
    return table.concat(letters)
end
-- The common monster with exactly these Natural elements ("cd" -> Fwog).
function FRIENDLY.__nameByGenes(key)
    local map = FRIENDLY.__geneNames
    if not map then
        map = {}
        local misses, count = 0, 0
        for id = 1, 3000 do
            local n = nil
            pcall(function() n = cleanText(LOC(game.getMonsterData(id):name())) end)
            if n and n ~= "" then
                misses = 0
                local special = false
                pcall(function() special = game.isRare(id) or game.isEpic(id) or game.isSeasonal(id) end)
                local k = not special and FRIENDLY.__geneKey(id)
                if k and map[k] == nil then map[k] = n; count = count + 1
                elseif k and map[k] ~= n then a11y_log("[genes] " .. k .. " also " .. n .. " (kept " .. tostring(map[k]) .. ")") end
            else
                misses = misses + 1
                if misses > 300 then break end
            end
        end
        a11y_log("[genes] " .. count .. " element sets named")
        FRIENDLY.__geneNames = map
    end
    return map[key]
end
-- What two Natural monsters can make, by the game's own Breeding Guide rules:
-- different elements combine; a repeated element gives one of the parents.
function FRIENDLY.__pairHint(t1, t2)
    local k1, k2 = t1 and FRIENDLY.__geneKey(t1), t2 and FRIENDLY.__geneKey(t2)
    if not k1 or not k2 then return nil end
    local shared, all = {}, {}
    for ch in k1:gmatch(".") do all[ch] = true end
    for ch in k2:gmatch(".") do
        if all[ch] then shared[#shared + 1] = FRIENDLY.__elementLetters[ch] end
        all[ch] = true
    end
    if #shared > 0 then
        return "both " .. table.concat(shared, " and ") .. ", usually gives one of the parents"
    end
    local letters = {}
    for ch in pairs(all) do letters[#letters + 1] = ch end
    table.sort(letters)
    local key = table.concat(letters)
    local els = {}
    for _, ch in ipairs(letters) do els[#els + 1] = FRIENDLY.__elementLetters[ch] end
    local list = table.concat(els, ", ", 1, #els - 1) .. " and " .. els[#els]
    local name = FRIENDLY.__nameByGenes(key)
    return "can make " .. (name and (name .. ", " .. list) or list)
end
-- Wishing Torch context bar buttons (ContextBar.lua light_torch etc.; costs
-- from template_torch_*cost.xml: Diamonds for lighting, torchCurrency to buy).
function FRIENDLY.__torchLabel(el)
    local fn = nil; pcall(function() fn = el("FunctionName"):GetString() end)
    local text = elementText(el) or ""
    local cost = nil
    pcall(function() cost = elementText(findNamed(el, "attachedTemplate", 2)) end)
    cost = cost and cost:gsub("^%-", "")
    if fn == "light_torch" then
        return "Light for a day" .. (cost and (", " .. cost .. " Diamonds") or "")
    elseif fn == "permalight_torch" then
        return "Light permanently" .. (cost and (", " .. cost .. " Diamonds") or "")
    elseif fn == "buy_another_torch" then
        local cur = nil
        pcall(function() cur = currencyCounterName("currency_counter_" .. tostring(game.torchCurrency())) end)
        a11y_log("[torch] torchCurrency " .. tostring(cur))
        if not cur or cur == "Currency" then cur = "Coins" end
        return "Buy another torch" .. (cost and (", " .. cost .. " " .. cur) or "")
    elseif text:upper() == "UNHIGHLIGHTED" then
        return "Highlight for friends: off. Press to show friends this torch needs lighting"
    elseif text:upper() == "HIGHLIGHTED" then
        return "Highlight for friends: on. Press to turn it off"
    end
    return nil
end
-- Colossingum battles (battle_base): health from the battle system (as
-- template_battle_healthbar.xml does: getActiveBattlePlayer(0 = you, 1 =
-- opponent)), the Status line (the move being played) and whose turn it is.
FRIENDLY.__battle = { at = 0 }
function FRIENDLY.__battleHealth()
    local out = {}
    for team = 0, 1 do
        pcall(function()
            local p = game.battleSystem():getActiveBattlePlayer(team)
            out[#out + 1] = cleanText(p:name()) .. " " .. p:health() .. " of " .. p:totalHealth() .. " health"
        end)
    end
    if #out == 0 then return nil end
    return table.concat(out, ", ")
end
function FRIENDLY.__battleTick(root, now)
    local B = FRIENDLY.__battle
    if now - B.at > 2 then B.status, B.hp, B.turn, B.hpAt = nil, nil, nil, nil end
    B.at = now
    local st = shownText(root, "Status")
    if st and st ~= B.status then say(st, false) end
    B.status = st
    -- Health: speak once it has settled (the bars tween for about a second).
    local hp = FRIENDLY.__battleHealth()
    if hp ~= B.hpSeen then B.hpSeen = hp; B.hpAt = now end
    if hp and hp ~= B.hp and B.hpAt and now - B.hpAt > 0.8 then
        if B.hp then say(hp, false) end
        B.hp = hp
    end
    -- Your turn: a move button becomes usable.
    local turn = false
    pcall(function()
        local bar = findNamed(root, "ActionBar", 2)
        for i = 0, 3 do
            local b = bar["ActionButton" .. i]
            if b and b["Touch"]("enabled"):GetInt() == 1 and b("locked"):GetInt() ~= 1 then turn = true end
        end
    end)
    if turn and B.turn == false then say("Your turn", false) end
    B.turn = turn
end
-- Battle results (battle_campaign_results, BattleCampaignResultsUI.lua):
-- Victory or Defeat, and the rewards (rewardEntryN: Amount, CurrencyType).
FRIENDLY.__battleRewardNames = { battle_xp = "Battle XP", xp = "XP", medals = "Medals", coins = "Coins",
    diamond = "Diamonds", diamonds = "Diamonds", costume = "Costume", trophy = "Trophies", trophies = "Trophies" }
function FRIENDLY.__resultsTick(root, now)
    local B = FRIENDLY.__battle
    if now - (B.resAt or 0) > 2 then B.resSaid = false end
    B.resAt = now
    if B.resSaid then return end
    local bg = findNamed(root, "Bg", 2)
    local win = findNamed(bg, "Victory", 1)
    local lose = findNamed(bg, "Defeat", 1)
    local parts = {}
    local items = {}
    if win and isVisible(win) then
        parts[1] = "Victory!"
        local kids = nil; pcall(function() kids = win:elements() end)
        local n = 0; pcall(function() n = kids:size() end)
        for i = 0, n - 1 do
            local c = nil; pcall(function() c = kids[i] end)
            local cn = c and elementName(c)
            if cn and cn:find("^rewardEntry") then
                local amt = elementText(findNamed(c, "Value", 1))
                local kind = ""; pcall(function() kind = c("CurrencyType"):GetString() end)
                if kind == "" then pcall(function() kind = c("Icon"):GetString() end) end
                a11y_log("[battle] reward " .. tostring(amt) .. " " .. tostring(kind))
                if amt then items[#items + 1] = amt .. " " .. (FRIENDLY.__battleRewardNames[kind:lower()] or kind) end
            end
        end
    elseif lose and isVisible(lose) then
        parts[1] = "Defeat."
    else
        return
    end
    if #items > 0 then parts[#parts + 1] = "You got " .. table.concat(items, ", ") .. "." end
    parts[#parts + 1] = "Tab to Continue."
    B.resSaid = true
    later(0.5, function() say(table.concat(parts, " "), true) end)
end
-- REMOVE on a selected tree or rock: its price, as template_removecost.xml
-- shows it (game.objectRemovalCoinCost() for the selected object).
function FRIENDLY.__removeLabel(el)
    local text = elementText(el) or ""
    if text:upper() ~= "REMOVE" then return nil end
    local cost = nil
    pcall(function() cost = tonumber(game.objectRemovalCoinCost()) end)
    if not cost then return nil end
    pcall(function()
        FRIENDLY.__sidPrice = FRIENDLY.__sidPrice or {}
        FRIENDLY.__sidPrice[game.selectedStructureId()] = cost
    end)
    local t = tostring(math.floor(cost)):reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
    return "Remove, " .. t .. " coins"
end
-- UPGRADE on a selected building's bar: the price the bar shows as a coloured
-- number (template_upgradecost.xml: game.structureUpgradeCost/Currency/Sale).
FRIENDLY.__upgradeCurrency = { coins = "Coins", coin = "Coins", diamond = "Diamonds", diamonds = "Diamonds",
    food = "Food", keys = "Keys", key = "Keys", relics = "Relics", relic = "Relics", shards = "Shards",
    eth_currency = "Shards", starpower = "Starpower", medals = "Medals" }
function FRIENDLY.__upgradeLabel(el)
    local text = elementText(el) or ""
    if text:upper() ~= "UPGRADE" then return nil end
    local cost, cur, sale, orig = nil, nil, false, nil
    pcall(function() cost = tonumber(game.structureUpgradeCost()) end)
    pcall(function() cur = game.structureUpgradeCurrency() end)
    pcall(function() sale = game.structureUpgradeSale() and true or false end)
    if sale then pcall(function() orig = tonumber(game.structureUpgradeOrigCost()) end) end
    if not cost then return nil end
    if not FRIENDLY.__upgradeLogged then
        FRIENDLY.__upgradeLogged = true
        a11y_log("[upgrade] cost " .. tostring(cost) .. " currency " .. tostring(cur) .. " sale " .. tostring(sale))
    end
    local name = nil
    if type(cur) == "number" then
        pcall(function() name = currencyCounterName("currency_counter_" .. tostring(cur)) end)
    elseif cur ~= nil then
        local k = tostring(cur):lower():gsub("^currency_", "")
        name = FRIENDLY.__upgradeCurrency[k]
    end
    if not name or name == "Currency" then name = "Coins" end
    local function num(n)
        local str = tostring(math.floor(n))
        local out = str:reverse():gsub("(%d%d%d)", "%1,"):reverse()
        return (out:gsub("^,", ""))
    end
    local label = "Upgrade, " .. num(cost) .. " " .. name
    if sale and orig and orig > cost then label = label .. ", on sale, was " .. num(orig) end
    return label
end
-- SPEED UP on a selected building's or monster's bar: the Diamonds it costs
-- (ContextBar.lua: SelectedObject():diamondsRequiredToCompleteAction()).
function FRIENDLY.__speedUpLabel(el)
    local text = elementText(el) or ""
    if text:upper() ~= "SPEED UP" then return nil end
    local d = nil
    pcall(function() d = tonumber(game.SelectedObject():diamondsRequiredToCompleteAction()) end)
    if not d or d <= 0 then pcall(function() d = tonumber(game.diamondsLeftToSpeedup()) end) end
    if not d or d <= 0 then return nil end
    return "Speed up, " .. math.floor(d) .. " Diamonds"
end
-- FEED on a selected monster's bar: the food it costs, the same number the
-- bar shows beside the button (template_foodreq.xml: game.objectFoodRequired).
function FRIENDLY.__feedLabel(el)
    local text = elementText(el) or ""
    if text:upper() ~= "FEED" then return nil end
    local cost = nil
    pcall(function() cost = tonumber(game.objectFoodRequired()) end)
    if not FRIENDLY.__feedLogged then
        FRIENDLY.__feedLogged = true
        a11y_log("[feed] button text '" .. text .. "', objectFoodRequired " .. tostring(cost))
    end
    if not cost or cost <= 0 then return nil end
    local str = tostring(math.floor(cost)):reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
    return "Feed, " .. str .. " food"
end
-- The in-game Breeding Guide (newsflash "BREEDING GUIDE"): its pages are
-- pictures with no text, so their words are written out here.
FRIENDLY.__guidePages = {
    "Eureka! You've unlocked the Breeding Structure! This handy guide will teach you how to start breeding Monster hybrids! Select Next to learn more.",
    "The Basics. Combine two Level 4 Monsters of different Elements to create a new type of Monster! A Monster's Elements appear in the Breeding Menu and on its Market frame. The picture: a Noggin, Earth, plus a Toe Jammer, Water, makes a Fwog, Earth and Water.",
    "The Basics. Combining Monsters of two or more Elements can result in new Monsters or ones just like the parents. The picture: a Noggin, Earth, plus a Maw, Water and Cold, makes a T-Rox, Earth, Water and Cold, or a Noggin, or a Maw.",
    "The Basics. If an Element is repeated in a Breeding combination, the resulting Monster will be one of the parents. The picture: a Mammott, Cold, plus a Drumpler, Earth and Cold, is crossed out, because both have Cold. A Mammott, Cold, plus a Fwog, Earth and Water, gets a check mark.",
    "Advanced. Some Special Monsters like Ethereals, Seasonals, Mythicals and Epics have secret, unique breeding combinations that do not follow the Elemental rules. Try different combinations and you might get lucky! The picture shows four mystery monsters around a heart with a question mark.",
    "Advanced. You can improve your breeding chances for Special Monsters by breeding higher Level Monsters together. You can also improve your chances by lighting Wishing Torches, unlocked at Level 12. The picture shows a level 10 T-Rox and a lit Wishing Torch.",
}
FRIENDLY.__guide = { page = nil, at = 0 }
-- Event screens: the event's name (Subtitle, when it has words) and its
-- two lines of description.
function POPUP_READERS.__eventScreen(popup)
    local parts = { shownText(popup, "Subtitle") or "New event" }
    for _, nm in ipairs({ "Description1", "Description2" }) do
        local t = shownText(popup, nm)
        if t then parts[#parts + 1] = t end
    end
    return joinSentences(parts)
end
-- Clubbox (ClubboxActSelect / ClubboxTutorialPopup): whoever is talking
-- (DJNametag) says DJWordsLabel; the act cards and island carousel are pictures.
FRIENDLY.__club = { at = -100 }
function FRIENDLY.__clubSpeaker(root)
    local who = shownText(root, "DJNametag")
    return who and (who .. ": ") or ""
end
function FRIENDLY.__clubAct(root)
    local sel = findNamed(root, "ActSelect", 3)
    if not sel then return nil end
    local id = nil
    pcall(function() id = sel.selectedActId end)
    if type(id) ~= "number" or id <= 0 then return nil end
    local parts = {}
    pcall(function() parts[1] = "Act: " .. cleanText(LOC(game.getClubboxActTitle(id))) end)
    for _, nm in ipairs({ "HypeCount", "RewardCount" }) do
        local t = shownText(sel, nm)
        if t then parts[#parts + 1] = t end
    end
    return id, joinSentences(parts)
end
function FRIENDLY.__clubIsland(root)
    local car = findNamed(root, "IslandCarousel", 3)
    if not car or not isVisible(car) then return nil end
    local id = nil
    pcall(function() id = findNamed(root, "IslandSelect", 2).selectedIslandId end)
    if type(id) ~= "number" then return nil end
    local name = "Island " .. id
    pcall(function() name = cleanText(LOC(game.islandName(id))) end)
    local owned = true
    pcall(function() owned = game.isIslandOwned(id) and true or false end)
    return id, name .. (owned and "" or ", you don't have this island")
end
function POPUP_READERS.__club(popup)
    local C = FRIENDLY.__club
    local parts = {}
    local words = shownText(popup, "DJWordsLabel")
    if words then C.spoken = words; parts[#parts + 1] = FRIENDLY.__clubSpeaker(popup) .. words end
    local id, act = FRIENDLY.__clubAct(popup)
    if act then C.actSpoken = id; parts[#parts + 1] = act end
    if #parts == 0 then return nil end
    return joinSentences(parts)
end
POPUP_READERS.clubbox_act_select = POPUP_READERS.__club
POPUP_READERS.clubbox_progress = function(popup)
    local parts = { "Hype progress" }
    local hype = shownText(popup, "HypeBlob")
    if hype then parts[#parts + 1] = hype end
    local a, b = (shownText(popup, "RewardBlob") or ""):match("(%d+)%s*/%s*(%d+)")
    if a then parts[#parts + 1] = "Rewards earned: " .. a .. " of " .. b end
    local left = shownText(popup, "TimeFrame")
    if left and not left:find("^[0:%s]+$") then parts[#parts + 1] = left .. " left" end
    local p1, p2 = shownText(popup, "TopPrize1"), shownText(popup, "TopPrize2")
    if p1 then parts[#parts + 1] = "Top prizes: " .. p1 .. (p2 and (" and " .. p2) or "") end
    return joinSentences(parts)
end
-- CUSTOMIXER performers: each row (PropN) is one monster in the act
-- (game.clubboxPropMonster); its icon opens that monster's costumes.
function FRIENDLY.__mixPerformer(row)
    local ind = nil
    pcall(function() ind = row.propInd end)
    local name = nil
    if type(ind) == "number" and ind >= 0 then
        local tid = nil
        pcall(function() tid = game.clubboxPropMonster(ind) end)
        pcall(function() name = cleanText(LOC(game.getMonsterData(tid):name())) end)
        if name and FRIENDLY.__withRarity then name = FRIENDLY.__withRarity(name, tid) end
        -- Act DJs are props named by their icon (button_djepic -> DJ Epic);
        -- the monster behind them (Hoola) isn't what the act calls them.
        local icon = nil
        pcall(function() icon = tostring(game.clubboxPropCustomizeIcon(ind)) end)
        local dj = icon and icon:match("^button_dj(%a+)")
        if dj then name = "DJ " .. dj:sub(1, 1):upper() .. dj:sub(2) end
        FRIENDLY.__mixLogged = FRIENDLY.__mixLogged or {}
        if not FRIENDLY.__mixLogged[ind] then
            FRIENDLY.__mixLogged[ind] = true
            local dj, audio, cost = nil, nil, nil
            pcall(function() dj = game.getDJHoolaPropInd() end)
            pcall(function() audio = game.hasAudioTrack(ind) end)
            pcall(function() cost = game.clubboxPropCustomizeIcon(ind) end)
            a11y_log("[mixer] prop " .. tostring(ind) .. " monster " .. tostring(tid) .. " -> " .. tostring(name)
                .. " dj " .. tostring(dj) .. " audio " .. tostring(audio) .. " icon " .. tostring(cost))
        end
        local unlocked = true
        pcall(function() unlocked = game.clubboxPropUnlocked(ind) and true or false end)
        if not unlocked then return (name or "Performer") .. ", locked" end
    end
    -- The DJ's row (it has an OptionsIcon) opens the options page instead.
    if findNamed(row, "OptionsIcon", 1) then return (name or "DJ") .. ", options" end
    return (name or "Performer") .. ", costumes"
end
-- Stage decor buttons: which part of the stage (from the button's icon
-- name) and the style number shown on it ("-" locked, "!" new style).
function FRIENDLY.__mixStage(bg, btn)
    local id, icon = nil, nil
    pcall(function() id = bg.buttonId end)
    pcall(function() icon = tostring(game.getStageEdButtonIcon(id)) end)
    local part = icon and icon:lower():gsub("^.*/", ""):gsub("%.%w+$", "")
        :gsub("^icon_", ""):gsub("^button_", ""):gsub("^customize_", ""):gsub("_", " ")
    if not part or part == "" or part == "nil" then part = "part " .. tostring(id) end
    part = part:gsub("^deco ", "decor, ")
    local t = elementText(btn)
    local total = nil
    pcall(function() total = game.getStageEditorNumVariants(id) end)
    if t == "-" then return "Stage " .. part .. ", locked" end
    if t == "!" then return "Stage " .. part .. ", new style to try" end
    return "Stage " .. part .. (t and (", style " .. t .. (type(total) == "number" and (" of " .. total) or "")) or "")
end
-- A performer's volume slider: who, how loud, and the keys. nil when it
-- isn't one (or the performer has no sound to mix).
function FRIENDLY.__mixRow(slider)
    local row = nil
    pcall(function() row = slider:parent():parent() end)
    local ind = nil
    pcall(function() ind = row.propInd end)
    if type(ind) ~= "number" or ind < 0 then return nil end
    return row, ind
end
function FRIENDLY.__mixVolume(slider)
    local row, ind = FRIENDLY.__mixRow(slider)
    if not row then return nil end
    local vol = nil
    pcall(function() vol = game.clubboxPropVolume(ind) end)
    if type(vol) ~= "number" then return nil end
    local who = FRIENDLY.__mixPerformer(row):gsub(", %a+$", "")
    local audio = true
    pcall(function() audio = game.hasAudioTrack(ind) ~= false end)
    if not audio then return who .. ", no sound to mix" end
    return who .. " volume, slider, " .. math.floor(vol * 100 + 0.5) .. " percent"
end
-- Control+Shift+A in the Clubbox: the act, where it plays, Hype toward the
-- next reward, tickets and time left (game.existingClubboxAct etc., as
-- ClubboxActSelect / ClubboxProgress use them).
function FRIENDLY.__clubStatus()
    local parts = {}
    local act, title, island = nil, nil, nil
    pcall(function() act = game.existingClubboxAct() end)
    pcall(function() title = cleanText(LOC(game.getClubboxActTitle(act))) end)
    pcall(function() island = cleanText(LOC(game.islandName(game.existingClubboxIslandId()))) end)
    parts[1] = "Clubbox" .. (title and (", " .. title) or "") .. (island and (", on " .. island) or "")
    local hud = liveMenu("hud_clubbox")
    local a, b = (elementText(hud and findNamed(hud, "RewardBar", 3)) or ""):match("(%d+)%s*/%s*(%d+)")
    if a then parts[#parts + 1] = "Hype " .. a .. " of " .. b .. " to the next reward" end
    local total = nil
    pcall(function() total = game.clubboxCurHype(act) end)
    if type(total) == "number" then parts[#parts + 1] = "Hype generated: " .. total end
    local tickets = elementText(hud and findNamed(hud, "TokenCounter", 2) and findNamed(findNamed(hud, "TokenCounter", 2), "currency_counter_12", 1))
    if not tickets and hud then
        local tc = findNamed(hud, "TokenCounter", 2)
        local first = nil
        pcall(function() first = tc:elements()[0] end)
        tickets = first and elementText(first)
    end
    if tickets then parts[#parts + 1] = tickets .. " Clubbox Tickets" end
    local left = nil
    pcall(function() left = cleanText(game.timeToString(game.clubboxShortestTimeAvail())) end)
    if left and left ~= "" then parts[#parts + 1] = left .. " left" end
    return joinSentences(parts)
end
-- Say the new style after pressing a stage decor button.
FRIENDLY.__mix = { at = -100, styles = {} }
function FRIENDLY.__mixTick(root, now)
    local M = FRIENDLY.__mix
    if now - M.at > 1.5 then M.styles = {} end
    M.at = now
    for i = 0, 2 do
        local bg = findNamed(root, "StageEditorBg" .. i, 4)
        local v = nil
        if bg then pcall(function() v = bg.activeVariantInd end) end
        if v ~= nil then
            local old = M.styles[i]
            M.styles[i] = v
            if old ~= nil and old ~= v then
                later(0.2, function()
                    local r = liveMenu("clubbox_customization")
                    local b = r and findNamed(r, "StageEditorBg" .. i, 4)
                    local btn = b and findNamed(b, "VariantControlButton", 1)
                    if btn then say(FRIENDLY.__mixStage(b, btn), true) end
                end)
            end
        end
    end
end
-- The Glowbe colour of a CONJURE choice. Not in the game's text; the game
-- tints them in code (tintDefaultBuddy sets one of red, green, blue to full
-- by the choice number: 0 red, 1 green, 2 blue).
FRIENDLY.__glowbeNames = { [0] = "Red Glowbe", [1] = "Green Glowbe", [2] = "Blue Glowbe" }
function FRIENDLY.__glowbeChoice(entry, i)
    return FRIENDLY.__glowbeNames[i] or ("Glowbe " .. (i + 1))
end
POPUP_READERS.fuzer_create = function(popup)
    return "Conjure a Glowbe: Red, Green or Blue"
end
POPUP_READERS.popup_clubbox_unlock_fanfare = function(popup)
    local who = shownText(popup, "MonsterName")
    local what = shownText(popup, "MonsterInfo")
    if not who and not what then return nil end
    local t = (((who or "") .. " " .. (what or "")):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""))
    if not t:find("[%.!?]$") then t = t .. "!" end
    return t
end
POPUP_READERS.open_card_pack = function(popup)
    local left = shownText(popup, "CurrencyCounter")
    return "Sticker pack" .. (left and (". " .. left .. " packs left") or "")
end
POPUP_READERS.clubbox_tutorial_popup = POPUP_READERS.__club
-- Hype game: say the ticket amount when it changes (with what the wheels can
-- give for it), and the spin's result ("40*3=120") once the wheels stop.
FRIENDLY.__hype = { at = -100 }
function FRIENDLY.__hypeOdds(g)
    local function list(t)
        local out = {}
        pcall(function() for i = 1, #t do out[#out + 1] = tostring(t[i]) end end)
        if #out == 0 then return nil end
        if #out == 1 then return out[1] end
        return table.concat(out, ", ", 1, #out - 1) .. " or " .. out[#out]
    end
    local base, multi = nil, nil
    pcall(function() base = list(g.baseValues) end)
    pcall(function() multi = list(g.multiValues) end)
    if not base then return nil end
    return "The left wheel gives " .. base .. " Hype" .. (multi and (", the right wheel multiplies it by " .. multi) or "")
end
function FRIENDLY.__hypeTick(root, now)
    local H = FRIENDLY.__hype
    if now - H.at > 1.5 then H.tickets, H.result = nil, nil end
    H.at = now
    local g = findNamed(root, "hype_game", 2)
    if not g then return end
    local tickets, result = nil, nil
    pcall(function() tickets = g.currentTickets end)
    pcall(function() result = g.currentResult end)
    if type(tickets) == "number" and tickets ~= H.tickets then
        local first = H.tickets == nil
        H.tickets = tickets
        a11y_log("[hype] tickets " .. tostring(tickets))
        later(first and 1.5 or 0.15, function()
            local r = liveMenu("hype_game")
            local g2 = r and findNamed(r, "hype_game", 2)
            local odds = g2 and FRIENDLY.__hypeOdds(g2)
            say(tickets .. " tickets" .. (odds and (". " .. odds) or ""), not first)
        end)
    end
    if type(result) == "string" and result ~= H.result then
        H.result = result
        a11y_log("[hype] result " .. result)
        local a, b, c = result:match("^%s*(%d+)%s*%*%s*(%d+)%s*=%s*(%d+)")
        if c then later(0.3, function() say("Result: " .. a .. " times " .. b .. ", " .. c .. " Hype!", true) end) end
    end
end
function FRIENDLY.__clubTick(root, now)
    local C = FRIENDLY.__club
    if now - C.at > 1.5 then
        C.words, C.spoken, C.act, C.actSpoken, C.island = nil, nil, nil, nil, nil
    end
    C.at = now
    local words = shownText(root, "DJWordsLabel")
    if words and words ~= C.words then
        local first = C.words == nil
        C.words = words
        local who = FRIENDLY.__clubSpeaker(root)
        later(first and 0.8 or 0.3, function()
            if C.spoken == words then return end
            C.spoken = words
            say(who .. words, true)
        end)
    end
    -- The act picked (cards, Left / Right): its name, Hype and rewards.
    local id, act = FRIENDLY.__clubAct(root)
    if id and id ~= C.act then
        C.act = id
        later(0.4, function()
            if C.actSpoken == id then return end
            C.actSpoken = id
            -- (A fresh root: this frame's may be gone by then.)
            local r, now2 = liveMenu("clubbox_act_select"), nil
            if r then local _i, t = FRIENDLY.__clubAct(r); now2 = t end
            say(now2 or act, false)
        end)
    end
    -- The island picked on the carousel.
    local iid, island = FRIENDLY.__clubIsland(root)
    if iid ~= C.island then
        C.island = iid
        if iid then later(0.3, function() say("Island: " .. island, false) end) end
    end
end
function FRIENDLY.__newsTick(root, now)
    local G = FRIENDLY.__guide
    if now - G.at > 1.5 then G.page = nil end
    G.at = now
    local title = shownText(root, "TitleFrame")
    if not title or title:upper() ~= "BREEDING GUIDE" then G.page = nil return end
    local page, total = (shownText(root, "PageCounter") or ""):match("(%d+)%s*/%s*(%d+)")
    page = tonumber(page)
    if not page or page == G.page then return end
    local first = G.page == nil
    G.page = page
    local text = FRIENDLY.__guidePages[page] or "No words for this page yet"
    later(first and 0.6 or 0.2, function()
        say("Breeding guide, page " .. page .. " of " .. total .. ". " .. text, not first)
    end)
end
function FRIENDLY.__appearance()
    local isMonster = false
    pcall(function() isMonster = game.selectedObjIsMonster() and true or false end)
    if not isMonster then say("Select a monster first, then press Control Shift I", true) return end
    local uid = nil
    pcall(function() uid = game.selectedMonsterId() end)
    local tid = nil
    pcall(function() tid = game.GetMonster(uid):monsterTypeId() end)
    if not tid then pcall(function() tid = game.selectedMonsterTypeId() end) end
    local name = nil
    pcall(function() name = cleanText(LOC(game.getMonsterData(tid):name())) end)
    local byName = name and FRIENDLY.__looksByName[name]
    name = FRIENDLY.__withRarity(name or "This monster", tid)
    -- Key the description by the monster's element letters (game.
    -- monsterTypeGenes, same numbering as its name). The portrait codes are
    -- built from those letters. getPortraitName's numbering didn't match the
    -- type id (it gave other monsters' pictures), so it is only logged, via
    -- the entity id, as a cross-check.
    local genes = nil
    pcall(function() genes = tostring(game.monsterTypeGenes(tid)) end)
    local code = nil
    pcall(function()
        local v = game.getPortraitName(game.monsterTypeEntityId(tid))
        code = v and tostring(v):match("([^/]+)$"):gsub("%.%w+$", "")
    end)
    a11y_log("[looks] type " .. tostring(tid) .. " genes " .. tostring(genes) .. " portrait by entity " .. tostring(code))
    local base = genes and genes:lower():gsub("[^%a]", "")
    if base then
        local letters = {}
        for ch in base:gmatch(".") do letters[#letters + 1] = ch end
        table.sort(letters)
        base = table.concat(letters)
    end
    if base and not base:find("^[a-g]+$") then base = nil end
    local parts = { name }
    local desc = byName or (base and FRIENDLY.__looks[base])
    parts[#parts + 1] = desc or "No description yet"
    local list, count = FRIENDLY.__elementsOf(tid)
    if list then parts[#parts + 1] = (count == 1 and "Element: " or "Elements: ") .. list end
    say(joinSentences(parts), true)
end

-- Monster type id from its display name, or nil if unknown or shared.
function POPUP_READERS.__typeByName(name)
    local map = POPUP_READERS.__names
    if not map then
        map = {}
        local misses = 0
        for id = 1, 3000 do
            local n = nil
            pcall(function() n = cleanText(LOC(game.getMonsterData(id):name())) end)
            if n and n ~= "" then
                misses = 0
                n = n:lower()
                map[n] = (map[n] == nil) and id or false
            else
                misses = misses + 1
                if misses > 300 then break end
            end
        end
        POPUP_READERS.__names = map
    end
    return map[(name or ""):lower()] or nil
end

-- "You've hatched..." / "You've bred..." keep the monster in a separate
-- MonsterName text; put it in place of the dots.
function POPUP_READERS.__eggResult(popup)
    local note = shownText(popup, "Notification")
    local name = shownText(popup, "MonsterName")
    if not note or not name then return nil end
    -- PopupHatchMonster.lua: setupMonster reads the MonsterID template var.
    local tid = nil
    pcall(function()
        local v = popup:templateVars().MonsterID
        if type(v) == "userdata" then v = v:GetInt() end
        tid = tonumber(v)
    end)
    -- popup_breed_egg is built in C++ with no MonsterID: look the name up,
    -- unless several monsters share it (common and rare Furcorn).
    if not (tid and tid > 0) then tid = POPUP_READERS.__typeByName(name) end
    if tid and tid > 0 then name = FRIENDLY.__withRarity(name, tid) end
    if not POPUP_READERS.__eggLogged then
        POPUP_READERS.__eggLogged = true
        a11y_log("[rarity] egg result " .. tostring(name) .. ", type id " .. tostring(tid))
    end
    local head, rest = note:match("^(.-)%.%.%.%s*(.*)$")
    if not head then return joinSentences({ note, name }) end
    return joinSentences({ head .. " " .. name, rest ~= "" and rest or nil })
end
POPUP_READERS.popup_hatch_monster = POPUP_READERS.__eggResult
POPUP_READERS.popup_breed_egg = POPUP_READERS.__eggResult

-- Memory game (FlipCardBase.lua / FlipCardEntry.lua): cardEntryN under Cards,
-- each with a CharacterImage whose sprite is monster_portrait_random while
-- face down and the card's own picture once turned over.
FRIENDLY.__flip = { seen = {}, pending = nil }
FRIENDLY.__flip.CURRENCY = { coin = "Coins", coins = "Coins", diamond = "Diamonds", diamonds = "Diamonds",
    food = "Food", xp = "XP", key = "Keys", keys = "Keys", shard = "Shards", relic = "Relics", star = "Starpower" }
-- Monster portraits are named by code (monster_portrait_square_q05_rare):
-- game.getPortraitName(monsterId) gives that code, so map it back once.
function FRIENDLY.__flip.portraitName(code)
    local map = FRIENDLY.__flip.portraits
    if not map then
        map = {}
        local misses = 0
        for id = 1, 3000 do
            -- Only ask for portraits of ids that are real monsters.
            local pn, nm = nil, nil
            pcall(function() nm = cleanText(LOC(game.getMonsterData(id):name())) end)
            if nm and nm ~= "" then pcall(function() pn = game.getPortraitName(id) end) end
            if nm and nm ~= "" then
                misses = 0
                if pn and pn ~= "" then
                    pn = tostring(pn):match("([^/]+)$"):gsub("%.%w+$", "")
                    if not map[pn] then map[pn] = FRIENDLY.__withRarity(nm, id) end
                end
            else
                misses = misses + 1
                if misses > 300 then break end
            end
        end
        FRIENDLY.__flip.portraits = map
        local n = 0; for _ in pairs(map) do n = n + 1 end
        a11y_log("[flip] portrait names: " .. n)
    end
    return map[code]
end
-- What a card shows, or nil while face down.
function FRIENDLY.__flip.face(entry)
    local img = findNamed(entry, "CharacterImage", 1)
    if not img then return nil end
    local s = ""
    pcall(function() s = tostring(img:C("Sprite")("spriteName"):GetString() or "") end)
    if s == "" or s:find("portrait_random", 1, true) then return nil end
    local code = (s:match("([^/]+)$") or s):gsub("%.%w+$", "")
    local amt = elementText(img)
    amt = amt and amt:find("%d") and amt or nil
    if not FRIENDLY.__flip.seen[s] then
        FRIENDLY.__flip.seen[s] = true
        local ind, emb = nil, nil
        pcall(function() ind = entry:templateVars().CardInd end)
        pcall(function() emb = game.getFlipEmbeddedSprite(tonumber(ind) or ind) end)
        a11y_log("[flip] sprite " .. s .. " text " .. tostring(amt) .. " ind " .. tostring(ind) .. " embedded " .. tostring(emb))
    end
    local cur = FRIENDLY.__flip.CURRENCY[code:lower()]
    if cur then return amt and (amt .. " " .. cur) or cur end
    if code == "monster_portrait_prize" then return amt and ("Prize, " .. amt) or "Prize" end
    local name = FRIENDLY.__flip.portraitName(code)
    if not name then
        name = code:gsub("^monster_portrait_square_", ""):gsub("^monster_portrait_", ""):gsub("_", " ")
    end
    return amt and (amt .. " " .. name) or name
end
function FRIENDLY.__flip.label(entry, i)
    if not findNamed(entry, "CharacterImage", 1) then return nil end
    local face = FRIENDLY.__flip.face(entry)
    if not face then return "Card " .. i .. ", face down" end
    -- Face up and not the card waiting for its pair: a matched card.
    local matched = FRIENDLY.__flip.pending ~= i and liveMenu("flip_base") ~= nil
    return "Card " .. i .. ": " .. face .. (matched and ", matched" or "")
end
function FRIENDLY.__flip.status(root)
    return joinSentences({ shownText(root, "Title"), shownText(root, "Mismatches") })
end
function FRIENDLY.__flip.turn(i)
    later(0.05, function()
        local root = liveMenu("flip_base")
        local entry = root and findNamed(root, "cardEntry" .. (i - 1), 3)
        local img = entry and findNamed(entry, "CharacterImage", 1)
        if not img then say("Card not found", true) return end
        if FRIENDLY.__flip.face(entry) then
            say("Card " .. i .. " is already face up: " .. FRIENDLY.__flip.face(entry), true)
            return
        end
        local before = FRIENDLY.__flip.status(root)
        local beforeMis = shownText(root, "Mismatches")
        local beforeTitle = shownText(root, "Title")
        local first = FRIENDLY.__flip.pending
        local second = first ~= nil and first ~= i
        FRIENDLY.__flip.pending = second and nil or i
        -- The card's touch is FlipCardEntry's own CFlipCardTouch, which has no
        -- onTouchDown to call: tap its centre through the game's touch input,
        -- the way the scratch ticket is rubbed.
        local touch = resolve("a11y_touch")
        local fx, fy = nil, nil
        pcall(function()
            local sw, sh = lua_sys.screenWidth(), lua_sys.screenHeight()
            fx = (img:absX() + img:absW() / 2) / sw
            fy = (img:absY() + img:absH() / 2) / sh
        end)
        if type(touch) ~= "function" or not fx then
            a11y_log("[flip] can't tap card " .. i .. ": touch=" .. type(touch) .. " pos=" .. tostring(fx))
            say("Could not turn the card", true)
            return
        end
        a11y_log(string.format("[flip] tap card %d at %.3f,%.3f", i, fx, fy))
        menuState.touch()
        pcall(touch, fx, fy, 2)
        pcall(touch, fx, fy, 1)
        later(0.06, function() pcall(touch, fx, fy, 0) end)
        later(0.8, function()
            local r = liveMenu("flip_base")
            local e = r and findNamed(r, "cardEntry" .. (i - 1), 3)
            local face = e and FRIENDLY.__flip.face(e)
            local parts = { "Card " .. i .. ": " .. (face or "face down") }
            if second then
                local mis = r and shownText(r, "Mismatches")
                local title = r and shownText(r, "Title")
                if title and beforeTitle and title ~= beforeTitle then
                    parts[#parts + 1] = "Match. Level complete"
                elseif mis and beforeMis and mis ~= beforeMis then
                    parts[#parts + 1] = "No match"
                else
                    parts[#parts + 1] = "Match"
                end
            end
            local after = r and FRIENDLY.__flip.status(r)
            if after and after ~= before then parts[#parts + 1] = after end
            say(joinSentences(parts), true)
        end)
    end)
end
POPUP_READERS.flip_base = function(popup)
    FRIENDLY.__flip.pending = nil
    return joinSentences({ "Memory game", FRIENDLY.__flip.status(popup),
        "Tab to a card and press Enter to turn it over. Find the matching pairs" })
end

-- Spin the Wheel (minigame_spinprize.xml): the prize is known once the wheel
-- stops (game.getSpinWheelRewardAmount / getSpinWheelRewardType), before
-- Collect is pressed. Said when the Collect button appears.
FRIENDLY.__spin = { said = false }
function FRIENDLY.__spinPrize()
    local amt, kind = nil, nil
    pcall(function() amt = game.getSpinWheelRewardAmount() end)
    pcall(function() kind = tostring(game.getSpinWheelRewardType()) end)
    if not kind or kind == "" or kind == "nil" then return nil end
    local words = { coins = "Coins", diamonds = "Diamonds", food = "Food", keys = "Keys", relics = "Relics",
                    clubboxtokens = "Clubbox Tokens", shards = "Shards", starpower = "Starpower" }
    local word = words[kind:lower()] or kind
    local num = nil
    pcall(function() num = game.commaizeNumber(amt) end)
    num = num or (amt and tostring(amt))
    if not num or num == "0" then return word end
    return num .. " " .. word
end
function FRIENDLY.__spinTick(root)
    local btn = findNamed(root, "Button", 3)
    local collecting = btn and isVisible(btn) and elementText(btn) ~= nil
    if collecting and not FRIENDLY.__spin.said then
        FRIENDLY.__spin.said = true
        local prize = FRIENDLY.__spinPrize()
        a11y_log("[spin] prize " .. tostring(prize))
        later(0.3, function() say("You won " .. (prize or "a prize") .. ". Tab to Collect.", true) end)
    elseif not collecting then
        FRIENDLY.__spin.said = false
    end
end
-- Loading screen (login_base): the status line ("Downloading Game Data")
-- whenever it changes, and the game's tip once per load. Never interrupts.
FRIENDLY.__loading = { status = nil, tip = nil }
function FRIENDLY.__loadingTick(root)
    local L = FRIENDLY.__loading
    local status = shownText(root, "ConnectionStatus")
    -- "Downloading Game Data 45%": drop the percentage, so it is said once
    -- per step rather than at every percent.
    if status then
        status = status:gsub("%(?%s*%d+%.?%d*%s*%%%s*%)?", ""):gsub("%s*%d+%s*/%s*%d+", "")
            :gsub("[%s%.:,%-]+$", ""):gsub("^%s+", "")
        if status == "" then status = nil end
    end
    local tip = shownText(root, "ToolTip")
    local parts = {}
    if status and status ~= L.status then
        L.status = status
        parts[#parts + 1] = status
    end
    if tip and tip ~= L.tip then
        L.tip = tip
        parts[#parts + 1] = "Tip: " .. tip
    end
    if #parts > 0 then say(joinSentences(parts), false) end
end

-- Time Machine WARP (warp_popup.xml): game.timeWarpSpeed / setTimeWarpSpeed,
-- 0.5 to 2, 1 is normal. The slider's knob is moved to match, with the
-- same formula the menu's onInit uses.
FRIENDLY.__warp = {}
function FRIENDLY.__warp.get()
    local v = 1
    pcall(function() v = tonumber(game.timeWarpSpeed()) or 1 end)
    return v
end
function FRIENDLY.__warp.text()
    local v = FRIENDLY.__warp.get()
    local r = math.floor(v * 10 + 0.5) / 10
    local t = string.format("%.1f", r):gsub("%.0$", "")
    if r == 1 then return "Speed normal" end
    return "Speed " .. t .. " times, " .. (r > 1 and "faster" or "slower") .. " than normal"
end
function FRIENDLY.__warp.set(v)
    v = math.max(0.5, math.min(2.0, math.floor(v * 10 + 0.5) / 10))
    pcall(function() game.setTimeWarpSpeed(v) end)
    later(0.05, function()
        local root = liveMenu("warp_popup")
        local slider = root and findNamed(root, "Slider", 3)
        if slider then
            pcall(function()
                local w = slider:absW()
                local x = v >= 1 and (w / 2) * (v - 1) or w * (v - 1)
                slider:C("Sprite")("xOffset"):SetInt(math.floor(x + 0.5))
            end)
        end
    end)
    say(FRIENDLY.__warp.text(), true)
end
function FRIENDLY.__warp.step(d)
    FRIENDLY.__warp.set(FRIENDLY.__warp.get() + d)
end
POPUP_READERS.warp_popup = function(popup)
    return joinSentences({ shownText(popup, "Label") or "Time Warper", FRIENDLY.__warp.text(),
        "Tab to Faster, Slower or Normal speed, or Shift Comma and Shift Period. Escape when done" })
end

-- XP to the next level (X / Control+Shift+X). CurrencyCounterAvatarXP.lua
-- fills the level ring with game.playerCurrentXp() / game.playerXpForLevel().
function FRIENDLY.__xp()
    local lvl, maxLvl, cur, need = nil, nil, nil, nil
    pcall(function() lvl = tonumber(game.playerLevel()) end)
    pcall(function() maxLvl = tonumber(game.maxPlayerLevel()) end)
    pcall(function() cur = tonumber(game.playerCurrentXp()) end)
    pcall(function() need = tonumber(game.playerXpForLevel()) end)
    if not need and lvl then pcall(function() need = tonumber(game.playerXpForLevel(lvl + 1)) end) end
    a11y_log("[xp] level " .. tostring(lvl) .. " max " .. tostring(maxLvl) .. " current " .. tostring(cur) .. " for level " .. tostring(need))
    local function num(n)
        local t = nil
        pcall(function() t = game.commaizeNumber(n) end)
        return t or tostring(math.floor(n))
    end
    if lvl and maxLvl and lvl >= maxLvl then say("Level " .. lvl .. ", the highest level", true) return end
    if not cur or not need or need <= 0 then say("XP not available", true) return end
    local left = math.max(0, need - cur)
    local pct = math.floor(cur * 100 / need)
    say((lvl and ("Level " .. lvl .. ". ") or "") .. num(cur) .. " of " .. num(need) .. " XP, " .. pct .. " percent. "
        .. num(left) .. " XP to level " .. (lvl and (lvl + 1) or "the next level"), true)
end

POPUP_READERS.minigame_spinprize = function(popup)
    local parts = { "Spin the Wheel" }
    local desc = shownText(popup, "Description")
    if desc then parts[#parts + 1] = desc end
    return joinSentences(parts)
end

-- Offer popup (ComboPack.lua): title, description, price tag and what's in it.
POPUP_READERS.combo_pack = function(popup)
    local parts = {}
    local title = shownText(popup, "TitleText")
    parts[#parts + 1] = "Offer" .. (title and (": " .. title) or "")
    local desc = shownText(popup, "DescriptionText")
    if desc then parts[#parts + 1] = desc end
    local pct = shownText(popup, "PercentageLabel")
    if pct then parts[#parts + 1] = pct end
    local old = shownText(popup, "OldValue")
    if old then parts[#parts + 1] = "Was " .. old end
    local tag = shownText(popup, "TagValue")
    if tag then parts[#parts + 1] = tag end
    -- The bundle's items: every shown text under Bundle, once each.
    local seen, items = {}, {}
    local function walk(el, depth)
        if not el or depth > 6 then return end
        local t = nil
        pcall(function() if el.Text("visible"):GetInt() ~= 0 then t = elementText(el) end end)
        if t and not t:find("^[%.%s]*$") and not seen[t] then seen[t] = true; items[#items + 1] = t end
        local kids = nil; pcall(function() kids = el:elements() end)
        local n = 0; pcall(function() n = kids:size() end)
        for i = 0, n - 1 do
            local c = nil; pcall(function() c = kids[i] end)
            walk(c, depth + 1)
        end
    end
    walk(findNamed(popup, "Bundle", 3), 0)
    if #items > 0 then parts[#parts + 1] = "Contains: " .. table.concat(items, ", ") end
    local time = shownText(popup, "OfferTime")
    if time then parts[#parts + 1] = time end
    a11y_log("[offer] " .. table.concat(parts, " | "))
    return joinSentences(parts)
end

POPUP_READERS.minigame_doorprize = function(popup)
    local parts = { "Scratch ticket" }
    local desc = shownText(popup, "Description")
    if desc then parts[#parts + 1] = desc end
    local more = shownText(popup, "MonsterDescription")
    if more then parts[#parts + 1] = more end
    parts[#parts + 1] = "Tab to a square and press Enter to scratch it, or choose Scratch all squares"
    return joinSentences(parts)
end

POPUP_READERS.popup_encore_info = function(popup)
    local parts = {}
    local title = shownText(popup, "TitleFrame")
    if title then parts[#parts + 1] = "Encore event: " .. title end
    local theme = shownText(popup, "TopText")
    if theme then parts[#parts + 1] = theme end
    local conv = shownText(popup, "ConversionInfo")
    if conv then
        local n, unit, pts = conv:match("(%d+)%s*([smhd])%s*=%s*(%d+)")
        local UNITS = { s = "seconds", m = "minutes", h = "hours", d = "days" }
        if n then
            local what = theme and theme:match(":%s*(.+)$")
            parts[#parts + 1] = "Every " .. n .. " " .. UNITS[unit] .. (what and (" of " .. what .. " time") or "")
                .. " earns " .. pts .. (pts == "1" and " point" or " points")
        else
            parts[#parts + 1] = conv
        end
    end
    pcall(function()
        local bar = findNamed(game.getHUD(), "EncoreBar", 2)
        local pts = bar and elementText(findNamed(bar, "RewardBar", 1))
        local a, b = (pts or ""):match("(%d+)%s*/%s*(%d+)")
        if a then parts[#parts + 1] = "You have " .. a .. " of " .. b .. " points" end
        local left = bar and elementText(findNamed(bar, "Timer", 1))
        if left then parts[#parts + 1] = left .. " left" end
    end)
    if #parts == 0 then return nil end
    return joinSentences(parts)
end

-- "You received:": read the rewards. They can still be filling in when the
-- popup is pushed; then speak them once they show.
POPUP_READERS.popup_store_bundle_rewards = function(popup)
    local items = FRIENDLY.__social.rewardList(popup)
    if #items > 0 then return "You received: " .. table.concat(items, ", ") end
    later(0.8, function()
        local r = liveMenu("popup_store_bundle_rewards")
        local it = r and FRIENDLY.__social.rewardList(r) or {}
        if #it > 0 then say("You received: " .. table.concat(it, ", ") .. ".", false) end
    end)
    return nil
end

-- ---------------------------------------------------------------------------
-- "Places" menu (Ctrl+Shift+M): a keyboard-openable list of the main
-- destinations. The on-screen market/book/map/options bar lives in a separate
-- menu tree the game exposes no element handle for (dump: topAncestor
-- EntityReduxMenu_Root has only the HUD under it). But those buttons just call
-- game.* entry points -- verified in decompiled ContextBar.lua -- so we invoke
-- them directly. For a screen reader, a direct destination list beats hunting a
-- spatial bar anyway. Every action is pcall-guarded.
-- ---------------------------------------------------------------------------
local function goOptions()
    -- Mirror ContextBar: close a non-root popup first, then open options.
    local cur = ""; pcall(function() cur = tostring(game.getPopUp()) end)
    if cur ~= "options" then
        if cur ~= "" and cur ~= "MenuReduxElement_Root" then pcall(game.popPopUp) end
        pcall(function() game.pushPopUp("options") end)
    end
end
local function goBook()
    pcall(function()
        local isl = game.player():getActiveIsland()
        game.setBookOfMonstersIslandId(isl:id(), isl:islandMode())
    end)
    pcall(function() game.pushPopUp("book_o_monsters") end)
end

local PLACES = {
    { "Market",           function() pcall(game.loadStoreContext) end },
    { "Book of Monsters", goBook },
    { "Map",              function() pcall(function() game.loadMapContext(false) end) end },
    { "Goals",            function() pcall(function() game.pushPopUp("goals") end) end },
    { "Friends",          function() pcall(function() game.checkGamePermission("FRIENDS", "popup_permission_friends") end) end },
    { "Mail",             function() pcall(function() game.pushPopUp("mail") end) end },
    { "Options",          goOptions },
}


-- A virtual list (Places, Objects) driven by Tab / Shift+Tab / Enter.
-- items: array of { label, action }.
local vmenu = { active = false, index = 0, kind = nil, items = {} }

local function openList(kind, title, items, hint)
    if vmenu.active and vmenu.kind == kind then   -- same hotkey again: close
        vmenu.active = false
        say(title .. " closed", true)
        return
    end
    if #items == 0 then say(title .. ": nothing here", true) return end
    vmenu.active, vmenu.index, vmenu.kind, vmenu.items = true, 0, kind, items
    local labels = {}
    for i, d in ipairs(items) do labels[i] = d[1] end
    local list = #items <= 8 and (table.concat(labels, ", ") .. ". ") or (#items .. " items. ")
    say(title .. ". " .. list .. hint, true)
end

local function openPlaces()
    openList("places", "Places", PLACES, "Tab to move, Enter to open, Control Shift M to close.")
end

-- ---------------------------------------------------------------------------
-- Island objects (Ctrl+Shift+O): structures and monsters on the current
-- island, selected the same way the Goals screen's "go" buttons do it
-- (game.getFirstStructureOfType + game.selectStructure, game.selectMonster).
-- Selecting shows the object's context bar, which Tab then navigates.
-- ---------------------------------------------------------------------------
-- getFirstStructureOfType uses the game's structure-type numbers (Goals.lua:
-- 6 = obstacle, 17 = awakener), not SpecificEntityType, so scan the range.
local MAX_STRUCTURE_TYPE = 64

-- The selected object's name, as the game shows it.
local function selectedName()
    local n = nil
    pcall(function() n = game.objectName() end)
    n = n and n ~= "" and cleanText(n) or nil
    -- A selected monster: add its species to the nickname ("Glob, Toe Jammer").
    local isMonster = false
    pcall(function() isMonster = game.selectedObjIsMonster() and true or false end)
    if isMonster then
        local species = nil
        pcall(function() species = cleanText(LOC(game.getMonsterDataFromUniqueId(game.selectedMonsterId()):name())) end)
        local tid = nil
        pcall(function() tid = game.GetMonster(game.selectedMonsterId()):monsterTypeId() end)
        species = FRIENDLY.__withRarity(species, tid)
        if species and (not n or n:lower() ~= species:lower()) then
            return n and (n .. ", " .. species) or species
        end
    end
    return n
end

local sdLogged = false
local function structureLabel(uid)
    local sd = nil
    pcall(function() sd = game.getStructureDataFromUniqueId(uid) end)
    if not sd then return nil end
    if not sdLogged then
        sdLogged = true
        local names = {}
        pcall(function()
            local mt = getmetatable(sd)
            for _, t in ipairs({ mt, rawget(mt, ".fn") }) do
                if type(t) == "table" then for k in pairs(t) do names[#names + 1] = tostring(k) end end
            end
        end)
        a11y_log("[objects] structure data members: " .. table.concat(names, " "))
    end
    for _, m in ipairs({ "name", "getName", "displayName", "entityName", "structureName" }) do
        local ok, v = pcall(function() return sd[m](sd) end)
        if ok and type(v) == "string" and v ~= "" then return cleanText(v) end
    end
    for _, m in ipairs({ "entityId", "getEntityId", "id", "structureId", "type" }) do
        local ok, v = pcall(function() return sd[m](sd) end)
        if ok and type(v) == "number" then
            local ok2, nm = pcall(game.structureTypeName, v)
            if ok2 and type(nm) == "string" and nm ~= "" then return cleanText(nm) end
        end
    end
    return nil
end

-- The species ("Toe Jammer"), from the monster's data.
local function monsterSpecies(uid)
    local sp, tid = nil, nil
    pcall(function() sp = cleanText(LOC(game.getMonsterDataFromUniqueId(uid):name())) end)
    pcall(function() tid = game.GetMonster(uid):monsterTypeId() end)
    if not tid then pcall(function() tid = game.GetMultiMonster(uid):monsterTypeId() end) end
    return FRIENDLY.__withRarity(sp, tid)
end

-- Players can rename monsters, and getMonsterName returns that nickname
-- ("Glob"). Say both: "Glob, Toe Jammer"; just the species if they match.
local function monsterLabel(uid)
    local nick = nil
    pcall(function() nick = cleanText(game.getMonsterName(uid)) end)
    local species = monsterSpecies(uid)
    if nick and species and nick:lower() ~= species:lower() then return nick .. ", " .. species end
    return species or nick or "Monster"
end

local TAP_ZOOM, TAP_SECONDS = 0.8, 0.4    -- same zoom FugueSuccess.lua uses
local TAP_FX, TAP_FY = 0.5, 0.47          -- object anchor is at its base: aim just above

local function objectSelected()
    local s = false
    pcall(function() s = game.isObjectSelected() and true or false end)
    return s
end

local function selectedObject()
    local obj = nil
    pcall(function() obj = game.SelectedObject() end)
    if not obj then pcall(function() obj = game:SelectedObject() end) end
    return obj
end

-- What is selected right now, as "m<uid>" / "s<id>" (nil if nothing), so a
-- tap can be checked: did it select our object, or something standing in front?
local function selectionKey()
    if not objectSelected() then return nil end
    local isMonster, key = false, nil
    pcall(function() isMonster = game.selectedObjIsMonster() and true or false end)
    if isMonster then pcall(function() key = "m" .. tostring(game.selectedMonsterId()) end)
    else pcall(function() key = "s" .. tostring(game.selectedStructureId()) end) end
    return key
end

-- Is the current selection our object? By id, or by name in case the id
-- spaces differ. Returns nil when nothing is selected.
local function selectionIs(wantKey, name)
    local got = selectionKey()
    if not got then return nil end
    if wantKey == nil or got == wantKey then return true end
    local n = selectedName()
    if n and name and n:lower() == name:lower() then return true end
    return false
end

-- Points to try on the object, centred by the camera. Its anchor is at its
-- base, so go up first; then sideways, for trees or rocks standing in front.
-- The second point is the centre itself: on a 16:10 screen (1280x800) the
-- tutorial Nursery's egg sits at 0.50 and 0.47 lands on the chain above it.
local TAP_POINTS = {
    { 0.5, 0.47 }, { 0.5, 0.51 }, { 0.5, 0.40 }, { 0.5, 0.33 }, { 0.46, 0.42 }, { 0.54, 0.42 },
}
local TAP_CHECK_SECONDS = 0.45
-- Second pass when every point hit something in front (a small rock behind
-- a building): zoom in closer, so the object is bigger on screen, and try
-- tighter points around its middle.
FRIENDLY.__tapCloseZoom = 1.6
FRIENDLY.__tapClosePoints = {
    { 0.5, 0.48 }, { 0.5, 0.44 }, { 0.47, 0.46 }, { 0.53, 0.46 }, { 0.5, 0.40 }, { 0.5, 0.52 },
}

-- Tap a world object like a finger would: centre the camera on it with the
-- game's zoomCameraToObject, then click. A real tap collects treats and coins,
-- and is what tutorial steps that block direct selection wait for.
-- wantKey: the selectionKey the tap should leave (nil = don't check).
-- reselect: puts our object back after a miss. done(hit): called at the end.
-- untilSomething: also count a click that selected nothing and opened no
-- screen as a miss (it hit empty ground), and try the next point.
local function tapEntity(entity, name, wantKey, reselect, done, untilSomething)
    if not entity then say("Can't find " .. name, true) if done then done(false) end return end
    if type(clickFraction) ~= "function" and not resolve("a11y_touch") then say("Click function unavailable", true) return end
    local ok, err = pcall(function() game.worldContext():zoomCameraToObject(entity, TAP_ZOOM, TAP_SECONDS) end)
    if not ok then
        -- Camera didn't move: a click would hit whatever is mid-screen.
        a11y_log("[tap] zoomCameraToObject failed, not clicking: " .. tostring(err))
        if done then done(false) end
        return
    end
    -- A tap can make the object go away instead of selecting it (clearing a
    -- tree or rock whose removal has finished). Then stop: further taps would
    -- land on whatever was behind it.
    local sid = wantKey and tonumber(tostring(wantKey):match("^s(%d+)$"))
    local function gone()
        if not sid then return false end
        local e = nil
        pcall(function() e = game.GetStructure(sid) end)
        return e == nil
    end
    local points, closer = TAP_POINTS, false
    local function try(i)
        local pt = points[i]
        local clickedAt = clock()
        menuState.tap(pt[1], pt[2])
        later(TAP_CHECK_SECONDS, function()
            if gone() then
                a11y_log("[tap] " .. name .. " went away after point " .. i)
                if done then done(true, "gone") end
                return
            end
            local got = selectionKey()
            -- A miss is something else getting selected (a tree in front),
            -- or, when asked, nothing happening at all.
            local miss = selectionIs(wantKey, name) == false
                or (untilSomething and got == nil and not menuState.openedSince(clickedAt))
            a11y_log("[tap] " .. name .. " point " .. i .. " -> " .. tostring(got) .. (miss and " (miss)" or ""))
            if miss and i < #points then
                if reselect then pcall(reselect) end
                later(0.2, function() try(i + 1) end)
            elseif miss and not closer and got ~= nil then
                -- Everything hit something else: zoom in and try again.
                closer, points = true, FRIENDLY.__tapClosePoints
                if reselect then pcall(reselect) end
                a11y_log("[tap] " .. name .. ": zooming in closer")
                local zok = pcall(function() game.worldContext():zoomCameraToObject(entity, FRIENDLY.__tapCloseZoom, TAP_SECONDS) end)
                if zok then later(TAP_SECONDS + 0.25, function() try(1) end)
                elseif done then done(false) end
            elseif done then
                if miss and reselect then pcall(reselect) end
                done(not miss)
            end
        end)
    end
    later(TAP_SECONDS + 0.25, function() try(1) end)
end

local function tapSelected()
    local obj = selectedObject()
    if not obj then say("Nothing selected", true) return end
    local name = selectedName() or "object"
    local key = selectionKey()
    local isMonster = key and key:sub(1, 1) == "m"
    local id = key and tonumber(key:sub(2))
    local function reselect()
        if isMonster then game.selectMonster(id) else game.selectStructure(id) end
    end
    say("Tap " .. name, true)
    -- Selected Nursery with a finished egg: hatch it the game's way first
    -- (see activateObject); click only if that didn't take.
    -- On a friend's island: a plain click, nothing the game wouldn't do.
    if FRIENDLY.__visiting and FRIENDLY.__visiting() then
        tapEntity(obj, name, key, nil, function(hit)
            if not hit then say("Something is in front of " .. name .. ". Could not tap it.", true) end
        end)
        return
    end
    local ready = false
    if name:lower():find("nursery", 1, true) then
        pcall(function() ready = game.eggReadyToHatch() and true or false end)
    end
    if ready then
        local hok, herr = pcall(function() game.hatchEgg() end)
        if not hok and id and tostring(herr):find("args", 1, true) then
            hok, herr = pcall(function() game.hatchEgg(id) end)
        end
        a11y_log("[hatch] (tap) hatchEgg -> " .. tostring(hok) .. " " .. tostring(herr))
        later(0.8, function()
            local still = false
            pcall(function() still = game.eggReadyToHatch() and true or false end)
            if still then tapEntity(obj, name, nil, nil, function() end) end
        end)
        return
    end
    tapEntity(obj, name, key, id and reselect or nil, function(hit)
        if not hit then say("Something is in front of " .. name .. ". Could not tap it.", true) end
    end)
end

-- Enter on an island object: select it directly (can't hit anything in front
-- of it). Tutorial steps that refuse direct selection get a real tap instead.
local function activateObject(entity, label, select, wantKey)
    say(label, true)
    local ok, err = pcall(select)
    if not ok then a11y_log("[tap] select " .. label .. " failed: " .. tostring(err)) end
    later(0.2, function()
        local got = selectionKey()
        if selectionIs(wantKey, label) then
            -- A Nursery whose egg is done hatches when tapped. The game does
            -- that from C++ through game.hatchEgg (no Lua caller to copy, so
            -- its arguments are unknown): try none, then the structure id. A
            -- wrong argument count is a Lua error, which pcall catches. Only
            -- with the Nursery selected, so the game has a Nursery to use.
            local ready = false
            if label:lower():find("nursery", 1, true) then
                pcall(function() ready = game.eggReadyToHatch() and true or false end)
            end
            if ready then
                local id = wantKey and tonumber(wantKey:match("^s(%d+)$"))
                local hok, herr = pcall(function() game.hatchEgg() end)
                if not hok and id and tostring(herr):find("args", 1, true) then
                    a11y_log("[hatch] hatchEgg(): " .. tostring(herr) .. "; trying with the id")
                    hok, herr = pcall(function() game.hatchEgg(id) end)
                end
                a11y_log("[hatch] hatchEgg -> " .. tostring(hok) .. " " .. tostring(herr))
                later(0.8, function()
                    local still = false
                    pcall(function() still = game.eggReadyToHatch() and true or false end)
                    a11y_log("[hatch] egg still ready afterwards: " .. tostring(still))
                    if not still then return end
                    -- Didn't hatch: tap the Nursery like a finger would.
                    tapEntity(entity, label, nil, nil, function()
                        later(0.6, function()
                            local again = false
                            pcall(function() again = game.eggReadyToHatch() and true or false end)
                            if again then say("Could not hatch the egg. Try Tab, then Tap " .. label .. ".", true) end
                        end)
                    end)
                end)
                return
            end
            local torch = FRIENDLY.__torchStatus and FRIENDLY.__torchStatus()
            say((selectedName() or label) .. " selected" .. (torch and (", " .. torch) or "") .. ". Tab for actions.", true)
            return
        end
        a11y_log("[tap] direct select of " .. label .. " didn't take (" .. tostring(got) .. "), tapping")
        local tapStart = clock()
        tapEntity(entity, label, wantKey, select, function(hit, how)
            later(0.15, function()
                if how == "gone" then
                    FRIENDLY.__objCache = nil
                    say(label .. " cleared away", false)
                elseif hit and menuState.openedSince(tapStart) then
                    -- The tap opened a screen (the hatching fanfare, a notice):
                    -- its own announcement says what happened; don't talk over it.
                    a11y_log("[tap] " .. label .. " opened a screen")
                elseif selectionIs(wantKey, label) then
                    local torch = FRIENDLY.__torchStatus and FRIENDLY.__torchStatus()
                    say((selectedName() or label) .. " selected" .. (torch and (", " .. torch) or "") .. ". Tab for actions.", true)
                elseif hit then
                    -- The click selected nothing; that's normal when the tap
                    -- does its own thing (hatch, collect), but say so honestly.
                    say("Clicked on " .. label .. ". If nothing happened, the click missed.", true)
                else
                    say("Could not tap " .. label .. ". Something is in front of it, or nothing answered the click.", true)
                end
            end)
        end, true)                              -- a click on empty ground: try the next spot
    end)
end

-- Structure lookups only answer while the island view is active (not in the
-- Market, Map...), so an empty structure list means "not on the island".
-- ---------------------------------------------------------------------------
-- Object status: what the icons floating over objects show sighted players.
-- Probed in game: secondsUntilActionDone is the time left on a bake, breed,
-- build or clear (0 when idle, negative once done); "done" is told apart from
-- "done long ago" by the island's has*Ready checks. The Nursery's egg calls
-- are not reachable from Lua (the entity comes back as a plain Structure).
-- ---------------------------------------------------------------------------
local function durationText(secs)
    secs = secs - secs % 1
    local h = (secs - secs % 3600) / 3600
    local m = (secs % 3600 - secs % 60) / 60
    local s = secs % 60
    local function unit(n, word) return n .. " " .. word .. (n == 1 and "" or "s") end
    if h > 0 then return m > 0 and (unit(h, "hour") .. " " .. unit(m, "minute")) or unit(h, "hour") end
    if m > 0 then return m >= 10 and unit(m, "minute") or (s > 0 and (unit(m, "minute") .. " " .. unit(s, "second")) or unit(m, "minute")) end
    return unit(s, "second")
end

-- The selected Wishing Torch: lit or not, and burn time left.
-- SharedObjectInfo.lua shows game.torchTime() (seconds) when it is > 0; the
-- bar's context says TORCH_UNLIT / TORCH_DAILY_LIT (ContextBar.lua).
function FRIENDLY.__torchStatus()
    local isTorch = false
    pcall(function() isTorch = game.selectedObjType() == game.SpecificEntityType_TORCH end)
    if not isTorch then return nil end
    local t, ctx = nil, nil
    pcall(function() t = tonumber(game.torchTime()) end)
    pcall(function() ctx = tostring(manager:getContext()) end)
    a11y_log("[torch] torchTime " .. tostring(t) .. " context " .. tostring(ctx))
    if ctx and ctx:find("PERMA") then return "lit permanently" end
    if t and t > 0 then return "lit, " .. durationText(t) .. " left" end
    if ctx == "TORCH_UNLIT" then return "not lit" end
    return nil
end

local function islandReady(check)
    local v = false
    pcall(function() local isl = game.player():getActiveIsland(); v = isl[check](isl) and true or false end)
    return v
end

local function entityIs(ent, method)
    local v = false
    pcall(function() v = ent[method](ent) and true or false end)
    return v
end

local MAX_BUSY_SECONDS = 60 * 60 * 24 * 60     -- larger means "never started" garbage

local function structureStatus(id)
    local ent = nil
    pcall(function() ent = game.GetStructure(id) end)
    if not ent then return nil end
    local secs = 0
    pcall(function() secs = ent:secondsUntilActionDone() or 0 end)
    local busy = secs > 0 and secs < MAX_BUSY_SECONDS
    local upgrading = false
    pcall(function() upgrading = game.isStructureUpgrading(id) and true or false end)
    if entityIs(ent, "isBakery") then
        if busy then return "baking, " .. durationText(secs) .. " left" end
        if islandReady("hasBakeryReady") then return "food ready to collect" end
        return "idle"
    elseif entityIs(ent, "isBreeding") then
        if busy then return "breeding, " .. durationText(secs) .. " left" end
        if islandReady("hasBreedingReady") then return "breeding finished, egg ready" end
        return "empty"
    elseif entityIs(ent, "isNursery") then
        if busy then
            -- Rare and Epic eggs shimmer while incubating (a game tip); say
            -- what sighted players see, without naming the monster.
            local look = ""
            pcall(function()
                local tid = game.FindNursery(0):getMonsterInEgg()
                if tid and tid > 0 then
                    if game.isEpic(tid) then
                        look = ", the egg is wrapped in a dazzling, swirling shimmer: an Epic egg!"
                    elseif game.isRare(tid) then
                        look = ", the egg sparkles with a soft shimmer: a Rare egg!"
                    end
                end
            end)
            return "egg hatching, " .. durationText(secs) .. " left" .. look
        end
        if islandReady("hasNurseryReady") then return "egg ready to hatch" end
        return nil
    elseif entityIs(ent, "isCastle") then
        if busy then return "upgrading, " .. durationText(secs) .. " left" end
        if islandReady("hasCastleUpgradeReady") then return "upgrade finished" end
        return nil
    elseif (structureLabel(id) or ""):lower():find("torch") then
        -- No per-torch state in the API; the island's counts tell it when
        -- every torch is in the same state (game.numLitTorches etc.).
        local function count(fn)
            local v = nil
            pcall(function() v = tonumber(game[fn]()) end)
            if v == nil then pcall(function() v = tonumber(game[fn](game.player():getActiveIsland())) end) end
            return v
        end
        local total, lit, perma = count("numTorchesTotal"), count("numLitTorches"), count("numPermaLitTorches")
        if not total or total < 1 or not lit then return nil end
        if perma and perma >= total then return "lit permanently" end
        if lit >= total then return "lit" end
        if lit == 0 and (perma or 0) == 0 then return "not lit" end
        return lit .. " of " .. total .. " torches lit"
    elseif entityIs(ent, "isObstacle") then
        if busy then return "being removed, " .. durationText(secs) .. " left" end
        -- Finished removals sit at a small negative time; never-started ones
        -- read as a huge negative number.
        if secs < 0 and secs > -MAX_BUSY_SECONDS then return "removal finished, tap it to clear it away" end
        return nil
    end
    if busy then return (upgrading and "upgrading, " or "building, ") .. durationText(secs) .. " left" end
    return nil
end

local function monsterStatus(uid)
    local ent = nil
    pcall(function() ent = game.GetMonster(uid) end)
    local parts = {}
    -- The Colossingum: no feeding, likes or coins; monsters train instead.
    local battle = false
    pcall(function() battle = game.isBattleIsland() and true or false end)
    if battle then
        local lvl = nil
        pcall(function() lvl = ent:level() end)
        if lvl then parts[#parts + 1] = "level " .. tostring(lvl) end
        local training = false
        -- isMonsterTraining needs the island's world context (it crashes
        -- outright otherwise): only ask while the island HUD is live.
        if liveMenu("hud") then
            pcall(function() training = game.isMonsterTraining(uid) and true or false end)
        end
        if training then parts[#parts + 1] = "training in the Conservatory" end
        return #parts > 0 and table.concat(parts, ", ") or nil
    end
    if ent then
        local lvl, fed, need = nil, nil, 0
        pcall(function() lvl = ent:level() end)
        pcall(function() fed = ent:timesFed() end)
        pcall(function() need = ent:foodRequired() or 0 end)
        if lvl then parts[#parts + 1] = "level " .. tostring(lvl) end
        if fed and need > 0 and lvl and lvl < 20 then parts[#parts + 1] = "fed " .. tostring(fed) .. " of 4" end
        local muted = false
        pcall(function() muted = ent:isMuted() and true or false end)
        if muted then parts[#parts + 1] = "muted" end
        -- Happiness (ContextBar.lua shows game.monsterHappiness as a bar).
        local happy = nil
        local ok = pcall(function() happy = tonumber(game.monsterHappiness(uid)) end)
        if not ok then
            local sel = nil
            pcall(function() sel = game.selectedMonsterId() end)
            if sel == uid then pcall(function() happy = tonumber(game.monsterHappiness()) end) end
        end
        if not menuState.happyLogged then
            menuState.happyLogged = true
            a11y_log("[likes] monsterHappiness(" .. tostring(uid) .. ") ok=" .. tostring(ok) .. " -> " .. tostring(happy))
        end
        if happy and happy > 0 then
            if happy <= 1 then happy = happy * 100 end
            parts[#parts + 1] = "happiness " .. math.floor(happy + 0.5) .. "%"
        end
        local st = nil
        pcall(function() st = FRIENDLY.__likeStatus(uid) end)
        if st then parts[#parts + 1] = st.met .. " of " .. st.total .. " known likes met" end
    end
    local coins = 0
    pcall(function() coins = game.monsterEarnings(uid) or 0 end)
    if coins > 0 then parts[#parts + 1] = tostring(coins) .. " coins" end
    return #parts > 0 and table.concat(parts, ", ") or nil
end

-- Level-ups (mostly from feeding, which needs the monster selected): watch
-- the selected monster's level and say when it goes up.
menuState.levels = { t = -100 }
function menuState.levelWatch(now)
    local w = menuState.levels
    if now - w.t < 0.25 then return end
    w.t = now
    local fh = menus.friend_hud
    if fh and now - fh.t < 3 then w.uid = nil return end
    local uid, lvl = nil, nil
    pcall(function() uid = game.selectedMonsterId() end)
    if not uid or uid == 0 then w.uid = nil return end
    pcall(function() lvl = game.GetMonster(uid):level() end)
    if not lvl then return end
    if w.uid == uid and w.lvl and lvl > w.lvl then
        local name = nil
        pcall(function() name = cleanText(game.getMonsterName(uid)) end)
        if not name or name == "" then name = "Monster" end
        say(name .. " leveled up to level " .. tostring(lvl), false)
        a11y_log("[level] " .. name .. " " .. tostring(w.lvl) .. " -> " .. tostring(lvl))
    end
    w.uid, w.lvl = uid, lvl
end

local function withStatus(label, status)
    return status and (label .. ", " .. status) or label
end

-- Every structure on the island (not just the first of each type: there are
-- usually several Small Trees and Rocks). Falls back to the type scan.
local function islandStructureIds()
    local ids, seen = {}, {}
    pcall(function()
        local ss = game.player():getActiveIsland():structures()
        for i = 0, ss:size() - 1 do
            local id = ss[i]
            if id and not seen[id] then seen[id] = true; ids[#ids + 1] = id end
        end
    end)
    if #ids == 0 then
        for t = 0, MAX_STRUCTURE_TYPE do
            local id = 0
            pcall(function() id = game.getFirstStructureOfType(t) or 0 end)
            if id ~= 0 and not seen[id] then seen[id] = true; ids[#ids + 1] = id end
        end
    end
    return ids
end

local OBJECT_GROUPS = { [0] = "Buildings", [1] = "Monsters", [2] = "Decorations", [3] = "Trees and rocks", [4] = "Clearing" }

-- Visiting a friend's island (one table lookup: the visiting HUD ticked just now).
function FRIENDLY.__visiting()
    local fh = menus.friend_hud
    return fh ~= nil and clock() - fh.t < 0.5
end
-- A friend's island. game.getVisitedFriend():getActiveIsland() lists their
-- objects; GetMonster / GetStructure look objects up on the island on screen
-- (theirs). Enter does exactly what a finger would: bring it into view and
-- tap it. No direct selecting, so the game decides what a visitor may do.
function FRIENDLY.__friendObjects()
    local isl = nil
    pcall(function() isl = game.getVisitedFriend():getActiveIsland() end)
    if not isl then return {} end
    local function entry(label, rank, find, key)
        return { label, name = label, rank = rank, function()
            vmenu.active = false
            local ent = nil
            pcall(function() ent = find() end)
            say(label, true)
            tapEntity(ent, label, key, nil, function(hit)
                if not hit then say("Something is in front of " .. label .. ". Could not tap it.", true) return end
                if selectionIs(key, label) then say(label .. " selected. Tab for what you can do.", true) end
            end, true)
        end }
    end
    local structs, total, nth, logged = {}, {}, {}, 0
    pcall(function()
        local ss = isl:structures()
        for i = 0, ss:size() - 1 do
            local id = ss[i]
            local ent = nil
            pcall(function() ent = game.GetStructure(id) end)
            -- Name it from the object on screen (theirs), the way the game's
            -- scripts do (entityId -> getStructureByEntityId / entityName);
            -- structureLabel looks the id up in YOUR data, so it's a fallback.
            local eid, how, label = nil, nil, nil
            for _, m in ipairs({ "entityId", "getEntityId", "entityID" }) do
                if not eid then pcall(function() eid = tonumber(ent[m](ent)) end) end
            end
            if eid then
                pcall(function() label = cleanText(LOC(game.getStructureByEntityId(eid):name())); how = "structureByEntityId" end)
                if not label or label == "" then label = FRIENDLY.__entityName(eid); how = "entityName" end
            end
            if not label or label == "" then label = structureLabel(id); how = "your data" end
            label = (label and label ~= "") and label or "Structure"
            -- Group: the object's own flags, else its structure data's type.
            local rank = entityIs(ent, "isObstacle") and 3 or (entityIs(ent, "isDecoration") and 2 or 0)
            if rank == 0 and eid then
                local sd = nil
                pcall(function() sd = game.getStructureByEntityId(eid) end)
                if entityIs(sd, "isObstacle") then rank = 3 elseif entityIs(sd, "isDecoration") then rank = 2 end
            end
            if not FRIENDLY.__friendLogged and logged < 8 then
                logged = logged + 1
                a11y_log("[friend] structure " .. tostring(id) .. " eid " .. tostring(eid) .. " -> " .. tostring(label)
                    .. " (" .. tostring(how) .. ") rank " .. rank)
            end
            structs[#structs + 1] = { label = label, rank = rank, id = id }
            total[label] = (total[label] or 0) + 1
        end
    end)
    local mons = {}
    pcall(function()
        local ms = isl:monsters()
        for i = 0, ms:size() - 1 do
            local uid = ms[i]
            local ent, tid, lvl, species = nil, nil, nil, nil
            pcall(function() ent = game.GetMonster(uid) end)
            pcall(function() tid = ent:monsterTypeId() end)
            pcall(function() lvl = ent:level() end)
            pcall(function() species = cleanText(LOC(game.getMonsterData(tid):name())) end)
            species = FRIENDLY.__withRarity(species, tid)
            if not FRIENDLY.__friendLogged and i < 3 then
                a11y_log("[friend] monster " .. tostring(uid) .. " -> " .. tostring(species) .. " level " .. tostring(lvl))
            end
            if species then
                mons[#mons + 1] = entry(species .. (lvl and (", level " .. lvl) or ""), 1,
                    function() return game.GetMonster(uid) end, "m" .. tostring(uid))
            end
        end
    end)
    FRIENDLY.__friendLogged = true
    local items = {}
    for _, st in ipairs(structs) do
        if total[st.label] > 1 then
            nth[st.label] = (nth[st.label] or 0) + 1
            st.label = st.label .. " " .. nth[st.label]
        end
        local sid = st.id
        st.item = entry(st.label, st.rank, function() return game.GetStructure(sid) end, "s" .. tostring(sid))
    end
    for _, st in ipairs(structs) do if st.rank == 0 then items[#items + 1] = st.item end end
    for _, m in ipairs(mons) do items[#items + 1] = m end
    for rank = 2, 3 do
        for _, st in ipairs(structs) do if st.rank == rank then items[#items + 1] = st.item end end
    end
    return items
end

local function islandObjects()
    if FRIENDLY.__visiting() then return FRIENDLY.__friendObjects() end
    -- In the Clubbox, game.player()'s island is still your home island.
    local club = menus.hud_clubbox
    if club and clock() - club.t < 0.5 then return {} end
    local items = {}
    -- Buildings first, then monsters, decorations, and trees/rocks last.
    -- Repeated names get a number: "Small Tree 2".
    local structs, total, nth = {}, {}, {}
    for _, id in ipairs(islandStructureIds()) do
        local ent = nil
        pcall(function() ent = game.GetStructure(id) end)
        local label = structureLabel(id) or "Structure"
        local rank = entityIs(ent, "isObstacle") and 3 or (entityIs(ent, "isDecoration") and 2 or 0)
        -- Trees and rocks being removed, or done and waiting for a tap, get a
        -- group of their own ("Clearing"), only while there are any.
        local clearing = nil
        if rank == 3 then
            local st = (structureStatus(id) or ""):lower()
            if st:find("removal finished", 1, true) then clearing = 1
            elseif st:find("being removed", 1, true) then clearing = 2 end
            if clearing then rank = 4 end
        end
        structs[#structs + 1] = { id = id, label = label, rank = rank, clearing = clearing }
        total[label] = (total[label] or 0) + 1
    end
    for _, st in ipairs(structs) do
        if total[st.label] > 1 then
            nth[st.label] = (nth[st.label] or 0) + 1
            st.label = st.label .. " " .. nth[st.label]
        end
        local id, label = st.id, st.label
        st.item = { withStatus(label, structureStatus(id)), name = label, rank = st.rank, sid = id,
            live = function() return withStatus(label, structureStatus(id)) end, function()
            vmenu.active = false
            local ent = nil
            pcall(function() ent = game.GetStructure(id) end)
            activateObject(ent, label, function() game.selectStructure(id) end, "s" .. tostring(id))
        end }
    end
    for _, st in ipairs(structs) do if st.rank == 0 then items[#items + 1] = st.item end end
    pcall(function()
        local mons = game.player():getActiveIsland():monsters()
        for i = 0, mons:size() - 1 do
            local uid = mons[i]
            local label = monsterLabel(uid)
            local species = nil
            pcall(function() species = LOC(game.getMonsterDataFromUniqueId(uid):name()) end)
            items[#items + 1] = { withStatus(label, monsterStatus(uid)), name = label,
                species = species and tostring(species) or nil, rank = 1,
                live = function() return withStatus(label, monsterStatus(uid)) end, function()
                vmenu.active = false
                local ent = nil
                pcall(function() ent = game.GetMonster(uid) end)
                if not ent then pcall(function() ent = game.GetMultiMonster(uid) end) end
                activateObject(ent, label, function() game.selectMonster(uid) end, "m" .. tostring(uid))
            end }
        end
    end)
    for rank = 2, 3 do
        for _, st in ipairs(structs) do if st.rank == rank then items[#items + 1] = st.item end end
    end
    -- Clearing: finished ones first (ready to tap away), then being removed.
    for c = 1, 2 do
        for _, st in ipairs(structs) do if st.clearing == c then items[#items + 1] = st.item end end
    end
    return items
end

-- ---------------------------------------------------------------------------
-- Tutorial target. The banner always names what to tap ("Collect the Treats",
-- "Click on the Egg...", "Feed your Noggin..."). Map its words to an island
-- object so one key (or the first Tab entry) taps the right thing.
-- Rules are checked in order, against the game's own tutorial lines (en.utf8):
-- "Click on the Egg to transfer it to the Nursery" is the egg sitting in the
-- Breeding Structure; "Wait for the egg to hatch", "Speed up the hatching of
-- your Mammott egg" and "Monster eggs incubate in the Nursery" are the Nursery,
-- so hatching wins over the bare word "egg".
-- ---------------------------------------------------------------------------
local TUTORIAL_TARGETS = {
    { "transfer it to the nursery", "breeding" },
    { "place the monster", "nursery" },
    { "hatch",             "nursery" },
    { "incubat",           "nursery" },
    { "nursery",           "nursery" },
    { "egg",               "breeding" },
    { "treat",             "bakery" },
    { "cookie",            "bakery" },
    { "bak",               "bakery" },
    { "breed",             "breeding" },
    { "castle",            "castle" },
}

local function tutorialBannerText()
    local active = false
    pcall(function() active = game.tutorialActive() and true or false end)
    if not active then return nil end
    local root = liveMenu("tutorial")
    if not root then return nil end
    local vis, t = 1, nil
    pcall(function() vis = root["primaryText"]["Text"]("visible"):GetInt() end)
    if vis == 0 then return nil end
    pcall(function() t = root["primaryText"]["Text"]("text"):GetString() end)
    return cleanText(t)
end

-- Returns { label, action } for the object the tutorial wants, or nil.
local function tutorialTarget()
    local text = tutorialBannerText()
    if not text then return nil end
    local lower = text:lower()
    -- Buying happens in the Market, not on an island object ("Buy a Noggin
    -- egg" used to match the "egg" rule and point at the Breeding Structure).
    if lower:find("buy", 1, true) or lower:find("market", 1, true) or lower:find("purchase", 1, true) then
        return { "Market", function() pcall(game.loadStoreContext) end, verb = "open" }
    end
    local objs = islandObjects()
    for _, rule in ipairs(TUTORIAL_TARGETS) do
        if lower:find(rule[1], 1, true) then
            for _, o in ipairs(objs) do
                if o[1]:lower():find(rule[2], 1, true) then return o end
            end
        end
    end
    -- A monster named by species ("Feed your Noggin") or nickname.
    for _, o in ipairs(objs) do
        for _, n in ipairs({ o.species, o.name }) do
            if n and #n > 2 and lower:find(n:lower(), 1, true) then return o end
        end
    end
    return nil
end

local function openObjects()
    if popupOpen() or topOverlay() then say("Close the current screen first", true) return end
    local found = false
    for t = 0, MAX_STRUCTURE_TYPE do
        local id = 0
        pcall(function() id = game.getFirstStructureOfType(t) or 0 end)
        if id ~= 0 then found = true break end
    end
    if not found then say("Island objects are only available on the island view", true) return end
    openList("objects", "Island objects", islandObjects(), "Tab to move, Enter to select, Control Shift O to close.")
end

-- ---------------------------------------------------------------------------
-- Selected-object actions that have no on-screen button.
-- Tapping an object in the world does things the context bar can't: collect a
-- finished bakery's treats, collect coins from a monster. We centre the camera
-- on the selection with the game's own zoomCameraToObject, then click the
-- middle of the window.
-- ---------------------------------------------------------------------------
-- ---------------------------------------------------------------------------
-- Placing / moving an object (new monster from the nursery, MOVE button).
-- The game moves objects by dragging. Arrow keys centre the camera on the
-- object and drag it one step that way (native a11y_drag), then say whether
-- the spot is free (game.isSelectedObjectPlaceable). Tab reaches the context
-- bar's confirm / cancel buttons.
-- ---------------------------------------------------------------------------
local dragFn = resolve("a11y_drag")
local MOVE_STEP_X, MOVE_STEP_Y = 0.05, 0.07   -- one arrow press, as a fraction of the window

local function barContext()
    local c = nil
    pcall(function() c = manager:getContext() end)
    return c and tostring(c) or ""
end

local function placing()
    local m = false
    pcall(function() m = game.worldContext():isMovingNewObject() and true or false end)
    if not m then m = barContext():find("MOVE") ~= nil end
    return m
end

-- ---------------------------------------------------------------------------
-- Where the placed object is, relative to the nearest landmark.
-- Every world object keeps its grid tile in the variables pos_x / pos_y (the
-- game's own move code reads them; read here via native a11y_entity_tile). The island is drawn as a diamond: on
-- screen, left/right follows (x + y) and up/down follows (y - x). The signs
-- are learned from the first arrow presses (calibrate) instead of guessed.
-- ---------------------------------------------------------------------------
local function abs(v) return v < 0 and -v or v end

-- Lua can't read an entity's variables; the native a11y_entity_tile calls the
-- game's own pos_x / pos_y getters.
local entityTileFn = resolve("a11y_entity_tile")
local function entityTile(ent)
    if not ent or type(entityTileFn) ~= "function" then return nil end
    local ok, x, y = pcall(entityTileFn, ent)
    if ok then return x, y end
    return nil
end

-- The selected object's tile. While it is being moved, pos_x/pos_y still hold
-- the old spot; the live one is on the WorldContext (native a11y_move_tile,
-- the same fields game.isSelectedObjectPlaceable checks).
local moveTileFn = resolve("a11y_move_tile")
local function selectedTile()
    if placing() and type(moveTileFn) == "function" then
        local ok, x, y = pcall(function() return moveTileFn(game.worldContext()) end)
        if ok and x then return x, y end
    end
    return entityTile(selectedObject())
end

-- Screen direction of grid deltas: sx * (dx + dy) is right, sy * (dy - dx) is down.
-- Known from logged drags (right raises x + y, down raises y - x); a noisy
-- drag once flipped sy, so the signs are no longer re-learned.
local screenSign = { sx = 1, sy = 1, sxKnown = true, syKnown = true }

local function calibrate(dirX, dirY, gx, gy)
    if not gx or (gx == 0 and gy == 0) then return end
    if dirX ~= 0 and not screenSign.sxKnown and gx + gy ~= 0 then
        screenSign.sx = ((gx + gy > 0) == (dirX > 0)) and 1 or -1
        screenSign.sxKnown = true
        a11y_log("[where] calibrated sx=" .. screenSign.sx)
    elseif dirY ~= 0 and not screenSign.syKnown and gy - gx ~= 0 then
        screenSign.sy = ((gy - gx > 0) == (dirY > 0)) and 1 or -1
        screenSign.syKnown = true
        a11y_log("[where] calibrated sy=" .. screenSign.sy)
    end
end

local function directionWords(dx, dy)
    local h = screenSign.sx * (dx + dy)
    local v = screenSign.sy * (dy - dx)
    local hw = h > 0 and "right" or "left"
    local vw = v > 0 and "below" or "above"
    if abs(h) > 2 * abs(v) then return hw end
    if abs(v) > 2 * abs(h) then return vw end
    return vw .. " " .. hw
end

-- Every other structure and monster on the island, with its tile.
local function landmarks(noSkip)
    -- Skip the object being placed itself (by id, not tile: whatever blocks it
    -- shares its tile and must stay in the list).
    local skip = {}
    if not noSkip then
        pcall(function() skip[game.selectedMonsterId()] = true end)
        pcall(function() skip[game.selectedStructureId()] = true end)
    end
    local out = {}
    pcall(function()
        local isl = game.player():getActiveIsland()
        local ss = isl:structures()
        for i = 0, ss:size() - 1 do
            local id = ss[i]
            local ent = nil; pcall(function() ent = game.GetStructure(id) end)
            local x, y = entityTile(ent)
            if x and not skip[id] then
                local rank = entityIs(ent, "isObstacle") and 3 or (entityIs(ent, "isDecoration") and 2 or 1)
                out[#out + 1] = { x = x, y = y, name = structureLabel(id) or "structure", rank = rank }
            end
        end
        local ms = isl:monsters()
        for i = 0, ms:size() - 1 do
            local uid = ms[i]
            local ent = nil; pcall(function() ent = game.GetMonster(uid) end)
            local x, y = entityTile(ent)
            if x and not skip[uid] then
                local tid, sp = nil, nil
                pcall(function() tid = ent:monsterTypeId() end)
                pcall(function() sp = cleanText(LOC(game.getMonsterDataFromUniqueId(uid):name())) end)
                out[#out + 1] = { x = x, y = y, name = monsterLabel(uid), rank = 0, tid = tid, species = sp, uid = uid }
            end
        end
    end)
    return out
end

-- Which of a monster's Likes are met: each like's nearest copy on the island,
-- within FRIENDLY.LIKE_RADIUS of the monster (a guess until measured). The
-- island list is cached for a moment: the Monsters list asks for every row.
function FRIENDLY.__likeStatus(uid)
    local tid = nil
    pcall(function() tid = game.GetMonster(uid):monsterTypeId() end)
    if not tid then return nil end
    local names = FRIENDLY.__likeNames(tid)
    if #names == 0 then return nil end
    local mx, my = entityTile(game.GetMonster(uid))
    local now = clock()
    local cache = FRIENDLY.__islandCache
    if not cache or now - cache.t > 2 then
        cache = { t = now, list = landmarks(true) }
        FRIENDLY.__islandCache = cache
    end
    local out = { met = 0, total = #names, items = {} }
    for _, n in ipairs(names) do
        local best = nil
        for _, l in ipairs(cache.list) do
            if l.uid ~= uid and FRIENDLY.__isLike({ n }, l) then
                local d = mx and math.max(math.abs(l.x - mx), math.abs(l.y - my)) or nil
                if d and (not best or d < best) then best = d end
                if not mx and not best then best = -1 end
            end
        end
        local label = FRIENDLY.__likeDisplay and FRIENDLY.__likeDisplay[n] or n
        local text
        if not best then
            text = label .. ", not on your island"
        elseif best < 0 then
            text = label .. ", on your island"
        elseif best <= FRIENDLY.LIKE_RADIUS then
            out.met = out.met + 1
            text = label .. ", met, " .. (best <= 1 and "next to it" or (best .. " tiles away"))
        else
            text = label .. ", too far, " .. best .. " tiles away"
        end
        out.items[#out.items + 1] = text
    end
    return out
end

local whereLogged = false
-- "right of Small Bakery", "2 tiles above Noggy1", "on Small Rock".
local function whereText(cx, cy)
    local x, y = cx, cy
    if not x then x, y = selectedTile() end
    local list = x and landmarks() or {}
    menuState.lastWhere = { x = x, y = y, list = list }
    a11y_log("[where] tile=" .. tostring(x) .. "," .. tostring(y))
    if not whereLogged then
        whereLogged = true
        a11y_log("[where] selected tile=" .. tostring(x) .. "," .. tostring(y) .. " landmarks=" .. #list
            .. (list[1] and (" first=" .. list[1].name .. "@" .. list[1].x .. "," .. list[1].y) or ""))
    end
    if not x then return nil end
    local best, bestD = nil, nil
    for _, l in ipairs(list) do
        local d = abs(l.x - x); if abs(l.y - y) > d then d = abs(l.y - y) end
        if not bestD or d < bestD then best, bestD = l, d end
    end
    if not best then return nil end
    if bestD == 0 then return "on " .. best.name end
    local dir = directionWords(x - best.x, y - best.y)
    if bestD == 1 then return dir .. " of " .. best.name end
    return bestD .. " tiles " .. dir .. " of " .. best.name
end

local function spotText()
    -- Placing with the cursor (menuState.cursorMove): describe the cursor's
    -- tile, tested with the game's own check (menuState.freeAt).
    local c = menuState.cur
    if c and menuState.freeAt and placing() then
        local f = menuState.freeAt(c.x, c.y)
        local st = f == nil and "Spot unknown" or (f and "Free spot" or "Blocked")
        local wh = nil; pcall(function() wh = whereText(c.x, c.y) end)
        local lk = nil; pcall(function() lk = FRIENDLY.__likesNear(menuState.lastWhere) end)
        return joinSentences({ wh and (st .. ", " .. wh) or st, lk })
    end
    local ok, p = pcall(function() return game.isSelectedObjectPlaceable() end)
    local status = not ok and "Spot unknown" or (p and "Free spot" or "Blocked")
    local where = nil; pcall(function() where = whereText() end)
    local likes = nil; pcall(function() likes = FRIENDLY.__likesNear(menuState.lastWhere) end)
    return joinSentences({ where and (status .. ", " .. where) or status, likes })
end

-- Where the object being placed is on screen, relative to the centre the
-- camera was put on. Lets repeated arrow presses drag from the object's
-- current spot without re-centring the camera (which costs ~0.6s) each time.
local placeAt = { x = 0, y = 0, t = -100 }
local PLACE_RECENTRE_SECONDS = 4      -- re-centre after a pause (camera may have moved)
local PLACE_MAX_OFFSET = 0.3          -- or when the object drifts toward the edge
local DRAG_SETTLE_SECONDS = 0.35      -- native drag takes ~0.25s, then the game updates

local function arrow(dx, dy)
    if not placing() then
        a11y_log("[place] arrow ignored, context=" .. barContext())
        return
    end
    if menuState.cursorMove and menuState.cursorMove(dx, dy) then return end
    if type(dragFn) ~= "function" then say("Drag function unavailable", true) return end
    local now = clock()
    local function drag()
        local x, y = TAP_FX + placeAt.x, TAP_FY + placeAt.y
        local nx, ny = x + dx * MOVE_STEP_X, y + dy * MOVE_STEP_Y
        local bx, by = selectedTile()
        if not dragFn(x, y, nx, ny) then return end        -- previous drag still running
        placeAt.x, placeAt.y, placeAt.t = nx - TAP_FX, ny - TAP_FY, clock()
        later(DRAG_SETTLE_SECONDS, function()
            local ax, ay = selectedTile()
            -- The drag missed the object: later drags would start from the
            -- wrong spot too, so re-centre the camera on it next time.
            if bx and ax and ax == bx and ay == by then
                placeAt.t = -100
                a11y_log("[place] drag did not move the object")
                say("Did not move. " .. spotText(), true)
                return
            end
            if bx and ax then
                calibrate(dx, dy, ax - bx, ay - by)
                if screenSign.learn then screenSign.learn(dx * MOVE_STEP_X, dy * MOVE_STEP_Y, ax - bx, ay - by) end
            end
            say(spotText(), true)
        end)
    end
    local far = placeAt.x > PLACE_MAX_OFFSET or -placeAt.x > PLACE_MAX_OFFSET
        or placeAt.y > PLACE_MAX_OFFSET or -placeAt.y > PLACE_MAX_OFFSET
    if now - placeAt.t > PLACE_RECENTRE_SECONDS or far then
        placeAt.x, placeAt.y, placeAt.t = 0, 0, now
        local obj = selectedObject()
        if obj then pcall(function() game.worldContext():zoomCameraToObject(obj, TAP_ZOOM, TAP_SECONDS) end) end
        later(TAP_SECONDS + 0.2, drag)
    else
        drag()
    end
end

-- Announce entering placement once (checked on the context bar's tick).
local wasPlacing = false
local function watchPlacing()
    local now = placing()
    if now and not wasPlacing then
        a11y_log("[place] placing, context=" .. barContext())
        placeAt.t = -100                 -- new placement: centre the camera on first move
        menuState.cur = nil
        later(0.3, function()
            say("Placing " .. (selectedName() or "object") .. ". " .. spotText()
                .. ". Arrow keys move it, Enter places it, Escape cancels.", false)
        end)
    end
    if not now and wasPlacing then menuState.cur = nil end
    wasPlacing = now
end
contextbarHook = watchPlacing

-- ---------------------------------------------------------------------------
-- Points of interest ([ and ] while placing): jump the object to a free tile
-- next to another object ("place it next to the Noggin").
-- The move is a series of drags. Screen offset per tile is learned from what
-- drags actually do: screen x = A * (dx + dy), screen y = B * (dy - dx), in
-- window fractions. Each drag is followed by reading the live tile, so errors
-- correct themselves on the next drag.
-- ---------------------------------------------------------------------------
local poiStep, spotStep
do
    local MAX_DRAG = 0.3                -- longest single drag from the centre
    local MOVE_TRIES = 6                -- drags allowed to reach one tile
    local NEIGHBOURS = {                -- tried in order until one is free
        { 1, 0 }, { 0, 1 }, { -1, 0 }, { 0, -1 }, { 1, 1 }, { -1, -1 }, { 1, -1 }, { -1, 1 },
        { 2, 0 }, { 0, 2 }, { -2, 0 }, { 0, -2 }, { 3, 0 }, { 0, 3 }, { -3, 0 }, { 0, -3 },
    }
    local poi = { list = nil, index = 0, t = -100, gen = 0, target = nil, spots = nil, spot = 0 }
    local setTileFn = resolve("a11y_set_move_tile")
    local SPOT_RADIUS = 4               -- look this many tiles around the object
    local MAX_SPOTS = 12

    -- Is (x, y) free for the object being placed? Writes the live tile, asks
    -- the game's own check, and restores it in the same call (no frame sees it).
    local function freeAt(x, y)
        if type(setTileFn) ~= "function" or type(moveTileFn) ~= "function" then return nil end
        local free = nil
        pcall(function()
            local wc = game.worldContext()
            local ox, oy = moveTileFn(wc)
            if not ox then return end
            setTileFn(wc, x, y)
            local ok, p = pcall(function() return game.isSelectedObjectPlaceable() end)
            setTileFn(wc, ox, oy)
            free = ok and p and true or false
        end)
        return free
    end

    -- The placing cursor: arrows move a tile position the mod keeps, tested
    -- with freeAt, so nothing in the game moves until Enter (menuState.placeHere).
    -- The grid is a diamond: one tile is half a step on screen, so Right
    -- alternates (1,0) / (0,1) and Down (0,1) / (-1,0), which goes straight.
    menuState.freeAt = freeAt
    menuState.setTile = setTileFn
    function menuState.cursorMove(dirX, dirY)
        if type(setTileFn) ~= "function" or type(moveTileFn) ~= "function" then return false end
        local c = menuState.cur
        if not c then
            local x, y = selectedTile()
            if not x then return false end
            c = { x = x, y = y, h = false, v = false }
            menuState.cur = c
        end
        local mx, my = 0, 0
        if dirX ~= 0 then
            c.h = not c.h
            if c.h then mx = dirX else my = dirX end
        else
            c.v = not c.v
            if c.v then my = dirY else mx = -dirY end
        end
        c.x, c.y = c.x + mx, c.y + my
        say(spotText(), true)
        return true
    end
    -- Where to describe from: the cursor while placing with it, else the object.
    function menuState.cursorTile()
        local c = menuState.cur
        if c then return c.x, c.y end
        return selectedTile()
    end

    -- Free tiles around the target, nearest rings first. nil = can't probe.
    local function freeSpots(target)
        local out = {}
        for d = 1, SPOT_RADIUS do
            for dx = -d, d do
                for dy = -d, d do
                    if (abs(dx) == d or abs(dy) == d) and #out < MAX_SPOTS then
                        local f = freeAt(target.x + dx, target.y + dy)
                        if f == nil then return nil end
                        if f then out[#out + 1] = { x = target.x + dx, y = target.y + dy } end
                    end
                end
            end
            if #out >= MAX_SPOTS then break end
        end
        return out
    end

    screenSign.learn = function(fx, fy, gx, gy)
        if gx + gy ~= 0 and abs(fx) > 0.02 then
            local a = fx / (gx + gy)
            screenSign.A = screenSign.A and (screenSign.A + a) / 2 or a
        end
        if gy - gx ~= 0 and abs(fy) > 0.02 then
            local b = fy / (gy - gx)
            screenSign.B = screenSign.B and (screenSign.B + b) / 2 or b
        end
    end

    -- Drag the object by (fx, fy) of the window, re-centring the camera on it
    -- first when the drag would leave the safe middle of the screen.
    local function dragBy(gen, fx, fy, done)
        local function go()
            if gen ~= poi.gen then return end
            local x, y = TAP_FX + placeAt.x, TAP_FY + placeAt.y
            local bx, by = selectedTile()
            if not dragFn(x, y, x + fx, y + fy) then later(0.2, go) return end
            placeAt.x, placeAt.y, placeAt.t = placeAt.x + fx, placeAt.y + fy, clock()
            later(DRAG_SETTLE_SECONDS, function()
                if gen ~= poi.gen then return end
                local ax, ay = selectedTile()
                if bx and ax then screenSign.learn(fx, fy, ax - bx, ay - by) end
                done()
            end)
        end
        local nx, ny = placeAt.x + fx, placeAt.y + fy
        if clock() - placeAt.t > PLACE_RECENTRE_SECONDS or abs(nx) > 0.4 or abs(ny) > 0.35 then
            placeAt.x, placeAt.y, placeAt.t = 0, 0, clock()
            local obj = selectedObject()
            if obj then pcall(function() game.worldContext():zoomCameraToObject(obj, TAP_ZOOM, TAP_SECONDS) end) end
            later(TAP_SECONDS + 0.2, go)
        else
            go()
        end
    end

    -- Drag until the live tile is (tx, ty); done(reached).
    local function moveTo(gen, tx, ty, tries, done)
        if gen ~= poi.gen then return end
        local cx, cy = selectedTile()
        if not cx then done(false) return end
        if cx == tx and cy == ty then done(true) return end
        if tries <= 0 then done(false) return end
        local dx, dy = tx - cx, ty - cy
        local fx, fy
        if screenSign.A and screenSign.B then
            fx, fy = screenSign.A * (dx + dy), screenSign.B * (dy - dx)
        else
            fx, fy = 0.12, 0.12             -- first time: a diagonal drag teaches both axes
        end
        local m = abs(fx) > abs(fy) and abs(fx) or abs(fy)
        if m > MAX_DRAG then fx, fy = fx * MAX_DRAG / m, fy * MAX_DRAG / m end
        dragBy(gen, fx, fy, function() moveTo(gen, tx, ty, tries - 1, done) end)
    end
    function menuState.dragTo(x, y, done)
        poi.gen = poi.gen + 1
        moveTo(poi.gen, x, y, MOVE_TRIES + 4, done)
    end

    local function placeable()
        local ok, p = pcall(function() return game.isSelectedObjectPlaceable() end)
        return ok and p
    end

    local function relation(target)
        local x, y = menuState.cursorTile()
        if not x then return "near " .. target.name end
        local dx, dy = x - target.x, y - target.y
        local d = abs(dx); if abs(dy) > d then d = abs(dy) end
        if d == 0 then return "on " .. target.name end
        local dir = directionWords(dx, dy)
        if d == 1 then return dir .. " of " .. target.name end
        return d .. " tiles " .. dir .. " of " .. target.name
    end

    -- ". Likes nearby: ..." for the spot reached (FRIENDLY.__likesNear).
    local function likesTail()
        local x, y = menuState.cursorTile()
        local t = nil
        if x then pcall(function() t = FRIENDLY.__likesNear({ x = x, y = y, list = landmarks() }) end) end
        return t and (". " .. t) or ""
    end

    local function goToSpot(gen, target)
        local sp = poi.spots[poi.spot]
        if type(setTileFn) == "function" then
            -- Cursor: just point at the free spot; Enter moves the object there.
            local c = menuState.cur or { h = false, v = false }
            c.x, c.y = sp.x, sp.y
            menuState.cur = c
            local tl = ", " .. poi.spot .. " of " .. #poi.spots .. (poi.suffix or "")
            poi.suffix = nil
            local pre = poi.prefix or ""
            poi.prefix = nil
            say(pre .. "Free spot, " .. relation(target) .. likesTail() .. tl, true)
            return
        end
        moveTo(gen, sp.x, sp.y, MOVE_TRIES, function(reached)
            if gen ~= poi.gen then return end
            local tail = ", " .. poi.spot .. " of " .. #poi.spots .. (poi.suffix or "")
            poi.suffix = nil
            if reached and placeable() then say("Free spot, " .. relation(target) .. likesTail() .. tail, true)
            else say(spotText() .. tail, true) end
        end)
    end

    -- Probe the free tiles around the target, then move to the first. Without
    -- probing, try neighbouring tiles one by one by dragging.
    local function jumpTo(gen, target)
        poi.target, poi.spots, poi.spot = target, freeSpots(target), 1
        if poi.spots then
            if #poi.spots == 0 then
                poi.prefix = nil
                say(target.name .. ". No free spots near it", true)
                return
            end
            a11y_log("[poi] " .. #poi.spots .. " free spots near " .. target.name)
            if #poi.spots > 1 then poi.suffix = ". Comma and period for the other free spots" end
            goToSpot(gen, target)
            return
        end
        if poi.prefix then say(poi.prefix, true) poi.prefix = nil end
        local i = 0
        local function nextSpot()
            if gen ~= poi.gen then return end
            i = i + 1
            local off = NEIGHBOURS[i]
            if not off then
                say("No free spot found next to " .. target.name .. ". " .. spotText(), true)
                return
            end
            moveTo(gen, target.x + off[1], target.y + off[2], MOVE_TRIES, function(reached)
                if gen ~= poi.gen then return end
                if reached and placeable() then
                    a11y_log("[poi] free at offset " .. off[1] .. "," .. off[2] .. " of " .. target.name)
                    say("Free spot, " .. relation(target) .. likesTail(), true)
                else
                    nextSpot()
                end
            end)
        end
        nextSpot()
    end

    spotStep = function(dir)
        if not placing() then return end
        if not poi.spots or #poi.spots == 0 or not poi.target then
            say("Press a bracket to pick an object first", true)
            return
        end
        poi.spot = poi.spot + dir
        if poi.spot > #poi.spots then poi.spot = 1 end
        if poi.spot < 1 then poi.spot = #poi.spots end
        poi.gen = poi.gen + 1
        goToSpot(poi.gen, poi.target)
    end

    poiStep = function(dir)
        if not placing() then
            say("Brackets jump between objects while you are placing something", true)
            return
        end
        if type(dragFn) ~= "function" or type(moveTileFn) ~= "function" then
            say("Jumping is unavailable", true)
            return
        end
        if not poi.list or clock() - poi.t > 30 then
            -- Monsters, then buildings, decorations, and trees/rocks last.
            local list = landmarks()
            for i, l in ipairs(list) do l.order = i end
            table.sort(list, function(a, b)
                if a.rank ~= b.rank then return a.rank < b.rank end
                return a.order < b.order
            end)
            poi.list, poi.index = list, 0
        end
        poi.t = clock()
        local n = #poi.list
        if n == 0 then say("No objects to jump to", true) return end
        poi.index = poi.index + dir
        if poi.index > n then poi.index = 1 end
        if poi.index < 1 then poi.index = n end
        poi.gen = poi.gen + 1
        local target = poi.list[poi.index]
        -- Said together with the spot it finds (jumpTo), so the free-spot
        -- message doesn't cut the landmark's name off.
        poi.prefix = target.name .. ", " .. poi.index .. " of " .. n .. ". "
        local gen = poi.gen
        later(0.05, function() jumpTo(gen, target) end)
    end
end

-- The checkmark / X drawn next to the object being placed are world sprites,
-- not menu buttons. They do what ContextBar.confirm_move / cancel_move do:
-- close the "show grid" popup, then game.moveObjectDone(true/false).
local function closeGridPopup()
    local top = currentPopupName()
    if top == "showgrid_popup" or top == "volume_popup" then pcall(game.popPopUp) end
end

local function confirmPlacement()
    local ok, p = pcall(function() return game.isSelectedObjectPlaceable() end)
    if ok and not p then say("Blocked here. Move it with the arrow keys first.", true) return end
    closeGridPopup()
    local done, err = pcall(function() game.moveObjectDone(true) end)
    if not done then a11y_log("[place] moveObjectDone(true) failed: " .. tostring(err)) say("Could not place", true) return end
    -- ContextBar.lua confirm_move then leaves the MOVE bar: a monster goes back
    -- to its own actions, anything else to the island's. Without this the bar
    -- stays in MOVE and placing never ends.
    local isMonster = false
    pcall(function() isMonster = game.selectedObjIsMonster() and true or false end)
    local ctxOk = isMonster and pcall(function() manager:setContext("MONSTER") end)
    if not ctxOk then pcall(function() manager:setContext(manager:getDefaultContext()) end) end
    later(0.3, function()
        if placing() then
            a11y_log("[place] still placing after confirm (" .. barContext() .. "), back to the island")
            pcall(function() manager:setContext(manager:getDefaultContext()) end)
            closeGridPopup()
        end
    end)
    say("Placed", true)
end

local function cancelPlacement()
    closeGridPopup()
    pcall(function() game.moveObjectDone(false) end)
    pcall(function() manager:setContext(manager:getDefaultContext()) end)
    say("Placement cancelled", true)
end

-- Enter while placing: move the object to the cursor, then place it. First
-- write the tile straight into the game (as freeAt does for a moment); if the
-- game doesn't keep it, drag there instead.
function menuState.placeHere()
    local c = menuState.cur
    if not c then confirmPlacement() return end
    local f = menuState.freeAt and menuState.freeAt(c.x, c.y)
    if f == false then say("Blocked here. Move with the arrow keys first.", true) return end
    local tx, ty = c.x, c.y
    local wrote = pcall(function() menuState.setTile(game.worldContext(), tx, ty) end)
    later(0.15, function()
        if not placing() then return end
        local lx, ly = nil, nil
        pcall(function() lx, ly = moveTileFn(game.worldContext()) end)
        if wrote and lx == tx and ly == ty then
            a11y_log("[place] direct tile write held at " .. tx .. "," .. ty)
            menuState.cur = nil
            confirmPlacement()
            later(0.5, function()
                local ex, ey = entityTile(selectedObject())
                a11y_log("[place] after placing, object tile " .. tostring(ex) .. "," .. tostring(ey)
                    .. " (wanted " .. tx .. "," .. ty .. ")")
            end)
            return
        end
        a11y_log("[place] direct tile write didn't hold (" .. tostring(lx) .. "," .. tostring(ly) .. "), dragging")
        say("Moving it there", true)
        menuState.dragTo(tx, ty, function(reached)
            if reached then
                menuState.cur = nil
                confirmPlacement()
            else
                say("Couldn't move it all the way. " .. spotText(), true)
            end
        end)
    end)
end

local function deselect()
    local name = nil
    pcall(function() name = selectedName() end)
    pcall(function() game.deselectSelectedObject() end)
    pcall(function() manager:setContext(manager:getDefaultContext()) end)
    say(name and (name .. " deselected") or "Deselected", true)
end

-- ---------------------------------------------------------------------------
-- Navigation: Tab / Shift+Tab move between controls, Enter activates.
-- Driven by native hotkeys through queue_lua (a safe frame boundary on the game
-- thread). Context: an open list (Places/Objects), else a tutorial popup, else
-- the top popup, else the selected object's actions, else the island (context
-- bar + HUD). Controls are re-scanned on every action, so we never touch a
-- stale object. Virtual entries ({ label, fn }) sit alongside real elements.
-- ---------------------------------------------------------------------------
local nav = { items = {}, labels = {}, index = 0, key = nil, base = nil, remembered = {} }

-- Roots to navigate, a context key for the current screen, and virtual entries.
local function navContext()
    -- Tutorial popups sit on their own layer, not the popup stack, and only
    -- tick while shown.
    for _, n in ipairs({ "popup_tutorial", "popup_tutorial_streamlined" }) do
        local r = liveMenu(n)
        if r then return { r }, "popup:" .. n, {} end
    end
    if placing() then
        -- Confirm / Cancel are world sprites: offer them as entries, plus the
        -- Show Grid toggle that opens alongside.
        local roots = {}
        for f in pairs(menuState.sidePanels) do
            local r = liveMenu(f)
            if r then roots[#roots + 1] = r end
        end
        return roots, "placing", {
            { "Confirm placement", confirmPlacement },
            { "Check spot", function() say(spotText(), true) end },
            { "Cancel placement", cancelPlacement },
        }
    end
    -- After placing or cancelling, the Show Grid toggle can stay reported as the
    -- top popup, and a selected decoration brings its Decoration Size panel.
    -- Outside placement they are not screens: show the island or selection.
    local gridLeftover = menuState.sidePanels[currentPopupName()]
    if not popupOpen() or gridLeftover then
        popupStack = {}
        local inEmpty = FRIENDLY.__emptyPopup()
        if inEmpty then return { inEmpty.el }, "popup:" .. inEmpty.name, {} end
        local ov, ovName, ovFile = topOverlay()
        if ov then
            -- Screens can share one root (a reward popup over the Hype game):
            -- list only the newest screen's own element.
            if ovName == ovFile then
                local own = findNamed(ov, ovFile, 3)
                if own and isVisible(own) then ov = own end
            end
            return { ov }, "popup:" .. ovName, {}
        end
        -- No popup or overlay: navigate the island.
        local cb = liveMenu("contextbar")
        if objectSelected() then
            -- Only the selection's own actions: no HUD bleed-through.
            local name = selectedName() or "object"
            local virtual = {
                { "Tap " .. name, tapSelected },
                { "Deselect " .. name, deselect },
            }
            -- Its bar (Info, Sell, Move...) plus a Decoration Size / Show Grid panel.
            local roots = {}
            if cb then roots[#roots + 1] = cb end
            local sp = liveMenu("scale_popup")
            if sp then roots[#roots + 1] = sp end
            return roots, "selected:" .. name, virtual
        end
        -- Nothing selected: main bar (Market, Options...), the HUD, then the
        -- island's structures and monsters, so Tab alone reaches everything.
        local roots = {}
        if cb then roots[#roots + 1] = cb end
        local ok, hud = pcall(game.getHUD); if ok and hud then roots[#roots + 1] = hud end
        local club = liveMenu("hud_clubbox")
        if club then roots[#roots + 1] = club end
        local virtual = {}
        local target = tutorialTarget()
        if target then virtual[1] = { "Tutorial: " .. target[1], target[2], first = true, group = "Tutorial" } end
        -- Rebuilding every building and monster with its status takes 30-60 ms;
        -- reuse it for 1.5 seconds so quick Tabbing doesn't lag.
        local cache = FRIENDLY.__objCache
        if not cache or clock() - cache.t > 1.5 then
            cache = { t = clock(), list = islandObjects() }
            FRIENDLY.__objCache = cache
        end
        for _, o in ipairs(cache.list) do virtual[#virtual + 1] = { o[1], o[2], group = OBJECT_GROUPS[o.rank] } end
        return roots, "island", virtual
    end
    -- A real popup is open. Reconcile the stack with the live top name in case a
    -- popup closed via a path we didn't hook (Esc, setContext, etc.).
    local name = currentPopupName()
    while #popupStack > 0 and tostring(popupStack[#popupStack].id) ~= name do
        popupStack[#popupStack] = nil
    end
    -- Prefer live roots from the menus' own ticks (works for popups opened
    -- from C++ too), and of those the newest: the game can keep naming the
    -- Bakery while its "Would you like to bake...?" confirmation is on top.
    local top2 = ""; pcall(function() top2 = tostring(game.getTopPopUpName()) end)
    local best, bestKey, bestT = nil, nil, -1
    local function consider(root, key, file)
        local m = file and menus[file]
        if root and m and (m.appeared or 0) > bestT then best, bestKey, bestT = root, key, m.appeared or 0 end
    end
    consider(liveMenu(name), name, name)
    consider(liveMenu(top2), top2, top2)
    local ov, ovKey, ovFile = topOverlay()
    consider(ov, ovKey, ovFile)
    if best then
        -- Popups pushed from Lua (Options' Screen Size, Language) are built
        -- inside the screen below them, all under one shared root. List only
        -- the popup's own element, or the screen behind leaks in (and pressing
        -- Language there stacks a second popup on top).
        -- (Not for a reused popup whose newest panel topOverlay already picked.)
        local m = menus[bestKey]
        local own = bestKey and not (m and m.panel) and findNamed(best, bestKey, 6)
        if own and isVisible(own) then best = own end
        return { best }, "popup:" .. bestKey, {}
    end
    local top = popupStack[#popupStack]
    if top and top.obj then
        return { top.obj }, "popup:" .. tostring(top.id), {}
    end
    -- No handle at all: stay silent rather than navigate the island behind it.
    return {}, "popup:" .. name, {}
end

local function navEnsure()
    local roots, key, virtual = navContext()
    nav.items, nav.labels, nav.groups = {}, {}, {}
    for _, r in ipairs(roots) do
        local items, labels, groups = scanClickables(r)
        for i = 1, #items do
            nav.items[#nav.items + 1] = items[i]
            nav.labels[#nav.labels + 1] = labels[i]
            nav.groups[#nav.groups + 1] = groups[i] or "Buttons"
        end
    end
    for _, v in ipairs(virtual) do
        if v.first then                          -- e.g. the tutorial target: before everything
            table.insert(nav.items, 1, { virtual = v[2] })
            table.insert(nav.labels, 1, v[1])
            table.insert(nav.groups, 1, v.group or "Actions")
        else
            nav.items[#nav.items + 1] = { virtual = v[2] }
            nav.labels[#nav.labels + 1] = v[1]
            nav.groups[#nav.groups + 1] = v.group or "Actions"
        end
    end
    -- On the island, show one group at a time (Buttons, Buildings, Monsters,
    -- Decorations, Trees and rocks); [ and ] switch groups. The tutorial entry
    -- stays at the top of every group.
    nav.groupOrder = {}
    if key == "island" then
        local seen = {}
        for _, g in ipairs(nav.groups) do
            if g ~= "Tutorial" and not seen[g] then seen[g] = true; nav.groupOrder[#nav.groupOrder + 1] = g end
        end
        if #nav.groupOrder > 1 then
            if not nav.group or not seen[nav.group] then nav.group = nav.groupOrder[1] end
            local items, labels, groups = {}, {}, {}
            for i = 1, #nav.items do
                if nav.groups[i] == nav.group or nav.groups[i] == "Tutorial" then
                    items[#items + 1], labels[#labels + 1], groups[#groups + 1] = nav.items[i], nav.labels[i], nav.groups[i]
                end
            end
            nav.items, nav.labels, nav.groups = items, labels, groups
            key = key .. "@" .. nav.group
        else
            nav.groupOrder = {}
        end
    end
    -- Reset focus when the screen changes. The item count is part of the key
    -- so a context bar that changes buttons resets too.
    -- Remember the place on the screen we leave and restore it on return
    -- (deselecting the Bakery puts you back on the Bakery, not at the top).
    local base = key
    key = key .. "#" .. #nav.items
    if key ~= nav.key then
        if nav.base and nav.base ~= base then nav.remembered[nav.base] = nav.index end
        local saved = nav.base ~= base and nav.remembered[base] or nil
        nav.index = (saved and saved <= #nav.items) and saved or 0
    end
    nav.key, nav.base = key, base
    return #nav.items > 0
end

-- edge: Home/End, jump to the first (dir < 0) or last (dir > 0) item.
local function navMove(dir, edge)
    a11y_log("[timing] Tab code starts")
    if FRIENDLY.__keysLocked() then return end
    if vmenu.active then                        -- Places / Objects list takes precedence
        local n = #vmenu.items
        vmenu.index = edge and (dir > 0 and n or 1) or (vmenu.index + dir)
        if vmenu.index > n then vmenu.index = 1 end
        if vmenu.index < 1 then vmenu.index = n end
        local it = vmenu.items[vmenu.index]
        local label = it[1]
        if it.live then pcall(function() label = it.live() or label end) end
        say(label .. ", " .. vmenu.index .. " of " .. n, true)
        return
    end
    -- Placing: no list to move through. Say where it is and what to press.
    if placing() and (not popupOpen() or menuState.sidePanels[currentPopupName()]) then
        say(spotText() .. ". Enter places it, Escape cancels.", true)
        return
    end
    local t0 = clock()
    if not navEnsure() then                     -- nothing navigable
        if popupOpen() then say("Nothing to navigate in this dialog", true) end
        return
    end
    local took = clock() - t0                   -- find screens that make Tab feel slow
    if took > 0.03 then a11y_log(string.format("[nav] slow scan %.0f ms, %d items, %s", took * 1000, #nav.items, tostring(nav.key))) end
    local prev = nav.index
    nav.index = edge and (dir > 0 and #nav.items or 1) or (nav.index + dir)
    if nav.index > #nav.items then nav.index = 1 end
    if nav.index < 1 then nav.index = #nav.items end
    -- Entering a named list ("Monster 1 list") says its name first.
    local g = nav.groups[nav.index]
    local prefix = (g and g:find(" list$") and g ~= nav.groups[prev]) and (g .. ". ") or ""
    a11y_log("[timing] Tab text sent to speech")
    say(prefix .. (nav.labels[nav.index] or "item") .. ", " .. nav.index .. " of " .. #nav.items, true)
end

-- [ and ] when not placing: jump between groups of the list (buttons,
-- buildings, monsters, decorations, trees and rocks), like headings.
local function groupJump(groups, index, n, dir)
    local starts = {}
    for i = 1, n do
        if i == 1 or groups[i] ~= groups[i - 1] then starts[#starts + 1] = i end
    end
    if #starts < 2 then return nil end
    if dir > 0 then
        for _, st in ipairs(starts) do if st > index then return st end end
        return starts[1]
    end
    for k = #starts, 1, -1 do if starts[k] < index then return starts[k] end end
    return starts[#starts]
end

local function navGroupJump(dir)
    if vmenu.active then
        local groups = {}
        for i, it in ipairs(vmenu.items) do groups[i] = OBJECT_GROUPS[it.rank] or "Items" end
        local n = #vmenu.items
        local to = groupJump(groups, vmenu.index, n, dir)
        if not to then navMove(dir) return end
        vmenu.index = to
        local it = vmenu.items[to]
        local label = it[1]
        if it.live then pcall(function() label = it.live() or label end) end
        say(groups[to] .. ": " .. label .. ", " .. to .. " of " .. n, true)
        return
    end
    if not navEnsure() then return end
    local order = nav.groupOrder or {}
    if #order < 2 then
        local to = groupJump(nav.groups, nav.index, #nav.items, dir)
        if not to then navMove(dir) return end
        nav.index = to
        say(nav.groups[to] .. ": " .. (nav.labels[to] or "item") .. ", " .. to .. " of " .. #nav.items, true)
        return
    end
    local cur = 1
    for i, g in ipairs(order) do if g == nav.group then cur = i end end
    cur = cur + dir
    if cur > #order then cur = 1 end
    if cur < 1 then cur = #order end
    nav.group = order[cur]
    navEnsure()                                 -- refilter; restores this group's place
    local n = #nav.items
    if nav.index < 1 then nav.index = 1 end
    say(nav.group .. ", " .. n .. (n == 1 and " item. " or " items. ")
        .. (nav.labels[nav.index] or "item") .. ", " .. nav.index .. " of " .. n, true)
end

-- Press an element the way the game does. Direct touch calls work for most
-- buttons; list rows like bakery foods only answer the game's own keyboard
-- path (template_barbutton's gotMsgKeyUp), DoStoredScript on the Touch.
local function pressElement(el)
    menuState.touch()                           -- the press may free this screen
    local ok, err = pcall(function()
        el.Touch:onTouchDown(el, 0, 0)
        el.Touch:onTouchUp(el, 0, 0)
    end)
    if ok then return true end
    a11y_log("[nav] direct touch failed (" .. tostring(err) .. "), trying DoStoredScript")
    pcall(function() el["Touch"]:DoStoredScript("onTouchDown") end)
    local ok2, err2 = pcall(function() el["Touch"]:DoStoredScript("onTouchUp") end)
    if not ok2 then a11y_log("[nav] DoStoredScript failed: " .. tostring(err2)) end
    return ok2
end

-- Enter is also the game's own confirm key: buttons mapped to it (Yes, OK)
-- press themselves when Enter is released. So after we press No, the game
-- would press Yes on key up and win. Disarm those buttons for a moment: clear
-- the key they caught and switch their touch off until Enter is released.
--
-- Element handles must never outlive the frame: pressing a button can close
-- the screen (Market, a confirmation), and writing to a freed element crashes
-- the game outright (pcall can't catch it). So mute only on menus that ticked
-- just now, BEFORE the press, and switch back on from inside each menu's own
-- tick (runPending perRoot), matching buttons by identity, not by a kept handle.
do
local MUTE_SECONDS = 0.6
local function eachEnterButton(root, confirmKey, fn)
    local budget = 3000
    local function walk(el, depth)
        if depth > 12 or budget <= 0 then return end
        budget = budget - 1
        pcall(function()
            local tv = el:templateVars()
            if tonumber(tv.buttonMapping) == confirmKey or tonumber(tv.buttonMappingAlt) == confirmKey then fn(el) end
        end)
        local kids = nil; pcall(function() kids = el:elements() end)
        local n = 0; pcall(function() n = kids:size() end)
        for i = 0, n - 1 do
            local c = nil; pcall(function() c = kids[i] end)
            if c then walk(c, depth + 1) end
        end
    end
    pcall(walk, root, 0)
end

function nav.muteGameEnter(skip)
    local confirmKey = nil
    pcall(function() confirmKey = tonumber(game.confirmButton()) end)
    if not confirmKey or confirmKey == 0 then return end
    local now, ids, count = clock(), {}, 0
    local skipId = skip and tostring(skip)
    for _, m in pairs(menus) do
        if menuState.usable(m) then
            eachEnterButton(m.root, confirmKey, function(el)
                if tostring(el) == skipId then return end
                pcall(function() el("buttonDown"):SetInt(0) end)
                local touch = el["Touch"]
                if touch("enabled"):GetInt() ~= 0 then
                    touch("enabled"):SetInt(0)
                    ids[tostring(el)] = true
                    count = count + 1
                end
            end)
        end
    end
    if count == 0 then return end
    a11y_log("[nav] muted " .. count .. " Enter-mapped button(s)")
    local t = now + MUTE_SECONDS
    pending[#pending + 1] = { t = t, stop = t + 1.5, perRoot = true, done = {}, fn = function(root)
        eachEnterButton(root, confirmKey, function(el)
            if ids[tostring(el)] then
                ids[tostring(el)] = nil
                pcall(function() el["Touch"]("enabled"):SetInt(1) end)
            end
        end)
    end }
end

-- Enter can open a screen (Bread -> "Would you like to bake Bread?"), and
-- that new screen's Yes is mapped to Enter too: the game pressed it when the
-- same Enter was released (or auto-repeated), buying before you chose. While
-- Enter is physically down (a11y_key_down; 0.8 seconds if unavailable) and a
-- quarter second after, keep every Enter-mapped button on every screen
-- muted, then switch back on the ones this guard muted. Matched by identity
-- each tick; no handle is kept.
function nav.guardEnter()
    local confirmKey = nil
    pcall(function() confirmKey = tonumber(game.confirmButton()) end)
    if not confirmKey or confirmKey == 0 then return end
    local keyDown = resolve("a11y_key_down")
    local start = clock()
    local ids, releasedAt = {}, nil
    local p = { t = start, stop = start + 3, everyTick = true }
    p.fn = function(root, now)
        local held = nil
        if type(keyDown) == "function" then
            local ok, v = pcall(keyDown, 13)
            if ok and v ~= nil then held = v and true or false end
        end
        if held == nil then held = now - start < 0.8 end
        if held then releasedAt = nil; p.stop = now + 1 else releasedAt = releasedAt or now end
        local mute = releasedAt == nil or now - releasedAt < 0.25
        eachEnterButton(root, confirmKey, function(el)
            local id = tostring(el)
            if mute then
                pcall(function() el("buttonDown"):SetInt(0) end)
                pcall(function()
                    local touch = el["Touch"]
                    if touch("enabled"):GetInt() ~= 0 then
                        touch("enabled"):SetInt(0)
                        if not ids[id] then a11y_log("[nav] Enter held: holding back " .. tostring(elementName(el))) end
                        ids[id] = true
                        isClickable.heldBack[id] = true
                    end
                end)
            elseif ids[id] then
                ids[id] = nil
                isClickable.heldBack[id] = nil
                pcall(function() el["Touch"]("enabled"):SetInt(1) end)
            end
        end)
        if not mute and next(ids) == nil then p.finished = true end
    end
    pending[#pending + 1] = p
end
end -- do (Enter muting)

-- After picking a monster on the breeding screen: what is chosen, what next.
function nav.breedingStatus()
    local root = liveMenu("breeding_v2")
    if not root then return end
    local a, b, heart = FRIENDLY.__social.breedPicks(root)
    local h = heart and elementText(heart)
    if a and b then
        local hint = nil
        pcall(function()
            hint = FRIENDLY.__pairHint(FRIENDLY.__pickTid(findNamed(root, "LeftMonsterSelect")),
                FRIENDLY.__pickTid(findNamed(root, "RightMonsterSelect")))
        end)
        say("Breeding " .. a .. " with " .. b .. (hint and (", " .. hint) or "") .. ". Now press " .. ((h and h ~= "") and h or "the Breed button")
            .. ", near the top of the list.", true)
    elseif a or b then
        say((a or b) .. " picked as " .. (a and "monster 1" or "monster 2") .. ". Now choose "
            .. (a and "monster 2" or "monster 1") .. ".", true)
    else
        say("No monsters picked.", true)
    end
end

-- After picking an island on the Map: its details (Main/IslandName and
-- IslandInfo: collected counts, cost, requirements), then focus on GO.
-- Keep tapping the hatching fanfare's egg until it cracks (7 taps in all).
-- Each tap finds the egg afresh: no handle is kept across frames.
function nav.crackEgg(n)
    later(0.25, function()
        local root = liveMenu("popup_hatch_monster_fanfare")
        local egg = root and findNamed(root, "EggImage", 4)
        if not egg or not isClickable(egg) or n > 9 then
            if n > 1 then nav.hatchedSay(0) end
            return
        end
        pressElement(egg)
        nav.crackEgg(n + 1)
    end)
end

-- Whether any visible text under el (3 levels) says "continue".
function FRIENDLY.__saysContinue(el, depth)
    if depth > 3 then return false end
    local kids = nil; pcall(function() kids = el:elements() end)
    if not kids then return false end
    local n = 0; pcall(function() n = kids:size() end)
    for i = 0, n - 1 do
        local c = nil; pcall(function() c = kids[i] end)
        if c then
            local vis = 1; pcall(function() vis = c.Text("visible"):GetInt() end)
            local t = vis ~= 0 and elementText(c) or nil
            if t and t:lower():find("continue", 1, true) then return true end
            if FRIENDLY.__saysContinue(c, depth + 1) then return true end
        end
    end
    return false
end

-- "You discovered Potbelly! Class: Natural", from the fanfare once it shows.
function FRIENDLY.__hatchedText(panel)
    local function txt(nm) return elementText(findNamed(panel, nm, 1)) end
    local name = txt("PostNotificationMonsterName")
    if not name then return nil end
    local parts = { (txt("PostNotificationTop") or "You discovered") .. " " .. name }
    local cls = txt("PostNotificationClass")
    if cls then parts[#parts + 1] = cls end
    return table.concat(parts, ", ")
end
function nav.hatchedSay(n)
    later(0.5, function()
        local root = liveMenu("popup_hatch_monster_fanfare")
        if not root then return end
        local panel = findNamed(root, "popup_hatch_monster_fanfare", 3)
        local t = panel and FRIENDLY.__hatchedText(panel)
        if t then
            say(t .. ". Tab to Continue", true)
        elseif n < 12 then
            nav.hatchedSay(n + 1)
        else
            say("The egg cracked open. Tab to Continue", true)
        end
    end)
end

function nav.mapInfo()
    local root = liveMenu("map_base")
    local main = root and findNamed(root, "Main", 3)
    if not main or not isVisible(main) then return end
    local parts = { elementText(findNamed(main, "IslandName", 1)) or "Island" }
    local budget = 200
    local function walk(el, depth)
        if depth > 4 or budget <= 0 then return end
        local kids = nil; pcall(function() kids = el:elements() end)
        local n = 0; pcall(function() n = kids:size() end)
        for i = 0, n - 1 do
            budget = budget - 1
            local c = nil; pcall(function() c = kids[i] end)
            if c and isVisible(c) then
                local nm = elementName(c) or ""
                local t = elementText(c)
                if t and t ~= "?" and not t:find("^[%p%s]*$") then
                    local rarity = nm:match("^Collected(%u%l+)$")
                    parts[#parts + 1] = rarity and (rarity .. " " .. t) or t
                end
                walk(c, depth + 1)
            end
        end
    end
    walk(findNamed(main, "IslandInfo", 1), 0)
    -- Put focus on GO, so Enter travels there.
    local hint = ""
    if navEnsure() then
        for i, l in ipairs(nav.labels) do
            if elementName(nav.items[i]) == "ActivateButton" then
                nav.index = i
                hint = " " .. l .. " is focused: press Enter to go, or Tab to look around."
                break
            end
        end
    end
    say(table.concat(parts, ", ") .. "." .. hint, true)
end

local function navActivate()
    if FRIENDLY.__keysLocked() then return end
    if vmenu.active then                        -- run the chosen list entry
        if vmenu.index < 1 then say("Press Tab to choose", true) return end
        local dest = vmenu.items[vmenu.index]
        vmenu.active = false
        if vmenu.kind == "places" then say("Opening " .. dest[1], false); FRIENDLY.__lockKeys("Places: " .. tostring(dest[1])) end
        pcall(nav.muteGameEnter)                -- before: the action may close screens
        pcall(nav.guardEnter)
        menuState.touch()
        pcall(dest[2])
        return
    end
    if liveMenu("popup_name_entry") then
        -- The game saves the name on Enter itself (PopupMonsterNameEntry
        -- doKeyActions); pressing a focused button too would fight it.
        menuState.nameText = nil
        say("Saving the name", true)
        return
    end
    pcall(nav.guardEnter)                       -- a screen this opens must not take the same Enter
    if placing() and menuState.placeHere and (not popupOpen() or menuState.sidePanels[currentPopupName()]) then
        menuState.placeHere()
        return
    end
    if not navEnsure() then return end
    local el = nav.items[nav.index]
    if not el then say("Press Tab to choose", true) return end
    local label = nav.labels[nav.index] or "item"
    if type(el) == "table" and el.virtual then
        pcall(nav.muteGameEnter)
        menuState.touch()
        pcall(el.virtual)
        return
    end
    -- "Close" on INFO (its background): do what Escape does.
    if elementName(el) == "FadedBG" and elementName(el:parent()) == "object_info" and FRIENDLY.__goBack then
        FRIENDLY.__goBack("escape")
        return
    end
    -- Enter on a slider resets it (a tap would set it to wherever it landed).
    if (elementName(el) == "SliderBg" and elementName(el:parent()) == "VolumeControl")
        or (elementName(el) == "Slider" and (liveMenu("volume_popup") or liveMenu("scale_popup") or liveMenu("warp_popup"))) then
        if FRIENDLY.__adjust then FRIENDLY.__adjust("reset") end
        return
    end
    pcall(nav.muteGameEnter, el)                -- before the press, never after
    -- Decide follow-ups before the press: never touch el after it.
    local breedRow = (nav.groups[nav.index] or ""):find("^Monster %d list$") and (elementName(el) or ""):find("^entry%d")
    local isle = false
    pcall(function() isle = (elementName(el) or ""):find("^entry%d") ~= nil and el:parent():name() == "IslandList" end)
    if elementName(el) == "EggImage" then
        if pressElement(el) then say("Cracking the egg", true); nav.crackEgg(2) end
        return
    end
    do
        local up = label:upper()
        for _, w in ipairs({ "MARKET", "MAP", "BATTLE", "COLLECTION", "QUESTS", "VERSUS", "START BATTLE", "EXIT" }) do
            if up == w or up:find("^" .. w .. ",") then FRIENDLY.__lockKeys(label) end
        end
    end
    if pressElement(el) then say(label, false) else say("Could not activate " .. label, true) end
    if breedRow then later(0.4, nav.breedingStatus) end
    if isle then later(0.5, nav.mapInfo) end
    -- Don't force an index reset here: navContext's key already changes (and
    -- resets focus) if a popup opened or the screen changed. If activation did
    -- nothing to the screen, keep the user's place in the list.
end

-- ---------------------------------------------------------------------------
-- Escape / Backspace: go back. Closes our lists, cancels placement, presses
-- the screen's Close / Back / No / Cancel button, or deselects.
-- The game handles Escape itself on some screens, so we wait a moment and
-- only act if the screen didn't change; otherwise one press would go back twice.
-- ---------------------------------------------------------------------------
local goBack
do
local BACK_NAMES = { CloseButton = true, BackButton = true, NoButton = true, CancelButton = true,
                     ExitButton = true, DismissButton = true, Close = true }
local BACK_WORDS = { "close", "back", "cancel", "no", "not now", "later", "maybe later", "exit", "done" }
local OK_NAMES = { OkayButton = true, OkButton = true }
-- Menus with a text box: Backspace there deletes text, so leave it alone.
local TEXT_ENTRY_MENUS = { "bind_email", "bind_password", "composer_base", "friends_invite", "login_email",
    "login_mfa", "login_register_email", "login_register_password", "popup_delete_account",
    "popup_name_entry", "popup_referral_sending", "popup_text_entry", "tribal" }
local BACK_WAIT_SECONDS = 0.5           -- the game's own Escape gets this long first
local pressEscapeFn = resolve("a11y_press_escape")

local function textEntryOpen()
    for _, f in ipairs(TEXT_ENTRY_MENUS) do
        if liveMenu(f) then return true end
    end
    return false
end
nav.textEntryOpen = textEntryOpen

local function screenKey()
    local key = nil
    pcall(function() local _, k = navContext(); key = k end)
    return tostring(key) .. "|" .. tostring(currentPopupName()) .. "|" .. tostring(selectionKey()) .. "|" .. tostring(placing())
end

-- A Close/Back/No button among these controls: el, label.
local function backButtonIn(items, labels)
    local okEl, okLabel, okCount = nil, nil, 0
    for i, el in ipairs(items) do
        if type(el) ~= "table" then
            local nm = elementName(el)
            local label = labels[i] or ""
            if nm and BACK_NAMES[nm] then return el, label end
            local lower = label:lower()
            for _, w in ipairs(BACK_WORDS) do
                -- "Exit" only as the whole label: never "EXIT GAME" on Options.
                if lower == w or (w ~= "exit" and lower:find("^" .. w .. "[%s,%.:]")) then return el, label end
            end
            -- "Continue" (rewards, "Click to continue") is the way out too.
            if (nm and OK_NAMES[nm]) or lower == "continue" then okEl, okLabel, okCount = el, label, okCount + 1 end
        end
    end
    -- A message with only an OK button: OK is the way out.
    if okCount == 1 and #items <= 2 then return okEl, okLabel end
    return nil
end

-- The Close/Back/No button for the current screen. Some screens (the Bakery)
-- keep theirs on the context bar at the bottom, not in their own window.
local function findBackButton()
    if navEnsure() then
        local el, label = backButtonIn(nav.items, nav.labels)
        if el then return el, label end
    end
    -- Context bar buttons run a named function (close_bakery, close_goals,
    -- cancel_scale, cancel_breeding...), reliable even for icon-only buttons.
    local cb = liveMenu("contextbar")
    if cb then
        local items, labels = scanClickables(cb)
        for i, el in ipairs(items) do
            local fn = ""; pcall(function() fn = el("FunctionName"):GetString() or "" end)
            if fn:find("^close") or fn:find("^cancel") or fn:find("^back") then
                return el, (labels[i] and labels[i] ~= "" and labels[i]) or "Close"
            end
        end
        for i, el in ipairs(items) do
            local lower = (labels[i] or ""):lower()
            if lower == "close" or lower == "back" or lower == "done" or lower == "cancel" then return el, labels[i] end
        end
    end
    return nil
end

local function doBack()
    if placing() then cancelPlacement() return end
    if currentPopupName() == "showgrid_popup" or currentPopupName() == "volume_popup" then  -- leftover from placing
        closeGridPopup()
        say("Back to the island", true)
        return
    end
    -- A selected decoration's Decoration Size panel: deselect, and close the
    -- panel if the game leaves it behind.
    if currentPopupName() == "scale_popup" then
        if objectSelected() then deselect() else say("Back to the island", true) end
        later(0.3, function()
            if currentPopupName() == "scale_popup" and not objectSelected() and not placing() then
                pcall(game.popPopUp)
            end
        end)
        return
    end
    local onScreen = popupOpen() or topOverlay() ~= nil
    if liveMenu("minigame_doorprize") then
        say("The scratch ticket has no close button. Scratch all six squares, then press Collect.", true)
        return
    end
    if onScreen or objectSelected() then
        local el, label = findBackButton()
        if el then
            a11y_log("[back] pressing " .. tostring(elementName(el)) .. " (" .. tostring(label) .. ")")
            if pressElement(el) then say(label ~= "" and label or "Back", true) return end
        end
    end
    if objectSelected() then deselect() return end
    if onScreen then
        a11y_log("[back] no close button on " .. tostring(currentPopupName()))
        say("No close button found here", true)
    end
end

function goBack(key)
    if FRIENDLY.__keysLocked() then return end
    -- Escape in the Market leaves it: lock the keys while the island loads.
    pcall(function()
        if os.clock() - FRIENDLY.__storeSeenAt < 0.5 then FRIENDLY.__lockKeys("leaving the Market") end
    end)
    if key == "backspace" then
        if textEntryOpen() then return end
        -- Backspace is a real Escape for the game: its own Escape handling runs
        -- first, and the Escape hotkey brings the mod's fallback after it.
        if type(pressEscapeFn) == "function" and not vmenu.active then
            pressEscapeFn()
            return
        end
    end
    if vmenu.active then
        vmenu.active = false
        say("Closed", true)
        return
    end
    local before = screenKey()
    later(BACK_WAIT_SECONDS, function()
        if screenKey() ~= before then
            a11y_log("[back] game handled " .. key)
            return
        end
        doBack()
    end)
end
end

-- ---------------------------------------------------------------------------
-- Tutorial "Continue" (Ctrl+Shift+Enter).
--
-- Tutorial speech popups (e.g. the Bakery/Cookies message) are a separate C++
-- layer: NOT a game.pushPopUp popup, NOT in any reachable element tree, so we
-- can neither read their text nor find their Continue button. The only lever the
-- scripts expose is advancing the tutorial by sending MsgNextTutorialStep to the
-- engine receiver (see IslandPurchaseFanfare.lua). This dismisses/advances the
-- current tutorial step.
-- ---------------------------------------------------------------------------
-- Tutorial dialogs are C++-drawn: no element to click, no dismiss API, and
-- MsgNextTutorialStep does NOT dismiss them. So: press once -> synthesize a real
-- mouse click on the Continue button's on-screen spot (native a11y_click_fraction);
-- press AGAIN quickly (<1.5s, click didn't work) -> skip the whole first-time
-- tutorial via game.endIslandFirstTimeTutorial(). Spacing presses out >1.5s just
-- clicks again (for the next speech step).
-- ---------------------------------------------------------------------------
-- Live tutorial reader. This mod overrides the tutorial menus (data/menus/*.xml,
-- generated by scripts/Build-MenuOverrides.ps1) so their own onTick calls
-- a11y_tutTick(root, menu) every frame. We get a fresh handle while the menu
-- exists and stop getting one the moment it's gone, so we never hold a stale one.
-- ---------------------------------------------------------------------------
local TUT_STABLE_FRAMES = 6      -- text must hold steady this many frames before speaking
local TUT_FRESH_SECONDS = 0.5    -- handle is live if a tick arrived this recently

local tut = { root = nil, menu = nil, lastTick = -100, spoken = "", pending = "", stable = 0, seen = {} }

local function sentence(s)
    if s:find("[%.!?]$") then return s end
    return s .. "."
end


local function tutText(root, elName)
    local visible = 1
    pcall(function() visible = root[elName]["Text"]("visible"):GetInt() end)
    if visible == 0 then return nil end
    local t = nil
    pcall(function() t = root[elName]["Text"]("text"):GetString() end)
    return cleanText(t)
end

-- Tutorial popups are filled from C++, invisible to the Lua "text" property.
-- The native hook on the game's ShowTutorialPopup captures title + text and
-- calls a11y_onTutorialPopup; we keep the message for re-reading.
local popupTextFn = resolve("a11y_tutorial_popup_text")
local tutPopupMsg = nil

local function tutorialPopupMessage()
    if type(popupTextFn) ~= "function" then return nil end
    local ok, title, text = pcall(popupTextFn)
    if not ok then return nil end
    local parts = {}
    for _, s in ipairs({ title, text }) do
        local t = cleanText(s)
        if t then parts[#parts + 1] = sentence(t) end
    end
    if #parts == 0 then return nil end
    return table.concat(parts, " ")
end

local function onTutorialPopup()
    tutPopupMsg = tutorialPopupMessage()
    if not tutPopupMsg then return end
    a11y_log("[tut] popup: " .. tutPopupMsg)
    say(tutPopupMsg .. " Control Shift Enter to continue.", true)
end

local function tutMessage(root, menu)
    if menu ~= "tutorial" then return tutPopupMsg end
    local parts = {}
    local names = (menu == "tutorial") and { "primaryText", "SecondaryText" } or { "Title", "Text" }
    for _, nm in ipairs(names) do
        local t = tutText(root, nm)
        if t then parts[#parts + 1] = sentence(t) end
    end
    if #parts == 0 then return nil end
    return table.concat(parts, " ")
end

-- The banner menu only advances on click when the game has enabled
-- click-anywhere; otherwise the step wants a real action (place a monster...).
-- Popup menus always have a Continue button.
local function tutCanContinue(root, menu)
    if menu ~= "tutorial" then return true end
    local on = false
    pcall(function() on = root["FadedBG"]["Touch"]("enabled"):GetInt() ~= 0 end)
    return on
end

local function tutHint(root, menu)
    if tutCanContinue(root, menu) then return " Control Shift Enter to continue." end
    local target = nil
    pcall(function() target = tutorialTarget() end)
    if target then return " Control Shift Enter to " .. (target.verb or "tap") .. " " .. target[1] .. "." end
    return ""
end

local function tutLive()
    -- Like menus: ticked recently compared with the other screens, and since
    -- the mod last pressed anything.
    return tut.root ~= nil and (clock() - tut.lastTick) <= TUT_FRESH_SECONDS
        and menuState.lastTick - tut.lastTick <= 0.1 and tut.lastTick > menuState.activated
end

local TUT_DEBUG = false   -- true: log raw tutorial menu state ([tutprobe]/[tuthb]/[tutswig])

-- DIAGNOSTIC: log the raw state of each tutorial menu whenever it changes, so we
-- can see what the game actually puts in these menus during a tutorial step.
local TUT_PROBE = {
    tutorial = { "primaryText", "SecondaryText", "bg", "FadedBG" },
    popup_tutorial = { "Title", "Text", "bg", "OkayButton", "FadedBG" },
    popup_tutorial_streamlined = { "Title", "Text", "bg", "OkayButton", "FadedBG" },
}
local tutRawSig = {}
tut.roots = {}

local function probe(fn)
    local ok, v = pcall(fn)
    if ok then return tostring(v) end
    return "ERR(" .. tostring(v) .. ")"
end

local function tutProbe(root, menu)
    local parts = {}
    parts[#parts + 1] = "rootVisible=" .. probe(function() return root.isVisible end)
    for _, nm in ipairs(TUT_PROBE[menu] or {}) do
        local el = "?"; pcall(function() el = root[nm] end)
        parts[#parts + 1] = nm .. "{el=" .. tostring(el ~= nil)
            .. " elVis=" .. probe(function() return root[nm].isVisible end)
            .. " textVis=" .. probe(function() return root[nm]["Text"]("visible"):GetInt() end)
            .. " spriteVis=" .. probe(function() return root[nm]["Sprite"]("visible"):GetInt() end)
            .. " alpha=" .. probe(function() return root[nm]["Sprite"]("alpha"):GetFloat() end)
            .. " touch=" .. probe(function() return root[nm]["Touch"]("enabled"):GetInt() end)
            .. " text='" .. probe(function() return root[nm]["Text"]("text"):GetString() end) .. "'}"
    end
    local sig = table.concat(parts, " ")
    if sig ~= tutRawSig[menu] then
        tutRawSig[menu] = sig
        a11y_log("[tutprobe] " .. menu .. ": " .. sig)
    end
end

-- DIAGNOSTIC: list the SWIG methods/properties an object exposes (metatable,
-- .fn, .get and __index tables), so we can find a getter for drawn text.
local function swigMembers(obj)
    local names, seen = {}, {}
    local function add(t, prefix)
        if type(t) ~= "table" then return end
        for k, v in pairs(t) do
            local n = prefix .. tostring(k)
            if not seen[n] then seen[n] = true; names[#names + 1] = n .. ":" .. type(v) end
        end
    end
    local ok, mt = pcall(getmetatable, obj)
    if not ok or type(mt) ~= "table" then return "no metatable (" .. tostring(mt) .. ")" end
    add(mt, "")
    add(rawget(mt, ".fn"), ".fn.")
    add(rawget(mt, ".get"), ".get.")
    local idx = rawget(mt, "__index"); if type(idx) == "table" then add(idx, "__index.") end
    table.sort(names)
    return table.concat(names, " ")
end

local TEXT_GETTERS = { "getText", "GetText", "text", "getString", "GetString", "getDisplayText",
    "displayText", "getLocalizedText", "getTextString", "string", "str" }

local tutTextProbed = {}
local function tutProbeTextComponent(root, menu)
    for _, nm in ipairs({ "Title", "Text" }) do
        local comp = nil; pcall(function() comp = root[nm]["Text"] end)
        local key = menu .. "." .. nm
        if comp and not tutTextProbed[key] then
            tutTextProbed[key] = true
            a11y_log("[tutswig] " .. key .. " component members: " .. swigMembers(comp))
            local el = nil; pcall(function() el = root[nm] end)
            a11y_log("[tutswig] " .. key .. " element members: " .. swigMembers(el))
        end
        if comp then
            local res = {}
            for _, g in ipairs(TEXT_GETTERS) do
                res[#res + 1] = g .. "=" .. probe(function() return comp[g](comp) end)
            end
            local sig = table.concat(res, " ")
            if sig ~= tutTextProbed[key .. "#sig"] then
                tutTextProbed[key .. "#sig"] = sig
                a11y_log("[tutswig] " .. key .. " getters: " .. sig)
            end
        end
    end
end

-- DIAGNOSTIC heartbeat: every 2s per menu, log tick count + game tutorial state.
local tutHb = {}
local function tutHeartbeat(menu, now)
    local hb = tutHb[menu] or { n = 0, t = now }
    tutHb[menu] = hb
    hb.n = hb.n + 1
    if now - hb.t < 2 then return end
    local active = probe(function() return game.tutorialActive() end)
    local step = probe(function() local s, m = tutStepFn(); return tostring(s) .. "/" .. tostring(m) end)
    local pop = probe(function() return game.getPopUp() end)
    a11y_log("[tuthb] " .. menu .. " ticks=" .. hb.n .. " tutorialActive=" .. active .. " step=" .. step .. " popup=" .. pop)
    hb.n, hb.t = 0, now
end

local function tutTick(root, menu)
    if FRIENDLY.__quietNow(clock()) then return end
    tut.roots[menu] = root
    if TUT_DEBUG then
        pcall(tutProbe, root, menu)
        pcall(tutHeartbeat, menu, clock())
        if menu ~= "tutorial" then pcall(tutProbeTextComponent, root, menu) end
    end
    -- Popup text is spoken by onTutorialPopup (native hook), not polled here.
    if menu ~= "tutorial" then
        tut.root, tut.menu, tut.lastTick = root, menu, clock()
        return
    end
    local now = clock()
    if now - tut.lastTick > TUT_FRESH_SECONDS then tut.spoken = "" end   -- menu (re)appeared
    tut.root, tut.menu, tut.lastTick = root, menu, now
    if not tut.seen[menu] then tut.seen[menu] = true; a11y_log("[tut] first tick from " .. menu) end

    -- Wait for the text to settle: C++ fills title and body separately after onInit.
    local msg = tutMessage(root, menu) or ""
    if msg ~= tut.pending then tut.pending, tut.stable = msg, 0 return end
    tut.stable = tut.stable + 1
    if tut.stable ~= TUT_STABLE_FRAMES or msg == tut.spoken then return end
    tut.spoken = msg
    if msg == "" then return end
    a11y_log("[tut] " .. menu .. ": " .. msg)
    -- A raw text key (BATT_TUT_01_02b_OTHER_DMG_EXPOSITION): the game has no
    -- English words for this step, so it shows the key itself.
    if msg:find("^[%u%d_]+%.?$") and msg:find("_") then
        msg = "This tutorial step has no text in the game, it only shows a code."
    end
    say(msg .. tutHint(root, menu), false)
end

local function tutGone(menu)
    if tut.menu == menu then
        tut.root, tut.menu, tut.spoken, tut.pending, tut.stable = nil, nil, "", "", 0
    end
end

-- Do exactly what the menu's own Continue button / click-anywhere does.
local function tutContinueLive()
    local root, menu = tut.root, tut.menu
    if not tutCanContinue(root, menu) then
        -- The step wants an action: do it if we know the target.
        local target = nil
        if not popupOpen() and not topOverlay() then target = tutorialTarget() end
        if target then pcall(target[2]) return end
        local what = tut.spoken ~= "" and tut.spoken or "Tab to find it."
        say("This step needs an action. " .. what, true)
        return
    end
    local ok = pcall(function() root:GetReceiver():Send(game.MsgNextTutorialStep()) end)
    if not ok then say("Could not continue", true) return end
    pcall(function() lua_sys.playSoundFx("audio/sfx/menu_click.wav") end)
    tut.spoken, tut.pending, tut.stable = "", "", 0   -- re-read even if text repeats
    say("Continue", true)
end

local CONTINUE_FX, CONTINUE_FY = 0.5, 0.72   -- observed Continue button position
local lastTutClick = -100
-- ---------------------------------------------------------------------------
-- Tutorial step descriptions (Ctrl+Shift+T).
--
-- The tutorial is a fixed, scripted sequence. The game's own message text lives
-- in a complex C++ data structure that isn't cleanly readable, so instead we
-- keep OUR OWN map of step number -> what to do. Keyed by the SPOKEN (1-based)
-- step number, i.e. what "step N of M" announces. Fill in as you play: at each
-- step press Ctrl+Shift+T, note the number and task, and add it here. Unknown
-- steps just announce "step N of M".
-- ---------------------------------------------------------------------------
local TUTORIAL_STEPS = {
    [29] = "Bake cookies in the Bakery",
    -- [n] = "description",
}

local function announceTutorialStep()
    local rawStep, maxStep = -1, 0
    if type(tutStepFn) == "function" then
        local ok, s, m = pcall(tutStepFn)
        if ok then rawStep, maxStep = (s or -1), (m or 0) end
    end
    local live = tutLive() and tutMessage(tut.root, tut.menu) or nil
    if live then
        local step = (rawStep and rawStep >= 0) and (" Step " .. (rawStep + 1) .. " of " .. maxStep .. ".") or ""
        say(live .. step .. tutHint(tut.root, tut.menu), true)
        return
    end
    if not rawStep or rawStep < 0 then say("No tutorial active", true) return end
    local shown = rawStep + 1
    local desc = TUTORIAL_STEPS[shown]
    local msg = (desc and (desc .. ", ") or "") .. "step " .. shown .. " of " .. maxStep
    say(msg, true)
end

-- Press a tutorial popup's own Continue button (same handlers a click runs).
local function pressTutorialPopup(root)
    local ok = pcall(function()
        local b = root["OkayButton"]
        b.Touch:onTouchDown(b, 0, 0)
        b.Touch:onTouchUp(b, 0, 0)
    end)
    if not ok then
        ok = pcall(function() root:GetReceiver():Send(game.MsgNextTutorialStep()) end)
    end
    return ok
end

local function tutorialContinue()
    for _, n in ipairs({ "popup_tutorial", "popup_tutorial_streamlined" }) do
        local r = liveMenu(n)
        if r then
            if pressTutorialPopup(r) then
                tut.spoken, tut.pending, tut.stable = "", "", 0
                say("Continue", true)
            else
                say("Could not continue", true)
            end
            return
        end
    end
    local active = false
    pcall(function() active = game.tutorialActive() end)
    -- Tutorial menus are preloaded and tick even when hidden, so also require
    -- the game to report an active tutorial before sending a step message.
    if active and tutLive() then tutContinueLive() return end
    if not active then lastTutClick = -100; say("No tutorial to continue", true) return end

    local now = 0; pcall(function() now = os.clock() end)

    if (now - lastTutClick) < 1.5 then
        -- Rapid second press: the click didn't dismiss it -> skip the tutorial.
        local ok = pcall(function() game.endIslandFirstTimeTutorial() end)
        lastTutClick = -100
        if ok then say("Skipping tutorial", false) else say("Could not skip tutorial", true) end
    elseif type(clickFraction) == "function" then
        menuState.tap(CONTINUE_FX, CONTINUE_FY)
        lastTutClick = now
        say("Continue", false)
    else
        say("Click function unavailable", true)
    end
end

-- ---------------------------------------------------------------------------
-- "What now?" (Ctrl+Shift+W). After the tutorial nothing tells a blind player
-- what to do next: the game shows it as sparkles over buildings and the Goals
-- checklist. Read both: what's ready on this island (Island:has*Ready, the
-- checks behind the game's own indicators), then the current goals with their
-- progress, filled in the way FillQuestDescription.lua does it.
-- ---------------------------------------------------------------------------
local READY_CHECKS = {
    -- Collect All only appears on the bar once the game unlocks it, and it
    -- recharges after use (ContextBar.lua: collectAllUnlocked/Disabled).
    { "hasMonsterCollectReady", function()
        local base = "Monsters have coins to collect"
        local ok, unlocked = pcall(function() return game.collectAllUnlocked() end)
        if ok and unlocked then
            local okd, off = pcall(function() return game.collectAllDisabled() end)
            if okd and off then
                local tt = nil; pcall(function() tt = cleanText(localize(game.collectAllTimerText()) or "") end)
                return base .. ". Collect All on the bar is recharging" .. ((tt and tt ~= "") and (", " .. tt) or "")
            end
            return base .. ". Collect All is on the bar"
        end
        return base .. ". Collect All isn't unlocked yet, so collect from each monster: Control Shift O, pick a monster, press Enter"
    end },
    { "hasBakeryReady",           "Bakery food is ready to collect" },
    { "hasBreedingReady",         "Breeding is finished" },
    { "hasNurseryReady",          "An egg in the Nursery is ready to hatch" },
    { "hasMineReady",             "The Mine is ready" },
    { "hasStructureUpgradeReady", "A structure upgrade is finished" },
    { "hasCastleUpgradeReady",    "The Castle upgrade is finished" },
    { "hasEvolutionReady",        "A monster is ready to evolve" },
    { "hasTrainingReady",         "Monster training is finished" },
    { "hasAttunementReady",       "Attuning is finished" },
    { "hasSynthesisReady",        "Synthesizing is finished" },
    { "hasFuzingReady",           "Fuzing is finished" },
}

local function readyList()
    local out = {}
    local isl = nil
    pcall(function() isl = game.player():getActiveIsland() end)
    if not isl then return out end
    for _, c in ipairs(READY_CHECKS) do
        local ok, v = pcall(function() return isl[c[1]](isl) end)
        if ok and v then
            local text = c[2]
            if type(text) == "function" then
                local okt, t = pcall(text); text = okt and t or "Monsters have coins to collect"
            end
            out[#out + 1] = text
        end
    end
    return out
end

-- Speak when something finishes while you play (the game's "ding"). Polls the
-- island's ready flags and announces only false -> true changes; the first poll
-- on an island just records the baseline. Coins are left out: they fill
-- constantly, and Control Shift W reports them.
do
local FINISHED_TEXT = {
    hasBakeryReady           = "Baking finished. Food is ready to collect at the Bakery",
    hasBreedingReady         = "Breeding finished. The egg is ready",
    hasNurseryReady          = "An egg finished incubating. It is ready to hatch in the Nursery",
    hasMineReady             = "The Mine is ready",
    hasStructureUpgradeReady = "A structure finished building or upgrading",
    hasCastleUpgradeReady    = "The Castle upgrade is finished",
    hasEvolutionReady        = "A monster is ready to evolve",
    hasTrainingReady         = "Monster training is finished",
    hasAttunementReady       = "Attuning is finished",
    hasSynthesisReady        = "Synthesizing is finished",
    hasFuzingReady           = "Fuzing is finished",
}
local READY_POLL_SECONDS = 2
local readyWatch = { t = -100, island = nil, state = {} }

local function watchReady(now)
    if now - readyWatch.t < READY_POLL_SECONDS then return end
    readyWatch.t = now
    local isl, islId = nil, nil
    pcall(function() isl = game.player():getActiveIsland() end)
    if not isl then readyWatch.island = nil return end
    pcall(function() islId = tostring(isl:id()) end)
    local fresh = islId ~= readyWatch.island
    if fresh then readyWatch.island, readyWatch.state = islId, {} end
    local done = {}
    for check, text in pairs(FINISHED_TEXT) do
        local ok, v = pcall(function() return isl[check](isl) and true or false end)
        if ok then
            if v and readyWatch.state[check] == false and not fresh then done[#done + 1] = text end
            readyWatch.state[check] = v
        end
    end
    if #done > 0 then
        a11y_log("[ready] " .. table.concat(done, "; "))
        say(joinSentences(done), false)
    end
end
readyHook = watchReady

-- Speak what you just got or spent ("Got 120 coins", "Spent 40 food"), the
-- way the counters animating at the top tell sighted players. Changes are
-- added up until the balances settle, so a collect that counts up over a few
-- frames is one announcement.
local WALLET = {
    { "playerCoins", "coins" }, { "playerDiamonds", "diamonds" }, { "playerFood", "food" },
    { "playerEtherealCurrency", "shards" }, { "playerKeys", "keys" }, { "playerRelics", "relics" },
    { "playerStarpower", "starpower" }, { "playerCurrentXp", "XP" },
}
local WALLET_POLL_SECONDS = 0.25
local WALLET_SETTLE_SECONDS = 0.8
local wallet = { t = -100, last = nil, level = nil, pending = {}, changed = nil }

local function readWallet()
    local w = {}
    for _, c in ipairs(WALLET) do
        local ok, v = pcall(function() return game[c[1]]() end)
        if ok and type(v) == "number" then w[c[1]] = v end
    end
    return w
end

local function watchWallet(now)
    if now - wallet.t < WALLET_POLL_SECONDS then return end
    wallet.t = now
    -- Visiting a friend (and 3 seconds after): balances and level read as
    -- theirs. Drop everything and start over from a fresh baseline at home.
    -- A loading screen (going to a friend's island loads it first, with
    -- their balances already in place) counts the same.
    local busy = false
    -- (Not load_fade: it keeps ticking while the Market is open, and purchases
    -- there should still be announced.)
    for _, f in ipairs({ "friend_hud", "load_overlay", "load_full" }) do
        local m = menus[f]
        if m and now - m.t < 3 then busy = true end
    end
    if busy then
        wallet.last, wallet.pending, wallet.changed, wallet.ready = nil, {}, nil, nil
        return
    end
    -- Balances load in after the game starts: only watch once an island is up,
    -- and start from a fresh baseline whenever there was none.
    local isl = nil
    pcall(function() isl = game.player():getActiveIsland() end)
    if not isl then wallet.last, wallet.pending, wallet.changed = nil, {}, nil return end
    if not wallet.ready then wallet.ready = now end
    if now - wallet.ready < 3 then wallet.last = nil return end
    local w = readWallet()
    local lvl = nil; pcall(function() lvl = game.playerLevel() end)
    if not wallet.last then wallet.last, wallet.level = w, lvl return end
    for _, c in ipairs(WALLET) do
        local k = c[1]
        local a, b = wallet.last[k], w[k]
        if a and b and a ~= b then
            if not (k == "playerCurrentXp" and lvl ~= wallet.level) then
                wallet.pending[k] = (wallet.pending[k] or 0) + (b - a)
            end
            wallet.changed = now
        end
    end
    if lvl and wallet.level and lvl > wallet.level then
        wallet.pending.levelUp = lvl
        wallet.changed = now
    end
    wallet.last, wallet.level = w, lvl or wallet.level
    if not wallet.changed or now - wallet.changed < WALLET_SETTLE_SECONDS then return end
    local got, spent = {}, {}
    for _, c in ipairs(WALLET) do
        local d = wallet.pending[c[1]]
        if d and d > 0 then got[#got + 1] = tostring(d) .. " " .. c[2] end
        if d and d < 0 then spent[#spent + 1] = tostring(-d) .. " " .. c[2] end
    end
    local msg = {}
    if #got > 0 then msg[#msg + 1] = "Got " .. table.concat(got, ", ") end
    if #spent > 0 then msg[#msg + 1] = "Spent " .. table.concat(spent, ", ") end
    if wallet.pending.levelUp then msg[#msg + 1] = "Level up! You are now level " .. tostring(wallet.pending.levelUp) end
    wallet.pending, wallet.changed = {}, nil
    if #msg > 0 then
        a11y_log("[wallet] " .. table.concat(msg, "; "))
        say(joinSentences(msg), false)
    end
end
walletHook = watchWallet
end

-- Goal text with its placeholders filled ({0:object} -> a name, {0:num} -> a number).
local function questText(quest, s)
    s = s and cleanText(s) or nil
    if not s then return nil end
    s = s:gsub("{%s*([0-9]+)%s*:*s*([A-Za-z0-9]+)%s*}", function(index, target)
        local out = nil
        pcall(function()
            local v = quest:getPropertyInt(tonumber(index), target)
            if target == "object" then out = cleanText(game.getLocalizedText(game.entityName(v)))
            else out = tostring(v) end
        end)
        return out or ""
    end)
    return s
end

local MAX_GOALS_SPOKEN = 4

-- The goals the Goals screen's main tab shows (Goals.lua TabMain.filterQuest):
-- visible at the player's level; completed ones, plus up to maxMainQuests open.
-- Their text is the description (the name is an internal id like M_C_LVL_4),
-- falling back to the name only when there is no description, like GoalEntry.
local function goalList()
    local out = {}
    pcall(function()
        local qs = game.quests(2)
        local level = 1; pcall(function() level = game.playerLevel() end)
        local maxOpen = 3; pcall(function() maxOpen = game.maxMainQuests() end)
        -- Same order as the Goals screen (GoalEntries.questCompare, minus its
        -- "can help" check): most complete first, then priority (-1 last), then id.
        local list = {}
        for i = 0, qs:size() - 1 do
            local q = qs[i]
            local e = { q = q, pct = 0, pri = -1, id = 0 }
            pcall(function() e.pct, e.pri, e.id = q:percentComplete(), q:priority(), q:getId() end)
            list[#list + 1] = e
        end
        table.sort(list, function(a, b)
            if a.pct ~= b.pct then return a.pct > b.pct end
            if a.pri ~= b.pri then
                if a.pri == -1 then return false end
                if b.pri == -1 then return true end
                return a.pri < b.pri
            end
            return a.id < b.id
        end)
        local done, open = {}, {}
        for _, e in ipairs(list) do
            local q = e.q
            local visible = false
            pcall(function() visible = q:isVisible(level) and true or false end)
            local complete = false
            pcall(function() complete = q:isComplete() and true or false end)
            if visible and (complete or #open < maxOpen) then
                local raw = nil
                pcall(function() raw = q:getDescription() end)
                if not raw or raw == "" then pcall(function() raw = q:getName() end) end
                local line = questText(q, raw) or "Goal"
                if complete then
                    done[#done + 1] = trimEnd(line) .. ", Done, claim it in Goals"
                else
                    local d, t = nil, nil
                    pcall(function() d, t = q:numProgressMarkersDone(), q:numProgressMarkersTotal() end)
                    if d and t and t > 1 then line = trimEnd(line) .. ", " .. d .. " of " .. t end
                    open[#open + 1] = line
                end
            end
        end
        for _, l in ipairs(done) do out[#out + 1] = l end   -- rewards waiting first
        for _, l in ipairs(open) do out[#out + 1] = l end
    end)
    return out
end

local function whatNow()
    local parts = {}
    local ready = readyList()
    if #ready > 0 then parts[#parts + 1] = "Ready: " .. joinSentences(ready) .. "." end
    local goals = goalList()
    if #goals > 0 then
        local spoken = {}
        for i = 1, MAX_GOALS_SPOKEN do
            if goals[i] then spoken[#spoken + 1] = goals[i] end
        end
        parts[#parts + 1] = "Goals: " .. numberedList(spoken)
        if #goals > #spoken then parts[#parts + 1] = (#goals - #spoken) .. " more in the Goals screen." end
    end
    if #parts == 0 then
        say("Nothing ready and no goals found. Try the Market to buy a monster, or the Goals screen.", true)
        return
    end
    say(table.concat(parts, " "), true)
end

-- ---------------------------------------------------------------------------
-- Diagnostic dump (Ctrl+Shift+D): log the live UI tree to accessibility.log so
-- we can build accurate navigation. For each element: indent, name, [CLICK] if
-- it has a Touch, [hidden] if not visible, and its text/label.
-- ---------------------------------------------------------------------------
local DUMP_MAX_DEPTH = 14
local function dumpElement(el, depth, budget)
    if not el or depth > DUMP_MAX_DEPTH or budget.n <= 0 then return end
    budget.n = budget.n - 1
    local nm = "?"; pcall(function() nm = tostring(el:name()) end)
    local click = isClickable(el) and " [CLICK]" or ""
    local hid = isVisible(el) and "" or " [hidden]"
    local txt = elementText(el)
    local bl = nil; pcall(function() local b = el("ButtonLabelText"):GetString(); if b and #b > 0 then bl = b end end)
    local extra = txt and (" ='" .. txt .. "'") or (bl and (" lbl=" .. bl) or "")
    a11y_log(string.rep("  ", depth) .. nm .. click .. hid .. extra)
    local kids = nil; pcall(function() kids = el:elements() end)
    if not kids then return end
    local n = 0; pcall(function() n = kids:size() end)
    for i = 0, n - 1 do
        if budget.n <= 0 then return end
        local child = nil; pcall(function() child = kids[i] end)
        if child then dumpElement(child, depth + 1, budget) end
    end
end

-- Climb to the topmost ancestor reachable via :parent(), so we can dump sibling
-- menus (market/book/options bar) that aren't under the HUD root.
local function topAncestor(el)
    local cur = el
    for _ = 1, 30 do
        local p = nil
        pcall(function() p = cur:parent() end)
        if not p or p == cur then break end
        cur = p
    end
    return cur
end

-- Probe which per-object status calls work (the icons floating over objects).
local function probeCall(label, fn)
    local ok, v = pcall(fn)
    a11y_log("    " .. label .. " = " .. (ok and tostring(v) or ("ERR " .. tostring(v))))
end

local function probeStatus()
    a11y_log("-- STATUS PROBE --")
    -- Visiting a friend: what the game gives for their island (dump only).
    local fh = menus.friend_hud
    if fh and clock() - fh.t < 1 then
        a11y_log("  -- visiting a friend --")
        probeCall("game.isFriendMode()", function() return game.isFriendMode() end)
        local vf, cfi = nil, nil
        pcall(function() vf = game.getVisitedFriend() end)
        pcall(function() cfi = game.currentFriendIsland() end)
        a11y_log("    getVisitedFriend = " .. tostring(vf) .. "  members: " .. tostring(type(vf) == "userdata" and swigMembers(vf)))
        a11y_log("    currentFriendIsland = " .. tostring(cfi) .. "  members: " .. tostring(type(cfi) == "userdata" and swigMembers(cfi)))
        for _, src in ipairs({ { "currentFriendIsland", function() return cfi end },
                               { "friend:getActiveIsland", function() return vf:getActiveIsland() end },
                               { "friend:activeIsland", function() return vf:activeIsland() end },
                               { "friend:getIsland", function() return vf:getIsland(cfi) end } }) do
            local isl = nil
            pcall(function() isl = src[2]() end)
            if type(isl) == "userdata" then
                a11y_log("    " .. src[1] .. " = " .. tostring(isl) .. "  members: " .. swigMembers(isl))
                probeCall(src[1] .. " monsters", function() return isl:monsters():size() end)
                probeCall(src[1] .. " structures", function() return isl:structures():size() end)
                probeCall(src[1] .. " first monster", function()
                    local m = isl:monsters()[0]
                    return tostring(m) .. " " .. swigMembers(m)
                end)
            else
                a11y_log("    " .. src[1] .. " = " .. tostring(isl))
            end
        end
    end
    for _, c in ipairs(READY_CHECKS) do
        probeCall("island:" .. c[1], function() local i = game.player():getActiveIsland(); return i[c[1]](i) end)
    end
    for t = 0, MAX_STRUCTURE_TYPE do
        local id = 0
        pcall(function() id = game.getFirstStructureOfType(t) or 0 end)
        if id ~= 0 then
            local ent = nil
            pcall(function() ent = game.GetStructure(id) end)
            a11y_log("  structure type " .. t .. " id " .. tostring(id) .. " " .. tostring(structureLabel(id)) .. " ent=" .. tostring(ent))
            if ent then
                probeCall("secondsUntilActionDone", function() return ent:secondsUntilActionDone() end)
                probeCall("diamondsRequiredToCompleteAction", function() return ent:diamondsRequiredToCompleteAction() end)
                probeCall("isEggHolder", function() return ent:isEggHolder() end)
                probeCall("hasEgg", function() return ent:hasEgg() end)
                probeCall("isEggReadyToHatch", function() return ent:isEggReadyToHatch() end)
                probeCall("secondsUntilHatch", function() return ent:secondsUntilHatch() end)
                probeCall("percentHatched", function() return ent:percentHatched() end)
                probeCall("getMonsterInEgg", function() return ent:getMonsterInEgg() end)
            end
            probeCall("game.timeLeftOnStruct(id)", function() return game.timeLeftOnStruct(id) end)
            probeCall("game.isStructureUpgrading(id)", function() return game.isStructureUpgrading(id) end)
            probeCall("game.timeLeft(id)", function() return game.timeLeft(id) end)
        end
    end
    pcall(function()
        local mons = game.player():getActiveIsland():monsters()
        for i = 0, mons:size() - 1 do
            local uid = mons[i]
            local ent = nil
            pcall(function() ent = game.GetMonster(uid) end)
            a11y_log("  monster " .. tostring(uid) .. " " .. tostring(monsterLabel(uid)) .. " ent=" .. tostring(ent))
            if ent then
                probeCall("level", function() return ent:level() end)
                probeCall("timesFed", function() return ent:timesFed() end)
                probeCall("foodRequired", function() return ent:foodRequired() end)
                probeCall("secondsUntilActionDone", function() return ent:secondsUntilActionDone() end)
            end
            probeCall("game.monsterEarnings(uid)", function() return game.monsterEarnings(uid) end)
            probeCall("game.monsterEarnings()", function() return game.monsterEarnings() end)
        end
    end)
    a11y_log("  selected: " .. tostring(selectionKey()))
    probeCall("context", function() return manager:getContext() end)
    for _, f in ipairs({ "bakeryTime", "timeLeftToBake", "timeLeftToBreed", "timeLeftToHatchEgg", "eggReadyToHatch",
                         "isBreedingFinished", "timeLeftToBuild", "timeLeftToDestoryObstacle", "monsterEarnings" }) do
        probeCall("game." .. f .. "()", function() return game[f]() end)
    end
    a11y_log("-- STATUS PROBE end --")
end

local function dumpUI()
    a11y_log("=== UI DUMP begin ===")
    probeStatus()

    -- What does the game think the top popup is? (getPopUp returns a NAME string.)
    local popName = "?"; pcall(function() popName = tostring(game.getPopUp()) end)
    local hasPop = "?"; pcall(function() hasPop = tostring(game.hasPopUp()) end)
    local topName2 = "?"; pcall(function() topName2 = tostring(game.getTopPopUpName()) end)
    a11y_log("getPopUp()='" .. popName .. "'  hasPopUp()=" .. hasPop .. "  getTopPopUpName()='" .. topName2 .. "'")

    -- Our captured push/pop stack.
    local ids = {}
    for i, e in ipairs(popupStack) do ids[i] = tostring(e.id) end
    a11y_log("popupStack (" .. #popupStack .. "): " .. (table.concat(ids, ", ")))

    -- Dump the stack-top popup object tree, if we captured one.
    local top = popupStack[#popupStack]
    if top and top.obj then
        a11y_log("-- CAPTURED POPUP TREE (id=" .. tostring(top.id) .. ") --")
        dumpElement(top.obj, 0, { n = 600 })
    else
        a11y_log("-- no captured popup object --")
    end

    -- Every menu currently ticking (captured by the XML overrides' A11yHook).
    for file, m in pairs(menus) do
        if clock() - m.t <= 5 then
            a11y_log(string.format("-- menu timing: %s gap=%.3f lag=%.3f age=%.3f usable=%s", file, m.gap or -1,
                menuState.lastTick - m.t, clock() - m.t, tostring(menuState.usable(m))))
        end
        if menuState.usable(m) and file ~= "hud" then
            a11y_log("-- LIVE MENU TREE (" .. file .. ", root " .. tostring(m.rootName) .. ") --")
            dumpElement(m.root, 0, { n = 2000 })
        end
    end

    -- Try to reach the popup element via game.topPopUp() (returns an element in
    -- scripts, unlike getPopUp which returns a name).
    local tp = nil; pcall(function() tp = game.topPopUp() end)
    if tp then
        a11y_log("-- game.topPopUp() TREE --")
        dumpElement(tp, 0, { n = 600 })
    else
        a11y_log("-- game.topPopUp() returned nil/non-element --")
    end

    -- Full HUD tree from top ancestor (island + anything parented under it).
    local ok2, hud = pcall(game.getHUD)
    if ok2 and hud then
        local hudName = "?"; pcall(function() hudName = tostring(hud:name()) end)
        local top2 = topAncestor(hud)
        local topName = "?"; pcall(function() topName = tostring(top2:name()) end)
        a11y_log("HUD name=" .. hudName .. "  topAncestor=" .. topName)
        a11y_log("-- FULL TREE from top ancestor --")
        dumpElement(top2, 0, { n = 2000 })
    else
        a11y_log("no HUD")
    end

    a11y_log("=== UI DUMP end ===")
    say("UI dumped to log", true)
end

-- ---------------------------------------------------------------------------
-- 4. Expose readers for hotkeys / other mods / manual console use.
-- ---------------------------------------------------------------------------
shared.a11y = {
    say        = say,
    silence    = silence,
    is_active  = is_active,
    announceHud= announceHud,
    readCoins  = readCoins,
    readDiamonds = readDiamonds,
    readFood   = readFood,
    readLevel  = readLevel,
    readIsland = readIsland,
    announceCurrentPopup = announceCurrentPopup,
    dumpUI     = dumpUI,
}

-- Expose reader functions into the GAME Lua state (not just the mod sandbox) so
-- native hotkeys, which run via queue_lua in the game state, can reach them.
-- `shared` alone isn't visible there; jeode.registerGlobal is.
if type(jeode) == "table" and type(jeode.registerGlobal) == "function" then
    -- On the loading screen, status is the loading line with its percentage
    -- ("Downloading Game Data 45%"), which the automatic message leaves out.
    nav.hudKey = function()
        local root = liveMenu("login_base")
        local status = root and shownText(root, "ConnectionStatus")
        if status then say(status, true) return end
        if liveMenu("hud_clubbox") and FRIENDLY.__clubStatus then
            local t = FRIENDLY.__clubStatus()
            if t then say(t, true) return end
        end
        if liveMenu("battle_base") and FRIENDLY.__battleHealth then
            local hp = FRIENDLY.__battleHealth()
            if hp then say(hp, true) return end
        end
        announceHud()
    end
    jeode.registerGlobal("a11y_announceHud", FRIENDLY.__keyGuard(nav.hudKey))
    jeode.registerGlobal("a11y_announcePopup", FRIENDLY.__keyGuard(announceCurrentPopup))
    jeode.registerGlobal("a11y_navNext", function() navMove(1) end)
    jeode.registerGlobal("a11y_navPrev", function() navMove(-1) end)
    jeode.registerGlobal("a11y_navEdge", function(dir) navMove(dir, true) end)
    jeode.registerGlobal("a11y_navActivate", navActivate)
    jeode.registerGlobal("a11y_menu", FRIENDLY.__keyGuard(openPlaces))
    jeode.registerGlobal("a11y_tutorialContinue", FRIENDLY.__keyGuard(tutorialContinue))
    jeode.registerGlobal("a11y_tutorial_announce", FRIENDLY.__keyGuard(announceTutorialStep))
    jeode.registerGlobal("a11y_dump", FRIENDLY.__keyGuard(dumpUI))
    jeode.registerGlobal("a11y_tutTick", tutTick)
    jeode.registerGlobal("a11y_tutGone", tutGone)
    jeode.registerGlobal("a11y_onTutorialPopup", onTutorialPopup)
    jeode.registerGlobal("a11y_menuTick", menuTick)
    jeode.registerGlobal("a11y_objects", FRIENDLY.__keyGuard(openObjects))
    jeode.registerGlobal("a11y_arrow", FRIENDLY.__keyGuard(arrow))
    jeode.registerGlobal("a11y_whatnow", FRIENDLY.__keyGuard(whatNow))
    jeode.registerGlobal("a11y_appearance", FRIENDLY.__keyGuard(function() FRIENDLY.__appearance() end))
    jeode.registerGlobal("a11y_xp", FRIENDLY.__keyGuard(function() FRIENDLY.__xp() end))
    -- Plain letters A, W, M, O, I, C, T: the same as their Control+Shift
    -- fallbacks, except while a text box is open (typing a name).
    jeode.registerGlobal("a11y_plainKey", function(what)
        if FRIENDLY.__keysLocked() then return end
        if nav.textEntryOpen and nav.textEntryOpen() then return end
        local run = {
            hud = nav.hudKey,
            whatnow = whatNow,
            menu = openPlaces,
            objects = openObjects,
            looks = function() FRIENDLY.__appearance() end,
            camera = nav.cameraKey,
            tutstep = announceTutorialStep,
            xp = function() FRIENDLY.__xp() end,
            advice = function() FRIENDLY.__advice() end,
        }
        local fn = run[what]
        if fn then fn() end
    end)
    jeode.registerGlobal("a11y_back", goBack)
    FRIENDLY.__goBack = goBack
    -- Comma and Period: free spots while placing, otherwise the same as
    -- Shift+Tab and Tab (Shift+Tab also opens the Steam overlay). Left alone
    -- while a text box is open, so names can have commas and full stops.
    jeode.registerGlobal("a11y_spot", function(dir)
        if FRIENDLY.__keysLocked() then return end
        if placing() then spotStep(dir) return end
        if nav.textEntryOpen and nav.textEntryOpen() then return end
        navMove(dir)
    end)
    -- Control Shift C: the game's own default island view (what it uses after
    -- the island fanfare). Placing re-centres on the object at the next arrow.
    nav.cameraKey = function()
        local ok, err = pcall(function() game.setDefaultCameraSettings() end)
        if not ok then
            a11y_log("[camera] setDefaultCameraSettings failed: " .. tostring(err))
            say("Can't reset the camera here", true)
            return
        end
        placeAt.t = -100
        say("Camera reset to the whole island", true)
    end
-- Sliders: Shift+Comma / Shift+Period step down / up, Shift+Home /
-- Shift+End go to the ends, Enter on a slider resets it. Each kind sets its
-- value the way dragging does (the game's own setter), then moves the knob.
-- A kind is either the focused element (CUSTOMIXER volumes) or the only
-- slider on an open screen (Time Warper, monster volume, decoration size).
function FRIENDLY.__pct(v) return math.floor(v * 100 + 0.5) .. " percent" end
function FRIENDLY.__knob(screen, x)
    later(0.05, function()
        local root = liveMenu(screen)
        local slider = root and findNamed(root, "Slider", 3)
        if slider then pcall(function() slider:C("Sprite")("xOffset"):SetFloat(x(slider:absW())) end) end
    end)
end
FRIENDLY.__sliderKinds = {
    -- Time Warper speed, 0.5 to 2 (1 is normal).
    { screen = "warp_popup", name = "Time warp", min = 0.5, max = 2, reset = 1, step = 0.1,
      get = function() return FRIENDLY.__warp.get() end,
      set = function(v) FRIENDLY.__warp.set(v) end, speaks = true },
    -- Monster volume (volume_popup.xml), 0 to 1.
    { screen = "volume_popup", name = "Monster volume", min = 0, max = 1, reset = 1, step = 0.1,
      get = function() local v = 1; pcall(function() v = tonumber(game.monsterVolume()) or 1 end) return v end,
      set = function(v)
          pcall(function() game.setMonsterVolume(v) end)
          FRIENDLY.__knob("volume_popup", function(w) return w * 0.85 * (v - 0.5) end)
      end,
      text = function(v) return FRIENDLY.__pct(v) end },
    -- Decoration size (scale_popup.xml), 0.7 to 1.1 (1 is normal).
    { screen = "scale_popup", name = "Decoration size", min = 0.7, max = 1.1, reset = 1, step = 0.05,
      get = function() local v = 1; pcall(function() v = tonumber(game.decorationScale()) or 1 end) return v end,
      set = function(v)
          pcall(function() game.setDecorationScale(v) end)
          FRIENDLY.__knob("scale_popup", function(w)
              local half = w * 0.85 / 2
              return v >= 1 and half * ((v - 1) / 0.1) or -half * ((1 - v) / 0.3)
          end)
      end,
      text = function(v) return FRIENDLY.__pct(v) end },
}
-- The CUSTOMIXER volume under focus, as a slider kind.
function FRIENDLY.__mixSliderKind(el)
    local isSlider = false
    pcall(function() isSlider = elementName(el) == "SliderBg" and elementName(el:parent()) == "VolumeControl" end)
    if not isSlider then return nil end
    local row, ind = FRIENDLY.__mixRow(el)
    if not row then return false end
    local audio = true
    pcall(function() audio = game.hasAudioTrack(ind) ~= false end)
    if not audio then return false end
    return { min = 0, max = 1, reset = 1, step = 0.1,
        get = function() local v = 0; pcall(function() v = game.clubboxPropVolume(ind) end) return v end,
        set = function(v)
            pcall(function() game.setClubboxPropVolume(ind, v) end)
            pcall(function()
                el.Touch.vol = game.clubboxPropVolume(ind)
                el.Touch:redraw(el)
            end)
            local t = FRIENDLY.__mixVolume(el)
            if t then nav.labels[nav.index] = t end
        end,
        text = function(v) return FRIENDLY.__pct(v) end }
end
-- dir: -1 / 1 a step; "min" / "max" the ends; "reset" the normal value.
function FRIENDLY.__adjust(dir)
    local el = nav.items and nav.items[nav.index]
    local kind = FRIENDLY.__mixSliderKind(el)
    if kind == false then say("This one can't be changed", true) return end
    if not kind then
        for _, k in ipairs(FRIENDLY.__sliderKinds) do
            if liveMenu(k.screen) then kind = k break end
        end
    end
    if not kind then say("Nothing to adjust here", true) return end
    local v = kind.get()
    local new
    if dir == "min" then new = kind.min
    elseif dir == "max" then new = kind.max
    elseif dir == "reset" then new = kind.reset
    else new = v + dir * kind.step end
    new = math.floor(new / kind.step + 0.5) * kind.step
    if new < kind.min then new = kind.min elseif new > kind.max then new = kind.max end
    kind.set(new)
    if kind.speaks then return end
    local now = kind.get()
    say((dir == "reset" and "Reset. " or "") .. kind.text(now), true)
end
    jeode.registerGlobal("a11y_camera", FRIENDLY.__keyGuard(nav.cameraKey))
    jeode.registerGlobal("a11y_adjust", FRIENDLY.__keyGuard(function(dir) FRIENDLY.__adjust(dir) end))
    -- F (fallback Control+Shift+F): advice for your island. How many trees
    -- and rocks are in the way, the cheapest one to clear (by its name in the
    -- Trees and rocks list, e.g. "Small Rock 3", with Tab focus moved onto it
    -- so Enter selects it), and whether coins are waiting.
    function FRIENDLY.__adviceCheapest()
        local r = nil
        pcall(function() r = game.getCheapestObstacle() end)
        if r == nil then pcall(function() r = game.getCheapestObstacle(game.player():getActiveIsland()) end) end
        local id = nil
        if type(r) == "number" then id = r
        elseif r ~= nil then
            for _, m in ipairs({ "id", "getId", "userStructureId", "uniqueId" }) do
                if not id then pcall(function() id = tonumber(r[m](r)) end) end
            end
        end
        if not FRIENDLY.__adviceLogged then
            FRIENDLY.__adviceLogged = true
            a11y_log("[advice] getCheapestObstacle -> " .. tostring(r) .. " (" .. type(r) .. "), id " .. tostring(id))
        end
        return id
    end
    function FRIENDLY.__commas(n)
        local t = tostring(math.floor(n))
        local out = t:reverse():gsub("(%d%d%d)", "%1,"):reverse()
        return (out:gsub("^,", ""))
    end
    function FRIENDLY.__advice()
        if popupOpen() or topOverlay() or placing() then say("Advice works on your island, with nothing open", true) return end
        if FRIENDLY.__visiting() or liveMenu("hud_clubbox") then say("Advice is for your own island", true) return end
        local objs = islandObjects()
        local parts, obstacles = {}, {}
        for _, o in ipairs(objs) do if o.rank == 3 or o.rank == 4 then obstacles[#obstacles + 1] = o end end
        local function busy(o)
            local t = (o.live and o.live() or o[1]):lower()
            return t:find("being removed", 1, true) or t:find("removal finished", 1, true)
        end
        local function kind(o) return (o.name:gsub("%s+%d+$", "")) end
        -- Which trees and rocks box in your monsters and buildings: within a
        -- few tiles of one (tiles from the native a11y_entity_tile; one tile
        -- per object, so this is close, not exact).
        local others = {}
        for _, l in ipairs(landmarks(true)) do
            if l.rank == 0 or l.rank == 1 then others[#others + 1] = l end
        end
        local blocking = {}
        for _, o in ipairs(obstacles) do
            local x, y = nil, nil
            pcall(function() x, y = entityTile(game.GetStructure(o.sid)) end)
            if x and not busy(o) then
                for _, l in ipairs(others) do
                    local reach = l.rank == 0 and 3 or 4
                    if abs(l.x - x) <= reach and abs(l.y - y) <= reach then
                        blocking[#blocking + 1] = o
                        break
                    end
                end
            end
        end
        if #obstacles == 0 then
            parts[#parts + 1] = "No trees or rocks left on this island"
        elseif #blocking == 0 then
            parts[#parts + 1] = "None of your " .. #obstacles .. " trees and rocks are right next to your monsters or buildings"
        else
            parts[#parts + 1] = #blocking .. " of your " .. #obstacles .. " trees and rocks "
                .. (#blocking == 1 and "is" or "are") .. " right next to your monsters or buildings"
        end
        -- Which of those to clear first: the game's cheapest kind, then kinds
        -- whose REMOVE price you've heard (cheapest first), then by size.
        local cid, cheapKind = FRIENDLY.__adviceCheapest(), nil
        for _, o in ipairs(obstacles) do if o.sid == cid then cheapKind = kind(o) end end
        local kindPrice = {}
        for _, o in ipairs(obstacles) do
            local pr = FRIENDLY.__sidPrice and FRIENDLY.__sidPrice[o.sid]
            if pr and (not kindPrice[kind(o)] or pr < kindPrice[kind(o)]) then kindPrice[kind(o)] = pr end
        end
        local function sizeRank(k)
            local l = k:lower()
            if l:find("small") or l:find("tiny") then return 1 end
            if l:find("medium") then return 2 end
            if l:find("big") or l:find("large") then return 3 end
            return 4
        end
        local function cost(o)
            if kind(o) == cheapKind then return -1 end
            return kindPrice[kind(o)] or (1e12 + sizeRank(kind(o)))
        end
        table.sort(blocking, function(a, b)
            local ca, cb = cost(a), cost(b)
            if ca ~= cb then return ca < cb end
            return a.name < b.name
        end)
        local target = blocking[1]
        if target then
            local pr = kindPrice[kind(target)]
            parts[#parts + 1] = "Easiest to clear first: " .. target.name
                .. (pr and (", " .. FRIENDLY.__commas(pr) .. " coins") or "")
            if #blocking > 1 then
                local more = {}
                for i = 2, math.min(3, #blocking) do more[#more + 1] = blocking[i].name end
                parts[#parts + 1] = "Then " .. table.concat(more, " and ")
                    .. (#blocking > 3 and (", and " .. (#blocking - 3) .. " more") or "")
            end
            parts[#parts + 1] = "Enter selects " .. target.name .. ", and REMOVE says the price"
        end
        local ready = false
        pcall(function() ready = game.player():getActiveIsland():hasMonsterCollectReady() and true or false end)
        if ready then parts[#parts + 1] = "Your monsters have coins to collect" end
        say(joinSentences(parts), true)
        -- Put Tab on that obstacle, so Enter selects it.
        if target then
            FRIENDLY.__objCache = nil
            nav.group = OBJECT_GROUPS[3]
            if navEnsure() then
                for i, lbl in ipairs(nav.labels) do
                    if lbl == target.name or lbl:sub(1, #target.name + 1) == target.name .. "," then
                        nav.index = i
                        break
                    end
                end
            end
        end
    end
    jeode.registerGlobal("a11y_advice", FRIENDLY.__keyGuard(function() FRIENDLY.__advice() end))
    jeode.registerGlobal("a11y_poi", function(dir)
        if FRIENDLY.__keysLocked() then return end
        if placing() then poiStep(dir) else navGroupJump(dir) end
    end)
    a11y_log("registered a11y_* globals (HUD, popup, nav, menu, dump) via jeode.registerGlobal")
else
    a11y_log("jeode.registerGlobal unavailable - hotkeys will not work")
end

say("Accessibility Lua layer ready", false)
a11y_log("init.lua loaded")
