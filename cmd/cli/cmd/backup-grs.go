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
	"log"
	be "richardmace.co.uk/boxwallet/cmd/cli/cmd/bend"

	"github.com/spf13/cobra"
)

// grsCmd represents the grs command
var grsCmd = &cobra.Command{
	Use:   "grs",
	Short: "Makes a backup copy of your " + be.CCoinNameGroestlcoin + " wallet.dat file, into the current folder",
	Long:  ``,
	Run: func(cmd *cobra.Command, args []string) {
		fmt.Println("Attempting to backup your " + be.CCoinNameGroestlcoin + " wallet.dat file")
		if err := be.WalletBackup(be.PTGroestlcoin); err != nil {
			log.Fatal("Unable to backup the " + be.CCoinNameGroestlcoin + " wallet.dat file: " + err.Error())
		}
		fmt.Println("Backup completed. Please store your backup wallet.dat file somewhere safe.")
		fmt.Println("\n\nThank you for using " + be.CAppName)
		fmt.Println(be.CAppName + " is FREE to use, and if you'd like to send a tip, please feel free to at the following " + be.CCoinNameGroestlcoin + " address below:")
		s := be.GetTipAddress(be.PTGroestlcoin)
		fmt.Println("\n" + be.CCoinAbbrevGroestlcoin + ": " + s)
	},
}

func init() {
	backupCmd.AddCommand(grsCmd)

	// Here you will define your flags and configuration settings

	// Cobra supports Persistent Flags which will work for this command
	// and all subcommands, e.g.:
	// grsCmd.PersistentFlags().String("foo", "", "A help for foo")

	// Cobra supports local flags which will only run when this command
	// is called directly, e.g.:
	// grsCmd.Flags().BoolP("toggle", "t", false, "Help message for toggle")
}
