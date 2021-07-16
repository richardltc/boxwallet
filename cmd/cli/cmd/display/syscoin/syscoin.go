package syscoin

import (
	"github.com/dustin/go-humanize"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/app"
	divi "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/divi"
	sysImport "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/syscoin"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/currencyconvert"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/display"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/models"
	"strconv"
	"time"
)

type Syscoin struct {
}

var blockChainInfo models.SYSBlockchainInfo

//var ticker models.DiviTicker
var transactions models.DiviListTransactions
var walletInfo models.DiviWalletInfo
var diffGood, diffWarning float64
var lastBCSyncStatus = ""

var localCurrency string
var currConvert currencyconvert.CurrencyConvert

func (s Syscoin) Bootstrap(lcurrency string) {
	localCurrency = lcurrency
}

func (s Syscoin) About(coinAuth *models.CoinAuth) string {
	var a app.App
	var sys sysImport.Syscoin
	var sCoreVersion string
	info, err := sys.WalletInfo(coinAuth)
	if err != nil {
		sCoreVersion = "Unknown"
	} else {
		sCoreVersion = info.Result.Walletversion
	}

	return "  [" + a.Name() + "    v" + a.Version() + "](fg:white)\n" +
		"  [" + divi.CoinName() + " Core    v" + sCoreVersion + "](fg:white)\n\n"
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
	s := display.ConvertBCVerification(blockChainInfo.Result.Verificationprogress)
	if s == "0.0" {
		s = ""
	} else {
		s = s + "%"
	}
	return s
}

func getNextLotteryTxtDIVI() string {
	if nextLotteryCounter > (60*30) || nextLotteryStored == "" {
		nextLotteryCounter = 0
		//lrs, _ := getDiviLotteryInfo(conf)
		if lottery.Lottery.Countdown.Humanized != "" {
			return "Next Lottery:     [" + lottery.Lottery.Countdown.Humanized + "](fg:white)"
		} else {
			return "Next Lottery:     [" + nextLotteryStored + "](fg:white)"
		}
	} else {
		return "Next Lottery:     [" + nextLotteryStored + "](fg:white)"
	}
}

func lotteryTickets() string {
	iTotalTickets := 0

	for i := len(transactions.Result) - 1; i >= 0; i-- {
		// If this transaction is not a stake, we're not interested in it.
		if transactions.Result[i].Category != "stake_reward" {
			continue
		}

		// Check to make sure the confirmations count is higher than -1
		if transactions.Result[i].Confirmations < 0 {
			continue
		}

		prevBlock := lottery.Lottery.NextLotteryBlock - 10080
		numBlocksSpread := lottery.Lottery.CurrentBlock - prevBlock

		// If the stake block is less than the next lottery block - 10080 then it's not in this weeks lottery
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
		"  Masternodes: [checking...](fg:yellow)" +
		"  Connections:  [checking...](fg:yellow)\n"
}

func (d DIVI) LiveNetwork() string {
	var bcSynced bool
	var sBlockchainSync, sConnections, sHeaders, sBlocks, sDiff, sDiffVal string

	if blockChainInfo.Result.Verificationprogress > 0.99999 {
		bcSynced = true
	}

	// bci, _ := xBC.BlockchainInfo(coinAuth)

	headersStr := humanize.Comma(int64(blockChainInfo.Result.Headers))
	if blockChainInfo.Result.Headers > 1 {
		sHeaders = "Headers:     [" + headersStr + "](fg:green)"
	} else {
		sHeaders = "[Headers:     " + headersStr + "](fg:red)"
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

	s := blockchainSyncTxt()

	if !bcSynced {
		nextBCSyncIndicator := display.NextProgBCIndicator(lastBCSyncStatus)
		sBlockchainSync = "Blockchain: [" + display.NextProgBCIndicator(nextBCSyncIndicator) + "syncing " + s + " ](fg:yellow)"
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

	return "  " + sHeaders + "\n" +
		"  " + sBlocks + "\n" +
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
		sColour := display.GetCategoryColour(transactions.Result[i].Category)
		sRows = append(sRows, []string{
			" [" + tm.Format("2006-01-02 15:04"+"](fg:"+sColour+")"),
			" [" + sCat + "](fg:" + sColour + ")",
			" [" + tAmountStr + "](fg:" + sColour + ")",
			" [" + strconv.Itoa(transactions.Result[i].Confirmations) + "](fg:" + sColour + ")"})

		if i > 10 {
			break
		}
	}

	return bZeroConfs, sRows
}

func (d DIVI) LiveWallet() string {
	//return "  Balance:          [waiting for sync...](fg:yellow)\n" +
	//	"  Currency:         [waiting for sync...](fg:yellow)\n" +
	//	"  Security:         [waiting for sync...](fg:yellow)\n" +
	//	"  Staking %:	        [waiting for sync...](fg:yellow)\n" +
	//	"  Actively Staking: [waiting for sync...](fg:yellow)\n" +
	//	"  Next Lottery:     [waiting for sync...](fg:yellow)\n" +
	//	"  Lottery tickets:	  [waiting for sync...](fg:yellow)"

	return "" + balanceTxt() + "\n" +
		"  " + balanceInCurrency() + "\n" +
		"  " + walletSecurityStatusTxt() + "\n" +
		"  " + walletStaking() + "\n" +
		"  " + activelyStakingTxt() + "\n" + //e.g. "15%" or "staking".
		"  " + nextLottery() + "\n" +
		"  " + lotteryTickets()
}

func nextLottery() string {
	if nextLotteryCounter > (60*30) || nextLotteryStored == "" {
		nextLotteryCounter = 0
		//lrs, _ := getDiviLotteryInfo(conf)
		if lottery.Lottery.Countdown.Humanized != "" {
			return "Next Lottery:     [" + lottery.Lottery.Countdown.Humanized + "](fg:white)"
		} else {
			return "Next Lottery:     [" + nextLotteryStored + "](fg:white)"
		}
	} else {
		return "Next Lottery:     [" + nextLotteryStored + "](fg:white)"
	}
}

func (d DIVI) RefreshDifficulty() {
	var divi diviImport.Divi

	diffGood, diffWarning, _ = divi.NetworkDifficultyInfo()
}

func (d DIVI) RefreshNetwork(coinAuth *models.CoinAuth) {
	var divi diviImport.Divi

	blockChainInfo, _ = divi.BlockchainInfo(coinAuth)
	currConvert.Refresh()
	//networkInfo, _ = xbc.NetworkInfo(coinAuth)
	info, _, _ = divi.Info(coinAuth)
	lottery, _ = divi.LotteryInfo()
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
