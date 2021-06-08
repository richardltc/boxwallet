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
	// "log"
	// "os"
	// be "richardmace.co.uk/boxwallet/cmd/cli/cmd/bend"

	"github.com/spf13/cobra"
)

const (
	cWalletDisplaySeedWarning string = `
A recovery seed can be used to recover your wallet, should anything happen to this computer.
						
It's a good idea to have more than one and keep each in a safe place, other than your computer.`
)

// displayprivseedCmd represents the displayprivseed command
var displayprivseedCmd = &cobra.Command{
	Use:   "displayprivseed",
	Short: "Displays your wallet private seed for future restore (make sure nobody is watching over your shoulder)",
	Long:  ``,
	Run: func(cmd *cobra.Command, args []string) {

		// apw, err := be.GetAppWorkingFolder()
		// if err != nil {
		// 	log.Fatal("Unable to GetAppWorkingFolder: " + err.Error())
		// }

		// // Make sure the config file exists, and if not, force user to use "coin" command first.
		// if _, err := os.Stat(apw + be.CConfFile + be.CConfFileExt); os.IsNotExist(err) {
		// 	log.Fatal("Unable to determine coin type. Please run " + be.CAppFilename + " coin first")
		// }

		// cliConf, err := be.GetConfigStruct("", true)
		// if err != nil {
		// 	log.Fatal("Unable to GetCLIConfStruct " + err.Error())
		// }

		// sAppFileCLIName, err := be.GetAppFileName()
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

		// switch cliConf.ProjectType {
		// case be.PTDivi:
		// 	wi, err := be.GetWalletInfoDivi(&cliConf)
		// 	if err != nil {
		// 		log.Fatalf("error getting wallet info: %v", err)
		// 	}
		// 	if wi.Result.EncryptionStatus != be.CWalletESUnlocked {
		// 		log.Fatal("\n\nYour wallet is not currently unlocked.\n\nPlease use the command: boxwallet wallet unlock\n\nAnd then re-run this command again.")
		// 	}
		// default:
		// 	log.Fatalf("It looks like " + cn + " does not currently support this command.")
		// }

		// // Display instructions for displaying seed recovery

		// sWarning := cWalletDisplaySeedWarning
		// fmt.Printf(sWarning)
		// fmt.Println("")
		// fmt.Println("\nRequesting private seed...")

		// hdInfo, err := be.GetDumpHDInfoDivi(&cliConf)
		// if err != nil {
		// 	log.Fatalf("error calling hddumpinfo info: %v", err)
		// }

		// fmt.Println("\nPrivate seed received...")
		// fmt.Println("")
		// println(hdInfo.Result.Mnemonic)
	},
}

func init() {
	walletCmd.AddCommand(displayprivseedCmd)

	// Here you will define your flags and configuration settings.

	// Cobra supports Persistent Flags which will work for this command
	// and all subcommands, e.g.:
	// displayprivseedCmd.PersistentFlags().String("foo", "", "A help for foo")

	// Cobra supports local flags which will only run when this command
	// is called directly, e.g.:
	// displayprivseedCmd.Flags().BoolP("toggle", "t", false, "Help message for toggle")
}
