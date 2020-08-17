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
	"fmt"
	"log"

	be "richardmace.co.uk/boxdivi/cmd/cli/cmd/bend"

	gwc "github.com/richardltc/gwcommon"
	"github.com/spf13/cobra"
	//gdc "richardmace.co.uk/boxdivi/gdcommon"
)

// displayaddressCmd represents the displayaddress command
var displayaddressCmd = &cobra.Command{
	Use:   "displayaddress",
	Short: "Displays your wallet address",
	Long:  ``,
	Run: func(cmd *cobra.Command, args []string) {
		cliConf, err := gwc.GetCLIConfStruct()
		if err != nil {
			log.Fatal("Unable to GetCLIConfStruct " + err.Error())
		}

		r, err := be.GetWalletAddress(&cliConf)
		if err != nil {
			log.Fatalf("failed to displayaddress %s\n", err)
		}
		fmt.Println("Your address is: \n\n" + r.Result[0] + "\n")

		// sAppCLIName, err := gwc.GetAppCLIName() // e.g. GoDivi CLI
		// if err != nil {
		// 	log.Fatal("Unable to GetAppCLIName " + err.Error())
		// }
		// sAppFileCLIName, err := gwc.GetAppFileName(gwc.APPTCLI)
		// if err != nil {
		// 	log.Fatal("Unable to GetAppFileCLIName " + err.Error())
		// }

		// // Check to make sure we're installed
		// if !gwc.IsGoWalletInstalled() {
		// 	log.Fatal(sAppCLIName + ` doesn't appear to be installed yet. Please run "` + sAppFileCLIName + ` install" first`)
		// }

		// Start the Coin Daemon service if required...
		// err = gwc.RunCoinDaemon(true)
		// if err != nil {
		// 	log.Fatalf("failed to run the coin daemon: %v", err)
		// }
		// wa, err := gwc.GetWalletAddress(10)
		// if err != nil {
		// 	log.Fatalf("unable to get wallet address: %v", err)
		// }
		//fmt.Printf("\nYour address has been received:\n\n")
		//fmt.Println(wa)
	},
}

func init() {
	walletCmd.AddCommand(displayaddressCmd)

	// Here you will define your flags and configuration settings.

	// Cobra supports Persistent Flags which will work for this command
	// and all subcommands, e.g.:
	// displayaddressCmd.PersistentFlags().String("foo", "", "A help for foo")

	// Cobra supports local flags which will only run when this command
	// is called directly, e.g.:
	// displayaddressCmd.Flags().BoolP("toggle", "t", false, "Help message for toggle")
}
