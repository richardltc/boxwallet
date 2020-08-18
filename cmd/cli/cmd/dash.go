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
	gwc "github.com/richardltc/gwcommon"
	"github.com/spf13/cobra"
	"github.com/theckman/yacspin"

	_ "github.com/AlecAivazis/survey/v2"
	ui "github.com/gizak/termui/v3"
	"github.com/gizak/termui/v3/widgets"
	be "richardmace.co.uk/boxdivi/cmd/cli/cmd/bend"
	m "richardmace.co.uk/boxdivi/pkg/models"
)

type getinfoRespStruct struct {
	Result struct {
		Version         string  `json:"version"`
		Protocolversion int     `json:"protocolversion"`
		Walletversion   int     `json:"walletversion"`
		Balance         float64 `json:"balance"`
		Zerocoinbalance float64 `json:"zerocoinbalance"`
		Blocks          int     `json:"blocks"`
		Timeoffset      int     `json:"timeoffset"`
		Connections     int     `json:"connections"`
		Proxy           string  `json:"proxy"`
		Difficulty      float64 `json:"difficulty"`
		Testnet         bool    `json:"testnet"`
		Moneysupply     float64 `json:"moneysupply"`
		Keypoololdest   int     `json:"keypoololdest"`
		Keypoolsize     int     `json:"keypoolsize"`
		Paytxfee        float64 `json:"paytxfee"`
		Relayfee        float64 `json:"relayfee"`
		StakingStatus   string  `json:"staking status"`
		Errors          string  `json:"errors"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

type hdinfoRespStruct struct {
	Result struct {
		Hdseed             string `json:"hdseed"`
		Mnemonic           string `json:"mnemonic"`
		Mnemonicpassphrase string `json:"mnemonicpassphrase"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

type tickerStruct struct {
	DIVI struct {
		ID                int         `json:"id"`
		Name              string      `json:"name"`
		Symbol            string      `json:"symbol"`
		Slug              string      `json:"slug"`
		NumMarketPairs    int         `json:"num_market_pairs"`
		DateAdded         time.Time   `json:"date_added"`
		Tags              []string    `json:"tags"`
		MaxSupply         interface{} `json:"max_supply"`
		CirculatingSupply float64     `json:"circulating_supply"`
		TotalSupply       float64     `json:"total_supply"`
		Platform          interface{} `json:"platform"`
		CmcRank           int         `json:"cmc_rank"`
		LastUpdated       time.Time   `json:"last_updated"`
		Quote             struct {
			BTC struct {
				Price            float64   `json:"price"`
				Volume24H        float64   `json:"volume_24h"`
				PercentChange1H  float64   `json:"percent_change_1h"`
				PercentChange24H float64   `json:"percent_change_24h"`
				PercentChange7D  float64   `json:"percent_change_7d"`
				MarketCap        float64   `json:"market_cap"`
				LastUpdated      time.Time `json:"last_updated"`
			} `json:"BTC"`
			USD struct {
				Price            float64   `json:"price"`
				Volume24H        float64   `json:"volume_24h"`
				PercentChange1H  float64   `json:"percent_change_1h"`
				PercentChange24H float64   `json:"percent_change_24h"`
				PercentChange7D  float64   `json:"percent_change_7d"`
				MarketCap        float64   `json:"market_cap"`
				LastUpdated      time.Time `json:"last_updated"`
			} `json:"USD"`
		} `json:"quote"`
	} `json:"DIVI"`
}

type usd2AUDRespStruct struct {
	Rates struct {
		AUD float64 `json:"AUD"`
	} `json:"rates"`
	Base string `json:"base"`
	Date string `json:"date"`
}

type usd2GBPRespStruct struct {
	Rates struct {
		GBP float64 `json:"GBP"`
	} `json:"rates"`
	Base string `json:"base"`
	Date string `json:"date"`
}

var gGetBCInfoCount int = 0
var gBCSyncStuckCount int = 0
var gWalletRICount int = 0
var gLastBCSyncPosStr string = ""
var gLastBCSyncPos float64 = 0

//var lastRMNAssets int = 0
var lastMNSyncStatus string = ""
var NextLotteryStored string = ""
var NextLotteryCounter int = 0

// Ticker related variables
var gGetTickerInfoCount int
var gPricePerCoinAUD usd2AUDRespStruct
var gPricePerCoinGBP usd2GBPRespStruct
var gTicker tickerStruct

// Progress constants
const (
	cProg1 string = "|"
	cProg2 string = "/"
	cProg3 string = "-"
	cProg4 string = "\\"
	cProg5 string = "|"
	cProg6 string = "/"
	cProg7 string = "-"
	cProg8 string = "\\"

	cWalletESUnlockedForStaking = "unlocked-for-staking"
	cWalletESLocked             = "locked"
	cWalletESUnlocked           = "unlocked"
	cWalletESUnencrypted        = "unencrypted"
)

// dashCmd represents the dash command
var dashCmd = &cobra.Command{
	Use:   "dash",
	Short: "Display CLI a dashboard for your " + sCoinName + " wallet",
	Long: `Displays the following info in CLI form:
	
	* Wallet balance
	* Blockchain sync progress
	* Masternode sync progress
	* Wallet encryption status
	* Progress bar displaying the percentage of ` + sCoinName + ` required for staking`,
	Run: func(cmd *cobra.Command, args []string) {
		// Lets load our config file first
		cliConf, err := gwc.GetCLIConfStruct()
		if err != nil {
			log.Fatal("Unable to GetCLIConfStruct " + err.Error())
		}
		// abf, err := gwc.GetAppsBinFolder(gwc.APPTCLI)
		// if err != nil {
		// 	log.Fatal("Unable to GetAppsBinFolder " + err.Error())
		// }
		// sLogfileName, err := gwc.GetAppLogfileName()
		// if err != nil {
		// 	log.Fatal("Unable to GetAppLogfileName " + err.Error())
		// }

		//lfp := abf + sLogfileName

		sAppFileCLIName, err := gwc.GetAppFileName(gwc.APPTCLI)
		if err != nil {
			log.Fatal("Unable to GetAppFileCLIName " + err.Error())
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
			log.Fatalf("Unable to initialise spinner - %v", err)
		}

		spinner.Start()

		gi, err := getInfo(&cliConf)
		if err != nil {
			coind, err := gwc.GetCoinDaemonFilename(gwc.APPTCLI)
			if err != nil {
				log.Fatalf("Unable to GetCoinDaemonFilename - %v", err)
			}

			if err := spinner.Stop(); err != nil {
			}
			fmt.Println("")
			log.Fatal("Unable to communicate with the " + coind + " server. Please make sure the " + coind + " server is running, by running:\n\n" +
				"./" + sAppFileCLIName + " start\n\n")
		}
		if gi.Result.Version == "" {
			log.Fatalf("Unable to getPrivateKey(): failed with %s\n", err)
		}
		spinner.Stop()

		if !cliConf.UserConfirmedSeedRecovery {
			// d = Display seed, f= Save seed to file, c = confirm backed up, m = move on
			resp := getWalletSeedRecoveryResp()
			switch resp {
			case "d":
				pk, err := getPrivateKeyNew(&cliConf)
				if err != nil {
					log.Fatalf("Unable to getPrivateKey(): failed with %s\n", err)
				}
				fmt.Printf("\n\nYour private seed recovery details are as follows:\n\nHdseed: " +
					pk.Result.Hdseed + "\n\nMnemonic phrase: " +
					pk.Result.Mnemonic + "\n\nPlease make sure you safely secure this information, and then re-run " + sAppCLIFilename + " dash again.\n\n")

				os.Exit(0)
			case "f":
				// TODO ask user to run the command line to save seed to file
				// err = gwc.DoPrivKeyFile()
				// if err != nil {
				// 	log.Fatalf("gdc.DoPrivKeyFile() failed with %s\n", err)
				// }

				// os.Exit(0)
			case "c":
				// Users confirmed that they have backed up
				allOk := getWalletSeedRecoveryConfirmationResp()

				if allOk {
					// dir, err := gwc.GetRunningDir()
					// if err != nil {
					// 	log.Fatalf("Unable to GetRunningDir - %v", err)
					// }

					cliConf.UserConfirmedSeedRecovery = true
					err := gwc.SetCLIConfStruct(cliConf)
					if err != nil {
						log.Fatalf("Unable to SetCLIConfStruct(): failed with %s\n", err)
						// gdConfig.UserConfirmedSeedRecovery = true
						// gwc.SetCLIConfigStruct(dir, gdConfig)
					}
				}
			}

		}

		// Check wallet encryption status
		wi, err := getWalletInfo(&cliConf)
		if err != nil {
			log.Fatal("Unable to getWalletInfo " + err.Error())
		}

		if wi.Result.EncryptionStatus == cWalletESUnencrypted {
			gwc.ClearScreen()
			resp := be.GetWalletEncryptionResp()
			if resp == true {
				wep := gwc.GetWalletEncryptionPassword()
				r, err := encryptWallet(&cliConf, wep)
				if err != nil {
					log.Fatalf("failed to encrypt wallet %s\n", err)
				}
				fmt.Println(r.Result)
				//os.Exit(0)
				// gwc.ClearScreen()
				fmt.Println("Restarting wallet after encryption...")
				if err := be.RunCoinDaemon(false); err != nil {
					log.Fatalf("failed to run divid: %v", err)
				}
			}
		}

		if err := ui.Init(); err != nil {
			log.Fatalf("failed to initialize termui: %v", err)
		}
		defer ui.Close()

		pAbout := widgets.NewParagraph()
		pAbout.Title = "About"
		pAbout.SetRect(0, 0, 32, 4)
		pAbout.TextStyle.Fg = ui.ColorWhite
		pAbout.BorderStyle.Fg = ui.ColorGreen
		pAbout.Text = "  [" + sAppName + "      v" + gwc.CAppVersion + "](fg:white)\n" +
			"  [" + sCoinName + "         v" + gwc.CDiviAppVersion + "](fg:white)\n\n"

		pWallet := widgets.NewParagraph()
		pWallet.Title = "Wallet"
		pWallet.SetRect(33, 0, 84, 10)
		pWallet.TextStyle.Fg = ui.ColorWhite
		pWallet.BorderStyle.Fg = ui.ColorYellow
		pWallet.Text = "  Balance:          [waiting...](fg:yellow)\n" +
			"  Currency:         [waiting...](fg:yellow)\n" +
			"  Security:         [waiting...](fg:yellow)\n" +
			"  Staking %:	        [waiting...](fg:yellow)\n" +
			"  Actively Staking: [waiting...](fg:yellow)\n" +
			"  Next Lottery:     [waiting...](fg:yellow)\n" +
			"  Lottery tickets:	  [waiting...](fg:yellow)"

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
		pNetwork.Text = "  Blocks:      [checking...](fg:yellow)\n" +
			"  Difficulty:  [checking...](fg:yellow)\n" +
			"  Blockchain:  [checking...](fg:yellow)\n" +
			"  Masternodes: [checking...](fg:yellow)"

		// var numSeconds int = -1
		updateParagraph := func(count int) {
			var bci be.BlockchainInfoRespStruct
			//var gi be.GetInfoRespStruct
			var mnss be.MNSyncStatusRespStruct
			var ss be.StakingStatusRespStruct
			var wi be.WalletInfoRespStruct
			if gGetBCInfoCount == 0 || gGetBCInfoCount > cliConf.RefreshTimer {
				if gGetBCInfoCount > cliConf.RefreshTimer {
					gGetBCInfoCount = 1
				}
				bci, _ = be.GetBlockchainInfo(&cliConf)

			} else {
				gGetBCInfoCount++
			}
			//gi, _ := getInfo(&cliConf)

			// Check the blockchain sync health
			if err := checkHealth(&bci); err != nil {
				log.Fatalf("Unable to check health: %v", err)
			}

			// Now, we only want to get this other stuff, when the blockchain has synced.
			if bci.Result.Verificationprogress > 0.99 {
				mnss, _ = be.GetMNSyncStatus(&cliConf)
				ss, _ = getStakingStatus(&cliConf)
				if wi, err = getWalletInfo(&cliConf); err != nil {
					log.Fatalf("Unable to get Wallet Info: %v", err)
				}
			}

			// Decide what colour the network panel border should be...
			// If the blockchain or masternodes aren't synced or the network difficulty is < 5000...
			if !mnss.Result.IsBlockchainSynced ||
				mnss.Result.RequestedMasternodeAssets < 999 ||
				bci.Result.Difficulty < 5000 {
				// Now check to see if it's worse than that, and the the nw difficulty is less than 3000
				if bci.Result.Difficulty < 3000 {
					pNetwork.BorderStyle.Fg = ui.ColorRed
				} else {
					// nw difficulty is between 3k-5k
					pNetwork.BorderStyle.Fg = ui.ColorYellow
				}
			} else {
				// We're all good...
				pNetwork.BorderStyle.Fg = ui.ColorGreen
			}

			// Populate the Network panel
			sBlocks := getNetworkBlocksTxt(&bci)
			sDiff := getDifficultyTxt(bci.Result.Difficulty)
			sBlockchainSync := getBlockchainSyncTxt(mnss.Result.IsBlockchainSynced, &bci)
			sMNSync := getMNSyncStatusTxt(&mnss)

			pNetwork.Text = "  " + sBlocks + "\n" +
				"  " + sDiff + "\n" +
				"  " + sBlockchainSync + "\n" +
				"  " + sMNSync

			// Populate the Wallet panel

			// Decide what colour the wallet panel border should be...
			switch wi.Result.EncryptionStatus {
			case cWalletESLocked:
				pWallet.BorderStyle.Fg = ui.ColorYellow
			case cWalletESUnlocked:
				pWallet.BorderStyle.Fg = ui.ColorRed
			case cWalletESUnlockedForStaking:
				pWallet.BorderStyle.Fg = ui.ColorGreen
			case cWalletESUnencrypted:
				pWallet.BorderStyle.Fg = ui.ColorRed
			default:
				pWallet.BorderStyle.Fg = ui.ColorYellow
			}

			// Update the wallet display, if we're all synced up
			if bci.Result.Verificationprogress > 0.9999 {
				pWallet.Text = "" + getBalanceInDiviTxt(&wi) + "\n" +
					"  " + getBalanceInCurrencyTxt(&cliConf, &wi) + "\n" +
					"  " + getWalletSecurityStatusTxt(&wi) + "\n" +
					"  " + getWalletStakingTxt(&wi) + "\n" + //e.g. "15%" or "staking"
					"  " + getActivelyStakingTxt(&ss, &wi) + "\n" + //e.g. "15%" or "staking"
					"  " + getNextLotteryTxt(&cliConf) + "\n" +
					"  " + "Lottery tickets:  0"
			}

			// Update Ticker display
			if gGetTickerInfoCount == 0 || gGetTickerInfoCount > 30 {
				if gGetTickerInfoCount > 30 {
					gGetTickerInfoCount = 1
				}
				_ = updateTickerInfo()
				// Now check to see which currency the user is interested in...
				switch cliConf.Currency {
				case "AUD":
					_ = updateAUDPriceInfo()
				case "GBP":
					_ = updateGBPPriceInfo()
				}
				_ = updateGBPPriceInfo()
				//pTicker.Text = "  " + getTickerPricePerCoinTxt() + "\n" +
				//	"  " + getTickerBTCValueTxt() + "\n" +
				//	"  " + getTicker24HrChangeTxt() + "\n" +
				//	"  " + getTickerWeekChangeTxt() + "\n" +

			}
			gGetTickerInfoCount++
			// numSeconds = numSeconds + 1
			// if numSeconds >= 10 || numSeconds == 0 {
			// 	numSeconds = 0
			// }
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

func checkHealth(bci *be.BlockchainInfoRespStruct) error {
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

func encryptWallet(cliConf *gwc.CLIConfStruct, pw string) (be.GenericRespStruct, error) {
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

func getNetworkBlocksTxt(bci *be.BlockchainInfoRespStruct) string {
	blocksStr := humanize.Comma(int64(bci.Result.Blocks))

	if bci.Result.Blocks > 100 {
		return "Blocks:      [" + blocksStr + "](fg:green)"
	} else {
		return "[Blocks:      " + blocksStr + "](fg:red)"
	}
}

func getBlockchainSyncTxt(synced bool, bci *be.BlockchainInfoRespStruct) string {
	s := gwc.ConvertBCVerification(bci.Result.Verificationprogress)
	if s == "0.0" {
		s = ""
	} else {
		s = s + "%"
	}

	if !synced {
		if bci.Result.Verificationprogress > gLastBCSyncPos {
			gLastBCSyncPos = bci.Result.Verificationprogress
			return "Blockchain:  [syncing " + s + " ](fg:yellow)"
		} else {
			gLastBCSyncPos = bci.Result.Verificationprogress
			return "Blockchain:  [waiting " + s + " ](fg:yellow)"
		}
	} else {
		return "Blockchain:  [synced " + gwc.CUtfTickBold + "](fg:green)"
	}

}

func getDifficultyTxt(difficulty float64) string {
	var s string
	if difficulty > 1000 {
		s = humanize.FormatFloat("#.#", difficulty/1000) + "k"
	} else {
		s = humanize.Ftoa(difficulty)
	}
	if difficulty > 6000 {
		return "Difficulty:  [" + s + "](fg:green)"
	} else if difficulty > 3000 {
		return "[Difficulty:  " + s + "](fg:yellow)"
	} else {
		return "[Difficulty:  " + s + "](fg:red)"
	}
}

func getMNSyncStatusTxt(mnss *be.MNSyncStatusRespStruct) string {
	if mnss.Result.RequestedMasternodeAssets == 999 {
		return "Masternodes: [synced " + gwc.CUtfTickBold + "](fg:green)"
	} else {
		return "Masternodes: [syncing " + getNextProgMNIndicator(lastMNSyncStatus) + "](fg:yellow)"
	}
	//if mnss.Result.RequestedMasternodeAssets < 999 {
	//	if mnss.Result.RequestedMasternodeAssets != lastRMNAssets {
	//		lastRMNAssets = mnss.Result.RequestedMasternodeAssets
	//		return "Masternodes: [syncing " + getNextProgMNIndicator(lastMNSyncStatus) + "](fg:yellow)"
	//	}
	//} else {
	//	return "Masternodes: [synced " + gwc.CUtfTickBold + "](fg:green)"
	//}
	//return ""
}

func getNextLotteryTxt(conf *gwc.CLIConfStruct) string {
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

func getActivelyStakingTxt(ss *be.StakingStatusRespStruct, wi *be.WalletInfoRespStruct) string {
	// Work out balance
	//todo Make sure that we only return yes, if the StakingStatus is true AND we have enough coins
	if ss.Result.StakingStatus == true && (wi.Result.Balance > 10000) {
		return "Actively Staking: [Yes](fg:green)"
	} else {
		return "Actively Staking: [No](fg:yellow)"
	}
}

func getBalanceInDiviTxt(wi *be.WalletInfoRespStruct) string {
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

func getBalanceInCurrencyTxt(conf *gwc.CLIConfStruct, wi *be.WalletInfoRespStruct) string {
	tBalance := wi.Result.ImmatureBalance + wi.Result.UnconfirmedBalance + wi.Result.Balance
	var pricePerCoin float64
	var symbol string

	// Work out what currency
	switch conf.Currency {
	case "AUD":
		symbol = "$"
		pricePerCoin = gTicker.DIVI.Quote.USD.Price * gPricePerCoinAUD.Rates.AUD
	case "USD":
		symbol = "$"
		pricePerCoin = gTicker.DIVI.Quote.USD.Price
	case "GBP":
		symbol = "£"
		pricePerCoin = gTicker.DIVI.Quote.USD.Price * gPricePerCoinGBP.Rates.GBP
	default:
		symbol = "$"
		pricePerCoin = gTicker.DIVI.Quote.USD.Price
	}

	tBalanceCurrency := pricePerCoin * tBalance

	tBalanceCurrencyStr := humanize.FormatFloat("###,###.##", tBalanceCurrency) //humanize.Commaf(tBalanceCurrency) //FormatFloat("#,###.####", tBalanceCurrency)

	// Work out balance
	if wi.Result.ImmatureBalance > 0 {
		return "Incoming......... [" + symbol + tBalanceCurrencyStr + "](fg:cyan)"
	} else if wi.Result.UnconfirmedBalance > 0 {
		return "Confirming....... [" + symbol + tBalanceCurrencyStr + "](fg:yellow)"
	} else {
		return "Currency:         [" + symbol + tBalanceCurrencyStr + "](fg:green)"
	}
}

func getWalletStakingTxt(wi *be.WalletInfoRespStruct) string {
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

func getWalletSecurityStatusTxt(wi *be.WalletInfoRespStruct) string {
	switch wi.Result.EncryptionStatus {
	case cWalletESLocked:
		return "Security:         [Locked - Not Staking](fg:yellow)"
	case cWalletESUnlocked:
		return "Security:         [UNLOCKED](fg:red)"
	case cWalletESUnlockedForStaking:
		return "Security:         [Locked and Staking](fg:green)"
	case cWalletESUnencrypted:
		return "Security:         [UNENCRYPTED](fg:red)"
	default:
		return "Security:         [checking...](fg:yellow)"
	}
}

func getInfo(cliConf *gwc.CLIConfStruct) (getinfoRespStruct, error) {
	attempts := 5
	waitingStr := "Checking server..."
	var respStruct getinfoRespStruct

	for i := 1; i < 50; i++ {
		fmt.Printf("\r"+waitingStr+" %d/"+strconv.Itoa(attempts), i)
		body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"getinfo\",\"params\":[]}")
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
		if bytes.Contains(bodyResp, []byte("Loading")) {
			// The wallet is still loading, so print message, and sleep for 3 seconds and try again...
			var errStruct be.GenericRespStruct
			err = json.Unmarshal(bodyResp, &errStruct)
			if err != nil {
				return respStruct, err
			}
			//fmt.Println("Waiting for wallet to load...")
			time.Sleep(5 * time.Second)
		} else {

			_ = json.Unmarshal(bodyResp, &respStruct)
			return respStruct, err
		}
	}
	return respStruct, nil
}

func getLotteryInfo(cliConf *gwc.CLIConfStruct) (be.LotteryRespStruct, error) {
	var respStruct be.LotteryRespStruct

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

func updateAUDPriceInfo() error {
	resp, err := http.Get("https://api.exchangeratesapi.io/latest?base=USD&symbols=AUD")
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	body, err := ioutil.ReadAll(resp.Body)
	if err != nil {
		return err
	}
	err = json.Unmarshal(body, &gPricePerCoinAUD)
	if err != nil {
		return err
	}
	return errors.New("unable to updateAUDPriceInfo")
}

func updateGBPPriceInfo() error {
	resp, err := http.Get("https://api.exchangeratesapi.io/latest?base=USD&symbols=GBP")
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	body, err := ioutil.ReadAll(resp.Body)
	if err != nil {
		return err
	}
	err = json.Unmarshal(body, &gPricePerCoinGBP)
	if err != nil {
		return err
	}
	return errors.New("unable to updateGBPPriceInfo")
}

func updateTickerInfo() error {
	resp, err := http.Get("https://ticker.neist.io/DIVI")
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	body, err := ioutil.ReadAll(resp.Body)
	if err != nil {
		return err
	}
	err = json.Unmarshal(body, &gTicker)
	if err != nil {
		return err
	}
	return errors.New("unable to updateTicketInfo")
}

func getNextProgMNIndicator(LIndicator string) string {
	if LIndicator == cProg1 {
		lastMNSyncStatus = cProg2
		return cProg2
	} else if LIndicator == cProg2 {
		lastMNSyncStatus = cProg3
		return cProg3
	} else if LIndicator == cProg3 {
		lastMNSyncStatus = cProg4
		return cProg4
	} else if LIndicator == cProg4 {
		lastMNSyncStatus = cProg5
		return cProg5
	} else if LIndicator == cProg5 {
		lastMNSyncStatus = cProg6
		return cProg6
	} else if LIndicator == cProg6 {
		lastMNSyncStatus = cProg7
		return cProg7
	} else if LIndicator == cProg7 {
		lastMNSyncStatus = cProg8
		return cProg8
	} else if LIndicator == cProg8 || LIndicator == "" {
		lastMNSyncStatus = cProg1
		return cProg1
	} else {
		lastMNSyncStatus = cProg1
		return cProg1
	}
}

func getPrivateKey(token string) (m.PrivateKeyStruct, error) {
	ws := m.WalletRequestStruct{}
	ws.WalletRequest = gwc.CWalletRequestGetPrivateKey

	var respStruct m.PrivateKeyStruct
	waitingStr := "Attempt..."
	attempts := 5
	requestBody, err := json.Marshal(ws)
	if err != nil {
		return respStruct, err
	}

	for i := 1; i < 5; i++ {
		fmt.Printf("\r"+waitingStr+" %d/"+strconv.Itoa(attempts), i)

		//_, _ = http.Post("http://127.0.0.1:4000/server/", "application/json", bytes.NewBuffer(requestBody))
		resp, err := http.Post("http://127.0.0.1:4000/wallet/", "application/json", bytes.NewBuffer(requestBody))
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

		if err == nil && respStruct.ResponseCode == gwc.NoServerError {
			return respStruct, nil
		} else {
			time.Sleep(1 * time.Second)
		}
	}

	return respStruct, errors.New("unable to retrieve WalletStatus from server")
}

func getPrivateKeyNew(cliConf *gwc.CLIConfStruct) (hdinfoRespStruct, error) {
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

func getStakingStatus(cliConf *gwc.CLIConfStruct) (be.StakingStatusRespStruct, error) {
	var respStruct be.StakingStatusRespStruct

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"getstakingstatus\",\"params\":[]}")
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
	fmt.Println("Please enter the response: " + gwc.CSeedStoredSafelyStr)
	resp, _ := reader.ReadString('\n')
	if resp == gwc.CSeedStoredSafelyStr+"\n" {
		return true
	}

	return false
}

func getWalletInfo(cliConf *gwc.CLIConfStruct) (be.WalletInfoRespStruct, error) {
	var respStruct be.WalletInfoRespStruct

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"getwalletinfo\",\"params\":[]}")
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
