package nexa

import (
	"github.com/dustin/go-humanize"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/app"
	nexaImport "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/nexa"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/display"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/models"
	"strconv"
	"time"
)

type Nexa struct {
}

var blockChainInfo models.NEXABlockchainInfo
var networkInfo models.NEXANetworkInfo
var ticker models.NEXATicker
var transactions models.NEXAListTransactions
var walletInfo models.NEXAWalletInfo
var diffGood, diffWarning float64
var lastBCSyncStatus = ""

func (n Nexa) About(coinAuth *models.CoinAuth) string {
	var a app.App
	var nexa nexaImport.Nexa
	var sCoreVersion string
	info, err := nexa.WalletInfo(coinAuth)
	if err != nil {
		sCoreVersion = "Unknown"
	} else {
		sCoreVersion = strconv.Itoa(info.Result.Walletversion)
	}

	return "  [" + a.Name() + "        v" + a.Version() + "](fg:white)\n" +
		"  [" + nexa.CoinName() + " Core        " + sCoreVersion + "](fg:white)\n\n"
}

func balanceTxt() string {
	tBalance := walletInfo.Result.Balance
	tBalanceStr := humanize.FormatFloat("#,###.########", tBalance)

	// Work out balance
	if walletInfo.Result.ImmatureBalance > 0 {
		return "  Incoming......... [" + tBalanceStr + "](fg:cyan)"
	} else if walletInfo.Result.UnconfirmedBalance > 0 {
		return "  Confirming....... [" + tBalanceStr + "](fg:yellow)"
	} else {
		return "  Balance:          [" + tBalanceStr + "](fg:green)"
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

func (n Nexa) InitialBalance() string {
	return "  Balance:          [waiting for sync...](fg:yellow)\n" +
		"  Security:         [waiting for sync...](fg:yellow)\n"
}

func (n Nexa) InitialNetwork() string {
	return "  Headers:     [checking...](fg:yellow)\n" +
		"  Blocks:      [checking...](fg:yellow)\n" +
		"  Difficulty:  [checking...](fg:yellow)\n" +
		"  Blockchain:  [checking...](fg:yellow)\n" +
		"  Connections: [checking...](fg:yellow)\n"
}

func (n Nexa) LiveNetwork() string {
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

	sNumCon := strconv.Itoa(networkInfo.Result.Connections)

	if networkInfo.Result.Connections < 1 {
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

func (n Nexa) LiveTransactions() (containsZeroConfs bool, rows [][]string) {
	var sRows [][]string

	// Record whether any of the transactions have 0 conf (so that we can display the boarder as yellow).
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
		tAmountStr := humanize.FormatFloat("#,###.####", transactions.Result[i].Amount)
		sColour := display.GetCategoryColour(transactions.Result[i].Category)
		sRows = append(sRows, []string{
			" [" + tm.Format("2006-01-02 15:04"+"](fg:"+sColour+")"),
			" [" + sCat + "](fg:" + sColour + ")",
			" [" + tAmountStr + "](fg:" + sColour + ")",
			" [" + strconv.Itoa(transactions.Result[i].Confirmations) + "](fg:" + sColour + ")"})

		//if i > 10 {
		//	break
		//}
	}

	return bZeroConfs, sRows
}

func (n Nexa) LiveWallet() string {
	return "" + balanceTxt() + "\n" +
		"  " + walletSecurityStatusTxt()
}

func (n Nexa) RefreshDifficulty() {
	var nexa nexaImport.Nexa

	diffGood, diffWarning, _ = nexa.NetworkDifficultyInfo()
}

func (n Nexa) RefreshNetwork(coinAuth *models.CoinAuth) {
	var nexa nexaImport.Nexa

	blockChainInfo, _ = nexa.BlockchainInfo(coinAuth)
	networkInfo, _ = nexa.NetworkInfo(coinAuth)
	walletInfo, _ = nexa.WalletInfo(coinAuth)
}

func (n Nexa) RefreshPrice() {
	var nexa nexaImport.Nexa

	ticker, _ = nexa.UpdateTickerInfo()
}

func (n Nexa) RefreshTransactions(coinAuth *models.CoinAuth) {
	var nexa nexaImport.Nexa

	transactions, _ = nexa.ListTransactions(coinAuth)
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
