# Changelog - AuctionatorSniperBuyout

## v1.0.0 (2026-11-24)
- Neu: Companion-Addon `AuctionatorSniperBuyout` fuer WoW Forever `16001` (`Dependencies: Auctionator` v352).
- Neu: Nativer 5. AH-Tab `Sniper` via `Auctionator.Tabs.Register` + `LibAHTab-1-0` mit eigenem 256x256 Medaillon-Artwork `logo.tga`.
- Neu: Automatische Analyse nach Auctionator Full Scan (`IncrementalScan` + `ReplicateScan`) sowie manuelle DB-Analyse mit time-sliced Batches und asynchroner Item-Daten-Aufloesung.
- Neu: Sortierung `Nach Gewinn` (gesamt / pro Stueck), `Pro Item (A-Z)`, Buyout, Vendor-Wert und Menge sowie Textsuche und Mindestgewinn-/Margen-Filter.
- Neu: Sichere Hardware-Klick-Direktkauf-FSM fuer Non-Commodities (`PlaceBid`) und Commodities (`StartCommoditiesPurchase` -> harter Vendor-Preis-Guard -> 2-Arg `ConfirmCommoditiesPurchase`) inkl. Browse-Fallback fuer Replicate-Gear.
- Neu: Blizzard-Settings-Integration (`/asb`, `/sniper`, Addon Compartment, Reset).
