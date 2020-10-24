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
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"

	"io/ioutil"
	"log"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/dustin/go-humanize"
	"github.com/spf13/cobra"
	"github.com/theckman/yacspin"

	_ "github.com/AlecAivazis/survey/v2"
	ui "github.com/gizak/termui/v3"
	"github.com/gizak/termui/v3/widgets"
	be "richardmace.co.uk/boxwallet/cmd/cli/cmd/bend"
	//m "richardmace.co.uk/boxwallet/pkg/models"
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

var gGetBCInfoCount int = 0
var gBCSyncStuckCount int = 0
var gWalletRICount int = 0
var gLastBCSyncPosStr string = ""
var gDiffGood float64
var gDiffWarning float64

// General counters
var gTickerCounter int = 0
var gCheckWalletHealthCounter int = 0

//var lastRMNAssets int = 0
var NextLotteryStored string = ""
var NextLotteryCounter int = 0

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
		fmt.Println("  ____          __          __   _ _      _   \n |  _ \\         \\ \\        / /  | | |    | |  \n | |_) | _____  _\\ \\  /\\  / /_ _| | | ___| |_ \n |  _ < / _ \\ \\/ /\\ \\/  \\/ / _` | | |/ _ \\ __|\n | |_) | (_) >  <  \\  /\\  / (_| | | |  __/ |_ \n |____/ \\___/_/\\_\\  \\/  \\/ \\__,_|_|_|\\___|\\__|\n                                              \n                                              ")
		// Lets load our config file first, to see if the user has made their coin choice...
		cliConf, err := be.GetConfigStruct("", true)
		if err != nil {
			log.Fatal("Unable to determine coin type. Please run " + be.CAppFilename + " coin" + err.Error())
			//log.Fatal("Unable to GetCLIConfStruct " + err.Error())
		}

		sCoinName, err := be.GetCoinName(be.APPTCLI)
		// sLogfileName, err := gwc.GetAppLogfileName()
		// if err != nil {
		// 	log.Fatal("Unable to GetAppLogfileName " + err.Error())
		// }

		//lfp := abf + sLogfileName

		sAppFileCLIName, err := be.GetAppFileName()
		if err != nil {
			log.Fatal("Unable to GetAppFileCLIName " + err.Error())
		}

		wRunning, err := confirmWalletReady()
		if err != nil {
			log.Fatal("Unable to determine if wallet is ready: " + err.Error())
		}

		coind, err := be.GetCoinDaemonFilename(be.APPTCLI)
		if err != nil {
			log.Fatalf("Unable to GetCoinDaemonFilename - %v", err)
		}
		if !wRunning {
			fmt.Println("")
			log.Fatal("Unable to communicate with the " + coind + " server. Please make sure the " + coind + " server is running, by running:\n\n" +
				"./" + sAppFileCLIName + " start\n\n")
		}

		// The first thing we need to check is to see if the wallet currently has amy addresses
		bWalletExists := false
		switch cliConf.ProjectType {
		case be.PTDivi:
			addresses, _ := be.ListReceivedByAddressDivi(&cliConf, false)
			if len(addresses.Result) > 0 {
				bWalletExists = true
			}
		case be.PTFeathercoin:
			addresses, _ := be.ListReceivedByAddressFeathercoin(&cliConf, false)
			if len(addresses.Result) > 0 {
				bWalletExists = true
			}
		case be.PTPhore:
			addresses, _ := be.ListReceivedByAddressPhore(&cliConf, false)
			if len(addresses.Result) > 0 {
				bWalletExists = true
			}
		case be.PTTrezarcoin:
			addresses, _ := be.ListReceivedByAddressTrezarcoin(&cliConf, false)
			if len(addresses.Result) > 0 {
				bWalletExists = true
			}
		default:
			log.Fatalf("Unable to determine project type")
		}

		pw := ""
		if !cliConf.UserConfirmedWalletBU && bWalletExists {
			// We need to work out what coin we are, to see what options we have.
			switch cliConf.ProjectType {
			case be.PTDivi:
				wet, err := be.GetWalletEncryptionStatus()
				if err != nil {
					log.Fatalf("Unable to determine wallet encryption status")
				}
				if wet == be.WETLocked {
					pw = be.GetWalletEncryptionPassword()
				}
				bConfirmedBU, err := HandleWalletBUDivi(pw)
				cliConf.UserConfirmedWalletBU = bConfirmedBU
				if err := be.SetConfigStruct("", cliConf); err != nil {
					log.Fatalf("Unable to SetCLIConfStruct(): failed with %s\n", err)
				}
			case be.PTFeathercoin:
			case be.PTPhore:
			case be.PTTrezarcoin:
			default:
				log.Fatalf("Unable to determine project type")
			}
		}

		// Check wallet encryption status
		bWalletNeedsEncrypting := false
		switch cliConf.ProjectType {
		case be.PTDivi:
			wi, err := be.GetWalletInfoDivi(&cliConf)
			if err != nil {
				log.Fatal("Unable to perform GetWalletInfoDivi " + err.Error())
			}

			if wi.Result.EncryptionStatus == be.CWalletESUnencrypted {
				bWalletNeedsEncrypting = true
			}
		case be.PTFeathercoin:
			wi, err := be.GetWalletInfoFeathercoin(&cliConf)
			if err != nil {
				log.Fatal("Unable to perform GetWalletInfoFeathercoin " + err.Error())
			}

			if wi.Result.UnlockedUntil < 0 {
				bWalletNeedsEncrypting = true
			}
		case be.PTPhore:
			wi, err := be.GetWalletInfoPhore(&cliConf)
			if err != nil {
				log.Fatal("Unable to perform GetWalletInfoPhore " + err.Error())
			}

			if wi.Result.UnlockedUntil < 0 {
				bWalletNeedsEncrypting = true
			}
		case be.PTTrezarcoin:
			wi, err := be.GetWalletInfoTrezarcoin(&cliConf)
			if err != nil {
				log.Fatal("Unable to perform GetWalletInfoTrezarcoin " + err.Error())
			}

			if wi.Result.UnlockedUntil < 0 {
				bWalletNeedsEncrypting = true
			}
		default:
			log.Fatalf("Unable to determine project type")
		}

		if bWalletNeedsEncrypting {
			be.ClearScreen()
			resp := be.GetWalletEncryptionResp()
			if resp == true {
				wep := be.GetPasswordToEncryptWallet()
				r, err := encryptWallet(&cliConf, wep)
				if err != nil {
					log.Fatalf("failed to encrypt wallet %s\n", err)
				}
				fmt.Println(r.Result)
				fmt.Println("Restarting wallet after encryption...")
				if err := be.RunCoinDaemon(false); err != nil {
					log.Fatalf("failed to run "+coind+": %v", err)
				}
			}
		}

		// Init display...

		if err := ui.Init(); err != nil {
			log.Fatalf("failed to initialize termui: %v", err)
		}
		defer ui.Close()

		pAbout := widgets.NewParagraph()
		pAbout.Title = "About"
		pAbout.SetRect(0, 0, 32, 4)
		pAbout.TextStyle.Fg = ui.ColorWhite
		pAbout.BorderStyle.Fg = ui.ColorGreen
		switch cliConf.ProjectType {
		case be.PTDivi:
			pAbout.Text = "  [" + be.CAppName + "    v" + be.CBWAppVersion + "](fg:white)\n" +
				"  [" + sCoinName + " Core    v" + be.CDiviCoreVersion + "](fg:white)\n\n"
		case be.PTFeathercoin:
			pAbout.Text = "  [" + be.CAppName + "          v" + be.CBWAppVersion + "](fg:white)\n" +
				"  [" + sCoinName + " Core   v" + be.CFeathercoinCoreVersion + "](fg:white)\n\n"
		case be.PTPhore:
			pAbout.Text = "  [" + be.CAppName + "    v" + be.CBWAppVersion + "](fg:white)\n" +
				"  [" + sCoinName + " Core   v" + be.CPhoreCoreVersion + "](fg:white)\n\n"
		case be.PTTrezarcoin:
			pAbout.Text = "  [" + be.CAppName + "         v" + be.CBWAppVersion + "](fg:white)\n" +
				"  [" + sCoinName + " Core   v" + be.CTrezarcoinCoreVersion + "](fg:white)\n\n"
		default:
			err = errors.New("unable to determine ProjectType")
		}

		pWallet := widgets.NewParagraph()
		pWallet.Title = "Wallet"
		pWallet.SetRect(33, 0, 84, 10)
		pWallet.TextStyle.Fg = ui.ColorWhite
		pWallet.BorderStyle.Fg = ui.ColorYellow
		switch cliConf.ProjectType {
		case be.PTDivi:
			pWallet.Text = "  Balance:          [waiting...](fg:yellow)\n" +
				"  Currency:         [waiting...](fg:yellow)\n" +
				"  Security:         [waiting...](fg:yellow)\n" +
				"  Staking %:	        [waiting...](fg:yellow)\n" +
				"  Actively Staking: [waiting...](fg:yellow)\n" +
				"  Next Lottery:     [waiting...](fg:yellow)\n" +
				"  Lottery tickets:	  [waiting...](fg:yellow)"
		case be.PTFeathercoin:
			pWallet.Text = "  Balance:          [waiting...](fg:yellow)\n" +
				"  Security:         [waiting...](fg:yellow)\n"
		case be.PTPhore:
			pWallet.Text = "  Balance:          [waiting...](fg:yellow)\n" +
				"  Security:         [waiting...](fg:yellow)\n" +
				"  Actively Staking: [waiting...](fg:yellow)\n"
		case be.PTTrezarcoin:
			pWallet.Text = "  Balance:          [waiting...](fg:yellow)\n" +
				"  Security:         [waiting...](fg:yellow)\n" +
				"  Actively Staking: [waiting...](fg:yellow)\n"
		default:
			err = errors.New("unable to determine ProjectType")
		}

		pTicker := widgets.NewParagraph()
		pTicker.Title = "Ticker"
		pTicker.SetRect(33, 0, 84, 9)
		pTicker.TextStyle.Fg = ui.ColorWhite
		pTicker.BorderStyle.Fg = ui.ColorYellow
		pTicker.Text = "  Price:        [checking...](fg:yellow)\n" +
			"  BTC:         [waiting...](fg:yellow)\n" +
			"  24Hr Chg:	        [waiting...](fg:yellow)\n" +
			"  Week Chg: [waiting...](fg:yellow)"

		pNetwork := widgets.NewParagraph()
		pNetwork.Title = "Network"
		pNetwork.SetRect(0, 10, 32, 4)
		pNetwork.TextStyle.Fg = ui.ColorWhite
		pNetwork.BorderStyle.Fg = ui.ColorWhite

		switch cliConf.ProjectType {
		case be.PTDivi:
			pNetwork.Text = "  Blocks:      [checking...](fg:yellow)\n" +
				"  Difficulty:  [checking...](fg:yellow)\n" +
				"  Blockchain:  [checking...](fg:yellow)\n" +
				"  Masternodes: [checking...](fg:yellow)"
		case be.PTFeathercoin:
			pNetwork.Text = "  Headers:     [checking...](fg:yellow)\n" +
				"  Blocks:      [checking...](fg:yellow)\n" +
				"  Difficulty:  [checking...](fg:yellow)\n" +
				"  Blockchain:  [checking...](fg:yellow)\n"
		case be.PTPhore:
			pNetwork.Text = "  Blocks:      [checking...](fg:yellow)\n" +
				"  Difficulty:  [checking...](fg:yellow)\n" +
				"  Blockchain:  [checking...](fg:yellow)\n" +
				"  Masternodes: [checking...](fg:yellow)"
		case be.PTTrezarcoin:
			pNetwork.Text = "  Blocks:      [checking...](fg:yellow)\n" +
				"  Difficulty:  [checking...](fg:yellow)\n" +
				"  Blockchain:  [checking...](fg:yellow)\n" +
				"  Masternodes: [checking...](fg:yellow)"
		default:
			err = errors.New("unable to determine ProjectType")
		}

		// var numSeconds int = -1
		updateParagraph := func(count int) {
			var bciDivi be.DiviBlockchainInfoRespStruct
			var bciFeathercoin be.FeathercoinBlockchainInfoRespStruct
			var bciPhore be.PhoreBlockchainInfoRespStruct
			var bciTrezarcoin be.TrezarcoinBlockchainInfoRespStruct
			//var gi be.GetInfoRespStruct
			var mnssDivi be.DiviMNSyncStatusRespStruct
			var mnssPhore be.PhoreMNSyncStatusRespStruct
			bFTCBlockchainIsSynced := false
			bTZCBlockchainIsSynced := false
			var ssDivi be.DiviStakingStatusRespStruct
			var ssPhore be.PhoreStakingStatusRespStruct
			var ssTrezarcoin be.TrezarcoinStakingInfoRespStruct
			var wiDivi be.DiviWalletInfoRespStruct
			var wiFeathercoin be.FeathercoinWalletInfoRespStruct
			var wiPhore be.PhoreWalletInfoRespStruct
			var wiTrezarcoin be.TrezarcoinWalletInfoRespStruct
			if gGetBCInfoCount == 0 || gGetBCInfoCount > cliConf.RefreshTimer {
				if gGetBCInfoCount > cliConf.RefreshTimer {
					gGetBCInfoCount = 1
				}
				switch cliConf.ProjectType {
				case be.PTDivi:
					bciDivi, _ = be.GetBlockchainInfoDivi(&cliConf)
				case be.PTFeathercoin:
					bciFeathercoin, _ = be.GetBlockchainInfoFeathercoin(&cliConf)
					if bciFeathercoin.Result.Verificationprogress > 0.9999 {
						bFTCBlockchainIsSynced = true
					}
				case be.PTPhore:
					bciPhore, _ = be.GetBlockchainInfoPhore(&cliConf)
				case be.PTTrezarcoin:
					bciTrezarcoin, _ = be.GetBlockchainInfoTrezarcoin(&cliConf)
					if bciTrezarcoin.Result.Verificationprogress > 0.9999 {
						bTZCBlockchainIsSynced = true
					}
				default:
					err = errors.New("unable to determine ProjectType")
				}
			} else {
				gGetBCInfoCount++
			}
			//gi, _ := diviGetInfo(&cliConf)

			// Check the blockchain sync health
			if err := checkHealth(&bciDivi); err != nil {
				log.Fatalf("Unable to check health: %v", err)
			}

			// Now, we only want to get this other stuff, when the blockchain has synced.
			switch cliConf.ProjectType {
			case be.PTDivi:
				if bciDivi.Result.Verificationprogress > 0.999 {
					mnssDivi, _ = be.GetMNSyncStatusDivi(&cliConf)
					ssDivi, _ = be.GetStakingStatusDivi(&cliConf)
					wiDivi, _ = be.GetWalletInfoDivi(&cliConf)
				}
			case be.PTFeathercoin:
				if bFTCBlockchainIsSynced {
					wiFeathercoin, _ = be.GetWalletInfoFeathercoin(&cliConf)
				}
			case be.PTPhore:
				if bciPhore.Result.Verificationprogress > 0.999 {
					mnssPhore, _ = be.GetMNSyncStatusPhore(&cliConf)
					ssPhore, _ = be.GetStakingStatusPhore(&cliConf)
					wiPhore, _ = be.GetWalletInfoPhore(&cliConf)
				}
			case be.PTTrezarcoin:
				if bTZCBlockchainIsSynced {
					ssTrezarcoin, _ = be.GetStakingInfoTrezarcoin(&cliConf)
					wiTrezarcoin, _ = be.GetWalletInfoTrezarcoin(&cliConf)
				}
			default:
				err = errors.New("unable to determine ProjectType")
			}

			// Decide what colour the network panel border should be...
			switch cliConf.ProjectType {
			case be.PTDivi:
				if mnssDivi.Result.IsBlockchainSynced {
					pNetwork.BorderStyle.Fg = ui.ColorGreen
				} else {
					pNetwork.BorderStyle.Fg = ui.ColorYellow
				}
			case be.PTFeathercoin:
				if bFTCBlockchainIsSynced {
					pNetwork.BorderStyle.Fg = ui.ColorGreen
				} else {
					pNetwork.BorderStyle.Fg = ui.ColorYellow
				}
			case be.PTPhore:
				if mnssPhore.Result.IsBlockchainSynced {
					pNetwork.BorderStyle.Fg = ui.ColorGreen
				} else {
					pNetwork.BorderStyle.Fg = ui.ColorYellow
				}
			case be.PTTrezarcoin:
				if bTZCBlockchainIsSynced {
					pNetwork.BorderStyle.Fg = ui.ColorGreen
				} else {
					pNetwork.BorderStyle.Fg = ui.ColorYellow
				}
			default:
				err = errors.New("unable to determine ProjectType")
			}

			// Populate the Network panel
			var sBlocks string
			var sDiff string
			var sBlockchainSync string
			var sHeaders string
			var sMNSync string
			switch cliConf.ProjectType {
			case be.PTDivi:
				sBlocks = be.GetNetworkBlocksTxtDivi(&bciDivi)
				sDiff = be.GetNetworkDifficultyTxtDivi(bciDivi.Result.Difficulty, gDiffGood, gDiffWarning)
				sBlockchainSync = be.GetBlockchainSyncTxtDivi(mnssDivi.Result.IsBlockchainSynced, &bciDivi)
				sMNSync = be.GetMNSyncStatusTxtDivi(&mnssDivi)
			case be.PTFeathercoin:
				sHeaders = be.GetNetworkHeadersTxtFeathercoin(&bciFeathercoin)
				sBlocks = be.GetNetworkBlocksTxtFeathercoin(&bciFeathercoin)
				sDiff = be.GetNetworkDifficultyTxtFeathercoin(bciFeathercoin.Result.Difficulty, gDiffGood, gDiffWarning)
				sBlockchainSync = be.GetBlockchainSyncTxtFeathercoin(bFTCBlockchainIsSynced, &bciFeathercoin)
			case be.PTPhore:
				sBlocks = be.GetNetworkBlocksTxtPhore(&bciPhore)
				sDiff = be.GetNetworkDifficultyTxtPhore(bciPhore.Result.Difficulty, gDiffGood, gDiffWarning)
				sBlockchainSync = be.GetBlockchainSyncTxtPhore(mnssPhore.Result.IsBlockchainSynced, &bciPhore)
				sMNSync = be.GetMNSyncStatusTxtPhore(&mnssPhore)
			case be.PTTrezarcoin:
				sBlocks = be.GetNetworkBlocksTxtTrezarcoin(&bciTrezarcoin)
				sDiff = be.GetNetworkDifficultyTxtTrezarcoin(bciTrezarcoin.Result.Difficulty, gDiffGood, gDiffWarning)
				sBlockchainSync = be.GetBlockchainSyncTxtTrezarcoin(bTZCBlockchainIsSynced, &bciTrezarcoin)
			default:
				err = errors.New("unable to determine ProjectType")
			}

			switch cliConf.ProjectType {
			case be.PTDivi:
				pNetwork.Text = "  " + sBlocks + "\n" +
					"  " + sDiff + "\n" +
					"  " + sBlockchainSync + "\n" +
					"  " + sMNSync
			case be.PTFeathercoin:
				pNetwork.Text = "  " + sHeaders + "\n" +
					"  " + sBlocks + "\n" +
					"  " + sDiff + "\n" +
					"  " + sBlockchainSync + "\n" +
					"  " + sMNSync
			case be.PTPhore:
				pNetwork.Text = "  " + sBlocks + "\n" +
					"  " + sDiff + "\n" +
					"  " + sBlockchainSync + "\n" +
					"  " + sMNSync
			case be.PTTrezarcoin:
				pNetwork.Text = "  " + sBlocks + "\n" +
					"  " + sDiff + "\n" +
					"  " + sBlockchainSync + "\n" +
					"  " + sMNSync
			default:
				pNetwork.Text = "  " + sBlocks + "\n" +
					"  " + sDiff + "\n" +
					"  " + sBlockchainSync + "\n" +
					"  " + sMNSync
			}

			// Populate the Wallet panel

			// Decide what colour the wallet panel border should be...

			switch cliConf.ProjectType {
			case be.PTDivi:
				wet := be.GetWalletSecurityStateDivi(&wiDivi)
				switch wet {
				case be.WETLocked:
					pWallet.BorderStyle.Fg = ui.ColorYellow
				case be.WETUnlocked:
					pWallet.BorderStyle.Fg = ui.ColorRed
				case be.WETUnlockedForStaking:
					pWallet.BorderStyle.Fg = ui.ColorGreen
				case be.WETUnencrypted:
					pWallet.BorderStyle.Fg = ui.ColorRed
				default:
					pWallet.BorderStyle.Fg = ui.ColorYellow
				}
			case be.PTFeathercoin:
				wet := be.GetWalletSecurityStateFeathercoin(&wiFeathercoin)
				switch wet {
				case be.WETLocked:
					pWallet.BorderStyle.Fg = ui.ColorYellow
				case be.WETUnlocked:
					pWallet.BorderStyle.Fg = ui.ColorRed
				case be.WETUnlockedForStaking:
					pWallet.BorderStyle.Fg = ui.ColorGreen
				case be.WETUnencrypted:
					pWallet.BorderStyle.Fg = ui.ColorRed
				default:
					pWallet.BorderStyle.Fg = ui.ColorYellow
				}
			case be.PTPhore:
				wet := be.GetWalletSecurityStatePhore(&wiPhore)
				switch wet {
				case be.WETLocked:
					pWallet.BorderStyle.Fg = ui.ColorYellow
				case be.WETUnlocked:
					pWallet.BorderStyle.Fg = ui.ColorRed
				case be.WETUnlockedForStaking:
					pWallet.BorderStyle.Fg = ui.ColorGreen
				case be.WETUnencrypted:
					pWallet.BorderStyle.Fg = ui.ColorRed
				default:
					pWallet.BorderStyle.Fg = ui.ColorYellow
				}
			case be.PTTrezarcoin:
				wet := be.GetWalletSecurityStateTrezarcoin(&wiTrezarcoin)
				switch wet {
				case be.WETLocked:
					pWallet.BorderStyle.Fg = ui.ColorYellow
				case be.WETUnlocked:
					pWallet.BorderStyle.Fg = ui.ColorRed
				case be.WETUnlockedForStaking:
					pWallet.BorderStyle.Fg = ui.ColorGreen
				case be.WETUnencrypted:
					pWallet.BorderStyle.Fg = ui.ColorRed
				default:
					pWallet.BorderStyle.Fg = ui.ColorYellow
				}
			default:
				err = errors.New("unable to determine ProjectType")
			}

			// Update the wallet display, if we're all synced up
			switch cliConf.ProjectType {
			case be.PTDivi:
				if bciDivi.Result.Verificationprogress > 0.9999 {
					pWallet.Text = "" + getBalanceInDiviTxt(&wiDivi) + "\n" +
						"  " + be.GetBalanceInCurrencyTxtDivi(&cliConf, &wiDivi) + "\n" +
						"  " + getWalletSecurityStatusTxtDivi(&wiDivi) + "\n" +
						"  " + getWalletStakingTxt(&wiDivi) + "\n" + //e.g. "15%" or "staking"
						"  " + getActivelyStakingTxtDivi(&ssDivi, &wiDivi) + "\n" + //e.g. "15%" or "staking"
						"  " + getNextLotteryTxt(&cliConf) + "\n" +
						"  " + "Lottery tickets:  0"
				}
			case be.PTFeathercoin:
				if bciFeathercoin.Result.Verificationprogress > 0.9999 {
					pWallet.Text = "" + getBalanceInFeathercoinTxt(&wiFeathercoin) + "\n" +
						"  " + getWalletSecurityStatusTxtFeathercoin(&wiFeathercoin) + "\n"
				}
			case be.PTPhore:
				if bciPhore.Result.Verificationprogress > 0.9999 {
					pWallet.Text = "" + getBalanceInPhoreTxt(&wiPhore) + "\n" +
						"  " + getWalletSecurityStatusTxtPhore(&wiPhore) + "\n" +
						"  " + getActivelyStakingTxtPhore(&ssPhore) + "\n" //e.g. "15%" or "staking"
				}
			case be.PTTrezarcoin:
				if bciTrezarcoin.Result.Verificationprogress > 0.9999 {
					pWallet.Text = "" + getBalanceInTrezarcoinTxt(&wiTrezarcoin) + "\n" +
						"  " + getWalletSecurityStatusTxtTrezarcoin(&wiTrezarcoin) + "\n" +
						"  " + getActivelyStakingTxtTrezarcoin(&ssTrezarcoin) + "\n" //e.g. "15%" or "staking"
				}
			default:
				err = errors.New("unable to determine ProjectType")
			}

			// Update ticker info every 30 seconds...
			if gTickerCounter == 0 || gTickerCounter > 30 {
				if gTickerCounter > 30 {
					gTickerCounter = 1
				}
				switch cliConf.ProjectType {
				case be.PTDivi:
					_ = be.UpdateTickerInfoDivi()
					// Now check to see which currency the user is interested in...
					switch cliConf.Currency {
					case "AUD":
						_ = be.UpdateAUDPriceInfo()
					case "GBP":
						_ = be.UpdateGBPPriceInfo()
					}
					_ = be.UpdateGBPPriceInfo()
					gDiffGood, gDiffWarning, _ = getNetworkDifficultyInfo(be.PTDivi)
				case be.PTFeathercoin:
					gDiffGood, gDiffWarning, _ = getNetworkDifficultyInfo(be.PTFeathercoin)
				case be.PTPhore:
					// todo do for Phore
				case be.PTTrezarcoin:
					// todo do for Trezarcoin
				default:
					err = errors.New("unable to determine ProjectType")
				}

			}
			gTickerCounter++

		}

		draw := func(count int) {
			ui.Render(pAbout, pWallet, pNetwork)
		}

		tickerCount := 1
		updateParagraph(tickerCount)
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
				updateParagraph(tickerCount)
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

func checkHealth(bci *be.DiviBlockchainInfoRespStruct) error {
	// This func will be called regularly and will check the health of the local wallet. It will...

	// If the blockchain verification is 0.99 or higher, than all so good, otherwise...
	if bci.Result.Verificationprogress > 0.99 {
		return nil
	}

	// If the block count is stuck at 100...
	if bci.Result.Blocks == 100 {
		// 20 * 3 = 3 minutes
		if gBCSyncStuckCount > 20*3 {
			if err := be.WalletFix(be.WFTReSync); err != nil {
				return fmt.Errorf("unable to perform wallet resync: %v", err)
			}
			return nil
		} else {
			gBCSyncStuckCount++
			return nil
		}
	}

	//// Check "bcSyncStuckCount" to see if it's higher than X, if it is, we know that we need to perform a -reindex, if not...
	//if gBCSyncStuckCount > 3600/3 {
	//	gBCSyncStuckCount = 0
	//	// First, let's see if we need to bring the big guns out...
	//	if gWalletRICount >= 1 {
	//		gWalletRICount = 0
	//		// We have already tried 1 -reindex so let's go for a hard fix with -resync.
	//		if err := be.WalletFix(be.WFTReSync); err != nil {
	//			return fmt.Errorf("unable to perform wallet resync: %v", err)
	//		}
	//
	//		return nil
	//	}
	//
	//	// We've been stuck at the same blockchain verification point for > 25...
	//	if err := be.WalletFix(be.WFTReIndex); err != nil {
	//		return fmt.Errorf("unable to perform wallet reindex: %v", err)
	//	}
	//	gWalletRICount++
	//	return nil
	//}

	//// Check what verification status it is, if it's the same as last time "BCLastVerificationStatus" then, inc a "BCSyncStatus" by 1
	//s := gwc.ConvertBCVerification(bci.Result.Verificationprogress)
	//if s == gLastBCSyncPosStr {
	//	// Check to make sure we are online, and if we are, bump the bcSyncStuckCount
	//	if gwc.WebIsReachable() {
	//		gBCSyncStuckCount++
	//	}
	//} else {
	//	gLastBCSyncPosStr = s
	//}

	return nil
}

func confirmWalletReady() (bool, error) {
	cliConf, err := be.GetConfigStruct("", true)
	if err != nil {
		return false, fmt.Errorf("unable to determine coin type. Please run "+be.CAppFilename+" coin: %v", err.Error())
	}

	// Lets make sure that we have a running daemon
	cfg := yacspin.Config{
		Frequency:       250 * time.Millisecond,
		CharSet:         yacspin.CharSets[43],
		Suffix:          "",
		SuffixAutoColon: true,
		Message:         " waiting for wallet to load...",
		StopCharacter:   "",
		StopColors:      []string{"fgGreen"},
	}

	spinner, err := yacspin.New(cfg)
	if err != nil {
		return false, fmt.Errorf("unable to initialise spinner - %v", err)
	}

	spinner.Start()

	coind, err := be.GetCoinDaemonFilename(be.APPTCLI)
	if err != nil {
		log.Fatalf("Unable to GetCoinDaemonFilename - %v", err)
	}
	switch cliConf.ProjectType {
	case be.PTDivi:
		gi, err := be.GetInfoDivi(&cliConf)
		if err != nil {
			if err := spinner.Stop(); err != nil {
			}
			return false, fmt.Errorf("Unable to communicate with the " + coind + " server.")
		}
		if gi.Result.Version == "" {
			return false, fmt.Errorf("unable to call getinfo %s\n", err)
		}
	case be.PTFeathercoin:
		gi, err := be.GetNetworkInfoFeathercoin(&cliConf)
		if err != nil {
			if err := spinner.Stop(); err != nil {
			}
			return false, fmt.Errorf("Unable to communicate with the " + coind + " server.")
		}
		if gi.Result.Version == 0 {
			return false, fmt.Errorf("unable to call getinfo %s\n", err)
		}
	case be.PTPhore:
		gi, err := be.GetInfoPhore(&cliConf)
		if err != nil {
			if err := spinner.Stop(); err != nil {
			}
			return false, fmt.Errorf("Unable to communicate with the " + coind + " server.")
		}
		if gi.Result.Version == 0 {
			return false, fmt.Errorf("unable to call getinfo %s\n", err)
		}
	case be.PTTrezarcoin:
		gi, err := be.GetInfoTrezarcoin(&cliConf)
		if err != nil {
			if err := spinner.Stop(); err != nil {
			}
			return false, fmt.Errorf("Unable to communicate with the " + coind + " server.")
		}
		if gi.Result.Version == 0 {
			return false, fmt.Errorf("unable to call getinfo %s\n", err)
		}
	default:
		return false, fmt.Errorf("unable to determine project type")
	}
	spinner.Stop()

	return true, nil
}

func encryptWallet(cliConf *be.ConfStruct, pw string) (be.GenericRespStruct, error) {
	var respStruct be.GenericRespStruct

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"encryptwallet\",\"params\":[\"" + pw + "\"]}")
	req, err := http.NewRequest("POST", "http://"+cliConf.ServerIP+":"+cliConf.Port, body)
	if err != nil {
		return respStruct, err
	}
	req.SetBasicAuth(cliConf.RPCuser, cliConf.RPCpassword)
	req.Header.Set("Content-Type", "text/plain;")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return respStruct, err
	}
	defer resp.Body.Close()
	bodyResp, err := ioutil.ReadAll(resp.Body)
	if err != nil {
		return respStruct, err
	}
	err = json.Unmarshal(bodyResp, &respStruct)
	if err != nil {
		return respStruct, err
	}
	return respStruct, nil
}

func getNextLotteryTxt(conf *be.ConfStruct) string {
	if NextLotteryCounter > (60*30) || NextLotteryStored == "" {
		NextLotteryCounter = 0
		lrs, _ := getLotteryInfo(conf)
		if lrs.Lottery.Countdown.Humanized != "" {
			return "Next Lottery:     [" + lrs.Lottery.Countdown.Humanized + "](fg:white)"
		} else {
			return "Next Lottery:     [" + NextLotteryStored + "](fg:white)"
		}
	} else {
		return "Next Lottery:     [" + NextLotteryStored + "](fg:white)"
	}
}

func getActivelyStakingTxtDivi(ss *be.DiviStakingStatusRespStruct, wi *be.DiviWalletInfoRespStruct) string {
	// Work out balance
	//todo Make sure that we only return yes, if the StakingStatus is true AND we have enough coins
	if ss.Result.StakingStatus == true && (wi.Result.Balance > 10000) {
		return "Actively Staking: [Yes](fg:green)"
	} else {
		return "Actively Staking: [No](fg:yellow)"
	}
}

func getActivelyStakingTxtPhore(ss *be.PhoreStakingStatusRespStruct) string {
	if ss.Result.StakingStatus == true {
		return "Actively Staking: [Yes](fg:green)"
	} else {
		return "Actively Staking: [No](fg:yellow)"
	}
}

func getActivelyStakingTxtTrezarcoin(ss *be.TrezarcoinStakingInfoRespStruct) string {
	if ss.Result.Staking == true {
		return "Actively Staking: [Yes](fg:green)"
	} else {
		return "Actively Staking: [No](fg:yellow)"
	}
}

func getBalanceInDiviTxt(wi *be.DiviWalletInfoRespStruct) string {
	tBalance := wi.Result.ImmatureBalance + wi.Result.UnconfirmedBalance + wi.Result.Balance
	tBalanceStr := humanize.FormatFloat("#,###.####", tBalance)

	// Work out balance
	if wi.Result.ImmatureBalance > 0 {
		return "  Incoming....... [" + tBalanceStr + "](fg:cyan)"
	} else if wi.Result.UnconfirmedBalance > 0 {
		return "  Confirming....... [" + tBalanceStr + "](fg:yellow)"
	} else {
		return "  Balance:          [" + tBalanceStr + "](fg:green)"
	}
}

func getBalanceInFeathercoinTxt(wi *be.FeathercoinWalletInfoRespStruct) string {
	tBalance := wi.Result.Balance
	tBalanceStr := humanize.FormatFloat("#,###.####", tBalance)

	// Work out balance
	return "  Balance:          [" + tBalanceStr + "](fg:green)"
}

func getBalanceInPhoreTxt(wi *be.PhoreWalletInfoRespStruct) string {
	tBalance := wi.Result.Balance
	tBalanceStr := humanize.FormatFloat("#,###.####", tBalance)

	// Work out balance
	return "  Balance:          [" + tBalanceStr + "](fg:green)"
}

func getBalanceInTrezarcoinTxt(wi *be.TrezarcoinWalletInfoRespStruct) string {
	tBalance := wi.Result.Balance
	tBalanceStr := humanize.FormatFloat("#,###.####", tBalance)

	// Work out balance
	return "  Balance:          [" + tBalanceStr + "](fg:green)"
}

func getWalletStakingTxt(wi *be.DiviWalletInfoRespStruct) string {
	var fPercent float64
	if wi.Result.Balance > 10000 {
		fPercent = 100
	} else {
		fPercent = (wi.Result.Balance / 10000) * 100
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

func getWalletSecurityStatusTxtDivi(wi *be.DiviWalletInfoRespStruct) string {
	switch wi.Result.EncryptionStatus {
	case be.CWalletESLocked:
		return "Security:         [Locked - Not Staking](fg:yellow)"
	case be.CWalletESUnlocked:
		return "Security:         [UNLOCKED](fg:red)"
	case be.CWalletESUnlockedForStaking:
		return "Security:         [Locked and Staking](fg:green)"
	case be.CWalletESUnencrypted:
		return "Security:         [UNENCRYPTED](fg:red)"
	default:
		return "Security:         [checking...](fg:yellow)"
	}
}

func getWalletSecurityStatusTxtFeathercoin(wi *be.FeathercoinWalletInfoRespStruct) string {
	if wi.Result.UnlockedUntil == 0 {
		return "Security:         [Locked](fg:green)"
	} else if wi.Result.UnlockedUntil == -1 {
		return "Security:         [UNENCRYPTED](fg:red)"
	} else if wi.Result.UnlockedUntil > 0 {
		return "Security:         [Locked](fg:green)"
	} else {
		return "Security:         [checking...](fg:yellow)"
	}
}

func getWalletSecurityStatusTxtPhore(wi *be.PhoreWalletInfoRespStruct) string {
	if wi.Result.UnlockedUntil == 0 {
		return "Security:         [Locked - Not Staking](fg:yellow)"
	} else if wi.Result.UnlockedUntil == -1 {
		return "Security:         [UNENCRYPTED](fg:red)"
	} else if wi.Result.UnlockedUntil > 0 {
		return "Security:         [Locked and Staking](fg:green)"
	} else {
		return "Security:         [checking...](fg:yellow)"
	}
}

func getWalletSecurityStatusTxtTrezarcoin(wi *be.TrezarcoinWalletInfoRespStruct) string {
	if wi.Result.UnlockedUntil == 0 {
		return "Security:         [Locked - Not Staking](fg:yellow)"
	} else if wi.Result.UnlockedUntil == -1 {
		return "Security:         [UNENCRYPTED](fg:red)"
	} else if wi.Result.UnlockedUntil > 0 {
		return "Security:         [Locked and Staking](fg:green)"
	} else {
		return "Security:         [checking...](fg:yellow)"
	}
}

func getLotteryInfo(cliConf *be.ConfStruct) (be.LotteryDiviRespStruct, error) {
	var respStruct be.LotteryDiviRespStruct

	resp, err := http.Get("https://statbot.neist.io/api/v1/statbot")
	if err != nil {
		return respStruct, err
	}
	defer resp.Body.Close()

	body, err := ioutil.ReadAll(resp.Body)
	if err != nil {
		return respStruct, err
	}
	err = json.Unmarshal(body, &respStruct)
	if err != nil {
		return respStruct, err
	}
	return respStruct, errors.New("unable to getLotteryInfo")
}

func getNetworkDifficultyInfo(pt be.ProjectType) (float64, float64, error) {
	var coin string
	// https://chainz.cryptoid.info/ftc/api.dws?q=getdifficulty

	switch pt {
	case be.PTDivi:
		coin = "divi"
	case be.PTFeathercoin:
		coin = "ftc"
	default:
		return 0, 0, errors.New("unable to determine project type")
	}

	resp, err := http.Get("https://chainz.cryptoid.info/" + coin + "/api.dws?q=getdifficulty")
	if err != nil {
		return 0, 0, err
	}
	defer resp.Body.Close()

	body, err := ioutil.ReadAll(resp.Body)
	if err != nil {
		return 0, 0, err
	}

	var fGood float64
	var fWarning float64
	// Now calculate the correct levels...
	if fDiff, err := strconv.ParseFloat(string(body), 32); err == nil {
		fGood = fDiff * 0.75
		fWarning = fDiff * 0.50
	}
	return fGood, fWarning, nil
}

func getPrivateKeyNew(cliConf *be.ConfStruct) (hdinfoRespStruct, error) {
	attempts := 5
	waitingStr := "Attempt to Get Private Key..."
	var respStruct hdinfoRespStruct

	for i := 1; i < 5; i++ {
		fmt.Printf("\r"+waitingStr+" %d/"+strconv.Itoa(attempts), i)

		body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"dumphdinfo\",\"params\":[]}")
		req, err := http.NewRequest("POST", "http://"+cliConf.ServerIP+":"+cliConf.Port, body)
		if err != nil {
			return respStruct, err
		}
		//req.SetBasicAuth("divirpc", "3toXJZWrcrBzGERpCxkJ3LmTezF4yiCLDj5z3Y9nJebr")
		req.SetBasicAuth(cliConf.RPCuser, cliConf.RPCpassword)
		req.Header.Set("Content-Type", "text/plain;")

		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			return respStruct, err
		}
		defer resp.Body.Close()
		bodyResp, err := ioutil.ReadAll(resp.Body)
		if err != nil {
			return respStruct, err
		}
		// Check to make sure we are not loading the wallet
		if bytes.Contains(bodyResp, []byte("Loading wallet...")) {
			var errStruct be.GenericRespStruct
			err = json.Unmarshal(bodyResp, &errStruct)
			if err != nil {
				return respStruct, err
			}
			fmt.Println(errStruct.Error)
			time.Sleep(3 * time.Second)
		} else {

			err = json.Unmarshal(bodyResp, &respStruct)
			if err != nil {
				return respStruct, err
			}
		}
	}
	return respStruct, nil
}

func getWalletSeedRecoveryResp() string {
	reader := bufio.NewReader(os.Stdin)
	fmt.Println("\n\n*** WARNING ***" + "\n\n" +
		"You haven't provided confirmation that you've backed up your recovery seed!\n\n" +
		"This is *extremely* important as it's the only way of recovering your wallet in the future\n\n" +
		"To (d)isplay your reovery seed now press: d, to (c)onfirm that you've backed it up press: c, or to (m)ove on, press: m\n\n" +
		"Please enter: [d/c/m]")
	resp, _ := reader.ReadString('\n')
	resp = strings.ReplaceAll(resp, "\n", "")
	return resp
}

func getWalletSeedRecoveryConfirmationResp() bool {
	reader := bufio.NewReader(os.Stdin)
	fmt.Println("Please enter the response: " + be.CSeedStoredSafelyStr)
	resp, _ := reader.ReadString('\n')
	if resp == be.CSeedStoredSafelyStr+"\n" {
		return true
	}

	return false
}

// func getWalletStatusStruct(token string) (m.WalletStatusStruct, error) {
// 	ws := m.WalletRequestStruct{}
// 	ws.WalletRequest = gwc.CWalletRequestGetWalletStatus
// 	var respStruct m.WalletStatusStruct
// 	waitingStr := "Attempt..."
// 	attempts := 5
// 	requestBody, err := json.Marshal(ws)
// 	if err != nil {
// 		return respStruct, err
// 	}

// 	for i := 1; i < 5; i++ {
// 		fmt.Printf("\r"+waitingStr+" %d/"+strconv.Itoa(attempts), i)

// 		// We're going to send a request off, and then read the json response
// 		//_, _ = http.Post("http://127.0.0.1:4000/server/", "application/json", bytes.NewBuffer(requestBody))
// 		resp, err := http.Post("http://127.0.0.1:4000/wallet/", "application/json", bytes.NewBuffer(requestBody))
// 		if err != nil {
// 			return respStruct, err
// 		}
// 		defer resp.Body.Close()

// 		body, err := ioutil.ReadAll(resp.Body)
// 		if err != nil {
// 			return respStruct, err
// 		}
// 		err = json.Unmarshal(body, &respStruct)
// 		if err != nil {
// 			return respStruct, err
// 		}

// 		if err == nil && respStruct.ResponseCode == gwc.NoServerError {
// 			return respStruct, nil
// 		} else {
// 			time.Sleep(1 * time.Second)
// 		}
// 	}

// 	return respStruct, errors.New("Unable to retrieve WalletStatus from server...")
// }

// func getToken() (string, error) {
// 	reqStruct := m.ServerRequestStruct{}
// 	reqStruct.ServerRequest = "GenerateToken"
// 	var respStruct m.TokenResponseStruct
// 	waitingStr := "Attempt..."
// 	attempts := 5
// 	requestBody, err := json.Marshal(reqStruct)
// 	if err != nil {
// 		return "", err
// 	}
// 	for i := 1; i < 5; i++ {
// 		fmt.Printf("\r"+waitingStr+" %d/"+strconv.Itoa(attempts), i)
// 		// We're going to send a request off, and then read the json response
// 		//_, _ = http.Post("http://127.0.0.1:4000/server/", "application/json", bytes.NewBuffer(requestBody))
// 		resp, err := http.Post("http://127.0.0.1:4000/server/", "application/json", bytes.NewBuffer(requestBody))
// 		if err != nil {
// 			return "", err
// 		}
// 		defer resp.Body.Close()
// 		body, err := ioutil.ReadAll(resp.Body)
// 		if err != nil {
// 			return "", err
// 		}
// 		err = json.Unmarshal(body, &respStruct)
// 		if err != nil {
// 			return "", err
// 		}
// 		if err == nil && respStruct.ResponseCode == gwc.NoServerError {
// 			return respStruct.Token, nil
// 		} else {
// 			time.Sleep(1 * time.Second)
// 		}
// 		return respStruct.Token, nil
// 	}
// 	return "", errors.New("Unable to retrieve Token from server...")
// }
