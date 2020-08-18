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

		// Start the DiviD server if required...
		// err = gwc.RunCoinDaemon(true)
		// if err != nil {
		// 	log.Fatalf("failed to run divid: %v", err)
		// }

		// wi, err := gwc.GetWalletInfo(true)
		// if err != nil {
		// 	log.Fatalf("error getting wallet info: %v", err)
		// }

		// fmt.Println("\n\nWallet status is: " + wi.EncryptionStatus)
		// If the wallet is locked, it needs to be unlocked to be able to display the seed
		// if wi.EncryptionStatus == gwc.CWalletStatusLocked || wi.EncryptionStatus == gwc.CWalletStatusLockedAndSk {
		// 	//pw := "getWalletUnlockPassword()"
		// 	pw := gwc.GetWalletUnlockPassword()

		// 	couldUW, err := gwc.UnlockWallet(pw, 30, false)

		// 	if !couldUW || err != nil {
		// 		log.Fatalf("Unable to unlock wallet: " + err.Error())
		// 	}
		// }

		// Display instructions for displaying seed recovery

		sWarning := cWalletDisplaySeedWarning
		fmt.Printf(sWarning)
		fmt.Println("")
		fmt.Println("\nRequesting private seed...")

		// err = gwc.DoPrivKeyDisplay()
		// if err != nil {
		// 	log.Fatalf("doPrivKeyDisplay() failed with %s\n", err)
		// }
		fmt.Println("\nPrivate seed received...")
		fmt.Println("")
		// println(s)

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
