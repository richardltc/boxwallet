package zano

import (
	"fmt"
	"github.com/dustin/go-humanize"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/app"
	zanoImport "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/zano"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/display"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/models"
	"strconv"
	"time"
)

type Zano struct {
}

var info models.ZANOGetInfo
var diffGood, diffWarning float64
var lastBCSyncStatus string = ""

func (z Zano) About(coinAuth *models.CoinAuth) string {
	var a app.App
	var zano zanoImport.Zano
	var sCoreVersion string
	//info, err := zano.WalletInfo(coinAuth)
	//if err != nil {
	//	sCoreVersion = "Unknown"
	//} else {
	sCoreVersion = strconv.Itoa(info.Result.Mi.VerMajor) + "." + strconv.Itoa(info.Result.Mi.VerMinor)
	//}

	return "  [" + a.Name() + "        v" + a.Version() + "](fg:white)\n" +
		"  [" + zano.CoinName() + " Core        " + sCoreVersion + "](fg:white)\n\n"
}

//func balanceTxt() string {
//	tBalance := walletInfo.Result.Balance
//	tBalanceStr := humanize.FormatFloat("#,###.########", tBalance)
//
//	// Work out balance
//	if walletInfo.Result.ImmatureBalance > 0 {
//		return "  Incoming......... [" + tBalanceStr + "](fg:cyan)"
//	} else if walletInfo.Result.UnconfirmedBalance > 0 {
//		return "  Confirming....... [" + tBalanceStr + "](fg:yellow)"
//	} else {
//		return "  Balance:          [" + tBalanceStr + "](fg:green)"
//	}
//}

func blockchainSyncTxt() string {
	totalBlocks := info.Result.MaxNetSeenHeight
	currentBlock := info.Result.Height

	percentage := float64(currentBlock) / float64(totalBlocks) * 100
	s := fmt.Sprintf("%.2f", percentage)
	if s == "100%" {
		s = "99.99%"
	}

	//s := display.ConvertBCVerification(blockChainInfo.Result.Verificationprogress)
	if s == "0.0" {
		s = ""
	} else {
		s = s + "%"
	}

	return s
}

func (z Zano) InitialBalance() string {
	return "  Balance:          [waiting for sync...](fg:yellow)\n" +
		"  Security:         [waiting for sync...](fg:yellow)\n"
}

func (z Zano) InitialNetwork() string {
	return "  Headers:     [checking...](fg:yellow)\n" +
		"  Blocks:      [checking...](fg:yellow)\n" +
		"  Difficulty:  [checking...](fg:yellow)\n" +
		"  Blockchain:  [checking...](fg:yellow)\n" +
		"  Connections: [checking...](fg:yellow)\n"
}

func (z Zano) LiveNetwork() string {
	var bcSynced bool
	var sBlockchainSync, sConnections, sHeaders, sBlocks, sDiff, sDiffVal string

	totalBlocks := info.Result.MaxNetSeenHeight
	currentBlock := info.Result.Height

	if currentBlock >= totalBlocks {
		bcSynced = true
	}

	// bci, _ := xBC.BlockchainInfo(coinAuth)

	//headersStr := humanize.Comma(int64(blockChainInfo.Result.Headers))
	//if blockChainInfo.Result.Headers > 1 {
	//	sHeaders = "Headers:     [" + headersStr + "](fg:green)"
	//} else {
	//	sHeaders = "[Headers:     " + headersStr + "](fg:red)"
	//}

	blocksStr := humanize.Comma(int64(info.Result.Height))
	if blocksStr == "0" {
		sBlocks = "Blocks:      [waiting...](fg:white)"
	} else {
		sBlocks = "Blocks:      [" + blocksStr + "](fg:green)"
	}

	//if info.Result.PowDifficulty > 1000 {
	//	sDiffVal = humanize.FormatFloat("#.#", info.Result.PowDifficulty/1000) + "k"
	//} else {
	//	sDiffVal = humanize.Ftoa(blockChainInfo.Result.Difficulty)
	//}
	//
	//if blockChainInfo.Result.Difficulty >= diffGood {
	//	sDiff = "Difficulty:  [" + sDiffVal + "](fg:green)"
	//} else if blockChainInfo.Result.Difficulty >= diffWarning {
	//	sDiff = "Difficulty:  [" + sDiffVal + "](fg:yellow)"
	//} else {
	//	sDiff = "Difficulty:  [" + sDiffVal + "](fg:red)"
	//}

	s := blockchainSyncTxt()

	if !bcSynced {
		nextBCSyncIndicator := display.NextProgBCIndicator(lastBCSyncStatus)
		sBlockchainSync = "Blockchain: [" + display.NextProgBCIndicator(nextBCSyncIndicator) + "syncing " + s + " ](fg:yellow)"
		lastBCSyncStatus = nextBCSyncIndicator
	} else {
		sBlockchainSync = "Blockchain:  [synced " + display.CUTFTickBold + "](fg:green)"
	}

	//sNumCon := strconv.Itoa(info.Result.Connections)
	//
	//if networkInfo.Result.Connections < 1 {
	//	sConnections = "Connections: [" + sNumCon + "](fg:yellow)\n"
	//} else {
	//	sConnections = "Connections: [" + sNumCon + "](fg:green)\n"
	//}

	return "  " + sHeaders + "\n" +
		"  " + sBlocks + "\n" +
		"  " + sDiff + "\n" +
		"  " + sBlockchainSync + "\n" +
		"  " + sConnections
}

func (z Zano) LiveTransactions() (containsZeroConfs bool, rows [][]string) {
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

func (z Zano) LiveWallet() string {
	return "" + balanceTxt() + "\n" +
		"  " + walletSecurityStatusTxt()
}

func (z Zano) RefreshDifficulty() {
	var zano zanoImport.Zano

	diffGood, diffWarning, _ = zano.NetworkDifficultyInfo()
}

func (z Zano) RefreshNetwork(coinAuth *models.CoinAuth) {
	var zano zanoImport.Zano

	info, _ = zano.BlockchainInfo(coinAuth)
	networkInfo, _ = zano.NetworkInfo(coinAuth)
	walletInfo, _ = zano.WalletInfo(coinAuth)
}

func (z Zano) RefreshPrice() {
	var zano zanoImport.Zano

	ticker, _ = zano.UpdateTickerInfo()
}

func (z Zano) RefreshTransactions(coinAuth *models.CoinAuth) {
	var zano zanoImport.Zano

	transactions, _ = zano.ListTransactions(coinAuth)
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
