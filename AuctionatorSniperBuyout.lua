local addonName, NS = ...

local TAB_ID = "AuctionatorTabs_Sniper"
local tabRegistered = false

local function RegisterSniperTab()
	if tabRegistered then
		return
	end
	if Auctionator and Auctionator.Tabs and type(Auctionator.Tabs.Register) == "function" then
		Auctionator.Tabs.Register({
			name = "Sniper",
			textLabel = "Sniper",
			tabTemplate = "AuctionatorSniperBuyoutTabFrameTemplate",
			tabHeader = "Auctionator Sniper Buyout",
			tabFrameName = "AuctionatorSniperBuyoutTabFrame",
			tabOrder = 5,
		})
		tabRegistered = true
	end
end

-- Sofort beim Laden registrieren (vor dem ersten Oeffnen des AH)
RegisterSniperTab()

function NS.OpenSniperTab()
	if not NS.IsAuctionHouseOpen() then
		NS.Print("Bitte zuerst ein Auktionshaus öffnen (Sniper ist dort der Tab 'Sniper').")
		return false
	end
	if type(LibStub) == "function" then
		local libAHTab = LibStub("LibAHTab-1-0", true)
		if libAHTab and type(libAHTab.DoesIDExist) == "function" and libAHTab:DoesIDExist(TAB_ID) then
			libAHTab:SetSelected(TAB_ID)
			return true
		end
	end
	NS.Print("Sniper-Tab ist noch nicht initialisiert.")
	return false
end

local eventBusListener = {}

function eventBusListener:ReceiveEvent(eventName, eventData)
	local fullEv = Auctionator and Auctionator.FullScan and Auctionator.FullScan.Events
	local incEv = Auctionator and Auctionator.IncrementalScan and Auctionator.IncrementalScan.Events

	if fullEv then
		if eventName == fullEv.ScanStart then
			NS.Scanner:NotifyScanStart("Replicate")
			return
		elseif eventName == fullEv.ScanProgress then
			NS.Scanner:NotifyScanProgress("Replicate", eventData)
			return
		elseif eventName == fullEv.ScanComplete then
			NS.Scanner:AnalyzeReplicateData(eventData)
			return
		elseif eventName == fullEv.ScanFailed then
			NS.Scanner:NotifyScanFailed("Replicate")
			return
		end
	end

	if incEv then
		if eventName == incEv.ScanStart then
			NS.Scanner:NotifyScanStart("FullScan")
			return
		elseif eventName == incEv.ScanProgress then
			NS.Scanner:NotifyScanProgress("FullScan", eventData)
			return
		elseif eventName == incEv.ScanComplete then
			NS.Scanner:AnalyzeIncrementalData(eventData)
			return
		elseif eventName == incEv.ScanFailed then
			NS.Scanner:NotifyScanFailed("FullScan")
			return
		end
	end
end

local function RegisterAuctionatorEventBus()
	if not (Auctionator and Auctionator.EventBus and type(Auctionator.EventBus.Register) == "function") then
		return
	end
	local events = {}
	if Auctionator.FullScan and Auctionator.FullScan.Events then
		local e = Auctionator.FullScan.Events
		if e.ScanStart then table.insert(events, e.ScanStart) end
		if e.ScanProgress then table.insert(events, e.ScanProgress) end
		if e.ScanComplete then table.insert(events, e.ScanComplete) end
		if e.ScanFailed then table.insert(events, e.ScanFailed) end
	end
	if Auctionator.IncrementalScan and Auctionator.IncrementalScan.Events then
		local e = Auctionator.IncrementalScan.Events
		if e.ScanStart then table.insert(events, e.ScanStart) end
		if e.ScanProgress then table.insert(events, e.ScanProgress) end
		if e.ScanComplete then table.insert(events, e.ScanComplete) end
		if e.ScanFailed then table.insert(events, e.ScanFailed) end
	end
	if #events > 0 then
		Auctionator.EventBus:Register(eventBusListener, events)
	end
end

NS.RegisterCallback("SCAN_COMPLETE", function(summary, sourceLabel)
	local db = NS.GetDB()
	local count = (summary and summary.itemCount) or 0
	local profit = (summary and summary.totalProfit) or 0

	if db.chatSummary then
		NS.Print(string.format(
			"%s abgeschlossen: %d Item(s) unter Vendor-Wert | Gewinn: +%s",
			tostring(sourceLabel or "Scan"),
			count,
			NS.FormatMoney(profit)
		))
	end

	if sourceLabel == "Replicate" or sourceLabel == "FullScan" then
		if count > 0 and db.playSound then
			NS.PlayDealSound()
		end
		if count > 0 and db.autoOpenTab and NS.IsAuctionHouseOpen() then
			NS.OpenSniperTab()
		end
	end
end)

_G.SLASH_AUCTIONATORSNIPERBUYOUT1 = "/asb"
_G.SLASH_AUCTIONATORSNIPERBUYOUT2 = "/sniper"
SlashCmdList["AUCTIONATORSNIPERBUYOUT"] = function(msg)
	local cmd = string.lower((tostring(msg or ""):match("^%s*(%S+)") or ""))
	if cmd == "options" or cmd == "opt" or cmd == "config" then
		NS.OpenSettings()
	elseif cmd == "scan" then
		NS.Scanner:StartFullScan()
	elseif cmd == "replicate" or cmd == "rep" then
		NS.Scanner:StartReplicateScan()
	elseif cmd == "db" then
		NS.Scanner:AnalyzeAuctionatorDB()
	elseif cmd == "status" then
		local sc = NS.Scanner
		local b = NS.Buyer
		NS.Print(string.format(
			"Status: %s | Treffer: %d | Session: %d gekauft (+%s)",
			sc.statusMessage or "Bereit",
			(sc.summary and sc.summary.itemCount) or 0,
			b.sessionBoughtQty or 0,
			NS.FormatMoney(b.sessionProfitCopper or 0)
		))
	elseif cmd == "help" or cmd == "?" then
		NS.Print("Befehle: /asb (Tab öffnen), /asb scan, /asb replicate, /asb db, /asb options, /asb status")
	else
		if NS.IsAuctionHouseOpen() then
			NS.OpenSniperTab()
		else
			NS.OpenSettings()
			NS.Print("Tipp: Im Auktionshaus findest du unten den Tab 'Sniper'.")
		end
	end
end

function AuctionatorSniperBuyout_OnAddonCompartmentClick()
	if NS.IsAuctionHouseOpen() then
		NS.OpenSniperTab()
	else
		NS.OpenSettings()
	end
end

local bootFrame = CreateFrame("Frame")
bootFrame:RegisterEvent("ADDON_LOADED")
bootFrame:RegisterEvent("PLAYER_LOGIN")
bootFrame:SetScript("OnEvent", function(_, event, arg1)
	if event == "ADDON_LOADED" and not NS.IsSecret(arg1) and arg1 == addonName then
		RegisterSniperTab()
		NS.InitDB()
		NS.Scanner:Init()
		NS.Options:Init()
	elseif event == "PLAYER_LOGIN" then
		RegisterSniperTab()
		RegisterAuctionatorEventBus()
	end
end)
