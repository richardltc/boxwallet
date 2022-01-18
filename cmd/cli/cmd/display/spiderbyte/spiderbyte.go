package spiderbyte

import (
	"fmt"
	"github.com/dustin/go-humanize"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/app"

	sbyteImport "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/spiderbyte"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/display"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/models"
	"strconv"
	"time"
)

type SBYTE struct {
}

var bcIsSynced bool
var info models.SBYTEInfo

//var networkInfo models.XBCNetworkInfo
//var stakingInfo models.XBCStakingInfo
//var ticker models.XBCTicker
var transactions models.SBYTEListTransactions

//var walletInfo models.XBCWalletInfo
var diffGood, diffWarning float64
var lastBCSyncStatus string = ""
var latestBlock int

func (s SBYTE) About(coinAuth *models.CoinAuth) string {
	var a app.App
	var sbyte sbyteImport.SpiderByte
	var sCoreVersion string
	info, _, err := sbyte.Info(coinAuth)
	if err != nil {
		sCoreVersion = "Unknown"
	} else {
		sCoreVersion = info.Result.Version
	}

	return "  [" + a.Name() + "        v" + a.Version() + "](fg:white)\n" +
		"  [" + sbyte.CoinName() + " Core  " + sCoreVersion + "](fg:white)\n\n"
}

//func activelyStakingTxt() string {
//	if stakingInfo.Result.Staking {
//		return "Actively Staking: [Yes](fg:green)"
//	} else {
//		return "Actively Staking: [No](fg:yellow)"
//	}
//}

func balanceTxt() string {
	tBalance := info.Result.Balance
	tBalanceStr := humanize.FormatFloat("#,###.########", tBalance)

	// Work out balance
	return "  Balance:          [" + tBalanceStr + "](fg:green)"
}

func blockchainSyncTxt() string {
	s := percentageBCSynced(info.Result.Blocks, latestBlock)
	if s == "0.0" {
		s = ""
	} else {
		s = s + "%"
	}

	return s
}

func (s SBYTE) InitialBalance() string {
	return "  Balance:          [waiting for sync...](fg:yellow)\n" +
		"  Security:         [waiting for sync...](fg:yellow)\n" +
		"  Actively Staking: [waiting for sync...](fg:yellow)\n"
}

func (s SBYTE) InitialNetwork() string {
	return "  Blocks:      [checking...](fg:yellow)\n" +
		"  Difficulty:  [checking...](fg:yellow)\n" +
		"  Blockchain:  [checking...](fg:yellow)\n" +
		"  Connections: [checking...](fg:yellow)\n"
}

func (s SBYTE) LiveNetwork() string {
	//var bcSynced bool
	var sBlockchainSync, sConnections, sBlocks, sDiff, sDiffVal string

	blocksStr := humanize.Comma(int64(info.Result.Blocks))
	if blocksStr == "0" {
		sBlocks = "Blocks:      [waiting...](fg:white)"
	} else {
		sBlocks = "Blocks:      [" + blocksStr + "](fg:green)"
	}

	if info.Result.Difficulty > 1000 {
		sDiffVal = humanize.FormatFloat("#.#", info.Result.Difficulty/1000) + "k"
	} else {
		sDiffVal = humanize.Ftoa(info.Result.Difficulty)
	}

	if info.Result.Difficulty >= diffGood {
		sDiff = "Difficulty:  [" + sDiffVal + "](fg:green)"
	} else if info.Result.Difficulty >= diffWarning {
		sDiff = "Difficulty:  [" + sDiffVal + "](fg:yellow)"
	} else {
		sDiff = "Difficulty:  [" + sDiffVal + "](fg:red)"
	}

	bst := blockchainSyncTxt()

	if !bcIsSynced {
		nextBCSyncIndicator := display.NextProgBCIndicator(lastBCSyncStatus)
		sBlockchainSync = "Blockchain: [" + display.NextProgBCIndicator(nextBCSyncIndicator) + "syncing " + bst + " ](fg:yellow)"
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

func (s SBYTE) LiveTransactions() (containsZeroConfs bool, rows [][]string) {
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

func (s SBYTE) LiveWallet() string {
	return "" + balanceTxt() + "\n" +
		"  " + walletSecurityStatusTxt() // + "\n" +
	// "  " + activelyStakingTxt() + "\n"

}

func (s SBYTE) RefreshDifficulty() {
	var sbyte sbyteImport.SpiderByte

	diffGood, diffWarning, _ = sbyte.NetworkDifficultyInfo()
}

func (s SBYTE) RefreshNetwork(coinAuth *models.CoinAuth) {
	var sbyte sbyteImport.SpiderByte

	bcIsSynced, _ = sbyte.BlockchainIsSynced(coinAuth)
	info, _, _ = sbyte.Info(coinAuth)
	latestBlock, _ = sbyte.BlockCount()
	//blockChainInfo, _ = xbc.BlockchainInfo(coinAuth)
	//networkInfo, _ = xbc.NetworkInfo(coinAuth)
	//stakingInfo, _ = xbc.StakingInfo(coinAuth)
	//walletInfo, _ = xbc.WalletInfo(coinAuth)
}

func (s SBYTE) RefreshPrice() {
	//var sbyte sbyteImport.SpiderByte
	//
	//ticker, _ = sbyte.UpdateTickerInfo()
}

func (s SBYTE) RefreshTransactions(coinAuth *models.CoinAuth) {
	var sbyte sbyteImport.SpiderByte

	transactions, _ = sbyte.ListTransactions(coinAuth)
}

func walletSecurityStatusTxt() string {
	//if walletInfo.Result.UnlockedUntil == 0 {
	//	return "Security:         [Locked](fg:green)"
	//} else if walletInfo.Result.UnlockedUntil == -1 {
	//	return "Security:         [UNENCRYPTED](fg:red)"
	//} else if walletInfo.Result.UnlockedUntil > 0 {
	//	return "Security:         [Locked and Staking](fg:green)"
	//} else {
	//	return "Security:         [checking...](fg:yellow)"
	//}

	return "Security:         [Unknown...](fg:yellow)"
}

func percentageBCSynced(currentBlock, latestBlock int) string {
	var sProg string
	fProg := (float64(currentBlock) * float64(100)) / float64(latestBlock)
	//fProg = verificationPG * 100
	sProg = fmt.Sprintf("%.2f", fProg)
	if sProg == "100%" {
		sProg = "99.99%"
	}

	return sProg
}
