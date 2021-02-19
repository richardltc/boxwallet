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
	"github.com/gookit/color"
)

const (
	cStakeReceived   string = "\u2618" // "\u2605" //"\u0276"
	cPaymentReceived string = "\u2770" //"\u261A" //"\u0293"
	cPaymentSent     string = "\u2771"
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
		fmt.Println("  ____          __          __   _ _      _   \n |  _ \\         \\ \\        / /  | | |    | |  \n | |_) | _____  _\\ \\  /\\  / /_ _| | | ___| |_ \n |  _ < / _ \\ \\/ /\\ \\/  \\/ / _` | | |/ _ \\ __|\n | |_) | (_) >  <  \\  /\\  / (_| | | |  __/ |_ \n |____/ \\___/_/\\_\\  \\/  \\/ \\__,_|_|_|\\___|\\__| v" + be.CBWAppVersion + "\n                                              \n                                               ")

		apw, err := be.GetAppWorkingFolder()
		if err != nil {
			log.Fatal("Unable to GetAppWorkingFolder: " + err.Error())
		}

		// Make sure the config file exists, and if not, force user to use "coin" command first..
		if _, err := os.Stat(apw + be.CConfFile + be.CConfFileExt); os.IsNotExist(err) {
			log.Fatal("Unable to determine coin type. Please run " + be.CAppFilename + " coin  first")
		}

		// Now load our config file to see what coin choice the user made...
		cliConf, err := be.GetConfigStruct("", true)
		if err != nil {
			log.Fatal("Unable to determine coin type. Please run " + be.CAppFilename + " coin: " + err.Error())
			//log.Fatal("Unable to GetCLIConfStruct " + err.Error())
		}

		sCoinName, err := be.GetCoinName(be.APPTCLI)
		// sLogfileName, err := gwc.GetAppLogfileName()
		// if err != nil {
		// 	log.Fatal("Unable to GetAppLogfileName " + err.Error())
		// }

		// lfp := abf + sLogfileName

		sAppFileCLIName, err := be.GetAppFileName()
		if err != nil {
			log.Fatal("Unable to GetAppFileCLIName " + err.Error())
		}

		coind, err := be.GetCoinDaemonFilename(be.APPTCLI, cliConf.ProjectType)
		if err != nil {
			log.Fatalf("Unable to GetCoinDaemonFilename - %v", err)
		}

		// Check to see if we are running the coin daemon locally, and if we are, make sure it's actually running
		// before attempting to connect to it.
		if cliConf.ServerIP == "127.0.0.1" {
			bCDRunning, _, err := be.IsCoinDaemonRunning(cliConf.ProjectType)
			if err != nil {
				log.Fatal("Unable to determine if coin daemon is running: " + err.Error())
			}
			if !bCDRunning {
				log.Fatal("Unable to communicate with the " + coind + " server. Please make sure the " + coind + " server is running, by running:\n\n" +
					"./" + sAppFileCLIName + " start\n\n")
			}
		}

		wRunning, s, err := confirmWalletReady()
		if err != nil {
			log.Fatalf("\nUnable to determine if wallet is ready: %v,%v", s, err)
		}

		if !wRunning {
			fmt.Println("")
			log.Fatal("Unable to communicate with the " + coind + " server. Please make sure the " + coind + " server is running, by running:\n\n" +
				"./" + sAppFileCLIName + " start\n\n")
		}

		// Let's display the tip message so the user sees it when they exit the dash command.
		sTipInfo := be.GetTipInfo(cliConf.ProjectType)
		fmt.Println("\n\n" + sTipInfo + "\n")

		// The first thing we need to do is to store the coin core version for the About display...
		sCoreVersion := ""
		switch cliConf.ProjectType {
		case be.PTDeVault:
			gi, err := be.GetInfoDVT(&cliConf)
			if err != nil {
				sCoreVersion = "Unknown"
			} else {
				sCoreVersion = strconv.Itoa(gi.Result.Version)
			}
		case be.PTDigiByte:
			gi, err := be.GetWalletInfoDGB(&cliConf)
			if err != nil {
				sCoreVersion = "Unknown"
			} else {
				sCoreVersion = strconv.Itoa(gi.Result.Walletversion)
			}
		case be.PTDivi:
			gi, err := be.GetInfoDivi(&cliConf)
			if err != nil {
				sCoreVersion = "Unknown"
			} else {
				sCoreVersion = gi.Result.Version
			}
		case be.PTFeathercoin:
			gi, err := be.GetNetworkInfoFeathercoin(&cliConf)
			if err != nil {
				sCoreVersion = "Unknown"
			} else {
				sCoreVersion = strconv.Itoa(gi.Result.Version)
			}
		case be.PTGroestlcoin:
			gi, err := be.GetNetworkInfoGRS(&cliConf)
			if err != nil {
				sCoreVersion = "Unknown"
			} else {
				sCoreVersion = strconv.Itoa(gi.Result.Version)
			}
		case be.PTPhore:
			gi, err := be.GetInfoPhore(&cliConf)
			if err != nil {
				sCoreVersion = "Unknown"
			} else {
				sCoreVersion = strconv.Itoa(gi.Result.Version)
			}
		case be.PTPIVX:
			gi, _, err := be.GetInfoPIVX(&cliConf)
			if err != nil {
				sCoreVersion = "Unknown"
			} else {
				sCoreVersion = strconv.Itoa(gi.Result.Version)
			}
		case be.PTRapids:
			gi, err := be.GetInfoRapids(&cliConf)
			if err != nil {
				sCoreVersion = "Unknown"
			} else {
				sCoreVersion = strconv.Itoa(gi.Result.Version)
			}
		case be.PTReddCoin:
			gi, err := be.GetNetworkInfoRDD(&cliConf)
			if err != nil {
				sCoreVersion = "Unknown"
			} else {
				sCoreVersion = strconv.Itoa(gi.Result.Version)
			}
		case be.PTTrezarcoin:
			gi, err := be.GetInfoTrezarcoin(&cliConf)
			if err != nil {
				sCoreVersion = "Unknown"
			} else {
				sCoreVersion = strconv.Itoa(gi.Result.Version)
			}
		case be.PTVertcoin:
			gi, err := be.GetNetworkInfoVTC(&cliConf)
			if err != nil {
				sCoreVersion = "Unknown"
			} else {
				sCoreVersion = strconv.Itoa(gi.Result.Version)
			}
		default:
			log.Fatal("unable to determine project type")
		}

		// The next thing we need to check is to see if the wallet currently has any addresses
		bWalletExists := false
		switch cliConf.ProjectType {
		case be.PTDeVault:
			addresses, _ := be.ListReceivedByAddressDVT(&cliConf, false)
			if len(addresses.Result) > 0 {
				bWalletExists = true
			}
		case be.PTDigiByte:
			addresses, _ := be.ListReceivedByAddressDGB(&cliConf, false)
			if len(addresses.Result) > 0 {
				bWalletExists = true
			}
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
		case be.PTGroestlcoin:
			addresses, _ := be.ListReceivedByAddressGRS(&cliConf, false)
			if len(addresses.Result) > 0 {
				bWalletExists = true
			}
		case be.PTPhore:
			addresses, _ := be.ListReceivedByAddressPhore(&cliConf, false)
			if len(addresses.Result) > 0 {
				bWalletExists = true
			}
		case be.PTPIVX:
			addresses, _ := be.ListReceivedByAddressPIVX(&cliConf, false)
			if len(addresses.Result) > 0 {
				bWalletExists = true
			}
		case be.PTRapids:
			addresses, _ := be.ListReceivedByAddressRapids(&cliConf, false)
			if len(addresses.Result) > 0 {
				bWalletExists = true
			}
		case be.PTReddCoin:
			addresses, _ := be.ListReceivedByAddressRDD(&cliConf, false)
			if len(addresses.Result) > 0 {
				bWalletExists = true
			}
		case be.PTScala:
		case be.PTTrezarcoin:
			addresses, _ := be.ListReceivedByAddressTrezarcoin(&cliConf, false)
			if len(addresses.Result) > 0 {
				bWalletExists = true
			}
		case be.PTVertcoin:
			addresses, _ := be.ListReceivedByAddressVTC(&cliConf, false)
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
			case be.PTDeVault:
				wet, err := be.GetWalletEncryptionStatus()
				if err != nil {
					log.Fatalf("Unable to determine wallet encryption status")
				}
				if wet == be.WETLocked {
					pw = be.GetWalletEncryptionPassword()
				}
				bConfirmedBU, err := HandleWalletBUDVT(pw)
				cliConf.UserConfirmedWalletBU = bConfirmedBU
				if err := be.SetConfigStruct("", cliConf); err != nil {
					log.Fatalf("Unable to SetCLIConfStruct(): failed with %s\n", err)
				}
			case be.PTDigiByte:
				wet, err := be.GetWalletEncryptionStatus()
				if err != nil {
					log.Fatalf("Unable to determine wallet encryption status")
				}
				if wet == be.WETLocked {
					pw = be.GetWalletEncryptionPassword()
				}
				bConfirmedBU, err := HandleWalletBUDGB(pw)
				cliConf.UserConfirmedWalletBU = bConfirmedBU
				if err := be.SetConfigStruct("", cliConf); err != nil {
					log.Fatalf("Unable to SetCLIConfStruct(): failed with %s\n", err)
				}
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
			case be.PTGroestlcoin:
				wet, err := be.GetWalletEncryptionStatus()
				if err != nil {
					log.Fatalf("Unable to determine wallet encryption status")
				}
				if wet == be.WETLocked {
					pw = be.GetWalletEncryptionPassword()
				}
				bConfirmedBU, err := HandleWalletBUGRS(pw)
				cliConf.UserConfirmedWalletBU = bConfirmedBU
				if err := be.SetConfigStruct("", cliConf); err != nil {
					log.Fatalf("Unable to SetCLIConfStruct(): failed with %s\n", err)
				}
			case be.PTPhore:
			case be.PTPIVX:
				wet, err := be.GetWalletEncryptionStatus()
				if err != nil {
					log.Fatalf("Unable to determine wallet encryption status")
				}
				if wet == be.WETLocked {
					pw = be.GetWalletEncryptionPassword()
				}
				// todo Below needs to be done for PIVX
				//bConfirmedBU, err := HandleWalletBURapids(pw)
				//cliConf.UserConfirmedWalletBU = bConfirmedBU
				//if err := be.SetConfigStruct("", cliConf); err != nil {
				//	log.Fatalf("Unable to SetCLIConfStruct(): failed with %s\n", err)
				//}

			case be.PTRapids:
				wet, err := be.GetWalletEncryptionStatus()
				if err != nil {
					log.Fatalf("Unable to determine wallet encryption status")
				}
				if wet == be.WETLocked {
					pw = be.GetWalletEncryptionPassword()
				}
				bConfirmedBU, err := HandleWalletBURapids(pw)
				cliConf.UserConfirmedWalletBU = bConfirmedBU
				if err := be.SetConfigStruct("", cliConf); err != nil {
					log.Fatalf("Unable to SetCLIConfStruct(): failed with %s\n", err)
				}
			case be.PTReddCoin:
				wet, err := be.GetWalletEncryptionStatus()
				if err != nil {
					log.Fatalf("Unable to determine wallet encryption status")
				}
				if wet == be.WETLocked {
					pw = be.GetWalletEncryptionPassword()
				}
				bConfirmedBU, err := HandleWalletBURDD(pw)
				cliConf.UserConfirmedWalletBU = bConfirmedBU
				if err := be.SetConfigStruct("", cliConf); err != nil {
					log.Fatalf("Unable to SetCLIConfStruct(): failed with %s\n", err)
				}
			case be.PTTrezarcoin:
			case be.PTVertcoin:
				wet, err := be.GetWalletEncryptionStatus()
				if err != nil {
					log.Fatalf("Unable to determine wallet encryption status")
				}
				if wet == be.WETLocked {
					pw = be.GetWalletEncryptionPassword()
				}
				bConfirmedBU, err := HandleWalletBUVTC(pw)
				cliConf.UserConfirmedWalletBU = bConfirmedBU
				if err := be.SetConfigStruct("", cliConf); err != nil {
					log.Fatalf("Unable to SetCLIConfStruct(): failed with %s\n", err)
				}
			default:
				log.Fatalf("Unable to determine project type")
			}
		}

		// Check wallet encryption status
		bWalletNeedsEncrypting := false
		switch cliConf.ProjectType {
		case be.PTDeVault:
			wi, err := be.GetWalletInfoDVT(&cliConf)
			if err != nil {
				log.Fatal("Unable to perform GetWalletInfoDVT " + err.Error())
			}

			if wi.Result.UnlockedUntil < 0 {
				bWalletNeedsEncrypting = true
			}
		case be.PTDigiByte:
			wi, err := be.GetWalletInfoDGB(&cliConf)
			if err != nil {
				log.Fatal("Unable to perform GetWalletInfoDGB " + err.Error())
			}

			if wi.Result.UnlockedUntil < 0 {
				bWalletNeedsEncrypting = true
			}
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
		case be.PTGroestlcoin:
			wi, err := be.GetWalletInfoGRS(&cliConf)
			if err != nil {
				log.Fatal("Unable to perform GetWalletInfoGRS " + err.Error())
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
		case be.PTPIVX:
			wi, err := be.GetWalletInfoPIVX(&cliConf)
			if err != nil {
				log.Fatal("Unable to perform GetWalletInfoPIVX " + err.Error())
			}

			if wi.Result.UnlockedUntil < 0 {
				bWalletNeedsEncrypting = true
			}
		case be.PTRapids:
			wi, err := be.GetWalletInfoRapids(&cliConf)
			if err != nil {
				log.Fatal("Unable to perform GetWalletInfoRapids " + err.Error())
			}

			if wi.Result.UnlockedUntil < 0 {
				bWalletNeedsEncrypting = true
			}
		case be.PTReddCoin:
			wi, err := be.GetWalletInfoRDD(&cliConf)
			if err != nil {
				log.Fatal("Unable to perform GetWalletInfoDVT " + err.Error())
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
		case be.PTVertcoin:
			wi, err := be.GetWalletInfoVTC(&cliConf)
			if err != nil {
				log.Fatal("Unable to perform GetWalletInfoVTC " + err.Error())
			}

			if wi.Result.UnlockedUntil < 0 {
				bWalletNeedsEncrypting = true
			}
		default:
			log.Fatalf("Unable to determine project type")
		}

		// Display warning message (visible when the users stops dash) if they haven't encrypted their wallet
		if bWalletNeedsEncrypting {
			color.Danger.Println("*** WARNING: Your wallet is NOT encrypted! ***")
			fmt.Println("\nPlease encrypt it NOW with the command:\n\n" +
				"./boxwallet wallet encrypt\n")
		}
		if bWalletNeedsEncrypting && cliConf.BlockchainSynced == true {
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
				time.Sleep(10 * time.Second)
				if err := be.StartCoinDaemon(false); err != nil {
					log.Fatalf("failed to run "+coind+": %v", err)
				}
				// todo I think we need a wallet is ready code here again..
				wRunning, s, err := confirmWalletReady()
				if err != nil {
					log.Fatalf("Unable to determine if wallet is ready: %v,%v", s, err)
				}

				coind, err := be.GetCoinDaemonFilename(be.APPTCLI, cliConf.ProjectType)
				if err != nil {
					log.Fatalf("Unable to GetCoinDaemonFilename - %v", err)
				}
				if !wRunning {
					fmt.Println("")
					log.Fatal("Unable to communicate with the " + coind + " server. Please make sure the " + coind + " server is running, by running:\n\n" +
						"./" + sAppFileCLIName + " start\n\n")
				}
			}
		}

		// Init display....

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
		case be.PTDeVault:
			pAbout.Text = "  [" + be.CAppName + "    v" + be.CBWAppVersion + "](fg:white)\n" +
				"  [" + sCoinName + " Core v" + sCoreVersion + "](fg:white)\n\n"
		case be.PTDigiByte:
			pAbout.Text = "  [" + be.CAppName + "     v" + be.CBWAppVersion + "](fg:white)\n" +
				"  [" + sCoinName + " Core v" + sCoreVersion + "](fg:white)\n\n"
		case be.PTDivi:
			pAbout.Text = "  [" + be.CAppName + "    v" + be.CBWAppVersion + "](fg:white)\n" +
				"  [" + sCoinName + " Core    v" + sCoreVersion + "](fg:white)\n\n"
		case be.PTFeathercoin:
			pAbout.Text = "  [" + be.CAppName + "          v" + be.CBWAppVersion + "](fg:white)\n" +
				"  [" + sCoinName + " Core   v" + sCoreVersion + "](fg:white)\n\n"
		case be.PTGroestlcoin:
			pAbout.Text = "  [" + be.CAppName + "          v" + be.CBWAppVersion + "](fg:white)\n" +
				"  [" + sCoinName + " Core   v" + sCoreVersion + "](fg:white)\n\n"
		case be.PTPhore:
			pAbout.Text = "  [" + be.CAppName + "    v" + be.CBWAppVersion + "](fg:white)\n" +
				"  [" + sCoinName + " Core   v" + sCoreVersion + "](fg:white)\n\n"
		case be.PTPIVX:
			pAbout.Text = "  [" + be.CAppName + "    v" + be.CBWAppVersion + "](fg:white)\n" +
				"  [" + sCoinName + " Core    v" + sCoreVersion + "](fg:white)\n\n"
		case be.PTRapids:
			pAbout.Text = "  [" + be.CAppName + "    v" + be.CBWAppVersion + "](fg:white)\n" +
				"  [" + sCoinName + " Core  v" + sCoreVersion + "](fg:white)\n\n"
		case be.PTReddCoin:
			pAbout.Text = "  [" + be.CAppName + "     v" + be.CBWAppVersion + "](fg:white)\n" +
				"  [" + sCoinName + " Core v" + sCoreVersion + "](fg:white)\n\n"
		case be.PTTrezarcoin:
			pAbout.Text = "  [" + be.CAppName + "         v" + be.CBWAppVersion + "](fg:white)\n" +
				"  [" + sCoinName + " Core   v" + sCoreVersion + "](fg:white)\n\n"
		case be.PTVertcoin:
			pAbout.Text = "  [" + be.CAppName + "       v" + be.CBWAppVersion + "](fg:white)\n" +
				"  [" + sCoinName + " Core   v" + sCoreVersion + "](fg:white)\n\n"
		default:
			err = errors.New("unable to determine ProjectType")
		}

		pWallet := widgets.NewParagraph()
		pWallet.Title = "Wallet"
		pWallet.SetRect(33, 0, 84, 11)
		pWallet.TextStyle.Fg = ui.ColorWhite
		pWallet.BorderStyle.Fg = ui.ColorYellow
		switch cliConf.ProjectType {
		case be.PTDeVault:
			pWallet.Text = "  Balance:          [waiting for sync...](fg:yellow)\n" +
				"  Security:         [waiting for sync...](fg:yellow)\n"
		case be.PTDigiByte:
			pWallet.Text = "  Balance:          [waiting for sync...](fg:yellow)\n" +
				"  Security:         [waiting for sync...](fg:yellow)\n"
		case be.PTDivi:
			pWallet.Text = "  Balance:          [waiting for sync...](fg:yellow)\n" +
				"  Currency:         [waiting for sync...](fg:yellow)\n" +
				"  Security:         [waiting for sync...](fg:yellow)\n" +
				"  Staking %:	        [waiting for sync...](fg:yellow)\n" +
				"  Actively Staking: [waiting for sync...](fg:yellow)\n" +
				"  Next Lottery:     [waiting for sync...](fg:yellow)\n" +
				"  Lottery tickets:	  [waiting for sync...](fg:yellow)"
		case be.PTFeathercoin:
			pWallet.Text = "  Balance:          [waiting for sync...](fg:yellow)\n" +
				"  Security:         [waiting for sync...](fg:yellow)\n"
		case be.PTGroestlcoin:
			pWallet.Text = "  Balance:          [waiting for sync...](fg:yellow)\n" +
				"  Security:         [waiting for sync...](fg:yellow)\n"
		case be.PTPhore:
			pWallet.Text = "  Balance:          [waiting for sync...](fg:yellow)\n" +
				"  Security:         [waiting for sync...](fg:yellow)\n" +
				"  Actively Staking: [waiting for sync...](fg:yellow)\n"
		case be.PTPIVX:
			pWallet.Text = "  Balance:          [waiting for sync...](fg:yellow)\n" +
				"  Security:         [waiting for sync...](fg:yellow)\n" +
				"  Actively Staking: [waiting for sync...](fg:yellow)\n"
		case be.PTRapids:
			pWallet.Text = "  Balance:          [waiting for sync...](fg:yellow)\n" +
				"  Security:         [waiting for sync...](fg:yellow)\n" +
				"  Actively Staking: [waiting for sync...](fg:yellow)\n"
		case be.PTReddCoin:
			pWallet.Text = "  Balance:          [waiting for sync...](fg:yellow)\n" +
				"  Security:         [waiting for sync...](fg:yellow)\n"
		case be.PTTrezarcoin:
			pWallet.Text = "  Balance:          [waiting for sync...](fg:yellow)\n" +
				"  Security:         [waiting for sync...](fg:yellow)\n" +
				"  Actively Staking: [waiting for sync...](fg:yellow)\n"
		case be.PTVertcoin:
			pWallet.Text = "  Balance:          [waiting for sync...](fg:yellow)\n" +
				"  Security:         [waiting for sync...](fg:yellow)\n"
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
		pNetwork.SetRect(0, 11, 32, 4)
		pNetwork.TextStyle.Fg = ui.ColorWhite
		pNetwork.BorderStyle.Fg = ui.ColorWhite

		switch cliConf.ProjectType {
		case be.PTDeVault:
			pNetwork.Text = "  Headers:     [checking...](fg:yellow)\n" +
				"  Blocks:      [checking...](fg:yellow)\n" +
				"  Difficulty:  [checking...](fg:yellow)\n" +
				"  Blockchain:  [checking...](fg:yellow)\n" +
				"  Peers:  [checking...](fg:yellow)\n"
		case be.PTDigiByte:
			pNetwork.Text = "  Headers:     [checking...](fg:yellow)\n" +
				"  Blocks:      [checking...](fg:yellow)\n" +
				"  Difficulty:  [checking...](fg:yellow)\n" +
				"  Blockchain:  [checking...](fg:yellow)\n" +
				"  Peers:  [checking...](fg:yellow)\n"
		case be.PTDivi:
			pNetwork.Text = "  Blocks:      [checking...](fg:yellow)\n" +
				"  Difficulty:  [checking...](fg:yellow)\n" +
				"  Blockchain:  [checking...](fg:yellow)\n" +
				"  Masternodes: [checking...](fg:yellow)" +
				"  Peers:  [checking...](fg:yellow)\n"
		case be.PTFeathercoin:
			pNetwork.Text = "  Headers:     [checking...](fg:yellow)\n" +
				"  Blocks:      [checking...](fg:yellow)\n" +
				"  Difficulty:  [checking...](fg:yellow)\n" +
				"  Blockchain:  [checking...](fg:yellow)\n" +
				"  Peers:  [checking...](fg:yellow)\n"

		case be.PTGroestlcoin:
			pNetwork.Text = "  Headers:     [checking...](fg:yellow)\n" +
				"  Blocks:      [checking...](fg:yellow)\n" +
				"  Difficulty:  [checking...](fg:yellow)\n" +
				"  Blockchain:  [checking...](fg:yellow)\n" +
				"  Peers:  [checking...](fg:yellow)\n"

		case be.PTPhore:
			pNetwork.Text = "  Blocks:      [checking...](fg:yellow)\n" +
				"  Difficulty:  [checking...](fg:yellow)\n" +
				"  Blockchain:  [checking...](fg:yellow)\n" +
				"  Masternodes: [checking...](fg:yellow)" +
				"  Peers:  [checking...](fg:yellow)\n"

		case be.PTPIVX:
			pNetwork.Text = "  Blocks:      [checking...](fg:yellow)\n" +
				"  Difficulty:  [checking...](fg:yellow)\n" +
				"  Blockchain:  [checking...](fg:yellow)\n" +
				"  Masternodes: [checking...](fg:yellow)" +
				"  Peers:  [checking...](fg:yellow)\n"

		case be.PTRapids:
			pNetwork.Text = "  Blocks:      [checking...](fg:yellow)\n" +
				"  Difficulty:  [checking...](fg:yellow)\n" +
				"  Blockchain:  [checking...](fg:yellow)\n" +
				"  Masternodes: [checking...](fg:yellow)" +
				"  Peers:  [checking...](fg:yellow)\n"
		case be.PTReddCoin:
			pNetwork.Text = "  Headers:     [checking...](fg:yellow)\n" +
				"  Blocks:      [checking...](fg:yellow)\n" +
				"  Difficulty:  [checking...](fg:yellow)\n" +
				"  Blockchain:  [checking...](fg:yellow)\n" +
				"  Peers:  [checking...](fg:yellow)\n"

		case be.PTTrezarcoin:
			pNetwork.Text = "  Blocks:      [checking...](fg:yellow)\n" +
				"  Difficulty:  [checking...](fg:yellow)\n" +
				"  Blockchain:  [checking...](fg:yellow)\n" +
				"  Masternodes: [checking...](fg:yellow)" +
				"  Peers:  [checking...](fg:yellow)\n"

		case be.PTVertcoin:
			pNetwork.Text = "  Headers:     [checking...](fg:yellow)\n" +
				"  Blocks:      [checking...](fg:yellow)\n" +
				"  Difficulty:  [checking...](fg:yellow)\n" +
				"  Blockchain:  [checking...](fg:yellow)\n" +
				"  Peers:  [checking...](fg:yellow)\n"

		default:
			err = errors.New("unable to determine ProjectType")
		}

		pTransactions := widgets.NewTable()
		pTransactions.Rows = [][]string{
			[]string{" Date", " Category", " Amount", " Confirmations"},
		}
		pTransactions.Title = "Transactions"
		pTransactions.RowSeparator = true
		pTransactions.SetRect(0, 11, 84, 30)
		pTransactions.TextStyle.Fg = ui.ColorWhite
		pTransactions.BorderStyle.Fg = ui.ColorWhite

		// var numSeconds int = -1
		updateDisplay := func(count int) {
			var bciDeVault be.DVTBlockchainInfoRespStruct
			var bciDigiByte be.DGBBlockchainInfoRespStruct
			var bciDivi be.DiviBlockchainInfoRespStruct
			var bciFeathercoin be.FeathercoinBlockchainInfoRespStruct
			var bciGroestlcoin be.GRSBlockchainInfoRespStruct
			var bciPhore be.PhoreBlockchainInfoRespStruct
			var bciPIVX be.PIVXBlockchainInfoRespStruct
			var bciRapids be.RapidsBlockchainInfoRespStruct
			var bciReddCoin be.RDDBlockchainInfoRespStruct
			var bciTrezarcoin be.TrezarcoinBlockchainInfoRespStruct
			var bciVertcoin be.VTCBlockchainInfoRespStruct
			//var gi be.GetInfoRespStruct
			var mnssDivi be.DiviMNSyncStatusRespStruct
			var mnssPhore be.PhoreMNSyncStatusRespStruct
			var mnssPIVX be.PIVXMNSyncStatusRespStruct
			var mnssRapids be.RapidsMNSyncStatusRespStruct
			//var niDeVault be.DVTNetworkInfoRespStruct
			bDGBBlockchainIsSynced := false
			bDVTBlockchainIsSynced := false
			bFTCBlockchainIsSynced := false
			bGRSBlockchainIsSynced := false
			bRDDBlockchainIsSynced := false
			bTZCBlockchainIsSynced := false
			bVTCBlockchainIsSynced := false
			var ssDivi be.DiviStakingStatusRespStruct
			var ssPhore be.PhoreStakingStatusRespStruct
			var ssPIVX be.PIVXStakingStatusRespStruct
			var ssRapids be.RapidsStakingStatusRespStruct
			var ssTrezarcoin be.TrezarcoinStakingInfoRespStruct
			var transDGB be.DGBListTransactions
			var transDivi be.DiviListTransactions
			var transFTC be.FTCListTransactions
			var transRDD be.RDDListTransactions
			var wiDeVault be.DVTWalletInfoRespStruct
			var wiDigiByte be.DGBWalletInfoRespStruct
			var wiDivi be.DiviWalletInfoRespStruct
			var wiFeathercoin be.FeathercoinWalletInfoRespStruct
			var wiGroestlcoin be.GRSWalletInfoRespStruct
			var wiPhore be.PhoreWalletInfoRespStruct
			var wiPIVX be.PIVXWalletInfoRespStruct
			var wiRapids be.RapidsWalletInfoRespStruct
			var wiReddCoin be.RDDWalletInfoRespStruct
			var wiTrezarcoin be.TrezarcoinWalletInfoRespStruct
			var wiVertcoin be.VTCWalletInfoRespStruct
			if gGetBCInfoCount == 0 || gGetBCInfoCount > cliConf.RefreshTimer {
				if gGetBCInfoCount > cliConf.RefreshTimer {
					gGetBCInfoCount = 1
				}
				switch cliConf.ProjectType {
				case be.PTDeVault:
					bciDeVault, _ = be.GetBlockchainInfoDVT(&cliConf)
					if bciDeVault.Result.Verificationprogress > 0.99999 {
						bDVTBlockchainIsSynced = true
					}
				case be.PTDigiByte:
					bciDigiByte, _ = be.GetBlockchainInfoDGB(&cliConf)
					if bciDigiByte.Result.Verificationprogress > 0.99999 {
						bDGBBlockchainIsSynced = true
					}
				case be.PTDivi:
					bciDivi, _ = be.GetBlockchainInfoDivi(&cliConf)
				case be.PTFeathercoin:
					bciFeathercoin, _ = be.GetBlockchainInfoFeathercoin(&cliConf)
					if bciFeathercoin.Result.Verificationprogress > 0.99999 {
						bFTCBlockchainIsSynced = true
					}
				case be.PTGroestlcoin:
					bciGroestlcoin, _ = be.GetBlockchainInfoGRS(&cliConf)
					if bciGroestlcoin.Result.Verificationprogress > 0.99999 {
						bGRSBlockchainIsSynced = true
					}
				case be.PTPhore:
					bciPhore, _ = be.GetBlockchainInfoPhore(&cliConf)
				case be.PTPIVX:
					bciPIVX, _ = be.GetBlockchainInfoPIVX(&cliConf)
				case be.PTRapids:
					bciRapids, _ = be.GetBlockchainInfoRapids(&cliConf)
				case be.PTReddCoin:
					bciReddCoin, _ = be.GetBlockchainInfoRDD(&cliConf)
					if bciReddCoin.Result.Verificationprogress > 0.99999 {
						bRDDBlockchainIsSynced = true
					}
				case be.PTTrezarcoin:
					bciTrezarcoin, _ = be.GetBlockchainInfoTrezarcoin(&cliConf)
					if bciTrezarcoin.Result.Verificationprogress > 0.99999 {
						bTZCBlockchainIsSynced = true
					}
				case be.PTVertcoin:
					bciVertcoin, _ = be.GetBlockchainInfoVTC(&cliConf)
					if bciVertcoin.Result.Verificationprogress > 0.99999 {
						bVTCBlockchainIsSynced = true
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
			case be.PTDeVault:
				if bDVTBlockchainIsSynced {
					wiDeVault, _ = be.GetWalletInfoDVT(&cliConf)
				}
			case be.PTDigiByte:
				if bDGBBlockchainIsSynced {
					wiDigiByte, _ = be.GetWalletInfoDGB(&cliConf)
				}
			case be.PTDivi:
				if bciDivi.Result.Verificationprogress > 0.999 {
					mnssDivi, _ = be.GetMNSyncStatusDivi(&cliConf)
					ssDivi, _ = be.GetStakingStatusDivi(&cliConf)
					transDivi, _ = be.ListTransactionsDivi(&cliConf)
					wiDivi, _ = be.GetWalletInfoDivi(&cliConf)
				}
			case be.PTFeathercoin:
				if bFTCBlockchainIsSynced {
					transFTC, _ = be.ListTransactionsFTC(&cliConf)
					wiFeathercoin, _ = be.GetWalletInfoFeathercoin(&cliConf)
				}
			case be.PTGroestlcoin:
				if bGRSBlockchainIsSynced {
					wiGroestlcoin, _ = be.GetWalletInfoGRS(&cliConf)
				}
			case be.PTPhore:
				if bciPhore.Result.Verificationprogress > 0.999 {
					mnssPhore, _ = be.GetMNSyncStatusPhore(&cliConf)
					ssPhore, _ = be.GetStakingStatusPhore(&cliConf)
					wiPhore, _ = be.GetWalletInfoPhore(&cliConf)
				}
			case be.PTPIVX:
				if bciPIVX.Result.Verificationprogress > 0.999 {
					mnssPIVX, _ = be.GetMNSyncStatusPIVX(&cliConf)
					ssPIVX, _ = be.GetStakingStatusPIVX(&cliConf)
					wiPIVX, _ = be.GetWalletInfoPIVX(&cliConf)
				}
			case be.PTRapids:
				if bciRapids.Result.Verificationprogress > 0.999 {
					mnssRapids, _ = be.GetMNSyncStatusRapids(&cliConf)
					ssRapids, _ = be.GetStakingStatusRapids(&cliConf)
					wiRapids, _ = be.GetWalletInfoRapids(&cliConf)
				}
			case be.PTReddCoin:
				if bRDDBlockchainIsSynced {
					transRDD, _ = be.ListTransactionsRDD(&cliConf)
					wiReddCoin, _ = be.GetWalletInfoRDD(&cliConf)
				}
			case be.PTTrezarcoin:
				if bTZCBlockchainIsSynced {
					ssTrezarcoin, _ = be.GetStakingInfoTrezarcoin(&cliConf)
					wiTrezarcoin, _ = be.GetWalletInfoTrezarcoin(&cliConf)
				}
			case be.PTVertcoin:
				if bVTCBlockchainIsSynced {
					wiVertcoin, _ = be.GetWalletInfoVTC(&cliConf)
				}
			default:
				err = errors.New("unable to determine ProjectType")
			}

			// Decide what colour the network panel border should be...
			switch cliConf.ProjectType {
			case be.PTDeVault:
				if bDVTBlockchainIsSynced {
					pNetwork.BorderStyle.Fg = ui.ColorGreen
				} else {
					pNetwork.BorderStyle.Fg = ui.ColorYellow
				}
			case be.PTDigiByte:
				if bDGBBlockchainIsSynced {
					pNetwork.BorderStyle.Fg = ui.ColorGreen
				} else {
					pNetwork.BorderStyle.Fg = ui.ColorYellow
				}
			case be.PTDivi:
				if mnssDivi.Result.IsBlockchainSynced && mnssDivi.Result.RequestedMasternodeAssets == 999 {
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
			case be.PTGroestlcoin:
				if bGRSBlockchainIsSynced {
					pNetwork.BorderStyle.Fg = ui.ColorGreen
				} else {
					pNetwork.BorderStyle.Fg = ui.ColorYellow
				}
			case be.PTPhore:
				if mnssPhore.Result.IsBlockchainSynced && mnssPhore.Result.RequestedMasternodeAssets == 999 {
					pNetwork.BorderStyle.Fg = ui.ColorGreen
				} else {
					pNetwork.BorderStyle.Fg = ui.ColorYellow
				}
			case be.PTPIVX:
				if mnssPIVX.Result.IsBlockchainSynced && mnssPIVX.Result.RequestedMasternodeAssets == 999 {
					pNetwork.BorderStyle.Fg = ui.ColorGreen
				} else {
					pNetwork.BorderStyle.Fg = ui.ColorYellow
				}
			case be.PTRapids:
				if mnssRapids.Result.IsBlockchainSynced && mnssRapids.Result.RequestedMasternodeAssets == 999 {
					pNetwork.BorderStyle.Fg = ui.ColorGreen
				} else {
					pNetwork.BorderStyle.Fg = ui.ColorYellow
				}
			case be.PTReddCoin:
				if bRDDBlockchainIsSynced {
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
			case be.PTVertcoin:
				if bVTCBlockchainIsSynced {
					pNetwork.BorderStyle.Fg = ui.ColorGreen
				} else {
					pNetwork.BorderStyle.Fg = ui.ColorYellow
				}
			default:
				err = errors.New("unable to determine ProjectType")
			}

			// **************************
			// Populate the Network panel
			// **************************

			var sBlocks string
			var sDiff string
			var sBlockchainSync string
			var sHeaders string
			var sMNSync string
			var sPeers string
			switch cliConf.ProjectType {
			case be.PTDeVault:
				sHeaders = be.GetNetworkHeadersTxtDVT(&bciDeVault)
				sBlocks = be.GetNetworkBlocksTxtDVT(&bciDeVault)
				sDiff = be.GetNetworkDifficultyTxtDVT(bciDeVault.Result.Difficulty, gDiffGood, gDiffWarning)
				sBlockchainSync = be.GetBlockchainSyncTxtDVT(bDVTBlockchainIsSynced, &bciDeVault)
				sPeers = be.GetNetworkConnectionsTxtDVT(gConnections)
			case be.PTDigiByte:
				sHeaders = be.GetNetworkHeadersTxtDGB(&bciDigiByte)
				sBlocks = be.GetNetworkBlocksTxtDGB(&bciDigiByte)
				sDiff = be.GetNetworkDifficultyTxtDGB(bciDigiByte.Result.Difficulties.Scrypt, gDiffGood, gDiffWarning)
				sBlockchainSync = be.GetBlockchainSyncTxtDGB(bDGBBlockchainIsSynced, &bciDigiByte)
				sPeers = be.GetNetworkConnectionsTxtDGB(gConnections)
			case be.PTDivi:
				sBlocks = be.GetNetworkBlocksTxtDivi(&bciDivi)
				sDiff = be.GetNetworkDifficultyTxtDivi(bciDivi.Result.Difficulty, gDiffGood, gDiffWarning)
				sBlockchainSync = be.GetBlockchainSyncTxtDivi(mnssDivi.Result.IsBlockchainSynced, &bciDivi)
				sMNSync = be.GetMNSyncStatusTxtDivi(&mnssDivi)
				sPeers = be.GetNetworkConnectionsTxtDivi(gConnections)
			case be.PTFeathercoin:
				sHeaders = be.GetNetworkHeadersTxtFeathercoin(&bciFeathercoin)
				sBlocks = be.GetNetworkBlocksTxtFeathercoin(&bciFeathercoin)
				sDiff = be.GetNetworkDifficultyTxtFeathercoin(bciFeathercoin.Result.Difficulty, gDiffGood, gDiffWarning)
				sBlockchainSync = be.GetBlockchainSyncTxtFeathercoin(bFTCBlockchainIsSynced, &bciFeathercoin)
				sPeers = be.GetNetworkConnectionsTxtFTC(gConnections)
			case be.PTGroestlcoin:
				sHeaders = be.GetNetworkHeadersTxtGRS(&bciGroestlcoin)
				sBlocks = be.GetNetworkBlocksTxtGRS(&bciGroestlcoin)
				sDiff = be.GetNetworkDifficultyTxtGRS(bciGroestlcoin.Result.Difficulty, gDiffGood, gDiffWarning)
				sBlockchainSync = be.GetBlockchainSyncTxtGRS(bGRSBlockchainIsSynced, &bciGroestlcoin)
				sPeers = be.GetNetworkConnectionsTxtGRS(gConnections)
			case be.PTPhore:
				sBlocks = be.GetNetworkBlocksTxtPhore(&bciPhore)
				sDiff = be.GetNetworkDifficultyTxtPhore(bciPhore.Result.Difficulty, gDiffGood, gDiffWarning)
				sBlockchainSync = be.GetBlockchainSyncTxtPhore(mnssPhore.Result.IsBlockchainSynced, &bciPhore)
				sMNSync = be.GetMNSyncStatusTxtPhore(&mnssPhore)
				sPeers = be.GetNetworkConnectionsTxtPhore(gConnections)
			case be.PTPIVX:
				sBlocks = be.GetNetworkBlocksTxtPIVX(&bciPIVX)
				sDiff = be.GetNetworkDifficultyTxtPIVX(bciPIVX.Result.Difficulty, gDiffGood, gDiffWarning)
				sBlockchainSync = be.GetBlockchainSyncTxtPIVX(mnssPIVX.Result.IsBlockchainSynced, &bciPIVX)
				sMNSync = be.GetMNSyncStatusTxtPIVX(&mnssPIVX)
				sPeers = be.GetNetworkConnectionsTxtPIVX(gConnections)
			case be.PTRapids:
				sBlocks = be.GetNetworkBlocksTxtRapids(&bciRapids)
				sDiff = be.GetNetworkDifficultyTxtRapids(bciRapids.Result.Difficulty, gDiffGood, gDiffWarning)
				sBlockchainSync = be.GetBlockchainSyncTxtRapids(mnssRapids.Result.IsBlockchainSynced, &bciRapids)
				sMNSync = be.GetMNSyncStatusTxtRapids(&mnssRapids)
				sPeers = be.GetNetworkConnectionsTxtRPD(gConnections)
			case be.PTReddCoin:
				sHeaders = be.GetNetworkHeadersTxtRDD(&bciReddCoin)
				sBlocks = be.GetNetworkBlocksTxtRDD(&bciReddCoin)
				sDiff = be.GetNetworkDifficultyTxtRDD(bciReddCoin.Result.Difficulty, gDiffGood, gDiffWarning)
				sBlockchainSync = be.GetBlockchainSyncTxtRDD(bRDDBlockchainIsSynced, &bciReddCoin)
				sPeers = be.GetNetworkConnectionsTxtRDD(gConnections)
			case be.PTTrezarcoin:
				sBlocks = be.GetNetworkBlocksTxtTrezarcoin(&bciTrezarcoin)
				sDiff = be.GetNetworkDifficultyTxtTrezarcoin(bciTrezarcoin.Result.Difficulty, gDiffGood, gDiffWarning)
				sBlockchainSync = be.GetBlockchainSyncTxtTrezarcoin(bTZCBlockchainIsSynced, &bciTrezarcoin)
				sPeers = be.GetNetworkConnectionsTxtTZC(gConnections)
			case be.PTVertcoin:
				sHeaders = be.GetNetworkHeadersTxtVTC(&bciVertcoin)
				sBlocks = be.GetNetworkBlocksTxtVTC(&bciVertcoin)
				sDiff = be.GetNetworkDifficultyTxtVTC(bciVertcoin.Result.Difficulty, gDiffGood, gDiffWarning)
				sBlockchainSync = be.GetBlockchainSyncTxtVTC(bVTCBlockchainIsSynced, &bciVertcoin)
				sPeers = be.GetNetworkConnectionsTxtVTC(gConnections)
			default:
				err = errors.New("unable to determine ProjectType")
			}

			switch cliConf.ProjectType {
			case be.PTDeVault:
				pNetwork.Text = "  " + sHeaders + "\n" +
					"  " + sBlocks + "\n" +
					"  " + sDiff + "\n" +
					"  " + sBlockchainSync + "\n" +
					"  " + sPeers
			case be.PTDigiByte:
				pNetwork.Text = "  " + sHeaders + "\n" +
					"  " + sBlocks + "\n" +
					"  " + sDiff + "\n" +
					"  " + sBlockchainSync + "\n" +
					"  " + sPeers
			case be.PTDivi:
				pNetwork.Text = "  " + sBlocks + "\n" +
					"  " + sDiff + "\n" +
					"  " + sBlockchainSync + "\n" +
					"  " + sMNSync + "\n" +
					"  " + sPeers
			case be.PTFeathercoin:
				pNetwork.Text = "  " + sHeaders + "\n" +
					"  " + sBlocks + "\n" +
					"  " + sDiff + "\n" +
					"  " + sBlockchainSync + "\n" +
					"  " + sPeers
			case be.PTGroestlcoin:
				pNetwork.Text = "  " + sHeaders + "\n" +
					"  " + sBlocks + "\n" +
					"  " + sDiff + "\n" +
					"  " + sBlockchainSync + "\n" +
					"  " + sPeers
			case be.PTPhore:
				pNetwork.Text = "  " + sBlocks + "\n" +
					"  " + sDiff + "\n" +
					"  " + sBlockchainSync + "\n" +
					"  " + sMNSync + "\n" +
					"  " + sPeers
			case be.PTPIVX:
				pNetwork.Text = "  " + sBlocks + "\n" +
					"  " + sDiff + "\n" +
					"  " + sBlockchainSync + "\n" +
					"  " + sMNSync + "\n" +
					"  " + sPeers
			case be.PTRapids:
				pNetwork.Text = "  " + sBlocks + "\n" +
					"  " + sDiff + "\n" +
					"  " + sBlockchainSync + "\n" +
					"  " + sMNSync + "\n" +
					"  " + sPeers
			case be.PTReddCoin:
				pNetwork.Text = "  " + sHeaders + "\n" +
					"  " + sBlocks + "\n" +
					"  " + sDiff + "\n" +
					"  " + sBlockchainSync + "\n" +
					"  " + sPeers
			case be.PTTrezarcoin:
				pNetwork.Text = "  " + sBlocks + "\n" +
					"  " + sDiff + "\n" +
					"  " + sBlockchainSync + "\n" +
					"  " + sMNSync + "\n" +
					"  " + sPeers
			case be.PTVertcoin:
				pNetwork.Text = "  " + sHeaders + "\n" +
					"  " + sBlocks + "\n" +
					"  " + sDiff + "\n" +
					"  " + sBlockchainSync + "\n" +
					"  " + sPeers
			default:
				pNetwork.Text = "  " + sBlocks + "\n" +
					"  " + sDiff + "\n" +
					"  " + sBlockchainSync + "\n" +
					"  " + sMNSync + "\n" +
					"  " + sPeers
			}

			// Populate the Wallet panel

			// Decide what colour the wallet panel border should be...

			switch cliConf.ProjectType {
			case be.PTDeVault:
				wet := be.GetWalletSecurityStateDVT(&wiDeVault)
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
			case be.PTDigiByte:
				wet := be.GetWalletSecurityStateDGB(&wiDigiByte)
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
			case be.PTGroestlcoin:
				wet := be.GetWalletSecurityStateGRS(&wiGroestlcoin)
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
			case be.PTPIVX:
				wet := be.GetWalletSecurityStatePIVX(&wiPIVX)
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
			case be.PTRapids:
				wet := be.GetWalletSecurityStateRapids(&wiRapids)
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
			case be.PTReddCoin:
				wet := be.GetWalletSecurityStateRDD(&wiReddCoin)
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
			case be.PTVertcoin:
				wet := be.GetWalletSecurityStateVTC(&wiVertcoin)
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
			case be.PTDeVault:
				if bciDeVault.Result.Verificationprogress > 0.999 {
					pWallet.Text = "" + getBalanceInDVTTxt(&wiDeVault) + "\n" +
						"  " + getWalletSecurityStatusTxtDVT(&wiDeVault) + "\n"
				}
			case be.PTDigiByte:
				if bciDigiByte.Result.Verificationprogress > 0.999 {
					pWallet.Text = "" + getBalanceInDGBTxt(&wiDigiByte) + "\n" +
						"  " + getWalletSecurityStatusTxtDGB(&wiDigiByte) + "\n"
				}
			case be.PTDivi:
				if bciDivi.Result.Verificationprogress > 0.999 {
					pWallet.Text = "" + getBalanceInDiviTxt(&wiDivi) + "\n" +
						"  " + be.GetBalanceInCurrencyTxtDivi(&cliConf, &wiDivi) + "\n" +
						"  " + getWalletSecurityStatusTxtDivi(&wiDivi) + "\n" +
						"  " + getWalletStakingTxt(&wiDivi) + "\n" + //e.g. "15%" or "staking"
						"  " + getActivelyStakingTxtDivi(&ssDivi, &wiDivi) + "\n" + //e.g. "15%" or "staking"
						"  " + getNextLotteryTxtDIVI(&cliConf) + "\n" +
						"  " + "Lottery tickets:  0"
				}
			case be.PTFeathercoin:
				if bciFeathercoin.Result.Verificationprogress > 0.999 {
					pWallet.Text = "" + getBalanceInFeathercoinTxt(&wiFeathercoin) + "\n" +
						"  " + getWalletSecurityStatusTxtFeathercoin(&wiFeathercoin) + "\n"
				}
			case be.PTGroestlcoin:
				if bciGroestlcoin.Result.Verificationprogress > 0.999 {
					pWallet.Text = "" + getBalanceInGRSTxt(&wiGroestlcoin) + "\n" +
						"  " + getWalletSecurityStatusTxtGRS(&wiGroestlcoin) + "\n"
				}
			case be.PTPhore:
				if bciPhore.Result.Verificationprogress > 0.999 {
					pWallet.Text = "" + getBalanceInPhoreTxt(&wiPhore) + "\n" +
						"  " + getWalletSecurityStatusTxtPhore(&wiPhore) + "\n" +
						"  " + getActivelyStakingTxtPhore(&ssPhore) + "\n" //e.g. "15%" or "staking"
				}
			case be.PTPIVX:
				if bciPIVX.Result.Verificationprogress > 0.999 {
					pWallet.Text = "" + getBalanceInPIVXTxt(&wiPIVX) + "\n" +
						"  " + getWalletSecurityStatusTxtPIVX(&wiPIVX) + "\n" +
						"  " + getActivelyStakingTxtPIVX(&ssPIVX) + "\n" //e.g. "15%" or "staking"
				}
			case be.PTRapids:
				if bciRapids.Result.Verificationprogress > 0.999 {
					pWallet.Text = "" + getBalanceInRapidsTxt(&wiRapids) + "\n" +
						"  " + getWalletSecurityStatusTxtRapids(&wiRapids) + "\n" +
						"  " + getActivelyStakingTxtRapids(&ssRapids) + "\n" //e.g. "15%" or "staking"
				}
			case be.PTReddCoin:
				if bciReddCoin.Result.Verificationprogress > 0.999 {
					pWallet.Text = "" + getBalanceInRDDTxt(&wiReddCoin) + "\n" +
						"  " + getWalletSecurityStatusTxtRDD(&wiReddCoin) + "\n"
				}
			case be.PTTrezarcoin:
				if bciTrezarcoin.Result.Verificationprogress > 0.999 {
					pWallet.Text = "" + getBalanceInTrezarcoinTxt(&wiTrezarcoin) + "\n" +
						"  " + getWalletSecurityStatusTxtTrezarcoin(&wiTrezarcoin) + "\n" +
						"  " + getActivelyStakingTxtTrezarcoin(&ssTrezarcoin) + "\n" //e.g. "15%" or "staking"
				}
			case be.PTVertcoin:
				if bciVertcoin.Result.Verificationprogress > 0.999 {
					pWallet.Text = "" + getBalanceInVTCTxt(&wiVertcoin) + "\n" +
						"  " + getWalletSecurityStatusTxtVTC(&wiVertcoin) + "\n"
				}
			default:
				err = errors.New("unable to determine ProjectType")
			}

			// *******************************************************
			// Update the transactions display, if we're all synced up
			// *******************************************************

			switch cliConf.ProjectType {
			case be.PTDigiByte:
				if bciDigiByte.Result.Verificationprogress > 0.999 {
					updateTransactionsDGB(&transDGB, pTransactions)
				}
			case be.PTDivi:
				if bciDivi.Result.Verificationprogress > 0.999 {
					updateTransactionsDIVI(&transDivi, pTransactions)
				}
			case be.PTFeathercoin:
				if bciFeathercoin.Result.Verificationprogress > 0.999 {
					updateTransactionsFTC(&transFTC, pTransactions)
				}
			case be.PTReddCoin:
				if bciReddCoin.Result.Verificationprogress > 0.999 {
					updateTransactionsRDD(&transRDD, pTransactions)
				}
				//default:
				//	err = errors.New("unable to determine ProjectType")
			}

			// Update ticker info every 30 seconds...
			if gTickerCounter == 0 || gTickerCounter > 30 {
				if gTickerCounter > 30 {
					gTickerCounter = 1
				}
				switch cliConf.ProjectType {
				case be.PTDeVault:
					gDiffGood, gDiffWarning, _ = getNetworkDifficultyInfo(be.PTDeVault)
					// update the Network Info details
					niDeVault, _ := be.GetNetworkInfoDVT(&cliConf)
					gConnections = niDeVault.Result.Connections
				case be.PTDigiByte:
					gDiffGood, gDiffWarning, _ = getNetworkDifficultyInfo(be.PTDigiByte)
					// update the Network Info details
					niDigiByte, _ := be.GetNetworkInfoDGB(&cliConf)
					gConnections = niDigiByte.Result.Connections
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
					giDivi, _ := be.GetInfoDivi(&cliConf)
					gConnections = giDivi.Result.Connections
				case be.PTFeathercoin:
					gDiffGood, gDiffWarning, _ = getNetworkDifficultyInfo(be.PTFeathercoin)
					niFTC, _ := be.GetNetworkInfoFeathercoin(&cliConf)
					gConnections = niFTC.Result.Connections
				case be.PTGroestlcoin:
					gDiffGood, gDiffWarning, _ = getNetworkDifficultyInfo(be.PTGroestlcoin)
					niGRS, _ := be.GetNetworkInfoGRS(&cliConf)
					gConnections = niGRS.Result.Connections
				case be.PTPhore:
					// todo Implement DiffGood and DiffWarning do for Phore
					giPHR, _ := be.GetInfoPhore(&cliConf)
					gConnections = giPHR.Result.Connections
				case be.PTPIVX:
					gDiffGood, gDiffWarning, _ = getNetworkDifficultyInfo(be.PTPIVX)
					giPIVX, _, _ := be.GetInfoPIVX(&cliConf)
					gConnections = giPIVX.Result.Connections
				case be.PTReddCoin:
					// todo Implement DiffGood and DiffWarning do for Phore
					//gDiffGood, gDiffWarning, _ = getNetworkDifficultyInfo(be.PTReddCoin)
					niRDD, _ := be.GetNetworkInfoRDD(&cliConf)
					gConnections = niRDD.Result.Connections
				case be.PTTrezarcoin:
					// todo Implement DiffGood and DiffWarning do for TZC
					giTZC, _ := be.GetInfoTrezarcoin(&cliConf)
					gConnections = giTZC.Result.Connections
				case be.PTVertcoin:
					gDiffGood, gDiffWarning, _ = getNetworkDifficultyInfo(be.PTVertcoin)
					niVTC, _ := be.GetNetworkInfoVTC(&cliConf)
					gConnections = niVTC.Result.Connections
				default:
					err = errors.New("unable to determine ProjectType")
				}

			}
			gTickerCounter++

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

func checkHealth(bci *be.DiviBlockchainInfoRespStruct) error {
	// This func will be called regularly and will check the health of the local wallet. It will..

	// If the blockchain verification is 0.99 or higher, than all so good, otherwise...
	if bci.Result.Verificationprogress > 0.99 {
		return nil
	}

	// If the block count is stuck at 100...
	if bci.Result.Blocks == 100 {
		// 20 * 3 = 3 minutes
		if gBCSyncStuckCount > 20*3 {
			if err := be.WalletFix(be.WFTReSync, be.PTDivi); err != nil {
				return fmt.Errorf("unable to perform wallet resync: %v", err)
			}
			return nil
		} else {
			gBCSyncStuckCount++
			return nil
		}
	}

	return nil
}

func confirmWalletReady() (bool, string, error) {
	cliConf, err := be.GetConfigStruct("", true)
	if err != nil {
		return false, "", fmt.Errorf("unable to determine coin type. Please run "+be.CAppFilename+" coin: %v", err.Error())
	}
	sCoinName, err := be.GetCoinName(be.APPTCLI)

	// Lets make sure that we have a running daemon.
	cfg := yacspin.Config{
		Frequency:       250 * time.Millisecond,
		CharSet:         yacspin.CharSets[43],
		Suffix:          "",
		SuffixAutoColon: true,
		Message:         " waiting for your " + sCoinName + " wallet to load, this could take several minutes...",
		StopCharacter:   "",
		StopColors:      []string{"fgGreen"},
	}

	spinner, err := yacspin.New(cfg)
	if err != nil {
		return false, "", fmt.Errorf("unable to initialise spinner - %v", err)
	}

	if err := spinner.Start(); err != nil {
		log.Fatalf("Unable to start spinner - %v", err)
	}

	coind, err := be.GetCoinDaemonFilename(be.APPTCLI, cliConf.ProjectType)
	if err != nil {
		log.Fatalf("Unable to GetCoinDaemonFilename - %v", err)
	}
	switch cliConf.ProjectType {
	case be.PTDeVault:
		gi, err := be.GetInfoDVT(&cliConf)
		if err != nil {
			if err := spinner.Stop(); err != nil {
			}
			return false, "", fmt.Errorf("Unable to communicate with the " + coind + " server.")
		}
		if gi.Result.Version == 0 {
			return false, gi.Result.Errors, fmt.Errorf("unable to call getinfo %s\n", err)
		}
	case be.PTDigiByte:
		gi, s, err := be.GetNetworkInfoDGBUI(&cliConf, spinner)
		if err != nil {
			if err := spinner.Stop(); err != nil {
			}
			return false, s, fmt.Errorf("Unable to communicate with the " + coind + " server.")
		}
		if gi.Result.Version == 0 {
			return false, s, fmt.Errorf("unable to call getinfo %s\n", err)
		}
	case be.PTDivi:
		gi, s, err := be.GetInfoDIVIUI(&cliConf, spinner)
		if err != nil {
			if err := spinner.Stop(); err != nil {
			}
			return false, s, fmt.Errorf("Unable to communicate with the " + coind + " server.")
		}
		if gi.Result.Version == "" {
			return false, s, fmt.Errorf("unable to call getinfo %s\n", err)
		}
	case be.PTFeathercoin:
		gi, err := be.GetNetworkInfoFeathercoin(&cliConf)
		if err != nil {
			if err := spinner.Stop(); err != nil {
			}
			return false, "", fmt.Errorf("Unable to communicate with the " + coind + " server.")
		}
		if gi.Result.Version == 0 {
			return false, gi.Result.Warnings, fmt.Errorf("unable to call getinfo %s\n", err)
		}
	case be.PTGroestlcoin:
		gi, err := be.GetNetworkInfoGRS(&cliConf)
		if err != nil {
			if err := spinner.Stop(); err != nil {
			}
			return false, "", fmt.Errorf("Unable to communicate with the " + coind + " server.")
		}
		if gi.Result.Version == 0 {
			return false, gi.Result.Warnings, fmt.Errorf("unable to call getinfo %s\n", err)
		}
	case be.PTPhore:
		gi, err := be.GetInfoPhore(&cliConf)
		if err != nil {
			if err := spinner.Stop(); err != nil {
			}
			return false, "", fmt.Errorf("Unable to communicate with the " + coind + " server.")
		}
		if gi.Result.Version == 0 {
			return false, gi.Result.Errors, fmt.Errorf("unable to call getinfo %s\n", err)
		}
	case be.PTPIVX:
		gi, s, err := be.GetInfoPIVXUI(&cliConf, spinner)
		if err != nil {
			if err := spinner.Stop(); err != nil {
			}
			return false, s, fmt.Errorf("Unable to communicate with the " + coind + " server.")
		}
		if gi.Result.Version == 0 {
			return false, s, fmt.Errorf("unable to call getinfo %s\n", err)
		}
	case be.PTRapids:
		gi, s, err := be.GetInfoRPDUI(&cliConf, spinner)
		if err != nil {
			if err := spinner.Stop(); err != nil {
			}
			return false, s, fmt.Errorf("Unable to communicate with the " + coind + " server.")
		}
		if gi.Result.Version == 0 {
			return false, s, fmt.Errorf("unable to call getinfo %s\n", err)
		}
	case be.PTReddCoin:
		gi, s, err := be.GetInfoRDDUI(&cliConf, spinner)
		if err != nil {
			if err := spinner.Stop(); err != nil {
			}
			return false, "", fmt.Errorf("Unable to communicate with the " + coind + " server.")
		}
		if gi.Result.Version == 0 {
			return false, s, fmt.Errorf("unable to call getinfo %s\n", err)
		}
	case be.PTTrezarcoin:
		gi, err := be.GetInfoTrezarcoin(&cliConf)
		if err != nil {
			if err := spinner.Stop(); err != nil {
			}
			return false, "", fmt.Errorf("Unable to communicate with the " + coind + " server.")
		}
		if gi.Result.Version == 0 {
			return false, gi.Result.Errors, fmt.Errorf("unable to call getinfo %s\n", err)
		}
	case be.PTVertcoin:
		gi, err := be.GetNetworkInfoVTC(&cliConf)
		if err != nil {
			if err := spinner.Stop(); err != nil {
			}
			return false, "", fmt.Errorf("Unable to communicate with the " + coind + " server.")
		}
		if gi.Result.Version == 0 {
			return false, "", fmt.Errorf("unable to call getinfo %s\n", err)
		}
	default:
		return false, "", fmt.Errorf("unable to determine project type")
	}
	spinner.Stop()

	return true, "", nil
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

func getNextLotteryTxtDIVI(conf *be.ConfStruct) string {
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

func getActivelyStakingTxtPIVX(ss *be.PIVXStakingStatusRespStruct) string {
	if ss.Result.StakingStatus == true {
		return "Actively Staking: [Yes](fg:green)"
	} else {
		return "Actively Staking: [No](fg:yellow)"
	}
}

func getActivelyStakingTxtRapids(ss *be.RapidsStakingStatusRespStruct) string {
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

func getBalanceInDGBTxt(wi *be.DGBWalletInfoRespStruct) string {
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

func getBalanceInDVTTxt(wi *be.DVTWalletInfoRespStruct) string {
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
	tBalance := wi.Result.ImmatureBalance + wi.Result.UnconfirmedBalance + wi.Result.Balance
	tBalanceStr := humanize.FormatFloat("#,###.##", tBalance)

	// Work out balance
	if wi.Result.ImmatureBalance > 0 {
		return "  Incoming....... [" + tBalanceStr + "](fg:cyan)"
	} else if wi.Result.UnconfirmedBalance > 0 {
		return "  Confirming....... [" + tBalanceStr + "](fg:yellow)"
	} else {
		return "  Balance:          [" + tBalanceStr + "](fg:green)"
	}
}

func getBalanceInGRSTxt(wi *be.GRSWalletInfoRespStruct) string {
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

	//tBalance := wi.Result.Balance
	//tBalanceStr := humanize.FormatFloat("#,###.####", tBalance)
	//
	//// Work out balance
	//return "  Balance:          [" + tBalanceStr + "](fg:green)"
}

func getBalanceInPhoreTxt(wi *be.PhoreWalletInfoRespStruct) string {
	tBalance := wi.Result.Balance
	tBalanceStr := humanize.FormatFloat("#,###.####", tBalance)

	// Work out balance
	return "  Balance:          [" + tBalanceStr + "](fg:green)"
}

func getBalanceInPIVXTxt(wi *be.PIVXWalletInfoRespStruct) string {
	tBalance := wi.Result.ImmatureBalance + wi.Result.UnconfirmedBalance + wi.Result.Balance
	tBalanceStr := humanize.FormatFloat("#,###.##", tBalance)

	// Work out balance
	if wi.Result.ImmatureBalance > 0 {
		return "  Incoming....... [" + tBalanceStr + "](fg:cyan)"
	} else if wi.Result.UnconfirmedBalance > 0 {
		return "  Confirming....... [" + tBalanceStr + "](fg:yellow)"
	} else {
		return "  Balance:          [" + tBalanceStr + "](fg:green)"
	}

	// Work out balance
	return "  Balance:          [" + tBalanceStr + "](fg:green)"
}

func getBalanceInRapidsTxt(wi *be.RapidsWalletInfoRespStruct) string {
	tBalance := wi.Result.ImmatureBalance + wi.Result.UnconfirmedBalance + wi.Result.Balance
	tBalanceStr := humanize.FormatFloat("#,###.##", tBalance)

	// Work out balance
	if wi.Result.ImmatureBalance > 0 {
		return "  Incoming....... [" + tBalanceStr + "](fg:cyan)"
	} else if wi.Result.UnconfirmedBalance > 0 {
		return "  Confirming....... [" + tBalanceStr + "](fg:yellow)"
	} else {
		return "  Balance:          [" + tBalanceStr + "](fg:green)"
	}

	// Work out balance
	return "  Balance:          [" + tBalanceStr + "](fg:green)"
}

func getBalanceInRDDTxt(wi *be.RDDWalletInfoRespStruct) string {
	tBalance := wi.Result.Balance
	tBalanceStr := humanize.FormatFloat("#,###.####", tBalance)

	// Work out balance
	return "  Balance:          [" + tBalanceStr + "](fg:green)"
}

func getBalanceInTrezarcoinTxt(wi *be.TrezarcoinWalletInfoRespStruct) string {
	tBalance := wi.Result.ImmatureBalance + wi.Result.UnconfirmedBalance + wi.Result.Balance
	tBalanceStr := humanize.FormatFloat("#,###.##", tBalance)

	// Work out balance
	if wi.Result.ImmatureBalance > 0 {
		return "  Incoming....... [" + tBalanceStr + "](fg:cyan)"
	} else if wi.Result.UnconfirmedBalance > 0 {
		return "  Confirming....... [" + tBalanceStr + "](fg:yellow)"
	} else {
		return "  Balance:          [" + tBalanceStr + "](fg:green)"
	}
}

func getBalanceInVTCTxt(wi *be.VTCWalletInfoRespStruct) string {
	tBalance := wi.Result.ImmatureBalance + wi.Result.UnconfirmedBalance + wi.Result.Balance
	tBalanceStr := humanize.FormatFloat("#,###.##", tBalance)

	// Work out balance
	if wi.Result.ImmatureBalance > 0 {
		return "  Incoming....... [" + tBalanceStr + "](fg:cyan)"
	} else if wi.Result.UnconfirmedBalance > 0 {
		return "  Confirming....... [" + tBalanceStr + "](fg:yellow)"
	} else {
		return "  Balance:          [" + tBalanceStr + "](fg:green)"
	}
}

func getCategorySymbol(s string) string {
	switch s {
	case "receive":
		return cPaymentReceived //cPaymentReceived
	case "sent":
		return cPaymentSent
	case "stake", "stake_reward":
		return cStakeReceived
	}
	return s
}

func getCategoryColour(s string) string {
	switch s {
	case "receive":
		return "green"
	case "sent":
		return "red"
	case "stake", "stake_reward":
		return "green"
	}
	return "white"
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

func getWalletSecurityStatusTxtDGB(wi *be.DGBWalletInfoRespStruct) string {
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

func getWalletSecurityStatusTxtDVT(wi *be.DVTWalletInfoRespStruct) string {
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

func getWalletSecurityStatusTxtGRS(wi *be.GRSWalletInfoRespStruct) string {
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

func getWalletSecurityStatusTxtPIVX(wi *be.PIVXWalletInfoRespStruct) string {
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

func getWalletSecurityStatusTxtRapids(wi *be.RapidsWalletInfoRespStruct) string {
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

func getWalletSecurityStatusTxtRDD(wi *be.RDDWalletInfoRespStruct) string {
	if wi.Result.UnlockedUntil == 0 {
		return "Security:         [Locked](fg:green)"
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

func getWalletSecurityStatusTxtVTC(wi *be.VTCWalletInfoRespStruct) string {
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
	case be.PTDigiByte:
		coin = "dgb"
	case be.PTDivi:
		coin = "divi"
	case be.PTFeathercoin:
		coin = "ftc"
	case be.PTGroestlcoin:
		coin = "grs"
	case be.PTPIVX:
		coin = "pivx"
	case be.PTVertcoin:
		coin = "vtc"
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

func updateTransactionsDGB(trans *be.DGBListTransactions, pt *widgets.Table) {
	pt.Rows = [][]string{
		[]string{" Date", " Category", " Amount", " Confirmations"},
	}

	// Record whether any of the transactions have 0 conf (so that we can display the boarder as yellow)
	bYellowBoarder := false

	for i := len(trans.Result) - 1; i >= 0; i-- {
		// Check to make sure the confirmations count is higher than -1
		if trans.Result[i].Confirmations < 0 {
			continue
		}

		if trans.Result[i].Confirmations < 1 {
			bYellowBoarder = true
		}
		iTime, err := strconv.ParseInt(strconv.Itoa(trans.Result[i].Timereceived), 10, 64)
		if err != nil {
			panic(err)
		}
		tm := time.Unix(iTime, 0)
		sCat := getCategorySymbol(trans.Result[i].Category)
		tAmountStr := humanize.FormatFloat("#,###.##", trans.Result[i].Amount)
		sColour := getCategoryColour(trans.Result[i].Category)
		pt.Rows = append(pt.Rows, []string{
			" [" + tm.Format("2006-01-02 15:04"+"](fg:"+sColour+")"),
			" [" + sCat + "](fg:" + sColour + ")",
			" [" + tAmountStr + "](fg:" + sColour + ")",
			" [" + strconv.Itoa(trans.Result[i].Confirmations) + "](fg:" + sColour + ")"})

		if i > 10 {
			break
		}
	}
	if bYellowBoarder {
		pt.BorderStyle.Fg = ui.ColorYellow
	} else {
		pt.BorderStyle.Fg = ui.ColorGreen
	}
}

func updateTransactionsDIVI(trans *be.DiviListTransactions, pt *widgets.Table) {
	pt.Rows = [][]string{
		[]string{" Date", " Category", " Amount", " Confirmations"},
	}

	// Record whether any of the transactions have 0 conf (so that we can display the boarder as yellow)
	bYellowBoarder := false

	for i := len(trans.Result) - 1; i >= 0; i-- {
		// Check to make sure the confirmations count is higher than -1
		if trans.Result[i].Confirmations < 0 {
			continue
		}

		if trans.Result[i].Confirmations < 1 {
			bYellowBoarder = true
		}
		iTime, err := strconv.ParseInt(strconv.Itoa(trans.Result[i].Timereceived), 10, 64)
		if err != nil {
			panic(err)
		}
		tm := time.Unix(iTime, 0)
		sCat := getCategorySymbol(trans.Result[i].Category)
		tAmountStr := humanize.FormatFloat("#,###.##", trans.Result[i].Amount)
		sColour := getCategoryColour(trans.Result[i].Category)
		pt.Rows = append(pt.Rows, []string{
			" [" + tm.Format("2006-01-02 15:04"+"](fg:"+sColour+")"),
			" [" + sCat + "](fg:" + sColour + ")",
			" [" + tAmountStr + "](fg:" + sColour + ")",
			" [" + strconv.Itoa(trans.Result[i].Confirmations) + "](fg:" + sColour + ")"})

		if i > 10 {
			break
		}
	}
	if bYellowBoarder {
		pt.BorderStyle.Fg = ui.ColorYellow
	} else {
		pt.BorderStyle.Fg = ui.ColorGreen
	}
}

func updateTransactionsFTC(trans *be.FTCListTransactions, pt *widgets.Table) {
	pt.Rows = [][]string{
		[]string{" Date", " Category", " Amount", " Confirmations"},
	}

	// Record whether any of the transactions have 0 conf (so that we can display the boarder as yellow)
	bYellowBoarder := false

	for i := len(trans.Result) - 1; i >= 0; i-- {
		// Check to make sure the confirmations count is higher than -1
		if trans.Result[i].Confirmations < 0 {
			continue
		}

		if trans.Result[i].Confirmations < 1 {
			bYellowBoarder = true
		}
		iTime, err := strconv.ParseInt(strconv.Itoa(trans.Result[i].Timereceived), 10, 64)
		if err != nil {
			panic(err)
		}
		tm := time.Unix(iTime, 0)
		sCat := getCategorySymbol(trans.Result[i].Category)
		tAmountStr := humanize.FormatFloat("#,###.##", trans.Result[i].Amount)
		sColour := getCategoryColour(trans.Result[i].Category)
		pt.Rows = append(pt.Rows, []string{
			" [" + tm.Format("2006-01-02 15:04"+"](fg:"+sColour+")"),
			" [" + sCat + "](fg:" + sColour + ")",
			" [" + tAmountStr + "](fg:" + sColour + ")",
			" [" + strconv.Itoa(trans.Result[i].Confirmations) + "](fg:" + sColour + ")"})

		if i > 10 {
			break
		}
	}
	if bYellowBoarder {
		pt.BorderStyle.Fg = ui.ColorYellow
	} else {
		pt.BorderStyle.Fg = ui.ColorGreen
	}
}

func updateTransactionsRDD(trans *be.RDDListTransactions, pt *widgets.Table) {
	pt.Rows = [][]string{
		[]string{" Date", " Category", " Amount", " Confirmations"},
	}

	// Record whether any of the transactions have 0 conf (so that we can display the boarder as yellow)
	bYellowBoarder := false

	for i := len(trans.Result) - 1; i >= 0; i-- {
		if trans.Result[i].Confirmations < 1 {
			bYellowBoarder = true
		}
		iTime, err := strconv.ParseInt(strconv.Itoa(trans.Result[i].Timereceived), 10, 64)
		if err != nil {
			panic(err)
		}
		tm := time.Unix(iTime, 0)
		sCat := getCategorySymbol(trans.Result[i].Category)
		tAmountStr := humanize.FormatFloat("#,###.##", trans.Result[i].Amount)
		sColour := getCategoryColour(trans.Result[i].Category)
		pt.Rows = append(pt.Rows, []string{
			" [" + tm.Format("2006-01-02 15:04"+"](fg:"+sColour+")"),
			" [" + sCat + "](fg:" + sColour + ")",
			" [" + tAmountStr + "](fg:" + sColour + ")",
			" [" + strconv.Itoa(trans.Result[i].Confirmations) + "](fg:" + sColour + ")"})

		if i > 10 {
			break
		}
	}
	if bYellowBoarder {
		pt.BorderStyle.Fg = ui.ColorYellow
	} else {
		pt.BorderStyle.Fg = ui.ColorGreen
	}
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
