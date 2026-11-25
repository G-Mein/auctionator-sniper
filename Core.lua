local addonName, NS = ...

_G.AuctionatorSniperBuyout = NS

NS.ICON_TEXTURE = "Interface\\AddOns\\AuctionatorSniperBuyout\\logo"

NS.PET_CAGE_ID = 82800
NS.WOW_TOKEN_ID = 122270

NS.DEFAULTS = {
	minProfitCopper = 1,
	minProfitPercent = 0,
	maxBuyoutCopper = 0,
	maxCommodityQty = 200,
	defaultSortField = "totalProfit",
	defaultSortAsc = false,
	hideOwnAuctions = true,
	autoOpenTab = false,
	playSound = true,
	chatSummary = true,
	confirmItemBuy = false,
	dbScanTodayOnly = true,
}

NS.SORT_DEFAULT_ASC = {
	name = true,
	qty = false,
	buyout = true,
	vendor = false,
	unitProfit = false,
	totalProfit = false,
}

local callbacks = {}

function NS.RegisterCallback(eventName, fn)
	if type(eventName) ~= "string" or type(fn) ~= "function" then
		return
	end
	if not callbacks[eventName] then
		callbacks[eventName] = {}
	end
	for _, existing in ipairs(callbacks[eventName]) do
		if existing == fn then
			return
		end
	end
	table.insert(callbacks[eventName], fn)
end

function NS.FireCallback(eventName, ...)
	local list = callbacks[eventName]
	if not list then
		return
	end
	for i = 1, #list do
		local ok, err = pcall(list[i], ...)
		if not ok and NS.Print then
			NS.Print("|cffff5555Callback-Fehler (" .. tostring(eventName) .. "):|r " .. tostring(err))
		end
	end
end

function NS.Clamp(val, minVal, maxVal)
	if val < minVal then
		return minVal
	end
	if val > maxVal then
		return maxVal
	end
	return val
end

function NS.IsSecret(val)
	if val == nil then
		return false
	end
	if type(issecretvalue) == "function" and issecretvalue(val) then
		return true
	end
	if type(canaccessvalue) == "function" and not canaccessvalue(val) then
		return true
	end
	return false
end

function NS.SafeVal(val)
	if NS.IsSecret(val) then
		return nil
	end
	return val
end

function NS.SafeGetMoney()
	if type(GetMoney) ~= "function" then
		return 0
	end
	local raw = NS.SafeVal(GetMoney())
	return tonumber(raw) or 0
end

function NS.SafePlayerName()
	if type(UnitName) ~= "function" then
		return nil
	end
	local name = NS.SafeVal(UnitName("player"))
	if type(name) == "string" and name ~= "" then
		return name
	end
	return nil
end

function NS.InitDB()
	local db = _G.AuctionatorSniperBuyoutDB
	if type(db) ~= "table" then
		db = {}
		_G.AuctionatorSniperBuyoutDB = db
	end
	for k, v in pairs(NS.DEFAULTS) do
		if db[k] == nil or type(db[k]) ~= type(v) then
			db[k] = v
		end
	end
	db.minProfitCopper = NS.Clamp(math.floor(tonumber(db.minProfitCopper) or 1), 1, 100000000)
	db.minProfitPercent = NS.Clamp(math.floor(tonumber(db.minProfitPercent) or 0), 0, 1000)
	db.maxBuyoutCopper = NS.Clamp(math.floor(tonumber(db.maxBuyoutCopper) or 0), 0, 1000000000)
	db.maxCommodityQty = NS.Clamp(math.floor(tonumber(db.maxCommodityQty) or 200), 1, 10000)
	if NS.SORT_DEFAULT_ASC[db.defaultSortField] == nil then
		db.defaultSortField = NS.DEFAULTS.defaultSortField
		db.defaultSortAsc = NS.DEFAULTS.defaultSortAsc
	end
	NS.db = db
	return db
end

function NS.GetDB()
	return NS.db or NS.InitDB()
end

function NS.ResetDB()
	local db = _G.AuctionatorSniperBuyoutDB
	if type(db) ~= "table" then
		db = {}
		_G.AuctionatorSniperBuyoutDB = db
	end
	for k, v in pairs(NS.DEFAULTS) do
		db[k] = v
	end
	NS.db = db
	if NS.Scanner then
		NS.Scanner:SetSort(db.defaultSortField, db.defaultSortAsc)
	end
	NS.FireCallback("OPTIONS_CHANGED")
	return db
end

function NS.FormatMoney(copper)
	local num = tonumber(copper)
	if not num then
		return "0c"
	end
	local neg = num < 0
	local absCopper = math.floor(math.abs(num) + 0.5)
	local text
	if type(GetMoneyString) == "function" then
		text = GetMoneyString(absCopper, true)
	elseif type(GetCoinTextureString) == "function" then
		text = GetCoinTextureString(absCopper)
	else
		local g = math.floor(absCopper / 10000)
		local s = math.floor((absCopper % 10000) / 100)
		local c = absCopper % 100
		if g > 0 then
			text = string.format("%dg %ds %dc", g, s, c)
		elseif s > 0 then
			text = string.format("%ds %dc", s, c)
		else
			text = string.format("%dc", c)
		end
	end
	if neg and absCopper > 0 then
		return "-" .. text
	end
	return text
end

function NS.FormatAge(ts)
	if not ts then
		return "Noch kein Scan"
	end
	local diff = math.max(0, time() - ts)
	if diff < 60 then
		return "vor wenigen Sek."
	elseif diff < 3600 then
		return string.format("vor %d Min.", math.floor(diff / 60))
	elseif diff < 86400 then
		return string.format("vor %d Std.", math.floor(diff / 3600))
	else
		return string.format("vor %d Tagen", math.floor(diff / 86400))
	end
end

function NS.IsVendorableInfo(itemInfo)
	if type(itemInfo) ~= "table" or #itemInfo == 0 then
		return false
	end
	if Auctionator and Auctionator.Utilities and type(Auctionator.Utilities.IsVendorable) == "function" then
		return Auctionator.Utilities.IsVendorable(itemInfo) == true
	end
	local rarity = NS.SafeVal(itemInfo[3])
	local sellPrice = tonumber(NS.SafeVal(itemInfo[11]))
	local isReagent = NS.SafeVal(itemInfo[17])
	local artifactEnum = Enum and Enum.ItemQuality and Enum.ItemQuality.Artifact or 6
	local legendaryEnum = Enum and Enum.ItemQuality and Enum.ItemQuality.Legendary or 5
	return sellPrice ~= nil and sellPrice > 0 and rarity ~= artifactEnum and (isReagent or rarity ~= legendaryEnum)
end

function NS.GetItemKeyString(itemKey)
	if type(itemKey) ~= "table" then
		return ""
	end
	if Auctionator and Auctionator.Utilities and type(Auctionator.Utilities.ItemKeyString) == "function" then
		return Auctionator.Utilities.ItemKeyString(itemKey)
	end
	return string.format(
		"%d %d %d %d",
		itemKey.itemID or 0,
		itemKey.itemSuffix or 0,
		itemKey.itemLevel or 0,
		itemKey.battlePetSpeciesID or 0
	)
end

function NS.IsEquipmentClass(classID)
	local cid = tonumber(NS.SafeVal(classID))
	if Auctionator and Auctionator.Utilities and type(Auctionator.Utilities.IsEquipment) == "function" then
		return Auctionator.Utilities.IsEquipment(cid) == true
	end
	if Enum and Enum.ItemClass then
		return cid == Enum.ItemClass.Weapon or cid == Enum.ItemClass.Armor
	end
	return cid == 2 or cid == 4
end

function NS.IsIncrementalScanRunning()
	return Auctionator
		and Auctionator.State
		and Auctionator.State.IncrementalScanFrameRef
		and Auctionator.State.IncrementalScanFrameRef.doingFullScan == true
end

function NS.IsAuctionHouseOpen()
	return AuctionHouseFrame ~= nil and AuctionHouseFrame:IsShown() == true
end

function NS.PlayDealSound()
	local kit = SOUNDKIT and (
		SOUNDKIT.LOOT_WINDOW_COIN_SOUND
		or SOUNDKIT.MONEY_FRAME_OPEN
		or SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON
		or SOUNDKIT.IG_MAINMENU_OPEN
	)
	if kit and type(PlaySound) == "function" then
		pcall(PlaySound, kit)
	end
end

function NS.InsertChatLink(link)
	if type(link) ~= "string" or link == "" then
		return
	end
	if Auctionator and Auctionator.Utilities and type(Auctionator.Utilities.InsertLink) == "function" then
		Auctionator.Utilities.InsertLink(link)
	elseif type(ChatEdit_InsertLink) == "function" then
		ChatEdit_InsertLink(link)
	end
end

function NS.TryDressUp(link)
	if type(link) ~= "string" or link == "" then
		return
	end
	if type(DressUpLink) == "function" then
		DressUpLink(link)
	elseif type(DressUpItemLink) == "function" then
		DressUpItemLink(link)
	end
end

function NS.Print(msg)
	local prefix = "|cff2ecc71[SniperBuyout]|r "
	if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
		DEFAULT_CHAT_FRAME:AddMessage(prefix .. tostring(msg))
	elseif type(print) == "function" then
		print(prefix .. tostring(msg))
	end
end
