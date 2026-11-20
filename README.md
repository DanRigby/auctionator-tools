# Auctionator Tools

A World of Warcraft **Forever** addon that finds ways to make gold on the auction house, built on [Auctionator](https://www.curseforge.com/wow/addons/auctionator)'s scan data. It doesn't scan the auction house itself. It reads Auctionator's scans and price history and has its own window.

## Install

1. Install Auctionator.
2. Copy the `AuctionatorTools` folder into `World of Warcraft\_forever_\Interface\AddOns\`.
3. Optional: install [Preserve Auctionator AH Scan](https://www.curseforge.com/wow/addons/preserve-auctionator-ah-scan) so your last scan is still available after a reload or relog.

## Use

Open the window with `/atools`, or from the addon compartment on the minimap. At the auction house, click **Scan**. This runs Auctionator's full scan, or its summary scan while the full scan is on its 15-minute cooldown.

| View | What it shows |
| --- | --- |
| **Below Vendor** | Listings you can buy and sell to a vendor for more. Use the toggle to compare buyouts or bids (bids need a full scan). |
| **Deals** | Listings at least *N*% (default 30%) below the item's typical price and at or below the **Max buyout** (default 5g). The limit applies to each listing's total buyout, or the per-item price in a summary scan; grouped totals can exceed it. Typical price is the median daily low over the last 14 days of Auctionator history, excluding today, with at least 3 days required. Profit includes the 5% AH cut. |
| **Disenchant** | Green, blue and purple gear selling for less than the expected value of its disenchanted materials (from Auctionator). |
| **Crafting** | Your learned recipes whose product sells for more than its materials cost. Each material uses the cheaper of the AH price and any known vendor price. Open each profession window once so your recipes are recorded. |
| **Vendor Resale** | Items sold by vendors you've visited that sell for more on the AH. |

- Click a column header to sort.
- Set **Min profit** per view, for example `1c`, `50s` or `1g 25s` (the default is 1c).
- Type in the search box to filter by name.
- Hover a row for the item tooltip and details, such as the material breakdown for a craft. The tooltip also shows the item's min, max and average AH price over the last 14 days (including today) from Auctionator's history. The average is the mean daily low.

### Buying

Select a row and click **Buy** (or double-click it). The addon runs a fresh search and offers the most profitable listing that is still worth buying, using your min profit. Click **Confirm Buy** to buy it, or **Skip** to see the next one. Commodities need two clicks, one to get the final price and one to confirm. Every purchase is a separate click, as Blizzard requires.

Right-click a row, or use **Search in Auctionator**, to open the item in Auctionator's Shopping tab. In Crafting, **Shop Mats** searches Auctionator for every material that's cheapest on the AH, with the right quantities.

### Commands

- `/atools` toggles the window.
- `/atools autoopen` opens the window with the auction house.
- `/atools reset` resets the window position.

## Notes

- The addon only does work while its window is open, and only for the view you're looking at. Large scans are processed in small chunks so the game doesn't stutter.
- Summary-scan results only know the cheapest listing of each item, so quantities show as `1+`. Run a full scan for exact numbers.
