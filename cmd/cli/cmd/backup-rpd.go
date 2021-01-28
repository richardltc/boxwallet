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

// rpdCmd represents the rpd command
var rpdCmd = &cobra.Command{
	Use:   "rpd",
	Short: "Makes a backup copy of your " + be.CCoinNameRapids + " wallet.dat file, into the current folder",
	Long:  ``,
	Run: func(cmd *cobra.Command, args []string) {
		fmt.Println("Attempting to backup your " + be.CCoinNameRapids + " wallet.dat file")
		if err := be.WalletBackup(be.PTRapids); err != nil {
			log.Fatal("Unable to backup the " + be.CCoinNameRapids + " wallet.dat file: " + err.Error())
		}
		fmt.Println("Backup completed. Please store your backup wallet.dat file somewhere safe.")
		fmt.Println("\n\nThank you for using " + be.CAppName)
		fmt.Println(be.CAppName + " is FREE to use, and if you'd like to send a tip, please feel free to at the following " + be.CCoinNameRapids + " address below:")
		s := be.GetTipAddress(be.PTRapids)
		fmt.Println("\n" + be.CCoinAbbrevRapids + ": " + s)
	},
}

func init() {
	backupCmd.AddCommand(rpdCmd)

	// Here you will define your flags and configuration settings

	// Cobra supports Persistent Flags which will work for this command
	// and all subcommands, e.g.:
	// rpdCmd.PersistentFlags().String("foo", "", "A help for foo")

	// Cobra supports local flags which will only run when this command
	// is called directly, e.g.:
	// rpdCmd.Flags().BoolP("toggle", "t", false, "Help message for toggle")
}
