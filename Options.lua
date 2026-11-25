local _, NS = ...

local Options = {
	initialized = false,
	mainCategory = nil,
}
NS.Options = Options

local registeredVars = {}

local function NotifyAllSettings()
	if not (Settings and Settings.NotifyUpdate) then
		return
	end
	for _, varName in ipairs(registeredVars) do
		pcall(Settings.NotifyUpdate, varName)
	end
end

local function AddSectionHeader(layout, title)
	if layout and CreateSettingsListSectionHeaderInitializer then
		layout:AddInitializer(CreateSettingsListSectionHeaderInitializer(title))
	end
end

local function AddButtonRow(layout, label, buttonText, onClick, tooltip)
	if layout and CreateSettingsButtonInitializer then
		-- 5. Argument zwingend false: verhindert Taint in Blizzards Optionssuche.
		layout:AddInitializer(CreateSettingsButtonInitializer(label, buttonText, onClick, tooltip, false))
	end
end

local function RegisterBool(category, varName, optKey, label, tooltip)
	local defaultVal = NS.DEFAULTS[optKey] == true
	local setting = Settings.RegisterProxySetting(
		category,
		varName,
		Settings.VarType.Boolean,
		label,
		defaultVal,
		function()
			local db = NS.GetDB()
			return db[optKey] == true
		end,
		function(val)
			local db = NS.GetDB()
			db[optKey] = val == true
			NS.FireCallback("OPTIONS_CHANGED")
		end
	)
	Settings.CreateCheckbox(category, setting, tooltip)
	table.insert(registeredVars, varName)
end

local function RegisterMappedSlider(category, varName, label, defaultVal, minVal, maxVal, step, getter, setter, formatter, tooltip)
	local setting = Settings.RegisterProxySetting(
		category,
		varName,
		Settings.VarType.Number,
		label,
		defaultVal,
		getter,
		setter
	)
	local sliderOpts = Settings.CreateSliderOptions(minVal, maxVal, step)
	if formatter and MinimalSliderWithSteppersMixin and MinimalSliderWithSteppersMixin.Label then
		sliderOpts:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right, formatter)
	end
	Settings.CreateSlider(category, setting, sliderOpts, tooltip)
	table.insert(registeredVars, varName)
end

function Options:Init()
	if self.initialized then
		return
	end
	if not (
		Settings
		and Settings.RegisterVerticalLayoutCategory
		and Settings.RegisterAddOnCategory
		and Settings.RegisterProxySetting
		and Settings.CreateCheckbox
		and Settings.CreateDropdown
		and Settings.CreateSlider
		and Settings.CreateSliderOptions
		and Settings.CreateControlTextContainer
	) then
		return
	end

	local mainCat, mainLayout = Settings.RegisterVerticalLayoutCategory("Auctionator Sniper Buyout")
	self.mainCategory = mainCat

	AddSectionHeader(mainLayout, "Scanner & Profit-Filter")

	RegisterMappedSlider(
		mainCat,
		"ASB_OPT_MIN_PROFIT_SILVER",
		"Mindestgewinn (Silber)",
		0,
		0,
		500,
		1,
		function()
			local copper = NS.GetDB().minProfitCopper or 1
			if copper <= 1 then
				return 0
			end
			return NS.Clamp(math.floor(copper / 100), 0, 500)
		end,
		function(val)
			local db = NS.GetDB()
			local s = math.floor(tonumber(val) or 0)
			db.minProfitCopper = (s <= 0) and 1 or (s * 100)
			NS.FireCallback("OPTIONS_CHANGED")
		end,
		function(v)
			local s = math.floor(tonumber(v) or 0)
			if s <= 0 then
				return "Ab 1 Kupfer"
			end
			return tostring(s) .. " Silber"
		end,
		"Zeigt nur Items, deren Stückgewinn (Vendor minus Buyout) mindestens diesem Wert entspricht."
	)

	RegisterMappedSlider(
		mainCat,
		"ASB_OPT_MIN_PROFIT_PCT",
		"Mindestmarge (%)",
		NS.DEFAULTS.minProfitPercent,
		0,
		100,
		1,
		function()
			return tonumber(NS.GetDB().minProfitPercent) or 0
		end,
		function(val)
			NS.GetDB().minProfitPercent = NS.Clamp(math.floor(tonumber(val) or 0), 0, 100)
			NS.FireCallback("OPTIONS_CHANGED")
		end,
		function(v)
			local pct = math.floor(tonumber(v) or 0)
			if pct <= 0 then
				return "Aus (ab 1c)"
			end
			return tostring(pct) .. " %"
		end,
		"Filtert zusätzlich nach minimaler Gewinnspanne im Verhältnis zum Kaufpreis."
	)

	RegisterBool(
		mainCat,
		"ASB_OPT_HIDE_OWN",
		"hideOwnAuctions",
		"Eigene Auktionen ausblenden",
		"Blendet Treffer aus, bei denen nur eigene Auktionen unter dem Vendor-Wert liegen. Beim Kauf werden eigene Auktionen immer ausgeschlossen."
	)

	RegisterBool(
		mainCat,
		"ASB_OPT_DB_TODAY_ONLY",
		"dbScanTodayOnly",
		"DB-Prüfung nur für heutige Scan-Preise",
		"Begrenzt den manuellen Button 'DB prüfen' auf Preise, die heute in Auctionator erfasst wurden."
	)

	AddSectionHeader(mainLayout, "Sortierung & Direktkauf-Sicherheit")

	local sortSetting = Settings.RegisterProxySetting(
		mainCat,
		"ASB_OPT_DEFAULT_SORT",
		Settings.VarType.String,
		"Standard-Sortierung",
		NS.DEFAULTS.defaultSortField,
		function()
			return NS.GetDB().defaultSortField or NS.DEFAULTS.defaultSortField
		end,
		function(val)
			local db = NS.GetDB()
			if NS.SORT_DEFAULT_ASC[val] ~= nil then
				db.defaultSortField = val
				db.defaultSortAsc = NS.SORT_DEFAULT_ASC[val] == true
				if NS.Scanner then
					NS.Scanner:SetSort(db.defaultSortField, db.defaultSortAsc)
				end
				NS.FireCallback("OPTIONS_CHANGED")
			end
		end
	)
	local function GetSortOptions()
		local c = Settings.CreateControlTextContainer()
		c:Add("totalProfit", "Nach Gewinn gesamt (absteigend)", "Zeigt zuerst die Items mit dem größten Gesamtgewinn.")
		c:Add("unitProfit", "Nach Gewinn pro Stück (absteigend)", "Zeigt zuerst den höchsten Einzelgewinn.")
		c:Add("name", "Pro Item (Alphabetisch A-Z)", "Sortiert die Trefferliste übersichtlich pro Item-Name.")
		c:Add("buyout", "Günstigster Buyout (aufsteigend)", "Zeigt zuerst die Items mit dem geringsten Kaufpreis.")
		return c:GetData()
	end
	Settings.CreateDropdown(mainCat, sortSetting, GetSortOptions, "Wählt die Standardsortierung nach jedem Full Scan.")
	table.insert(registeredVars, "ASB_OPT_DEFAULT_SORT")

	RegisterMappedSlider(
		mainCat,
		"ASB_OPT_MAX_BUYOUT_GOLD",
		"Max. Kaufpreis pro Klick (Gold)",
		0,
		0,
		5000,
		10,
		function()
			return NS.Clamp(math.floor((NS.GetDB().maxBuyoutCopper or 0) / 10000), 0, 5000)
		end,
		function(val)
			local g = NS.Clamp(math.floor(tonumber(val) or 0), 0, 5000)
			NS.GetDB().maxBuyoutCopper = g * 10000
			NS.FireCallback("OPTIONS_CHANGED")
		end,
		function(v)
			local g = math.floor(tonumber(v) or 0)
			if g <= 0 then
				return "Unbegrenzt"
			end
			return tostring(g) .. " Gold"
		end,
		"Schützt vor versehentlich hohen Einzelkäufen (0 = unbegrenzt)."
	)

	RegisterMappedSlider(
		mainCat,
		"ASB_OPT_MAX_COMMODITY_QTY",
		"Max. Stapelware pro Klick",
		NS.DEFAULTS.maxCommodityQty,
		1,
		1000,
		5,
		function()
			return NS.Clamp(math.floor(tonumber(NS.GetDB().maxCommodityQty) or 200), 1, 1000)
		end,
		function(val)
			NS.GetDB().maxCommodityQty = NS.Clamp(math.floor(tonumber(val) or 200), 1, 1000)
			NS.FireCallback("OPTIONS_CHANGED")
		end,
		function(v)
			return tostring(math.floor(tonumber(v) or 1)) .. " Stk."
		end,
		"Maximale Stückzahl, die bei Stapelware standardmäßig pro Kaufvorgang vorausgewählt wird."
	)

	RegisterBool(
		mainCat,
		"ASB_OPT_CONFIRM_ITEM_BUY",
		"confirmItemBuy",
		"Einzel-Items vor Kauf doppelt bestätigen",
		"Erfordert bei Einzel-Items zwei Klicks auf 'Direkt kaufen' statt 1-Klick-Sofortkauf."
	)

	AddSectionHeader(mainLayout, "Benachrichtigung & AH-Tab")

	RegisterBool(
		mainCat,
		"ASB_OPT_AUTO_OPEN_TAB",
		"autoOpenTab",
		"Bei Treffern nach Full Scan zum Sniper-Tab wechseln",
		"Öffnet automatisch den 'Sniper'-Tab im Auktionshaus, sobald ein Scan profitable Items findet."
	)

	RegisterBool(
		mainCat,
		"ASB_OPT_PLAY_SOUND",
		"playSound",
		"Ton bei Treffern und Käufen abspielen",
		"Spielt ein dezentes akustisches Signal bei neuen Sniper-Funden und erfolgreichen Käufen."
	)

	RegisterBool(
		mainCat,
		"ASB_OPT_CHAT_SUMMARY",
		"chatSummary",
		"Zusammenfassung nach Scan im Chat anzeigen",
		"Gibt nach jedem abgeschlossenen Scan Anzahl und Gesamtgewinn im Chat aus."
	)

	AddSectionHeader(mainLayout, "Aktionen & Standardwerte")

	AddButtonRow(
		mainLayout,
		"Sniper-Tab im Auktionshaus",
		"Tab öffnen",
		function()
			if NS.OpenSniperTab then
				NS.OpenSniperTab()
			end
		end,
		"Wechselt bei geöffnetem Auktionshaus direkt in den Sniper-Tab."
	)

	AddButtonRow(
		mainLayout,
		"Gespeicherte Auctionator-Daten prüfen",
		"DB prüfen",
		function()
			NS.Scanner:AnalyzeAuctionatorDB()
		end,
		"Durchsucht sofort alle bereits in Auctionator gespeicherten Preise nach Vendor-Schnäppchen."
	)

	AddButtonRow(
		mainLayout,
		"Einstellungen zurücksetzen",
		"Standardwerte",
		function()
			NS.ResetDB()
			NotifyAllSettings()
			NS.Print("Alle Einstellungen auf Standardwerte zurückgesetzt.")
		end,
		"Setzt alle Filter, Limits und Optionen wieder auf die Standardwerte zurück."
	)

	Settings.RegisterAddOnCategory(mainCat)
	self.initialized = true
end

function NS.OpenSettings()
	if type(InCombatLockdown) == "function" and InCombatLockdown() then
		NS.Print("Einstellungen können im Kampf nicht geöffnet werden.")
		return
	end
	if Options.mainCategory and Settings and Settings.OpenToCategory then
		Settings.OpenToCategory(Options.mainCategory:GetID())
	end
end
