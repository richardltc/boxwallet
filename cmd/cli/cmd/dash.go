/*
Package cmd ...
Copyright © 2020 Richard Mace <richard@rocksoftware.co.uk>

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/
package cmd

import (
	"errors"
	"fmt"
	"time"

	ui "github.com/gizak/termui/v3"
	"github.com/gizak/termui/v3/widgets"
	"github.com/gookit/color"
	"github.com/theckman/yacspin"
	xbc "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/bitcoinplus"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/wallet"

	"richardmace.co.uk/boxwallet/cmd/cli/cmd/display"

	"github.com/spf13/cobra"

	"log"
	"os"

	_ "github.com/AlecAivazis/survey/v2"
	// be "richardmace.co.uk/boxwallet/cmd/cli/ccoinsbend"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/app"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/coins"
	divi "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/divi"
	rpd "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/rapids"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/conf"
	xbcDisplay "richardmace.co.uk/boxwallet/cmd/cli/cmd/display/bitcoinplus"
	diviDisplay "richardmace.co.uk/boxwallet/cmd/cli/cmd/display/divi"
	rpdDisplay "richardmace.co.uk/boxwallet/cmd/cli/cmd/display/rapids"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/models"
	// "richardmace.co.uk/boxwallet/cmd/cli/cmd/wallet"
	// //m "richardmace.co.uk/boxwallet/pkg/models"
	// "github.com/gookit/color"
)

const (
	cStakeReceived   string = "\u2618"
	cPaymentReceived string = "<--" //"\u2770"
	cPaymentSent     string = "-->" //"\u2771"

	cProg1 string = "|"
	cProg2 string = "/"
	cProg3 string = "-"
	cProg4 string = "\\"
	cProg5 string = "|"
	cProg6 string = "/"
	cProg7 string = "-"
	cProg8 string = "\\"

	cUtfTickBold string = "\u2714"
)

type hdinfoRespStruct struct {
	Result struct {
		Hdseed             string `json:"hdseed"`
		Mnemonic           string `json:"mnemonic"`
		Mnemonicpassphrase string `json:"mnemonicpassphrase"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

var gDenariusBlockHeight int = 0
var gGetBCInfoCount int = 0

var gBCSyncStuckCount int = 0
var gWalletRICount int = 0

var gFreshBCSyncData bool = false
var gLastBCSyncPosD int = 0
var gLastBCSyncPos float64 = 0
var gLastBCSyncPosStr string = ""
var gLastBCSyncStatus string = ""

var gLastMNSyncStatus string = ""

var gDiffGood float64
var gDiffWarning float64

// General counters
var g10SecTickerCounter int = 0
var g30SecTickerCounter int = 0
var gCheckWalletHealthCounter int = 0

// var gDiviLottery be.DiviLotteryRespStruct
var NextLotteryStored string = ""
var NextLotteryCounter int = 0

// Network globals.
var gConnections int = 0

// dashCmd represents the dash command
var dashCmd = &cobra.Command{
	Use:   "dash",
	Short: "Display CLI a dashboard for your chosen coin's wallet",
	Long: `Displays the following info in CLI form:
	
	* Wallet balance
	* Blockchain sync progress
	* Masternode sync progress
	* Wallet encryption status
	* Balance info`,
	Run: func(cmd *cobra.Command, args []string) {
		var app app.App
		fmt.Println("  ____          __          __   _ _      _   \n |  _ \\         \\ \\        / /  | | |    | |  \n | |_) | _____  _\\ \\  /\\  / /_ _| | | ___| |_ \n |  _ < / _ \\ \\/ /\\ \\/  \\/ / _` | | |/ _ \\ __|\n | |_) | (_) >  <  \\  /\\  / (_| | | |  __/ |_ \n |____/ \\___/_/\\_\\  \\/  \\/ \\__,_|_|_|\\___|\\__| v" + app.Version() + "\n                                              \n                                               ")

		var conf conf.Conf
		var coin coins.Coin
		var coinBlockchainIsSynced coins.CoinBlockchainIsSynced
		var coinDaemon coins.CoinDaemon
		var coinDispAbout display.About
		var coinDispInitialBalance display.InitialBalance
		var coinDispInitialNetwork display.InitialNetwork
		var coinDispLiveTransactions display.LiveTransactions
		var coinDispLiveNetwork display.LiveNetwork
		var coinDispLiveWallet display.LiveWallet
		var coinAuth models.CoinAuth
		//var coinAnyAddresses coins.CoinAnyAddresses
		var coinName coins.CoinName
		var coinPrice coins.CoinPrice
		var coinWallet wallet.Wallet
		var walletRefreshDifficulty display.RefreshDifficulty
		var walletRefreshNetwork display.RefreshNetwork
		var walletRefreshTransactions display.RefreshTransactions
		var walletSecurityState wallet.WalletSecurityState

		appHomeDir, err := app.HomeFolder()
		if err != nil {
			log.Fatal("Unable to get HomeFolder: " + err.Error())
		}

		conf.Bootstrap(appHomeDir)

		appFileName, err := app.FileName()
		if err != nil {
			log.Fatal("Unable to get appFilename: " + err.Error())
		}

		// Make sure the config file exists, and if not, force user to use "coin" command first..
		if _, err := os.Stat(appHomeDir + conf.ConfFile()); os.IsNotExist(err) {
			log.Fatal("Unable to determine coin type. Please run " + appFileName + " coin  first")
		}

		// Now load our config file to see what coin choice the user made...
		confDB, err := conf.GetConfig(true)
		if err != nil {
			log.Fatal("Unable to determine coin type. Please run " + appFileName + " coin: " + err.Error())
		}

		coinAuth.IPAddress = confDB.ServerIP
		coinAuth.RPCUser = confDB.RPCuser
		coinAuth.RPCPassword = confDB.RPCpassword
		coinAuth.Port = confDB.Port

		switch confDB.ProjectType {
		case models.PTBitcoinPlus:
			coin = xbc.XBC{}
			coinBlockchainIsSynced = xbc.XBC{}
			coinDaemon = xbc.XBC{}
			coinDispAbout = xbcDisplay.XBC{}
			coinDispInitialBalance = xbcDisplay.XBC{}
			coinDispInitialNetwork = xbcDisplay.XBC{}
			coinDispLiveNetwork = xbcDisplay.XBC{}
			coinDispLiveTransactions = xbcDisplay.XBC{}
			coinDispLiveWallet = xbcDisplay.XBC{}
			//coinAnyAddresses = xbc.XBC{}
			coinName = xbc.XBC{}
			coinWallet = xbc.XBC{}
			walletRefreshDifficulty = xbcDisplay.XBC{}
			walletRefreshNetwork = xbcDisplay.XBC{}
			walletRefreshTransactions = xbcDisplay.XBC{}
			walletSecurityState = xbc.XBC{}
		case models.PTDivi:
			coin = divi.Divi{}
			coinBlockchainIsSynced = divi.Divi{}
			coinDaemon = divi.Divi{}
			coinDispAbout = diviDisplay.DIVI{}
			coinDispInitialBalance = diviDisplay.DIVI{}
			coinDispInitialNetwork = diviDisplay.DIVI{}
			coinDispLiveNetwork = diviDisplay.DIVI{}
			coinDispLiveTransactions = diviDisplay.DIVI{}
			coinDispLiveWallet = diviDisplay.DIVI{}
			coinName = divi.Divi{}
			coinPrice = diviDisplay.DIVI{}
			coinWallet = divi.Divi{}
			walletRefreshDifficulty = diviDisplay.DIVI{}
			walletRefreshNetwork = diviDisplay.DIVI{}
			walletRefreshTransactions = diviDisplay.DIVI{}
			walletSecurityState = divi.Divi{}
		case models.PTRapids:
			coin = rpd.Rapids{}
			coinBlockchainIsSynced = rpd.Rapids{}
			coinDaemon = rpd.Rapids{}
			coinDispAbout = rpdDisplay.RPD{}
			coinDispInitialBalance = rpdDisplay.RPD{}
			coinDispInitialNetwork = rpdDisplay.RPD{}
			coinDispLiveNetwork = rpdDisplay.RPD{}
			coinDispLiveTransactions = rpdDisplay.RPD{}
			coinDispLiveWallet = rpdDisplay.RPD{}
			//coinAnyAddresses = xbc.XBC{}
			coinName = rpd.Rapids{}
			coinWallet = rpd.Rapids{}
			walletRefreshDifficulty = rpdDisplay.RPD{}
			walletRefreshNetwork = rpdDisplay.RPD{}
			walletRefreshTransactions = rpdDisplay.RPD{}
			walletSecurityState = rpd.Rapids{}

		default:
			log.Fatal("Unable to determine ProjectType")
		}

		// sCoinName := coinName.CoinName()
		sCoinDaemon := coinDaemon.DaemonFilename()

		// Check to see if we are running the coin daemon locally, and if we are, make sure it's actually running
		// before attempting to connect to it.
		if confDB.ServerIP == "127.0.0.1" {
			bCDRunning, err := coinDaemon.DaemonRunning()
			if err != nil {
				log.Fatal("Unable to determine if coin daemon is running: " + err.Error())
			}
			if !bCDRunning {
				log.Fatal("Unable to communicate with the " + sCoinDaemon + " server. Please make sure the " + sCoinDaemon + " server is running, by running:\n\n" +
					"./" + appFileName + " start\n\n")
			}
		}

		wRunning, err := confirmWalletReady(&coinAuth, coinName.CoinName(), coinWallet)
		if err != nil {
			log.Fatalf("\nUnable to determine if wallet is ready: %v,%v", err)
		}

		if !wRunning {
			fmt.Println("")
			log.Fatal("Unable to communicate with the " + sCoinDaemon + " server. Please make sure the " +
				sCoinDaemon + " server is running, by running:\n\n" +
				"./" + appFileName + " start\n\n")
		}

		// Let's display the tip message so the user sees it when they exit the dash command.
		sTipInfo := coinName.CoinNameAbbrev() + ": " + coin.TipAddress()
		fmt.Println("\n\n" + sTipInfo + "\n")

		// // The first thing we need to do is to store the coin core version for the About display...
		// sCoreVersion := ""
		// switch cliConf.ProjectType {
		// case be.PTDenarius:
		// 	gi, err := be.GetInfoDenarius(&cliConf)
		// 	if err != nil {
		// 		sCoreVersion = "Unknown"
		// 	} else {
		// 		sCoreVersion = gi.Result.Version
		// 	}
		// case be.PTDeVault:
		// 	gi, err := be.GetInfoDVT(&cliConf)
		// 	if err != nil {
		// 		sCoreVersion = "Unknown"
		// 	} else {
		// 		sCoreVersion = strconv.Itoa(gi.Result.Version)
		// 	}
		// case be.PTDigiByte:
		// 	gi, err := be.GetWalletInfoDGB(&cliConf)
		// 	if err != nil {
		// 		sCoreVersion = "Unknown"
		// 	} else {
		// 		sCoreVersion = strconv.Itoa(gi.Result.Walletversion)
		// 	}
		// case be.PTFeathercoin:
		// 	gi, err := be.GetNetworkInfoFeathercoin(&cliConf)
		// 	if err != nil {
		// 		sCoreVersion = "Unknown"
		// 	} else {
		// 		sCoreVersion = strconv.Itoa(gi.Result.Version)
		// 	}
		// case be.PTGroestlcoin:
		// 	gi, err := be.GetNetworkInfoGRS(&cliConf)
		// 	if err != nil {
		// 		sCoreVersion = "Unknown"
		// 	} else {
		// 		sCoreVersion = strconv.Itoa(gi.Result.Version)
		// 	}
		// case be.PTPhore:
		// 	gi, err := be.GetInfoPhore(&cliConf)
		// 	if err != nil {
		// 		sCoreVersion = "Unknown"
		// 	} else {
		// 		sCoreVersion = strconv.Itoa(gi.Result.Version)
		// 	}
		// case be.PTPIVX:
		// 	gi, _, err := be.GetInfoPIVX(&cliConf)
		// 	if err != nil {
		// 		sCoreVersion = "Unknown"
		// 	} else {
		// 		sCoreVersion = strconv.Itoa(gi.Result.Version)
		// 	}
		// case be.PTReddCoin:
		// 	gi, err := be.GetNetworkInfoRDD(&cliConf)
		// 	if err != nil {
		// 		sCoreVersion = "Unknown"
		// 	} else {
		// 		sCoreVersion = strconv.Itoa(gi.Result.Version)
		// 	}
		// case be.PTTrezarcoin:
		// 	gi, err := be.GetInfoTrezarcoin(&cliConf)
		// 	if err != nil {
		// 		sCoreVersion = "Unknown"
		// 	} else {
		// 		sCoreVersion = strconv.Itoa(gi.Result.Version)
		// 	}
		// case be.PTVertcoin:
		// 	gi, err := be.GetNetworkInfoVTC(&cliConf)
		// 	if err != nil {
		// 		sCoreVersion = "Unknown"
		// 	} else {
		// 		sCoreVersion = strconv.Itoa(gi.Result.Version)
		// 	}
		// default:
		// 	log.Fatal("unable to determine project type")
		// }

		// anyAddresses := false
		// anyAddresses, err = coinAnyAddresses.AnyAddresses(&coinAuth)
		// if err != nil {
		// 	log.Fatalf("\nUnable to determine if wallet has any addresses: %v", err)
		// }

		// pw := ""
		// if !cliConf.UserConfirmedWalletBU && bWalletExists {
		// 	// We need to work out what coin we are, to see what options we have.
		// 	switch cliConf.ProjectType {
		// 	case be.PTBitcoinPlus:
		// 	case be.PTDenarius:
		// 		wet, err := be.GetWalletEncryptionStatus()
		// 		if err != nil {
		// 			log.Fatalf("Unable to determine wallet encryption status")
		// 		}
		// 		if wet == be.WETLocked {
		// 			pw = be.GetWalletEncryptionPassword()
		// 		}
		// 	case be.PTDeVault:
		// 		wet, err := be.GetWalletEncryptionStatus()
		// 		if err != nil {
		// 			log.Fatalf("Unable to determine wallet encryption status")
		// 		}
		// 		if wet == be.WETLocked {
		// 			pw = be.GetWalletEncryptionPassword()
		// 		}
		// 		bConfirmedBU, err := HandleWalletBUDVT(pw)
		// 		cliConf.UserConfirmedWalletBU = bConfirmedBU
		// 		if err := be.SetConfigStruct("", cliConf); err != nil {
		// 			log.Fatalf("Unable to SetCLIConfStruct(): failed with %s\n", err)
		// 		}
		// 	case be.PTDigiByte:
		// 		wet, err := be.GetWalletEncryptionStatus()
		// 		if err != nil {
		// 			log.Fatalf("Unable to determine wallet encryption status")
		// 		}
		// 		if wet == be.WETLocked {
		// 			pw = be.GetWalletEncryptionPassword()
		// 		}
		// 		bConfirmedBU, err := HandleWalletBUDGB(pw)
		// 		cliConf.UserConfirmedWalletBU = bConfirmedBU
		// 		if err := be.SetConfigStruct("", cliConf); err != nil {
		// 			log.Fatalf("Unable to SetCLIConfStruct(): failed with %s\n", err)
		// 		}
		// 	case be.PTDivi:
		// 		wet, err := be.GetWalletEncryptionStatus()
		// 		if err != nil {
		// 			log.Fatalf("Unable to determine wallet encryption status")
		// 		}
		// 		if wet == be.WETLocked {
		// 			pw = be.GetWalletEncryptionPassword()
		// 		}
		// 		bConfirmedBU, err := HandleWalletBUDivi(pw)
		// 		cliConf.UserConfirmedWalletBU = bConfirmedBU
		// 		if err := be.SetConfigStruct("", cliConf); err != nil {
		// 			log.Fatalf("Unable to SetCLIConfStruct(): failed with %s\n", err)
		// 		}
		// 	case be.PTFeathercoin:
		// 	case be.PTGroestlcoin:
		// 		wet, err := be.GetWalletEncryptionStatus()
		// 		if err != nil {
		// 			log.Fatalf("Unable to determine wallet encryption status")
		// 		}
		// 		if wet == be.WETLocked {
		// 			pw = be.GetWalletEncryptionPassword()
		// 		}
		// 		bConfirmedBU, err := HandleWalletBUGRS(pw)
		// 		cliConf.UserConfirmedWalletBU = bConfirmedBU
		// 		if err := be.SetConfigStruct("", cliConf); err != nil {
		// 			log.Fatalf("Unable to SetCLIConfStruct(): failed with %s\n", err)
		// 		}
		// 	case be.PTPhore:
		// 	case be.PTPIVX:
		// 		wet, err := be.GetWalletEncryptionStatus()
		// 		if err != nil {
		// 			log.Fatalf("Unable to determine wallet encryption status")
		// 		}
		// 		if wet == be.WETLocked {
		// 			pw = be.GetWalletEncryptionPassword()
		// 		}
		// 	case be.PTReddCoin:
		// 		wet, err := be.GetWalletEncryptionStatus()
		// 		if err != nil {
		// 			log.Fatalf("Unable to determine wallet encryption status")
		// 		}
		// 		if wet == be.WETLocked {
		// 			pw = be.GetWalletEncryptionPassword()
		// 		}
		// 		bConfirmedBU, err := HandleWalletBURDD(pw)
		// 		cliConf.UserConfirmedWalletBU = bConfirmedBU
		// 		if err := be.SetConfigStruct("", cliConf); err != nil {
		// 			log.Fatalf("Unable to SetCLIConfStruct(): failed with %s\n", err)
		// 		}
		// 	case be.PTTrezarcoin:
		// 	case be.PTVertcoin:
		// 		wet, err := be.GetWalletEncryptionStatus()
		// 		if err != nil {
		// 			log.Fatalf("Unable to determine wallet encryption status")
		// 		}
		// 		if wet == be.WETLocked {
		// 			pw = be.GetWalletEncryptionPassword()
		// 		}
		// 		bConfirmedBU, err := HandleWalletBUVTC(pw)
		// 		cliConf.UserConfirmedWalletBU = bConfirmedBU
		// 		if err := be.SetConfigStruct("", cliConf); err != nil {
		// 			log.Fatalf("Unable to SetCLIConfStruct(): failed with %s\n", err)
		// 		}
		// 	default:
		// 		log.Fatalf("Unable to determine project type")
		// 	}
		// }

		// Check wallet encryption status
		bWalletNeedsEncrypting, err := coinWallet.WalletNeedsEncrypting(&coinAuth)
		if err != nil {
			log.Fatal("Unable to perform: coinWallet.WalletNeedsEncrypting" + err.Error())
		}

		// switch cliConf.ProjectType {
		// case be.PTDenarius:
		// 	gi, err := be.GetInfoDenarius(&cliConf)
		// 	if err != nil {
		// 		log.Fatal("Unable to perform GetWalletInfoDenarius " + err.Error())
		// 	}

		// 	if gi.Result.UnlockedUntil < 0 {
		// 		bWalletNeedsEncrypting = true
		// 	}
		// case be.PTDeVault:
		// 	wi, err := be.GetWalletInfoDVT(&cliConf)
		// 	if err != nil {
		// 		log.Fatal("Unable to perform GetWalletInfoDVT " + err.Error())
		// 	}

		// 	if wi.Result.UnlockedUntil < 0 {
		// 		bWalletNeedsEncrypting = true
		// 	}
		// case be.PTDigiByte:
		// 	wi, err := be.GetWalletInfoDGB(&cliConf)
		// 	if err != nil {
		// 		log.Fatal("Unable to perform GetWalletInfoDGB " + err.Error())
		// 	}

		// 	if wi.Result.UnlockedUntil < 0 {
		// 		bWalletNeedsEncrypting = true
		// 	}
		// case be.PTDivi:
		// 	wi, err := be.GetWalletInfoDivi(&cliConf)
		// 	if err != nil {
		// 		log.Fatal("Unable to perform GetWalletInfoDivi " + err.Error())
		// 	}

		// 	if wi.Result.EncryptionStatus == be.CWalletESUnencrypted {
		// 		bWalletNeedsEncrypting = true
		// 	}
		// case be.PTFeathercoin:
		// 	wi, err := be.GetWalletInfoFeathercoin(&cliConf)
		// 	if err != nil {
		// 		log.Fatal("Unable to perform GetWalletInfoFeathercoin " + err.Error())
		// 	}

		// 	if wi.Result.UnlockedUntil < 0 {
		// 		bWalletNeedsEncrypting = true
		// 	}
		// case be.PTGroestlcoin:
		// 	wi, err := be.GetWalletInfoGRS(&cliConf)
		// 	if err != nil {
		// 		log.Fatal("Unable to perform GetWalletInfoGRS " + err.Error())
		// 	}

		// 	if wi.Result.UnlockedUntil < 0 {
		// 		bWalletNeedsEncrypting = true
		// 	}
		// case be.PTPhore:
		// 	wi, err := be.GetWalletInfoPhore(&cliConf)
		// 	if err != nil {
		// 		log.Fatal("Unable to perform GetWalletInfoPhore " + err.Error())
		// 	}

		// 	if wi.Result.UnlockedUntil < 0 {
		// 		bWalletNeedsEncrypting = true
		// 	}
		// case be.PTPIVX:
		// 	wi, err := be.GetWalletInfoPIVX(&cliConf)
		// 	if err != nil {
		// 		log.Fatal("Unable to perform GetWalletInfoPIVX " + err.Error())
		// 	}

		// 	if wi.Result.UnlockedUntil < 0 {
		// 		bWalletNeedsEncrypting = true
		// 	}
		// case be.PTRapids:
		// 	wi, err := be.GetWalletInfoRapids(&cliConf)
		// 	if err != nil {
		// 		log.Fatal("Unable to perform GetWalletInfoRapids " + err.Error())
		// 	}

		// 	if wi.Result.UnlockedUntil < 0 {
		// 		bWalletNeedsEncrypting = true
		// 	}
		// case be.PTReddCoin:
		// 	wi, err := be.GetWalletInfoRDD(&cliConf)
		// 	if err != nil {
		// 		log.Fatal("Unable to perform GetWalletInfoDVT " + err.Error())
		// 	}

		// 	if wi.Result.UnlockedUntil < 0 {
		// 		bWalletNeedsEncrypting = true
		// 	}
		// case be.PTTrezarcoin:
		// 	wi, err := be.GetWalletInfoTrezarcoin(&cliConf)
		// 	if err != nil {
		// 		log.Fatal("Unable to perform GetWalletInfoTrezarcoin " + err.Error())
		// 	}

		// 	if wi.Result.UnlockedUntil < 0 {
		// 		bWalletNeedsEncrypting = true
		// 	}
		// case be.PTVertcoin:
		// 	wi, err := be.GetWalletInfoVTC(&cliConf)
		// 	if err != nil {
		// 		log.Fatal("Unable to perform GetWalletInfoVTC " + err.Error())
		// 	}

		// 	if wi.Result.UnlockedUntil < 0 {
		// 		bWalletNeedsEncrypting = true
		// 	}
		// default:
		// 	log.Fatalf("Unable to determine project type")
		// }

		// Display warning message (visible when the users stops dash) if they haven't encrypted their wallet
		if bWalletNeedsEncrypting {
			color.Danger.Println("*** WARNING: Your wallet is NOT encrypted! ***")
			fmt.Println("\nPlease encrypt it NOW with the command:\n\n" +
				"./boxwallet wallet encrypt")
		}

		// Init display....

		if err := ui.Init(); err != nil {
			log.Fatalf("failed to initialize termui: %v", err)
		}
		defer ui.Close()

		// // **************************
		// // Populate the About panel
		// // **************************

		pAbout := widgets.NewParagraph()
		pAbout.Title = "About"
		pAbout.SetRect(0, 0, 32, 4)
		pAbout.TextStyle.Fg = ui.ColorWhite
		pAbout.BorderStyle.Fg = ui.ColorGreen
		pAbout.Text = coinDispAbout.About(&coinAuth)

		// **************************
		// Populate the Wallet panel
		// **************************

		pWallet := widgets.NewParagraph()
		pWallet.Title = "Wallet"
		pWallet.SetRect(33, 0, 84, 11)
		pWallet.TextStyle.Fg = ui.ColorWhite
		pWallet.BorderStyle.Fg = ui.ColorYellow
		pWallet.Text = coinDispInitialBalance.InitialBalance()
		// switch cliConf.ProjectType {
		// case be.PTDenarius:
		// 	pWallet.Text = "  Balance:          [waiting for sync...](fg:yellow)\n" +
		// 		"  Security:         [waiting for sync...](fg:yellow)\n" +
		// 		"  Actively Staking: [waiting for sync...](fg:yellow)\n"
		// case be.PTDeVault:
		// 	pWallet.Text = "  Balance:          [waiting for sync...](fg:yellow)\n" +
		// 		"  Security:         [waiting for sync...](fg:yellow)\n"
		// case be.PTDigiByte:
		// 	pWallet.Text = "  Balance:          [waiting for sync...](fg:yellow)\n" +
		// 		"  Security:         [waiting for sync...](fg:yellow)\n"
		// case be.PTFeathercoin:
		// 	pWallet.Text = "  Balance:          [waiting for sync...](fg:yellow)\n" +
		// 		"  Security:         [waiting for sync...](fg:yellow)\n"
		// case be.PTGroestlcoin:
		// 	pWallet.Text = "  Balance:          [waiting for sync...](fg:yellow)\n" +
		// 		"  Security:         [waiting for sync...](fg:yellow)\n"
		// case be.PTPhore:
		// 	pWallet.Text = "  Balance:          [waiting for sync...](fg:yellow)\n" +
		// 		"  Security:         [waiting for sync...](fg:yellow)\n" +
		// 		"  Actively Staking: [waiting for sync...](fg:yellow)\n"
		// case be.PTPIVX:
		// 	pWallet.Text = "  Balance:          [waiting for sync...](fg:yellow)\n" +
		// 		"  Security:         [waiting for sync...](fg:yellow)\n" +
		// 		"  Actively Staking: [waiting for sync...](fg:yellow)\n"
		// case be.PTReddCoin:
		// 	pWallet.Text = "  Balance:          [waiting for sync...](fg:yellow)\n" +
		// 		"  Security:         [waiting for sync...](fg:yellow)\n"
		// case be.PTTrezarcoin:
		// 	pWallet.Text = "  Balance:          [waiting for sync...](fg:yellow)\n" +
		// 		"  Security:         [waiting for sync...](fg:yellow)\n" +
		// 		"  Actively Staking: [waiting for sync...](fg:yellow)\n"
		// case be.PTVertcoin:
		// 	pWallet.Text = "  Balance:          [waiting for sync...](fg:yellow)\n" +
		// 		"  Security:         [waiting for sync...](fg:yellow)\n"
		// default:
		// 	err = errors.New("unable to determine ProjectType")
		// }

		// *************************
		// Populate the Ticker panel
		// *************************

		pTicker := widgets.NewParagraph()
		pTicker.Title = "Ticker"
		pTicker.SetRect(33, 0, 84, 9)
		pTicker.TextStyle.Fg = ui.ColorWhite
		pTicker.BorderStyle.Fg = ui.ColorYellow
		pTicker.Text = "  Price:        [checking...](fg:yellow)\n" +
			"  BTC:         [waiting...](fg:yellow)\n" +
			"  24Hr Chg:	        [waiting...](fg:yellow)\n" +
			"  Week Chg: [waiting...](fg:yellow)"

		// **************************
		// Populate the Network panel
		// **************************

		pNetwork := widgets.NewParagraph()
		pNetwork.Title = "Network"
		pNetwork.SetRect(0, 11, 32, 4)
		pNetwork.TextStyle.Fg = ui.ColorWhite
		pNetwork.BorderStyle.Fg = ui.ColorWhite
		pNetwork.Text = coinDispInitialNetwork.InitialNetwork()

		// switch cliConf.ProjectType {
		// case be.PTDenarius:
		// 	pNetwork.Text = "  Blocks:      [checking...](fg:yellow)\n" +
		// 		"  Difficulty:  [checking...](fg:yellow)\n" +
		// 		"  Blockchain:  [checking...](fg:yellow)\n" +
		// 		"  Masternodes: [checking...](fg:yellow)" +
		// 		"  Peers:  [checking...](fg:yellow)\n"
		// case be.PTDeVault:
		// 	pNetwork.Text = "  Headers:     [checking...](fg:yellow)\n" +
		// 		"  Blocks:      [checking...](fg:yellow)\n" +
		// 		"  Difficulty:  [checking...](fg:yellow)\n" +
		// 		"  Blockchain:  [checking...](fg:yellow)\n" +
		// 		"  Peers:  [checking...](fg:yellow)\n"
		// case be.PTDigiByte:
		// 	pNetwork.Text = "  Headers:     [checking...](fg:yellow)\n" +
		// 		"  Blocks:      [checking...](fg:yellow)\n" +
		// 		"  Difficulty:  [checking...](fg:yellow)\n" +
		// 		"  Blockchain:  [checking...](fg:yellow)\n" +
		// 		"  Peers:  [checking...](fg:yellow)\n"
		// case be.PTFeathercoin:
		// 	pNetwork.Text = "  Headers:     [checking...](fg:yellow)\n" +
		// 		"  Blocks:      [checking...](fg:yellow)\n" +
		// 		"  Difficulty:  [checking...](fg:yellow)\n" +
		// 		"  Blockchain:  [checking...](fg:yellow)\n" +
		// 		"  Peers:  [checking...](fg:yellow)\n"

		// case be.PTGroestlcoin:
		// 	pNetwork.Text = "  Headers:     [checking...](fg:yellow)\n" +
		// 		"  Blocks:      [checking...](fg:yellow)\n" +
		// 		"  Difficulty:  [checking...](fg:yellow)\n" +
		// 		"  Blockchain:  [checking...](fg:yellow)\n" +
		// 		"  Peers:  [checking...](fg:yellow)\n"
		// case be.PTPhore:
		// 	pNetwork.Text = "  Blocks:      [checking...](fg:yellow)\n" +
		// 		"  Difficulty:  [checking...](fg:yellow)\n" +
		// 		"  Blockchain:  [checking...](fg:yellow)\n" +
		// 		"  Masternodes: [checking...](fg:yellow)" +
		// 		"  Peers:  [checking...](fg:yellow)\n"
		// case be.PTPIVX:
		// 	pNetwork.Text = "  Blocks:      [checking...](fg:yellow)\n" +
		// 		"  Difficulty:  [checking...](fg:yellow)\n" +
		// 		"  Blockchain:  [checking...](fg:yellow)\n" +
		// 		"  Masternodes: [checking...](fg:yellow)" +
		// 		"  Peers:  [checking...](fg:yellow)\n"

		// case be.PTReddCoin:
		// 	pNetwork.Text = "  Headers:     [checking...](fg:yellow)\n" +
		// 		"  Blocks:      [checking...](fg:yellow)\n" +
		// 		"  Difficulty:  [checking...](fg:yellow)\n" +
		// 		"  Blockchain:  [checking...](fg:yellow)\n" +
		// 		"  Peers:  [checking...](fg:yellow)\n"

		// case be.PTTrezarcoin:
		// 	pNetwork.Text = "  Blocks:      [checking...](fg:yellow)\n" +
		// 		"  Difficulty:  [checking...](fg:yellow)\n" +
		// 		"  Blockchain:  [checking...](fg:yellow)\n" +
		// 		"  Masternodes: [checking...](fg:yellow)" +
		// 		"  Peers:  [checking...](fg:yellow)\n"

		// case be.PTVertcoin:
		// 	pNetwork.Text = "  Headers:     [checking...](fg:yellow)\n" +
		// 		"  Blocks:      [checking...](fg:yellow)\n" +
		// 		"  Difficulty:  [checking...](fg:yellow)\n" +
		// 		"  Blockchain:  [checking...](fg:yellow)\n" +
		// 		"  Peers:  [checking...](fg:yellow)\n"

		// default:
		// 	err = errors.New("unable to determine ProjectType")
		// }

		// *******************************
		// Populate the Transactions panel
		// *******************************

		pTransactions := widgets.NewTable()
		pTransactions.Rows = [][]string{
			[]string{" Date", " Category", " Amount", " Confirmations"},
		}
		pTransactions.Title = "Transactions"
		pTransactions.RowSeparator = true
		pTransactions.SetRect(0, 11, 84, 30)
		pTransactions.TextStyle.Fg = ui.ColorWhite
		pTransactions.BorderStyle.Fg = ui.ColorWhite

		// // var numSeconds int = -1
		// var bciDenarius be.DenariusBlockchainInfoRespStruct
		// var bciDeVault be.DVTBlockchainInfoRespStruct
		// var bciDigiByte be.DGBBlockchainInfoRespStruct
		// var bciFeathercoin be.FeathercoinBlockchainInfoRespStruct
		// var bciGroestlcoin be.GRSBlockchainInfoRespStruct
		// var bciPhore be.PhoreBlockchainInfoRespStruct
		// var bciPIVX be.PIVXBlockchainInfoRespStruct
		// var bciRapids be.RapidsBlockchainInfoRespStruct
		// var bciReddCoin be.RDDBlockchainInfoRespStruct
		// var bciTrezarcoin be.TrezarcoinBlockchainInfoRespStruct
		// var bciVertcoin be.VTCBlockchainInfoRespStruct
		// //var gi be.GetInfoRespStruct
		// //var mnssDenarius be.DenariusMNSyncStatusRespStruct
		// var mnssDivi be.DiviMNSyncStatusRespStruct
		// var mnssPhore be.PhoreMNSyncStatusRespStruct
		// var mnssPIVX be.PIVXMNSyncStatusRespStruct
		// var mnssRapids be.RapidsMNSyncStatusRespStruct
		// //var niDeVault be.DVTNetworkInfoRespStruct
		// bXBCBlockchainIsSynced := false
		// bDenariusBlockchainIsSynced := false
		// bDGBBlockchainIsSynced := false
		// bDVTBlockchainIsSynced := false
		// bFTCBlockchainIsSynced := false
		// bGRSBlockchainIsSynced := false
		// bRDDBlockchainIsSynced := false
		// bTZCBlockchainIsSynced := false
		// bVTCBlockchainIsSynced := false
		// var ssDenarius be.DenariusStakingInfoStruct
		// var ssDivi be.DiviStakingStatusRespStruct
		// var ssPhore be.PhoreStakingStatusRespStruct
		// var ssPIVX be.PIVXStakingStatusRespStruct
		// var ssRapids be.RapidsStakingStatusRespStruct
		// var ssTrezarcoin be.TrezarcoinStakingInfoRespStruct
		// var ssXBC be.XBCStakingInfoRespStruct
		// var transDenarius be.DenariusListTransactions
		// var transDGB be.DGBListTransactions
		// var transDivi be.DiviListTransactions
		// var transFTC be.FTCListTransactions
		// var transPHR be.PhoreListTransactions
		// var transRDD be.RDDListTransactions
		// var transTZC be.TZCListTransactionsRespStruct
		// var transXBC be.XBCListTransactions
		// var giDenarius be.DenariusGetInfoRespStruct
		// var wiDeVault be.DVTWalletInfoRespStruct
		// var wiDigiByte be.DGBWalletInfoRespStruct
		// var wiDivi be.DiviWalletInfoRespStruct
		// var wiFeathercoin be.FeathercoinWalletInfoRespStruct
		// var wiGroestlcoin be.GRSWalletInfoRespStruct
		// var wiPhore be.PhoreWalletInfoRespStruct
		// var wiPIVX be.PIVXWalletInfoRespStruct
		// var wiRapids be.RapidsWalletInfoRespStruct
		// var wiReddCoin be.RDDWalletInfoRespStruct
		// var wiTrezarcoin be.TrezarcoinWalletInfoRespStruct
		// var wiVertcoin be.VTCWalletInfoRespStruct
		// var wiXBC be.XBCWalletInfoRespStruct

		var bBlockchainIsSynced bool
		updateDisplay := func(count int) {
			// Make sure that the BlockchainInfo RPC call, only happens once every 10 seconds
			if gGetBCInfoCount == 0 || gGetBCInfoCount > 10 {
				if gGetBCInfoCount > 10 {
					gGetBCInfoCount = 1
				} else {
					gGetBCInfoCount++
				}
				walletRefreshNetwork.RefreshNetwork(&coinAuth)
				walletRefreshTransactions.RefreshTransactions(&coinAuth)
				bBlockchainIsSynced, _ = coinBlockchainIsSynced.BlockchainIsSynced(&coinAuth)

				// Refresh

				//switch cliConf.ProjectType {
				//case be.PTDenarius:
				//	bciDenarius, _ = be.GetBlockchainInfoDenarius(&cliConf)
				//	if gDenariusBlockHeight > 0 {
				//		if bciDenarius.Result.Blocks >= gDenariusBlockHeight {
				//			bDenariusBlockchainIsSynced = true
				//		}
				//	}
				//case be.PTDeVault:
				//	bciDeVault, _ = be.GetBlockchainInfoDVT(&cliConf)
				//	if bciDeVault.Result.Verificationprogress > 0.99999 {
				//		bDVTBlockchainIsSynced = true
				//	}
				//case be.PTDigiByte:
				//	bciDigiByte, _ = be.GetBlockchainInfoDGB(&cliConf)
				//	if bciDigiByte.Result.Verificationprogress > 0.99999 {
				//		bDGBBlockchainIsSynced = true
				//	}
				//case be.PTDivi:
				//	bciDivi, _ = be.GetBlockchainInfoDivi(&cliConf)
				//case be.PTFeathercoin:
				//	bciFeathercoin, _ = be.GetBlockchainInfoFeathercoin(&cliConf)
				//	if bciFeathercoin.Result.Verificationprogress > 0.99999 {
				//		bFTCBlockchainIsSynced = true
				//	}
				//case be.PTGroestlcoin:
				//	bciGroestlcoin, _ = be.GetBlockchainInfoGRS(&cliConf)
				//	if bciGroestlcoin.Result.Verificationprogress > 0.99999 {
				//		bGRSBlockchainIsSynced = true
				//	}
				//case be.PTPhore:
				//	bciPhore, _ = be.GetBlockchainInfoPhore(&cliConf)
				//case be.PTPIVX:
				//	bciPIVX, _ = be.GetBlockchainInfoPIVX(&cliConf)
				//case be.PTRapids:
				//	bciRapids, _ = be.GetBlockchainInfoRapids(&cliConf)
				//case be.PTReddCoin:
				//	bciReddCoin, _ = be.GetBlockchainInfoRDD(&cliConf)
				//	if bciReddCoin.Result.Verificationprogress > 0.99999 {
				//		bRDDBlockchainIsSynced = true
				//	}
				//case be.PTTrezarcoin:
				//	bciTrezarcoin, _ = be.GetBlockchainInfoTrezarcoin(&cliConf)
				//	if bciTrezarcoin.Result.Verificationprogress > 0.99999 {
				//		bTZCBlockchainIsSynced = true
				//	}
				//case be.PTVertcoin:
				//	bciVertcoin, _ = be.GetBlockchainInfoVTC(&cliConf)
				//	if bciVertcoin.Result.Verificationprogress > 0.99999 {
				//		bVTCBlockchainIsSynced = true
				//	}
				//default:
				//	err = errors.New("unable to determine ProjectType")
				//}
			} else {
				gGetBCInfoCount++
			}

			// Now, we only want to get this other stuff, when the blockchain has synced.
			// This is checked every 1x second. Too often? Maybe should be once every 3 seconds?

			if bBlockchainIsSynced {
				pNetwork.BorderStyle.Fg = ui.ColorGreen
			} else {
				pNetwork.BorderStyle.Fg = ui.ColorYellow
			}
			// 	switch cliConf.ProjectType {
			// 	case be.PTDenarius:
			// 		if bDenariusBlockchainIsSynced {
			// 			giDenarius, _ = be.GetInfoDenarius(&cliConf)
			// 			ssDenarius, _ = be.GetStakingInfoDenarius(&cliConf)
			// 			transDenarius, _ = be.ListTransactionsDenarius(&cliConf)
			// 		}
			// 	case be.PTDeVault:
			// 		if bDVTBlockchainIsSynced {
			// 			wiDeVault, _ = be.GetWalletInfoDVT(&cliConf)
			// 		}
			// 	case be.PTDigiByte:
			// 		if bDGBBlockchainIsSynced {
			// 			wiDigiByte, _ = be.GetWalletInfoDGB(&cliConf)
			// 		}
			// 	case be.PTDivi:
			// 		if bciDivi.Result.Verificationprogress > 0.999 {
			// 			mnssDivi, _ = be.GetMNSyncStatusDivi(&cliConf)
			// 			ssDivi, _ = be.GetStakingStatusDivi(&cliConf)
			// 			transDivi, _ = be.ListTransactionsDivi(&cliConf)
			// 			wiDivi, _ = be.GetWalletInfoDivi(&cliConf)
			// 		}
			// 	case be.PTFeathercoin:
			// 		if bFTCBlockchainIsSynced {
			// 			transFTC, _ = be.ListTransactionsFTC(&cliConf)
			// 			wiFeathercoin, _ = be.GetWalletInfoFeathercoin(&cliConf)
			// 		}
			// 	case be.PTGroestlcoin:
			// 		if bGRSBlockchainIsSynced {
			// 			wiGroestlcoin, _ = be.GetWalletInfoGRS(&cliConf)
			// 		}
			// 	case be.PTPhore:
			// 		if bciPhore.Result.Verificationprogress > 0.999 {
			// 			mnssPhore, _ = be.GetMNSyncStatusPhore(&cliConf)
			// 			ssPhore, _ = be.GetStakingStatusPhore(&cliConf)
			// 			wiPhore, _ = be.GetWalletInfoPhore(&cliConf)
			// 		}
			// 	case be.PTPIVX:
			// 		if bciPIVX.Result.Verificationprogress > 0.999 {
			// 			mnssPIVX, _ = be.GetMNSyncStatusPIVX(&cliConf)
			// 			ssPIVX, _ = be.GetStakingStatusPIVX(&cliConf)
			// 			wiPIVX, _ = be.GetWalletInfoPIVX(&cliConf)
			// 		}
			// 	case be.PTReddCoin:
			// 		if bRDDBlockchainIsSynced {
			// 			transRDD, _ = be.ListTransactionsRDD(&cliConf)
			// 			wiReddCoin, _ = be.GetWalletInfoRDD(&cliConf)
			// 		}
			// 	case be.PTTrezarcoin:
			// 		if bTZCBlockchainIsSynced {
			// 			ssTrezarcoin, _ = be.GetStakingInfoTrezarcoin(&cliConf)
			// 			wiTrezarcoin, _ = be.GetWalletInfoTrezarcoin(&cliConf)
			// 		}
			// 	case be.PTVertcoin:
			// 		if bVTCBlockchainIsSynced {
			// 			wiVertcoin, _ = be.GetWalletInfoVTC(&cliConf)
			// 		}
			// 	default:
			// 		err = errors.New("unable to determine ProjectType")
			// 	}

			// ***************************
			// Populate the Network panel
			// ***************************
			pNetwork.Text = coinDispLiveNetwork.LiveNetwork()

			// 	var sBlocks string
			// 	var sDiff string
			// 	var sBlockchainSync string
			// 	var sHeaders string
			// 	var sMNSync string
			// 	var sPeers string
			// 	switch cliConf.ProjectType {
			// 	case be.PTDenarius:
			// 		sBlocks = getNetworkBlocksTxtDenarius(&bciDenarius)
			// 		sDiff = getNetworkDifficultyTxtDenarius(bciDenarius.Result.Difficulty.ProofOfWork, gDiffGood, gDiffWarning)
			// 		sBlockchainSync = getBlockchainSyncTxtDenarius(bDenariusBlockchainIsSynced, &bciDenarius)
			// 		sPeers = getNetworkConnectionsTxtDenarius(gConnections)
			// 	case be.PTDeVault:
			// 		sHeaders = getNetworkHeadersTxtDVT(&bciDeVault)
			// 		sBlocks = getNetworkBlocksTxtDVT(&bciDeVault)
			// 		sDiff = getNetworkDifficultyTxtDVT(bciDeVault.Result.Difficulty, gDiffGood, gDiffWarning)
			// 		sBlockchainSync = getBlockchainSyncTxtDVT(bDVTBlockchainIsSynced, &bciDeVault)
			// 		sPeers = getNetworkConnectionsTxtDVT(gConnections)
			// 	case be.PTDigiByte:
			// 		sHeaders = getNetworkHeadersTxtDGB(&bciDigiByte)
			// 		sBlocks = getNetworkBlocksTxtDGB(&bciDigiByte)
			// 		sDiff = getNetworkDifficultyTxtDGB(bciDigiByte.Result.Difficulties.Scrypt, gDiffGood, gDiffWarning)
			// 		sBlockchainSync = getBlockchainSyncTxtDGB(bDGBBlockchainIsSynced, &bciDigiByte)
			// 		sPeers = getNetworkConnectionsTxtDGB(gConnections)
			// 	case be.PTDivi:
			// 		sBlocks = getNetworkBlocksTxtDivi(&bciDivi)
			// 		sDiff = getNetworkDifficultyTxtDivi(bciDivi.Result.Difficulty, gDiffGood, gDiffWarning)
			// 		sBlockchainSync = getBlockchainSyncTxtDivi(mnssDivi.Result.IsBlockchainSynced, &bciDivi)
			// 		sMNSync = getMNSyncStatusTxtDivi(mnssDivi.Result.IsBlockchainSynced, &mnssDivi)
			// 		sPeers = getNetworkConnectionsTxtDivi(gConnections)
			// 	case be.PTFeathercoin:
			// 		sHeaders = getNetworkHeadersTxtFeathercoin(&bciFeathercoin)
			// 		sBlocks = getNetworkBlocksTxtFeathercoin(&bciFeathercoin)
			// 		sDiff = getNetworkDifficultyTxtFeathercoin(bciFeathercoin.Result.Difficulty, gDiffGood, gDiffWarning)
			// 		sBlockchainSync = getBlockchainSyncTxtFTC(bFTCBlockchainIsSynced, &bciFeathercoin)
			// 		sPeers = getNetworkConnectionsTxtFTC(gConnections)
			// 	case be.PTGroestlcoin:
			// 		sHeaders = getNetworkHeadersTxtGRS(&bciGroestlcoin)
			// 		sBlocks = getNetworkBlocksTxtGRS(&bciGroestlcoin)
			// 		sDiff = getNetworkDifficultyTxtGRS(bciGroestlcoin.Result.Difficulty, gDiffGood, gDiffWarning)
			// 		sBlockchainSync = getBlockchainSyncTxtGRS(bGRSBlockchainIsSynced, &bciGroestlcoin)
			// 		sPeers = getNetworkConnectionsTxtGRS(gConnections)
			// 	case be.PTPhore:
			// 		sBlocks = getNetworkBlocksTxtPhore(&bciPhore)
			// 		sDiff = getNetworkDifficultyTxtPhore(bciPhore.Result.Difficulty, gDiffGood, gDiffWarning)
			// 		sBlockchainSync = getBlockchainSyncTxtPHR(mnssPhore.Result.IsBlockchainSynced, &bciPhore)
			// 		sMNSync = getMNSyncStatusTxtPhore(mnssPhore.Result.IsBlockchainSynced, &mnssPhore)
			// 		sPeers = getNetworkConnectionsTxtPhore(gConnections)
			// 	case be.PTPIVX:
			// 		sBlocks = getNetworkBlocksTxtPIVX(&bciPIVX)
			// 		sDiff = getNetworkDifficultyTxtPIVX(bciPIVX.Result.Difficulty, gDiffGood, gDiffWarning)
			// 		sBlockchainSync = getBlockchainSyncTxtPIVX(mnssPIVX.Result.IsBlockchainSynced, &bciPIVX)
			// 		sMNSync = getMNSyncStatusTxtPIVX(mnssPIVX.Result.IsBlockchainSynced, &mnssPIVX)
			// 		sPeers = getNetworkConnectionsTxtPIVX(gConnections)
			// 	case be.PTReddCoin:
			// 		sHeaders = be.GetNetworkHeadersTxtRDD(&bciReddCoin)
			// 		sBlocks = be.GetNetworkBlocksTxtRDD(&bciReddCoin)
			// 		sDiff = be.GetNetworkDifficultyTxtRDD(bciReddCoin.Result.Difficulty, gDiffGood, gDiffWarning)
			// 		sBlockchainSync = getBlockchainSyncTxtRDD(bRDDBlockchainIsSynced, &bciReddCoin)
			// 		sPeers = be.GetNetworkConnectionsTxtRDD(gConnections)
			// 	case be.PTTrezarcoin:
			// 		sBlocks = be.GetNetworkBlocksTxtTrezarcoin(&bciTrezarcoin)
			// 		sDiff = be.GetNetworkDifficultyTxtTrezarcoin(bciTrezarcoin.Result.Difficulty, gDiffGood, gDiffWarning)
			// 		sBlockchainSync = getBlockchainSyncTxtTZC(bTZCBlockchainIsSynced, &bciTrezarcoin)
			// 		sPeers = be.GetNetworkConnectionsTxtTZC(gConnections)
			// 	case be.PTVertcoin:
			// 		sHeaders = be.GetNetworkHeadersTxtVTC(&bciVertcoin)
			// 		sBlocks = be.GetNetworkBlocksTxtVTC(&bciVertcoin)
			// 		sDiff = be.GetNetworkDifficultyTxtVTC(bciVertcoin.Result.Difficulty, gDiffGood, gDiffWarning)
			// 		sBlockchainSync = getBlockchainSyncTxtVTC(bVTCBlockchainIsSynced, &bciVertcoin)
			// 		sPeers = be.GetNetworkConnectionsTxtVTC(gConnections)
			// 	default:
			// 		err = errors.New("unable to determine ProjectType")
			// 	}

			// 	switch cliConf.ProjectType {
			// 	case be.PTDenarius:
			// 		pNetwork.Text = "  " + sBlocks + "\n" +
			// 			"  " + sDiff + "\n" +
			// 			"  " + sBlockchainSync + "\n" +
			// 			"  " + sPeers
			// 	case be.PTDeVault:
			// 		pNetwork.Text = "  " + sHeaders + "\n" +
			// 			"  " + sBlocks + "\n" +
			// 			"  " + sDiff + "\n" +
			// 			"  " + sBlockchainSync + "\n" +
			// 			"  " + sPeers
			// 	case be.PTDigiByte:
			// 		pNetwork.Text = "  " + sHeaders + "\n" +
			// 			"  " + sBlocks + "\n" +
			// 			"  " + sDiff + "\n" +
			// 			"  " + sBlockchainSync + "\n" +
			// 			"  " + sPeers
			// 	case be.PTDivi:
			// 		pNetwork.Text = "  " + sBlocks + "\n" +
			// 			"  " + sDiff + "\n" +
			// 			"  " + sBlockchainSync + "\n" +
			// 			"  " + sMNSync + "\n" +
			// 			"  " + sPeers
			// 	case be.PTFeathercoin:
			// 		pNetwork.Text = "  " + sHeaders + "\n" +
			// 			"  " + sBlocks + "\n" +
			// 			"  " + sDiff + "\n" +
			// 			"  " + sBlockchainSync + "\n" +
			// 			"  " + sPeers
			// 	case be.PTGroestlcoin:
			// 		pNetwork.Text = "  " + sHeaders + "\n" +
			// 			"  " + sBlocks + "\n" +
			// 			"  " + sDiff + "\n" +
			// 			"  " + sBlockchainSync + "\n" +
			// 			"  " + sPeers
			// 	case be.PTPhore:
			// 		pNetwork.Text = "  " + sBlocks + "\n" +
			// 			"  " + sDiff + "\n" +
			// 			"  " + sBlockchainSync + "\n" +
			// 			"  " + sMNSync + "\n" +
			// 			"  " + sPeers
			// 	case be.PTPIVX:
			// 		pNetwork.Text = "  " + sBlocks + "\n" +
			// 			"  " + sDiff + "\n" +
			// 			"  " + sBlockchainSync + "\n" +
			// 			"  " + sMNSync + "\n" +
			// 			"  " + sPeers
			// 	case be.PTReddCoin:
			// 		pNetwork.Text = "  " + sHeaders + "\n" +
			// 			"  " + sBlocks + "\n" +
			// 			"  " + sDiff + "\n" +
			// 			"  " + sBlockchainSync + "\n" +
			// 			"  " + sPeers
			// 	case be.PTTrezarcoin:
			// 		pNetwork.Text = "  " + sBlocks + "\n" +
			// 			"  " + sDiff + "\n" +
			// 			"  " + sBlockchainSync + "\n" +
			// 			"  " + sMNSync + "\n" +
			// 			"  " + sPeers
			// 	case be.PTVertcoin:
			// 		pNetwork.Text = "  " + sHeaders + "\n" +
			// 			"  " + sBlocks + "\n" +
			// 			"  " + sDiff + "\n" +
			// 			"  " + sBlockchainSync + "\n" +
			// 			"  " + sPeers
			// 	default:
			// 		pNetwork.Text = "  " + sBlocks + "\n" +
			// 			"  " + sDiff + "\n" +
			// 			"  " + sBlockchainSync + "\n" +
			// 			"  " + sMNSync + "\n" +
			// 			"  " + sPeers
			// 	}

			//**************************
			// Populate the Wallet panel
			//**************************

			// Decide what colour the wallet panel border should be...
			wet, _ := walletSecurityState.WalletSecurityState(&coinAuth)
			switch wet {
			case models.WETLocked:
				pWallet.BorderStyle.Fg = ui.ColorYellow
			case models.WETUnlocked:
				pWallet.BorderStyle.Fg = ui.ColorRed
			case models.WETUnlockedForStaking:
				pWallet.BorderStyle.Fg = ui.ColorGreen
			case models.WETUnencrypted:
				pWallet.BorderStyle.Fg = ui.ColorRed
			default:
				pWallet.BorderStyle.Fg = ui.ColorYellow
			}

			if bBlockchainIsSynced {
				pWallet.Text = coinDispLiveWallet.LiveWallet()
			}
			// 	// Update the wallet display, if we're all synced up
			// 	switch cliConf.ProjectType {
			// 	case be.PTDenarius:
			// 		if bciDenarius.Result.Blocks >= gDenariusBlockHeight {
			// 			pWallet.Text = "" + getBalanceInDenariusTxt(&giDenarius) + "\n" +
			// 				"  " + getWalletSecurityStatusTxtDenarius(&giDenarius) + "\n" +
			// 				"  " + getActivelyStakingTxtDenarius(&ssDenarius) + "\n"
			// 		}
			// 	case be.PTDeVault:
			// 		if bciDeVault.Result.Verificationprogress > 0.999 {
			// 			pWallet.Text = "" + getBalanceInDVTTxt(&wiDeVault) + "\n" +
			// 				"  " + getWalletSecurityStatusTxtDVT(&wiDeVault) + "\n"
			// 		}
			// 	case be.PTDigiByte:
			// 		if bciDigiByte.Result.Verificationprogress > 0.999 {
			// 			pWallet.Text = "" + getBalanceInDGBTxt(&wiDigiByte) + "\n" +
			// 				"  " + getWalletSecurityStatusTxtDGB(&wiDigiByte) + "\n"
			// 		}
			// 	case be.PTDivi:
			// 		if bciDivi.Result.Verificationprogress > 0.999 {
			// 			pWallet.Text = "" + getBalanceInDiviTxt(&wiDivi) + "\n" +
			// 				"  " + be.GetBalanceInCurrencyTxtDivi(&cliConf, &wiDivi) + "\n" +
			// 				"  " + getWalletSecurityStatusTxtDivi(&wiDivi) + "\n" +
			// 				"  " + getWalletStakingTxt(&wiDivi) + "\n" + //e.g. "15%" or "staking"
			// 				"  " + getActivelyStakingTxtDivi(&ssDivi, &wiDivi) + "\n" + //e.g. "15%" or "staking"
			// 				"  " + getNextLotteryTxtDIVI() + "\n" +
			// 				"  " + getLotteryTicketsTxtDIVI(&transDivi) //"Lottery tickets:  0"
			// 		}
			// 	case be.PTFeathercoin:
			// 		if bciFeathercoin.Result.Verificationprogress > 0.999 {
			// 			pWallet.Text = "" + getBalanceInFeathercoinTxt(&wiFeathercoin) + "\n" +
			// 				"  " + getWalletSecurityStatusTxtFeathercoin(&wiFeathercoin) + "\n"
			// 		}
			// 	case be.PTGroestlcoin:
			// 		if bciGroestlcoin.Result.Verificationprogress > 0.999 {
			// 			pWallet.Text = "" + getBalanceInGRSTxt(&wiGroestlcoin) + "\n" +
			// 				"  " + getWalletSecurityStatusTxtGRS(&wiGroestlcoin) + "\n"
			// 		}
			// 	case be.PTPhore:
			// 		if bciPhore.Result.Verificationprogress > 0.999 {
			// 			pWallet.Text = "" + getBalanceInPhoreTxt(&wiPhore) + "\n" +
			// 				"  " + getWalletSecurityStatusTxtPhore(&wiPhore) + "\n" +
			// 				"  " + getActivelyStakingTxtPhore(&ssPhore) + "\n" //e.g. "15%" or "staking"
			// 		}
			// 	case be.PTPIVX:
			// 		if bciPIVX.Result.Verificationprogress > 0.999 {
			// 			pWallet.Text = "" + getBalanceInPIVXTxt(&wiPIVX) + "\n" +
			// 				"  " + getWalletSecurityStatusTxtPIVX(&wiPIVX) + "\n" +
			// 				"  " + getActivelyStakingTxtPIVX(&ssPIVX) + "\n" //e.g. "15%" or "staking"
			// 		}
			// 	case be.PTReddCoin:
			// 		if bciReddCoin.Result.Verificationprogress > 0.999 {
			// 			pWallet.Text = "" + getBalanceInRDDTxt(&wiReddCoin) + "\n" +
			// 				"  " + getWalletSecurityStatusTxtRDD(&wiReddCoin) + "\n"
			// 		}
			// 	case be.PTTrezarcoin:
			// 		if bciTrezarcoin.Result.Verificationprogress > 0.999 {
			// 			pWallet.Text = "" + getBalanceInTrezarcoinTxt(&wiTrezarcoin) + "\n" +
			// 				"  " + getWalletSecurityStatusTxtTrezarcoin(&wiTrezarcoin) + "\n" +
			// 				"  " + getActivelyStakingTxtTrezarcoin(&ssTrezarcoin) + "\n" //e.g. "15%" or "staking"
			// 		}
			// 	case be.PTVertcoin:
			// 		if bciVertcoin.Result.Verificationprogress > 0.999 {
			// 			pWallet.Text = "" + getBalanceInVTCTxt(&wiVertcoin) + "\n" +
			// 				"  " + getWalletSecurityStatusTxtVTC(&wiVertcoin) + "\n"
			// 		}
			// 	default:
			// 		err = errors.New("unable to determine ProjectType")
			// 	}

			// *******************************************************
			// Update the transactions display, if we're all synced up
			// *******************************************************

			if bBlockchainIsSynced {
				containsZeroConfs, rows := coinDispLiveTransactions.LiveTransactions()
				if containsZeroConfs {
					pWallet.BorderStyle.Fg = ui.ColorYellow
				} else {
					pWallet.BorderStyle.Fg = ui.ColorGreen
				}
				pTransactions.Rows = rows
			}

			// 	switch cliConf.ProjectType {
			// 	case be.PTDenarius:
			// 		if bciDenarius.Result.Blocks >= gDenariusBlockHeight {
			// 			updateTransactionsDenarius(&transDenarius, pTransactions)
			// 		}
			// 	case be.PTDigiByte:
			// 		if bciDigiByte.Result.Verificationprogress > 0.999 {
			// 			updateTransactionsDGB(&transDGB, pTransactions)
			// 		}
			// 	case be.PTDivi:
			// 		if bciDivi.Result.Verificationprogress > 0.999 {
			// 			updateTransactionsDIVI(&transDivi, pTransactions)
			// 		}
			// 	case be.PTFeathercoin:
			// 		if bciFeathercoin.Result.Verificationprogress > 0.999 {
			// 			updateTransactionsFTC(&transFTC, pTransactions)
			// 		}
			// 	case be.PTPhore:
			// 		if bciPhore.Result.Verificationprogress > 0.999 {
			// 			updateTransactionsPHR(&transPHR, pTransactions)
			// 		}
			// 	case be.PTReddCoin:
			// 		if bciReddCoin.Result.Verificationprogress > 0.999 {
			// 			updateTransactionsRDD(&transRDD, pTransactions)
			// 		}
			// 	case be.PTTrezarcoin:
			// 		if bciTrezarcoin.Result.Verificationprogress > 0.999 {
			// 			updateTransactionsTZC(&transTZC, pTransactions)
			// 		}
			// 		//default:
			// 		//	err = errors.New("unable to determine ProjectType")
			// 	}

			// **************************************
			// Update routine for every 30 seconds...
			// **************************************

			if g30SecTickerCounter == 0 || g30SecTickerCounter > 30 {
				if g30SecTickerCounter > 30 {
					g30SecTickerCounter = 1
				} else {
					g30SecTickerCounter++
				}

				coinPrice.RefreshPrice()
				walletRefreshDifficulty.RefreshDifficulty()

				// 		switch cliConf.ProjectType {
				// 		case be.PTDenarius:
				// 			// We need to get the difficulty and the Block height for Denarius so we can work the verification progress.
				// 			// I think the difficulty routine should be in a separate 60 seconds timer, to reduce the amount of api calls to the service
				// 			gDiffGood, gDiffWarning, _ = getNetworkDifficultyInfo(be.PTDenarius)
				// 			giDenarius, _ := be.GetInfoDenarius(&cliConf)
				// 			gConnections = giDenarius.Result.Connections
				// 			gDenariusBlockHeight, _ = getBlockchainHeight(be.PTDenarius)
				// 		case be.PTDeVault:
				// 			gDiffGood, gDiffWarning, _ = getNetworkDifficultyInfo(be.PTDeVault)
				// 			// update the Network Info details
				// 			niDeVault, _ := be.GetNetworkInfoDVT(&cliConf)
				// 			gConnections = niDeVault.Result.Connections
				// 		case be.PTDigiByte:
				// 			gDiffGood, gDiffWarning, _ = getNetworkDifficultyInfo(be.PTDigiByte)
				// 			// update the Network Info details
				// 			niDigiByte, _ := be.GetNetworkInfoDGB(&cliConf)
				// 			gConnections = niDigiByte.Result.Connections
				// 		case be.PTDivi:
				// 			_ = be.UpdateTickerInfoDivi()
				// 			// Now check to see which currency the user is interested in...
				// 			switch cliConf.Currency {
				// 			case "AUD":
				// 				_ = be.UpdateAUDPriceInfo()
				// 			case "GBP":
				// 				_ = be.UpdateGBPPriceInfo()
				// 			}
				// 			_ = be.UpdateGBPPriceInfo()
				// 			gDiffGood, gDiffWarning, _ = getNetworkDifficultyInfo(be.PTDivi)
				// 			giDivi, _ := be.GetInfoDivi(&cliConf)
				// 			gConnections = giDivi.Result.Connections
				// 			gDiviLottery, _ = getDiviLotteryInfo(&cliConf)
				// 		case be.PTFeathercoin:
				// 			gDiffGood, gDiffWarning, _ = getNetworkDifficultyInfo(be.PTFeathercoin)
				// 			niFTC, _ := be.GetNetworkInfoFeathercoin(&cliConf)
				// 			gConnections = niFTC.Result.Connections
				// 		case be.PTGroestlcoin:
				// 			gDiffGood, gDiffWarning, _ = getNetworkDifficultyInfo(be.PTGroestlcoin)
				// 			niGRS, _ := be.GetNetworkInfoGRS(&cliConf)
				// 			gConnections = niGRS.Result.Connections
				// 		case be.PTPhore:
				// 			// todo Implement DiffGood and DiffWarning do for Phore
				// 			giPHR, _ := be.GetInfoPhore(&cliConf)
				// 			gConnections = giPHR.Result.Connections
				// 		case be.PTPIVX:
				// 			gDiffGood, gDiffWarning, _ = getNetworkDifficultyInfo(be.PTPIVX)
				// 			giPIVX, _, _ := be.GetInfoPIVX(&cliConf)
				// 			gConnections = giPIVX.Result.Connections
				// 		case be.PTReddCoin:
				// 			// todo Implement DiffGood and DiffWarning do for ReddCoin
				// 			//gDiffGood, gDiffWarning, _ = getNetworkDifficultyInfo(be.PTReddCoin)
				// 			niRDD, _ := be.GetNetworkInfoRDD(&cliConf)
				// 			gConnections = niRDD.Result.Connections
				// 		case be.PTTrezarcoin:
				// 			// todo Implement DiffGood and DiffWarning do for TZC
				// 			giTZC, _ := be.GetInfoTrezarcoin(&cliConf)
				// 			gConnections = giTZC.Result.Connections
				// 		case be.PTVertcoin:
				// 			gDiffGood, gDiffWarning, _ = getNetworkDifficultyInfo(be.PTVertcoin)
				// 			niVTC, _ := be.GetNetworkInfoVTC(&cliConf)
				// 			gConnections = niVTC.Result.Connections
				// 		default:
				// 			err = errors.New("unable to determine ProjectType")
				// 		}

				// 		// Let's see if we need to perform a health check
				// 		if b, err := be.ShouldWeRunHealthCheck(); err != nil {
				// 			if b {

				// 			}
				// 		}

			}
			g30SecTickerCounter++
		}

		draw := func(count int) {
			ui.Render(pAbout, pWallet, pNetwork, pTransactions)
		}

		tickerCount := 1
		updateDisplay(tickerCount)
		draw(tickerCount)
		tickerCount++
		uiEvents := ui.PollEvents()
		ticker := time.NewTicker(1 * time.Second).C
		for {
			select {
			case e := <-uiEvents:
				switch e.ID {
				case "q", "<C-c>":
					return

				}
			case <-ticker:
				updateDisplay(tickerCount)
				draw(tickerCount)
				tickerCount++
			}
		}

	},
}

func init() {
	rootCmd.AddCommand(dashCmd)

	// Here you will define your flags and configuration settings.

	// Cobra supports Persistent Flags which will work for this command
	// and all subcommands, e.g.:
	// dashCmd.PersistentFlags().String("foo", "", "A help for foo")

	// Cobra supports local flags which will only run when this command
	// is called directly, e.g.:
	// dashCmd.Flags().BoolP("toggle", "t", false, "Help message for toggle")
}

// func checkHealth(bci *be.DiviBlockchainInfoRespStruct) error {
// 	// This func will be called regularly and will check the health of the local wallet. It will..

// 	// If the blockchain verification is 0.99 or higher, than all so good, otherwise...
// 	if bci.Result.Verificationprogress > 0.99 {
// 		return nil
// 	}

// 	// If the block count is stuck at 100...
// 	if bci.Result.Blocks == 100 {
// 		// 20 * 3 = 3 minutes
// 		if gBCSyncStuckCount > 20*3 {
// 			if err := be.WalletFix(be.WFTReSync, be.PTDivi); err != nil {
// 				return fmt.Errorf("unable to perform wallet resync: %v", err)
// 			}
// 			return nil
// 		} else {
// 			gBCSyncStuckCount++
// 			return nil
// 		}
// 	}

// 	return nil
// }

func confirmWalletReady(coinAuth *models.CoinAuth, coinName string, wallet wallet.Wallet) (bool, error) {
	// cliConf, err := be.GetConfigStruct("", true)
	// if err != nil {
	// 	return false, "", fmt.Errorf("unable to determine coin type. Please run "+be.CAppFilename+" coin: %v", err.Error())
	// }
	// sCoinName, err := be.GetCoinName(be.APPTCLI)

	// Lets make sure that we have a running daemon.
	cfg := yacspin.Config{
		Frequency:       250 * time.Millisecond,
		CharSet:         yacspin.CharSets[43],
		Suffix:          "",
		SuffixAutoColon: true,
		Message:         " waiting for your " + coinName + " wallet to load, this could take several minutes...",
		StopCharacter:   "",
		StopColors:      []string{"fgGreen"},
	}

	spinner, err := yacspin.New(cfg)
	if err != nil {
		return false, fmt.Errorf("unable to initialise spinner - %v", err)
	}

	if err := spinner.Start(); err != nil {
		errors.New("Unable to start spinner - " + err.Error())
	}

	for i := 1; i < 600; i++ {
		wlStatus := wallet.WalletLoadingStatus(coinAuth)
		switch wlStatus {
		case models.WLSTUnknown, models.WLSTWaitingForResponse:
			spinner.Message(" waiting for your " + coinName + " wallet to respond, this could take several minutes (ctrl-c to cancel)...")
		case models.WLSTLoading:
			spinner.Message(" Your " + coinName + " wallet is *Loading*, this could take a while...")
		case models.WLSTRescanning:
			spinner.Message(" Your " + coinName + " wallet is *Rescanning*, this could take a while...")
		case models.WLSTRewinding:
			spinner.Message(" Your " + coinName + " wallet is *Rewinding*, this could take a while...")
		case models.WLSTVerifying:
			spinner.Message(" Your " + coinName + " wallet is *Verifying*, this could take a while...")
		case models.WLSTCalculatingMoneySupply:
			spinner.Message(" Your " + coinName + " wallet is *Calculating money supply*, this could take a while...")
		case models.WLSTReady:
			spinner.Stop()
			return true, nil
		}
		time.Sleep(1 * time.Second)
	}

	//coind, err := be.GetCoinDaemonFilename(be.APPTCLI, cliConf.ProjectType)
	//if err != nil {
	//	log.Fatalf("Unable to GetCoinDaemonFilename - %v", err)
	//}
	//switch cliConf.ProjectType {
	//case be.PTBitcoinPlus:
	//	gi, s, err := be.GetInfoXBCUI(&cliConf, spinner)
	//	if err != nil {
	//		if err := spinner.Stop(); err != nil {
	//		}
	//		return false, s, fmt.Errorf("Unable to communicate with the " + coind + " server.")
	//	}
	//	if gi.Result.Version == 0 {
	//		return false, s, fmt.Errorf("unable to call getinfo %s\n", err)
	//	}
	//case be.PTDenarius:
	//	gi, s, err := be.GetInfoDenariusUI(&cliConf, spinner)
	//	if err != nil {
	//		if err := spinner.Stop(); err != nil {
	//		}
	//		return false, s, fmt.Errorf("Unable to communicate with the " + coind + " server.")
	//	}
	//	if gi.Result.Version == "" {
	//		return false, s, fmt.Errorf("unable to call getinfo %s\n", err)
	//	}
	//case be.PTDeVault:
	//	gi, err := be.GetInfoDVT(&cliConf)
	//	if err != nil {
	//		if err := spinner.Stop(); err != nil {
	//		}
	//		return false, "", fmt.Errorf("Unable to communicate with the " + coind + " server.")
	//	}
	//	if gi.Result.Version == 0 {
	//		return false, gi.Result.Errors, fmt.Errorf("unable to call getinfo %s\n", err)
	//	}
	//case be.PTDigiByte:
	//	gi, s, err := be.GetNetworkInfoDGBUI(&cliConf, spinner)
	//	if err != nil {
	//		if err := spinner.Stop(); err != nil {
	//		}
	//		return false, s, fmt.Errorf("Unable to communicate with the " + coind + " server.")
	//	}
	//	if gi.Result.Version == 0 {
	//		return false, s, fmt.Errorf("unable to call getinfo %s\n", err)
	//	}
	//case be.PTDivi:
	//	gi, s, err := be.GetInfoDIVIUI(&cliConf, spinner)
	//	if err != nil {
	//		if err := spinner.Stop(); err != nil {
	//		}
	//		return false, s, fmt.Errorf("Unable to communicate with the " + coind + " server.")
	//	}
	//	if gi.Result.Version == "" {
	//		return false, s, fmt.Errorf("unable to call getinfo %s\n", err)
	//	}
	//case be.PTFeathercoin:
	//	gi, err := be.GetNetworkInfoFeathercoin(&cliConf)
	//	if err != nil {
	//		if err := spinner.Stop(); err != nil {
	//		}
	//		return false, "", fmt.Errorf("Unable to communicate with the " + coind + " server.")
	//	}
	//	if gi.Result.Version == 0 {
	//		return false, gi.Result.Warnings, fmt.Errorf("unable to call getinfo %s\n", err)
	//	}
	//case be.PTGroestlcoin:
	//	gi, err := be.GetNetworkInfoGRS(&cliConf)
	//	if err != nil {
	//		if err := spinner.Stop(); err != nil {
	//		}
	//		return false, "", fmt.Errorf("Unable to communicate with the " + coind + " server.")
	//	}
	//	if gi.Result.Version == 0 {
	//		return false, gi.Result.Warnings, fmt.Errorf("unable to call getinfo %s\n", err)
	//	}
	//case be.PTPhore:
	//	gi, err := be.GetInfoPhore(&cliConf)
	//	if err != nil {
	//		if err := spinner.Stop(); err != nil {
	//		}
	//		return false, "", fmt.Errorf("Unable to communicate with the " + coind + " server.")
	//	}
	//	if gi.Result.Version == 0 {
	//		return false, gi.Result.Errors, fmt.Errorf("unable to call getinfo %s\n", err)
	//	}
	//case be.PTPIVX:
	//	gi, s, err := be.GetInfoPIVXUI(&cliConf, spinner)
	//	if err != nil {
	//		if err := spinner.Stop(); err != nil {
	//		}
	//		return false, s, fmt.Errorf("Unable to communicate with the " + coind + " server.")
	//	}
	//	if gi.Result.Version == 0 {
	//		return false, s, fmt.Errorf("unable to call getinfo %s\n", err)
	//	}
	//case be.PTRapids:
	//	gi, s, err := be.GetInfoRPDUI(&cliConf, spinner)
	//	if err != nil {
	//		if err := spinner.Stop(); err != nil {
	//		}
	//		return false, s, fmt.Errorf("Unable to communicate with the " + coind + " server.")
	//	}
	//	if gi.Result.Version == 0 {
	//		return false, s, fmt.Errorf("unable to call getinfo %s\n", err)
	//	}
	//case be.PTReddCoin:
	//	gi, s, err := be.GetInfoRDDUI(&cliConf, spinner)
	//	if err != nil {
	//		if err := spinner.Stop(); err != nil {
	//		}
	//		return false, "", fmt.Errorf("Unable to communicate with the " + coind + " server.")
	//	}
	//	if gi.Result.Version == 0 {
	//		return false, s, fmt.Errorf("unable to call getinfo %s\n", err)
	//	}
	//case be.PTTrezarcoin:
	//	gi, err := be.GetInfoTrezarcoin(&cliConf)
	//	if err != nil {
	//		if err := spinner.Stop(); err != nil {
	//		}
	//		return false, "", fmt.Errorf("Unable to communicate with the " + coind + " server.")
	//	}
	//	if gi.Result.Version == 0 {
	//		return false, gi.Result.Errors, fmt.Errorf("unable to call getinfo %s\n", err)
	//	}
	//case be.PTVertcoin:
	//	gi, err := be.GetNetworkInfoVTC(&cliConf)
	//	if err != nil {
	//		if err := spinner.Stop(); err != nil {
	//		}
	//		return false, "", fmt.Errorf("Unable to communicate with the " + coind + " server.")
	//	}
	//	if gi.Result.Version == 0 {
	//		return false, "", fmt.Errorf("unable to call getinfo %s\n", err)
	//	}
	//default:
	//	return false, "", fmt.Errorf("unable to determine project type")
	//}
	spinner.Stop()

	return true, nil
}

// // convertBCVerification - Convert Blockchain verification progress...
// func convertBCVerification(verificationPG float64) string {
// 	var sProg string
// 	var fProg float64

// 	fProg = verificationPG * 100
// 	sProg = fmt.Sprintf("%.2f", fProg)

// 	return sProg
// }

// func encryptWallet(cliConf *be.ConfStruct, pw string) (be.GenericRespStruct, error) {
// 	var respStruct be.GenericRespStruct

// 	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"encryptwallet\",\"params\":[\"" + pw + "\"]}")
// 	req, err := http.NewRequest("POST", "http://"+cliConf.ServerIP+":"+cliConf.Port, body)
// 	if err != nil {
// 		return respStruct, err
// 	}
// 	req.SetBasicAuth(cliConf.RPCuser, cliConf.RPCpassword)
// 	req.Header.Set("Content-Type", "text/plain;")

// 	resp, err := http.DefaultClient.Do(req)
// 	if err != nil {
// 		return respStruct, err
// 	}
// 	defer resp.Body.Close()
// 	bodyResp, err := ioutil.ReadAll(resp.Body)
// 	if err != nil {
// 		return respStruct, err
// 	}
// 	err = json.Unmarshal(bodyResp, &respStruct)
// 	if err != nil {
// 		return respStruct, err
// 	}
// 	return respStruct, nil
// }

// func getNextLotteryTxtDIVI() string {
// 	if nextLotteryCounter > (60*30) || nextLotteryStored == "" {
// 		nextLotteryCounter = 0
// 		//lrs, _ := getDiviLotteryInfo(conf)
// 		if gDiviLottery.Lottery.Countdown.Humanized != "" {
// 			return "Next Lottery:     [" + gDiviLottery.Lottery.Countdown.Humanized + "](fg:white)"
// 		} else {
// 			return "Next Lottery:     [" + nextLotteryStored + "](fg:white)"
// 		}
// 	} else {
// 		return "Next Lottery:     [" + nextLotteryStored + "](fg:white)"
// 	}
// }

// func getLotteryTicketsTxtDIVI(trans *be.DiviListTransactions) string {
// 	iTotalTickets := 0

// 	for i := len(trans.Result) - 1; i >= 0; i-- {
// 		// If this transaction is not a stake, we're not interested in it.
// 		if trans.Result[i].Category != "stake_reward" {
// 			continue
// 		}

// 		// Check to make sure the confirmations count is higher than -1
// 		if trans.Result[i].Confirmations < 0 {
// 			continue
// 		}

// 		prevBlock := gDiviLottery.Lottery.NextLotteryBlock - 10080
// 		numBlocksSpread := gDiviLottery.Lottery.CurrentBlock - prevBlock

// 		// If the stake block is less than the next lottery block - 10080 then it's not in this weeks lottery
// 		if trans.Result[i].Confirmations > numBlocksSpread {
// 			continue
// 		}

// 		// We've got here, so count the stake...
// 		iTotalTickets = iTotalTickets + 1
// 	}

// 	return "Lottery tickets:  " + strconv.Itoa(iTotalTickets)
// }

// func getActivelyStakingTxtDenarius(ss *be.DenariusStakingInfoStruct) string {
// 	if ss.Result.Staking == true {
// 		return "Actively Staking: [Yes](fg:green)"
// 	} else {
// 		return "Actively Staking: [No](fg:yellow)"
// 	}
// }

// func getActivelyStakingTxtDivi(ss *be.DiviStakingStatusRespStruct, wi *be.DiviWalletInfoRespStruct) string {
// 	// Work out balance
// 	//todo Make sure that we only return yes, if the StakingStatus is true AND we have enough coins
// 	if ss.Result.StakingStatus == true && (wi.Result.Balance > 10000) {
// 		return "Actively Staking: [Yes](fg:green)"
// 	} else {
// 		return "Actively Staking: [No](fg:yellow)"
// 	}
// }

// func getActivelyStakingTxtPhore(ss *be.PhoreStakingStatusRespStruct) string {
// 	if ss.Result.StakingStatus == true {
// 		return "Actively Staking: [Yes](fg:green)"
// 	} else {
// 		return "Actively Staking: [No](fg:yellow)"
// 	}
// }

// func getActivelyStakingTxtPIVX(ss *be.PIVXStakingStatusRespStruct) string {
// 	if ss.Result.StakingStatus == true {
// 		return "Actively Staking: [Yes](fg:green)"
// 	} else {
// 		return "Actively Staking: [No](fg:yellow)"
// 	}
// }

// func getActivelyStakingTxtTrezarcoin(ss *be.TrezarcoinStakingInfoRespStruct) string {
// 	if ss.Result.Staking == true {
// 		return "Actively Staking: [Yes](fg:green)"
// 	} else {
// 		return "Actively Staking: [No](fg:yellow)"
// 	}
// }

// func getBalanceInDenariusTxt(gi *be.DenariusGetInfoRespStruct) string {
// 	tBalance := gi.Result.Immature + gi.Result.Unconfirmed + gi.Result.Balance
// 	tBalanceStr := humanize.FormatFloat("#,###.##", tBalance)

// 	// Work out balance
// 	if gi.Result.Immature > 0 {
// 		return "  Incoming.......   [" + tBalanceStr + "](fg:cyan)"
// 	} else if gi.Result.Unconfirmed > 0 {
// 		return "  Confirming....... [" + tBalanceStr + "](fg:yellow)"
// 	} else {
// 		return "  Balance:          [" + tBalanceStr + "](fg:green)"
// 	}

// 	// Work out balance
// 	return "  Balance:          [" + tBalanceStr + "](fg:green)"
// }

// func getBalanceInDGBTxt(wi *be.DGBWalletInfoRespStruct) string {
// 	tBalance := wi.Result.ImmatureBalance + wi.Result.UnconfirmedBalance + wi.Result.Balance
// 	tBalanceStr := humanize.FormatFloat("#,###.####", tBalance)

// 	// Work out balance
// 	if wi.Result.ImmatureBalance > 0 {
// 		return "  Incoming....... [" + tBalanceStr + "](fg:cyan)"
// 	} else if wi.Result.UnconfirmedBalance > 0 {
// 		return "  Confirming....... [" + tBalanceStr + "](fg:yellow)"
// 	} else {
// 		return "  Balance:          [" + tBalanceStr + "](fg:green)"
// 	}
// }

// func getBalanceInDiviTxt(wi *be.DiviWalletInfoRespStruct) string {
// 	tBalance := wi.Result.ImmatureBalance + wi.Result.UnconfirmedBalance + wi.Result.Balance
// 	tBalanceStr := humanize.FormatFloat("#,###.####", tBalance)

// 	// Work out balance
// 	if wi.Result.ImmatureBalance > 0 {
// 		return "  Incoming....... [" + tBalanceStr + "](fg:cyan)"
// 	} else if wi.Result.UnconfirmedBalance > 0 {
// 		return "  Confirming....... [" + tBalanceStr + "](fg:yellow)"
// 	} else {
// 		return "  Balance:          [" + tBalanceStr + "](fg:green)"
// 	}
// }

// func getBalanceInDVTTxt(wi *be.DVTWalletInfoRespStruct) string {
// 	tBalance := wi.Result.ImmatureBalance + wi.Result.UnconfirmedBalance + wi.Result.Balance
// 	tBalanceStr := humanize.FormatFloat("#,###.####", tBalance)

// 	// Work out balance
// 	if wi.Result.ImmatureBalance > 0 {
// 		return "  Incoming....... [" + tBalanceStr + "](fg:cyan)"
// 	} else if wi.Result.UnconfirmedBalance > 0 {
// 		return "  Confirming....... [" + tBalanceStr + "](fg:yellow)"
// 	} else {
// 		return "  Balance:          [" + tBalanceStr + "](fg:green)"
// 	}
// }

// func getBalanceInFeathercoinTxt(wi *be.FeathercoinWalletInfoRespStruct) string {
// 	tBalance := wi.Result.ImmatureBalance + wi.Result.UnconfirmedBalance + wi.Result.Balance
// 	tBalanceStr := humanize.FormatFloat("#,###.##", tBalance)

// 	// Work out balance
// 	if wi.Result.ImmatureBalance > 0 {
// 		return "  Incoming....... [" + tBalanceStr + "](fg:cyan)"
// 	} else if wi.Result.UnconfirmedBalance > 0 {
// 		return "  Confirming....... [" + tBalanceStr + "](fg:yellow)"
// 	} else {
// 		return "  Balance:          [" + tBalanceStr + "](fg:green)"
// 	}
// }

// func getBalanceInGRSTxt(wi *be.GRSWalletInfoRespStruct) string {
// 	tBalance := wi.Result.ImmatureBalance + wi.Result.UnconfirmedBalance + wi.Result.Balance
// 	tBalanceStr := humanize.FormatFloat("#,###.####", tBalance)

// 	// Work out balance
// 	if wi.Result.ImmatureBalance > 0 {
// 		return "  Incoming....... [" + tBalanceStr + "](fg:cyan)"
// 	} else if wi.Result.UnconfirmedBalance > 0 {
// 		return "  Confirming....... [" + tBalanceStr + "](fg:yellow)"
// 	} else {
// 		return "  Balance:          [" + tBalanceStr + "](fg:green)"
// 	}

// 	//tBalance := wi.Result.Balance
// 	//tBalanceStr := humanize.FormatFloat("#,###.####", tBalance)
// 	//
// 	//// Work out balance
// 	//return "  Balance:          [" + tBalanceStr + "](fg:green)"
// }

// func getBalanceInPhoreTxt(wi *be.PhoreWalletInfoRespStruct) string {
// 	tBalance := wi.Result.Balance
// 	tBalanceStr := humanize.FormatFloat("#,###.####", tBalance)

// 	// Work out balance
// 	return "  Balance:          [" + tBalanceStr + "](fg:green)"
// }

// func getBalanceInPIVXTxt(wi *be.PIVXWalletInfoRespStruct) string {
// 	tBalance := wi.Result.ImmatureBalance + wi.Result.UnconfirmedBalance + wi.Result.Balance
// 	tBalanceStr := humanize.FormatFloat("#,###.##", tBalance)

// 	// Work out balance
// 	if wi.Result.ImmatureBalance > 0 {
// 		return "  Incoming....... [" + tBalanceStr + "](fg:cyan)"
// 	} else if wi.Result.UnconfirmedBalance > 0 {
// 		return "  Confirming....... [" + tBalanceStr + "](fg:yellow)"
// 	} else {
// 		return "  Balance:          [" + tBalanceStr + "](fg:green)"
// 	}

// 	// Work out balance
// 	return "  Balance:          [" + tBalanceStr + "](fg:green)"
// }

// func getBalanceInRapidsTxt(wi *be.RapidsWalletInfoRespStruct) string {
// 	tBalance := wi.Result.ImmatureBalance + wi.Result.UnconfirmedBalance + wi.Result.Balance
// 	tBalanceStr := humanize.FormatFloat("#,###.##", tBalance)

// 	// Work out balance
// 	if wi.Result.ImmatureBalance > 0 {
// 		return "  Incoming....... [" + tBalanceStr + "](fg:cyan)"
// 	} else if wi.Result.UnconfirmedBalance > 0 {
// 		return "  Confirming....... [" + tBalanceStr + "](fg:yellow)"
// 	} else {
// 		return "  Balance:          [" + tBalanceStr + "](fg:green)"
// 	}

// 	// Work out balance
// 	return "  Balance:          [" + tBalanceStr + "](fg:green)"
// }

// func getBalanceInRDDTxt(wi *be.RDDWalletInfoRespStruct) string {
// 	tBalance := wi.Result.Balance
// 	tBalanceStr := humanize.FormatFloat("#,###.####", tBalance)

// 	// Work out balance
// 	return "  Balance:          [" + tBalanceStr + "](fg:green)"
// }

// func getBalanceInTrezarcoinTxt(wi *be.TrezarcoinWalletInfoRespStruct) string {
// 	tBalance := wi.Result.ImmatureBalance + wi.Result.UnconfirmedBalance + wi.Result.Balance
// 	tBalanceStr := humanize.FormatFloat("#,###.##", tBalance)

// 	// Work out balance
// 	if wi.Result.ImmatureBalance > 0 {
// 		return "  Incoming....... [" + tBalanceStr + "](fg:cyan)"
// 	} else if wi.Result.UnconfirmedBalance > 0 {
// 		return "  Confirming....... [" + tBalanceStr + "](fg:yellow)"
// 	} else {
// 		return "  Balance:          [" + tBalanceStr + "](fg:green)"
// 	}
// }

// func getBalanceInVTCTxt(wi *be.VTCWalletInfoRespStruct) string {
// 	tBalance := wi.Result.ImmatureBalance + wi.Result.UnconfirmedBalance + wi.Result.Balance
// 	tBalanceStr := humanize.FormatFloat("#,###.##", tBalance)

// 	// Work out balance
// 	if wi.Result.ImmatureBalance > 0 {
// 		return "  Incoming....... [" + tBalanceStr + "](fg:cyan)"
// 	} else if wi.Result.UnconfirmedBalance > 0 {
// 		return "  Confirming....... [" + tBalanceStr + "](fg:yellow)"
// 	} else {
// 		return "  Balance:          [" + tBalanceStr + "](fg:green)"
// 	}
// }

// func getBlockchainHeight(pt be.ProjectType) (int, error) {
// 	var coin string
// 	// https://chainz.cryptoid.info/ftc/api.dws?q=getblockcount
// 	switch pt {
// 	case be.PTDenarius:
// 		coin = "d"
// 	default:
// 		return 0, errors.New("unable to determine project type")
// 	}

// 	resp, err := http.Get("https://chainz.cryptoid.info/" + coin + "/api.dws?q=getblockcount")
// 	if err != nil {
// 		return 0, err
// 	}
// 	defer resp.Body.Close()

// 	body, err := ioutil.ReadAll(resp.Body)
// 	if err != nil {
// 		return 0, err
// 	}

// 	if iBlockcount, err := strconv.Atoi(string(body)); err == nil {
// 		return iBlockcount, nil
// 	} else {
// 		return iBlockcount, err
// 	}
// }

// func getBlockchainSyncTxtDenarius(synced bool, bci *be.DenariusBlockchainInfoRespStruct) string {
// 	var sProg string
// 	var fProg float64

// 	if gDenariusBlockHeight > 0 {
// 		//fProg = (gDenariusBlockHeight / bci.Result.Blocks) * 100
// 		fProg = percent.PercentOf(bci.Result.Blocks, gDenariusBlockHeight)
// 	}
// 	sProg = fmt.Sprintf("%.1f", fProg)

// 	if sProg == "0.0" {
// 		sProg = ""
// 	} else {
// 		sProg = sProg + "%"
// 	}

// 	if !synced {
// 		return "Blockchain: [" + getNextProgBCIndicator(gLastBCSyncStatus) + "syncing " + sProg + " ](fg:yellow)"
// 		//if bci.Result.Blocks > gLastBCSyncPosD {
// 		//	gLastBCSyncPosD = bci.Result.Blocks
// 		//	return "Blockchain: [" + getNextProgBCIndicator(gLastBCSyncStatus) + "syncing " + sProg + " ](fg:yellow)"
// 		//} else {
// 		//	gLastBCSyncPosD = bci.Result.Blocks
// 		//	return "Blockchain: [" + getNextProgBCIndicator(gLastBCSyncStatus) + "waiting " + sProg + " ](fg:yellow)"
// 		//}
// 	} else {
// 		return "Blockchain:  [synced " + be.CUtfTickBold + "](fg:green)"
// 	}
// }

// func getBlockchainSyncTxtXBC(synced bool, bci *be.XBCBlockchainInfoRespStruct) string {
// 	s := convertBCVerification(bci.Result.Verificationprogress)
// 	if s == "0.0" {
// 		s = ""
// 	} else {
// 		s = s + "%"
// 	}

// 	if !synced {
// 		return "Blockchain: [" + getNextProgBCIndicator(gLastBCSyncStatus) + "syncing " + s + " ](fg:yellow)"
// 	} else {
// 		return "Blockchain:  [synced " + cUtfTickBold + "](fg:green)"
// 	}
// }

// func getBlockchainSyncTxtDVT(synced bool, bci *be.DVTBlockchainInfoRespStruct) string {
// 	s := convertBCVerification(bci.Result.Verificationprogress)
// 	if s == "0.0" {
// 		s = ""
// 	} else {
// 		s = s + "%"
// 	}

// 	if !synced {
// 		return "Blockchain: [" + getNextProgBCIndicator(gLastBCSyncStatus) + "syncing " + s + " ](fg:yellow)"
// 	} else {
// 		return "Blockchain:  [synced " + cUtfTickBold + "](fg:green)"
// 	}
// }

// func getBlockchainSyncTxtDGB(synced bool, bci *be.DGBBlockchainInfoRespStruct) string {
// 	s := convertBCVerification(bci.Result.Verificationprogress)
// 	if s == "0.0" {
// 		s = ""
// 	} else {
// 		s = s + "%"
// 	}

// 	if !synced {
// 		return "Blockchain: [" + getNextProgBCIndicator(gLastBCSyncStatus) + "syncing " + s + " ](fg:yellow)"
// 	} else {
// 		return "Blockchain:  [synced " + cUtfTickBold + "](fg:green)"
// 	}
// }

// func getBlockchainSyncTxtDivi(synced bool, bci *be.DiviBlockchainInfoRespStruct) string {
// 	s := convertBCVerification(bci.Result.Verificationprogress)
// 	if s == "0.0" {
// 		s = ""
// 	} else {
// 		s = s + "%"
// 	}

// 	if !synced {
// 		return "Blockchain: [" + getNextProgBCIndicator(gLastBCSyncStatus) + "syncing " + s + " ](fg:yellow)"
// 		//if bci.Result.Verificationprogress > gLastBCSyncPos {
// 		//	gLastBCSyncPos = bci.Result.Verificationprogress
// 		//	return "Blockchain:  [syncing " + s + " ](fg:yellow)"
// 		//} else {
// 		//	gLastBCSyncPos = bci.Result.Verificationprogress
// 		//	return "Blockchain:  [waiting " + s + " ](fg:yellow)"
// 		//}
// 	} else {
// 		return "Blockchain:  [synced " + cUtfTickBold + "](fg:green)"
// 	}
// }

// func getBlockchainSyncTxtFTC(synced bool, bci *be.FeathercoinBlockchainInfoRespStruct) string {
// 	s := convertBCVerification(bci.Result.Verificationprogress)
// 	if s == "0.0" {
// 		s = ""
// 	} else {
// 		s = s + "%"
// 	}

// 	if !synced {
// 		return "Blockchain: [" + getNextProgBCIndicator(gLastBCSyncStatus) + "syncing " + s + " ](fg:yellow)"
// 	} else {
// 		return "Blockchain:  [synced " + cUtfTickBold + "](fg:green)"
// 	}
// }

// func getBlockchainSyncTxtGRS(synced bool, bci *be.GRSBlockchainInfoRespStruct) string {
// 	s := convertBCVerification(bci.Result.Verificationprogress)
// 	if s == "0.0" {
// 		s = ""
// 	} else {
// 		s = s + "%"
// 	}

// 	if !synced {
// 		return "Blockchain: [" + getNextProgBCIndicator(gLastBCSyncStatus) + "syncing " + s + " ](fg:yellow)"
// 	} else {
// 		return "Blockchain:  [synced " + cUtfTickBold + "](fg:green)"
// 	}
// }

// func getBlockchainSyncTxtPHR(synced bool, bci *be.PhoreBlockchainInfoRespStruct) string {
// 	s := convertBCVerification(bci.Result.Verificationprogress)
// 	if s == "0.0" {
// 		s = ""
// 	} else {
// 		s = s + "%"
// 	}

// 	if !synced {
// 		return "Blockchain: [" + getNextProgBCIndicator(gLastBCSyncStatus) + "syncing " + s + " ](fg:yellow)"
// 	} else {
// 		return "Blockchain:  [synced " + cUtfTickBold + "](fg:green)"
// 	}
// }

// func getBlockchainSyncTxtPIVX(synced bool, bci *be.PIVXBlockchainInfoRespStruct) string {
// 	s := convertBCVerification(bci.Result.Verificationprogress)
// 	if s == "0.0" {
// 		s = ""
// 	} else {
// 		s = s + "%"
// 	}

// 	if !synced {
// 		return "Blockchain: [" + getNextProgBCIndicator(gLastBCSyncStatus) + "syncing " + s + " ](fg:yellow)"
// 	} else {
// 		return "Blockchain:  [synced " + cUtfTickBold + "](fg:green)"
// 	}
// }

// func getBlockchainSyncTxtRPD(synced bool, bci *be.RapidsBlockchainInfoRespStruct) string {
// 	s := convertBCVerification(bci.Result.Verificationprogress)
// 	if s == "0.0" {
// 		s = ""
// 	} else {
// 		s = s + "%"
// 	}

// 	if !synced {
// 		return "Blockchain: [" + getNextProgBCIndicator(gLastBCSyncStatus) + "syncing " + s + " ](fg:yellow)"
// 	} else {
// 		return "Blockchain:  [synced " + cUtfTickBold + "](fg:green)"
// 	}
// }

// func getBlockchainSyncTxtRDD(synced bool, bci *be.RDDBlockchainInfoRespStruct) string {
// 	s := convertBCVerification(bci.Result.Verificationprogress)
// 	if s == "0.0" {
// 		s = ""
// 	} else {
// 		s = s + "%"
// 	}

// 	if !synced {
// 		return "Blockchain: [" + getNextProgBCIndicator(gLastBCSyncStatus) + "syncing " + s + " ](fg:yellow)"
// 	} else {
// 		return "Blockchain:  [synced " + cUtfTickBold + "](fg:green)"
// 	}
// }

// func getBlockchainSyncTxtTZC(synced bool, bci *be.TrezarcoinBlockchainInfoRespStruct) string {
// 	s := convertBCVerification(bci.Result.Verificationprogress)
// 	if s == "0.0" {
// 		s = ""
// 	} else {
// 		s = s + "%"
// 	}

// 	if !synced {
// 		return "Blockchain: [" + getNextProgBCIndicator(gLastBCSyncStatus) + "syncing " + s + " ](fg:yellow)"
// 	} else {
// 		return "Blockchain:  [synced " + cUtfTickBold + "](fg:green)"
// 	}
// }

// func getBlockchainSyncTxtVTC(synced bool, bci *be.VTCBlockchainInfoRespStruct) string {
// 	s := convertBCVerification(bci.Result.Verificationprogress)
// 	if s == "0.0" {
// 		s = ""
// 	} else {
// 		s = s + "%"
// 	}

// 	if !synced {
// 		return "Blockchain: [" + getNextProgBCIndicator(gLastBCSyncStatus) + "syncing " + s + " ](fg:yellow)"
// 	} else {
// 		return "Blockchain:  [synced " + cUtfTickBold + "](fg:green)"
// 	}
// }

// func getMNSyncStatusTxtDivi(bcs bool, mnss *be.DiviMNSyncStatusRespStruct) string {
// 	if mnss.Result.RequestedMasternodeAssets == 999 {
// 		return "Masternodes: [synced " + cUtfTickBold + "](fg:green)"
// 	} else {
// 		if bcs {
// 			return "Masternodes:[" + getNextProgMNIndicator(gLastMNSyncStatus) + "syncing...](fg:yellow)"
// 		} else {
// 			return "Masternodes: [waiting...](fg:yellow)"
// 		}
// 	}
// }

// func getMNSyncStatusTxtPhore(bcs bool, mnss *be.PhoreMNSyncStatusRespStruct) string {
// 	if mnss.Result.RequestedMasternodeAssets == 999 {
// 		return "Masternodes: [synced " + cUtfTickBold + "](fg:green)"
// 	} else {
// 		if bcs {
// 			return "Masternodes:[" + getNextProgMNIndicator(gLastMNSyncStatus) + "syncing...](fg:yellow)"
// 		} else {
// 			return "Masternodes: [waiting...](fg:yellow)"
// 		}
// 	}
// }

// func getMNSyncStatusTxtPIVX(bcs bool, mnss *be.PIVXMNSyncStatusRespStruct) string {
// 	if mnss.Result.RequestedMasternodeAssets == 999 {
// 		return "Masternodes: [synced " + cUtfTickBold + "](fg:green)"
// 	} else {
// 		if bcs {
// 			return "Masternodes:[" + getNextProgMNIndicator(gLastMNSyncStatus) + "syncing...](fg:yellow)"
// 		} else {
// 			return "Masternodes: [waiting...](fg:yellow)"
// 		}
// 	}
// }

// func getMNSyncStatusTxtRapids(bcs bool, mnss *be.RapidsMNSyncStatusRespStruct) string {
// 	if mnss.Result.RequestedMasternodeAssets == 999 {
// 		return "Masternodes: [synced " + cUtfTickBold + "](fg:green)"
// 	} else {
// 		if bcs {
// 			return "Masternodes: [" + getNextProgMNIndicator(gLastMNSyncStatus) + "syncing ](fg:yellow)"
// 		} else {
// 			return "Masternodes: [waiting...](fg:yellow)"
// 		}
// 	}
// }

// func getNetworkBlocksTxtDenarius(bci *be.DenariusBlockchainInfoRespStruct) string {
// 	blocksStr := humanize.Comma(int64(bci.Result.Blocks))

// 	if blocksStr == "0" {
// 		return "Blocks:      [waiting...](fg:white)"
// 	}

// 	return "Blocks:      [" + blocksStr + "](fg:green)"
// }

// func getNetworkBlocksTxtDGB(bci *be.DGBBlockchainInfoRespStruct) string {
// 	blocksStr := humanize.Comma(int64(bci.Result.Blocks))

// 	if blocksStr == "0" {
// 		return "Blocks:      [waiting...](fg:white)"
// 	}

// 	return "Blocks:      [" + blocksStr + "](fg:green)"

// }

// func getNetworkBlocksTxtDivi(bci *be.DiviBlockchainInfoRespStruct) string {
// 	blocksStr := humanize.Comma(int64(bci.Result.Blocks))

// 	if bci.Result.Blocks > 100 {
// 		return "Blocks:      [" + blocksStr + "](fg:green)"
// 	} else {
// 		return "[Blocks:      " + blocksStr + "](fg:red)"
// 	}
// }

// func getNetworkBlocksTxtFeathercoin(bci *be.FeathercoinBlockchainInfoRespStruct) string {
// 	blocksStr := humanize.Comma(int64(bci.Result.Blocks))

// 	if blocksStr == "0" {
// 		return "Blocks:      [waiting...](fg:white)"
// 	}

// 	return "Blocks:      [" + blocksStr + "](fg:green)"
// 	//if bci.Result.Blocks > 0 {
// 	//	return "Blocks:      [" + blocksStr + "](fg:green)"
// 	//} else {
// 	//	return "[Blocks:      " + blocksStr + "](fg:red)"
// 	//}
// }

// func getNetworkBlocksTxtDVT(bci *be.DVTBlockchainInfoRespStruct) string {
// 	blocksStr := humanize.Comma(int64(bci.Result.Blocks))

// 	if blocksStr == "0" {
// 		return "Blocks:      [waiting...](fg:white)"
// 	}

// 	return "Blocks:      [" + blocksStr + "](fg:green)"
// }

// func getNetworkBlocksTxtGRS(bci *be.GRSBlockchainInfoRespStruct) string {
// 	blocksStr := humanize.Comma(int64(bci.Result.Blocks))

// 	if blocksStr == "0" {
// 		return "Blocks:      [waiting...](fg:white)"
// 	}

// 	return "Blocks:      [" + blocksStr + "](fg:green)"
// }

// func getNetworkBlocksTxtPhore(bci *be.PhoreBlockchainInfoRespStruct) string {
// 	blocksStr := humanize.Comma(int64(bci.Result.Blocks))

// 	if bci.Result.Blocks > 100 {
// 		return "Blocks:      [" + blocksStr + "](fg:green)"
// 	} else {
// 		return "[Blocks:      " + blocksStr + "](fg:red)"
// 	}
// }

// func getNetworkBlocksTxtPIVX(bci *be.PIVXBlockchainInfoRespStruct) string {
// 	blocksStr := humanize.Comma(int64(bci.Result.Blocks))

// 	if bci.Result.Blocks > 100 {
// 		return "Blocks:      [" + blocksStr + "](fg:green)"
// 	} else {
// 		return "[Blocks:      " + blocksStr + "](fg:red)"
// 	}
// }

// func getNetworkBlocksTxtXBC(bci *be.XBCBlockchainInfoRespStruct) string {
// 	blocksStr := humanize.Comma(int64(bci.Result.Blocks))

// 	if blocksStr == "0" {
// 		return "Blocks:      [waiting...](fg:white)"
// 	}

// 	return "Blocks:      [" + blocksStr + "](fg:green)"
// }

// func getNetworkConnectionsTxtDenarius(connections int) string {
// 	if connections == 0 {
// 		return "Peers:       [0](fg:red)"
// 	}
// 	return "Peers:       [" + strconv.Itoa(connections) + "](fg:green)"
// }

// func getNetworkConnectionsTxtDVT(connections int) string {
// 	if connections == 0 {
// 		return "Peers:       [0](fg:red)"
// 	}
// 	return "Peers:       [" + strconv.Itoa(connections) + "](fg:green)"
// }

// func getNetworkConnectionsTxtDGB(connections int) string {
// 	if connections == 0 {
// 		return "Peers:       [0](fg:red)"
// 	}
// 	return "Peers:       [" + strconv.Itoa(connections) + "](fg:green)"
// }

// func getNetworkConnectionsTxtDivi(connections int) string {
// 	if connections == 0 {
// 		return "Peers:       [0](fg:red)"
// 	}
// 	return "Peers:       [" + strconv.Itoa(connections) + "](fg:green)"
// }

// func getNetworkConnectionsTxtFTC(connections int) string {
// 	if connections == 0 {
// 		return "Peers:       [0](fg:red)"
// 	}
// 	return "Peers:       [" + strconv.Itoa(connections) + "](fg:green)"
// }

// func getNetworkConnectionsTxtGRS(connections int) string {
// 	if connections == 0 {
// 		return "Peers:       [0](fg:red)"
// 	}
// 	return "Peers:       [" + strconv.Itoa(connections) + "](fg:green)"
// }

// func getNetworkConnectionsTxtPhore(connections int) string {
// 	if connections == 0 {
// 		return "Peers:       [0](fg:red)"
// 	}
// 	return "Peers:       [" + strconv.Itoa(connections) + "](fg:green)"
// }

// func getNetworkConnectionsTxtPIVX(connections int) string {
// 	if connections == 0 {
// 		return "Peers:       [0](fg:red)"
// 	}
// 	return "Peers:       [" + strconv.Itoa(connections) + "](fg:green)"
// }

// func getNetworkConnectionsTxtXBC(connections int) string {
// 	if connections == 0 {
// 		return "Peers:       [0](fg:red)"
// 	}
// 	return "Peers:       [" + strconv.Itoa(connections) + "](fg:green)"
// }

// func getNetworkDifficultyTxtDenarius(difficulty, good, warn float64) string {
// 	var s string
// 	if difficulty > 1000 {
// 		s = humanize.FormatFloat("#.#", difficulty/1000) + "k"
// 	} else {
// 		s = humanize.Ftoa(difficulty)
// 	}

// 	// If Diff is less than 1, then we're not even calculating it properly yet...
// 	if difficulty < 1 {
// 		return "[Difficulty:  waiting...](fg:white)"
// 	}

// 	if difficulty >= good {
// 		return "Difficulty:  [" + s + "](fg:green)"
// 	} else if difficulty >= warn {
// 		return "Difficulty:  [" + s + "](fg:yellow)"
// 	} else {
// 		return "Difficulty:  [" + s + "](fg:red)"
// 	}
// }

// func getNetworkHeadersTxtDVT(bci *be.DVTBlockchainInfoRespStruct) string {
// 	headersStr := humanize.Comma(int64(bci.Result.Headers))

// 	if bci.Result.Headers > 1 {
// 		return "Headers:     [" + headersStr + "](fg:green)"
// 	} else {
// 		return "[Headers:     " + headersStr + "](fg:red)"
// 	}
// }

// func getNetworkHeadersTxtDGB(bci *be.DGBBlockchainInfoRespStruct) string {
// 	headersStr := humanize.Comma(int64(bci.Result.Headers))

// 	if bci.Result.Headers > 1 {
// 		return "Headers:     [" + headersStr + "](fg:green)"
// 	} else {
// 		return "[Headers:     " + headersStr + "](fg:red)"
// 	}
// }

// func getNetworkHeadersTxtFeathercoin(bci *be.FeathercoinBlockchainInfoRespStruct) string {
// 	headersStr := humanize.Comma(int64(bci.Result.Headers))

// 	if bci.Result.Headers > 1 {
// 		return "Headers:     [" + headersStr + "](fg:green)"
// 	} else {
// 		return "[Headers:     " + headersStr + "](fg:red)"
// 	}
// }

// func getNetworkHeadersTxtGRS(bci *be.GRSBlockchainInfoRespStruct) string {
// 	headersStr := humanize.Comma(int64(bci.Result.Headers))

// 	if bci.Result.Headers > 1 {
// 		return "Headers:     [" + headersStr + "](fg:green)"
// 	} else {
// 		return "[Headers:     " + headersStr + "](fg:red)"
// 	}
// }

// func getNetworkHeadersTxtXBC(bci *be.XBCBlockchainInfoRespStruct) string {
// 	headersStr := humanize.Comma(int64(bci.Result.Headers))

// 	if bci.Result.Headers > 1 {
// 		return "Headers:     [" + headersStr + "](fg:green)"
// 	} else {
// 		return "[Headers:     " + headersStr + "](fg:red)"
// 	}
// }

// func getNextProgBCIndicator(LIndicator string) string {
// 	if LIndicator == cProg1 {
// 		gLastBCSyncStatus = cProg2
// 		return cProg2
// 	} else if LIndicator == cProg2 {
// 		gLastBCSyncStatus = cProg3
// 		return cProg3
// 	} else if LIndicator == cProg3 {
// 		gLastBCSyncStatus = cProg4
// 		return cProg4
// 	} else if LIndicator == cProg4 {
// 		gLastBCSyncStatus = cProg5
// 		return cProg5
// 	} else if LIndicator == cProg5 {
// 		gLastBCSyncStatus = cProg6
// 		return cProg6
// 	} else if LIndicator == cProg6 {
// 		gLastBCSyncStatus = cProg7
// 		return cProg7
// 	} else if LIndicator == cProg7 {
// 		gLastBCSyncStatus = cProg8
// 		return cProg8
// 	} else if LIndicator == cProg8 || LIndicator == "" {
// 		gLastBCSyncStatus = cProg1
// 		return cProg1
// 	} else {
// 		gLastBCSyncStatus = cProg1
// 		return cProg1
// 	}
// }

// func getNextProgMNIndicator(LIndicator string) string {
// 	if LIndicator == cProg1 {
// 		gLastMNSyncStatus = cProg2
// 		return cProg2
// 	} else if LIndicator == cProg2 {
// 		gLastMNSyncStatus = cProg3
// 		return cProg3
// 	} else if LIndicator == cProg3 {
// 		gLastMNSyncStatus = cProg4
// 		return cProg4
// 	} else if LIndicator == cProg4 {
// 		gLastMNSyncStatus = cProg5
// 		return cProg5
// 	} else if LIndicator == cProg5 {
// 		gLastMNSyncStatus = cProg6
// 		return cProg6
// 	} else if LIndicator == cProg6 {
// 		gLastMNSyncStatus = cProg7
// 		return cProg7
// 	} else if LIndicator == cProg7 {
// 		gLastMNSyncStatus = cProg8
// 		return cProg8
// 	} else if LIndicator == cProg8 || LIndicator == "" {
// 		gLastMNSyncStatus = cProg1
// 		return cProg1
// 	} else {
// 		gLastMNSyncStatus = cProg1
// 		return cProg1
// 	}
// }

// func getWalletStakingTxt(wi *be.DiviWalletInfoRespStruct) string {
// 	var fPercent float64
// 	if wi.Result.Balance > 10000 {
// 		fPercent = 100
// 	} else {
// 		fPercent = (wi.Result.Balance / 10000) * 100
// 	}

// 	fPercentStr := humanize.FormatFloat("###.##", fPercent)
// 	if fPercent < 75 {
// 		return "Staking %:        [" + fPercentStr + "](fg:red)"
// 	} else if (fPercent >= 76) && (fPercent <= 99) {
// 		return "Staking %:        [" + fPercentStr + "](fg:yellow)"
// 	} else {
// 		return "Staking %:        [" + fPercentStr + "](fg:green)"
// 	}

// }

// func getWalletSecurityStatusTxtDenarius(gi *be.DenariusGetInfoRespStruct) string {
// 	if gi.Result.UnlockedUntil == 0 {
// 		return "Security:         [Locked - Not Staking](fg:yellow)"
// 	} else if gi.Result.UnlockedUntil == -1 {
// 		return "Security:         [UNENCRYPTED](fg:red)"
// 	} else if gi.Result.UnlockedUntil > 0 {
// 		return "Security:         [Locked and Staking](fg:green)"
// 	} else {
// 		return "Security:         [checking...](fg:yellow)"
// 	}
// }

// func getWalletSecurityStatusTxtDGB(wi *be.DGBWalletInfoRespStruct) string {
// 	if wi.Result.UnlockedUntil == 0 {
// 		return "Security:         [Locked](fg:green)"
// 	} else if wi.Result.UnlockedUntil == -1 {
// 		return "Security:         [UNENCRYPTED](fg:red)"
// 	} else if wi.Result.UnlockedUntil > 0 {
// 		return "Security:         [Locked](fg:green)"
// 	} else {
// 		return "Security:         [checking...](fg:yellow)"
// 	}
// }

// func getWalletSecurityStatusTxtDVT(wi *be.DVTWalletInfoRespStruct) string {
// 	if wi.Result.UnlockedUntil == 0 {
// 		return "Security:         [Locked](fg:green)"
// 	} else if wi.Result.UnlockedUntil == -1 {
// 		return "Security:         [UNENCRYPTED](fg:red)"
// 	} else if wi.Result.UnlockedUntil > 0 {
// 		return "Security:         [Locked](fg:green)"
// 	} else {
// 		return "Security:         [checking...](fg:yellow)"
// 	}
// }

// func getWalletSecurityStatusTxtDivi(wi *be.DiviWalletInfoRespStruct) string {
// 	switch wi.Result.EncryptionStatus {
// 	case be.CWalletESLocked:
// 		return "Security:         [Locked - Not Staking](fg:yellow)"
// 	case be.CWalletESUnlocked:
// 		return "Security:         [UNLOCKED](fg:red)"
// 	case be.CWalletESUnlockedForStaking:
// 		return "Security:         [Locked and Staking](fg:green)"
// 	case be.CWalletESUnencrypted:
// 		return "Security:         [UNENCRYPTED](fg:red)"
// 	default:
// 		return "Security:         [checking...](fg:yellow)"
// 	}
// }

// func getWalletSecurityStatusTxtFeathercoin(wi *be.FeathercoinWalletInfoRespStruct) string {
// 	if wi.Result.UnlockedUntil == 0 {
// 		return "Security:         [Locked](fg:green)"
// 	} else if wi.Result.UnlockedUntil == -1 {
// 		return "Security:         [UNENCRYPTED](fg:red)"
// 	} else if wi.Result.UnlockedUntil > 0 {
// 		return "Security:         [Locked](fg:green)"
// 	} else {
// 		return "Security:         [checking...](fg:yellow)"
// 	}
// }

// func getWalletSecurityStatusTxtGRS(wi *be.GRSWalletInfoRespStruct) string {
// 	if wi.Result.UnlockedUntil == 0 {
// 		return "Security:         [Locked](fg:green)"
// 	} else if wi.Result.UnlockedUntil == -1 {
// 		return "Security:         [UNENCRYPTED](fg:red)"
// 	} else if wi.Result.UnlockedUntil > 0 {
// 		return "Security:         [Locked](fg:green)"
// 	} else {
// 		return "Security:         [checking...](fg:yellow)"
// 	}
// }

// func getWalletSecurityStatusTxtPhore(wi *be.PhoreWalletInfoRespStruct) string {
// 	if wi.Result.UnlockedUntil == 0 {
// 		return "Security:         [Locked - Not Staking](fg:yellow)"
// 	} else if wi.Result.UnlockedUntil == -1 {
// 		return "Security:         [UNENCRYPTED](fg:red)"
// 	} else if wi.Result.UnlockedUntil > 0 {
// 		return "Security:         [Locked and Staking](fg:green)"
// 	} else {
// 		return "Security:         [checking...](fg:yellow)"
// 	}
// }

// func getWalletSecurityStatusTxtPIVX(wi *be.PIVXWalletInfoRespStruct) string {
// 	if wi.Result.UnlockedUntil == 0 {
// 		return "Security:         [Locked - Not Staking](fg:yellow)"
// 	} else if wi.Result.UnlockedUntil == -1 {
// 		return "Security:         [UNENCRYPTED](fg:red)"
// 	} else if wi.Result.UnlockedUntil > 0 {
// 		return "Security:         [Locked and Staking](fg:green)"
// 	} else {
// 		return "Security:         [checking...](fg:yellow)"
// 	}
// }

// func getWalletSecurityStatusTxtRapids(wi *be.RapidsWalletInfoRespStruct) string {
// 	if wi.Result.UnlockedUntil == 0 {
// 		return "Security:         [Locked - Not Staking](fg:yellow)"
// 	} else if wi.Result.UnlockedUntil == -1 {
// 		return "Security:         [UNENCRYPTED](fg:red)"
// 	} else if wi.Result.UnlockedUntil > 0 {
// 		return "Security:         [Locked and Staking](fg:green)"
// 	} else {
// 		return "Security:         [checking...](fg:yellow)"
// 	}
// }

// func getWalletSecurityStatusTxtRDD(wi *be.RDDWalletInfoRespStruct) string {
// 	if wi.Result.UnlockedUntil == 0 {
// 		return "Security:         [Locked](fg:green)"
// 	} else if wi.Result.UnlockedUntil == -1 {
// 		return "Security:         [UNENCRYPTED](fg:red)"
// 	} else if wi.Result.UnlockedUntil > 0 {
// 		return "Security:         [Locked and Staking](fg:green)"
// 	} else {
// 		return "Security:         [checking...](fg:yellow)"
// 	}
// }

// func getWalletSecurityStatusTxtTrezarcoin(wi *be.TrezarcoinWalletInfoRespStruct) string {
// 	if wi.Result.UnlockedUntil == 0 {
// 		return "Security:         [Locked - Not Staking](fg:yellow)"
// 	} else if wi.Result.UnlockedUntil == -1 {
// 		return "Security:         [UNENCRYPTED](fg:red)"
// 	} else if wi.Result.UnlockedUntil > 0 {
// 		return "Security:         [Locked and Staking](fg:green)"
// 	} else {
// 		return "Security:         [checking...](fg:yellow)"
// 	}
// }

// func getWalletSecurityStatusTxtVTC(wi *be.VTCWalletInfoRespStruct) string {
// 	if wi.Result.UnlockedUntil == 0 {
// 		return "Security:         [Locked](fg:green)"
// 	} else if wi.Result.UnlockedUntil == -1 {
// 		return "Security:         [UNENCRYPTED](fg:red)"
// 	} else if wi.Result.UnlockedUntil > 0 {
// 		return "Security:         [Locked](fg:green)"
// 	} else {
// 		return "Security:         [checking...](fg:yellow)"
// 	}
// }

// func getDiviLotteryInfo(cliConf *be.ConfStruct) (be.DiviLotteryRespStruct, error) {
// 	var respStruct be.DiviLotteryRespStruct

// 	resp, err := http.Get("https://statbot.neist.io/api/v1/statbot")
// 	if err != nil {
// 		return respStruct, err
// 	}
// 	defer resp.Body.Close()

// 	body, err := ioutil.ReadAll(resp.Body)
// 	if err != nil {
// 		return respStruct, err
// 	}
// 	err = json.Unmarshal(body, &respStruct)
// 	if err != nil {
// 		return respStruct, err
// 	}
// 	return respStruct, errors.New("unable to getDiviLotteryInfo")
// }

// func getNetworkDifficultyInfo(pt be.ProjectType) (float64, float64, error) {
// 	var coin string
// 	// https://chainz.cryptoid.info/ftc/api.dws?q=getdifficulty

// 	switch pt {
// 	case be.PTBitcoinPlus:
// 		coin = "xbc"
// 	case be.PTDenarius:
// 		coin = "d"
// 	case be.PTDigiByte:
// 		coin = "dgb"
// 	case be.PTDivi:
// 		coin = "divi"
// 	case be.PTFeathercoin:
// 		coin = "ftc"
// 	case be.PTGroestlcoin:
// 		coin = "grs"
// 	case be.PTPIVX:
// 		coin = "pivx"
// 	case be.PTVertcoin:
// 		coin = "vtc"
// 	default:
// 		return 0, 0, errors.New("unable to determine project type")
// 	}

// 	resp, err := http.Get("https://chainz.cryptoid.info/" + coin + "/api.dws?q=getdifficulty")
// 	if err != nil {
// 		return 0, 0, err
// 	}
// 	defer resp.Body.Close()

// 	body, err := ioutil.ReadAll(resp.Body)
// 	if err != nil {
// 		return 0, 0, err
// 	}

// 	var fGood float64
// 	var fWarning float64
// 	// Now calculate the correct levels...
// 	if fDiff, err := strconv.ParseFloat(string(body), 32); err == nil {
// 		fGood = fDiff * 0.75
// 		fWarning = fDiff * 0.50
// 	}
// 	return fGood, fWarning, nil
// }

// func getNetworkDifficultyTxtDVT(difficulty, good, warn float64) string {
// 	var s string
// 	if difficulty > 1000 {
// 		s = humanize.FormatFloat("#.#", difficulty/1000) + "k"
// 	} else {
// 		s = humanize.Ftoa(difficulty)
// 	}

// 	// If Diff is less than 1, then we're not even calculating it properly yet...
// 	if difficulty < 1 {
// 		return "[Difficulty:  waiting...](fg:white)"
// 	}

// 	if difficulty >= good {
// 		return "Difficulty:  [" + s + "](fg:green)"
// 	} else if difficulty >= warn {
// 		return "Difficulty:  [" + s + "](fg:yellow)"
// 	} else {
// 		return "Difficulty:  [" + s + "](fg:red)"
// 	}
// }

// func getNetworkDifficultyTxtDGB(difficulty, good, warn float64) string {
// 	var s string
// 	if difficulty > 1000 {
// 		s = humanize.FormatFloat("#.#", difficulty/1000) + "k"
// 	} else {
// 		s = humanize.Ftoa(difficulty)
// 	}

// 	// If Diff is less than 1, then we're not even calculating it properly yet..
// 	if difficulty < 1 {
// 		return "[Difficulty:  waiting...](fg:white)"
// 	}

// 	if difficulty >= good {
// 		return "Difficulty:  [" + s + "](fg:green)"
// 	} else if difficulty >= warn {
// 		return "Difficulty:  [" + s + "](fg:yellow)"
// 	} else {
// 		return "Difficulty:  [" + s + "](fg:red)"
// 	}
// }

// func getNetworkDifficultyTxtDivi(difficulty, good, warn float64) string {
// 	var s string
// 	if difficulty > 1000 {
// 		s = humanize.FormatFloat("#.#", difficulty/1000) + "k"
// 	} else {
// 		s = humanize.Ftoa(difficulty)
// 	}
// 	if difficulty >= good {
// 		return "Difficulty:  [" + s + "](fg:green)"
// 	} else if difficulty >= warn {
// 		return "Difficulty:  [" + s + "](fg:yellow)"
// 	} else {
// 		return "Difficulty:  [" + s + "](fg:red)"
// 	}
// }

// func getNetworkDifficultyTxtFeathercoin(difficulty, good, warn float64) string {
// 	var s string
// 	if difficulty > 1000 {
// 		s = humanize.FormatFloat("#.#", difficulty/1000) + "k"
// 	} else {
// 		s = humanize.Ftoa(difficulty)
// 	}

// 	// If Diff is less than 1, then we're not even calculating it properly yet...
// 	if difficulty < 1 {
// 		return "[Difficulty:  waiting...](fg:white)"
// 	}

// 	if difficulty >= good {
// 		return "Difficulty:  [" + s + "](fg:green)"
// 	} else if difficulty >= warn {
// 		return "Difficulty:  [" + s + "](fg:yellow)"
// 	} else {
// 		return "Difficulty:  [" + s + "](fg:red)"
// 	}
// }

// func getNetworkDifficultyTxtGRS(difficulty, good, warn float64) string {
// 	var s string
// 	if difficulty > 1000 {
// 		s = humanize.FormatFloat("#.#", difficulty/1000) + "k"
// 	} else {
// 		s = humanize.Ftoa(difficulty)
// 	}

// 	// If Diff is less than 1, then we're not even calculating it properly yet...
// 	if difficulty < 1 {
// 		return "[Difficulty:  waiting...](fg:white)"
// 	}

// 	if difficulty >= good {
// 		return "Difficulty:  [" + s + "](fg:green)"
// 	} else if difficulty >= warn {
// 		return "Difficulty:  [" + s + "](fg:yellow)"
// 	} else {
// 		return "Difficulty:  [" + s + "](fg:red)"
// 	}
// }

// func getNetworkDifficultyTxtPhore(difficulty, good, warn float64) string {
// 	var s string
// 	if difficulty > 1000 {
// 		s = humanize.FormatFloat("#.#", difficulty/1000) + "k"
// 	} else {
// 		s = humanize.Ftoa(difficulty)
// 	}
// 	if difficulty >= good {
// 		return "Difficulty:  [" + s + "](fg:green)"
// 	} else if difficulty >= warn {
// 		return "[Difficulty:  " + s + "](fg:yellow)"
// 	} else {
// 		return "[Difficulty:  " + s + "](fg:red)"
// 	}
// }

// func getNetworkDifficultyTxtPIVX(difficulty, good, warn float64) string {
// 	var s string
// 	if difficulty > 1000 {
// 		s = humanize.FormatFloat("#.#", difficulty/1000) + "k"
// 	} else {
// 		s = humanize.Ftoa(difficulty)
// 	}
// 	if difficulty >= good {
// 		return "Difficulty:  [" + s + "](fg:green)"
// 	} else if difficulty >= warn {
// 		return "Difficulty:  [" + s + "](fg:yellow)"
// 	} else {
// 		return "Difficulty:  [" + s + "](fg:red)"
// 	}
// }

// func getNetworkDifficultyTxtXBC(difficulty, good, warn float64) string {
// 	var s string
// 	if difficulty > 1000 {
// 		s = humanize.FormatFloat("#.#", difficulty/1000) + "k"
// 	} else {
// 		s = humanize.Ftoa(difficulty)
// 	}

// 	// If Diff is less than 1, then we're not even calculating it properly yet...
// 	//if difficulty < 1 {
// 	//	return "[Difficulty:  waiting...](fg:white)"
// 	//}

// 	if difficulty >= good {
// 		return "Difficulty:  [" + s + "](fg:green)"
// 	} else if difficulty >= warn {
// 		return "Difficulty:  [" + s + "](fg:yellow)"
// 	} else {
// 		return "Difficulty:  [" + s + "](fg:red)"
// 	}
// }

// func getPrivateKeyNew(cliConf *be.ConfStruct) (hdinfoRespStruct, error) {
// 	attempts := 5
// 	waitingStr := "Attempt to Get Private Key..."
// 	var respStruct hdinfoRespStruct

// 	for i := 1; i < 5; i++ {
// 		fmt.Printf("\r"+waitingStr+" %d/"+strconv.Itoa(attempts), i)

// 		body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"dumphdinfo\",\"params\":[]}")
// 		req, err := http.NewRequest("POST", "http://"+cliConf.ServerIP+":"+cliConf.Port, body)
// 		if err != nil {
// 			return respStruct, err
// 		}
// 		req.SetBasicAuth(cliConf.RPCuser, cliConf.RPCpassword)
// 		req.Header.Set("Content-Type", "text/plain;")

// 		resp, err := http.DefaultClient.Do(req)
// 		if err != nil {
// 			return respStruct, err
// 		}
// 		defer resp.Body.Close()
// 		bodyResp, err := ioutil.ReadAll(resp.Body)
// 		if err != nil {
// 			return respStruct, err
// 		}
// 		// Check to make sure we are not loading the wallet
// 		if bytes.Contains(bodyResp, []byte("Loading wallet...")) {
// 			var errStruct be.GenericRespStruct
// 			err = json.Unmarshal(bodyResp, &errStruct)
// 			if err != nil {
// 				return respStruct, err
// 			}
// 			fmt.Println(errStruct.Error)
// 			time.Sleep(3 * time.Second)
// 		} else {

// 			err = json.Unmarshal(bodyResp, &respStruct)
// 			if err != nil {
// 				return respStruct, err
// 			}
// 		}
// 	}
// 	return respStruct, nil
// }

// func getWalletSeedRecoveryResp() string {
// 	reader := bufio.NewReader(os.Stdin)
// 	fmt.Println("\n\n*** WARNING ***" + "\n\n" +
// 		"You haven't provided confirmation that you've backed up your recovery seed!\n\n" +
// 		"This is *extremely* important as it's the only way of recovering your wallet in the future\n\n" +
// 		"To (d)isplay your recovery seed now press: d, to (c)onfirm that you've backed it up press: c, or to (m)ove on, press: m\n\n" +
// 		"Please enter: [d/c/m]")
// 	resp, _ := reader.ReadString('\n')
// 	resp = strings.ReplaceAll(resp, "\n", "")
// 	return resp
// }

// func getWalletSeedRecoveryConfirmationResp() bool {
// 	reader := bufio.NewReader(os.Stdin)
// 	fmt.Println("Please enter the response: " + be.CSeedStoredSafelyStr)
// 	resp, _ := reader.ReadString('\n')
// 	if resp == be.CSeedStoredSafelyStr+"\n" {
// 		return true
// 	}

// 	return false
// }

// func updateTransactionsXBC(trans *be.XBCListTransactions, pt *widgets.Table) {
// 	pt.Rows = [][]string{
// 		[]string{" Date", " Category", " Amount", " Confirmations"},
// 	}

// 	// Record whether any of the transactions have 0 conf (so that we can display the boarder as yellow)
// 	bYellowBoarder := false

// 	for i := len(trans.Result) - 1; i >= 0; i-- {
// 		// Check to make sure the confirmations count is higher than -1
// 		if trans.Result[i].Confirmations < 0 {
// 			continue
// 		}

// 		if trans.Result[i].Confirmations < 1 {
// 			bYellowBoarder = true
// 		}
// 		iTime, err := strconv.ParseInt(strconv.Itoa(trans.Result[i].Blocktime), 10, 64)
// 		if err != nil {
// 			panic(err)
// 		}
// 		tm := time.Unix(iTime, 0)
// 		sCat := getCategorySymbol(trans.Result[i].Category)
// 		tAmountStr := humanize.FormatFloat("#,###.####", trans.Result[i].Amount)
// 		sColour := getCategoryColour(trans.Result[i].Category)
// 		pt.Rows = append(pt.Rows, []string{
// 			" [" + tm.Format("2006-01-02 15:04"+"](fg:"+sColour+")"),
// 			" [" + sCat + "](fg:" + sColour + ")",
// 			" [" + tAmountStr + "](fg:" + sColour + ")",
// 			" [" + strconv.Itoa(trans.Result[i].Confirmations) + "](fg:" + sColour + ")"})

// 		if i > 10 {
// 			break
// 		}
// 	}
// 	if bYellowBoarder {
// 		pt.BorderStyle.Fg = ui.ColorYellow
// 	} else {
// 		pt.BorderStyle.Fg = ui.ColorGreen
// 	}
// }

// func updateTransactionsDenarius(trans *be.DenariusListTransactions, pt *widgets.Table) {
// 	pt.Rows = [][]string{
// 		[]string{" Date", " Category", " Amount", " Confirmations"},
// 	}

// 	// Record whether any of the transactions have 0 conf (so that we can display the boarder as yellow)
// 	bYellowBoarder := false

// 	for i := len(trans.Result) - 1; i >= 0; i-- {
// 		// Check to make sure the confirmations count is higher than -1.
// 		if trans.Result[i].Confirmations < 0 {
// 			continue
// 		}

// 		if trans.Result[i].Confirmations < 1 {
// 			bYellowBoarder = true
// 		}
// 		iTime, err := strconv.ParseInt(strconv.Itoa(trans.Result[i].Blocktime), 10, 64)
// 		if err != nil {
// 			panic(err)
// 		}
// 		tm := time.Unix(iTime, 0)
// 		sCat := getCategorySymbol(trans.Result[i].Category)

// 		tAmountStr := ""
// 		if trans.Result[i].Category == "generate" {
// 			tAmountStr = humanize.FormatFloat("#,###.####", trans.Result[i].Reward)
// 		} else {
// 			tAmountStr = humanize.FormatFloat("#,###.####", trans.Result[i].Amount)
// 		}
// 		sColour := getCategoryColour(trans.Result[i].Category)
// 		pt.Rows = append(pt.Rows, []string{
// 			" [" + tm.Format("2006-01-02 15:04"+"](fg:"+sColour+")"),
// 			" [" + sCat + "](fg:" + sColour + ")",
// 			" [" + tAmountStr + "](fg:" + sColour + ")",
// 			" [" + strconv.Itoa(trans.Result[i].Confirmations) + "](fg:" + sColour + ")"})

// 		if i > 10 {
// 			break
// 		}
// 	}
// 	if bYellowBoarder {
// 		pt.BorderStyle.Fg = ui.ColorYellow
// 	} else {
// 		pt.BorderStyle.Fg = ui.ColorGreen
// 	}
// }

// func updateTransactionsDGB(trans *be.DGBListTransactions, pt *widgets.Table) {
// 	pt.Rows = [][]string{
// 		[]string{" Date", " Category", " Amount", " Confirmations"},
// 	}

// 	// Record whether any of the transactions have 0 conf (so that we can display the boarder as yellow)
// 	bYellowBoarder := false

// 	for i := len(trans.Result) - 1; i >= 0; i-- {
// 		// Check to make sure the confirmations count is higher than -1
// 		if trans.Result[i].Confirmations < 0 {
// 			continue
// 		}

// 		if trans.Result[i].Confirmations < 1 {
// 			bYellowBoarder = true
// 		}
// 		iTime, err := strconv.ParseInt(strconv.Itoa(trans.Result[i].Blocktime), 10, 64)
// 		if err != nil {
// 			panic(err)
// 		}
// 		tm := time.Unix(iTime, 0)
// 		sCat := getCategorySymbol(trans.Result[i].Category)
// 		tAmountStr := humanize.FormatFloat("#,###.##", trans.Result[i].Amount)
// 		sColour := getCategoryColour(trans.Result[i].Category)
// 		pt.Rows = append(pt.Rows, []string{
// 			" [" + tm.Format("2006-01-02 15:04"+"](fg:"+sColour+")"),
// 			" [" + sCat + "](fg:" + sColour + ")",
// 			" [" + tAmountStr + "](fg:" + sColour + ")",
// 			" [" + strconv.Itoa(trans.Result[i].Confirmations) + "](fg:" + sColour + ")"})

// 		if i > 10 {
// 			break
// 		}
// 	}
// 	if bYellowBoarder {
// 		pt.BorderStyle.Fg = ui.ColorYellow
// 	} else {
// 		pt.BorderStyle.Fg = ui.ColorGreen
// 	}
// }

// func updateTransactionsDIVI(trans *be.DiviListTransactions, pt *widgets.Table) {
// 	pt.Rows = [][]string{
// 		[]string{" Date", " Category", " Amount", " Confirmations"},
// 	}

// 	// Record whether any of the transactions have 0 conf (so that we can display the boarder as yellow)
// 	bYellowBoarder := false

// 	for i := len(trans.Result) - 1; i >= 0; i-- {
// 		// Check to make sure the confirmations count is higher than -1
// 		if trans.Result[i].Confirmations < 0 {
// 			continue
// 		}

// 		if trans.Result[i].Confirmations < 1 {
// 			bYellowBoarder = true
// 		}
// 		iTime, err := strconv.ParseInt(strconv.Itoa(trans.Result[i].Blocktime), 10, 64)
// 		if err != nil {
// 			panic(err)
// 		}
// 		tm := time.Unix(iTime, 0)
// 		sCat := getCategorySymbol(trans.Result[i].Category)
// 		tAmountStr := humanize.FormatFloat("#,###.##", trans.Result[i].Amount)
// 		sColour := getCategoryColour(trans.Result[i].Category)
// 		pt.Rows = append(pt.Rows, []string{
// 			" [" + tm.Format("2006-01-02 15:04"+"](fg:"+sColour+")"),
// 			" [" + sCat + "](fg:" + sColour + ")",
// 			" [" + tAmountStr + "](fg:" + sColour + ")",
// 			" [" + strconv.Itoa(trans.Result[i].Confirmations) + "](fg:" + sColour + ")"})

// 		if i > 10 {
// 			break
// 		}
// 	}
// 	if bYellowBoarder {
// 		pt.BorderStyle.Fg = ui.ColorYellow
// 	} else {
// 		pt.BorderStyle.Fg = ui.ColorGreen
// 	}
// }

// func updateTransactionsFTC(trans *be.FTCListTransactions, pt *widgets.Table) {
// 	pt.Rows = [][]string{
// 		[]string{" Date", " Category", " Amount", " Confirmations"},
// 	}

// 	// Record whether any of the transactions have 0 conf (so that we can display the boarder as yellow)
// 	bYellowBoarder := false

// 	for i := len(trans.Result) - 1; i >= 0; i-- {
// 		// Check to make sure the confirmations count is higher than -1
// 		if trans.Result[i].Confirmations < 0 {
// 			continue
// 		}

// 		if trans.Result[i].Confirmations < 1 {
// 			bYellowBoarder = true
// 		}
// 		iTime, err := strconv.ParseInt(strconv.Itoa(trans.Result[i].Blocktime), 10, 64)
// 		if err != nil {
// 			panic(err)
// 		}
// 		tm := time.Unix(iTime, 0)
// 		sCat := getCategorySymbol(trans.Result[i].Category)
// 		tAmountStr := humanize.FormatFloat("#,###.##", trans.Result[i].Amount)
// 		sColour := getCategoryColour(trans.Result[i].Category)
// 		pt.Rows = append(pt.Rows, []string{
// 			" [" + tm.Format("2006-01-02 15:04"+"](fg:"+sColour+")"),
// 			" [" + sCat + "](fg:" + sColour + ")",
// 			" [" + tAmountStr + "](fg:" + sColour + ")",
// 			" [" + strconv.Itoa(trans.Result[i].Confirmations) + "](fg:" + sColour + ")"})

// 		if i > 10 {
// 			break
// 		}
// 	}
// 	if bYellowBoarder {
// 		pt.BorderStyle.Fg = ui.ColorYellow
// 	} else {
// 		pt.BorderStyle.Fg = ui.ColorGreen
// 	}
// }

// func updateTransactionsPHR(trans *be.PhoreListTransactions, pt *widgets.Table) {
// 	pt.Rows = [][]string{
// 		[]string{" Date", " Category", " Amount", " Confirmations"},
// 	}

// 	// Record whether any of the transactions have 0 conf (so that we can display the boarder as yellow)
// 	bYellowBoarder := false

// 	for i := len(trans.Result) - 1; i >= 0; i-- {
// 		// Check to make sure the confirmations count is higher than -1
// 		if trans.Result[i].Confirmations < 0 {
// 			continue
// 		}

// 		if trans.Result[i].Confirmations < 1 {
// 			bYellowBoarder = true
// 		}
// 		iTime, err := strconv.ParseInt(strconv.Itoa(trans.Result[i].Blocktime), 10, 64)
// 		if err != nil {
// 			panic(err)
// 		}
// 		tm := time.Unix(iTime, 0)
// 		sCat := getCategorySymbol(trans.Result[i].Category)
// 		tAmountStr := humanize.FormatFloat("#,###.##", trans.Result[i].Amount)
// 		sColour := getCategoryColour(trans.Result[i].Category)
// 		pt.Rows = append(pt.Rows, []string{
// 			" [" + tm.Format("2006-01-02 15:04"+"](fg:"+sColour+")"),
// 			" [" + sCat + "](fg:" + sColour + ")",
// 			" [" + tAmountStr + "](fg:" + sColour + ")",
// 			" [" + strconv.Itoa(trans.Result[i].Confirmations) + "](fg:" + sColour + ")"})

// 		if i > 10 {
// 			break
// 		}
// 	}
// 	if bYellowBoarder {
// 		pt.BorderStyle.Fg = ui.ColorYellow
// 	} else {
// 		pt.BorderStyle.Fg = ui.ColorGreen
// 	}
// }

// func updateTransactionsRDD(trans *be.RDDListTransactions, pt *widgets.Table) {
// 	pt.Rows = [][]string{
// 		[]string{" Date", " Category", " Amount", " Confirmations"},
// 	}

// 	// Record whether any of the transactions have 0 conf (so that we can display the boarder as yellow)
// 	bYellowBoarder := false

// 	for i := len(trans.Result) - 1; i >= 0; i-- {
// 		if trans.Result[i].Confirmations < 1 {
// 			bYellowBoarder = true
// 		}
// 		iTime, err := strconv.ParseInt(strconv.Itoa(trans.Result[i].Blocktime), 10, 64)
// 		if err != nil {
// 			panic(err)
// 		}
// 		tm := time.Unix(iTime, 0)
// 		sCat := getCategorySymbol(trans.Result[i].Category)
// 		tAmountStr := humanize.FormatFloat("#,###.##", trans.Result[i].Amount)
// 		sColour := getCategoryColour(trans.Result[i].Category)
// 		pt.Rows = append(pt.Rows, []string{
// 			" [" + tm.Format("2006-01-02 15:04"+"](fg:"+sColour+")"),
// 			" [" + sCat + "](fg:" + sColour + ")",
// 			" [" + tAmountStr + "](fg:" + sColour + ")",
// 			" [" + strconv.Itoa(trans.Result[i].Confirmations) + "](fg:" + sColour + ")"})

// 		if i > 10 {
// 			break
// 		}
// 	}
// 	if bYellowBoarder {
// 		pt.BorderStyle.Fg = ui.ColorYellow
// 	} else {
// 		pt.BorderStyle.Fg = ui.ColorGreen
// 	}
// }

// func updateTransactionsTZC(trans *be.TZCListTransactionsRespStruct, pt *widgets.Table) {
// 	pt.Rows = [][]string{
// 		[]string{" Date", " Category", " Amount", " Confirmations"},
// 	}

// 	// Record whether any of the transactions have 0 conf (so that we can display the boarder as yellow)
// 	bYellowBoarder := false

// 	for i := len(trans.Result) - 1; i >= 0; i-- {
// 		// Check to make sure the confirmations count is higher than -1
// 		if trans.Result[i].Confirmations < 0 {
// 			continue
// 		}

// 		if trans.Result[i].Confirmations < 1 {
// 			bYellowBoarder = true
// 		}
// 		iTime, err := strconv.ParseInt(strconv.Itoa(trans.Result[i].Blocktime), 10, 64)
// 		if err != nil {
// 			panic(err)
// 		}
// 		tm := time.Unix(iTime, 0)
// 		sCat := getCategorySymbol(trans.Result[i].Category)
// 		tAmountStr := humanize.FormatFloat("#,###.##", trans.Result[i].Amount)
// 		sColour := getCategoryColour(trans.Result[i].Category)
// 		pt.Rows = append(pt.Rows, []string{
// 			" [" + tm.Format("2006-01-02 15:04"+"](fg:"+sColour+")"),
// 			" [" + sCat + "](fg:" + sColour + ")",
// 			" [" + tAmountStr + "](fg:" + sColour + ")",
// 			" [" + strconv.Itoa(trans.Result[i].Confirmations) + "](fg:" + sColour + ")"})

// 		if i > 10 {
// 			break
// 		}
// 	}
// 	if bYellowBoarder {
// 		pt.BorderStyle.Fg = ui.ColorYellow
// 	} else {
// 		pt.BorderStyle.Fg = ui.ColorGreen
// 	}
// }

// // func getWalletStatusStruct(token string) (m.WalletStatusStruct, error) {
// // 	ws := m.WalletRequestStruct{}
// // 	ws.WalletRequest = gwc.CWalletRequestGetWalletStatus
// // 	var respStruct m.WalletStatusStruct
// // 	waitingStr := "Attempt..."
// // 	attempts := 5
// // 	requestBody, err := json.Marshal(ws)
// // 	if err != nil {
// // 		return respStruct, err
// // 	}

// // 	for i := 1; i < 5; i++ {
// // 		fmt.Printf("\r"+waitingStr+" %d/"+strconv.Itoa(attempts), i)

// // 		// We're going to send a request off, and then read the json response
// // 		//_, _ = http.Post("http://127.0.0.1:4000/server/", "application/json", bytes.NewBuffer(requestBody))
// // 		resp, err := http.Post("http://127.0.0.1:4000/wallet/", "application/json", bytes.NewBuffer(requestBody))
// // 		if err != nil {
// // 			return respStruct, err
// // 		}
// // 		defer resp.Body.Close()

// // 		body, err := ioutil.ReadAll(resp.Body)
// // 		if err != nil {
// // 			return respStruct, err
// // 		}
// // 		err = json.Unmarshal(body, &respStruct)
// // 		if err != nil {
// // 			return respStruct, err
// // 		}

// // 		if err == nil && respStruct.ResponseCode == gwc.NoServerError {
// // 			return respStruct, nil
// // 		} else {
// // 			time.Sleep(1 * time.Second)
// // 		}
// // 	}

// // 	return respStruct, errors.New("Unable to retrieve WalletStatus from server...")
// // }

// // func getToken() (string, error) {
// // 	reqStruct := m.ServerRequestStruct{}
// // 	reqStruct.ServerRequest = "GenerateToken"
// // 	var respStruct m.TokenResponseStruct
// // 	waitingStr := "Attempt..."
// // 	attempts := 5
// // 	requestBody, err := json.Marshal(reqStruct)
// // 	if err != nil {
// // 		return "", err
// // 	}
// // 	for i := 1; i < 5; i++ {
// // 		fmt.Printf("\r"+waitingStr+" %d/"+strconv.Itoa(attempts), i)
// // 		// We're going to send a request off, and then read the json response
// // 		//_, _ = http.Post("http://127.0.0.1:4000/server/", "application/json", bytes.NewBuffer(requestBody))
// // 		resp, err := http.Post("http://127.0.0.1:4000/server/", "application/json", bytes.NewBuffer(requestBody))
// // 		if err != nil {
// // 			return "", err
// // 		}
// // 		defer resp.Body.Close()
// // 		body, err := ioutil.ReadAll(resp.Body)
// // 		if err != nil {
// // 			return "", err
// // 		}
// // 		err = json.Unmarshal(body, &respStruct)
// // 		if err != nil {
// // 			return "", err
// // 		}
// // 		if err == nil && respStruct.ResponseCode == gwc.NoServerError {
// // 			return respStruct.Token, nil
// // 		} else {
// // 			time.Sleep(1 * time.Second)
// // 		}
// // 		return respStruct.Token, nil
// // 	}
// // 	return "", errors.New("Unable to retrieve Token from server...")
// // }
