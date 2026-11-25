local _, NS = ...

local UI = {
	frame = nil,
}
NS.UI = UI

local ROW_HEIGHT = 22
local MAX_ROWS = 12

local DARK_BACKDROP = {
	bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
	edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
	tile = true,
	tileSize = 16,
	edgeSize = 12,
	insets = { left = 3, right = 3, top = 3, bottom = 3 },
}

local function ApplyBackdrop(frame, r, g, b, a, br, bg, bb, ba)
	if type(frame.SetBackdrop) == "function" then
		frame:SetBackdrop(DARK_BACKDROP)
		frame:SetBackdropColor(r, g, b, a)
		frame:SetBackdropBorderColor(br, bg, bb, ba)
	end
end

local function GetQualityColor(quality)
	if ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality] then
		local c = ITEM_QUALITY_COLORS[quality]
		return c.r, c.g, c.b
	end
	return 1, 1, 1
end

local function SetRowTooltip(anchorFrame, entry)
	if not entry or not GameTooltip then
		return
	end
	GameTooltip:SetOwner(anchorFrame, "ANCHOR_RIGHT")
	if type(entry.itemLink) == "string" and entry.itemLink ~= "" then
		local ok = pcall(GameTooltip.SetHyperlink, GameTooltip, entry.itemLink)
		if not ok and entry.itemID and type(GameTooltip.SetItemByID) == "function" then
			pcall(GameTooltip.SetItemByID, GameTooltip, entry.itemID)
		end
	elseif entry.itemID and type(GameTooltip.SetItemByID) == "function" then
		pcall(GameTooltip.SetItemByID, GameTooltip, entry.itemID)
	end

	GameTooltip:AddLine(" ")
	GameTooltip:AddLine("|cff2ecc71Auctionator Sniper Buyout|r")
	GameTooltip:AddDoubleLine("Günstigster Buyout:", NS.FormatMoney(entry.cheapestBuyout), 0.85, 0.85, 0.85, 1, 1, 1)
	GameTooltip:AddDoubleLine("Vendor-Verkaufswert:", NS.FormatMoney(entry.vendorPrice), 0.85, 0.85, 0.85, 1, 0.85, 0.3)
	GameTooltip:AddDoubleLine("Gewinn pro Stück:", "+" .. NS.FormatMoney(entry.unitProfit), 0.85, 0.85, 0.85, 0.25, 0.95, 0.45)
	if entry.isExact then
		GameTooltip:AddDoubleLine("Gewinn gesamt (" .. tostring(entry.profitableQty) .. "x):", "+" .. NS.FormatMoney(entry.totalProfit), 0.85, 0.85, 0.85, 0.2, 1, 0.4)
	else
		GameTooltip:AddDoubleLine("Mindestgewinn:", "+" .. NS.FormatMoney(entry.totalProfit) .. " (Scan-Schätzung)", 0.85, 0.85, 0.85, 1, 0.78, 0.2)
		GameTooltip:AddLine("Hinweis: Summary-/DB-Werte; beim Klick wird die exakte Menge live geprüft.", 0.75, 0.75, 0.75, true)
	end
	if entry.containsOwn then
		GameTooltip:AddLine("Enthält mindestens eine eigene Auktion (wird beim Kauf ignoriert).", 1, 0.82, 0.2, true)
	end
	GameTooltip:AddLine("Links-Klick: Live prüfen  |  Shift: Chat-Link  |  Strg: Vorschau", 0.6, 0.75, 0.9, true)
	GameTooltip:Show()
end

function UI.UpdateTabLabel()
	local tabBtn = _G["AuctionatorTabs_Sniper"]
	if not tabBtn then
		return
	end
	local count = (NS.Scanner and NS.Scanner.summary and NS.Scanner.summary.itemCount) or 0
	local label = (count > 0) and string.format("Sniper (%d)", count) or "Sniper"
	if tabBtn:GetText() ~= label then
		tabBtn:SetText(label)
		if type(PanelTemplates_TabResize) == "function" then
			local useSmall = Auctionator and Auctionator.Config and Auctionator.Config.Get
				and Auctionator.Config.Options and Auctionator.Config.Options.SMALL_TABS
				and Auctionator.Config.Get(Auctionator.Config.Options.SMALL_TABS)
			if useSmall then
				PanelTemplates_TabResize(tabBtn, 0, nil, 36)
			else
				PanelTemplates_TabResize(tabBtn, 20, nil, 70)
			end
		end
	end
end

AuctionatorSniperBuyoutTabMixin = {}

function AuctionatorSniperBuyoutTabMixin:OnLoad()
	UI.frame = self
	self.scrollOffset = 0
	self.rows = {}
	self.headerButtons = {}
	self.profitPresets = {}
	self:BuildUI()

	NS.RegisterCallback("RESULTS_UPDATED", function()
		UI.UpdateTabLabel()
		if self:IsShown() then
			self:RefreshTable()
			self:RefreshSummary()
		end
	end)
	NS.RegisterCallback("SCAN_PROGRESS", function()
		if self:IsShown() then
			self:RefreshStatus()
		end
	end)
	NS.RegisterCallback("SCAN_COMPLETE", function()
		UI.UpdateTabLabel()
		if self:IsShown() then
			self:RefreshTable()
			self:RefreshSummary()
			self:RefreshStatus()
		end
	end)
	NS.RegisterCallback("SCAN_FAILED", function()
		if self:IsShown() then
			self:RefreshStatus()
		end
	end)
	NS.RegisterCallback("BUYER_STATE_CHANGED", function()
		if self:IsShown() then
			self:RefreshBuyerPanel()
			self:RefreshTable()
		end
	end)
	NS.RegisterCallback("PURCHASE_SUCCEEDED", function()
		if self:IsShown() then
			self:RefreshSummary()
		end
	end)
	NS.RegisterCallback("OPTIONS_CHANGED", function()
		if NS.Scanner then
			NS.Scanner:ApplyFiltersAndSort()
		end
		if self:IsShown() then
			self:RefreshPresetButtons()
			self:RefreshSortToggles()
			self:RefreshSummary()
			self:RefreshBuyerPanel()
		end
	end)
end

function AuctionatorSniperBuyoutTabMixin:OnShow()
	NS.Buyer:OnTabShow()
	self:RefreshPresetButtons()
	self:RefreshSortToggles()
	self:RefreshTable()
	self:RefreshSummary()
	self:RefreshStatus()
	self:RefreshBuyerPanel()
end

function AuctionatorSniperBuyoutTabMixin:OnHide()
	NS.Buyer:OnTabHide()
end

function AuctionatorSniperBuyoutTabMixin:BuildUI()
	-- 1. Top Header Bar (rechts vom AH-Portrait)
	local header = CreateFrame("Frame", nil, self)
	header:SetPoint("TOPLEFT", self, "TOPLEFT", 64, -30)
	header:SetPoint("TOPRIGHT", self, "TOPRIGHT", -12, -30)
	header:SetHeight(36)
	self.Header = header

	local icon = header:CreateTexture(nil, "ARTWORK")
	icon:SetSize(28, 28)
	icon:SetPoint("LEFT", header, "LEFT", 0, 0)
	icon:SetTexture(NS.ICON_TEXTURE)

	local title = header:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	title:SetPoint("TOPLEFT", icon, "TOPRIGHT", 8, -1)
	title:SetText("Auctionator Sniper Buyout")

	local summary = header:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	summary:SetPoint("BOTTOMLEFT", icon, "BOTTOMRIGHT", 8, 1)
	summary:SetText("Treffer: 0 | Gewinn: 0c | Session: 0 (0c)")
	self.SummaryText = summary

	local function MakeTopButton(text, width, anchorTarget, onClick)
		local btn = CreateFrame("Button", nil, header, "UIPanelButtonTemplate")
		btn:SetSize(width, 22)
		if anchorTarget then
			btn:SetPoint("RIGHT", anchorTarget, "LEFT", -4, 0)
		else
			btn:SetPoint("RIGHT", header, "RIGHT", 0, 0)
		end
		btn:SetText(text)
		btn:SetScript("OnClick", onClick)
		return btn
	end

	local optBtn = MakeTopButton("Optionen", 70, nil, function()
		if NS.OpenSettings then
			NS.OpenSettings()
		end
	end)
	local dbBtn = MakeTopButton("DB prüfen", 78, optBtn, function()
		NS.Scanner:AnalyzeAuctionatorDB()
	end)
	local repBtn = MakeTopButton("Replicate", 76, dbBtn, function()
		NS.Scanner:StartReplicateScan()
	end)
	MakeTopButton("Full Scan", 80, repBtn, function()
		NS.Scanner:StartFullScan()
	end)

	-- 2. Filter & Sort Toolbar
	local toolbar = CreateFrame("Frame", nil, self, "BackdropTemplate")
	toolbar:SetPoint("TOPLEFT", self, "TOPLEFT", 10, -70)
	toolbar:SetPoint("TOPRIGHT", self, "TOPRIGHT", -10, -70)
	toolbar:SetHeight(30)
	ApplyBackdrop(toolbar, 0.06, 0.08, 0.10, 0.90, 0.30, 0.34, 0.40, 0.90)
	self.Toolbar = toolbar

	local searchLabel = toolbar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	searchLabel:SetPoint("LEFT", toolbar, "LEFT", 8, 0)
	searchLabel:SetText("Suche:")

	local searchBox = CreateFrame("EditBox", nil, toolbar, "InputBoxTemplate")
	searchBox:SetSize(140, 20)
	searchBox:SetPoint("LEFT", searchLabel, "RIGHT", 8, 0)
	searchBox:SetAutoFocus(false)
	searchBox:SetMaxLetters(64)
	searchBox:SetScript("OnTextChanged", function(box)
		self.scrollOffset = 0
		NS.Scanner:SetSearchText(box:GetText() or "")
	end)
	searchBox:SetScript("OnEscapePressed", function(box)
		box:ClearFocus()
	end)
	searchBox:SetScript("OnEnterPressed", function(box)
		box:ClearFocus()
	end)
	self.SearchBox = searchBox

	local clearSearchBtn = CreateFrame("Button", nil, toolbar, "UIPanelButtonTemplate")
	clearSearchBtn:SetSize(20, 20)
	clearSearchBtn:SetPoint("LEFT", searchBox, "RIGHT", 2, 0)
	clearSearchBtn:SetText("X")
	clearSearchBtn:SetScript("OnClick", function()
		self.SearchBox:SetText("")
		self.SearchBox:ClearFocus()
	end)

	local sortLabel = toolbar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	sortLabel:SetPoint("LEFT", clearSearchBtn, "RIGHT", 10, 0)
	sortLabel:SetText("Sortierung:")

	local sortProfitBtn = CreateFrame("Button", nil, toolbar, "UIPanelButtonTemplate")
	sortProfitBtn:SetSize(96, 20)
	sortProfitBtn:SetPoint("LEFT", sortLabel, "RIGHT", 4, 0)
	sortProfitBtn:SetText("Nach Gewinn")
	sortProfitBtn:SetScript("OnClick", function()
		self.scrollOffset = 0
		NS.Scanner:SetSort("totalProfit")
		self:RefreshSortToggles()
	end)
	self.SortProfitBtn = sortProfitBtn

	local sortItemBtn = CreateFrame("Button", nil, toolbar, "UIPanelButtonTemplate")
	sortItemBtn:SetSize(102, 20)
	sortItemBtn:SetPoint("LEFT", sortProfitBtn, "RIGHT", 4, 0)
	sortItemBtn:SetText("Pro Item (A-Z)")
	sortItemBtn:SetScript("OnClick", function()
		self.scrollOffset = 0
		NS.Scanner:SetSort("name")
		self:RefreshSortToggles()
	end)
	self.SortItemBtn = sortItemBtn

	local minLabel = toolbar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	minLabel:SetPoint("LEFT", sortItemBtn, "RIGHT", 10, 0)
	minLabel:SetText("Min:")

	local presets = {
		{ label = "Alle", copper = 1, width = 38 },
		{ label = "1s", copper = 100, width = 30 },
		{ label = "10s", copper = 1000, width = 36 },
		{ label = "1g", copper = 10000, width = 32 },
	}
	local prevPreset = minLabel
	for _, p in ipairs(presets) do
		local pBtn = CreateFrame("Button", nil, toolbar, "UIPanelButtonTemplate")
		pBtn:SetSize(p.width, 20)
		pBtn:SetPoint("LEFT", prevPreset, "RIGHT", 3, 0)
		pBtn:SetText(p.label)
		pBtn.baseLabel = p.label
		pBtn.minCopper = p.copper
		pBtn:SetScript("OnClick", function(b)
			local db = NS.GetDB()
			db.minProfitCopper = b.minCopper
			self.scrollOffset = 0
			NS.FireCallback("OPTIONS_CHANGED")
		end)
		table.insert(self.profitPresets, pBtn)
		prevPreset = pBtn
	end

	local statusText = toolbar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	statusText:SetPoint("LEFT", prevPreset, "RIGHT", 8, 0)
	statusText:SetPoint("RIGHT", toolbar, "RIGHT", -8, 0)
	statusText:SetJustifyH("RIGHT")
	statusText:SetText("Bereit")
	self.ScanStatusText = statusText

	-- 3. Results Table Container
	local tableBox = CreateFrame("Frame", nil, self, "BackdropTemplate")
	tableBox:SetPoint("TOPLEFT", self, "TOPLEFT", 10, -104)
	tableBox:SetPoint("BOTTOMRIGHT", self, "BOTTOMRIGHT", -10, 102)
	ApplyBackdrop(tableBox, 0.04, 0.05, 0.07, 0.94, 0.28, 0.33, 0.40, 0.95)
	tableBox:EnableMouseWheel(true)
	self.TableBox = tableBox

	local headerBar = CreateFrame("Frame", nil, tableBox, "BackdropTemplate")
	headerBar:SetPoint("TOPLEFT", tableBox, "TOPLEFT", 3, -3)
	headerBar:SetPoint("TOPRIGHT", tableBox, "TOPRIGHT", -23, -3)
	headerBar:SetHeight(22)
	ApplyBackdrop(headerBar, 0.10, 0.13, 0.17, 0.95, 0.26, 0.30, 0.36, 0.90)

	local columns = {
		{ field = "name", label = "Item", width = 248, align = "LEFT" },
		{ field = "qty", label = "Menge", width = 66, align = "CENTER" },
		{ field = "buyout", label = "Buyout", width = 100, align = "RIGHT" },
		{ field = "vendor", label = "Vendor", width = 100, align = "RIGHT" },
		{ field = "unitProfit", label = "Gewinn/Stk", width = 96, align = "RIGHT" },
		{ field = "totalProfit", label = "Gewinn ges.", width = 106, align = "RIGHT" },
		{ field = nil, label = "Aktion", width = 70, align = "CENTER" },
	}
	self.Columns = columns

	local colX = 4
	for _, col in ipairs(columns) do
		local hBtn = CreateFrame("Button", nil, headerBar)
		hBtn:SetPoint("TOPLEFT", headerBar, "TOPLEFT", colX, 0)
		hBtn:SetSize(col.width, 22)
		hBtn.col = col

		local hl = hBtn:CreateTexture(nil, "HIGHLIGHT")
		hl:SetAllPoints()
		hl:SetColorTexture(1, 1, 1, 0.08)

		local lbl = hBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		lbl:SetPoint("LEFT", hBtn, "LEFT", 4, 0)
		lbl:SetPoint("RIGHT", hBtn, "RIGHT", -4, 0)
		lbl:SetJustifyH(col.align)
		lbl:SetText(col.label)
		hBtn.label = lbl

		if col.field then
			hBtn:SetScript("OnClick", function()
				self.scrollOffset = 0
				NS.Scanner:SetSort(col.field)
				self:RefreshSortToggles()
			end)
		end
		table.insert(self.headerButtons, hBtn)
		colX = colX + col.width
	end

	-- Scroll Slider
	local slider = CreateFrame("Slider", nil, tableBox, "BackdropTemplate")
	slider:SetPoint("TOPRIGHT", tableBox, "TOPRIGHT", -5, -26)
	slider:SetPoint("BOTTOMRIGHT", tableBox, "BOTTOMRIGHT", -5, 6)
	slider:SetWidth(14)
	slider:SetOrientation("VERTICAL")
	slider:SetMinMaxValues(0, 0)
	slider:SetValueStep(1)
	slider:SetObeyStepOnDrag(true)
	ApplyBackdrop(slider, 0.07, 0.08, 0.10, 0.90, 0.25, 0.28, 0.34, 0.90)
	local thumb = slider:CreateTexture(nil, "OVERLAY")
	thumb:SetSize(10, 28)
	thumb:SetColorTexture(0.22, 0.72, 0.45, 0.90)
	slider:SetThumbTexture(thumb)
	slider:SetScript("OnValueChanged", function(_, val)
		local nextOff = math.floor(val + 0.5)
		if nextOff ~= self.scrollOffset then
			self.scrollOffset = nextOff
			self:RefreshTable()
		end
	end)
	self.ScrollSlider = slider

	local rowsContainer = CreateFrame("Frame", nil, tableBox)
	rowsContainer:SetPoint("TOPLEFT", tableBox, "TOPLEFT", 3, -26)
	rowsContainer:SetPoint("BOTTOMRIGHT", tableBox, "BOTTOMRIGHT", -22, 4)
	self.RowsContainer = rowsContainer

	local emptyText = rowsContainer:CreateFontString(nil, "OVERLAY", "GameFontDisable")
	emptyText:SetPoint("CENTER", rowsContainer, "CENTER", 0, 0)
	emptyText:SetText("Noch keine Treffer. Starte einen 'Full Scan' oder 'Replicate'-Scan über die Buttons oben.")
	self.EmptyText = emptyText

	for i = 1, MAX_ROWS do
		local row = CreateFrame("Button", nil, rowsContainer)
		row:SetPoint("TOPLEFT", rowsContainer, "TOPLEFT", 0, -((i - 1) * ROW_HEIGHT))
		row:SetPoint("TOPRIGHT", rowsContainer, "TOPRIGHT", 0, -((i - 1) * ROW_HEIGHT))
		row:SetHeight(ROW_HEIGHT)

		local bg = row:CreateTexture(nil, "BACKGROUND")
		bg:SetAllPoints()
		bg:SetColorTexture(0.08, 0.10, 0.12, (i % 2 == 0) and 0.65 or 0.35)
		row.bg = bg

		local hl = row:CreateTexture(nil, "HIGHLIGHT")
		hl:SetAllPoints()
		hl:SetColorTexture(0.25, 0.75, 0.45, 0.18)

		local rx = 4
		local iconTex = row:CreateTexture(nil, "ARTWORK")
		iconTex:SetSize(18, 18)
		iconTex:SetPoint("LEFT", row, "LEFT", rx + 2, 0)
		row.icon = iconTex

		local nameText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		nameText:SetPoint("LEFT", iconTex, "RIGHT", 5, 0)
		nameText:SetSize(columns[1].width - 28, ROW_HEIGHT)
		nameText:SetJustifyH("LEFT")
		row.nameText = nameText
		rx = rx + columns[1].width

		local qtyText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		qtyText:SetPoint("LEFT", row, "LEFT", rx, 0)
		qtyText:SetSize(columns[2].width - 4, ROW_HEIGHT)
		qtyText:SetJustifyH("CENTER")
		row.qtyText = qtyText
		rx = rx + columns[2].width

		local buyText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		buyText:SetPoint("LEFT", row, "LEFT", rx, 0)
		buyText:SetSize(columns[3].width - 6, ROW_HEIGHT)
		buyText:SetJustifyH("RIGHT")
		row.buyText = buyText
		rx = rx + columns[3].width

		local vendorText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		vendorText:SetPoint("LEFT", row, "LEFT", rx, 0)
		vendorText:SetSize(columns[4].width - 6, ROW_HEIGHT)
		vendorText:SetJustifyH("RIGHT")
		row.vendorText = vendorText
		rx = rx + columns[4].width

		local unitText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		unitText:SetPoint("LEFT", row, "LEFT", rx, 0)
		unitText:SetSize(columns[5].width - 6, ROW_HEIGHT)
		unitText:SetJustifyH("RIGHT")
		row.unitText = unitText
		rx = rx + columns[5].width

		local totalText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		totalText:SetPoint("LEFT", row, "LEFT", rx, 0)
		totalText:SetSize(columns[6].width - 6, ROW_HEIGHT)
		totalText:SetJustifyH("RIGHT")
		row.totalText = totalText
		rx = rx + columns[6].width

		local actBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
		actBtn:SetSize(columns[7].width - 8, 18)
		actBtn:SetPoint("LEFT", row, "LEFT", rx + 4, 0)
		actBtn:SetText("Prüfen")
		actBtn:SetScript("OnClick", function()
			if not row.entry then
				return
			end
			if NS.Buyer.selected and NS.Buyer.selected.groupKey == row.entry.groupKey and NS.Buyer:CanExecutePrimary() then
				NS.Buyer:ExecutePrimaryAction()
			else
				NS.Buyer:InspectEntry(row.entry)
			end
		end)
		row.actBtn = actBtn

		row:SetScript("OnClick", function()
			if not row.entry then
				return
			end
			if type(IsShiftKeyDown) == "function" and IsShiftKeyDown() and row.entry.itemLink then
				NS.InsertChatLink(row.entry.itemLink)
			elseif type(IsControlKeyDown) == "function" and IsControlKeyDown() and row.entry.itemLink then
				NS.TryDressUp(row.entry.itemLink)
			else
				NS.Buyer:InspectEntry(row.entry)
			end
		end)
		row:SetScript("OnEnter", function(r)
			SetRowTooltip(r, r.entry)
		end)
		row:SetScript("OnLeave", function()
			if GameTooltip then
				GameTooltip:Hide()
			end
		end)

		table.insert(self.rows, row)
	end

	tableBox:SetScript("OnMouseWheel", function(_, delta)
		local visible = self:GetVisibleRowCount()
		local maxOff = math.max(0, #NS.Scanner.filteredItems - visible)
		local nextOff = NS.Clamp(self.scrollOffset - delta * 2, 0, maxOff)
		if nextOff ~= self.scrollOffset then
			self.scrollOffset = nextOff
			self.ScrollSlider:SetValue(nextOff)
			self:RefreshTable()
		end
	end)

	rowsContainer:SetScript("OnSizeChanged", function()
		if self:IsShown() then
			self:RefreshTable()
		end
	end)

	-- 4. Bottom Direct-Buy Action Panel
	local buyBar = CreateFrame("Frame", nil, self, "BackdropTemplate")
	buyBar:SetPoint("BOTTOMLEFT", self, "BOTTOMLEFT", 10, 6)
	buyBar:SetPoint("BOTTOMRIGHT", self, "BOTTOMRIGHT", -10, 6)
	buyBar:SetHeight(90)
	ApplyBackdrop(buyBar, 0.05, 0.07, 0.09, 0.96, 0.24, 0.65, 0.42, 0.95)
	self.BuyBar = buyBar

	local selIconBtn = CreateFrame("Button", nil, buyBar)
	selIconBtn:SetSize(40, 40)
	selIconBtn:SetPoint("TOPLEFT", buyBar, "TOPLEFT", 12, -12)
	local selIcon = selIconBtn:CreateTexture(nil, "ARTWORK")
	selIcon:SetAllPoints()
	selIcon:SetTexture(NS.ICON_TEXTURE)
	selIconBtn.tex = selIcon
	selIconBtn:SetScript("OnEnter", function(b)
		if NS.Buyer.selected then
			SetRowTooltip(b, NS.Buyer.selected)
		end
	end)
	selIconBtn:SetScript("OnLeave", function()
		if GameTooltip then GameTooltip:Hide() end
	end)
	selIconBtn:SetScript("OnClick", function()
		if NS.Buyer.selected and NS.Buyer.selected.itemLink then
			if type(IsShiftKeyDown) == "function" and IsShiftKeyDown() then
				NS.InsertChatLink(NS.Buyer.selected.itemLink)
			elseif type(IsControlKeyDown) == "function" and IsControlKeyDown() then
				NS.TryDressUp(NS.Buyer.selected.itemLink)
			end
		end
	end)
	self.SelIconBtn = selIconBtn

	local selName = buyBar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	selName:SetPoint("TOPLEFT", selIconBtn, "TOPRIGHT", 10, -2)
	selName:SetSize(310, 16)
	selName:SetJustifyH("LEFT")
	selName:SetText("Kein Item ausgewählt")
	self.SelName = selName

	local selStatus = buyBar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	selStatus:SetPoint("TOPLEFT", selName, "BOTTOMLEFT", 0, -4)
	selStatus:SetPoint("BOTTOMLEFT", buyBar, "BOTTOMLEFT", 62, 10)
	selStatus:SetWidth(315)
	selStatus:SetJustifyH("LEFT")
	selStatus:SetJustifyV("TOP")
	selStatus:SetText("Wähle ein Item aus der Liste, um Live-Preise zu prüfen.")
	self.SelStatus = selStatus

	local priceLine = buyBar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	priceLine:SetPoint("TOPLEFT", buyBar, "TOPLEFT", 386, -14)
	priceLine:SetSize(205, 18)
	priceLine:SetJustifyH("LEFT")
	priceLine:SetText("")
	self.BuyPriceLine = priceLine

	local profitLine = buyBar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	profitLine:SetPoint("TOPLEFT", priceLine, "BOTTOMLEFT", 0, -4)
	profitLine:SetSize(205, 18)
	profitLine:SetJustifyH("LEFT")
	profitLine:SetText("")
	self.BuyProfitLine = profitLine

	local qtyLabel = buyBar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	qtyLabel:SetPoint("TOPLEFT", profitLine, "BOTTOMLEFT", 0, -8)
	qtyLabel:SetText("Menge:")
	qtyLabel:Hide()
	self.QtyLabel = qtyLabel

	local qtyBox = CreateFrame("EditBox", nil, buyBar, "InputBoxTemplate")
	qtyBox:SetSize(58, 20)
	qtyBox:SetPoint("LEFT", qtyLabel, "RIGHT", 8, 0)
	qtyBox:SetAutoFocus(false)
	qtyBox:SetNumeric(true)
	qtyBox:SetMaxLetters(5)
	qtyBox:SetScript("OnEnterPressed", function(box)
		box:ClearFocus()
		local v = tonumber(box:GetText())
		if v then
			NS.Buyer:SetCommodityQuantity(v)
		end
	end)
	qtyBox:SetScript("OnEditFocusLost", function(box)
		local v = tonumber(box:GetText())
		if v and NS.Buyer.state == "READY_COMMODITY" then
			NS.Buyer:SetCommodityQuantity(v)
		end
	end)
	qtyBox:Hide()
	self.QtyBox = qtyBox

	local maxQtyBtn = CreateFrame("Button", nil, buyBar, "UIPanelButtonTemplate")
	maxQtyBtn:SetSize(44, 20)
	maxQtyBtn:SetPoint("LEFT", qtyBox, "RIGHT", 4, 0)
	maxQtyBtn:SetText("Max")
	maxQtyBtn:SetScript("OnClick", function()
		if NS.Buyer.maxBuyableQty > 0 then
			NS.Buyer:SetCommodityQuantity(NS.Buyer.maxBuyableQty)
		end
	end)
	maxQtyBtn:Hide()
	self.MaxQtyBtn = maxQtyBtn

	local primaryBtn = CreateFrame("Button", nil, buyBar, "UIPanelButtonTemplate")
	primaryBtn:SetSize(196, 30)
	primaryBtn:SetPoint("TOPRIGHT", buyBar, "TOPRIGHT", -12, -14)
	primaryBtn:SetText("Direkt kaufen")
	primaryBtn:SetScript("OnClick", function()
		NS.Buyer:ExecutePrimaryAction()
	end)
	primaryBtn:Disable()
	self.PrimaryBuyBtn = primaryBtn

	local cancelBtn = CreateFrame("Button", nil, buyBar, "UIPanelButtonTemplate")
	cancelBtn:SetSize(56, 22)
	cancelBtn:SetPoint("TOPRIGHT", primaryBtn, "BOTTOMRIGHT", 0, -8)
	cancelBtn:SetText("Abbr.")
	cancelBtn:SetScript("OnClick", function()
		local cur = NS.Buyer.selected
		NS.Buyer:Reset(cur ~= nil)
		if cur then
			NS.Buyer:InspectEntry(cur)
		end
	end)
	self.CancelBuyBtn = cancelBtn

	local nextBtn = CreateFrame("Button", nil, buyBar, "UIPanelButtonTemplate")
	nextBtn:SetSize(66, 22)
	nextBtn:SetPoint("RIGHT", cancelBtn, "LEFT", -4, 0)
	nextBtn:SetText("Nächstes")
	nextBtn:SetScript("OnClick", function()
		NS.Buyer:SelectNextItem()
	end)
	self.NextItemBtn = nextBtn

	local refreshBtn = CreateFrame("Button", nil, buyBar, "UIPanelButtonTemplate")
	refreshBtn:SetSize(66, 22)
	refreshBtn:SetPoint("RIGHT", nextBtn, "LEFT", -4, 0)
	refreshBtn:SetText("Prüfen")
	refreshBtn:SetScript("OnClick", function()
		if NS.Buyer.selected then
			NS.Buyer:InspectEntry(NS.Buyer.selected)
		end
	end)
	self.RefreshItemBtn = refreshBtn
end

function AuctionatorSniperBuyoutTabMixin:GetVisibleRowCount()
	local h = self.RowsContainer and self.RowsContainer:GetHeight() or 260
	return NS.Clamp(math.floor(h / ROW_HEIGHT), 1, MAX_ROWS)
end

function AuctionatorSniperBuyoutTabMixin:RefreshPresetButtons()
	local db = NS.GetDB()
	for _, btn in ipairs(self.profitPresets) do
		local text = btn.baseLabel or btn:GetText()
		if db.minProfitCopper == btn.minCopper then
			btn:SetText("|cff44ff88" .. text .. "|r")
		else
			btn:SetText(text)
		end
	end
end

function AuctionatorSniperBuyoutTabMixin:RefreshSortToggles()
	local sortField, sortAsc = NS.Scanner:GetSort()
	if sortField == "totalProfit" then
		self.SortProfitBtn:SetText("|cff44ff88Nach Gewinn|r")
	else
		self.SortProfitBtn:SetText("Nach Gewinn")
	end
	if sortField == "name" then
		self.SortItemBtn:SetText("|cff44ff88Pro Item (A-Z)|r")
	else
		self.SortItemBtn:SetText("Pro Item (A-Z)")
	end

	for _, hBtn in ipairs(self.headerButtons) do
		local col = hBtn.col
		if col.field == sortField then
			local marker = sortAsc and " (^)" or " (v)"
			hBtn.label:SetText("|cff44ff88" .. col.label .. marker .. "|r")
		else
			hBtn.label:SetText(col.label)
		end
	end
end

function AuctionatorSniperBuyoutTabMixin:RefreshSummary()
	local s = NS.Scanner.summary
	local b = NS.Buyer
	self.SummaryText:SetText(string.format(
		"Treffer: |cff55ff99%d|r Items (%d Stk)  |  Gesamtgewinn: |cff55ff99+%s|r  |  Session: %d gekauft (+%s)",
		s.itemCount or 0,
		s.unitCount or 0,
		NS.FormatMoney(s.totalProfit or 0),
		b.sessionBoughtQty or 0,
		NS.FormatMoney(b.sessionProfitCopper or 0)
	))
end

function AuctionatorSniperBuyoutTabMixin:RefreshStatus()
	local sc = NS.Scanner
	if sc.state == "READY" then
		self.ScanStatusText:SetText(string.format(
			"%s (%s)",
			tostring(sc.scanSource or "Scan"),
			NS.FormatAge(sc.scanTimestamp)
		))
	else
		self.ScanStatusText:SetText(sc.statusMessage or "")
	end
end

function AuctionatorSniperBuyoutTabMixin:RefreshTable()
	local list = NS.Scanner.filteredItems
	local visibleCount = self:GetVisibleRowCount()
	local maxOffset = math.max(0, #list - visibleCount)
	self.scrollOffset = NS.Clamp(self.scrollOffset or 0, 0, maxOffset)

	self.ScrollSlider:SetMinMaxValues(0, maxOffset)
	self.ScrollSlider:SetValue(self.scrollOffset)
	if maxOffset > 0 then
		self.ScrollSlider:Show()
	else
		self.ScrollSlider:Hide()
	end

	self.EmptyText:SetShown(#list == 0)

	local selectedKey = NS.Buyer.selected and NS.Buyer.selected.groupKey or nil

	for i = 1, MAX_ROWS do
		local row = self.rows[i]
		local dataIdx = self.scrollOffset + i
		local entry = (i <= visibleCount) and list[dataIdx] or nil
		row.entry = entry
		if entry then
			row:Show()
			row.icon:SetTexture(entry.icon or NS.ICON_TEXTURE)
			local r, g, b = GetQualityColor(entry.quality)
			local displayName = entry.name or ("Item " .. tostring(entry.itemID))
			if entry.containsOwn then
				displayName = "|cffffd200[Eigene]|r " .. displayName
			end
			row.nameText:SetText(displayName)
			row.nameText:SetTextColor(r, g, b)

			if entry.isExact then
				row.qtyText:SetText(tostring(entry.profitableQty or 1))
			else
				row.qtyText:SetText("~" .. tostring(entry.scanTotalQty or 1))
			end
			row.buyText:SetText(NS.FormatMoney(entry.cheapestBuyout))
			row.vendorText:SetText(NS.FormatMoney(entry.vendorPrice))
			row.unitText:SetText("|cff66ff99+" .. NS.FormatMoney(entry.unitProfit) .. "|r")
			local totalColor = entry.isExact and "|cff33ff77+" or "|cffffcc44~+"
			row.totalText:SetText(totalColor .. NS.FormatMoney(entry.totalProfit) .. "|r")

			local isSel = (selectedKey ~= nil and entry.groupKey == selectedKey)
			if isSel then
				row.bg:SetColorTexture(0.10, 0.34, 0.22, 0.85)
			else
				row.bg:SetColorTexture(0.08, 0.10, 0.12, (i % 2 == 0) and 0.65 or 0.35)
			end

			if isSel and NS.Buyer:CanExecutePrimary() then
				if NS.Buyer.state == "CONFIRM_COMMODITY" then
					row.actBtn:SetText("Bestät.")
				else
					row.actBtn:SetText("Kaufen")
				end
			else
				row.actBtn:SetText("Prüfen")
			end
		else
			row:Hide()
		end
	end
end

function AuctionatorSniperBuyoutTabMixin:RefreshBuyerPanel()
	local b = NS.Buyer
	local entry = b.selected

	if not entry then
		self.SelIconBtn.tex:SetTexture(NS.ICON_TEXTURE)
		self.SelName:SetText("Kein Item ausgewählt")
		self.SelName:SetTextColor(0.85, 0.85, 0.85)
		self.SelStatus:SetText(b.statusText or "")
		self.SelStatus:SetTextColor(0.8, 0.85, 0.9)
		self.BuyPriceLine:SetText("")
		self.BuyProfitLine:SetText("")
		self.QtyLabel:Hide()
		self.QtyBox:Hide()
		self.MaxQtyBtn:Hide()
		self.PrimaryBuyBtn:SetText("Direkt kaufen")
		self.PrimaryBuyBtn:Disable()
		self.RefreshItemBtn:Disable()
		self.CancelBuyBtn:Disable()
		return
	end

	self.SelIconBtn.tex:SetTexture(entry.icon or NS.ICON_TEXTURE)
	local r, g, bl = GetQualityColor(entry.quality)
	self.SelName:SetText(entry.name or ("Item " .. tostring(entry.itemID)))
	self.SelName:SetTextColor(r, g, bl)
	self.SelStatus:SetText(b.statusText or "")
	if b.isError then
		self.SelStatus:SetTextColor(1, 0.38, 0.38)
	elseif b.state == "CONFIRM_COMMODITY" or b.state == "READY_ITEM" or b.state == "READY_COMMODITY" or b.state == "DONE" then
		self.SelStatus:SetTextColor(0.38, 1, 0.60)
	else
		self.SelStatus:SetTextColor(1, 0.85, 0.40)
	end

	self.RefreshItemBtn:Enable()
	if b.commodityPurchaseActive or b.state == "SEARCHING" or b.state == "SEARCHING_BROWSE" or b.state == "LOADING_KEY" or b.state == "CONFIRM_COMMODITY" then
		self.CancelBuyBtn:Enable()
	else
		self.CancelBuyBtn:Disable()
	end

	if b.state == "READY_COMMODITY" then
		self.QtyLabel:Show()
		self.QtyBox:Show()
		self.MaxQtyBtn:Show()
		if not self.QtyBox:HasFocus() then
			self.QtyBox:SetNumber(b.desiredQty or 1)
		end
		self.BuyPriceLine:SetText(string.format(
			"Kosten: %s  |  Vendor: %s",
			NS.FormatMoney(b.expectedTotal),
			NS.FormatMoney(entry.vendorPrice * (b.desiredQty or 1))
		))
		self.BuyProfitLine:SetText("|cff44ff88Gewinn: +" .. NS.FormatMoney(b.expectedProfit) .. "|r")
		self.PrimaryBuyBtn:SetText(string.format("Kauf starten (%dx)", b.desiredQty or 1))
	elseif b.state == "CONFIRM_COMMODITY" then
		self.QtyLabel:Hide()
		self.QtyBox:Hide()
		self.MaxQtyBtn:Hide()
		self.BuyPriceLine:SetText(string.format(
			"Gesperrt: %s  |  Vendor: %s",
			NS.FormatMoney(b.confirmedTotal),
			NS.FormatMoney(entry.vendorPrice * (b.desiredQty or 1))
		))
		self.BuyProfitLine:SetText("|cff33ff77Netto-Gewinn: +" .. NS.FormatMoney(b.confirmedProfit) .. "|r")
		self.PrimaryBuyBtn:SetText(string.format("JETZT KAUFEN (%dx)", b.desiredQty or 1))
	elseif b.state == "READY_ITEM" and b.targetListing then
		self.QtyLabel:Hide()
		self.QtyBox:Hide()
		self.MaxQtyBtn:Hide()
		self.BuyPriceLine:SetText(string.format(
			"Buyout: %s  |  Vendor: %s",
			NS.FormatMoney(b.targetListing.buyoutAmount),
			NS.FormatMoney(b.targetListing.vendorPrice)
		))
		self.BuyProfitLine:SetText("|cff44ff88Gewinn: +" .. NS.FormatMoney(b.targetListing.profit) .. "|r")
		if b.itemBuyArmed then
			self.PrimaryBuyBtn:SetText("KAUF BESTÄTIGEN!")
		else
			self.PrimaryBuyBtn:SetText("Direkt kaufen")
		end
	elseif b.state == "LOCKING_COMMODITY" or b.state == "BUYING" then
		self.QtyLabel:Hide()
		self.QtyBox:Hide()
		self.MaxQtyBtn:Hide()
		self.PrimaryBuyBtn:SetText("Wird ausgeführt...")
	else
		self.QtyLabel:Hide()
		self.QtyBox:Hide()
		self.MaxQtyBtn:Hide()
		self.BuyPriceLine:SetText("Vendor: " .. NS.FormatMoney(entry.vendorPrice))
		self.BuyProfitLine:SetText("")
		self.PrimaryBuyBtn:SetText("Direkt kaufen")
	end

	if b:CanExecutePrimary() then
		self.PrimaryBuyBtn:Enable()
	else
		self.PrimaryBuyBtn:Disable()
	end
end
