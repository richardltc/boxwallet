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
	"github.com/spf13/cobra"
	"log"
	be "richardmace.co.uk/boxwallet/cmd/cli/cmd/bend"
)

// backupCmd represents the backup command
var backupCmd = &cobra.Command{
	Use:   "backup",
	Short: "Performs a backup of the wallet.dat file for the current coin",
	Long:  `Copies the waller.dat file, of the currently selected coin, to the current directory`,
	Run: func(cmd *cobra.Command, args []string) {
		// The user has just chosen the wallet backup command, without specifying the coin type, so let's see if we have one
		bwConf, err := be.GetConfigStruct("", true)
		if err != nil {
			log.Fatal("Unable to GetCLIConfStruct " + err.Error())
		}
		sCoinName, err := be.GetCoinName(be.APPTCLI)
		if err != nil {
			log.Fatal("Unable to GetCoinName " + err.Error())
		}

		// Check that the current project is valid.
		switch bwConf.ProjectType {
		case be.PTBitcoinPlus:
			if err := be.WalletBackup(be.PTBitcoinPlus); err != nil {
				log.Fatal("Unable to backup the " + sCoinName + " wallet.dat file: " + err.Error())
			}
		case be.PTDenarius:
			if err := be.WalletBackup(be.PTDenarius); err != nil {
				log.Fatal("Unable to backup the " + sCoinName + " wallet.dat file: " + err.Error())
			}
		case be.PTDeVault:
			if err := be.WalletBackup(be.PTDeVault); err != nil {
				log.Fatal("Unable to backup the " + sCoinName + " wallet.dat file: " + err.Error())
			}
		case be.PTDigiByte:
			if err := be.WalletBackup(be.PTDigiByte); err != nil {
				log.Fatal("Unable to backup the " + sCoinName + " wallet.dat file: " + err.Error())
			}
		case be.PTDivi:
			if err := be.WalletBackup(be.PTDivi); err != nil {
				log.Fatal("Unable to backup the " + sCoinName + " wallet.dat file: " + err.Error())
			}
		case be.PTFeathercoin:
			if err := be.WalletBackup(be.PTFeathercoin); err != nil {
				log.Fatal("Unable to backup the " + sCoinName + " wallet.dat file: " + err.Error())
			}
		case be.PTGroestlcoin:
			if err := be.WalletBackup(be.PTGroestlcoin); err != nil {
				log.Fatal("Unable to backup the " + sCoinName + " wallet.dat file: " + err.Error())
			}
		case be.PTPhore:
			if err := be.WalletBackup(be.PTPhore); err != nil {
				log.Fatal("Unable to backup the " + sCoinName + " wallet.dat file: " + err.Error())
			}
		case be.PTPIVX:
			if err := be.WalletBackup(be.PTPIVX); err != nil {
				log.Fatal("Unable to backup the " + sCoinName + " wallet.dat file: " + err.Error())
			}
		case be.PTRapids:
			if err := be.WalletBackup(be.PTRapids); err != nil {
				log.Fatal("Unable to backup the " + sCoinName + " wallet.dat file: " + err.Error())
			}
		case be.PTReddCoin:
			if err := be.WalletBackup(be.PTReddCoin); err != nil {
				log.Fatal("Unable to backup the " + sCoinName + " wallet.dat file: " + err.Error())
			}
		case be.PTScala:
			if err := be.WalletBackup(be.PTScala); err != nil {
				log.Fatal("Unable to backup the " + sCoinName + " wallet.dat file: " + err.Error())
			}
		case be.PTTrezarcoin:
			if err := be.WalletBackup(be.PTTrezarcoin); err != nil {
				log.Fatal("Unable to backup the " + sCoinName + " wallet.dat file: " + err.Error())
			}
		case be.PTVertcoin:
			if err := be.WalletBackup(be.PTVertcoin); err != nil {
				log.Fatal("Unable to backup the " + sCoinName + " wallet.dat file: " + err.Error())
			}
		default:
			log.Fatal("Unable to determine project type")
		}

		fmt.Println("Backup completed. Please store your backup wallet.dat file somewhere safe.")
		// Now display tip message.
		sTipInfo := be.GetTipInfo(bwConf.ProjectType)
		fmt.Println("\n\n" + sTipInfo + "\n")
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
