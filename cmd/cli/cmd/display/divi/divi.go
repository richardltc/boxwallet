package divi

import (
	"github.com/dustin/go-humanize"
	"math"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/app"
	diviImport "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/divi"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/currencyconvert"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/display"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/models"
	"strconv"
	"time"
)

type DIVI struct {
}

var blockChainInfo models.DiviBlockchainInfo
var info models.DiviGetInfo
var mnss models.DiviMNSyncStatus

var stakingInfo models.DiviStakingStatus
var ticker models.DiviTicker
var transactions models.DiviListTransactions
var walletInfo models.DiviWalletInfo
var diffGood, diffWarning float64
var lastBCSyncStatus = ""

//var lastMNSyncStatus = ""

var localCurrency string
var currConvert currencyconvert.CurrencyConvert

func (d DIVI) Bootstrap(lcurrency string) {
	localCurrency = lcurrency
}

func (d DIVI) About(coinAuth *models.CoinAuth) string {
	var a app.App
	var divi diviImport.Divi
	var sCoreVersion string
	info, _, err := divi.Info(coinAuth)
	if err != nil {
		sCoreVersion = "Unknown"
	} else {
		sCoreVersion = info.Result.Version
	}

	return "  [" + a.Name() + "    v" + a.Version() + "](fg:white)\n" +
		"  [" + divi.CoinName() + " Core    v" + sCoreVersion + "](fg:white)\n\n"
}

func activelyStakingTxt() string {
	if stakingInfo.Result.StakingStatus == true {
		return "Actively Staking: [Yes](fg:green)"
	} else {
		return "Actively Staking: [No](fg:yellow)"
	}
}

func balanceTxt() string {
	tBalance := walletInfo.Result.ImmatureBalance + walletInfo.Result.UnconfirmedBalance + walletInfo.Result.Balance
	tBalanceStr := humanize.FormatFloat("#,###.########", tBalance)

	// Work out balance
	if walletInfo.Result.ImmatureBalance > 0 {
		return "  Incoming.......   [" + tBalanceStr + "](fg:cyan)"
	} else if walletInfo.Result.UnconfirmedBalance > 0 {
		return "  Confirming....... [" + tBalanceStr + "](fg:yellow)"
	} else {
		return "  Balance:          [" + tBalanceStr + "](fg:green)"
	}
}

func balanceInCurrency() string {
	tBalance := walletInfo.Result.ImmatureBalance + walletInfo.Result.UnconfirmedBalance + walletInfo.Result.Balance
	var pricePerCoin float64
	var symbol string

	// Work out what currency
	switch localCurrency {
	case "AUD":
		symbol = "$"
		pricePerCoin = currConvert.Convert(ticker.DIVI.Quote.USD.Price) //ticker.DIVI.Quote.USD.Price * pricePerCoinAUD.Rates.AUD
	case "USD":
		symbol = "$"
		pricePerCoin = ticker.DIVI.Quote.USD.Price
	case "GBP":
		symbol = "£"
		pricePerCoin = currConvert.Convert(ticker.DIVI.Quote.USD.Price) //ticker.DIVI.Quote.USD.Price * pricePerCoinGBP.Rates.GBP
	default:
		symbol = "$"
		pricePerCoin = ticker.DIVI.Quote.USD.Price
	}

	tBalanceCurrency := pricePerCoin * tBalance

	tBalanceCurrencyStr := humanize.FormatFloat("###,###.##", tBalanceCurrency) //humanize.Commaf(tBalanceCurrency) //FormatFloat("#,###.####", tBalanceCurrency)

	// Work out balance
	if walletInfo.Result.ImmatureBalance > 0 {
		return "Incoming......... [" + symbol + tBalanceCurrencyStr + "](fg:cyan)"
	} else if walletInfo.Result.UnconfirmedBalance > 0 {
		return "Confirming....... [" + symbol + tBalanceCurrencyStr + "](fg:yellow)"
	} else {
		return "Currency:         [" + symbol + tBalanceCurrencyStr + "](fg:green)"
	}
}

func blockchainSyncTxt() string {
	//s := display.ConvertBCVerification(blockChainInfo.Result.Verificationprogress)
	//if s == "0.0" {
	//	s = ""
	//} else {
	//	s = s + "%"
	//}
	//
	//return s

	return ""
}

func plural(count int, singular string) (result string) {
	if (count == 1) || (count == 0) {
		result = strconv.Itoa(count) + " " + singular + " "
	} else {
		result = strconv.Itoa(count) + " " + singular + "s "
	}
	return
}

func secondsToHuman(input int) (result string) {
	//years := math.Floor(float64(input) / 60 / 60 / 24 / 7 / 30 / 12)
	seconds := input % (60 * 60 * 24 * 7 * 30 * 12)
	//months := math.Floor(float64(seconds) / 60 / 60 / 24 / 7 / 30)
	seconds = input % (60 * 60 * 24 * 7 * 30)
	weeks := math.Floor(float64(seconds) / 60 / 60 / 24 / 7)
	seconds = input % (60 * 60 * 24 * 7)
	days := math.Floor(float64(seconds) / 60 / 60 / 24)
	seconds = input % (60 * 60 * 24)
	hours := math.Floor(float64(seconds) / 60 / 60)
	seconds = input % (60 * 60)
	minutes := math.Floor(float64(seconds) / 60)
	seconds = input % 60

	if weeks > 0 {
		result = plural(int(weeks), "week") + plural(int(days), "day") + plural(int(hours), "hour") + plural(int(minutes), "minute")
	} else if days > 0 {
		result = plural(int(days), "day") + plural(int(hours), "hour") + plural(int(minutes), "minute")
	} else if hours > 0 {
		result = plural(int(hours), "hour") + plural(int(minutes), "minute")
	} else {
		result = plural(int(minutes), "minute")
	}

	return
}

func calculateNextLottery() string {
	var latestBlock, blocksLeft, secsUntilNextLottery int
	var sDateTime string
	latestBlock = blockChainInfo.Result.Blocks

	blocksLeft = (lastLotteryBlock() + 10080) - latestBlock
	// Calculate the seconds left.
	secsUntilNextLottery = blocksLeft * 60

	sDateTime = secondsToHuman(secsUntilNextLottery)

	return sDateTime
}

func lotteryTickets() string {
	iTotalTickets := 0
	currentBlock := blockChainInfo.Result.Blocks

	for i := len(transactions.Result) - 1; i >= 0; i-- {
		// If this transaction is not a stake, we're not interested in it.
		if transactions.Result[i].Category != "stake_reward" {
			continue
		}

		// Check to make sure the confirmations count is higher than -1
		if transactions.Result[i].Confirmations < 0 {
			continue
		}

		//lastLotteryBlockBlock := lottery.Lottery.NextLotteryBlock - 10080
		numBlocksSpread := currentBlock - lastLotteryBlock()

		// If the stake block is less than the next lottery block - 10080 then it's not in this week's lottery
		if transactions.Result[i].Confirmations > numBlocksSpread {
			continue
		}

		// We've got here, so count the stake...
		iTotalTickets = iTotalTickets + 1
	}

	return "Lottery tickets:  " + strconv.Itoa(iTotalTickets)
}

func (d DIVI) InitialBalance() string {
	return "  Balance:          [waiting for sync...](fg:yellow)\n" +
		"  Currency:         [waiting for sync...](fg:yellow)\n" +
		"  Security:         [waiting for sync...](fg:yellow)\n" +
		"  Staking %:	        [waiting for sync...](fg:yellow)\n" +
		"  Actively Staking: [waiting for sync...](fg:yellow)\n" +
		"  Next Lottery:     [waiting for sync...](fg:yellow)\n" +
		"  Lottery tickets:	  [waiting for sync...](fg:yellow)"
}

func (d DIVI) InitialNetwork() string {
	return "  Blocks:      [checking...](fg:yellow)\n" +
		"  Difficulty:  [checking...](fg:yellow)\n" +
		"  Blockchain:  [checking...](fg:yellow)\n" +
		"  Connections:  [checking...](fg:yellow)\n"
}

func lastLotteryBlock() int {
	var lastLotteryBlock, latestBlock int
	latestBlock = blockChainInfo.Result.Blocks

	for i := 0; i <= 10; i-- {
		lastLotteryBlock = lastLotteryBlock + 10080
		if lastLotteryBlock > latestBlock {
			lastLotteryBlock = lastLotteryBlock - 10080
			break
		}
	}

	return lastLotteryBlock
}

func (d DIVI) LiveNetwork() string {
	var bcSynced bool
	//var mnSynced bool
	var sBlockchainSync, sConnections, sBlocks, sDiff, sDiffVal string

	//if blockChainInfo.Result.Verificationprogress > 0.99999 {
	//	bcSynced = true
	//}
	if mnss.Result.IsBlockchainSynced == true {
		bcSynced = true
	} else {
		bcSynced = false
	}

	blocksStr := humanize.Comma(int64(blockChainInfo.Result.Blocks))
	if blocksStr == "0" {
		sBlocks = "Blocks:      [waiting...](fg:white)"
	} else {
		sBlocks = "Blocks:      [" + blocksStr + "](fg:green)"
	}

	if blockChainInfo.Result.Difficulty > 1000 {
		sDiffVal = humanize.FormatFloat("#.#", blockChainInfo.Result.Difficulty/1000) + "k"
	} else {
		sDiffVal = humanize.Ftoa(blockChainInfo.Result.Difficulty)
	}

	if blockChainInfo.Result.Difficulty >= diffGood {
		sDiff = "Difficulty:  [" + sDiffVal + "](fg:green)"
	} else if blockChainInfo.Result.Difficulty >= diffWarning {
		sDiff = "Difficulty:  [" + sDiffVal + "](fg:yellow)"
	} else {
		sDiff = "Difficulty:  [" + sDiffVal + "](fg:red)"
	}

	sBC := blockchainSyncTxt()

	if !bcSynced {
		nextBCSyncIndicator := display.NextProgBCIndicator(lastBCSyncStatus)
		sBlockchainSync = "Blockchain: [" + display.NextProgBCIndicator(nextBCSyncIndicator) + "syncing " + sBC + " ](fg:yellow)"
		lastBCSyncStatus = nextBCSyncIndicator
	} else {
		sBlockchainSync = "Blockchain:  [synced " + display.CUTFTickBold + "](fg:green)"
	}

	sNumCon := strconv.Itoa(info.Result.Connections)

	if info.Result.Connections < 1 {
		sConnections = "Connections: [" + sNumCon + "](fg:yellow)\n"
	} else {
		sConnections = "Connections: [" + sNumCon + "](fg:green)\n"
	}

	return "  " + sBlocks + "\n" +
		"  " + sDiff + "\n" +
		"  " + sBlockchainSync + "\n" +
		"  " + sConnections
}

func (d DIVI) LiveTransactions() (containsZeroConfs bool, rows [][]string) {
	var sRows [][]string

	// Record whether any of the transactions have 0 conf (so that we can display the boarder as yellow)
	bZeroConfs := false
	sRows = append(sRows, []string{" Date", " Category", " Amount", " Confirmations"})

	for i := len(transactions.Result) - 1; i >= 0; i-- {
		// Check to make sure the confirmations count is higher than -1
		if transactions.Result[i].Confirmations < 0 {
			continue
		}

		if transactions.Result[i].Confirmations < 1 {
			bZeroConfs = true
		}
		iTime, err := strconv.ParseInt(strconv.Itoa(transactions.Result[i].Blocktime), 10, 64)
		if err != nil {
			continue
		}
		tm := time.Unix(iTime, 0)
		sCat := display.GetCategorySymbol(transactions.Result[i].Category)
		tAmountStr := humanize.FormatFloat("#,###.########", transactions.Result[i].Amount)
		sConfirmationsStr := ""
		if transactions.Result[i].Confirmations > 5 {
			sConfirmationsStr = "Confirmed"
		} else {
			sConfirmationsStr = strconv.Itoa(transactions.Result[i].Confirmations)
		}
		sColour := display.GetCategoryColour(transactions.Result[i].Category)
		sRows = append(sRows, []string{
			" [" + tm.Format("2006-01-02 15:04"+"](fg:"+sColour+")"),
			" [" + sCat + "](fg:" + sColour + ")",
			" [" + tAmountStr + "](fg:" + sColour + ")",
			" [" + sConfirmationsStr + "](fg:" + sColour + ")"})
	}

	return bZeroConfs, sRows
}

func (d DIVI) LiveWallet() string {
	return "" + balanceTxt() + "\n" +
		"  " + balanceInCurrency() + "\n" +
		"  " + walletSecurityStatusTxt() + "\n" +
		"  " + walletStaking() + "\n" +
		"  " + activelyStakingTxt() + "\n" + //e.g. "15%" or "staking".
		"  " + nextLottery() + "\n" +
		"  " + lotteryTickets()
}

func nextLottery() string {
	return "Next Lottery:     [" + calculateNextLottery() + "](fg:white)"
}

func (d DIVI) RefreshDifficulty() {
	var divi diviImport.Divi

	diffGood, diffWarning, _ = divi.NetworkDifficultyInfo()
}

func (d DIVI) RefreshNetwork(coinAuth *models.CoinAuth) {
	var divi diviImport.Divi

	blockChainInfo, _ = divi.BlockchainInfo(coinAuth)
	currConvert.Refresh()
	info, _, _ = divi.Info(coinAuth)
	mnss, _ = divi.MNSyncStatus(coinAuth)
	stakingInfo, _ = divi.StakingStatus(coinAuth)
	walletInfo, _ = divi.WalletInfo(coinAuth)
}

func (d DIVI) RefreshPrice() {
	var divi diviImport.Divi

	ticker, _ = divi.UpdateTickerInfo()
}

func (d DIVI) RefreshTransactions(coinAuth *models.CoinAuth) {
	var divi diviImport.Divi

	transactions, _ = divi.ListTransactions(coinAuth)
}

func walletSecurityStatusTxt() string {
	if walletInfo.Result.EncryptionStatus == diviImport.CWalletESLocked {
		return "Security:         [Locked](fg:green)"
	} else if walletInfo.Result.EncryptionStatus == diviImport.CWalletESUnencrypted {
		return "Security:         [UNENCRYPTED](fg:red)"
	} else if walletInfo.Result.EncryptionStatus == diviImport.CWalletESUnlockedForStaking {
		return "Security:         [Locked and Staking](fg:green)"
	} else if walletInfo.Result.EncryptionStatus == diviImport.CWalletESUnlocked {
		return "Security:         [Unlocked](fg:yellow)"
	} else {
		return "Security:         [checking...](fg:yellow)"
	}
}

func walletStaking() string {
	var fPercent float64
	if walletInfo.Result.Balance > 10000 {
		fPercent = 100
	} else {
		fPercent = (walletInfo.Result.Balance / 10000) * 100
	}

	fPercentStr := humanize.FormatFloat("###.##", fPercent)
	if fPercent < 75 {
		return "Staking %:        [" + fPercentStr + "](fg:red)"
	} else if (fPercent >= 76) && (fPercent <= 99) {
		return "Staking %:        [" + fPercentStr + "](fg:yellow)"
	} else {
		return "Staking %:        [" + fPercentStr + "](fg:green)"
	}
}
