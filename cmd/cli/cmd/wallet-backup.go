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
	"fmt"
	"os"
	"path/filepath"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/app"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/coins"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/divi"
	ppc "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/peercoin"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/conf"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/models"

	// "fmt"
	"github.com/spf13/cobra"
	"log"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/wallet"
	// "log"
	// be "richardmace.co.uk/boxwallet/cmd/cli/cmd/bend"
)

// backupCmd represents the backup command
var backupCmd = &cobra.Command{
	Use:   "backup",
	Short: "Performs a backup of the wallet.dat file for the current coin",
	Long:  `Copies the waller.dat file, of the currently selected coin, to the current directory`,
	Run: func(cmd *cobra.Command, args []string) {
		var app app.App

		fmt.Println("  ____          __          __   _ _      _   \n |  _ \\         \\ \\        / /  | | |    | |  \n | |_) | _____  _\\ \\  /\\  / /_ _| | | ___| |_ \n |  _ < / _ \\ \\/ /\\ \\/  \\/ / _` | | |/ _ \\ __|\n | |_) | (_) >  <  \\  /\\  / (_| | | |  __/ |_ \n |____/ \\___/_/\\_\\  \\/  \\/ \\__,_|_|_|\\___|\\__| v" + app.Version() + "\n                                              \n                                               ")

		var conf conf.Conf
		var coinName coins.CoinName
		var daemonRunning coins.CoinDaemon
		var walletSecurityState wallet.WalletSecurityState
		var walletBackup wallet.WalletBackup

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

		switch confDB.ProjectType {
		case models.PTBitcoinPlus:
		case models.PTDenarius:
		case models.PTDeVault:
		case models.PTDigiByte:
		case models.PTDivi:
			coinName = divi.Divi{}
			daemonRunning = divi.Divi{}
			walletSecurityState = divi.Divi{}
			walletBackup = divi.Divi{}
		case models.PTFeathercoin:
		case models.PTGroestlcoin:
		case models.PTPeercoin:
			coinName = ppc.Peercoin{}
			daemonRunning = ppc.Peercoin{}
			walletSecurityState = ppc.Peercoin{}
			walletBackup = ppc.Peercoin{}
		case models.PTPhore:
		case models.PTPIVX:
		case models.PTRapids:
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

		wst, err := walletSecurityState.WalletSecurityState(&coinAuth)
		if err != nil {
			log.Fatal("Unable to determine Wallet Security State: " + err.Error())
		}
		if wst == models.WETUnencrypted {
			log.Fatal("Your wallet is not currently encrypted! Please encrypt before backing up\n\n" +
				"Your wallet has ***NOT*** been backed up!")
		}

		ex, err := os.Executable()
		if err != nil {
			panic(err)
		}
		exPath := filepath.Dir(ex)

		r, err := walletBackup.WalletBackup(&coinAuth, exPath)
		if err != nil {
			log.Fatal("failed to backup wallet: \n\n"+r.Result, err.Error())
		}

		fmt.Println("Your wallet.dat file has been backed up to: " + exPath)

		// The user has just chosen the wallet backup command, without specifying the coin type, so let's see if we have one
		// bwConf, err := be.GetConfigStruct("", true)
		// if err != nil {
		// 	log.Fatal("Unable to GetCLIConfStruct " + err.Error())
		// }
		// sCoinName, err := be.GetCoinName(be.APPTCLI)
		// if err != nil {
		// 	log.Fatal("Unable to GetCoinName " + err.Error())
		// }

		// // Check that the current project is valid.
		// switch bwConf.ProjectType {
		// case be.PTBitcoinPlus:
		// 	if err := be.WalletBackup(be.PTBitcoinPlus); err != nil {
		// 		log.Fatal("Unable to backup the " + sCoinName + " wallet.dat file: " + err.Error())
		// 	}
		// case be.PTDenarius:
		// 	if err := be.WalletBackup(be.PTDenarius); err != nil {
		// 		log.Fatal("Unable to backup the " + sCoinName + " wallet.dat file: " + err.Error())
		// 	}
		// case be.PTDeVault:
		// 	if err := be.WalletBackup(be.PTDeVault); err != nil {
		// 		log.Fatal("Unable to backup the " + sCoinName + " wallet.dat file: " + err.Error())
		// 	}
		// case be.PTDigiByte:
		// 	if err := be.WalletBackup(be.PTDigiByte); err != nil {
		// 		log.Fatal("Unable to backup the " + sCoinName + " wallet.dat file: " + err.Error())
		// 	}
		// case be.PTDivi:
		// 	if err := be.WalletBackup(be.PTDivi); err != nil {
		// 		log.Fatal("Unable to backup the " + sCoinName + " wallet.dat file: " + err.Error())
		// 	}
		// case be.PTFeathercoin:
		// 	if err := be.WalletBackup(be.PTFeathercoin); err != nil {
		// 		log.Fatal("Unable to backup the " + sCoinName + " wallet.dat file: " + err.Error())
		// 	}
		// case be.PTGroestlcoin:
		// 	if err := be.WalletBackup(be.PTGroestlcoin); err != nil {
		// 		log.Fatal("Unable to backup the " + sCoinName + " wallet.dat file: " + err.Error())
		// 	}
		// case be.PTPhore:
		// 	if err := be.WalletBackup(be.PTPhore); err != nil {
		// 		log.Fatal("Unable to backup the " + sCoinName + " wallet.dat file: " + err.Error())
		// 	}
		// case be.PTPIVX:
		// 	if err := be.WalletBackup(be.PTPIVX); err != nil {
		// 		log.Fatal("Unable to backup the " + sCoinName + " wallet.dat file: " + err.Error())
		// 	}
		// case be.PTRapids:
		// 	if err := be.WalletBackup(be.PTRapids); err != nil {
		// 		log.Fatal("Unable to backup the " + sCoinName + " wallet.dat file: " + err.Error())
		// 	}
		// case be.PTReddCoin:
		// 	if err := be.WalletBackup(be.PTReddCoin); err != nil {
		// 		log.Fatal("Unable to backup the " + sCoinName + " wallet.dat file: " + err.Error())
		// 	}
		// case be.PTScala:
		// 	if err := be.WalletBackup(be.PTScala); err != nil {
		// 		log.Fatal("Unable to backup the " + sCoinName + " wallet.dat file: " + err.Error())
		// 	}
		// case be.PTTrezarcoin:
		// 	if err := be.WalletBackup(be.PTTrezarcoin); err != nil {
		// 		log.Fatal("Unable to backup the " + sCoinName + " wallet.dat file: " + err.Error())
		// 	}
		// case be.PTVertcoin:
		// 	if err := be.WalletBackup(be.PTVertcoin); err != nil {
		// 		log.Fatal("Unable to backup the " + sCoinName + " wallet.dat file: " + err.Error())
		// 	}
		// default:
		// 	log.Fatal("Unable to determine project type")
		// }

		// fmt.Println("Backup completed. Please store your backup wallet.dat file somewhere safe.")
		// // Now display tip message.
		// sTipInfo := be.GetTipInfo(bwConf.ProjectType)
		// fmt.Println("\n\n" + sTipInfo + "\n")
	},
}

func init() {
	walletCmd.AddCommand(backupCmd)

	// Here you will define your flags and configuration settings.

	// Cobra supports Persistent Flags which will work for this command
	// and all subcommands, e.g.:
	// backupCmd.PersistentFlags().String("foo", "", "A help for foo")

	// Cobra supports local flags which will only run when this command
	// is called directly, e.g.:
	// backupCmd.Flags().BoolP("toggle", "t", false, "Help message for toggle")
}
