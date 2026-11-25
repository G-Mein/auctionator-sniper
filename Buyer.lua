local _, NS = ...

local Buyer = {
	state = "IDLE",
	statusText = "Wähle ein Item aus der Liste, um Live-Preise zu prüfen.",
	isError = false,
	selected = nil,
	isCommodity = false,
	requestGen = 0,
	retryCount = 0,
	vendorRetryCount = 0,
	triedBrowseFallback = false,
	requireLiveVendorVerify = false,
	pendingQueueFn = nil,
	commodityPurchaseActive = false,
	itemBuyArmed = false,

	targetListing = nil,
	commodityTiers = {},
	maxBuyableQty = 0,
	skippedOwnQty = 0,
	desiredQty = 0,
	expectedTotal = 0,
	expectedProfit = 0,
	confirmedTotal = 0,
	confirmedProfit = 0,

	pendingPurchase = nil,
	sessionBoughtQty = 0,
	sessionProfitCopper = 0,
}
NS.Buyer = Buyer

local SEARCH_TIMEOUT_SEC = 6.0
local BUY_TIMEOUT_SEC = 6.0
local MAX_EMPTY_RETRIES = 2

local buyerFrame = CreateFrame("Frame")
local searchTimer = nil
local buyTimer = nil
local retryTimer = nil

local BASE_EVENTS = {
	"COMMODITY_SEARCH_RESULTS_UPDATED",
	"ITEM_SEARCH_RESULTS_UPDATED",
	"COMMODITY_PURCHASE_SUCCEEDED",
	"COMMODITY_PURCHASE_FAILED",
	"AUCTION_HOUSE_PURCHASE_COMPLETED",
	"AUCTION_HOUSE_CLOSED",
	"UI_ERROR_MESSAGE",
}

local PRICE_EVENTS = {
	"COMMODITY_PRICE_UPDATED",
	"COMMODITY_PRICE_UNAVAILABLE",
}

local BROWSE_EVENTS = {
	"AUCTION_HOUSE_BROWSE_RESULTS_UPDATED",
	"AUCTION_HOUSE_BROWSE_FAILURE",
}

local function CancelTimer(timerObj)
	if timerObj and type(timerObj.Cancel) == "function" then
		timerObj:Cancel()
	end
	return nil
end

local function UnregisterEventList(list)
	for _, ev in ipairs(list) do
		buyerFrame:UnregisterEvent(ev)
	end
end

local function RegisterEventList(list)
	for _, ev in ipairs(list) do
		buyerFrame:RegisterEvent(ev)
	end
end

local function CancelActiveCommodityPurchase()
	if Buyer.commodityPurchaseActive then
		Buyer.commodityPurchaseActive = false
		if C_AuctionHouse and C_AuctionHouse.CancelCommoditiesPurchase then
			pcall(C_AuctionHouse.CancelCommoditiesPurchase)
		end
	end
end

local function ScheduleReinspect(entry, myGen, delaySec)
	if not entry then
		return
	end
	local targetKey = entry.groupKey
	C_Timer.After(delaySec or 0.3, function()
		if myGen == Buyer.requestGen and Buyer.selected and Buyer.selected.groupKey == targetKey and NS.IsAuctionHouseOpen() then
			Buyer:InspectEntry(Buyer.selected, true)
		end
	end)
end

local function HasValidBuyLimits(totalCost, qty, vendorPrice)
	if not totalCost or totalCost <= 0 or not vendorPrice or vendorPrice <= 0 or not qty or qty <= 0 then
		return false
	end
	local maxVendor = vendorPrice * qty
	if totalCost >= maxVendor then
		return false
	end
	local db = NS.GetDB()
	local netProfit = maxVendor - totalCost
	local minRequired = (db.minProfitCopper <= 1) and 1 or (db.minProfitCopper * qty)
	if netProfit < minRequired then
		return false
	end
	if db.minProfitPercent > 0 then
		local pct = netProfit / totalCost * 100
		if pct < db.minProfitPercent then
			return false
		end
	end
	if totalCost > NS.SafeGetMoney() then
		return false
	end
	if db.maxBuyoutCopper > 0 and totalCost > db.maxBuyoutCopper then
		return false
	end
	return true
end

local function ComputeTiersForQty(tiers, qty, vendorPrice)
	local remaining = math.max(0, math.floor(tonumber(qty) or 0))
	local totalCost = 0
	local filled = 0
	for _, tier in ipairs(tiers) do
		if remaining <= 0 then
			break
		end
		local take = math.min(remaining, tier.quantity)
		if take > 0 then
			totalCost = totalCost + (take * tier.unitPrice)
			filled = filled + take
			remaining = remaining - take
		end
	end
	local totalProfit = math.max(0, (filled * vendorPrice) - totalCost)
	return filled, totalCost, totalProfit
end

local function ComputeAffordableQty(tiers, maxQty)
	local db = NS.GetDB()
	local budget = NS.SafeGetMoney()
	if db.maxBuyoutCopper > 0 and db.maxBuyoutCopper < budget then
		budget = db.maxBuyoutCopper
	end

	local runningQty = 0
	local runningCost = 0
	local bestAffordable = 0

	for _, tier in ipairs(tiers) do
		if runningQty >= maxQty then
			break
		end
		local availInTier = math.min(tier.quantity, maxQty - runningQty)
		if availInTier > 0 then
			if tier.unitPrice <= 0 then
				break
			end
			local canPay = math.floor((budget - runningCost) / tier.unitPrice)
			local take = math.min(availInTier, math.max(0, canPay))
			if take > 0 then
				runningQty = runningQty + take
				runningCost = runningCost + (take * tier.unitPrice)
				bestAffordable = runningQty
			end
			if take < availInTier then
				break
			end
		end
	end

	return math.max(0, bestAffordable)
end

function Buyer:FireState()
	NS.FireCallback("BUYER_STATE_CHANGED", self)
end

function Buyer:SetError(msg)
	self.state = "ERROR"
	self.isError = true
	self.statusText = tostring(msg or "Unbekannter Fehler.")
	self:FireState()
end

function Buyer:Reset(keepSelection)
	self.requestGen = self.requestGen + 1
	searchTimer = CancelTimer(searchTimer)
	buyTimer = CancelTimer(buyTimer)
	retryTimer = CancelTimer(retryTimer)

	if self.pendingQueueFn and Auctionator and Auctionator.AH and Auctionator.AH.Queue and Auctionator.AH.Queue.Remove then
		pcall(Auctionator.AH.Queue.Remove, Auctionator.AH.Queue, self.pendingQueueFn)
	end
	self.pendingQueueFn = nil

	CancelActiveCommodityPurchase()
	UnregisterEventList(PRICE_EVENTS)
	UnregisterEventList(BROWSE_EVENTS)

	self.itemBuyArmed = false
	self.retryCount = 0
	self.targetListing = nil
	wipe(self.commodityTiers)
	self.maxBuyableQty = 0
	self.skippedOwnQty = 0
	self.desiredQty = 0
	self.expectedTotal = 0
	self.expectedProfit = 0
	self.confirmedTotal = 0
	self.confirmedProfit = 0
	self.pendingPurchase = nil

	if not keepSelection then
		self.selected = nil
		self.vendorRetryCount = 0
		self.triedBrowseFallback = false
		self.requireLiveVendorVerify = false
		self.isCommodity = false
		self.state = "IDLE"
		self.isError = false
		self.statusText = "Wähle ein Item aus der Liste, um Live-Preise zu prüfen."
	end
	self:FireState()
end

function Buyer:SyncAfterScan(rawItemsByKey)
	if not self.selected or type(rawItemsByKey) ~= "table" then
		return
	end
	if self.state ~= "IDLE" and self.state ~= "READY_ITEM" and self.state ~= "READY_COMMODITY"
		and self.state ~= "UNAVAILABLE" and self.state ~= "ERROR"
	then
		return
	end
	local fresh = rawItemsByKey[self.selected.groupKey]
	if fresh then
		self.selected = fresh
	elseif self.state ~= "READY_ITEM" and self.state ~= "READY_COMMODITY" then
		self:Reset(false)
	end
end

function Buyer:OnTabShow()
	RegisterEventList(BASE_EVENTS)
	self:FireState()
end

function Buyer:OnTabHide()
	self:Reset(false)
	UnregisterEventList(BASE_EVENTS)
end

function Buyer:EnqueueAH(fn)
	if not NS.IsAuctionHouseOpen() then
		self:SetError("Auktionshaus ist geschlossen.")
		return false
	end
	if not (Auctionator and Auctionator.AH and Auctionator.AH.Queue and Auctionator.AH.Queue.Enqueue) then
		self:SetError("Auctionator-AH-Warteschlange nicht verfügbar.")
		return false
	end

	if self.pendingQueueFn and Auctionator.AH.Queue.Remove then
		pcall(Auctionator.AH.Queue.Remove, Auctionator.AH.Queue, self.pendingQueueFn)
		self.pendingQueueFn = nil
	end

	local myGen = self.requestGen
	local queuedFn
	queuedFn = function()
		if self.pendingQueueFn == queuedFn then
			self.pendingQueueFn = nil
		end
		if myGen ~= self.requestGen or not NS.IsAuctionHouseOpen() then
			return
		end
		local ok, err = pcall(fn)
		if not ok then
			self:SetError("AH-Anfrage fehlgeschlagen: " .. tostring(err))
		end
	end

	self.pendingQueueFn = queuedFn
	Auctionator.AH.Queue:Enqueue(queuedFn)
	return true
end

function Buyer:TryRetryEmptySearch(entry, myGen)
	if self.retryCount >= MAX_EMPTY_RETRIES then
		return false
	end
	self.retryCount = self.retryCount + 1
	local targetKey = entry.groupKey
	retryTimer = CancelTimer(retryTimer)
	retryTimer = C_Timer.NewTimer(0.4, function()
		retryTimer = nil
		if myGen == self.requestGen and self.state == "SEARCHING"
			and self.selected and self.selected.groupKey == targetKey and NS.IsAuctionHouseOpen()
		then
			self:SendLiveQuery(self.selected, myGen)
		end
	end)
	return true
end

function Buyer:StartBrowseFallback(entry, myGen)
	if self.triedBrowseFallback or NS.IsIncrementalScanRunning() or not entry.name or entry.name == "" then
		self.state = "UNAVAILABLE"
		self.isError = false
		self.statusText = "Nicht mehr im Auktionshaus gefunden (bereits verkauft)."
		NS.Scanner:MarkItemStatus(entry.groupKey, "SOLD_OUT")
		self:FireState()
		return
	end

	self.triedBrowseFallback = true
	self.state = "SEARCHING_BROWSE"
	self.isError = false
	self.statusText = "Suche exakten ItemKey über AH-Übersicht..."
	self:FireState()

	RegisterEventList(BROWSE_EVENTS)
	searchTimer = CancelTimer(searchTimer)
	searchTimer = C_Timer.NewTimer(SEARCH_TIMEOUT_SEC, function()
		searchTimer = nil
		if myGen == self.requestGen and self.state == "SEARCHING_BROWSE" then
			UnregisterEventList(BROWSE_EVENTS)
			self.state = "UNAVAILABLE"
			self.statusText = "Zeitüberschreitung bei der Übersichtssuche."
			self:FireState()
		end
	end)

	self:EnqueueAH(function()
		if NS.IsIncrementalScanRunning() then
			error("Auctionator Full Scan läuft gerade")
		end
		local priceOrder = (Enum and Enum.AuctionHouseSortOrder and Enum.AuctionHouseSortOrder.Price) or 0
		C_AuctionHouse.SendBrowseQuery({
			searchString = entry.name,
			sorts = { { sortOrder = priceOrder, reverseSort = false } },
			filters = {},
			itemClassFilters = {},
		})
	end)
end

function Buyer:SendLiveQuery(entry, myGen)
	retryTimer = CancelTimer(retryTimer)
	self.state = "SEARCHING"
	self.isError = false
	self.statusText = "Frage aktuelle Live-Auktionen ab..."
	self:FireState()

	searchTimer = CancelTimer(searchTimer)
	searchTimer = C_Timer.NewTimer(SEARCH_TIMEOUT_SEC, function()
		searchTimer = nil
		if myGen == self.requestGen and self.state == "SEARCHING" then
			self.state = "UNAVAILABLE"
			self.isError = true
			self.statusText = "Live-Abfrage hat nicht rechtzeitig geantwortet."
			self:FireState()
		end
	end)

	self:EnqueueAH(function()
		if self.isCommodity then
			local priceSort = (Enum and Enum.AuctionHouseSortOrder and Enum.AuctionHouseSortOrder.Price) or 0
			C_AuctionHouse.SendSearchQuery(
				entry.itemKey,
				{ { sortOrder = priceSort, reverseSort = false } },
				false
			)
		else
			local buyoutSort = (Enum and Enum.AuctionHouseSortOrder and Enum.AuctionHouseSortOrder.Buyout) or 4
			C_AuctionHouse.SendSearchQuery(
				entry.itemKey,
				{ { sortOrder = buyoutSort, reverseSort = false } },
				true
			)
		end
	end)
end

function Buyer:InspectEntry(entry, preserveFlags)
	if not entry then
		return
	end
	if not NS.IsAuctionHouseOpen() then
		self:SetError("Bitte zuerst das Auktionshaus öffnen.")
		return
	end

	local prevTried = preserveFlags and self.triedBrowseFallback or false
	local prevRequireVerify = preserveFlags and self.requireLiveVendorVerify or false
	local prevVendorRetries = preserveFlags and self.vendorRetryCount or 0
	self:Reset(true)
	self.selected = entry
	self.triedBrowseFallback = prevTried
	self.requireLiveVendorVerify = prevRequireVerify
	self.vendorRetryCount = prevVendorRetries
	self.state = "LOADING_KEY"
	self.isError = false
	self.statusText = "Lade Item-Schlüssel..."
	self:FireState()

	local myGen = self.requestGen
	searchTimer = C_Timer.NewTimer(SEARCH_TIMEOUT_SEC, function()
		searchTimer = nil
		if myGen == self.requestGen and self.state == "LOADING_KEY" then
			self.state = "UNAVAILABLE"
			self.isError = true
			self.statusText = "Item-Schlüssel konnte nicht rechtzeitig geladen werden."
			self:FireState()
		end
	end)

	local targetKey = entry.groupKey
	if Auctionator and Auctionator.AH and Auctionator.AH.GetItemKeyInfo then
		Auctionator.AH.GetItemKeyInfo(entry.itemKey, function(itemKeyInfo)
			if myGen ~= self.requestGen or not self.selected or self.selected.groupKey ~= targetKey then
				return
			end
			searchTimer = CancelTimer(searchTimer)
			self.isCommodity = itemKeyInfo ~= nil and itemKeyInfo.isCommodity == true
			self:SendLiveQuery(self.selected, myGen)
		end)
	else
		searchTimer = CancelTimer(searchTimer)
		local info = C_AuctionHouse and C_AuctionHouse.GetItemKeyInfo and C_AuctionHouse.GetItemKeyInfo(entry.itemKey)
		self.isCommodity = info ~= nil and info.isCommodity == true
		self:SendLiveQuery(entry, myGen)
	end
end

function Buyer:ProcessItemResults(itemKey)
	local entry = self.selected
	if not entry then
		return
	end

	local db = NS.GetDB()
	local totalResults = tonumber(NS.SafeVal(C_AuctionHouse.GetNumItemSearchResults(itemKey))) or 0
	local listings = {}
	local totalProfit = 0
	local totalBuyoutSum = 0
	local ownProfitableCount = 0
	local uncachedVendorCount = 0

	for i = 1, totalResults do
		local info = C_AuctionHouse.GetItemSearchResultInfo(itemKey, i)
		if info then
			local auctionID = NS.SafeVal(info.auctionID)
			local buyoutAmount = tonumber(NS.SafeVal(info.buyoutAmount))
			local link = NS.SafeVal(info.itemLink)
			local isOwner = NS.SafeVal(info.containsOwnerItem) == true
			local isAccount = NS.SafeVal(info.containsAccountItem) == true

			if auctionID and buyoutAmount and buyoutAmount > 0 then
				local sellPrice = nil
				local vendorValid = false

				if type(link) == "string" and link ~= "" then
					local liveInfo = { C_Item.GetItemInfo(link) }
					if #liveInfo > 0 then
						local sp = tonumber(NS.SafeVal(liveInfo[11]))
						if NS.IsVendorableInfo(liveInfo) and sp and sp > 0 then
							sellPrice = sp
							vendorValid = true
						end
					else
						uncachedVendorCount = uncachedVendorCount + 1
						if C_Item and C_Item.RequestLoadItemDataByID then
							C_Item.RequestLoadItemDataByID(entry.itemID)
						end
					end
				elseif not self.requireLiveVendorVerify and entry.vendorPrice and entry.vendorPrice > 0 then
					sellPrice = entry.vendorPrice
					vendorValid = true
				end

				if vendorValid and sellPrice and buyoutAmount < sellPrice then
					local profit = sellPrice - buyoutAmount
					local pct = profit / buyoutAmount * 100
					if profit >= db.minProfitCopper and pct >= db.minProfitPercent then
						if isOwner or isAccount then
							ownProfitableCount = ownProfitableCount + 1
						else
							totalProfit = totalProfit + profit
							totalBuyoutSum = totalBuyoutSum + buyoutAmount
							table.insert(listings, {
								auctionID = auctionID,
								buyoutAmount = buyoutAmount,
								vendorPrice = sellPrice,
								profit = profit,
								itemLink = link or entry.itemLink,
							})
						end
					end
				end
			end
		end
	end

	table.sort(listings, function(a, b)
		if a.buyoutAmount ~= b.buyoutAmount then
			return a.buyoutAmount < b.buyoutAmount
		end
		return a.auctionID < b.auctionID
	end)

	self.itemBuyArmed = false

	if #listings == 0 then
		self.targetListing = nil
		if uncachedVendorCount > 0 and self.vendorRetryCount < MAX_EMPTY_RETRIES then
			self.vendorRetryCount = self.vendorRetryCount + 1
			self.state = "LOADING_KEY"
			self.isError = false
			self.statusText = "Lade exakten Live-Vendor-Wert..."
			self:FireState()
			ScheduleReinspect(entry, self.requestGen, 0.35)
			return
		end
		if ownProfitableCount > 0 then
			self.state = "UNAVAILABLE"
			self.isError = false
			self.statusText = "Nur eigene Auktionen unter Vendor-Wert vorhanden."
			NS.Scanner:UpdateItemFromLive(entry.groupKey, {
				itemKey = itemKey,
				profitableQty = ownProfitableCount,
				containsOwn = true,
				allOwn = true,
				status = "LIVE",
			})
		else
			self.state = "UNAVAILABLE"
			self.isError = false
			self.statusText = "Keine verifizierte Auktion unter Vendor-Verkaufswert."
			NS.Scanner:MarkItemStatus(entry.groupKey, "NOT_PROFITABLE")
		end
		self:FireState()
		return
	end

	local best = listings[1]
	self.vendorRetryCount = 0
	self.targetListing = best
	self.expectedTotal = best.buyoutAmount
	self.expectedProfit = best.profit
	self.desiredQty = 1

	NS.Scanner:UpdateItemFromLive(entry.groupKey, {
		itemKey = itemKey,
		itemLink = best.itemLink,
		vendorPrice = best.vendorPrice,
		cheapestBuyout = best.buyoutAmount,
		profitableQty = #listings,
		totalProfit = totalProfit,
		totalBuyoutCost = totalBuyoutSum,
		containsOwn = ownProfitableCount > 0,
		allOwn = false,
		status = "LIVE",
	})

	self.state = "READY_ITEM"
	self.isError = false
	local money = NS.SafeGetMoney()
	if best.buyoutAmount > money then
		self.statusText = string.format(
			"Live: %d Stk gefunden, aber nicht genug Gold (%s benötigt).",
			#listings,
			NS.FormatMoney(best.buyoutAmount)
		)
	elseif db.maxBuyoutCopper > 0 and best.buyoutAmount > db.maxBuyoutCopper then
		self.statusText = string.format(
			"Live: Buyout %s überschreitet Sicherheitslimit (%s).",
			NS.FormatMoney(best.buyoutAmount),
			NS.FormatMoney(db.maxBuyoutCopper)
		)
	else
		self.statusText = string.format(
			"Live bestätigt: %d Auktion(en) unter Vendor-Wert | Gewinn: +%s",
			#listings,
			NS.FormatMoney(best.profit)
		)
	end
	self:FireState()
end

function Buyer:ProcessCommodityResults(itemID)
	local entry = self.selected
	if not entry then
		return
	end

	local db = NS.GetDB()
	local vendorPrice = entry.vendorPrice
	local numRows = tonumber(NS.SafeVal(C_AuctionHouse.GetNumCommoditySearchResults(itemID))) or 0
	local tiers = {}
	local totalQty = 0
	local totalProfitAll = 0
	local totalCostAll = 0
	local cheapestBuyout = nil
	local skippedOwn = 0

	for i = 1, numRows do
		local info = C_AuctionHouse.GetCommoditySearchResultInfo(itemID, i)
		if info then
			local unitPrice = tonumber(NS.SafeVal(info.unitPrice))
			local quantity = tonumber(NS.SafeVal(info.quantity))
			local isOwner = NS.SafeVal(info.containsOwnerItem) == true
			local isAccount = NS.SafeVal(info.containsAccountItem) == true
			if unitPrice and unitPrice > 0 and quantity and quantity > 0 then
				if unitPrice >= vendorPrice then
					break
				end
				local unitProfit = vendorPrice - unitPrice
				local pct = unitProfit / unitPrice * 100
				if unitProfit >= db.minProfitCopper and pct >= db.minProfitPercent then
					if isOwner or isAccount then
						skippedOwn = skippedOwn + quantity
					else
						if not cheapestBuyout or unitPrice < cheapestBuyout then
							cheapestBuyout = unitPrice
						end
						totalQty = totalQty + quantity
						totalCostAll = totalCostAll + (unitPrice * quantity)
						totalProfitAll = totalProfitAll + (unitProfit * quantity)
						table.insert(tiers, {
							unitPrice = unitPrice,
							quantity = quantity,
						})
					end
				end
			end
		end
	end

	self.commodityTiers = tiers
	self.maxBuyableQty = totalQty
	self.skippedOwnQty = skippedOwn

	if totalQty == 0 or not cheapestBuyout then
		self.desiredQty = 0
		if skippedOwn > 0 then
			self.state = "UNAVAILABLE"
			self.isError = false
			self.statusText = string.format("Nur %dx eigene Ware unter Vendor-Wert gefunden.", skippedOwn)
			NS.Scanner:UpdateItemFromLive(entry.groupKey, {
				profitableQty = skippedOwn,
				containsOwn = true,
				allOwn = true,
				status = "LIVE",
			})
		else
			self.state = "UNAVAILABLE"
			self.isError = false
			self.statusText = "Keine Stapelware mehr unter Vendor-Verkaufswert."
			NS.Scanner:MarkItemStatus(entry.groupKey, "NOT_PROFITABLE")
		end
		self:FireState()
		return
	end

	NS.Scanner:UpdateItemFromLive(entry.groupKey, {
		cheapestBuyout = cheapestBuyout,
		profitableQty = totalQty,
		totalProfit = totalProfitAll,
		totalBuyoutCost = totalCostAll,
		containsOwn = skippedOwn > 0,
		allOwn = false,
		status = "LIVE",
	})

	local defaultCap = math.min(totalQty, db.maxCommodityQty)
	local affordable = ComputeAffordableQty(tiers, defaultCap)
	local chosen = (affordable > 0) and affordable or math.min(1, totalQty)
	self:SetCommodityQuantity(chosen, true)

	self.state = "READY_COMMODITY"
	self.isError = false
	self.statusText = string.format(
		"Live bestätigt: %d Stk kaufbar (Klick 1: Preis sperren, Klick 2: Kaufen).",
		totalQty
	)
	self:FireState()
end

function Buyer:SetCommodityQuantity(qty, silent)
	if not self.selected or #self.commodityTiers == 0 then
		return
	end
	local q = math.floor(tonumber(qty) or 0)
	local db = NS.GetDB()
	local maxAllowed = math.min(self.maxBuyableQty, math.max(1, db.maxCommodityQty))
	q = NS.Clamp(q, 1, math.max(1, maxAllowed))

	local filled, totalCost, profit = ComputeTiersForQty(
		self.commodityTiers,
		q,
		self.selected.vendorPrice
	)
	self.desiredQty = filled
	self.expectedTotal = totalCost
	self.expectedProfit = profit
	if not silent then
		self:FireState()
	end
end

function Buyer:CanExecutePrimary()
	if not NS.IsAuctionHouseOpen() or (type(InCombatLockdown) == "function" and InCombatLockdown()) then
		return false
	end
	local entry = self.selected
	if not entry then
		return false
	end

	if self.state == "READY_ITEM" then
		local l = self.targetListing
		return l ~= nil and l.auctionID ~= nil and HasValidBuyLimits(l.buyoutAmount, 1, l.vendorPrice)
	elseif self.state == "READY_COMMODITY" then
		return HasValidBuyLimits(self.expectedTotal, self.desiredQty, entry.vendorPrice)
	elseif self.state == "CONFIRM_COMMODITY" then
		return HasValidBuyLimits(self.confirmedTotal, self.desiredQty, entry.vendorPrice)
	end
	return false
end

function Buyer:ExecutePrimaryAction()
	if type(InCombatLockdown) == "function" and InCombatLockdown() then
		self:SetError("Kauf im Kampf nicht möglich.")
		return
	end
	if not NS.IsAuctionHouseOpen() then
		self:SetError("Auktionshaus ist geschlossen.")
		return
	end
	local entry = self.selected
	if not entry then
		return
	end
	retryTimer = CancelTimer(retryTimer)
	local db = NS.GetDB()

	if self.state == "READY_ITEM" then
		local l = self.targetListing
		if not l or not l.auctionID or not HasValidBuyLimits(l.buyoutAmount, 1, l.vendorPrice) then
			self:SetError("Sicherheitsabbruch: Preis-, Filter- oder Goldlimit verletzt.")
			return
		end
		if db.confirmItemBuy and not self.itemBuyArmed then
			self.itemBuyArmed = true
			self.isError = false
			self.statusText = string.format(
				"Sicherheits-Bestätigung aktiv: Erneut klicken für Kauf (%s)!",
				NS.FormatMoney(l.buyoutAmount)
			)
			self:FireState()
			return
		end

		self.itemBuyArmed = false
		self.pendingPurchase = {
			isCommodity = false,
			qty = 1,
			cost = l.buyoutAmount,
			profit = l.vendorPrice - l.buyoutAmount,
			groupKey = entry.groupKey,
			itemName = entry.name,
		}
		self.state = "BUYING"
		self.isError = false
		self.statusText = "Sende Sofortkauf..."
		self:FireState()

		buyTimer = CancelTimer(buyTimer)
		local myGen = self.requestGen
		buyTimer = C_Timer.NewTimer(BUY_TIMEOUT_SEC, function()
			buyTimer = nil
			if myGen == self.requestGen and self.state == "BUYING" then
				self.pendingPurchase = nil
				self:SetError("Kauf-Antwort ausgeblieben. Prüfe Live-Bestand...")
				ScheduleReinspect(entry, myGen, 0.25)
			end
		end)

		C_AuctionHouse.PlaceBid(l.auctionID, l.buyoutAmount)

	elseif self.state == "READY_COMMODITY" then
		if not self:CanExecutePrimary() then
			self:SetError("Kauf durch Filter-, Geld- oder Sicherheitslimit blockiert.")
			return
		end
		self.state = "LOCKING_COMMODITY"
		self.isError = false
		self.commodityPurchaseActive = true
		self.statusText = string.format("Reserviere %dx Stapelware & prüfe Live-Preis...", self.desiredQty)
		RegisterEventList(PRICE_EVENTS)
		self:FireState()

		local myGen = self.requestGen
		searchTimer = CancelTimer(searchTimer)
		searchTimer = C_Timer.NewTimer(SEARCH_TIMEOUT_SEC, function()
			searchTimer = nil
			if myGen == self.requestGen and self.state == "LOCKING_COMMODITY" then
				UnregisterEventList(PRICE_EVENTS)
				CancelActiveCommodityPurchase()
				self:SetError("Preis-Reservierung abgelaufen.")
			end
		end)

		C_AuctionHouse.StartCommoditiesPurchase(entry.itemID, self.desiredQty)

	elseif self.state == "CONFIRM_COMMODITY" then
		if not self:CanExecutePrimary() then
			CancelActiveCommodityPurchase()
			self:SetError("Sicherheitsabbruch vor Bestätigung.")
			return
		end
		self.commodityPurchaseActive = false
		self.pendingPurchase = {
			isCommodity = true,
			qty = self.desiredQty,
			cost = self.confirmedTotal,
			profit = self.confirmedProfit,
			groupKey = entry.groupKey,
			itemName = entry.name,
		}
		self.state = "BUYING"
		self.isError = false
		self.statusText = string.format("Schließe Kauf von %dx ab...", self.desiredQty)
		self:FireState()

		buyTimer = CancelTimer(buyTimer)
		local myGen = self.requestGen
		buyTimer = C_Timer.NewTimer(BUY_TIMEOUT_SEC, function()
			buyTimer = nil
			if myGen == self.requestGen and self.state == "BUYING" then
				self.pendingPurchase = nil
				self:SetError("Kaufbestätigung ohne Rückmeldung. Prüfe Live-Preise...")
				ScheduleReinspect(entry, myGen, 0.25)
			end
		end)

		-- WoW ModernAH / Auctionator erwartet exakt 2 Argumente: (itemID, quantity).
		C_AuctionHouse.ConfirmCommoditiesPurchase(entry.itemID, self.desiredQty)
	end
end

function Buyer:SelectNextItem()
	local curKey = self.selected and self.selected.groupKey or nil
	local nextEntry = NS.Scanner:GetNextAvailableItem(curKey)
	if nextEntry then
		self:InspectEntry(nextEntry)
	else
		self:Reset(false)
	end
end

local function HandlePurchaseSuccess()
	buyTimer = CancelTimer(buyTimer)
	local p = Buyer.pendingPurchase
	Buyer.pendingPurchase = nil
	if p then
		Buyer.sessionBoughtQty = Buyer.sessionBoughtQty + (p.qty or 1)
		Buyer.sessionProfitCopper = Buyer.sessionProfitCopper + (p.profit or 0)
		local db = NS.GetDB()
		if db.playSound then
			NS.PlayDealSound()
		end
		NS.Print(string.format(
			"Gekauft: %dx %s für %s (Gewinn: +%s)",
			p.qty or 1,
			p.itemName or "Item",
			NS.FormatMoney(p.cost or 0),
			NS.FormatMoney(p.profit or 0)
		))
	end
	Buyer.state = "DONE"
	Buyer.isError = false
	Buyer.statusText = "Kauf erfolgreich! Aktualisiere Angebote..."
	NS.FireCallback("PURCHASE_SUCCEEDED", Buyer.sessionBoughtQty, Buyer.sessionProfitCopper)
	Buyer:FireState()

	ScheduleReinspect(Buyer.selected, Buyer.requestGen, 0.3)
end

buyerFrame:SetScript("OnEvent", function(_, event, arg1, arg2)
	if event == "AUCTION_HOUSE_CLOSED" then
		Buyer:OnTabHide()
		return
	end

	local entry = Buyer.selected
	local myGen = Buyer.requestGen

	if event == "UI_ERROR_MESSAGE" then
		if Buyer.state == "BUYING" or Buyer.state == "LOCKING_COMMODITY" then
			local safeMsg = NS.SafeVal(arg2) or NS.SafeVal(arg1)
			local errMsg = safeMsg and tostring(safeMsg) or "Auktionshaus-Fehler (geschützte Meldung)"
			buyTimer = CancelTimer(buyTimer)
			searchTimer = CancelTimer(searchTimer)
			Buyer.pendingPurchase = nil
			CancelActiveCommodityPurchase()
			Buyer:SetError("AH-Fehler: " .. errMsg)
			ScheduleReinspect(entry, myGen, 0.3)
		end
		return
	end

	local safe1 = NS.SafeVal(arg1)
	local safe2 = NS.SafeVal(arg2)

	if event == "COMMODITY_SEARCH_RESULTS_UPDATED" then
		if Buyer.state ~= "SEARCHING" or not entry or not Buyer.isCommodity or safe1 ~= entry.itemID then
			return
		end
		searchTimer = CancelTimer(searchTimer)
		retryTimer = CancelTimer(retryTimer)
		local itemKey = C_AuctionHouse.MakeItemKey(entry.itemID)
		local has = C_AuctionHouse.HasSearchResults(itemKey)
		local full = C_AuctionHouse.HasFullCommoditySearchResults(entry.itemID)
		local qty = tonumber(NS.SafeVal(C_AuctionHouse.GetCommoditySearchResultsQuantity(entry.itemID))) or 0
		if has and not full and qty == 0 and Buyer:TryRetryEmptySearch(entry, myGen) then
			return
		end
		if not has or qty == 0 then
			Buyer.state = "UNAVAILABLE"
			Buyer.isError = false
			Buyer.statusText = "Keine Stapelware mehr im Auktionshaus."
			NS.Scanner:MarkItemStatus(entry.groupKey, "SOLD_OUT")
			Buyer:FireState()
			return
		end
		Buyer:ProcessCommodityResults(entry.itemID)

	elseif event == "ITEM_SEARCH_RESULTS_UPDATED" then
		if Buyer.state ~= "SEARCHING" or not entry or Buyer.isCommodity or type(safe1) ~= "table" then
			return
		end
		if NS.GetItemKeyString(safe1) ~= NS.GetItemKeyString(entry.itemKey) then
			return
		end
		searchTimer = CancelTimer(searchTimer)
		retryTimer = CancelTimer(retryTimer)
		local has = C_AuctionHouse.HasSearchResults(safe1)
		local full = C_AuctionHouse.HasFullItemSearchResults(safe1)
		local qty = tonumber(NS.SafeVal(C_AuctionHouse.GetItemSearchResultsQuantity(safe1))) or 0
		if has and not full and qty == 0 and Buyer:TryRetryEmptySearch(entry, myGen) then
			return
		end
		if not has or qty == 0 then
			if (entry.source == "replicate" or entry.source == "database") and not Buyer.triedBrowseFallback then
				Buyer:StartBrowseFallback(entry, myGen)
			else
				Buyer.state = "UNAVAILABLE"
				Buyer.isError = false
				Buyer.statusText = "Nicht mehr verfügbar (bereits verkauft)."
				NS.Scanner:MarkItemStatus(entry.groupKey, "SOLD_OUT")
				Buyer:FireState()
			end
			return
		end
		Buyer:ProcessItemResults(safe1)

	elseif event == "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED" then
		if Buyer.state ~= "SEARCHING_BROWSE" or not entry then
			return
		end
		searchTimer = CancelTimer(searchTimer)
		UnregisterEventList(BROWSE_EVENTS)
		local results = C_AuctionHouse.GetBrowseResults and C_AuctionHouse.GetBrowseResults() or {}
		local bestMatch = nil
		local wantIlvl = (entry.itemKey and entry.itemKey.itemLevel and entry.itemKey.itemLevel > 0 and entry.itemKey.itemLevel)
			or (entry.expectedItemLevel and entry.expectedItemLevel > 0 and entry.expectedItemLevel)
			or nil
		local wantSuffix = (entry.itemKey and entry.itemKey.itemSuffix and entry.itemKey.itemSuffix > 0) and entry.itemKey.itemSuffix or nil

		for _, res in ipairs(results) do
			if res and res.itemKey and NS.SafeVal(res.itemKey.itemID) == entry.itemID then
				local minPrice = tonumber(NS.SafeVal(res.minPrice))
				local totalQty = tonumber(NS.SafeVal(res.totalQuantity)) or 0
				local ilvl = tonumber(NS.SafeVal(res.itemKey.itemLevel)) or 0
				local suffix = tonumber(NS.SafeVal(res.itemKey.itemSuffix)) or 0
				local ilvlOk = (not wantIlvl) or (ilvl == 0) or (ilvl == wantIlvl)
				local suffixOk = (not wantSuffix) or (suffix == wantSuffix)
				if minPrice and minPrice > 0 and minPrice < entry.vendorPrice and totalQty > 0 and ilvlOk and suffixOk then
					if not bestMatch or minPrice < bestMatch.minPrice then
						bestMatch = res
					end
				end
			end
		end

		if bestMatch then
			entry.itemKey = bestMatch.itemKey
			Buyer.requireLiveVendorVerify = true
			local targetKey = entry.groupKey
			if Auctionator and Auctionator.AH and Auctionator.AH.GetItemKeyInfo then
				Buyer.state = "LOADING_KEY"
				Buyer.isError = false
				Buyer.statusText = "Lade exakten Item-Schlüssel..."
				Buyer:FireState()
				searchTimer = C_Timer.NewTimer(SEARCH_TIMEOUT_SEC, function()
					searchTimer = nil
					if myGen == Buyer.requestGen and Buyer.state == "LOADING_KEY" then
						Buyer.state = "UNAVAILABLE"
						Buyer.isError = true
						Buyer.statusText = "Item-Schlüssel konnte nicht rechtzeitig geladen werden."
						Buyer:FireState()
					end
				end)
				Auctionator.AH.GetItemKeyInfo(entry.itemKey, function(itemKeyInfo)
					if myGen ~= Buyer.requestGen or not Buyer.selected or Buyer.selected.groupKey ~= targetKey or not NS.IsAuctionHouseOpen() then
						return
					end
					searchTimer = CancelTimer(searchTimer)
					Buyer.isCommodity = itemKeyInfo ~= nil and itemKeyInfo.isCommodity == true
					Buyer:SendLiveQuery(Buyer.selected, myGen)
				end)
			else
				local info = C_AuctionHouse and C_AuctionHouse.GetItemKeyInfo and C_AuctionHouse.GetItemKeyInfo(entry.itemKey)
				Buyer.isCommodity = info ~= nil and info.isCommodity == true
				Buyer:SendLiveQuery(entry, myGen)
			end
		else
			Buyer.state = "UNAVAILABLE"
			Buyer.isError = false
			Buyer.statusText = "Keine passende Variante unter Vendor-Wert gefunden."
			NS.Scanner:MarkItemStatus(entry.groupKey, "SOLD_OUT")
			Buyer:FireState()
		end

	elseif event == "AUCTION_HOUSE_BROWSE_FAILURE" then
		if Buyer.state ~= "SEARCHING_BROWSE" then
			return
		end
		searchTimer = CancelTimer(searchTimer)
		UnregisterEventList(BROWSE_EVENTS)
		Buyer:SetError("Übersichtssuche fehlgeschlagen.")

	elseif event == "COMMODITY_PRICE_UPDATED" then
		if Buyer.state ~= "LOCKING_COMMODITY" or not entry then
			return
		end
		searchTimer = CancelTimer(searchTimer)
		UnregisterEventList(PRICE_EVENTS)

		local newUnitPrice = tonumber(safe1)
		local newTotalPrice = tonumber(safe2)
		if not newUnitPrice or not newTotalPrice or newTotalPrice <= 0 then
			CancelActiveCommodityPurchase()
			Buyer:SetError("Ungültiger Live-Preis vom Server.")
			return
		end

		if not HasValidBuyLimits(newTotalPrice, Buyer.desiredQty, entry.vendorPrice) then
			CancelActiveCommodityPurchase()
			Buyer:SetError(string.format(
				"Abgebrochen! Live-Preis gestiegen (%s verletzt Vendor-/Filter-/Geldlimit).",
				NS.FormatMoney(newTotalPrice)
			))
			ScheduleReinspect(entry, myGen, 0.3)
			return
		end

		local netProfit = (entry.vendorPrice * Buyer.desiredQty) - newTotalPrice
		Buyer.confirmedTotal = newTotalPrice
		Buyer.confirmedProfit = netProfit
		Buyer.state = "CONFIRM_COMMODITY"
		Buyer.isError = false
		if newTotalPrice > Buyer.expectedTotal then
			Buyer.statusText = string.format(
				"Preis leicht gestiegen auf %s, aber noch +%s Gewinn! Jetzt bestätigen.",
				NS.FormatMoney(newTotalPrice),
				NS.FormatMoney(netProfit)
			)
		else
			Buyer.statusText = string.format(
				"Preis gesperrt: %dx für %s (Gewinn: +%s). Klicke 'Bestätigen'!",
				Buyer.desiredQty,
				NS.FormatMoney(newTotalPrice),
				NS.FormatMoney(netProfit)
			)
		end
		Buyer:FireState()

	elseif event == "COMMODITY_PRICE_UNAVAILABLE" then
		if Buyer.state ~= "LOCKING_COMMODITY" then
			return
		end
		searchTimer = CancelTimer(searchTimer)
		UnregisterEventList(PRICE_EVENTS)
		CancelActiveCommodityPurchase()
		Buyer:SetError("Gewünschte Menge nicht mehr verfügbar. Lade Live-Bestand neu...")
		ScheduleReinspect(entry, myGen, 0.3)

	elseif event == "COMMODITY_PURCHASE_SUCCEEDED" or event == "AUCTION_HOUSE_PURCHASE_COMPLETED" then
		if Buyer.state == "BUYING" then
			HandlePurchaseSuccess()
		end

	elseif event == "COMMODITY_PURCHASE_FAILED" then
		if Buyer.state == "BUYING" or Buyer.state == "LOCKING_COMMODITY" or Buyer.state == "CONFIRM_COMMODITY" then
			buyTimer = CancelTimer(buyTimer)
			Buyer.pendingPurchase = nil
			CancelActiveCommodityPurchase()
			Buyer:SetError("Stapelware-Kauf fehlgeschlagen (evtl. gerade weggekauft).")
			ScheduleReinspect(entry, myGen, 0.3)
		end
	end
end)
