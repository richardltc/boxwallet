/*
Package cmd ...
Copyright © 2020 NAME HERE <EMAIL ADDRESS>

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
	// "fmt"
	"log"
	xbc "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/bitcoinplus"
	divi "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/divi"
	ppc "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/peercoin"
	rpd "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/rapids"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/models"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/wallet"

	// be "richardmace.co.uk/boxwallet/cmd/cli/cmd/bend"

	"fmt"
	"github.com/spf13/cobra"
	"os"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/app"

	"richardmace.co.uk/boxwallet/cmd/cli/cmd/conf"
)

// encryptCmd represents the encrypt command
var encryptCmd = &cobra.Command{
	Use:   "encrypt",
	Short: "Encrypts your wallet",
	Long:  ``,
	Run: func(cmd *cobra.Command, args []string) {
		var app app.App

		fmt.Println("  ____          __          __   _ _      _   \n |  _ \\         \\ \\        / /  | | |    | |  \n | |_) | _____  _\\ \\  /\\  / /_ _| | | ___| |_ \n |  _ < / _ \\ \\/ /\\ \\/  \\/ / _` | | |/ _ \\ __|\n | |_) | (_) >  <  \\  /\\  / (_| | | |  __/ |_ \n |____/ \\___/_/\\_\\  \\/  \\/ \\__,_|_|_|\\___|\\__| v" + app.Version() + "\n                                              \n                                               ")

		var conf conf.Conf
		var walletSecurityState wallet.WalletSecurityState
		var walletEncrypt wallet.WalletEncrypt

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

		// Now load our config file to see what coin choice the user made....
		confDB, err := conf.GetConfig(true)
		if err != nil {
			log.Fatal("Unable to determine coin type. Please run " + appFileName + " coin: " + err.Error())
		}

		switch confDB.ProjectType {
		case models.PTBitcoinPlus:
			walletSecurityState = xbc.XBC{}
			walletEncrypt = xbc.XBC{}
		case models.PTDenarius:
		case models.PTDeVault:
		case models.PTDigiByte:
		case models.PTDivi:
			walletSecurityState = divi.Divi{}
			walletEncrypt = divi.Divi{}
		case models.PTFeathercoin:
		case models.PTGroestlcoin:
		case models.PTPeercoin:
			walletSecurityState = ppc.Peercoin{}
			walletEncrypt = ppc.Peercoin{}
		case models.PTPhore:
		case models.PTPIVX:
		case models.PTRapids:
			walletSecurityState = rpd.Rapids{}
			walletEncrypt = rpd.Rapids{}
		case models.PTReddCoin:
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

		wst, err := walletSecurityState.WalletSecurityState(&coinAuth)
		if err != nil {
			log.Fatal("Unable to determine Wallet Security State: " + err.Error())
		}
		if wst != models.WETUnencrypted {
			log.Fatal("Wallet is already encrypted")
		}

		wep := wallet.GetWalletEncryptionPassword()
		if wep == "" {
			log.Fatal("Password was blank or didn't match")
		}

		r, err := walletEncrypt.WalletEncrypt(&coinAuth, wep)
		if err != nil {
			log.Fatal("failed to encrypt wallet: ", err.Error())
		}

		fmt.Println(r.Result)

		// Lets load our config file first, to see if the user has made their coin choice..
		// cliConf, err := be.GetConfigStruct("", true)
		// if err != nil {
		// 	log.Fatal("Unable to determine coin type. Please run " + be.CAppFilename + " coin" + err.Error())
		// }

		// sCoinDaemonName, err := be.GetCoinDaemonFilename(be.APPTCLI, cliConf.ProjectType)
		// if err != nil {
		// 	log.Fatal("Unable to GetCoinDaemonFilename " + err.Error())
		// }

		// switch cliConf.ProjectType {
		// case be.PTBitcoinPlus:
		// 	wet, err := be.GetWalletEncryptionStatus()
		// 	if err != nil {
		// 		log.Fatalf("Unable to determine wallet encryption status")
		// 	}
		// 	if wet != be.WETUnencrypted {
		// 		log.Fatal("Wallet is already encrypted")
		// 	}
		// case be.PTDenarius:
		// 	wet, err := be.GetWalletEncryptionStatus()
		// 	if err != nil {
		// 		log.Fatalf("Unable to determine wallet encryption status")
		// 	}
		// 	if wet != be.WETUnencrypted {
		// 		log.Fatal("Wallet is already encrypted")
		// 	}
		// case be.PTDeVault:
		// 	wet, err := be.GetWalletEncryptionStatus()
		// 	if err != nil {
		// 		log.Fatalf("Unable to determine wallet encryption status")
		// 	}
		// 	if wet != be.WETUnencrypted {
		// 		log.Fatal("Wallet is already encrypted")
		// 	}
		// case be.PTDigiByte:
		// 	wet, err := be.GetWalletEncryptionStatus()
		// 	if err != nil {
		// 		log.Fatalf("Unable to determine wallet encryption status")
		// 	}
		// 	if wet != be.WETUnencrypted {
		// 		log.Fatal("Wallet is already encrypted")
		// 	}
		// case be.PTDivi:
		// 	wet, err := be.GetWalletEncryptionStatus()
		// 	if err != nil {
		// 		log.Fatalf("Unable to determine wallet encryption status")
		// 	}
		// 	if wet != be.WETUnencrypted {
		// 		log.Fatal("Wallet is already encrypted")
		// 	}

		// 	//// Check wallet encryption status
		// 	//wi, err := be.GetWalletInfoDivi(&cliConf)
		// 	//if err != nil {
		// 	//	log.Fatal("Unable to getWalletInfo " + err.Error())
		// 	//}
		// 	//
		// 	//if (wi.Result.EncryptionStatus != "unencrypted") && (wi.Result.EncryptionStatus != "") {
		// 	//	log.Fatal("Wallet is already encrypted")
		// 	//}
		// case be.PTGroestlcoin:
		// 	wet, err := be.GetWalletEncryptionStatus()
		// 	if err != nil {
		// 		log.Fatalf("Unable to determine wallet encryption status")
		// 	}
		// 	if wet != be.WETUnencrypted {
		// 		log.Fatal("Wallet is already encrypted")
		// 	}
		// case be.PTPhore:
		// 	wet, err := be.GetWalletEncryptionStatus()
		// 	if err != nil {
		// 		log.Fatalf("Unable to determine wallet encryption status")
		// 	}
		// 	if wet != be.WETUnencrypted {
		// 		log.Fatal("Wallet is already encrypted")
		// 	}
		// case be.PTPIVX:
		// 	wet, err := be.GetWalletEncryptionStatus()
		// 	if err != nil {
		// 		log.Fatalf("Unable to determine wallet encryption status")
		// 	}
		// 	if wet != be.WETUnencrypted {
		// 		log.Fatal("Wallet is already encrypted")
		// 	}
		// case be.PTReddCoin:
		// 	wet, err := be.GetWalletEncryptionStatus()
		// 	if err != nil {
		// 		log.Fatalf("Unable to determine wallet encryption status")
		// 	}
		// 	if wet != be.WETUnencrypted {
		// 		log.Fatal("Wallet is already encrypted")
		// 	}
		// case be.PTTrezarcoin:
		// 	wet, err := be.GetWalletEncryptionStatus()
		// 	if err != nil {
		// 		log.Fatalf("Unable to determine wallet encryption status")
		// 	}
		// 	if wet != be.WETUnencrypted {
		// 		log.Fatal("Wallet is already encrypted")
		// 	}
		// case be.PTVertcoin:
		// 	wet, err := be.GetWalletEncryptionStatus()
		// 	if err != nil {
		// 		log.Fatalf("Unable to determine wallet encryption status")
		// 	}
		// 	if wet != be.WETUnencrypted {
		// 		log.Fatal("Wallet is already encrypted")
		// 	}
		// default:
		// 	log.Fatal("Unable to determine project type ")
		// }

		// wep := be.GetPasswordToEncryptWallet()
		// r, err := encryptWallet(&cliConf, wep)
		// if err != nil {
		// 	log.Fatalf("failed to encrypt wallet %s\n", err)
		// }
		// fmt.Println(r.Result)
		// // Start the coin daemon server if required...
		// if err := be.StartCoinDaemon(true); err != nil {
		// 	log.Fatalf("failed to run "+sCoinDaemonName+": %v", err)
		// }

		// // sAppCLIName, err := gwc.GetAppCLIName() // e.g. GoDivi CLI
		// // if err != nil {
		// // 	log.Fatal("Unable to GetAppCLIName " + err.Error())
		// // }

		// // sAppFileCLIName, err := gwc.GetAppFileName(gwc.APPTCLI)
		// // if err != nil {
		// // 	log.Fatal("Unable to GetAppFileCLIName " + err.Error())
		// // }
		// // sCoinDaemonFile, err := gwc.GetCoinDaemonFilename()
		// // if err != nil {
		// // 	log.Fatal("Unable to GetCoinDaemonFilename " + err.Error())
		// // }

		// // // Check to make sure we're installed
		// // if !gwc.IsGoWalletInstalled() { //DiviInstalled() {
		// // 	log.Fatal(sAppCLIName + ` doesn't appear to be installed yet. Please run "` + sAppFileCLIName + ` install" first`)
		// // }

		// // // Start the Coin Daemon server if required...
		// // err = gwc.StartCoinDaemon(true) //DiviD(true)
		// // if err != nil {
		// // 	log.Fatalf("failed to run "+sCoinDaemonFile+": %v", err)
		// // }

		// // wi, err := gwc.GetWalletInfo(true)
		// // if err != nil {
		// // 	log.Fatalf("error getting wallet info: %v", err)
		// // }

		// // fmt.Println("Wallet status is: " + wi.EncryptionStatus)
		// // if wi.EncryptionStatus != "unencrypted" {
		// // 	log.Fatalf("Looks like your wallet is already encrypted")
		// // }

		// // }

	},
}

func init() {
	walletCmd.AddCommand(encryptCmd)

	// Here you will define your flags and configuration settings.

	// Cobra supports Persistent Flags which will work for this command
	// and all subcommands, e.g.:
	// encryptCmd.PersistentFlags().String("foo", "", "A help for foo")

	// Cobra supports local flags which will only run when this command
	// is called directly, e.g.:
	// encryptCmd.Flags().BoolP("toggle", "t", false, "Help message for toggle")
}
