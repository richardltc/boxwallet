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

// dgbCmd represents the dgb command
var dgbCmd = &cobra.Command{
	Use:   "dgb",
	Short: "Makes a backup copy of your " + be.CCoinNameDigiByte + " wallet.dat file, into the current folder",
	Long:  ``,
	Run: func(cmd *cobra.Command, args []string) {
		fmt.Println("Attempting to backup your " + be.CCoinNameDigiByte + " wallet.dat file")
		if err := be.WalletBackup(be.PTDigiByte); err != nil {
			log.Fatal("Unable to backup the " + be.CCoinNameDigiByte + " wallet.dat file: " + err.Error())
		}
		fmt.Println("Backup completed. Please store your backup wallet.dat file somewhere safe.")
		fmt.Println("\n\nThank you for using " + be.CAppName)
		fmt.Println(be.CAppName + " is FREE to use, and if you'd like to send a tip, please feel free to at the following " + be.CCoinNameDigiByte + " address below:")
		s := be.GetTipAddress(be.PTDigiByte)
		fmt.Println("\n" + be.CCoinAbbrevDigiByte + ": " + s)
	},
}

func init() {
	backupCmd.AddCommand(dgbCmd)

	// Here you will define your flags and configuration settings.

	// Cobra supports Persistent Flags which will work for this command
	// and all subcommands, e.g.:
	// dgbCmd.PersistentFlags().String("foo", "", "A help for foo")

	// Cobra supports local flags which will only run when this command
	// is called directly, e.g.:
	// dgbCmd.Flags().BoolP("toggle", "t", false, "Help message for toggle")
}
