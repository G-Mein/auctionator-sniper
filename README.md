# AuctionatorSniperBuyout

Companion-Addon fuer **Auctionator** auf **WoW Forever (`1.60.1.71037`, `## Interface: 16001`)**.
Findet nach jedem Auctionator Full Scan (sowohl Standard-FullScan als auch Replicate-Scan oder bestehender Auctionator-Datenbank) alle vendorbaren Items, deren AH-Buyout unter dem NPC-Vendor-Verkaufswert liegt, und erlaubt den sicheren Direktkauf per Hardware-Klick.

## Installation
Ordner `AuctionatorSniperBuyout` nach `_forever_\Interface\AddOns\AuctionatorSniperBuyout\` legen (`Dependencies: Auctionator` v352).

## Funktionen
- **Nativer AH-Tab `Sniper`**: Integriert sich als 5. Auctionator-Tab im Auktionshaus (bestehende Tabs 1..4 bleiben unveraendert) und zeigt im Tab-Titel die aktuelle Trefferzahl `Sniper (N)`.
- **Automatische Scan-Auswertung**: Reagiert automatisch auf Auctionator Full Scans (`IncrementalScan` & `ReplicateScan`) sowie ueber Buttons im Tab (`Full Scan`, `Replicate`, `DB pruefen`).
- **Exakte Vendor-Gewinn-Berechnung**: Filtert auf `sellPrice > 0`, schliesst BattlePets, WoW-Tokens, nicht verkaufbare Items sowie Bid-Only-Auktionen ohne Buyout aus und rechnet in exakter 1c-Kupfer-Granularitaet.
- **Sortierung pro Item & nach Gewinn**:
  - Schnell-Buttons: **Nach Gewinn** (`totalProfit` absteigend) und **Pro Item (A-Z)** (`name` aufsteigend)
  - Klickbare Spaltenkoepfe fuer Item-Name, Menge, Buyout, Vendor-Wert, Gewinn/Stk und Gewinn gesamt
  - Live-Filter: Suchfeld, Mindestgewinn-Presets (`Alle`, `1s`, `10s`, `1g`), Mindestmarge (%) und Ausblenden eigener Auktionen
- **Sicherer Live-Direktkauf**:
  - Klick auf ein Item prueft zuerst den aktuellen Live-Bestand im AH (mit Reload-Schutz und Ausfilterung eigener Auktionen).
  - **Einzel-Items**: `Direkt kaufen` per `PlaceBid` (optional doppelte Sicherheitsbestaetigung).
  - **Stapelware (Commodities)**: Menge waehlbar (`Menge`-Feld + `Max`), Klick 1 sperrt Live-Preis (`StartCommoditiesPurchase`), harter Profit-Guard bricht automatisch ab falls der Preis ueber Vendor/Limit steigt, Klick 2 kauft (`ConfirmCommoditiesPurchase`).
  - **Session-Zaehler**: Zeigt gekaufte Menge und realisierten Netto-Gewinn.

## Slash-Commands
- `/asb` oder `/sniper` -> Oeffnet den Sniper-Tab (bei offenem AH) bzw. die Einstellungen.
- `/asb scan` -> Startet Auctionator Full Scan.
- `/asb replicate` -> Startet Replicate Scan.
- `/asb db` -> Prueft sofort die gespeicherte Auctionator-Datenbank.
- `/asb options` -> Oeffnet die Blizzard-Addon-Einstellungen.
- `/asb status` -> Gibt aktuellen Scan- und Session-Status im Chat aus.

## Praxisgate / Offener In-Game-Test (WoW Forever 16001)
Bisher nur statisch gegen Auctionator v352 und `Wow.exe` geprueft (kein laufender Client-Zugriff). Nach erstem Login kurz pruefen:
1. AH oeffnen -> Tab `Sniper` erscheint ohne Lua-Fehler; Tabs 1..4 unveraendert.
2. Full Scan / Replicate ausfuehren -> Trefferliste fuellt sich, Sortierung `Nach Gewinn` & `Pro Item (A-Z)` arbeitet sauber.
3. Item anklicken & testen: Live-Pruefung, Kauf eines Einzel-Items (`PlaceBid`) und 2-Klick-Kauf + Abbruch einer Commodity-Auktion.
