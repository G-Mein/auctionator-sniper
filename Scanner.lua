local _, NS = ...

local Scanner = {
	state = "IDLE",
	scanSource = nil,
	scanTimestamp = nil,
	progress = 0,
	statusMessage = "Bereit. Bitte einen Auctionator Full Scan starten.",
	scanGen = 0,
	rawItems = {},
	rawItemsByKey = {},
	filteredItems = {},
	summary = {
		itemCount = 0,
		unitCount = 0,
		totalProfit = 0,
	},
	sortField = "totalProfit",
	sortAsc = false,
	searchText = "",
}
NS.Scanner = Scanner

local BATCH_SIZE = 250
local RETRY_INTERVAL = 0.4
local HARD_TIMEOUT = 4.0

local activeTicker = nil
local activeTimeout = nil
local activeFinalize = nil
local pendingByItemID = {}
local waitingCount = 0
local itemLoadElapsed = 0

local loaderFrame = CreateFrame("Frame")

local function CancelHandle(h)
	if h and type(h.Cancel) == "function" then
		h:Cancel()
	end
	return nil
end

local function StopAsyncLoader()
	waitingCount = 0
	itemLoadElapsed = 0
	wipe(pendingByItemID)
	activeFinalize = nil
	activeTimeout = CancelHandle(activeTimeout)
	activeTicker = CancelHandle(activeTicker)
	loaderFrame:UnregisterEvent("ITEM_DATA_LOAD_RESULT")
	loaderFrame:SetScript("OnUpdate", nil)
end

local function EvaluateCandidate(itemMap, cand, itemInfo)
	if not NS.IsVendorableInfo(itemInfo) then
		return
	end
	local sellPrice = tonumber(NS.SafeVal(itemInfo[11]))
	if not sellPrice or sellPrice <= 0 then
		return
	end

	local count = cand.count or 1
	local buyoutPrice = cand.buyoutPrice or 0
	if count <= 0 or buyoutPrice <= 0 then
		return
	end

	local totalVendor = sellPrice * count
	if buyoutPrice >= totalVendor then
		return
	end

	local listingProfit = totalVendor - buyoutPrice
	local exactUnitProfit = sellPrice - (buyoutPrice / count)
	local exactMarginPct = (buyoutPrice > 0) and (listingProfit / buyoutPrice * 100) or 0
	local unitBuyout = math.floor((buyoutPrice / count) + 0.5)
	local rawInfoName = NS.SafeVal(itemInfo[1])
	local overrideName = (type(cand.overrideName) == "string" and cand.overrideName ~= "") and cand.overrideName or nil
	local name = overrideName or rawInfoName or ("Item " .. tostring(cand.itemID))
	local link = NS.SafeVal(itemInfo[2]) or cand.itemLink
	local quality = tonumber(NS.SafeVal(itemInfo[3])) or 1
	local icon = cand.overrideIcon or NS.SafeVal(itemInfo[10])
	local classID = NS.SafeVal(itemInfo[12])
	local ilvl = cand.expectedItemLevel or tonumber(NS.SafeVal(itemInfo[4])) or 0

	local groupKey = cand.groupKey
	if not groupKey then
		if NS.IsEquipmentClass(classID) then
			if C_Item and type(C_Item.GetDetailedItemLevelInfo) == "function" and link then
				ilvl = tonumber(NS.SafeVal(C_Item.GetDetailedItemLevelInfo(link))) or ilvl
			end
			groupKey = string.format("eq:%d:%s:%d", cand.itemID, tostring(name), ilvl)
		else
			groupKey = "id:" .. tostring(cand.itemID)
		end
	end

	local entry = itemMap[groupKey]
	local unitProfit = math.max(0, sellPrice - unitBuyout)
	local scanTotalQty = cand.scanTotalQty or count
	local isOwn = cand.isOwn == true
	local isAllOwn = isOwn and (cand.isExact == true or scanTotalQty <= 1)

	if not entry then
		itemMap[groupKey] = {
			groupKey = groupKey,
			itemID = cand.itemID,
			itemKey = cand.itemKey or C_AuctionHouse.MakeItemKey(cand.itemID),
			expectedItemLevel = ilvl,
			name = name,
			nameLower = string.lower(name),
			itemLink = link,
			icon = icon,
			quality = quality,
			vendorPrice = sellPrice,
			cheapestBuyout = unitBuyout,
			totalBuyoutCost = buyoutPrice,
			unitProfit = unitProfit,
			bestUnitProfit = exactUnitProfit,
			bestMarginPct = exactMarginPct,
			profitableQty = cand.isExact and count or 1,
			scanTotalQty = scanTotalQty,
			totalProfit = listingProfit,
			containsOwn = isOwn,
			allOwn = isAllOwn,
			isExact = cand.isExact == true,
			source = cand.source,
			status = "SCANNED",
		}
	else
		if cand.isExact then
			entry.profitableQty = entry.profitableQty + count
			entry.scanTotalQty = entry.scanTotalQty + scanTotalQty
			entry.totalProfit = entry.totalProfit + listingProfit
			entry.totalBuyoutCost = entry.totalBuyoutCost + buyoutPrice
		else
			entry.scanTotalQty = math.max(entry.scanTotalQty, scanTotalQty)
			if listingProfit > entry.totalProfit then
				entry.totalProfit = listingProfit
				entry.totalBuyoutCost = buyoutPrice
			end
		end
		if exactUnitProfit > (entry.bestUnitProfit or 0) then
			entry.bestUnitProfit = exactUnitProfit
		end
		if exactMarginPct > (entry.bestMarginPct or 0) then
			entry.bestMarginPct = exactMarginPct
		end
		if unitBuyout < entry.cheapestBuyout then
			entry.cheapestBuyout = unitBuyout
			entry.unitProfit = sellPrice - unitBuyout
			if cand.itemKey then
				entry.itemKey = cand.itemKey
			end
			if link then
				entry.itemLink = link
			end
		end
		entry.containsOwn = entry.containsOwn or isOwn
		entry.allOwn = entry.allOwn and isAllOwn
	end
end

loaderFrame:SetScript("OnEvent", function(_, event, rawItemID, rawSuccess)
	if event ~= "ITEM_DATA_LOAD_RESULT" then
		return
	end
	local itemID = NS.SafeVal(rawItemID)
	local success = NS.SafeVal(rawSuccess)
	if not itemID or success == nil then
		return
	end
	local bucket = pendingByItemID[itemID]
	if not bucket then
		return
	end
	pendingByItemID[itemID] = nil
	waitingCount = waitingCount - 1

	if success then
		for _, rec in ipairs(bucket) do
			if rec.gen == Scanner.scanGen then
				local itemInfo = { C_Item.GetItemInfo(rec.cand.itemLink or rec.cand.itemID) }
				if #itemInfo > 0 then
					EvaluateCandidate(rec.itemMap, rec.cand, itemInfo)
				end
			end
		end
	end

	if waitingCount <= 0 then
		waitingCount = 0
		loaderFrame:UnregisterEvent("ITEM_DATA_LOAD_RESULT")
		loaderFrame:SetScript("OnUpdate", nil)
		if activeFinalize then
			local fn = activeFinalize
			activeFinalize = nil
			fn()
		end
	end
end)

local function OnLoaderUpdate(_, elapsed)
	itemLoadElapsed = itemLoadElapsed + elapsed
	if itemLoadElapsed < RETRY_INTERVAL then
		return
	end
	itemLoadElapsed = 0
	for itemID in pairs(pendingByItemID) do
		if C_Item and C_Item.RequestLoadItemDataByID then
			C_Item.RequestLoadItemDataByID(itemID)
		end
	end
	if next(pendingByItemID) == nil then
		waitingCount = 0
		loaderFrame:UnregisterEvent("ITEM_DATA_LOAD_RESULT")
		loaderFrame:SetScript("OnUpdate", nil)
	end
end

local function QueueCandidate(itemMap, cand, gen)
	local queryTarget = cand.itemLink or cand.itemID
	local itemInfo = { C_Item.GetItemInfo(queryTarget) }
	if #itemInfo > 0 then
		EvaluateCandidate(itemMap, cand, itemInfo)
		return
	end
	if C_Item and C_Item.DoesItemExistByID and not C_Item.DoesItemExistByID(cand.itemID) then
		return
	end
	if not pendingByItemID[cand.itemID] then
		pendingByItemID[cand.itemID] = {}
		waitingCount = waitingCount + 1
	end
	table.insert(pendingByItemID[cand.itemID], {
		cand = cand,
		itemMap = itemMap,
		gen = gen,
	})
	loaderFrame:RegisterEvent("ITEM_DATA_LOAD_RESULT")
	loaderFrame:SetScript("OnUpdate", OnLoaderUpdate)
	if C_Item and C_Item.RequestLoadItemDataByID then
		C_Item.RequestLoadItemDataByID(cand.itemID)
	end
end

function Scanner:Init()
	local db = NS.GetDB()
	self.sortField = db.defaultSortField or "totalProfit"
	if db.defaultSortAsc ~= nil then
		self.sortAsc = db.defaultSortAsc == true
	else
		self.sortAsc = NS.SORT_DEFAULT_ASC[self.sortField] == true
	end
end

function Scanner:NotifyScanStart(sourceLabel)
	StopAsyncLoader()
	self.scanGen = self.scanGen + 1
	self.state = "SCANNING_AH"
	self.scanSource = sourceLabel
	self.progress = 0.05
	self.statusMessage = string.format("%s-Scan laeuft (warte auf AH-Daten)...", sourceLabel)
	NS.FireCallback("SCAN_PROGRESS", self.progress, self.statusMessage)
end

function Scanner:NotifyScanProgress(sourceLabel, frac)
	self.state = "SCANNING_AH"
	self.scanSource = sourceLabel
	self.progress = NS.Clamp(tonumber(NS.SafeVal(frac)) or 0, 0, 1)
	self.statusMessage = string.format(
		"%s-Scan laeuft: %d%%",
		sourceLabel,
		math.floor(self.progress * 100 + 0.5)
	)
	NS.FireCallback("SCAN_PROGRESS", self.progress, self.statusMessage)
end

function Scanner:NotifyScanFailed(sourceLabel)
	if self.state == "SCANNING_AH" then
		StopAsyncLoader()
		self.scanGen = self.scanGen + 1
		self.state = "FAILED"
		self.progress = 0
		self.statusMessage = sourceLabel .. "-Scan abgebrochen oder fehlgeschlagen."
		NS.FireCallback("SCAN_FAILED", self.statusMessage)
	end
end

function Scanner:SetSearchText(text)
	self.searchText = tostring(text or "")
	self:ApplyFiltersAndSort()
end

function Scanner:SetSort(field, ascending)
	if not field or NS.SORT_DEFAULT_ASC[field] == nil then
		return
	end
	if ascending == nil then
		if self.sortField == field then
			self.sortAsc = not self.sortAsc
		else
			self.sortField = field
			self.sortAsc = NS.SORT_DEFAULT_ASC[field] == true
		end
	else
		self.sortField = field
		self.sortAsc = ascending == true
	end
	self:ApplyFiltersAndSort()
end

function Scanner:GetSort()
	return self.sortField, self.sortAsc
end

local function CompareField(leftVal, rightVal, asc)
	if leftVal == rightVal then
		return nil
	end
	if asc then
		return leftVal < rightVal
	else
		return leftVal > rightVal
	end
end

function Scanner:ApplyFiltersAndSort()
	local db = NS.GetDB()
	local searchLower = string.lower(self.searchText or "")
	searchLower = searchLower:match("^%s*(.-)%s*$") or ""

	local out = {}
	local totalUnits = 0
	local totalProfit = 0

	for _, entry in ipairs(self.rawItems) do
		local keep = true
		local bestUnit = entry.bestUnitProfit or entry.unitProfit or 0
		local bestPct = entry.bestMarginPct
		if bestPct == nil then
			bestPct = (entry.cheapestBuyout and entry.cheapestBuyout > 0)
				and (bestUnit / entry.cheapestBuyout * 100)
				or 0
		end

		if entry.status == "BOUGHT" or entry.status == "SOLD_OUT" or entry.status == "NOT_PROFITABLE" then
			keep = false
		elseif db.hideOwnAuctions and entry.allOwn then
			keep = false
		elseif db.minProfitCopper <= 1 then
			if (entry.totalProfit or 0) < 1 then
				keep = false
			end
		elseif bestUnit < db.minProfitCopper then
			keep = false
		end

		if keep and db.minProfitPercent > 0 and bestPct < db.minProfitPercent then
			keep = false
		end

		if keep and searchLower ~= "" then
			if not entry.nameLower:find(searchLower, 1, true) then
				keep = false
			end
		end

		if keep then
			table.insert(out, entry)
			totalUnits = totalUnits + (entry.profitableQty or 0)
			totalProfit = totalProfit + (entry.totalProfit or 0)
		end
	end

	local sortField = self.sortField or "totalProfit"
	local sortAsc = self.sortAsc == true

	table.sort(out, function(a, b)
		local cmp
		if sortField == "name" then
			cmp = CompareField(a.nameLower, b.nameLower, sortAsc)
			if cmp ~= nil then return cmp end
			cmp = CompareField(a.totalProfit, b.totalProfit, false)
			if cmp ~= nil then return cmp end
		elseif sortField == "unitProfit" then
			cmp = CompareField(a.unitProfit, b.unitProfit, sortAsc)
			if cmp ~= nil then return cmp end
			cmp = CompareField(a.totalProfit, b.totalProfit, false)
			if cmp ~= nil then return cmp end
		elseif sortField == "buyout" then
			cmp = CompareField(a.cheapestBuyout, b.cheapestBuyout, sortAsc)
			if cmp ~= nil then return cmp end
			cmp = CompareField(a.totalProfit, b.totalProfit, false)
			if cmp ~= nil then return cmp end
		elseif sortField == "vendor" then
			cmp = CompareField(a.vendorPrice, b.vendorPrice, sortAsc)
			if cmp ~= nil then return cmp end
			cmp = CompareField(a.totalProfit, b.totalProfit, false)
			if cmp ~= nil then return cmp end
		elseif sortField == "qty" then
			cmp = CompareField(a.profitableQty, b.profitableQty, sortAsc)
			if cmp ~= nil then return cmp end
			cmp = CompareField(a.totalProfit, b.totalProfit, false)
			if cmp ~= nil then return cmp end
		else
			cmp = CompareField(a.totalProfit, b.totalProfit, sortAsc)
			if cmp ~= nil then return cmp end
			cmp = CompareField(a.unitProfit, b.unitProfit, false)
			if cmp ~= nil then return cmp end
		end
		if a.nameLower ~= b.nameLower then
			return a.nameLower < b.nameLower
		end
		return a.groupKey < b.groupKey
	end)

	self.filteredItems = out
	self.summary.itemCount = #out
	self.summary.unitCount = totalUnits
	self.summary.totalProfit = totalProfit
	NS.FireCallback("RESULTS_UPDATED")
end

function Scanner:UpdateItemFromLive(groupKey, liveData)
	local entry = self.rawItemsByKey[groupKey]
	if not entry or type(liveData) ~= "table" then
		return
	end
	if liveData.itemKey then
		entry.itemKey = liveData.itemKey
	end
	if liveData.itemLink then
		entry.itemLink = liveData.itemLink
	end
	if liveData.vendorPrice and liveData.vendorPrice > 0 then
		entry.vendorPrice = liveData.vendorPrice
	end
	if liveData.cheapestBuyout and liveData.cheapestBuyout > 0 then
		entry.cheapestBuyout = liveData.cheapestBuyout
		entry.unitProfit = math.max(0, entry.vendorPrice - entry.cheapestBuyout)
		entry.bestUnitProfit = entry.unitProfit
		entry.bestMarginPct = entry.unitProfit / entry.cheapestBuyout * 100
	end
	if liveData.profitableQty ~= nil then
		entry.profitableQty = liveData.profitableQty
		entry.scanTotalQty = math.max(entry.scanTotalQty or 0, liveData.profitableQty)
	end
	if liveData.totalProfit ~= nil then
		entry.totalProfit = liveData.totalProfit
	end
	if liveData.totalBuyoutCost ~= nil then
		entry.totalBuyoutCost = liveData.totalBuyoutCost
	end
	if liveData.containsOwn ~= nil then
		entry.containsOwn = liveData.containsOwn
	end
	if liveData.allOwn ~= nil then
		entry.allOwn = liveData.allOwn
	end
	entry.isExact = true
	entry.status = liveData.status or "LIVE"
	self:ApplyFiltersAndSort()
end

function Scanner:MarkItemStatus(groupKey, status)
	local entry = self.rawItemsByKey[groupKey]
	if not entry then
		return
	end
	entry.status = status
	self:ApplyFiltersAndSort()
end

function Scanner:GetNextAvailableItem(afterGroupKey)
	if #self.filteredItems == 0 then
		return nil
	end
	if not afterGroupKey then
		return self.filteredItems[1]
	end
	local found = false
	for _, entry in ipairs(self.filteredItems) do
		if found then
			return entry
		end
		if entry.groupKey == afterGroupKey then
			found = true
		end
	end
	for _, entry in ipairs(self.filteredItems) do
		if entry.groupKey ~= afterGroupKey then
			return entry
		end
	end
	return nil
end

local function FinishAnalysis(sourceLabel, itemMap, gen)
	if gen ~= Scanner.scanGen then
		return
	end
	StopAsyncLoader()
	wipe(Scanner.rawItems)
	wipe(Scanner.rawItemsByKey)
	for groupKey, entry in pairs(itemMap) do
		Scanner.rawItemsByKey[groupKey] = entry
		table.insert(Scanner.rawItems, entry)
	end
	Scanner.state = "READY"
	Scanner.scanSource = sourceLabel
	Scanner.scanTimestamp = time()
	Scanner.progress = 1
	if NS.Buyer and NS.Buyer.SyncAfterScan then
		NS.Buyer:SyncAfterScan(Scanner.rawItemsByKey)
	end
	Scanner:ApplyFiltersAndSort()
	Scanner.statusMessage = string.format(
		"Analyse (%s): %d Items unter Vendor-Wert | Gewinn: %s",
		sourceLabel,
		Scanner.summary.itemCount,
		NS.FormatMoney(Scanner.summary.totalProfit)
	)
	NS.FireCallback("SCAN_COMPLETE", Scanner.summary, sourceLabel)
end

local function ScheduleFinalize(sourceLabel, itemMap, gen)
	local doneFn = function()
		FinishAnalysis(sourceLabel, itemMap, gen)
	end
	if waitingCount <= 0 then
		doneFn()
		return
	end
	activeFinalize = doneFn
	Scanner.statusMessage = string.format(
		"Lade %d fehlende Item-Daten (%s)...",
		waitingCount,
		sourceLabel
	)
	NS.FireCallback("SCAN_PROGRESS", 0.95, Scanner.statusMessage)
	local thisTimer
	thisTimer = C_Timer.NewTimer(HARD_TIMEOUT, function()
		if gen ~= Scanner.scanGen then
			return
		end
		if activeTimeout == thisTimer then
			activeTimeout = nil
		end
		if activeFinalize then
			local fn = activeFinalize
			activeFinalize = nil
			fn()
		end
	end)
	activeTimeout = thisTimer
end

local function RunBatchAnalysis(sourceKey, sourceLabel, progressFmt, rows, processRowFn)
	StopAsyncLoader()
	Scanner.scanGen = Scanner.scanGen + 1
	local gen = Scanner.scanGen
	Scanner.state = "ANALYZING"
	Scanner.scanSource = sourceKey
	Scanner.progress = 0

	if type(rows) ~= "table" or #rows == 0 then
		FinishAnalysis(sourceLabel, {}, gen)
		return
	end

	local itemMap = {}
	local total = #rows
	local index = 1
	local thisTicker

	thisTicker = C_Timer.NewTicker(0, function()
		if gen ~= Scanner.scanGen then
			CancelHandle(thisTicker)
			return
		end
		local stopIdx = math.min(index + BATCH_SIZE - 1, total)
		for i = index, stopIdx do
			processRowFn(rows[i], itemMap, gen)
		end

		index = stopIdx + 1
		Scanner.progress = index / (total + 1)
		Scanner.statusMessage = string.format(progressFmt, math.min(stopIdx, total), total)
		NS.FireCallback("SCAN_PROGRESS", Scanner.progress, Scanner.statusMessage)

		if index > total then
			CancelHandle(thisTicker)
			if activeTicker == thisTicker then
				activeTicker = nil
			end
			ScheduleFinalize(sourceLabel, itemMap, gen)
		end
	end)
	activeTicker = thisTicker
end

function Scanner:AnalyzeReplicateData(fixedScanData)
	local playerName = NS.SafePlayerName()
	RunBatchAnalysis("replicate", "Replicate", "Analysiere Replicate-Scan: %d / %d", fixedScanData, function(row, itemMap, gen)
		if type(row) ~= "table" or type(row.replicateInfo) ~= "table" then
			return
		end
		local info = row.replicateInfo
		local count = tonumber(NS.SafeVal(info[3]))
		local buyoutPrice = tonumber(NS.SafeVal(info[10]))
		local owner = NS.SafeVal(info[14])
		local itemID = tonumber(NS.SafeVal(info[17]))
		local link = NS.SafeVal(row.itemLink)
		if itemID and itemID > 0 and itemID ~= NS.PET_CAGE_ID and itemID ~= NS.WOW_TOKEN_ID
			and count and count > 0 and buyoutPrice and buyoutPrice > 0
			and not (type(link) == "string" and link:find("battlepet:", 1, true))
		then
			local isOwn = (type(owner) == "string" and owner ~= "" and playerName ~= nil and owner == playerName)
			QueueCandidate(itemMap, {
				itemID = itemID,
				itemLink = link,
				count = count,
				buyoutPrice = buyoutPrice,
				scanTotalQty = count,
				isOwn = isOwn,
				isExact = true,
				source = "replicate",
			}, gen)
		end
	end)
end

function Scanner:AnalyzeIncrementalData(rawScan)
	RunBatchAnalysis("incremental", "FullScan", "Analysiere Full Scan: %d / %d", rawScan, function(result, itemMap, gen)
		if type(result) ~= "table" or type(result.itemKey) ~= "table" then
			return
		end
		local ik = result.itemKey
		local itemID = tonumber(NS.SafeVal(ik.itemID))
		local petID = tonumber(NS.SafeVal(ik.battlePetSpeciesID)) or 0
		local minPrice = tonumber(NS.SafeVal(result.minPrice))
		local totalQty = tonumber(NS.SafeVal(result.totalQuantity))
		if itemID and itemID > 0 and petID == 0
			and itemID ~= NS.PET_CAGE_ID and itemID ~= NS.WOW_TOKEN_ID
			and minPrice and minPrice > 0 and totalQty and totalQty > 0
		then
			local keyInfo = C_AuctionHouse and C_AuctionHouse.GetItemKeyInfo and C_AuctionHouse.GetItemKeyInfo(ik) or nil
			local overrideName = keyInfo and NS.SafeVal(keyInfo.itemName) or nil
			local overrideIcon = keyInfo and NS.SafeVal(keyInfo.iconFileID) or nil
			local ikStr = "ik:" .. NS.GetItemKeyString(ik)
			QueueCandidate(itemMap, {
				groupKey = ikStr,
				itemID = itemID,
				itemKey = ik,
				expectedItemLevel = tonumber(NS.SafeVal(ik.itemLevel)) or 0,
				overrideName = overrideName,
				overrideIcon = overrideIcon,
				count = 1,
				buyoutPrice = minPrice,
				scanTotalQty = totalQty,
				isOwn = NS.SafeVal(result.containsOwnerItem) == true,
				isExact = false,
				source = "incremental",
			}, gen)
		end
	end)
end

function Scanner:AnalyzeAuctionatorDB()
	if not (Auctionator and Auctionator.Database and type(Auctionator.Database.db) == "table") then
		StopAsyncLoader()
		self.scanGen = self.scanGen + 1
		self.state = "FAILED"
		self.statusMessage = "Keine Auctionator-Datenbank geladen."
		NS.FireCallback("SCAN_FAILED", self.statusMessage)
		return
	end

	local db = NS.GetDB()
	local aDb = Auctionator.Database.db
	local keys = {}
	for k, v in pairs(aDb) do
		if type(k) == "string" and k ~= "__dbversion" and k:sub(1, 2) ~= "p:" and type(v) == "table" and v.m and v.m > 0 then
			local ageOk = true
			if db.dbScanTodayOnly and Auctionator.Database.GetPriceAge then
				local age = Auctionator.Database:GetPriceAge(k)
				if age == nil or age > 0 then
					ageOk = false
				end
			end
			if ageOk then
				table.insert(keys, k)
			end
		end
	end

	RunBatchAnalysis("database", "Datenbank", "Pruefe Auctionator-DB: %d / %d", keys, function(dbKey, itemMap, gen)
		local priceEntry = aDb[dbKey]
		if not (priceEntry and priceEntry.m and priceEntry.m > 0) then
			return
		end
		local itemID, ilvl
		local numID = tonumber(dbKey)
		if numID then
			itemID = numID
		else
			local gID, gIlvl = dbKey:match("^g:(%d+):(%d+)$")
			if gID then
				itemID = tonumber(gID)
				ilvl = tonumber(gIlvl)
			else
				local grID = dbKey:match("^gr:(%d+):")
				if grID then
					itemID = tonumber(grID)
				end
			end
		end
		if itemID and itemID > 0 and itemID ~= NS.PET_CAGE_ID and itemID ~= NS.WOW_TOKEN_ID then
			local itemKey = ilvl and C_AuctionHouse.MakeItemKey(itemID, ilvl) or C_AuctionHouse.MakeItemKey(itemID)
			QueueCandidate(itemMap, {
				groupKey = "db:" .. dbKey,
				itemID = itemID,
				itemKey = itemKey,
				expectedItemLevel = ilvl or 0,
				count = 1,
				buyoutPrice = priceEntry.m,
				scanTotalQty = 1,
				isOwn = false,
				isExact = false,
				source = "database",
			}, gen)
		end
	end)
end

function Scanner:StartFullScan()
	if not NS.IsAuctionHouseOpen() then
		NS.Print("Bitte zuerst das Auktionshaus oeffnen.")
		return false
	end
	local useReplicate = Auctionator
		and Auctionator.Config
		and Auctionator.Config.Get
		and Auctionator.Config.Options
		and Auctionator.Config.Options.REPLICATE_SCAN
		and Auctionator.Config.Get(Auctionator.Config.Options.REPLICATE_SCAN)
	if useReplicate then
		return self:StartReplicateScan()
	end
	local ref = Auctionator and Auctionator.State and Auctionator.State.IncrementalScanFrameRef
	if not ref or type(ref.InitiateScan) ~= "function" then
		NS.Print("Auctionator FullScan-Frame ist noch nicht bereit.")
		return false
	end
	ref:InitiateScan()
	return true
end

function Scanner:StartReplicateScan()
	if not NS.IsAuctionHouseOpen() then
		NS.Print("Bitte zuerst das Auktionshaus oeffnen.")
		return false
	end
	local ref = Auctionator and Auctionator.State and Auctionator.State.FullScanFrameRef
	if not ref or type(ref.InitiateScan) ~= "function" then
		NS.Print("Auctionator ReplicateScan-Frame ist noch nicht bereit.")
		return false
	end
	ref:InitiateScan()
	return true
end
