/*
Copyright © 2021 NAME HERE <EMAIL ADDRESS>

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
	// "log"
	// "os"
	// be "richardmace.co.uk/boxwallet/cmd/cli/cmd/bend"

	"fmt"
	"github.com/AlecAivazis/survey/v2"
	"github.com/spf13/cobra"
	"log"
	"os"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/app"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/coins"
	xbc "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/bitcoinplus"
	divi "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/divi"
	rdd "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/reddcoin"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/conf"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/models"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/wallet"
)

// sendCmd represents the send command
var sendCmd = &cobra.Command{
	Use:   "send",
	Short: "Send coins to another wallet",
	Long: `A longer description that spans multiple lines and likely contains examples
and usage of using your command. For example:

Cobra is a CLI library for Go that empowers applications.
This application is a tool to generate the needed files
to quickly create a Cobra application.`,
	Run: func(cmd *cobra.Command, args []string) {
		var app app.App

		fmt.Println("  ____          __          __   _ _      _   \n |  _ \\         \\ \\        / /  | | |    | |  \n | |_) | _____  _\\ \\  /\\  / /_ _| | | ___| |_ \n |  _ < / _ \\ \\/ /\\ \\/  \\/ / _` | | |/ _ \\ __|\n | |_) | (_) >  <  \\  /\\  / (_| | | |  __/ |_ \n |____/ \\___/_/\\_\\  \\/  \\/ \\__,_|_|_|\\___|\\__| v" + app.Version() + "\n                                              \n                                               ")

		var conf conf.Conf
		var coinName coins.CoinName
		var daemonRunning coins.CoinDaemon
		var walletSecurityState wallet.WalletSecurityState
		var walletUnlock wallet.WalletUnlock
		var walletValidateAddress wallet.WalletVaidateAddress
		var sendToAddress wallet.WalletSendToAddress

		appHomeDir, err := app.HomeFolder()
		if err != nil {
			log.Fatal("Unable to get HomeFolder: " + err.Error())
		}

		conf.Bootstrap(appHomeDir)

		appFileName, err := app.FileName()
		if err != nil {
			log.Fatal("Unable to get appFilename: " + err.Error())
		}

		// Make sure the config file exists, and if not, force user to use "coin" command first...
		if _, err := os.Stat(appHomeDir + conf.ConfFile()); os.IsNotExist(err) {
			log.Fatal("Unable to determine coin type. Please run " + appFileName + " coin  first")
		}

		// Now load our config file to see what coin choice the user made...
		confDB, err := conf.GetConfig(true)
		if err != nil {
			log.Fatal("Unable to determine coin type. Please run " + appFileName + " coin: " + err.Error())
		}

		switch confDB.ProjectType {
		case models.PTBitcoinPlus:
			walletSecurityState = xbc.XBC{}
		case models.PTDenarius:
		case models.PTDeVault:
		case models.PTDigiByte:
		case models.PTDivi:
			coinName = divi.Divi{}
			daemonRunning = divi.Divi{}
			walletSecurityState = divi.Divi{}
			walletUnlock = divi.Divi{}
			walletValidateAddress = divi.Divi{}
			sendToAddress = divi.Divi{}
		case models.PTFeathercoin:
		case models.PTGroestlcoin:
		case models.PTPhore:
		case models.PTPeercoin:
		case models.PTPIVX:
		case models.PTRapids:
		case models.PTReddCoin:
			coinName = rdd.ReddCoin{}
			daemonRunning = rdd.ReddCoin{}
			walletSecurityState = rdd.ReddCoin{}
			walletUnlock = rdd.ReddCoin{}
			walletValidateAddress = rdd.ReddCoin{}
			sendToAddress = rdd.ReddCoin{}
		case models.PTScala:
		case models.PTTrezarcoin:
		case models.PTVertcoin:
		default:
			log.Fatal("unable to determine ProjectType")
		}

		var coinAuth models.CoinAuth
		coinAuth.RPCUser = confDB.RPCuser
		coinAuth.RPCPassword = confDB.RPCpassword
		coinAuth.IPAddress = confDB.ServerIP
		coinAuth.Port = confDB.Port

		// Check to see if we are running the coin daemon locally, and if we are, make sure it's actually running
		// before attempting to connect to it.
		if coinAuth.IPAddress == "127.0.0.1" {
			bCDRunning, err := daemonRunning.DaemonRunning()
			if err != nil {
				log.Fatal("Unable to determine if coin daemon is running: " + err.Error())
			}
			if !bCDRunning {
				log.Fatal("Unable to communicate with the " + coinName.CoinName() + " server. Please make sure the " + coinName.CoinName() + " server is running, by running:\n\n" +
					appFileName + " start\n\n")
			}
		}

		// Then ask for the amount they want to send
		var amount float32
		promptAmount := &survey.Input{
			Message: "How much " + coinName.CoinNameAbbrev() + " would you like to send?",
		}
		survey.AskOne(promptAmount, &amount)

		// Then ask for the address
		address := ""
		promptAddress := &survey.Input{
			Message: "Which " + coinName.CoinName() + " address would you like to send to?",
		}
		survey.AskOne(promptAddress, &address)

		// Validate address as best we can...
		// DIVI, length is 34 and starts with a D
		av := walletValidateAddress.ValidateAddress(address)
		if !av {
			log.Fatalf("It looks like the address that you are sending to is not a " + coinName.CoinName() + " address?\n\n" +
				"Please check and try again.")
		}

		// Then ask for confirmation
		send := false
		promptConfirm := &survey.Confirm{
			Message: "Are you sure?\n\nSend: " + fmt.Sprintf("%f", amount) + "\n\nTo " + coinName.CoinName() + " address: " + address + "\n\n",
		}
		survey.AskOne(promptConfirm, &send)

		// Check that their wallet is unlocked

		wst, err := walletSecurityState.WalletSecurityState(&coinAuth)
		if err != nil {
			log.Fatal("Unable to determine Wallet Security State: " + err.Error())
		}
		if wst != models.WETUnlocked {
			wep := coins.GetWalletEncryptionPassword()
			err := walletUnlock.WalletUnlock(&coinAuth, wep)
			if err != nil {
				log.Fatalf("failed to unlock wallet %s\n", err)
			}
		}

		// Then send..
		if send {
			if r, err := sendToAddress.SendToAddress(&coinAuth, address, amount); err != nil {
				log.Fatalf("unable to send: %v", err)
			} else {
				fmt.Printf("Payment sent\n\n")
				fmt.Println("txid: " + r.Result)
			}
		}

		// 	wet := be.GetWalletSecurityStateDivi(&wi)
		// 	if wet != be.WETUnlocked {
		// 		wep := be.GetWalletEncryptionPassword()
		// 		r, err := unlockWallet(&cliConf, wep)
		// 		if err != nil || r.Error != nil {
		// 			log.Fatalf("failed to unlock wallet %s\n", err)
		// 		}
		// 	}

		// apw, err := be.GetAppWorkingFolder()
		// if err != nil {
		// 	log.Fatal("Unable to GetAppWorkingFolder: " + err.Error())
		// }

		// // Make sure the config file exists, and if not, force user to use "coin" command first..
		// if _, err := os.Stat(apw + be.CConfFile + be.CConfFileExt); os.IsNotExist(err) {
		// 	log.Fatal("Unable to determine coin type. Please run " + be.CAppFilename + " coin  first")
		// }

		// sAppFileCLIName, err := be.GetAppFileName()
		// if err != nil {
		// 	log.Fatal("Unable to GetAppFileCLIName " + err.Error())
		// }

		// cliConf, err := be.GetConfigStruct("", true)
		// if err != nil {
		// 	log.Fatal("Unable to GetCLIConfStruct " + err.Error())
		// }

		// sAppFileCLIName, err = be.GetAppFileName()
		// if err != nil {
		// 	log.Fatal("Unable to GetAppFileCLIName " + err.Error())
		// }

		// coind, err := be.GetCoinDaemonFilename(be.APPTCLI, cliConf.ProjectType)
		// if err != nil {
		// 	log.Fatalf("Unable to GetCoinDaemonFilename - %v", err)
		// }

		// // Check to see if we are running the coin daemon locally, and if we are, make sure it's actually running
		// // before attempting to connect to it.
		// if cliConf.ServerIP == "127.0.0.1" {
		// 	bCDRunning, _, err := be.IsCoinDaemonRunning(cliConf.ProjectType)
		// 	if err != nil {
		// 		log.Fatal("Unable to determine if coin daemon is running: " + err.Error())
		// 	}
		// 	if !bCDRunning {
		// 		log.Fatal("Unable to communicate with the " + coind + " server. Please make sure the " + coind + " server is running, by running:\n\n" +
		// 			"./" + sAppFileCLIName + " start\n\n")
		// 	}
		// }

		// wRunning, _, err := confirmWalletReady()
		// if err != nil {
		// 	log.Fatal("Unable to determine if wallet is ready: " + err.Error())
		// }

		// if !wRunning {
		// 	fmt.Println("")
		// 	log.Fatal("Unable to communicate with the " + coind + " server. Please make sure the " + coind + " server is running, by running:\n\n" +
		// 		"./" + sAppFileCLIName + " start\n\n")
		// }

		// cn, err := be.GetCoinName(be.APPTCLI)
		// if err != nil {
		// 	log.Fatal("Unable to GetCoinName: " + err.Error())
		// }

		// // Then ask for the amount they want to send
		// var amount float32
		// promptAmount := &survey.Input{
		// 	Message: "How much would you like to send?",
		// }
		// survey.AskOne(promptAmount, &amount)

		// // Then ask for the address
		// address := ""
		// promptAddress := &survey.Input{
		// 	Message: "Which " + cn + " address would you like to send to?",
		// }
		// survey.AskOne(promptAddress, &address)

		// // Validate address as best we can...
		// // DIVI, length is 34 and starts with a D
		// av := false
		// if av, err = be.ValidateAddress(cliConf.ProjectType, address); err != nil {
		// 	log.Fatalf("Unable to validate address: %v", err)
		// }
		// if !av {
		// 	log.Fatalf("It looks like the address that you are sending to is not a " + cn + " address?\n\n" +
		// 		"Please check and try again.")
		// }

		// // Then ask for confirmation
		// send := false
		// promptConfirm := &survey.Confirm{
		// 	Message: "Are you sure?\n\nSend: " + fmt.Sprintf("%f", amount) + "\n\nTo " + cn + " address: " + address + "\n\n",
		// }
		// survey.AskOne(promptConfirm, &send)

		// // Check that their wallet is unlocked

		// switch cliConf.ProjectType {
		// case be.PTDenarius:
		// 	wi, err := be.GetInfoDenarius(&cliConf)
		// 	if err != nil {
		// 		log.Fatalf("error getting wallet info: %v", err)
		// 	}
		// 	wet := be.GetWalletSecurityStateDenarius(&wi)
		// 	if wet != be.WETUnlocked {
		// 		wep := be.GetWalletEncryptionPassword()
		// 		r, err := unlockWallet(&cliConf, wep)
		// 		if err != nil || r.Error != nil {
		// 			log.Fatalf("failed to unlock wallet %s\n", err)
		// 		}
		// 	}
		// case be.PTDeVault:
		// 	wi, err := be.GetWalletInfoDVT(&cliConf)
		// 	if err != nil {
		// 		log.Fatalf("error getting wallet info: %v", err)
		// 	}
		// 	wet := be.GetWalletSecurityStateDVT(&wi)
		// 	if wet != be.WETUnlocked {
		// 		wep := be.GetWalletEncryptionPassword()
		// 		r, err := unlockWallet(&cliConf, wep)
		// 		if err != nil || r.Error != nil {
		// 			log.Fatalf("failed to unlock wallet %s\n", err)
		// 		}
		// 	}
		// case be.PTDigiByte:
		// 	wi, err := be.GetWalletInfoDGB(&cliConf)
		// 	if err != nil {
		// 		log.Fatalf("error getting wallet info: %v", err)
		// 	}
		// 	wet := be.GetWalletSecurityStateDGB(&wi)
		// 	if wet != be.WETUnlocked {
		// 		wep := be.GetWalletEncryptionPassword()
		// 		r, err := unlockWallet(&cliConf, wep)
		// 		if err != nil || r.Error != nil {
		// 			log.Fatalf("failed to unlock wallet %s\n", err)
		// 		}
		// 	}
		// case be.PTDivi:
		// 	wi, err := be.GetWalletInfoDivi(&cliConf)
		// 	if err != nil {
		// 		log.Fatalf("error getting wallet info: %v", err)
		// 	}
		// 	wet := be.GetWalletSecurityStateDivi(&wi)
		// 	if wet != be.WETUnlocked {
		// 		wep := be.GetWalletEncryptionPassword()
		// 		r, err := unlockWallet(&cliConf, wep)
		// 		if err != nil || r.Error != nil {
		// 			log.Fatalf("failed to unlock wallet %s\n", err)
		// 		}
		// 	}
		// case be.PTFeathercoin:
		// 	wi, err := be.GetWalletInfoFeathercoin(&cliConf)
		// 	if err != nil {
		// 		log.Fatalf("error getting wallet info: %v", err)
		// 	}
		// 	wet := be.GetWalletSecurityStateFeathercoin(&wi)
		// 	if wet != be.WETUnlocked {
		// 		wep := be.GetWalletEncryptionPassword()
		// 		r, err := unlockWallet(&cliConf, wep)
		// 		if err != nil || r.Error != nil {
		// 			log.Fatalf("failed to unlock wallet %s\n", err)
		// 		}
		// 	}
		// case be.PTGroestlcoin:
		// 	wi, err := be.GetWalletInfoGRS(&cliConf)
		// 	if err != nil {
		// 		log.Fatalf("error getting wallet info: %v", err)
		// 	}
		// 	wet := be.GetWalletSecurityStateGRS(&wi)
		// 	if wet != be.WETUnlocked {
		// 		wep := be.GetWalletEncryptionPassword()
		// 		r, err := unlockWallet(&cliConf, wep)
		// 		if err != nil || r.Error != nil {
		// 			log.Fatalf("failed to unlock wallet %s\n", err)
		// 		}
		// 	}
		// case be.PTPhore:
		// 	wi, err := be.GetWalletInfoPhore(&cliConf)
		// 	if err != nil {
		// 		log.Fatalf("error getting wallet info: %v", err)
		// 	}
		// 	wet := be.GetWalletSecurityStatePhore(&wi)
		// 	if wet != be.WETUnlocked {
		// 		wep := be.GetWalletEncryptionPassword()
		// 		r, err := unlockWallet(&cliConf, wep)
		// 		if err != nil || r.Error != nil {
		// 			log.Fatalf("failed to unlock wallet %s\n", err)
		// 		}
		// 	}
		// case be.PTPIVX:
		// 	wi, err := be.GetWalletInfoPIVX(&cliConf)
		// 	if err != nil {
		// 		log.Fatalf("error getting wallet info: %v", err)
		// 	}
		// 	wet := be.GetWalletSecurityStatePIVX(&wi)
		// 	if wet != be.WETUnlocked {
		// 		wep := be.GetWalletEncryptionPassword()
		// 		r, err := unlockWallet(&cliConf, wep)
		// 		if err != nil || r.Error != nil {
		// 			log.Fatalf("failed to unlock wallet %s\n", err)
		// 		}
		// 	}
		// case be.PTRapids:
		// 	wi, err := be.GetWalletInfoRapids(&cliConf)
		// 	if err != nil {
		// 		log.Fatalf("error getting wallet info: %v", err)
		// 	}
		// 	wet := be.GetWalletSecurityStateRapids(&wi)
		// 	if wet != be.WETUnlocked {
		// 		wep := be.GetWalletEncryptionPassword()
		// 		r, err := unlockWallet(&cliConf, wep)
		// 		if err != nil || r.Error != nil {
		// 			log.Fatalf("failed to unlock wallet %s\n", err)
		// 		}
		// 	}
		// case be.PTReddCoin:
		// 	wi, err := be.GetWalletInfoRDD(&cliConf)
		// 	if err != nil {
		// 		log.Fatalf("error getting wallet info: %v", err)
		// 	}
		// 	wet := be.GetWalletSecurityStateRDD(&wi)
		// 	if wet != be.WETUnlocked {
		// 		wep := be.GetWalletEncryptionPassword()
		// 		r, err := unlockWallet(&cliConf, wep)
		// 		if err != nil || r.Error != nil {
		// 			log.Fatalf("failed to unlock wallet %s\n", err)
		// 		}
		// 	}
		// case be.PTTrezarcoin:
		// 	wi, err := be.GetWalletInfoTrezarcoin(&cliConf)
		// 	if err != nil {
		// 		log.Fatalf("error getting wallet info: %v", err)
		// 	}
		// 	wet := be.GetWalletSecurityStateTrezarcoin(&wi)
		// 	if wet != be.WETUnlocked {
		// 		wep := be.GetWalletEncryptionPassword()
		// 		r, err := unlockWallet(&cliConf, wep)
		// 		if err != nil || r.Error != nil {
		// 			log.Fatalf("failed to unlock wallet %s\n", err)
		// 		}
		// 	}
		// case be.PTVertcoin:
		// 	wi, err := be.GetWalletInfoVTC(&cliConf)
		// 	if err != nil {
		// 		log.Fatalf("error getting wallet info: %v", err)
		// 	}
		// 	wet := be.GetWalletSecurityStateVTC(&wi)
		// 	if wet != be.WETUnlocked {
		// 		wep := be.GetWalletEncryptionPassword()
		// 		r, err := unlockWallet(&cliConf, wep)
		// 		if err != nil || r.Error != nil {
		// 			log.Fatalf("failed to unlock wallet %s\n", err)
		// 		}
		// 	}
		// default:
		// 	log.Fatalf("It looks like " + cn + " does not currently support this command.")
		// }

		// // Then send..
		// if send {
		// 	if r, err := be.SendToAddressDivi(&cliConf, address, amount); err != nil {
		// 		log.Fatalf("unable to send: %v", err)
		// 	} else {
		// 		fmt.Printf("Payment sent\n\n")
		// 		fmt.Println(r.Result)
		// 	}
		// }
	},
}

func init() {
	rootCmd.AddCommand(sendCmd)

	// Here you will define your flags and configuration settings.

	// Cobra supports Persistent Flags which will work for this command
	// and all subcommands, e.g.:
	// sendCmd.PersistentFlags().String("foo", "", "A help for foo")

	// Cobra supports local flags which will only run when this command
	// is called directly, e.g.:
	// sendCmd.Flags().BoolP("toggle", "t", false, "Help message for toggle")
}
