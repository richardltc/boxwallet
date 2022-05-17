package doegecash

import (
	"github.com/dustin/go-humanize"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/app"
	dogecashImport "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/dogecash"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/currencyconvert"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/display"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/models"
	"strconv"
	"time"
)

type DOGEC struct {
}

var blockChainInfo models.DOGECBlockchainInfo
var info models.DOGECGetInfo
var mnSyncStatus models.DOGECMNSyncStatus
var stakingInfo models.DOGECStakingStatus
var ticker models.DOGECTicker
var transactions models.DOGECListTransactions
var walletInfo models.DOGECWalletInfo
var diffGood, diffWarning float64
var lastBCSyncStatus = ""
var lastMNSyncStatus = ""

var localCurrency string
var currConvert currencyconvert.CurrencyConvert

func (d DOGEC) Bootstrap(lcurrency string) {
	localCurrency = lcurrency
}

func (d DOGEC) About(coinAuth *models.CoinAuth) string {
	var a app.App
	var dogec dogecashImport.DogeCash
	var sCoreVersion string
	info, _, err := dogec.Info(coinAuth)
	if err != nil {
		sCoreVersion = "Unknown"
	} else {
		sCoreVersion = strconv.Itoa(info.Result.Version)
	}

	return "  [" + a.Name() + "     v" + a.Version() + "](fg:white)\n" +
		"  [" + dogec.CoinName() + " Core v" + sCoreVersion + "](fg:white)\n\n"
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
		pricePerCoin = currConvert.Convert(ticker.DOGEC.Quote.USD.Price) //ticker.DIVI.Quote.USD.Price * pricePerCoinAUD.Rates.AUD
	case "USD":
		symbol = "$"
		pricePerCoin = ticker.DOGEC.Quote.USD.Price
	case "GBP":
		symbol = "£"
		pricePerCoin = currConvert.Convert(ticker.DOGEC.Quote.USD.Price) //ticker.DIVI.Quote.USD.Price * pricePerCoinGBP.Rates.GBP
	default:
		symbol = "$"
		pricePerCoin = ticker.DOGEC.Quote.USD.Price
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

func (d DOGEC) InitialBalance() string {
	return "  Balance:          [waiting for sync...](fg:yellow)\n" +
		"  Currency:         [waiting for sync...](fg:yellow)\n" +
		"  Security:         [waiting for sync...](fg:yellow)\n" +
		"  Actively Staking: [waiting for sync...](fg:yellow)\n"
}

func (d DOGEC) InitialNetwork() string {
	return "  Blocks:      [checking...](fg:yellow)\n" +
		"  Difficulty:  [checking...](fg:yellow)\n" +
		"  Blockchain:  [checking...](fg:yellow)\n" +
		"  Masternodes: [checking...](fg:yellow)" +
		"  Connections:  [checking...](fg:yellow)\n"
}

func (d DOGEC) LiveNetwork() string {
	var bcSynced bool
	var mnSynced bool
	var sBlockchainSync, sMNSync, sConnections, sBlocks, sDiff, sDiffVal string

	if blockChainInfo.Result.Verificationprogress > 0.99999 {
		bcSynced = true
	}

	if mnSyncStatus.Result.RequestedMasternodeAssets == 999 { // stakingInfo.Result.Mnsync {
		mnSynced = true
	}

	// bci, _ := xBC.BlockchainInfo(coinAuth)

	//headersStr := humanize.Comma(int64(blockChainInfo.Result.Headers))
	//if blockChainInfo.Result.Headers > 1 {
	//	sHeaders = "Headers:     [" + headersStr + "](fg:green)"
	//} else {
	//	sHeaders = "[Headers:     " + headersStr + "](fg:red)"
	//}

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

	sDiff = "Difficulty:  [" + sDiffVal + "](fg:green)"

	sBC := blockchainSyncTxt()

	if !bcSynced {
		nextBCSyncIndicator := display.NextProgBCIndicator(lastBCSyncStatus)
		sBlockchainSync = "Blockchain: [" + display.NextProgBCIndicator(nextBCSyncIndicator) + "syncing " + sBC + " ](fg:yellow)"
		lastBCSyncStatus = nextBCSyncIndicator
	} else {
		sBlockchainSync = "Blockchain:  [synced " + display.CUTFTickBold + "](fg:green)"
	}

	if !mnSynced {
		nextMNSyncIndicator := display.NextProgBCIndicator(lastMNSyncStatus)
		sMNSync = "Masternodes:[" + display.NextProgMNIndicator(nextMNSyncIndicator) + "syncing ](fg:yellow)"
		lastMNSyncStatus = nextMNSyncIndicator
	} else {
		sMNSync = "Masternodes: [synced " + display.CUTFTickBold + "](fg:green)"
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
		"  " + sMNSync + "\n" +
		"  " + sConnections
}

func (d DOGEC) LiveTransactions() (containsZeroConfs bool, rows [][]string) {
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

		if i > 25 {
			break
		}
	}

	return bZeroConfs, sRows
}

func (d DOGEC) LiveWallet() string {
	return "" + balanceTxt() + "\n" +
		"  " + balanceInCurrency() + "\n" +
		"  " + walletSecurityStatusTxt() + "\n" +
		"  " + activelyStakingTxt()
}

func mnSyncTxt(mns bool) string {
	if stakingInfo.Result.Mnsync == true {
		return "[synced " + display.CUTFTickBold + "](fg:green)"
	} else {
		if mns {
			return "[" + display.NextProgBCIndicator(lastMNSyncStatus) + "syncing...](fg:yellow)"
		} else {
			return "[waiting...](fg:yellow)"
		}
	}
}

// RefreshDifficulty - DogeC is not currently supported.
func (d DOGEC) RefreshDifficulty() {
	//var dogec dogecashImport.DogeCash
	//
	//diffGood, diffWarning, _ = dogec.NetworkDifficultyInfo()
}

func (d DOGEC) RefreshNetwork(coinAuth *models.CoinAuth) {
	var dogec dogecashImport.DogeCash

	blockChainInfo, _ = dogec.BlockchainInfo(coinAuth)
	currConvert.Refresh()
	//networkInfo, _ = xbc.NetworkInfo(coinAuth)
	info, _, _ = dogec.Info(coinAuth)
	mnSyncStatus, _ = dogec.MNSyncStatus(coinAuth)
	stakingInfo, _ = dogec.StakingStatus()
	walletInfo, _ = dogec.WalletInfo(coinAuth)
}

func (d DOGEC) RefreshPrice() {
	var dogec dogecashImport.DogeCash

	ticker, _ = dogec.UpdateTickerInfo()
}

func (d DOGEC) RefreshTransactions(coinAuth *models.CoinAuth) {
	var dogec dogecashImport.DogeCash

	transactions, _ = dogec.ListTransactions(coinAuth)
}

func walletSecurityStatusTxt() string {
	if walletInfo.Result.UnlockedUntil == 0 {
		return "Security:         [Locked](fg:green)"
	} else if walletInfo.Result.UnlockedUntil == -1 {
		return "Security:         [UNENCRYPTED](fg:red)"
	} else if walletInfo.Result.UnlockedUntil > 0 {
		return "Security:         [Locked and Staking](fg:green)"
	} else {
		return "Security:         [checking...](fg:yellow)"
	}
}
